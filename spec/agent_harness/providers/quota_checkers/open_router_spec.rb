# frozen_string_literal: true

require "json"

RSpec.describe AgentHarness::Providers::QuotaCheckers::OpenRouter do
  describe ".routes_through_open_router?" do
    it "returns true when OPENROUTER_API_KEY is present" do
      expect(described_class.routes_through_open_router?("OPENROUTER_API_KEY" => "sk-or-...")).to be true
    end

    it "returns true when OPENAI_BASE_URL points at openrouter.ai" do
      env = {"OPENAI_BASE_URL" => "https://openrouter.ai/api/v1"}
      expect(described_class.routes_through_open_router?(env)).to be true
    end

    it "returns true with symbol keys" do
      env = {OPENROUTER_API_KEY: "sk-or-..."}
      expect(described_class.routes_through_open_router?(env)).to be true
    end

    it "returns false for unrelated envs" do
      expect(described_class.routes_through_open_router?("OPENAI_API_KEY" => "sk-...")).to be false
    end

    it "returns false for nil" do
      expect(described_class.routes_through_open_router?(nil)).to be false
    end
  end

  describe ".resolve_api_key" do
    it "prefers OPENROUTER_API_KEY" do
      env = {"OPENROUTER_API_KEY" => "sk-or-...", "OPENAI_API_KEY" => "sk-oai"}
      expect(described_class.resolve_api_key(env)).to eq("sk-or-...")
    end

    it "falls back to OPENAI_API_KEY" do
      env = {"OPENAI_API_KEY" => "sk-oai"}
      expect(described_class.resolve_api_key(env)).to eq("sk-oai")
    end

    it "returns nil when no key is present" do
      expect(described_class.resolve_api_key({})).to be_nil
    end
  end

  describe ".check" do
    let(:http) { instance_double(Net::HTTP) }
    let(:response) do
      instance_double(
        Net::HTTPSuccess,
        body: JSON.generate({"data" => {"total_credits" => 20.0, "total_usage" => 7.5}})
      )
    end

    before do
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:request).and_return(response)
      allow(response).to receive(:is_a?).and_return(false)
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
    end

    it "returns a populated QuotaStatus with credit unit" do
      status = described_class.check(env: {"OPENROUTER_API_KEY" => "sk-or-..."})

      expect(status.available?).to be true
      expect(status.unit).to eq(:credits)
      expect(status.remaining).to eq(12.5)
      expect(status.limit).to eq(20.0)
    end

    it "uses OPENROUTER_BASE_URL override when provided" do
      expect(Net::HTTP).to receive(:new).with("staging.openrouter.test", 443).and_return(http)

      described_class.check(env: {
        "OPENROUTER_API_KEY" => "sk-or-...",
        "OPENROUTER_BASE_URL" => "https://staging.openrouter.test/api/v1"
      })
    end

    it "returns unavailable when no api key is present" do
      status = described_class.check(env: {})

      expect(status.available?).to be false
      expect(Net::HTTP).not_to have_received(:new)
    end

    it "returns unavailable on non-200 responses" do
      error_response = instance_double(Net::HTTPNotFound, code: "404", body: "")
      allow(error_response).to receive(:is_a?).and_return(false)
      allow(error_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(http).to receive(:request).and_return(error_response)

      status = described_class.check(env: {"OPENROUTER_API_KEY" => "sk-or-..."})
      expect(status.available?).to be false
    end

    it "returns unavailable on malformed JSON" do
      malformed_response = instance_double(Net::HTTPSuccess, body: "not-json")
      allow(malformed_response).to receive(:is_a?).and_return(false)
      allow(malformed_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(malformed_response)

      status = described_class.check(env: {"OPENROUTER_API_KEY" => "sk-or-..."})
      expect(status.available?).to be false
    end

    it "returns unavailable when data bucket is missing" do
      empty_response = instance_double(Net::HTTPSuccess, body: JSON.generate({}))
      allow(empty_response).to receive(:is_a?).and_return(false)
      allow(empty_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(empty_response)

      status = described_class.check(env: {"OPENROUTER_API_KEY" => "sk-or-..."})
      expect(status.available?).to be false
    end

    it "returns unavailable on network errors" do
      allow(http).to receive(:request).and_raise(Errno::ECONNREFUSED, "Connection refused")

      status = described_class.check(env: {"OPENROUTER_API_KEY" => "sk-or-..."})
      expect(status.available?).to be false
    end
  end
end
