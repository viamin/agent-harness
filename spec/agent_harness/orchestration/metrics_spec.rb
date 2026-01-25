# frozen_string_literal: true

RSpec.describe AgentHarness::Orchestration::Metrics do
  subject(:metrics) { described_class.new }

  describe "#record_attempt" do
    it "increments attempt count for provider" do
      metrics.record_attempt(:claude)
      metrics.record_attempt(:claude)

      summary = metrics.summary
      expect(summary[:total_attempts]).to eq(2)
      expect(summary[:by_provider][:claude][:attempts]).to eq(2)
    end
  end

  describe "#record_success" do
    it "increments success count and tracks duration" do
      metrics.record_attempt(:claude)
      metrics.record_success(:claude, 1.5)

      summary = metrics.summary
      expect(summary[:total_successes]).to eq(1)
      expect(summary[:by_provider][:claude][:successes]).to eq(1)
      expect(summary[:by_provider][:claude][:average_duration]).to eq(1.5)
    end
  end

  describe "#record_failure" do
    it "increments failure count and tracks error" do
      metrics.record_attempt(:claude)
      error = StandardError.new("test error")
      metrics.record_failure(:claude, error)

      summary = metrics.summary
      expect(summary[:total_failures]).to eq(1)
      expect(summary[:by_provider][:claude][:failures]).to eq(1)
      expect(summary[:error_counts]["StandardError"]).to eq(1)
    end
  end

  describe "#record_switch" do
    it "tracks provider switches" do
      metrics.record_switch(:claude, :cursor, "rate_limited")

      summary = metrics.summary
      expect(summary[:total_switches]).to eq(1)
      expect(summary[:recent_switches].first[:from]).to eq(:claude)
      expect(summary[:recent_switches].first[:to]).to eq(:cursor)
      expect(summary[:recent_switches].first[:reason]).to eq("rate_limited")
    end
  end

  describe "#summary" do
    before do
      2.times do
        metrics.record_attempt(:claude)
        metrics.record_success(:claude, 1.0)
      end

      metrics.record_attempt(:claude)
      metrics.record_failure(:claude, StandardError.new("error"))
    end

    it "calculates success rate" do
      summary = metrics.summary
      expect(summary[:success_rate]).to be_within(0.01).of(0.67)
    end

    it "includes last success/failure times" do
      summary = metrics.summary
      expect(summary[:last_success_time]).not_to be_nil
      expect(summary[:last_failure_time]).not_to be_nil
    end
  end

  describe "#provider_metrics" do
    before do
      metrics.record_attempt(:claude)
      metrics.record_success(:claude, 2.0)
      metrics.record_attempt(:claude)
      metrics.record_failure(:claude, StandardError.new("error"))
    end

    it "returns metrics for specific provider" do
      pm = metrics.provider_metrics(:claude)

      expect(pm[:attempts]).to eq(2)
      expect(pm[:successes]).to eq(1)
      expect(pm[:failures]).to eq(1)
      expect(pm[:success_rate]).to eq(0.5)
      expect(pm[:average_duration]).to eq(2.0)
    end
  end

  describe "#reset!" do
    it "clears all metrics" do
      metrics.record_attempt(:claude)
      metrics.record_success(:claude, 1.0)
      metrics.reset!

      summary = metrics.summary
      expect(summary[:total_attempts]).to eq(0)
      expect(summary[:total_successes]).to eq(0)
    end
  end
end
