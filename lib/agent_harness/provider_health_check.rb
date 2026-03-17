# frozen_string_literal: true

require "timeout"

module AgentHarness
  # Performs health checks on configured providers
  #
  # Validates provider setup, authentication status, and reachability.
  # Returns per-provider status objects with name, status, message, and latency.
  #
  # @example Check all providers
  #   results = AgentHarness::ProviderHealthCheck.check_all
  #   results.each { |r| puts "#{r[:name]}: #{r[:status]}" }
  #
  # @example Check a single provider
  #   result = AgentHarness::ProviderHealthCheck.check(:claude)
  #   puts result[:status] # => "ok", "error", or "degraded"
  class ProviderHealthCheck
    DEFAULT_TIMEOUT = 5

    class << self
      # Check health of all configured providers
      #
      # @param timeout [Integer] timeout in seconds for each check
      # @return [Array<Hash>] health status for each provider
      def check_all(timeout: configured_timeout)
        provider_names = enabled_provider_names
        provider_names = Providers::Registry.instance.all if provider_names.empty?

        provider_names.map { |name| check(name, timeout: timeout) }
      end

      # Check health of a single provider
      #
      # @param provider_name [Symbol, String] the provider name
      # @param timeout [Integer] timeout in seconds
      # @return [Hash] health status with :name, :status, :message, :latency_ms keys
      def check(provider_name, timeout: configured_timeout)
        name = normalize_name(provider_name)
        start_time = monotonic_now

        Timeout.timeout(timeout) do
          perform_check(name, start_time)
        end
      rescue Timeout::Error
        build_result(
          name: name,
          status: "error",
          message: "Health check timed out after #{timeout}s",
          start_time: start_time || monotonic_now
        )
      rescue => e
        build_result(
          name: name,
          status: "error",
          message: e.message,
          start_time: start_time || monotonic_now
        )
      end

      # Format health check results for CLI output
      #
      # @param results [Array<Hash>] health check results
      # @return [String] formatted output
      def format_results(results)
        lines = ["Checking providers..."]

        results.each do |result|
          name = result[:name].to_s.ljust(16)
          case result[:status]
          when "ok"
            latency = result[:latency_ms] ? "(#{result[:latency_ms]}ms)" : ""
            lines << "  ✓ #{name} OK #{latency}".rstrip
          when "degraded"
            lines << "  ~ #{name} #{result[:message]}"
          else
            lines << "  ✗ #{name} #{result[:message]}"
          end
        end

        failed = results.count { |r| r[:status] == "error" }
        degraded = results.count { |r| r[:status] == "degraded" }
        total = results.size

        lines << ""
        summary_parts = []
        summary_parts << "#{failed} failed" if failed > 0
        summary_parts << "#{degraded} degraded" if degraded > 0

        lines << if summary_parts.any?
          "#{total} providers checked: #{summary_parts.join(", ")}."
        else
          "All #{total} providers healthy."
        end

        lines.join("\n")
      end

      private

      def enabled_provider_names
        AgentHarness.configuration.providers.select { |_name, config| config.enabled }.keys
      end

      def configured_timeout
        timeout = AgentHarness.configuration.orchestration_config.health_check_config.timeout
        (timeout.is_a?(Numeric) && timeout.positive?) ? timeout : DEFAULT_TIMEOUT
      rescue NoMethodError
        DEFAULT_TIMEOUT
      end

      def normalize_name(provider_name)
        provider_name.to_sym
      rescue NoMethodError, ArgumentError, TypeError
        :unknown
      end

      def perform_check(provider_name, start_time)
        # Step 1: Check provider is registered
        registry = Providers::Registry.instance
        unless registry.registered?(provider_name)
          return build_result(
            name: provider_name,
            status: "error",
            message: "Provider not registered",
            start_time: start_time
          )
        end

        # Step 2: Check CLI availability
        klass = registry.get(provider_name)
        unless klass.available?
          return build_result(
            name: provider_name,
            status: "error",
            message: "CLI '#{klass.binary_name}' not found in PATH",
            start_time: start_time
          )
        end

        # Step 3: Check authentication
        auth = Authentication.auth_status(provider_name)
        unless auth[:valid]
          return build_result(
            name: provider_name,
            status: "error",
            message: auth[:error] || "Authentication failed",
            start_time: start_time
          )
        end

        # Step 4: Check provider-level health (e.g., endpoint reachability)
        provider_instance = build_provider(provider_name, klass)
        health = provider_instance.health_status
        unless health[:healthy]
          return build_result(
            name: provider_name,
            status: "degraded",
            message: health[:message] || "Provider health check failed",
            start_time: start_time
          )
        end

        # Step 5: Validate provider config
        validation = provider_instance.validate_config
        unless validation[:valid]
          errors_msg = Array(validation[:errors]).join(", ")
          return build_result(
            name: provider_name,
            status: "degraded",
            message: "Configuration issues: #{errors_msg}",
            start_time: start_time
          )
        end

        build_result(
          name: provider_name,
          status: "ok",
          message: "Authenticated successfully",
          start_time: start_time
        )
      end

      def build_result(name:, status:, message:, start_time:)
        latency = ((monotonic_now - start_time) * 1000).round
        {
          name: name,
          status: status,
          message: message,
          latency_ms: latency
        }
      end

      def build_provider(provider_name, klass)
        config = AgentHarness.configuration.providers[provider_name]
        klass.new(
          config: config,
          executor: AgentHarness.configuration.command_executor,
          logger: AgentHarness.logger
        )
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
