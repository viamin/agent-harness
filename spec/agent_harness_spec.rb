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

  describe ".provider_install_contract" do
    let(:provider_without_contract) do
      Class.new do
        class << self
          def provider_name
            :no_contract
          end

          def available?
            true
          end

          def binary_name
            "no-contract"
          end
        end
      end
    end

    it "delegates to the registered provider class" do
      contract = {provider: :gemini}
      expect(AgentHarness::Providers::Registry.instance).to receive(:get).with(:gemini).and_return(AgentHarness::Providers::Gemini)
      expect(AgentHarness::Providers::Gemini).to receive(:install_contract).and_return(contract)

      expect(AgentHarness.provider_install_contract(:gemini)).to eq(contract)
    end

    it "passes through an explicit version override" do
      contract = {provider: :gemini, resolved_version: "0.35.3"}
      expect(AgentHarness::Providers::Registry.instance).to receive(:get).with(:gemini).and_return(AgentHarness::Providers::Gemini)
      expect(AgentHarness::Providers::Gemini).to receive(:install_contract).with(version: "0.35.3").and_return(contract)

      expect(AgentHarness.provider_install_contract(:gemini, version: "0.35.3")).to eq(contract)
    end

    it "returns nil when the provider has no install contract and version is supplied" do
      expect(AgentHarness::Providers::Registry.instance).to receive(:get).with(:no_contract).and_return(provider_without_contract)

      expect(AgentHarness.provider_install_contract(:no_contract, version: "0.35.3")).to be_nil
    end

    it "returns nil when the provider has no install contract and no version is supplied" do
      expect(AgentHarness::Providers::Registry.instance).to receive(:get).with(:no_contract).and_return(provider_without_contract)

      expect(AgentHarness.provider_install_contract(:no_contract)).to be_nil
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
      expect(AgentHarness::Authentication).to receive(:refresh_auth).with(:claude, token: "abc").and_return({success: true})
      expect(AgentHarness.refresh_auth(:claude, token: "abc")).to eq({success: true})
    end
  end
end
