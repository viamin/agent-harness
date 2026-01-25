# frozen_string_literal: true

module AgentHarness
  module Orchestration
    # Monitors provider health based on success/failure metrics
    #
    # Tracks success and failure rates to determine provider health status.
    # Uses a sliding window approach to focus on recent performance.
    #
    # @example
    #   monitor = HealthMonitor.new
    #   monitor.record_success(:claude)
    #   monitor.healthy?(:claude) # => true
    class HealthMonitor
      DEFAULT_WINDOW_SIZE = 100
      DEFAULT_HEALTH_THRESHOLD = 0.5

      # Create a new health monitor
      #
      # @param config [HealthCheckConfig, nil] configuration object
      # @param window_size [Integer] number of events to track
      # @param health_threshold [Float] minimum success rate for healthy
      def initialize(config = nil, window_size: nil, health_threshold: nil)
        if config
          @enabled = config.enabled
          @failure_threshold = config.failure_threshold
        else
          @enabled = true
          @failure_threshold = 3
        end

        @window_size = window_size || DEFAULT_WINDOW_SIZE
        @health_threshold = health_threshold || DEFAULT_HEALTH_THRESHOLD
        @provider_metrics = Hash.new { |h, k| h[k] = ProviderHealthMetrics.new(@window_size) }
        @mutex = Mutex.new
      end

      # Record a successful call for a provider
      #
      # @param provider_name [Symbol, String] the provider name
      # @return [void]
      def record_success(provider_name)
        @mutex.synchronize do
          @provider_metrics[provider_name.to_sym].record_success
        end
      end

      # Record a failed call for a provider
      #
      # @param provider_name [Symbol, String] the provider name
      # @return [void]
      def record_failure(provider_name)
        @mutex.synchronize do
          @provider_metrics[provider_name.to_sym].record_failure
        end
      end

      # Check if a provider is healthy
      #
      # @param provider_name [Symbol, String] the provider name
      # @return [Boolean] true if healthy
      def healthy?(provider_name)
        return true unless @enabled

        metrics = @provider_metrics[provider_name.to_sym]
        return true if metrics.total_calls == 0

        metrics.success_rate >= @health_threshold
      end

      # Get health metrics for a provider
      #
      # @param provider_name [Symbol, String] the provider name
      # @return [Hash] health metrics
      def metrics_for(provider_name)
        metrics = @provider_metrics[provider_name.to_sym]
        {
          success_rate: metrics.success_rate,
          total_calls: metrics.total_calls,
          recent_successes: metrics.recent_successes,
          recent_failures: metrics.recent_failures,
          healthy: healthy?(provider_name)
        }
      end

      # Get health status for all tracked providers
      #
      # @return [Hash<Symbol, Hash>] health status by provider
      def all_metrics
        @provider_metrics.transform_values do |metrics|
          {
            success_rate: metrics.success_rate,
            total_calls: metrics.total_calls,
            recent_successes: metrics.recent_successes,
            recent_failures: metrics.recent_failures
          }
        end
      end

      # Reset all health metrics
      #
      # @return [void]
      def reset!
        @mutex.synchronize do
          @provider_metrics.clear
        end
      end

      # Reset metrics for a specific provider
      #
      # @param provider_name [Symbol, String] the provider name
      # @return [void]
      def reset_provider!(provider_name)
        @mutex.synchronize do
          @provider_metrics.delete(provider_name.to_sym)
        end
      end
    end

    # Internal class for tracking per-provider metrics
    class ProviderHealthMetrics
      attr_reader :total_calls, :recent_successes, :recent_failures

      def initialize(window_size)
        @window_size = window_size
        @events = []
        @total_calls = 0
        @recent_successes = 0
        @recent_failures = 0
      end

      def record_success
        add_event(:success)
      end

      def record_failure
        add_event(:failure)
      end

      def success_rate
        return 1.0 if @events.empty?
        @recent_successes.to_f / @events.size
      end

      private

      def add_event(type)
        @total_calls += 1

        # Remove oldest event if at capacity
        if @events.size >= @window_size
          old_event = @events.shift
          if old_event == :success
            @recent_successes -= 1
          else
            @recent_failures -= 1
          end
        end

        # Add new event
        @events << type
        if type == :success
          @recent_successes += 1
        else
          @recent_failures += 1
        end
      end
    end
  end
end
