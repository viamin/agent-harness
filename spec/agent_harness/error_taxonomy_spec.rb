# frozen_string_literal: true

RSpec.describe AgentHarness::ErrorTaxonomy do
  describe ".classify" do
    let(:patterns) do
      {
        rate_limited: [/custom_rate_limit/i],
        auth_expired: [/custom_auth_error/i]
      }
    end

    it "uses provider-specific patterns first" do
      error = StandardError.new("custom_rate_limit error occurred")
      expect(described_class.classify(error, patterns)).to eq(:rate_limited)
    end

    it "falls back to generic patterns" do
      error = StandardError.new("rate limit exceeded")
      expect(described_class.classify(error)).to eq(:rate_limited)
    end
  end

  describe ".classify_message" do
    it "classifies rate limit errors" do
      expect(described_class.classify_message("rate limit exceeded")).to eq(:rate_limited)
      expect(described_class.classify_message("too many requests")).to eq(:rate_limited)
      expect(described_class.classify_message("HTTP 429")).to eq(:rate_limited)
    end

    it "classifies quota errors" do
      expect(described_class.classify_message("quota exceeded")).to eq(:quota_exceeded)
      expect(described_class.classify_message("usage limit reached")).to eq(:quota_exceeded)
      expect(described_class.classify_message("billing issue")).to eq(:quota_exceeded)
    end

    it "classifies auth errors" do
      expect(described_class.classify_message("unauthorized access")).to eq(:auth_expired)
      expect(described_class.classify_message("invalid api key")).to eq(:auth_expired)
      expect(described_class.classify_message("HTTP 401")).to eq(:auth_expired)
      expect(described_class.classify_message("HTTP 403")).to eq(:auth_expired)
    end

    it "classifies timeout errors" do
      expect(described_class.classify_message("connection timed out")).to eq(:timeout)
    end

    it "classifies transient errors" do
      expect(described_class.classify_message("temporary error")).to eq(:transient)
      expect(described_class.classify_message("HTTP 503")).to eq(:transient)
      expect(described_class.classify_message("please retry")).to eq(:transient)
    end

    it "classifies permanent errors" do
      expect(described_class.classify_message("invalid request")).to eq(:permanent)
      expect(described_class.classify_message("bad request 400")).to eq(:permanent)
      expect(described_class.classify_message("malformed input")).to eq(:permanent)
    end

    it "returns unknown for unclassified errors" do
      expect(described_class.classify_message("some random error")).to eq(:unknown)
    end
  end

  describe ".action_for" do
    it "returns correct action for each category" do
      expect(described_class.action_for(:rate_limited)).to eq(:switch_provider)
      expect(described_class.action_for(:auth_expired)).to eq(:switch_provider)
      expect(described_class.action_for(:transient)).to eq(:retry_with_backoff)
      expect(described_class.action_for(:permanent)).to eq(:escalate)
    end

    it "returns escalate for unknown categories" do
      expect(described_class.action_for(:nonexistent)).to eq(:escalate)
    end
  end

  describe ".retryable?" do
    it "returns true for retryable categories" do
      expect(described_class.retryable?(:transient)).to be true
      expect(described_class.retryable?(:timeout)).to be true
      expect(described_class.retryable?(:unknown)).to be true
    end

    it "returns false for non-retryable categories" do
      expect(described_class.retryable?(:rate_limited)).to be false
      expect(described_class.retryable?(:auth_expired)).to be false
      expect(described_class.retryable?(:permanent)).to be false
    end
  end

  describe ".description_for" do
    it "returns description for known categories" do
      expect(described_class.description_for(:rate_limited)).to eq("Rate limit exceeded")
      expect(described_class.description_for(:auth_expired)).to eq("Authentication failed or expired")
    end

    it "returns default for unknown categories" do
      expect(described_class.description_for(:nonexistent)).to eq("Unknown error")
    end
  end

  describe ".categories" do
    it "returns all category names" do
      categories = described_class.categories
      expect(categories).to include(:rate_limited, :auth_expired, :transient, :permanent)
    end
  end
end
