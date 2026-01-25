# frozen_string_literal: true

module AgentHarness
  module Orchestration
    # Collects and aggregates orchestration metrics
    #
    # Tracks attempts, successes, failures, and timing information
    # for provider orchestration.
    class Metrics
      def initialize
        @mutex = Mutex.new
        reset!
      end

      # Record an attempt for a provider
      #
      # @param provider_name [Symbol, String] the provider name
      # @return [void]
      def record_attempt(provider_name)
        @mutex.synchronize do
          provider = provider_name.to_sym
          @attempts[provider] += 1
          @total_attempts += 1
        end
      end

      # Record a success for a provider
      #
      # @param provider_name [Symbol, String] the provider name
      # @param duration [Float] request duration in seconds
      # @return [void]
      def record_success(provider_name, duration)
        @mutex.synchronize do
          provider = provider_name.to_sym
          @successes[provider] += 1
          @total_successes += 1
          @durations[provider] << duration
          @last_success_time = Time.now
        end
      end

      # Record a failure for a provider
      #
      # @param provider_name [Symbol, String] the provider name
      # @param error [Exception] the error that occurred
      # @return [void]
      def record_failure(provider_name, error)
        @mutex.synchronize do
          provider = provider_name.to_sym
          @failures[provider] += 1
          @total_failures += 1
          @error_counts[error.class.name] += 1
          @last_failure_time = Time.now
        end
      end

      # Record a provider switch
      #
      # @param from_provider [Symbol, String] the original provider
      # @param to_provider [Symbol, String] the new provider
      # @param reason [String] reason for switch
      # @return [void]
      def record_switch(from_provider, to_provider, reason)
        @mutex.synchronize do
          @switches << {
            from: from_provider.to_sym,
            to: to_provider.to_sym,
            reason: reason,
            timestamp: Time.now
          }
          @total_switches += 1
        end
      end

      # Get metrics summary
      #
      # @return [Hash] metrics summary
      def summary
        @mutex.synchronize do
          {
            total_attempts: @total_attempts,
            total_successes: @total_successes,
            total_failures: @total_failures,
            total_switches: @total_switches,
            success_rate: success_rate,
            by_provider: provider_summary,
            error_counts: @error_counts.dup,
            last_success_time: @last_success_time,
            last_failure_time: @last_failure_time,
            recent_switches: @switches.last(10)
          }
        end
      end

      # Get metrics for a specific provider
      #
      # @param provider_name [Symbol, String] the provider name
      # @return [Hash] provider metrics
      def provider_metrics(provider_name)
        provider = provider_name.to_sym
        @mutex.synchronize do
          {
            attempts: @attempts[provider],
            successes: @successes[provider],
            failures: @failures[provider],
            success_rate: provider_success_rate(provider),
            average_duration: average_duration(provider)
          }
        end
      end

      # Reset all metrics
      #
      # @return [void]
      def reset!
        @mutex.synchronize do
          @attempts = Hash.new(0)
          @successes = Hash.new(0)
          @failures = Hash.new(0)
          @durations = Hash.new { |h, k| h[k] = [] }
          @error_counts = Hash.new(0)
          @switches = []

          @total_attempts = 0
          @total_successes = 0
          @total_failures = 0
          @total_switches = 0

          @last_success_time = nil
          @last_failure_time = nil
        end
      end

      private

      def success_rate
        return 1.0 if @total_attempts == 0
        @total_successes.to_f / @total_attempts
      end

      def provider_success_rate(provider)
        attempts = @attempts[provider]
        return 1.0 if attempts == 0
        @successes[provider].to_f / attempts
      end

      def average_duration(provider)
        durations = @durations[provider]
        return 0.0 if durations.empty?
        durations.sum / durations.size
      end

      def provider_summary
        providers = (@attempts.keys + @successes.keys + @failures.keys).uniq
        providers.to_h do |provider|
          [provider, {
            attempts: @attempts[provider],
            successes: @successes[provider],
            failures: @failures[provider],
            success_rate: provider_success_rate(provider),
            average_duration: average_duration(provider)
          }]
        end
      end
    end
  end
end
