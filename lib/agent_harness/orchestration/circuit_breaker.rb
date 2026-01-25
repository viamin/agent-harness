# frozen_string_literal: true

module AgentHarness
  module Orchestration
    # Circuit breaker for provider fault tolerance
    #
    # Implements the circuit breaker pattern to prevent cascading failures.
    # The circuit has three states:
    # - :closed - Normal operation, requests pass through
    # - :open - Failures exceeded threshold, requests are blocked
    # - :half_open - After timeout, limited requests allowed to test recovery
    #
    # @example
    #   breaker = CircuitBreaker.new(failure_threshold: 5, timeout: 300)
    #   breaker.record_failure
    #   breaker.open? # => false (still below threshold)
    class CircuitBreaker
      STATES = [:closed, :open, :half_open].freeze

      attr_reader :state, :failure_count, :success_count

      # Create a new circuit breaker
      #
      # @param config [CircuitBreakerConfig, nil] configuration object
      # @param failure_threshold [Integer] failures before opening
      # @param timeout [Integer] seconds before half-open transition
      # @param half_open_max_calls [Integer] successful calls to close
      def initialize(config = nil, failure_threshold: nil, timeout: nil, half_open_max_calls: nil)
        if config
          @enabled = config.enabled
          @failure_threshold = config.failure_threshold
          @timeout = config.timeout
          @half_open_max_calls = config.half_open_max_calls
        else
          @enabled = true
          @failure_threshold = failure_threshold || 5
          @timeout = timeout || 300
          @half_open_max_calls = half_open_max_calls || 3
        end

        reset!
      end

      # Check if circuit is open (blocking requests)
      #
      # @return [Boolean] true if open
      def open?
        return false unless @enabled

        if @state == :open && timeout_elapsed?
          transition_to(:half_open)
        end

        @state == :open
      end

      # Check if circuit is closed (allowing requests)
      #
      # @return [Boolean] true if closed
      def closed?
        @state == :closed
      end

      # Check if circuit is half-open (testing recovery)
      #
      # @return [Boolean] true if half-open
      def half_open?
        @state == :half_open
      end

      # Record a successful call
      #
      # @return [void]
      def record_success
        @mutex.synchronize do
          @success_count += 1

          if @state == :half_open && @success_count >= @half_open_max_calls
            transition_to(:closed)
          end
        end
      end

      # Record a failed call
      #
      # @return [void]
      def record_failure
        @mutex.synchronize do
          @failure_count += 1

          if @failure_count >= @failure_threshold
            transition_to(:open)
          end
        end
      end

      # Reset the circuit breaker to initial state
      #
      # @return [void]
      def reset!
        @mutex = Mutex.new
        @state = :closed
        @failure_count = 0
        @success_count = 0
        @opened_at = nil
      end

      # Get time until circuit attempts recovery
      #
      # @return [Integer, nil] seconds until half-open, or nil if not open
      def time_until_recovery
        return nil unless @state == :open && @opened_at

        remaining = @timeout - (Time.now - @opened_at)
        remaining.positive? ? remaining.to_i : 0
      end

      # Get circuit status
      #
      # @return [Hash] status information
      def status
        {
          state: @state,
          failure_count: @failure_count,
          success_count: @success_count,
          failure_threshold: @failure_threshold,
          timeout: @timeout,
          time_until_recovery: time_until_recovery,
          enabled: @enabled
        }
      end

      private

      def transition_to(new_state)
        old_state = @state
        @state = new_state

        case new_state
        when :open
          @opened_at = Time.now
          @failure_count = 0
          emit_event(:circuit_open, old_state: old_state)
        when :half_open
          @success_count = 0
          emit_event(:circuit_half_open, old_state: old_state)
        when :closed
          @failure_count = 0
          @success_count = 0
          @opened_at = nil
          emit_event(:circuit_close, old_state: old_state)
        end

        AgentHarness.logger&.info(
          "[AgentHarness::CircuitBreaker] State transition: #{old_state} -> #{new_state}"
        )
      end

      def timeout_elapsed?
        return true unless @opened_at
        Time.now - @opened_at >= @timeout
      end

      def emit_event(event, **data)
        AgentHarness.configuration.callbacks.emit(event, data.merge(circuit_breaker: self))
      end
    end
  end
end
