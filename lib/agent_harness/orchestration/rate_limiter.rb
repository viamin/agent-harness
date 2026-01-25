# frozen_string_literal: true

module AgentHarness
  module Orchestration
    # Rate limiter for tracking and managing provider rate limits
    #
    # Tracks rate limit events and provides information about when
    # providers are expected to be available again.
    #
    # @example
    #   limiter = RateLimiter.new
    #   limiter.mark_limited(reset_at: Time.now + 3600)
    #   limiter.limited? # => true
    class RateLimiter
      attr_reader :limited_until, :limit_count

      # Create a new rate limiter
      #
      # @param config [RateLimitConfig, nil] configuration object
      # @param default_reset_time [Integer] default seconds until reset
      def initialize(config = nil, default_reset_time: nil)
        if config
          @enabled = config.enabled
          @default_reset_time = config.default_reset_time
        else
          @enabled = true
          @default_reset_time = default_reset_time || 3600
        end

        reset!
      end

      # Check if currently rate limited
      #
      # @return [Boolean] true if rate limited
      def limited?
        return false unless @enabled
        return false unless @limited_until

        if Time.now >= @limited_until
          clear_limit
          false
        else
          true
        end
      end

      # Mark as rate limited
      #
      # @param reset_at [Time, nil] when the limit resets
      # @param reset_in [Integer, nil] seconds until reset
      # @return [void]
      def mark_limited(reset_at: nil, reset_in: nil)
        @mutex.synchronize do
          @limit_count += 1

          @limited_until = if reset_at
            reset_at
          elsif reset_in
            Time.now + reset_in
          else
            Time.now + @default_reset_time
          end

          AgentHarness.logger&.warn(
            "[AgentHarness::RateLimiter] Rate limited until #{@limited_until}"
          )
        end
      end

      # Clear rate limit status
      #
      # @return [void]
      def clear_limit
        @mutex.synchronize do
          @limited_until = nil
        end
      end

      # Get time until limit resets
      #
      # @return [Integer, nil] seconds until reset, or nil if not limited
      def time_until_reset
        return nil unless @limited_until

        remaining = @limited_until - Time.now
        remaining.positive? ? remaining.to_i : 0
      end

      # Reset the rate limiter
      #
      # @return [void]
      def reset!
        @mutex = Mutex.new
        @limited_until = nil
        @limit_count = 0
      end

      # Get rate limiter status
      #
      # @return [Hash] status information
      def status
        {
          limited: limited?,
          limited_until: @limited_until,
          time_until_reset: time_until_reset,
          limit_count: @limit_count,
          enabled: @enabled
        }
      end
    end
  end
end
