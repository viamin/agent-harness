# frozen_string_literal: true

RSpec.describe AgentHarness::TokenTracker do
  subject(:tracker) { described_class.new }

  describe "#record" do
    it "records token usage" do
      event = tracker.record(
        provider: :claude,
        model: "claude-3-5-sonnet",
        input_tokens: 100,
        output_tokens: 50
      )

      expect(event.provider).to eq(:claude)
      expect(event.model).to eq("claude-3-5-sonnet")
      expect(event.input_tokens).to eq(100)
      expect(event.output_tokens).to eq(50)
      expect(event.total_tokens).to eq(150)
    end

    it "calculates total_tokens if not provided" do
      event = tracker.record(provider: :claude, input_tokens: 100, output_tokens: 50)
      expect(event.total_tokens).to eq(150)
    end

    it "uses provided total_tokens" do
      event = tracker.record(provider: :claude, input_tokens: 100, output_tokens: 50, total_tokens: 200)
      expect(event.total_tokens).to eq(200)
    end

    it "generates request_id if not provided" do
      event = tracker.record(provider: :claude, input_tokens: 100, output_tokens: 50)
      expect(event.request_id).not_to be_nil
    end

    it "uses provided request_id" do
      event = tracker.record(provider: :claude, input_tokens: 100, output_tokens: 50, request_id: "custom-id")
      expect(event.request_id).to eq("custom-id")
    end
  end

  describe "#summary" do
    before do
      tracker.record(provider: :claude, model: "sonnet", input_tokens: 100, output_tokens: 50)
      tracker.record(provider: :claude, model: "sonnet", input_tokens: 200, output_tokens: 100)
      tracker.record(provider: :cursor, model: "gpt-4", input_tokens: 50, output_tokens: 25)
    end

    it "returns total requests" do
      expect(tracker.summary[:total_requests]).to eq(3)
    end

    it "returns total tokens" do
      expect(tracker.summary[:total_input_tokens]).to eq(350)
      expect(tracker.summary[:total_output_tokens]).to eq(175)
      expect(tracker.summary[:total_tokens]).to eq(525)
    end

    it "groups by provider" do
      by_provider = tracker.summary[:by_provider]
      expect(by_provider[:claude][:requests]).to eq(2)
      expect(by_provider[:cursor][:requests]).to eq(1)
    end

    it "groups by model" do
      by_model = tracker.summary[:by_model]
      expect(by_model["claude:sonnet"][:requests]).to eq(2)
      expect(by_model["cursor:gpt-4"][:requests]).to eq(1)
    end

    it "filters by provider" do
      summary = tracker.summary(provider: :claude)
      expect(summary[:total_requests]).to eq(2)
    end
  end

  describe "#on_tokens_used" do
    it "calls callback when tokens are recorded" do
      callback_event = nil
      tracker.on_tokens_used { |event| callback_event = event }

      tracker.record(provider: :claude, input_tokens: 100, output_tokens: 50)

      expect(callback_event).not_to be_nil
      expect(callback_event.provider).to eq(:claude)
    end
  end

  describe "#clear!" do
    it "clears all recorded events" do
      tracker.record(provider: :claude, input_tokens: 100, output_tokens: 50)
      tracker.clear!

      expect(tracker.event_count).to eq(0)
    end
  end

  describe "#total_tokens" do
    it "returns total tokens across all events" do
      tracker.record(provider: :claude, input_tokens: 100, output_tokens: 50)
      tracker.record(provider: :cursor, input_tokens: 50, output_tokens: 25)

      expect(tracker.total_tokens).to eq(225)
    end
  end

  describe "#recent_events" do
    it "returns recent events" do
      5.times { |i| tracker.record(provider: :claude, input_tokens: i * 10, output_tokens: i * 5) }

      events = tracker.recent_events(limit: 3)
      expect(events.size).to eq(3)
    end
  end
end
