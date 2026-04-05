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
    # Single source of truth: derive the fallback from HealthCheckConfig's default
    # so that the timeout isn't duplicated here and in configuration.rb.
    DEFAULT_TIMEOUT = HealthCheckConfig.new.timeout

    class << self
      # Check health of all configured providers
      #
      # @param timeout [Integer] timeout in seconds for each check
      # @return [Array<Hash>] health status for each provider
      def check_all(timeout: configured_timeout, executor: nil, provider_runtime: nil)
        provider_names = if AgentHarness.configuration.providers.empty?
          Providers::Registry.instance.all
        else
          enabled_provider_names
        end

        provider_names.map do |name|
          check(name, timeout: timeout, executor: executor, provider_runtime: provider_runtime)
        end
      end

      # Check health of a single provider
      #
      # @param provider_name [Symbol, String] the provider name
      # @param timeout [Integer] timeout in seconds
      # @return [Hash] health status with :name, :status, :message, :latency_ms keys
      def check(provider_name, timeout: configured_timeout, executor: nil, provider_runtime: nil)
        name = normalize_name(provider_name)
        start_time = monotonic_now
        timeout = validate_timeout(timeout)

        Timeout.timeout(timeout) do
          perform_check(
            name,
            start_time,
            timeout: timeout,
            executor: executor,
            provider_runtime: provider_runtime
          )
        end
      rescue Timeout::Error
        build_result(
          name: name,
          status: "error",
          message: "Health check timed out after #{timeout}s",
          start_time: start_time || monotonic_now,
          error_category: :timeout,
          check: :timeout
        )
      rescue NotImplementedError => e
        # NotImplementedError inherits from ScriptError, not StandardError,
        # so it must be rescued explicitly. Its messages are safe internal
        # setup errors (e.g., missing provider methods) that help users
        # diagnose configuration problems.
        AgentHarness.logger&.error("ProviderHealthCheck error for #{name}: #{e.class}")
        build_result(
          name: name,
          status: "error",
          message: "Health check failed: #{e.class}: #{e.message}",
          start_time: start_time || monotonic_now,
          error_category: :unknown,
          check: :provider_health
        )
      rescue => e
        # Return a generic message to avoid leaking sensitive details
        # (e.g., tokens embedded in exception messages). Log only the
        # exception class (not the message) to avoid leaking secrets.
        AgentHarness.logger&.error("ProviderHealthCheck error for #{name}: #{e.class}")
        build_result(
          name: name,
          status: "error",
          message: "Health check failed: #{e.class}",
          start_time: start_time || monotonic_now,
          error_category: :unknown,
          check: :provider_health
        )
      end

      # Format health check results for CLI output
      #
      # @param results [Array<Hash>] health check results
      # @return [String] formatted output
      def format_results(results)
        lines = ["Checking providers..."]

        if results.empty?
          lines << ""
          lines << "No providers checked."
          return lines.join("\n")
        end

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

        provider_word = (total == 1) ? "provider" : "providers"
        lines << if summary_parts.any?
          "#{total} #{provider_word} checked: #{summary_parts.join(", ")}."
        else
          "All #{total} #{provider_word} healthy."
        end

        lines.join("\n")
      end

      private

      def enabled_provider_names
        AgentHarness.configuration.providers.select { |_name, config| config.enabled }.keys
      end

      def validate_timeout(timeout)
        (timeout.is_a?(Numeric) && timeout.positive?) ? timeout : configured_timeout
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

      def perform_check(provider_name, start_time, timeout:, executor:, provider_runtime:)
        # Step 1: Check provider is registered
        registry = Providers::Registry.instance
        unless registry.registered?(provider_name)
          return build_result(
            name: provider_name,
            status: "error",
            message: "Provider not registered",
            start_time: start_time,
            error_category: :installation,
            check: :registration
          )
        end

        klass = registry.get(provider_name)
        provider_instance = build_provider(provider_name, klass, executor: executor)
        host_preflight_allowed = host_preflight_allowed?(executor: executor, provider_runtime: provider_runtime)

        auth_degraded = false
        if host_preflight_allowed
          # Step 2: Check CLI availability
          unless klass.available?
            return build_result(
              name: provider_name,
              status: "error",
              message: "CLI '#{klass.binary_name}' not found in PATH",
              start_time: start_time,
              error_category: :installation,
              check: :availability
            )
          end

          # Step 3: Check authentication
          # Treat "not implemented" auth status as degraded rather than error,
          # since most built-in providers don't implement auth_status hooks.
          # In either case, continue to steps 4/5 so health and config issues
          # are still surfaced for providers that lack an auth_status hook.
          auth = Authentication.auth_status(provider_name)
          unless auth[:valid]
            unless auth_not_implemented?(auth)
              return build_result(
                name: provider_name,
                status: "error",
                message: auth[:error] || "Authentication failed",
                start_time: start_time,
                error_category: :authentication,
                check: :authentication
              )
            end
            auth_degraded = true
          end

          # Step 4: Check provider-level health (e.g., endpoint reachability)
          # The Adapter default always returns {healthy: true}, so providers
          # that haven't implemented a real health check are reported as ok
          # with a note that the check is not implemented.
          health = provider_instance.health_status
          unless health[:healthy]
            return build_result(
              name: provider_name,
              status: "degraded",
              message: health[:message] || "Provider health check failed",
              start_time: start_time,
              error_category: :transient,
              check: :provider_health
            )
          end
        end

        # Step 5: Validate provider config
        # The Adapter default always returns {valid: true}, so providers
        # that haven't implemented real config validation pass by default.
        validation = provider_instance.validate_config
        unless validation[:valid]
          errors_msg = Array(validation[:errors]).join(", ")
          errors_msg = "check provider configuration" if errors_msg.empty?
          return build_result(
            name: provider_name,
            status: "degraded",
            message: "Configuration issues: #{errors_msg}",
            start_time: start_time,
            error_category: :configuration,
            check: :configuration
          )
        end

        smoke_contract = provider_instance.smoke_test_contract
        unless smoke_contract || provider_overrides_method?(provider_instance, :smoke_test)
          message = if host_preflight_allowed && auth_degraded
            "Auth status check not implemented; health and config checks passed (smoke test unavailable)"
          elsif host_preflight_allowed && (provider_overrides_method?(provider_instance, :health_status) ||
            provider_overrides_method?(provider_instance, :validate_config))
            "Health and config checks passed (smoke test unavailable)"
          elsif host_preflight_allowed
            "Registered and authenticated; health/config checks use defaults and smoke test is unavailable"
          elsif provider_overrides_method?(provider_instance, :validate_config)
            "Configuration checks passed, but smoke test is unavailable for the supplied execution context"
          else
            "Smoke test is unavailable for the supplied execution context"
          end

          return build_result(
            name: provider_name,
            status: "degraded",
            message: message,
            start_time: start_time,
            error_category: :configuration,
            check: :smoke_test
          )
        end

        smoke = provider_instance.smoke_test(timeout: timeout, provider_runtime: provider_runtime)
        unless smoke[:ok]
          return build_result(
            name: provider_name,
            status: smoke[:status] || "error",
            message: smoke[:message] || "Smoke test failed",
            start_time: start_time,
            error_category: normalize_smoke_error_category(smoke[:error_category], smoke[:message]),
            check: :smoke_test
          )
        end

        # If auth was not implemented but health/config passed, report degraded
        if auth_degraded
          return build_result(
            name: provider_name,
            status: "degraded",
            message: "Auth status check not implemented; health, config, and smoke tests passed",
            start_time: start_time,
            error_category: :authentication,
            check: :authentication
          )
        end

        message = if !host_preflight_allowed && provider_overrides_method?(provider_instance, :validate_config)
          "Configuration and smoke test passed using the supplied execution context"
        elsif !host_preflight_allowed
          "Smoke test passed using the supplied execution context"
        elsif provider_overrides_method?(provider_instance, :health_status) ||
            provider_overrides_method?(provider_instance, :validate_config)
          "All checks passed"
        else
          "Registered, authenticated, and smoke test passed (health/config checks use defaults)"
        end

        build_result(
          name: provider_name,
          status: "ok",
          message: message,
          start_time: start_time,
          check: :smoke_test
        )
      end

      def auth_not_implemented?(auth)
        # Prefer explicit flags over brittle string matching on error messages.
        # This keeps backward compatibility with existing callers that only set :error,
        # while allowing newer callers to pass structured reasons.
        if auth.respond_to?(:[])
          return true if auth.key?(:implemented) && auth[:implemented] == false
          return true if auth.key?(:reason) && auth[:reason] == :not_implemented
        end

        error = auth[:error].to_s
        error.include?("not implemented")
      end

      def host_preflight_allowed?(executor:, provider_runtime:)
        return false unless executor.nil?
        return true if provider_runtime.nil?

        ProviderRuntime.wrap(provider_runtime).empty?
      end

      def normalize_smoke_error_category(category, message)
        normalized = if installation_failure_message?(message)
          :installation
        else
          category || ErrorTaxonomy.classify_message(message)
        end

        case normalized&.to_sym
        when :installation
          :installation
        when :auth_expired, :authentication
          :authentication
        when :rate_limited, :rate_limit
          :rate_limit
        when :quota_exceeded, :quota
          :quota
        when :timeout
          :timeout
        when :transient
          :transient
        when :sandbox_failure, :configuration, :permanent
          :configuration
        else
          :unknown
        end
      end

      def installation_failure_message?(message)
        message.to_s.match?(/(not found in PATH|command not found|No such file or directory|is not installed)/i)
      end

      def provider_overrides_method?(provider_instance, method_name)
        provider_instance.method(method_name).owner != Providers::Adapter
      end

      def build_result(name:, status:, message:, start_time:, error_category: nil, check: nil)
        latency = ((monotonic_now - start_time) * 1000).round
        {
          name: name,
          status: status,
          message: message,
          latency_ms: latency,
          error_category: error_category,
          check: check
        }
      end

      def build_provider(provider_name, klass, executor:)
        config = AgentHarness.configuration.providers[provider_name]
        klass.new(
          config: config,
          executor: executor || AgentHarness.configuration.command_executor,
          logger: AgentHarness.logger
        )
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
