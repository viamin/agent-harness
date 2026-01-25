# frozen_string_literal: true

require "securerandom"

module AgentHarness
  # Tracks token usage across provider interactions
  #
  # Provides in-memory tracking of token usage with support for callbacks
  # when tokens are used. Consumers can register callbacks to persist
  # usage data externally.
  #
  # @example Basic usage
  #   tracker = AgentHarness::TokenTracker.new
  #   tracker.record(provider: :claude, input_tokens: 100, output_tokens: 50)
  #   puts tracker.summary
  #
  # @example With callback
  #   tracker.on_tokens_used do |event|
  #     MyDatabase.save_usage(event)
  #   end
  class TokenTracker
    # Token usage event structure
    TokenEvent = Struct.new(
      :provider, :model, :input_tokens, :output_tokens, :total_tokens,
      :timestamp, :request_id,
      keyword_init: true
    )

    def initialize
      @events = []
      @callbacks = []
      @mutex = Mutex.new
    end

    # Record token usage
    #
    # @param provider [Symbol, String] the provider name
    # @param model [String, nil] the model used
    # @param input_tokens [Integer] input tokens used
    # @param output_tokens [Integer] output tokens used
    # @param total_tokens [Integer, nil] total tokens (calculated if nil)
    # @param request_id [String, nil] unique request ID (generated if nil)
    # @return [TokenEvent] the recorded event
    def record(provider:, model: nil, input_tokens: 0, output_tokens: 0, total_tokens: nil, request_id: nil)
      total = total_tokens || (input_tokens + output_tokens)

      event = TokenEvent.new(
        provider: provider.to_sym,
        model: model,
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        total_tokens: total,
        timestamp: Time.now,
        request_id: request_id || SecureRandom.uuid
      )

      @mutex.synchronize do
        @events << event
      end

      # Notify callbacks
      notify_callbacks(event)

      event
    end

    # Get usage summary
    #
    # @param since [Time, nil] only include events after this time
    # @param provider [Symbol, String, nil] filter by provider
    # @return [Hash] usage summary
    def summary(since: nil, provider: nil)
      events = filtered_events(since: since, provider: provider)

      {
        total_requests: events.size,
        total_input_tokens: events.sum(&:input_tokens),
        total_output_tokens: events.sum(&:output_tokens),
        total_tokens: events.sum(&:total_tokens),
        by_provider: group_by_provider(events),
        by_model: group_by_model(events)
      }
    end

    # Get recent events
    #
    # @param limit [Integer] maximum number of events to return
    # @return [Array<TokenEvent>] recent events
    def recent_events(limit: 100)
      @mutex.synchronize do
        @events.last(limit)
      end
    end

    # Register callback for token events
    #
    # @yield [TokenEvent] called when tokens are recorded
    # @return [void]
    def on_tokens_used(&block)
      @callbacks << block
    end

    # Clear all recorded events
    #
    # @return [void]
    def clear!
      @mutex.synchronize do
        @events.clear
      end
    end

    # Get total token count
    #
    # @param since [Time, nil] only include events after this time
    # @return [Integer] total tokens used
    def total_tokens(since: nil)
      filtered_events(since: since).sum(&:total_tokens)
    end

    # Get event count
    #
    # @return [Integer] number of recorded events
    def event_count
      @mutex.synchronize do
        @events.size
      end
    end

    private

    def filtered_events(since: nil, provider: nil)
      @mutex.synchronize do
        events = @events.dup
        events = events.select { |e| e.timestamp >= since } if since
        events = events.select { |e| e.provider.to_s == provider.to_s } if provider
        events
      end
    end

    def group_by_provider(events)
      events.group_by(&:provider).transform_values do |provider_events|
        {
          requests: provider_events.size,
          input_tokens: provider_events.sum(&:input_tokens),
          output_tokens: provider_events.sum(&:output_tokens),
          total_tokens: provider_events.sum(&:total_tokens)
        }
      end
    end

    def group_by_model(events)
      events.group_by { |e| "#{e.provider}:#{e.model}" }.transform_values do |model_events|
        {
          requests: model_events.size,
          input_tokens: model_events.sum(&:input_tokens),
          output_tokens: model_events.sum(&:output_tokens),
          total_tokens: model_events.sum(&:total_tokens)
        }
      end
    end

    def notify_callbacks(event)
      @callbacks.each do |callback|
        callback.call(event)
      rescue => e
        AgentHarness.logger&.error("[AgentHarness::TokenTracker] Callback error: #{e.message}")
      end
    end
  end
end
