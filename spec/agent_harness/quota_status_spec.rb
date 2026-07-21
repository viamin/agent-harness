# frozen_string_literal: true

require "time"

RSpec.describe AgentHarness::QuotaStatus do
  describe ".new" do
    it "builds a populated status with a checked_at timestamp" do
      status = described_class.new(
        available: true,
        remaining: 1_500,
        limit: 2_000,
        reset_at: Time.utc(2026, 8, 1),
        unit: :tokens
      )

      expect(status.available?).to be true
      expect(status.remaining).to eq(1_500)
      expect(status.limit).to eq(2_000)
      expect(status.reset_at).to eq(Time.utc(2026, 8, 1))
      expect(status.unit).to eq(:tokens)
      expect(status.checked_at).to be_a(Time)
    end

    it "freezes the returned instance" do
      status = described_class.new(available: true, remaining: 1)
      expect(status).to be_frozen
    end

    it "rejects non-boolean available values" do
      expect {
        described_class.new(available: "yes")
      }.to raise_error(ArgumentError, /available must be a boolean/)
    end

    it "rejects non-Time reset_at values" do
      expect {
        described_class.new(available: true, reset_at: "tomorrow")
      }.to raise_error(ArgumentError, /reset_at must be a Time/)
    end

    it "rejects non-Symbol unit values" do
      expect {
        described_class.new(available: true, unit: "tokens")
      }.to raise_error(ArgumentError, /unit must be a Symbol/)
    end

    it "leaves checked_at nil when unavailable" do
      status = described_class.new(available: false)
      expect(status.checked_at).to be_nil
    end
  end

  describe ".unavailable" do
    it "returns a sentinel status that is not available" do
      status = described_class.unavailable

      expect(status.available?).to be false
      expect(status.remaining).to be_nil
      expect(status.limit).to be_nil
      expect(status.unit).to be_nil
    end

    it "is frozen" do
      expect(described_class.unavailable).to be_frozen
    end
  end

  describe "#exhausted?" do
    it "returns true when remaining is zero" do
      status = described_class.new(available: true, remaining: 0, limit: 100, unit: :tokens)
      expect(status).to be_exhausted
    end

    it "returns true when remaining is negative" do
      status = described_class.new(available: true, remaining: -5, limit: 100, unit: :tokens)
      expect(status).to be_exhausted
    end

    it "returns false when remaining is positive" do
      status = described_class.new(available: true, remaining: 5, limit: 100, unit: :tokens)
      expect(status).not_to be_exhausted
    end

    it "returns false when unavailable" do
      expect(described_class.unavailable).not_to be_exhausted
    end

    it "returns false when remaining is nil" do
      status = described_class.new(available: true, limit: 100, unit: :tokens)
      expect(status).not_to be_exhausted
    end
  end

  describe "#unit_label" do
    it "returns the unit name as a string" do
      expect(described_class.new(available: true, unit: :credits).unit_label).to eq("credits")
    end

    it "returns 'unknown' when unit is nil" do
      expect(described_class.unavailable.unit_label).to eq("unknown")
    end
  end

  describe "#to_h round-trip via .from_h" do
    it "preserves all fields across serialization" do
      original = described_class.new(
        available: true,
        remaining: 1_500,
        limit: 2_000,
        reset_at: Time.utc(2026, 8, 1, 12, 0, 0),
        unit: :tokens,
        checked_at: Time.utc(2026, 7, 21, 10, 30, 0)
      )

      restored = described_class.from_h(original.to_h)

      expect(restored.available?).to be true
      expect(restored.remaining).to eq(1_500)
      expect(restored.limit).to eq(2_000)
      expect(restored.reset_at).to eq(Time.utc(2026, 8, 1, 12, 0, 0))
      expect(restored.unit).to eq(:tokens)
      expect(restored.checked_at).to eq(Time.utc(2026, 7, 21, 10, 30, 0))
    end

    it "serializes reset_at and checked_at as ISO8601 strings" do
      hash = described_class.new(
        available: true,
        reset_at: Time.utc(2026, 8, 1),
        checked_at: Time.utc(2026, 7, 21)
      ).to_h

      expect(hash[:reset_at]).to eq("2026-08-01T00:00:00Z")
      expect(hash[:checked_at]).to eq("2026-07-21T00:00:00Z")
    end

    it "round-trips an unavailable status" do
      restored = described_class.from_h(described_class.unavailable.to_h)
      expect(restored.available?).to be false
    end

    it "tolerates nil input" do
      expect(described_class.from_h(nil)).to eq(described_class.unavailable)
    end

    it "tolerates unparseable timestamps by clearing them" do
      restored = described_class.from_h(available: true, reset_at: "not a time")
      expect(restored.reset_at).to be_nil
      expect(restored.available?).to be true
    end

    it "accepts string keys from JSON deserialization" do
      hash = {
        "available" => true,
        "remaining" => 100,
        "limit" => 200,
        "unit" => "requests"
      }

      restored = described_class.from_h(hash)
      expect(restored.available?).to be true
      expect(restored.remaining).to eq(100)
      expect(restored.unit).to eq(:requests)
    end
  end
end
