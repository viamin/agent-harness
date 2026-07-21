# frozen_string_literal: true

RSpec.describe AgentHarness::TokenUsageTracker do
  subject(:tracker) { described_class.new }

  describe "#set_quota" do
    it "configures a quota limit for a provider" do
      tracker.set_quota(provider: :aider, limit: 2_000, reset_at: Time.utc(2026, 8, 1), unit: :tokens)

      status = tracker.estimated_usage(provider: :aider)

      expect(status.available?).to be true
      expect(status.limit).to eq(2_000)
      expect(status.unit).to eq(:tokens)
      expect(status.reset_at).to eq(Time.utc(2026, 8, 1))
    end

    it "accepts string provider names and normalizes them" do
      tracker.set_quota(provider: "aider", limit: 1_000, reset_at: nil, unit: :requests)

      status = tracker.estimated_usage(provider: :aider)
      expect(status.available?).to be true
    end
  end

  describe "#record" do
    it "records token usage events" do
      event = tracker.record(provider: :aider, model: "gpt-4o", input_tokens: 100, output_tokens: 50)

      expect(event.provider).to eq(:aider)
      expect(event.input_tokens).to eq(100)
      expect(event.output_tokens).to eq(50)
      expect(event.total_tokens).to eq(150)
    end

    it "calculates total_tokens when not provided" do
      event = tracker.record(provider: :aider, input_tokens: 100, output_tokens: 50)
      expect(event.total_tokens).to eq(150)
    end

    it "uses provided total_tokens" do
      event = tracker.record(provider: :aider, input_tokens: 100, output_tokens: 50, total_tokens: 200)
      expect(event.total_tokens).to eq(200)
    end

    it "generates a request_id when not provided" do
      event = tracker.record(provider: :aider, input_tokens: 100, output_tokens: 50)
      expect(event.request_id).not_to be_nil
    end

    it "fires registered callbacks" do
      seen = nil
      tracker.on_usage_recorded { |event| seen = event }

      tracker.record(provider: :aider, input_tokens: 100, output_tokens: 50)

      expect(seen).not_to be_nil
      expect(seen.provider).to eq(:aider)
    end
  end

  describe "#estimated_usage" do
    before do
      tracker.set_quota(provider: :aider, limit: 1_000, reset_at: Time.utc(2026, 8, 1), unit: :tokens)
      tracker.record(provider: :aider, input_tokens: 200, output_tokens: 100)
      tracker.record(provider: :aider, input_tokens: 100, output_tokens: 50)
    end

    it "subtracts recorded usage from the configured limit" do
      status = tracker.estimated_usage(provider: :aider)

      expect(status.available?).to be true
      expect(status.remaining).to eq(550) # 1000 - (300 + 150)
      expect(status.limit).to eq(1_000)
    end

    it "returns unavailable when no quota is configured" do
      status = tracker.estimated_usage(provider: :codex)
      expect(status.available?).to be false
    end

    it "respects an explicit since: cutoff" do
      future = Time.now.utc + 3600
      tracker.record(provider: :aider, input_tokens: 10, output_tokens: 5)
      status = tracker.estimated_usage(provider: :aider, since: future)

      # No usage recorded in the future window
      expect(status.remaining).to eq(1_000)
    end

    it "resets usage when callers clear events after a billing reset" do
      tracker.clear!(provider: :aider)

      status = tracker.estimated_usage(provider: :aider)
      expect(status.remaining).to eq(1_000)
    end
  end

  describe "#estimated_usage without pre-seeded events" do
    it "counts every recorded event when no cutoff is given" do
      tracker.set_quota(provider: :aider, limit: 1_000, reset_at: Time.utc(2026, 8, 1), unit: :tokens)
      tracker.record(provider: :aider, input_tokens: 100, output_tokens: 50)

      status = tracker.estimated_usage(provider: :aider)
      expect(status.remaining).to eq(850)
    end
  end

  describe "#usage_total" do
    it "returns total tokens recorded for a provider" do
      tracker.record(provider: :aider, input_tokens: 100, output_tokens: 50)
      tracker.record(provider: :aider, input_tokens: 50, output_tokens: 25)

      expect(tracker.usage_total(:aider)).to eq(225)
    end

    it "isolates usage by provider" do
      tracker.record(provider: :aider, input_tokens: 100, output_tokens: 50)
      tracker.record(provider: :codex, input_tokens: 200, output_tokens: 100)

      expect(tracker.usage_total(:aider)).to eq(150)
      expect(tracker.usage_total(:codex)).to eq(300)
    end

    it "respects the since: cutoff" do
      tracker.record(provider: :aider, input_tokens: 100, output_tokens: 50)
      tracker.record(provider: :aider, input_tokens: 50, output_tokens: 25)

      cutoff = Time.now.utc
      sleep 0.01
      tracker.record(provider: :aider, input_tokens: 10, output_tokens: 5)

      expect(tracker.usage_total(:aider, since: cutoff)).to eq(15)
    end
  end

  describe "#event_count" do
    it "returns total event count when no provider is given" do
      3.times { tracker.record(provider: :aider, input_tokens: 10, output_tokens: 5) }

      expect(tracker.event_count).to eq(3)
    end

    it "filters by provider" do
      2.times { tracker.record(provider: :aider, input_tokens: 10, output_tokens: 5) }
      tracker.record(provider: :codex, input_tokens: 10, output_tokens: 5)

      expect(tracker.event_count(:aider)).to eq(2)
    end
  end

  describe "#clear!" do
    it "drops events for a specific provider" do
      tracker.record(provider: :aider, input_tokens: 100, output_tokens: 50)
      tracker.record(provider: :codex, input_tokens: 50, output_tokens: 25)

      tracker.clear!(provider: :aider)

      expect(tracker.event_count(:aider)).to eq(0)
      expect(tracker.event_count(:codex)).to eq(1)
    end

    it "drops everything when called without a provider" do
      tracker.record(provider: :aider, input_tokens: 100, output_tokens: 50)
      tracker.record(provider: :codex, input_tokens: 50, output_tokens: 25)

      tracker.clear!

      expect(tracker.event_count).to eq(0)
    end
  end

  describe "fallback path integration with QuotaStatus" do
    it "returns a serializable status that can round-trip through to_h/from_h" do
      tracker.set_quota(provider: :aider, limit: 1_000, reset_at: Time.utc(2026, 8, 1), unit: :tokens)
      tracker.record(provider: :aider, input_tokens: 100, output_tokens: 50)

      status = tracker.estimated_usage(provider: :aider)
      restored = AgentHarness::QuotaStatus.from_h(status.to_h)

      expect(restored.available?).to be true
      expect(restored.remaining).to eq(850)
      expect(restored.unit).to eq(:tokens)
    end
  end
end
