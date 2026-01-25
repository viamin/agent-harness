# frozen_string_literal: true

module AgentHarness
  module Orchestration
    # Main orchestration entry point
    #
    # Provides a simple interface for sending messages while managing
    # provider selection, fallback, retries, and error handling internally.
    #
    # @example Basic usage
    #   conductor = AgentHarness::Orchestration::Conductor.new
    #   response = conductor.send_message("Hello, world!")
    #
    # @example With explicit provider
    #   response = conductor.send_message("Hello", provider: :gemini)
    class Conductor
      attr_reader :provider_manager, :metrics

      # Create a new conductor
      #
      # @param config [Configuration, nil] configuration object
      def initialize(config: nil)
        @config = config || AgentHarness.configuration
        @provider_manager = ProviderManager.new(@config)
        @metrics = Metrics.new
      end

      # Send a message with full orchestration
      #
      # Handles provider selection, fallback, retries, circuit breakers,
      # and error handling transparently.
      #
      # @param prompt [String] the prompt to send
      # @param provider [Symbol, nil] preferred provider
      # @param model [String, nil] model to use
      # @param options [Hash] additional options
      # @return [Response] the response
      # @raise [NoProvidersAvailableError] if all providers fail
      def send_message(prompt, provider: nil, model: nil, **options)
        provider_name = provider || @config.default_provider

        with_orchestration(provider_name, model, options) do |selected_provider|
          selected_provider.send_message(prompt: prompt, model: model, **options)
        end
      end

      # Execute with explicit provider (bypass orchestration)
      #
      # @param prompt [String] the prompt to send
      # @param provider [Symbol] the provider to use
      # @param options [Hash] additional options
      # @return [Response] the response
      def execute_direct(prompt, provider:, **options)
        provider_instance = @provider_manager.get_provider(provider)
        provider_instance.send_message(prompt: prompt, **options)
      end

      # Get current orchestration status
      #
      # @return [Hash] status information
      def status
        {
          current_provider: @provider_manager.current_provider,
          available_providers: @provider_manager.available_providers,
          health: @provider_manager.health_status,
          metrics: @metrics.summary
        }
      end

      # Reset all orchestration state
      #
      # @return [void]
      def reset!
        @provider_manager.reset!
        @metrics.reset!
      end

      private

      def with_orchestration(provider_name, model, options)
        retries = 0
        retry_config = @config.orchestration_config.retry_config
        max_retries = retry_config.max_attempts
        last_error = nil
        attempted_providers = []

        begin
          # Select provider (may return different provider based on health)
          provider = @provider_manager.select_provider(provider_name)
          provider_name = provider.class.provider_name
          attempted_providers << provider_name

          # Record attempt
          @metrics.record_attempt(provider_name)

          start_time = Time.now
          response = yield(provider)
          duration = Time.now - start_time

          # Record success
          @metrics.record_success(provider_name, duration)
          @provider_manager.record_success(provider_name)

          response
        rescue RateLimitError => e
          last_error = e
          @provider_manager.mark_rate_limited(provider_name, reset_at: e.reset_time)
          handle_provider_failure(e, provider_name, :switch)
          retry if should_retry?(retries += 1, max_retries)
          raise
        rescue CircuitOpenError => e
          last_error = e
          handle_provider_failure(e, provider_name, :switch)
          retry if should_retry?(retries += 1, max_retries)
          raise
        rescue TimeoutError, ProviderError => e
          last_error = e
          @provider_manager.record_failure(provider_name)
          handle_provider_failure(e, provider_name, :retry)
          retry if should_retry?(retries += 1, max_retries)
          raise
        rescue NoProvidersAvailableError
          # Re-raise as-is, don't wrap
          raise
        rescue => e
          last_error = e
          @metrics.record_failure(provider_name, e)
          @provider_manager.record_failure(provider_name)

          # Try switching for unknown errors
          handle_provider_failure(e, provider_name, :switch)
          retry if should_retry?(retries += 1, max_retries)
          raise ProviderError.new(e.message, original_error: e)
        end
      end

      def should_retry?(current_retries, max_retries)
        return false unless @config.orchestration_config.retry_config.enabled
        current_retries < max_retries
      end

      def handle_provider_failure(error, provider_name, strategy)
        @metrics.record_failure(provider_name, error)

        case strategy
        when :switch
          if @config.orchestration_config.auto_switch_on_error
            new_provider = begin
              @provider_manager.switch_provider(
                reason: error.class.name,
                context: {error: error.message}
              )
            rescue NoProvidersAvailableError
              nil
            end

            if new_provider
              @metrics.record_switch(provider_name, new_provider.class.provider_name, error.class.name)
            end
          end
        when :retry
          delay = calculate_retry_delay
          sleep(delay) if delay > 0
        end
      end

      def calculate_retry_delay
        retry_config = @config.orchestration_config.retry_config
        return 0 unless retry_config.enabled

        base = retry_config.base_delay
        max = retry_config.max_delay

        # Add jitter if configured
        if retry_config.jitter
          jitter = rand * base * 0.5
          base += jitter
        end

        [base, max].min
      end
    end
  end
end
