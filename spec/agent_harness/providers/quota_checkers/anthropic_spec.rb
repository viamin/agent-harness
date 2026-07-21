# frozen_string_literal: true

require "json"

RSpec.describe AgentHarness::Providers::QuotaCheckers::Anthropic do
  describe ".resolve_api_key" do
    it "prefers ANTHROPIC_ADMIN_API_KEY from env" do
      env = {"ANTHROPIC_ADMIN_API_KEY" => "sk-ant-admin", "ANTHROPIC_API_KEY" => "sk-ant"}
      expect(described_class.resolve_api_key(env)).to eq("sk-ant-admin")
    end

    it "falls back to ANTHROPIC_API_KEY from env" do
      env = {"ANTHROPIC_API_KEY" => "sk-ant"}
      expect(described_class.resolve_api_key(env)).to eq("sk-ant")
    end

    it "falls back to ANTHROPIC_API_KEY from process ENV" do
      with_env("ANTHROPIC_API_KEY" => "sk-ant-from-env") do
        expect(described_class.resolve_api_key({})).to eq("sk-ant-from-env")
      end
    end

    it "returns nil when no key is present" do
      with_env("ANTHROPIC_ADMIN_API_KEY" => nil, "ANTHROPIC_API_KEY" => nil) do
        expect(described_class.resolve_api_key({})).to be_nil
      end
    end
  end

  describe ".check" do
    let(:http) { instance_double(Net::HTTP) }
    let(:response) do
      instance_double(
        Net::HTTPSuccess,
        body: JSON.generate({
          "data" => [
            {"input_tokens" => 1_000, "output_tokens" => 500},
            {"input_tokens" => 200, "output_tokens" => 50}
          ]
        })
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

    it "returns a populated QuotaStatus with tokens unit" do
      status = described_class.check(env: {"ANTHROPIC_API_KEY" => "sk-ant"})

      expect(status.available?).to be true
      expect(status.unit).to eq(:tokens)
      # The usage_reports endpoint reports consumption, not a cap, so limit and
      # remaining stay nil rather than mislabeling usage as the ceiling.
      expect(status.limit).to be_nil
      expect(status.remaining).to be_nil
      expect(status.reset_at).to be_a(Time)
    end

    it "sends x-api-key and anthropic-version headers" do
      request_double = instance_double(Net::HTTP::Get).as_null_object
      allow(Net::HTTP::Get).to receive(:new).and_return(request_double)
      allow(request_double).to receive(:[]=)

      described_class.check(env: {"ANTHROPIC_API_KEY" => "sk-ant"})

      expect(request_double).to have_received(:[]=).with("x-api-key", "sk-ant")
      expect(request_double).to have_received(:[]=).with("anthropic-version", anything)
    end

    it "returns unavailable when no api key is present" do
      with_env("ANTHROPIC_ADMIN_API_KEY" => nil, "ANTHROPIC_API_KEY" => nil) do
        status = described_class.check(env: {})

        expect(status.available?).to be false
        expect(Net::HTTP).not_to have_received(:new)
      end
    end

    it "returns unavailable on non-200 responses" do
      error_response = instance_double(Net::HTTPUnauthorized, code: "401", body: "")
      allow(error_response).to receive(:is_a?).and_return(false)
      allow(error_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(http).to receive(:request).and_return(error_response)

      status = described_class.check(env: {"ANTHROPIC_API_KEY" => "sk-ant"})
      expect(status.available?).to be false
    end

    it "returns unavailable on empty data" do
      empty_response = instance_double(Net::HTTPSuccess, body: JSON.generate({"data" => []}))
      allow(empty_response).to receive(:is_a?).and_return(false)
      allow(empty_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(empty_response)

      status = described_class.check(env: {"ANTHROPIC_API_KEY" => "sk-ant"})
      expect(status.available?).to be false
    end

    it "returns unavailable on malformed JSON" do
      malformed_response = instance_double(Net::HTTPSuccess, body: "garbage")
      allow(malformed_response).to receive(:is_a?).and_return(false)
      allow(malformed_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(malformed_response)

      status = described_class.check(env: {"ANTHROPIC_API_KEY" => "sk-ant"})
      expect(status.available?).to be false
    end

    it "returns unavailable on network errors" do
      allow(http).to receive(:request).and_raise(Errno::ECONNREFUSED, "Connection refused")

      status = described_class.check(env: {"ANTHROPIC_API_KEY" => "sk-ant"})
      expect(status.available?).to be false
    end

    it "uses ANTHROPIC_BASE_URL override when provided" do
      expect(Net::HTTP).to receive(:new).with("internal.anthropic.test", 443).and_return(http)

      described_class.check(env: {
        "ANTHROPIC_API_KEY" => "sk-ant",
        "ANTHROPIC_BASE_URL" => "https://internal.anthropic.test"
      })
    end
  end

  # Minimal ENV helper. Saves and restores the named keys around the block so
  # tests don't leak state into the rest of the suite.
  def with_env(overrides)
    saved = overrides.keys.each_with_object({}) do |key, acc|
      acc[key] = ENV[key]
    end
    overrides.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
    yield
  ensure
    saved.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end
end
