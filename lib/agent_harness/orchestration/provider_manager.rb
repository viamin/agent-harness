# frozen_string_literal: true

module AgentHarness
  module Orchestration
    # Manages provider instances and selection
    #
    # Handles provider lifecycle, health tracking, circuit breakers,
    # and rate limiters. Provides intelligent provider selection based
    # on availability and health.
    class ProviderManager
      attr_reader :current_provider, :provider_instances

      # Create a new provider manager
      #
      # @param config [Configuration] the configuration
      def initialize(config)
        @config = config
        @registry = Providers::Registry.instance
        @provider_instances = {}
        @current_provider = config.default_provider

        @circuit_breakers = {}
        @rate_limiters = {}
        @health_monitor = HealthMonitor.new(config.orchestration_config.health_check_config)
        @fallback_chains = {}

        initialize_providers
      end

      # Select best available provider
      #
      # @param preferred [Symbol, nil] preferred provider name
      # @param executor [CommandExecutor, nil] per-request executor override
      # @return [Providers::Base] selected provider instance
      # @raise [NoProvidersAvailableError] if no providers available
      def select_provider(preferred = nil, executor: nil)
        preferred ||= @current_provider

        # Check circuit breaker
        if circuit_open?(preferred)
          return select_fallback(preferred, reason: :circuit_open, executor: executor)
        end

        # Check rate limit
        if rate_limited?(preferred)
          return select_fallback(preferred, reason: :rate_limited, executor: executor)
        end

        # Check health
        unless healthy?(preferred)
          return select_fallback(preferred, reason: :unhealthy, executor: executor)
        end

        get_provider(preferred, executor: executor)
      end

      # Get or create provider instance
      #
      # @param name [Symbol, String] the provider name
      # @param executor [CommandExecutor, nil] per-request executor override
      # @return [Providers::Base] the provider instance
      def get_provider(name, executor: nil)
        name = name.to_sym
        return create_provider(name, executor: executor) if executor

        @provider_instances[name] ||= create_provider(name)
      end

      # Switch to next available provider
      #
      # @param reason [Symbol, String] reason for switch
      # @param context [Hash] additional context
      # @param executor [CommandExecutor, nil] per-request executor override
      # @return [Providers::Base, nil] new provider or nil if none available
      def switch_provider(reason:, context: {}, executor: nil)
        old_provider = @current_provider

        fallback = select_fallback(@current_provider, reason: reason, executor: executor)
        return nil unless fallback

        return fallback if executor

        @current_provider = fallback.class.provider_name

        AgentHarness.logger&.info(
          "[AgentHarness] Provider switch: #{old_provider} -> #{@current_provider} (#{reason})"
        )

        @config.callbacks.emit(:provider_switch, {
          from: old_provider,
          to: @current_provider,
          reason: reason,
          context: context
        })

        fallback
      end

      # Record success for provider
      #
      # @param provider_name [Symbol, String] the provider name
      # @return [void]
      def record_success(provider_name)
        provider_name = provider_name.to_sym
        @health_monitor.record_success(provider_name)
        @circuit_breakers[provider_name]&.record_success
      end

      # Record failure for provider
      #
      # @param provider_name [Symbol, String] the provider name
      # @return [void]
      def record_failure(provider_name)
        provider_name = provider_name.to_sym
        @health_monitor.record_failure(provider_name)
        @circuit_breakers[provider_name]&.record_failure
      end

      # Mark provider as rate limited
      #
      # @param provider_name [Symbol, String] the provider name
      # @param reset_at [Time, nil] when the limit resets
      # @return [void]
      def mark_rate_limited(provider_name, reset_at: nil)
        provider_name = provider_name.to_sym
        @rate_limiters[provider_name]&.mark_limited(reset_at: reset_at)
      end

      # Get available providers
      #
      # @return [Array<Symbol>] available provider names
      def available_providers
        @provider_instances.keys.select do |name|
          !circuit_open?(name) && !rate_limited?(name) && healthy?(name)
        end
      end

      # Get health status for all providers
      #
      # @return [Array<Hash>] health status for each provider
      def health_status
        @provider_instances.keys.map do |name|
          {
            provider: name,
            healthy: healthy?(name),
            circuit_open: circuit_open?(name),
            rate_limited: rate_limited?(name),
            metrics: @health_monitor.metrics_for(name)
          }
        end
      end

      # Reset all state
      #
      # @return [void]
      def reset!
        @circuit_breakers.each_value(&:reset!)
        @rate_limiters.each_value(&:reset!)
        @health_monitor.reset!
        @current_provider = @config.default_provider
      end

      # Check if circuit is open for provider
      #
      # @param provider_name [Symbol, String] the provider name
      # @return [Boolean] true if open
      def circuit_open?(provider_name)
        @circuit_breakers[provider_name.to_sym]&.open? || false
      end

      # Check if provider is rate limited
      #
      # @param provider_name [Symbol, String] the provider name
      # @return [Boolean] true if limited
      def rate_limited?(provider_name)
        @rate_limiters[provider_name.to_sym]&.limited? || false
      end

      # Check if provider is healthy
      #
      # @param provider_name [Symbol, String] the provider name
      # @return [Boolean] true if healthy
      def healthy?(provider_name)
        @health_monitor.healthy?(provider_name.to_sym)
      end

      private

      def initialize_providers
        @config.providers.each do |name, provider_config|
          next unless provider_config.enabled

          @circuit_breakers[name] = CircuitBreaker.new(
            @config.orchestration_config.circuit_breaker_config
          )

          @rate_limiters[name] = RateLimiter.new(
            @config.orchestration_config.rate_limit_config
          )

          @fallback_chains[name] = build_fallback_chain(name)
        end
      end

      def create_provider(name, executor: @config.command_executor)
        klass = @registry.get(name)
        config = @config.providers[name]

        klass.new(
          config: config,
          executor: executor,
          logger: AgentHarness.logger
        )
      end

      def select_fallback(provider_name, reason:, executor: nil)
        chain = @fallback_chains[provider_name] || build_fallback_chain(provider_name)

        chain.each do |fallback_name|
          next if fallback_name == provider_name
          next if circuit_open?(fallback_name)
          next if rate_limited?(fallback_name)
          next unless healthy?(fallback_name)

          AgentHarness.logger&.debug(
            "[AgentHarness::ProviderManager] Falling back from #{provider_name} to #{fallback_name} (#{reason})"
          )

          return get_provider(fallback_name, executor: executor)
        end

        # No fallback available
        raise NoProvidersAvailableError.new(
          "No providers available after #{provider_name} (#{reason})",
          attempted_providers: chain,
          errors: {provider_name => reason.to_s}
        )
      end

      def build_fallback_chain(provider_name)
        chain = [provider_name] + @config.fallback_providers
        chain += @config.providers.keys
        chain.uniq
      end
    end
  end
end
