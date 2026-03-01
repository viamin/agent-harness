# frozen_string_literal: true

RSpec.describe AgentHarness do
  it "has a version number" do
    expect(AgentHarness::VERSION).not_to be_nil
  end

  describe ".configuration" do
    it "returns a Configuration instance" do
      expect(AgentHarness.configuration).to be_a(AgentHarness::Configuration)
    end

    it "returns the same instance on subsequent calls" do
      config1 = AgentHarness.configuration
      config2 = AgentHarness.configuration
      expect(config1).to be(config2)
    end
  end

  describe ".configure" do
    it "yields the configuration" do
      AgentHarness.configure do |config|
        config.default_provider = :claude
        config.log_level = :debug
      end

      expect(AgentHarness.configuration.default_provider).to eq(:claude)
      expect(AgentHarness.configuration.log_level).to eq(:debug)
    end
  end

  describe ".reset!" do
    it "resets configuration to defaults" do
      AgentHarness.configure do |config|
        config.default_provider = :claude
      end

      AgentHarness.reset!

      expect(AgentHarness.configuration.default_provider).to eq(:cursor)
    end
  end

  describe ".token_tracker" do
    it "returns a TokenTracker instance" do
      expect(AgentHarness.token_tracker).to be_a(AgentHarness::TokenTracker)
    end
  end

  describe ".auth_valid?" do
    it "delegates to Authentication module" do
      expect(AgentHarness::Authentication).to receive(:auth_valid?).with(:claude).and_return(true)
      expect(AgentHarness.auth_valid?(:claude)).to be true
    end
  end

  describe ".auth_status" do
    it "delegates to Authentication module" do
      status = {valid: true, expires_at: nil, error: nil}
      expect(AgentHarness::Authentication).to receive(:auth_status).with(:claude).and_return(status)
      expect(AgentHarness.auth_status(:claude)).to eq(status)
    end
  end

  describe ".auth_url" do
    it "delegates to Authentication module" do
      expect(AgentHarness::Authentication).to receive(:auth_url).with(:claude).and_return("https://example.com")
      expect(AgentHarness.auth_url(:claude)).to eq("https://example.com")
    end
  end

  describe ".refresh_auth" do
    it "delegates to Authentication module" do
      expect(AgentHarness::Authentication).to receive(:refresh_auth).with(:claude, code: "abc", token: nil).and_return({success: true})
      expect(AgentHarness.refresh_auth(:claude, code: "abc")).to eq({success: true})
    end
  end
end
