# frozen_string_literal: true

require "securerandom"

module AgentHarness
  # Fallback quota tracker for providers that do not expose a public quota API.
  #
  # When {Providers::Base#check_quota} returns a {QuotaStatus} with
  # +available: false+ (the default for providers like Aider or Kilocode that
  # route through opaque upstreams), the orchestration layer falls back to
  # {TokenUsageTracker}. The tracker records the same per-request token usage
  # surfaced by {Providers::Base#track_tokens}, then derives an estimated
  # {QuotaStatus} by subtracting usage from a caller-configured billing
  # period limit.
  #
  # The tracker holds no connection to the provider and never makes an HTTP
  # request; it is purely an in-memory aggregate that mirrors what
  # {TokenTracker} records but with the additional concept of a billing-period
  # limit per provider.
  #
  # @example Configure a daily token limit and record usage
  #   tracker = AgentHarness::TokenUsageTracker.new
  #   tracker.set_quota(provider: :aider, limit: 2_000_000, reset_at: Time.utc(2026, 8, 1), unit: :tokens)
  #   tracker.record(provider: :aider, model: "gpt-4o", input_tokens: 500, output_tokens: 100)
  #   tracker.estimated_usage(provider: :aider)
  #   # => #<AgentHarness::QuotaStatus available=true remaining=1999400 limit=2000000 unit=:tokens>
  class TokenUsageTracker
    UsageEvent = Struct.new(:provider, :model, :input_tokens, :output_tokens, :total_tokens, :timestamp, :request_id)

    QuotaConfig = Struct.new(:limit, :reset_at, :unit) do
      def configured?
        !limit.nil?
      end
    end

    def initialize
      @events = []
      @quota_configs = Hash.new { |hash, key| hash[key] = QuotaConfig.new }
      @callbacks = []
      @mutex = Mutex.new
    end

    # Configure the billing-period quota for a provider.
    #
    # The orchestration layer uses this to seed tracker state from Paid's
    # provider config before any usage is recorded.
    #
    # @param provider [Symbol, String] provider name
    # @param limit [Integer, Float, nil] total quota for the period; pass nil
    #   to mark the provider as untracked
    # @param reset_at [Time, nil] when the period resets
    # @param unit [Symbol] quota unit (:tokens, :requests, :credits, :cost_cents)
    # @return [void]
    def set_quota(provider:, limit:, reset_at:, unit:)
      provider_key = normalize_provider(provider)
      @mutex.synchronize do
        @quota_configs[provider_key] = QuotaConfig.new(limit: limit, reset_at: reset_at, unit: normalize_unit(unit))
      end
    end

    # Record token usage for a provider.
    #
    # Mirrors the {TokenTracker#record} signature so the tracker can be wired
    # into the same +track_tokens+ hook on {Providers::Base}.
    #
    # @param provider [Symbol, String] provider name
    # @param model [String, nil] model identifier
    # @param input_tokens [Integer] input tokens used
    # @param output_tokens [Integer] output tokens used
    # @param total_tokens [Integer, nil] total tokens (calculated if nil)
    # @param request_id [String, nil] unique request ID (generated if nil)
    # @return [UsageEvent]
    def record(provider:, model: nil, input_tokens: 0, output_tokens: 0, total_tokens: nil, request_id: nil)
      total = total_tokens || (input_tokens + output_tokens)
      event = UsageEvent.new(
        provider: normalize_provider(provider),
        model: model,
        input_tokens: input_tokens.to_i,
        output_tokens: output_tokens.to_i,
        total_tokens: total.to_i,
        timestamp: Time.now.utc,
        request_id: request_id || SecureRandom.uuid
      )

      @mutex.synchronize { @events << event }
      notify_callbacks(event)
      event
    end

    # Return an estimated {QuotaStatus} for the given provider.
    #
    # Returns a {QuotaStatus} with +available: true+ as long as the caller has
    # configured a quota for the provider (via {#set_quota}). The +remaining+
    # value is the configured limit minus recorded usage since +since:+ (or
    # every recorded event when +since:+ is omitted — callers are responsible
    # for clearing events with {#clear!} when a billing period rolls over).
    #
    # @param provider [Symbol, String] provider name
    # @param since [Time, nil] cutoff for usage events
    # @return [AgentHarness::QuotaStatus]
    def estimated_usage(provider:, since: nil)
      provider_key = normalize_provider(provider)
      config = @mutex.synchronize { @quota_configs[provider_key] }
      return QuotaStatus.unavailable unless config&.configured?

      used = usage_total(provider_key, since:)
      remaining = config.limit.nil? ? nil : (config.limit - used)

      QuotaStatus.new(
        available: true,
        remaining: remaining,
        limit: config.limit,
        reset_at: config.reset_at,
        unit: config.unit
      )
    end

    # Register a callback invoked whenever usage is recorded.
    #
    # @yield [UsageEvent]
    # @return [void]
    def on_usage_recorded(&block)
      @callbacks << block
    end

    # Drop all recorded events for a provider. Useful when a billing period
    # rolls over or in tests.
    #
    # @param provider [Symbol, String, nil] provider name; clears everything when nil
    # @return [void]
    def clear!(provider: nil)
      @mutex.synchronize do
        if provider.nil?
          @events.clear
        else
          provider_key = normalize_provider(provider)
          @events.reject! { |event| event.provider == provider_key }
        end
      end
    end

    # Total recorded token usage for a provider since an optional cutoff.
    #
    # @param provider [Symbol, String] provider name
    # @param since [Time, nil] cutoff
    # @return [Integer]
    def usage_total(provider, since: nil)
      provider_key = normalize_provider(provider)
      events = filtered_events(provider_key, since:)
      events.sum(&:total_tokens)
    end

    # Number of usage events recorded for a provider since an optional cutoff.
    #
    # @param provider [Symbol, String] provider name
    # @param since [Time, nil] cutoff
    # @return [Integer]
    def event_count(provider = nil, since: nil)
      @mutex.synchronize do
        events = @events.dup
        events = events.select { |event| event.provider == normalize_provider(provider) } if provider
        events = events.select { |event| since.nil? || event.timestamp >= since }
        events.size
      end
    end

    private

    def normalize_provider(provider)
      provider.to_sym
    end

    def normalize_unit(unit)
      return nil if unit.nil?

      unit.to_sym
    end

    def filtered_events(provider_key, since:)
      @mutex.synchronize do
        events = @events.select { |event| event.provider == provider_key }
        return events if since.nil?

        events.select { |event| event.timestamp >= since }
      end
    end

    def notify_callbacks(event)
      @callbacks.each do |callback|
        callback.call(event)
      rescue => e
        AgentHarness.logger&.error("[AgentHarness::TokenUsageTracker] Callback error: #{e.message}")
      end
    end
  end
end
