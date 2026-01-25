# frozen_string_literal: true

RSpec.describe AgentHarness::Orchestration::RateLimiter do
  subject(:limiter) { described_class.new(default_reset_time: 60) }

  describe "#initialize" do
    it "starts not limited" do
      expect(limiter.limited?).to be false
    end

    it "starts with zero limit count" do
      expect(limiter.limit_count).to eq(0)
    end
  end

  describe "#mark_limited" do
    it "marks as limited" do
      limiter.mark_limited
      expect(limiter.limited?).to be true
    end

    it "increments limit count" do
      limiter.mark_limited
      limiter.mark_limited
      expect(limiter.limit_count).to eq(2)
    end

    it "accepts reset_at time" do
      reset_time = Time.now + 3600
      limiter.mark_limited(reset_at: reset_time)
      expect(limiter.limited_until).to eq(reset_time)
    end

    it "accepts reset_in seconds" do
      limiter.mark_limited(reset_in: 120)
      expect(limiter.limited_until).to be_within(1).of(Time.now + 120)
    end

    it "uses default reset time when no time provided" do
      limiter.mark_limited
      expect(limiter.limited_until).to be_within(1).of(Time.now + 60)
    end
  end

  describe "#limited?" do
    it "returns false after reset time passes" do
      limiter.mark_limited(reset_in: 0)
      sleep 0.01
      expect(limiter.limited?).to be false
    end
  end

  describe "#clear_limit" do
    it "clears the limit" do
      limiter.mark_limited
      limiter.clear_limit
      expect(limiter.limited?).to be false
    end
  end

  describe "#time_until_reset" do
    it "returns nil when not limited" do
      expect(limiter.time_until_reset).to be_nil
    end

    it "returns remaining time when limited" do
      limiter.mark_limited(reset_in: 100)
      expect(limiter.time_until_reset).to be_within(2).of(100)
    end
  end

  describe "#reset!" do
    it "resets all state" do
      limiter.mark_limited
      limiter.reset!

      expect(limiter.limited?).to be false
      expect(limiter.limit_count).to eq(0)
    end
  end

  describe "#status" do
    it "returns status hash" do
      limiter.mark_limited

      status = limiter.status
      expect(status[:limited]).to be true
      expect(status[:limit_count]).to eq(1)
      expect(status[:enabled]).to be true
    end
  end
end
