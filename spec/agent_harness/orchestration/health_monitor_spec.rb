# frozen_string_literal: true

RSpec.describe AgentHarness::Orchestration::HealthMonitor do
  subject(:monitor) { described_class.new(health_threshold: 0.5) }

  describe "#record_success" do
    it "increases success count" do
      monitor.record_success(:claude)
      metrics = monitor.metrics_for(:claude)
      expect(metrics[:recent_successes]).to eq(1)
    end
  end

  describe "#record_failure" do
    it "increases failure count" do
      monitor.record_failure(:claude)
      metrics = monitor.metrics_for(:claude)
      expect(metrics[:recent_failures]).to eq(1)
    end
  end

  describe "#healthy?" do
    it "returns true when no calls have been made" do
      expect(monitor.healthy?(:claude)).to be true
    end

    it "returns true when success rate is above threshold" do
      3.times { monitor.record_success(:claude) }
      monitor.record_failure(:claude)

      expect(monitor.healthy?(:claude)).to be true
    end

    it "returns false when success rate is below threshold" do
      monitor.record_success(:claude)
      3.times { monitor.record_failure(:claude) }

      expect(monitor.healthy?(:claude)).to be false
    end
  end

  describe "#metrics_for" do
    before do
      3.times { monitor.record_success(:claude) }
      monitor.record_failure(:claude)
    end

    it "returns success rate" do
      metrics = monitor.metrics_for(:claude)
      expect(metrics[:success_rate]).to eq(0.75)
    end

    it "returns total calls" do
      metrics = monitor.metrics_for(:claude)
      expect(metrics[:total_calls]).to eq(4)
    end

    it "returns healthy status" do
      metrics = monitor.metrics_for(:claude)
      expect(metrics[:healthy]).to be true
    end
  end

  describe "#all_metrics" do
    before do
      monitor.record_success(:claude)
      monitor.record_success(:cursor)
    end

    it "returns metrics for all tracked providers" do
      all = monitor.all_metrics
      expect(all.keys).to include(:claude, :cursor)
    end
  end

  describe "#reset!" do
    it "clears all metrics" do
      monitor.record_success(:claude)
      monitor.reset!

      expect(monitor.all_metrics).to be_empty
    end
  end

  describe "#reset_provider!" do
    it "clears metrics for specific provider" do
      monitor.record_success(:claude)
      monitor.record_success(:cursor)

      monitor.reset_provider!(:claude)

      expect(monitor.all_metrics.keys).to eq([:cursor])
    end
  end
end
