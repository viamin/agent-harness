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

  describe ".install_contract" do
    it "delegates to the provider registry" do
      contract = {provider: :claude}
      expect(AgentHarness::Providers::Registry.instance).to receive(:install_contract).with(:claude).and_return(contract)

      expect(AgentHarness.install_contract(:claude)).to eq(contract)
    end

    it "accepts string provider names" do
      contract = {provider: :claude}
      expect(AgentHarness::Providers::Registry.instance).to receive(:install_contract).with("claude").and_return(contract)

      expect(AgentHarness.install_contract("claude")).to eq(contract)
    end
  end

  describe ".send_message" do
    it "passes executor overrides to the conductor" do
      executor = instance_double(AgentHarness::CommandExecutor)
      response = instance_double(AgentHarness::Response)

      expect(AgentHarness.conductor).to receive(:send_message)
        .with("Hello", provider: :codex, executor: executor, temperature: 0.1)
        .and_return(response)

      expect(
        AgentHarness.send_message("Hello", provider: :codex, executor: executor, temperature: 0.1)
      ).to be(response)
    end
  end

  describe ".provider_installation_contract" do
    it "delegates to the provider registry" do
      contract = {binary_name: "kilo"}

      expect(AgentHarness::Providers::Registry.instance)
        .to receive(:installation_contract).with(:kilocode).and_return(contract)

      expect(AgentHarness.provider_installation_contract(:kilocode)).to eq(contract)
    end

    it "forwards target selection options to the provider registry" do
      contract = {binary_name: "kilo", default_version: "7.1.3"}

      expect(AgentHarness::Providers::Registry.instance)
        .to receive(:installation_contract).with(:kilocode, version: "7.1.3").and_return(contract)

      expect(AgentHarness.provider_installation_contract(:kilocode, version: "7.1.3")).to eq(contract)
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

    after do
      AgentHarness::Providers::Registry.instance.reset!
    end

    it "delegates to the provider installation API" do
      contract = {provider: :gemini}

      expect(AgentHarness).to receive(:provider_installation_contract).with(:gemini).and_return(contract)

      expect(AgentHarness.provider_install_contract(:gemini)).to eq(contract)
    end

    it "passes through an explicit version override" do
      contract = {provider: :gemini, resolved_version: "0.35.3"}

      expect(AgentHarness).to receive(:provider_installation_contract).with(:gemini, version: "0.35.3").and_return(contract)

      expect(AgentHarness.provider_install_contract(:gemini, version: "0.35.3")).to eq(contract)
    end

    it "returns nil when the provider has no install contract and version is supplied" do
      expect(AgentHarness::Providers::Registry.instance)
        .to receive(:installation_contract).with(:no_contract, version: "0.35.3").and_return(nil)

      expect(AgentHarness.provider_install_contract(:no_contract, version: "0.35.3")).to be_nil
    end

    it "returns nil when the provider has no install contract and no version is supplied" do
      expect(AgentHarness::Providers::Registry.instance)
        .to receive(:installation_contract).with(:no_contract).and_return(nil)

      expect(AgentHarness.provider_install_contract(:no_contract)).to be_nil
    end

    it "returns nil for a registry-accepted provider class without adapter install APIs" do
      AgentHarness::Providers::Registry.instance.register(:no_contract, provider_without_contract)

      expect(AgentHarness.provider_install_contract(:no_contract)).to be_nil
      expect(AgentHarness.provider_install_contract(:no_contract, version: "0.35.3")).to be_nil
    end
  end

  describe ".installation_contract" do
    it "returns provider install metadata" do
      contract = AgentHarness.installation_contract(:codex)

      expect(contract).to include(
        source: :npm,
        package_name: "@openai/codex",
        binary_name: "codex"
      )
    end

    it "raises ConfigurationError for an unknown provider" do
      expect {
        AgentHarness.installation_contract(:nonexistent_provider_xyz)
      }.to raise_error(AgentHarness::ConfigurationError, /Unknown provider/)
    end

    it "forwards target selection options to the provider registry" do
      contract = {binary_name: "kilo", default_version: "7.1.3"}

      expect(AgentHarness::Providers::Registry.instance)
        .to receive(:installation_contract).with(:kilocode, version: "7.1.3").and_return(contract)

      expect(AgentHarness.installation_contract(:kilocode, version: "7.1.3")).to eq(contract)
    end

    it "returns versioned install metadata for providers with generic contracts" do
      contract = AgentHarness.installation_contract(:opencode, version: "1.3.9")

      expect(contract).to include(
        package_name: "opencode-ai",
        version: "1.3.9",
        binary_name: "opencode"
      )
      expect(contract[:install_command]).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "opencode-ai@1.3.9"]
      )
    end

    it "preserves provider normalization for generic-contract version lookups" do
      contract = AgentHarness.installation_contract(:opencode, version: " 1.3.9 ")

      expect(contract).to include(
        package_name: "opencode-ai",
        version: "1.3.9",
        binary_name: "opencode"
      )
      expect(contract[:install_command]).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "opencode-ai@1.3.9"]
      )
    end
  end

  describe ".installation_contracts" do
    it "returns all registered provider installation contracts" do
      contracts = AgentHarness.installation_contracts

      expect(contracts).to include(:codex, :gemini, :opencode)
    end
  end

  describe ".provider_metadata" do
    it "delegates to the provider registry" do
      metadata = {provider: :claude, auth: {service: :anthropic}}

      expect(AgentHarness::Providers::Registry.instance)
        .to receive(:provider_metadata).with(:claude, refresh: false).and_return(metadata)

      expect(AgentHarness.provider_metadata(:claude)).to eq(metadata)
    end
  end

  describe ".provider_metadata_catalog" do
    it "returns provider metadata for all providers" do
      metadata = {claude: {provider: :claude}}

      expect(AgentHarness::Providers::Registry.instance)
        .to receive(:provider_metadata_catalog).with(refresh: false).and_return(metadata)

      expect(AgentHarness.provider_metadata_catalog).to eq(metadata)
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
