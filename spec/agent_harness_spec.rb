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

    it "clears registered skills" do
      AgentHarness::Skills.register(:code_review, {
        description: "Review code",
        instructions: "Body"
      })

      AgentHarness.reset!

      expect {
        AgentHarness::Skills.find(:code_review)
      }.to raise_error(AgentHarness::ConfigurationError, /Unknown skill/)
    end
  end

  describe ".token_tracker" do
    it "returns a TokenTracker instance" do
      expect(AgentHarness.token_tracker).to be_a(AgentHarness::TokenTracker)
    end
  end

  describe ".providers" do
    it "returns an array of registered provider name symbols" do
      result = AgentHarness.providers
      expect(result).to be_an(Array)
      expect(result).to include(:claude, :cursor, :gemini)
    end

    it "lists :omp separately from :pi" do
      providers = AgentHarness.providers

      expect(providers).to include(:omp, :pi)
      expect(providers.count(:omp)).to eq(1)
      expect(providers.count(:pi)).to eq(1)
    end

    it "delegates to Registry#all" do
      expect(AgentHarness.providers).to eq(AgentHarness::Providers::Registry.instance.all)
    end
  end

  describe ".provider_class" do
    it "returns the provider class for a known provider" do
      expect(AgentHarness.provider_class(:claude)).to eq(AgentHarness::Providers::Anthropic)
    end

    it "resolves aliases" do
      expect(AgentHarness.provider_class(:anthropic)).to eq(AgentHarness::Providers::Anthropic)
    end

    it "raises ConfigurationError for an unknown provider" do
      expect { AgentHarness.provider_class(:nonexistent) }.to raise_error(AgentHarness::ConfigurationError)
    end
  end

  describe ".build_config" do
    it "returns a ProviderConfig with the given name" do
      config = AgentHarness.build_config(:claude)
      expect(config).to be_a(AgentHarness::ProviderConfig)
      expect(config.name).to eq(:claude)
    end

    it "applies default values" do
      config = AgentHarness.build_config(:cursor)
      expect(config.enabled).to be true
      expect(config.priority).to eq(10)
    end

    it "merges provided options" do
      config = AgentHarness.build_config(:claude, priority: 5, model: "opus")
      expect(config.priority).to eq(5)
      expect(config.model).to eq("opus")
    end
  end

  describe ".sub_agent" do
    it "resolves configured sub-agents" do
      AgentHarness.configure do |config|
        config.sub_agent(:code_reviewer,
          description: "Reviews code",
          instructions: "Review the provided changes")
      end

      expect(AgentHarness.sub_agent(:code_reviewer).name).to eq(:code_reviewer)
    end
  end

  describe ".translate_sub_agent" do
    it "translates configured sub-agents for a provider" do
      AgentHarness.configure do |config|
        config.register_tool(:read_file, anthropic: "Read")
        config.sub_agent(:code_reviewer,
          description: "Reviews code",
          instructions: "Review the provided changes",
          tools: [:read_file])
      end

      translated = AgentHarness.translate_sub_agent(:code_reviewer, provider: :anthropic)
      expect(translated[:agent][:tools]).to eq(["Read"])
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
      contract = {binary_name: "kilo", default_version: "7.4.22"}

      expect(AgentHarness::Providers::Registry.instance)
        .to receive(:installation_contract).with(:kilocode, version: "7.4.22").and_return(contract)

      expect(AgentHarness.provider_installation_contract(:kilocode, version: "7.4.22")).to eq(contract)
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

    it "returns Aider provider install metadata" do
      contract = AgentHarness.installation_contract(:aider)

      expect(contract).to include(
        source: :uv_tool,
        package_name: "aider-chat",
        binary_name: "aider"
      )
    end

    it "raises ConfigurationError for an unknown provider" do
      expect {
        AgentHarness.installation_contract(:nonexistent_provider_xyz)
      }.to raise_error(AgentHarness::ConfigurationError, /Unknown provider/)
    end

    it "forwards target selection options to the provider registry" do
      contract = {binary_name: "kilo", default_version: "7.4.22"}

      expect(AgentHarness::Providers::Registry.instance)
        .to receive(:installation_contract).with(:kilocode, version: "7.4.22").and_return(contract)

      expect(AgentHarness.installation_contract(:kilocode, version: "7.4.22")).to eq(contract)
    end

    it "returns versioned install metadata for providers with generic contracts" do
      contract = AgentHarness.installation_contract(:opencode, version: "1.18.19")

      expect(contract).to include(
        package_name: "opencode-ai",
        version: "1.18.19",
        binary_name: "opencode"
      )
      expect(contract[:install_command]).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "opencode-ai@1.18.19"]
      )
    end

    it "returns Pi provider install metadata" do
      contract = AgentHarness.installation_contract(:pi)

      expect(contract).to include(
        source: :npm,
        package_name: "@mariozechner/pi-coding-agent",
        binary_name: "pi"
      )
    end

    it "returns Oh My Pi provider install metadata with Bun runtime requirements" do
      contract = AgentHarness.installation_contract(:omp)

      expect(contract).to include(
        source: :npm,
        package_name: "@oh-my-pi/pi-coding-agent",
        version: "17.3.5",
        binary_name: "omp"
      )

      bun = contract.fetch(:runtime_requirements).find { |req| req[:name] == :bun }
      expect(bun).to include(
        binary_name: "bun",
        pinned_version: "1.4.0",
        version_requirement: ">= 1.4.0",
        install_script_url: "https://bun.sh/install"
      )
    end

    it "preserves provider normalization for generic-contract version lookups" do
      contract = AgentHarness.installation_contract(:opencode, version: " 1.18.19 ")

      expect(contract).to include(
        package_name: "opencode-ai",
        version: "1.18.19",
        binary_name: "opencode"
      )
      expect(contract[:install_command]).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "opencode-ai@1.18.19"]
      )
    end
  end

  describe ".installation_contracts" do
    it "returns all registered provider installation contracts" do
      contracts = AgentHarness.installation_contracts

      expect(contracts).to include(:codex, :aider, :gemini, :opencode, :pi)
    end
  end

  describe ".provider_metadata" do
    it "delegates to the provider registry" do
      metadata = {provider: :claude, auth: {service: :anthropic}}

      expect(AgentHarness::Providers::Registry.instance)
        .to receive(:provider_metadata).with(:claude, refresh: false).and_return(metadata)

      expect(AgentHarness.provider_metadata(:claude)).to eq(metadata)
    end

    it "returns distinct metadata for :omp" do
      metadata = AgentHarness.provider_metadata(:omp)

      expect(metadata).to include(
        provider: :omp,
        canonical_provider: :omp,
        binary_name: "omp",
        display_name: "Oh My Pi"
      )
      expect(metadata[:auth]).to include(
        service: :omp,
        api_family: :multi_provider,
        api_key_source: :provider_runtime_env
      )

      installation = metadata.dig(:runtime, :installation)
      expect(installation).to include(
        package_name: "@oh-my-pi/pi-coding-agent",
        default_version: "17.3.5",
        resolved_version: "17.3.5",
        binary_name: "omp"
      )

      bun = installation.fetch(:runtime_requirements).find { |req| req[:name] == :bun }
      expect(bun).to include(
        pinned_version: "1.4.0",
        version_requirement: ">= 1.4.0"
      )
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

  describe ".smoke_test_contract" do
    it "returns the Oh My Pi smoke-test contract" do
      expect(AgentHarness.smoke_test_contract(:omp)).to include(
        prompt: "Reply with exactly OK.",
        expected_output: "OK",
        timeout: 30,
        success_message: "Oh My Pi smoke test passed"
      )
    end
  end

  describe ".auth_status" do
    it "delegates to Authentication module" do
      status = {valid: true, expires_at: nil, error: nil}
      expect(AgentHarness::Authentication).to receive(:auth_status).with(:claude).and_return(status)
      expect(AgentHarness.auth_status(:claude)).to eq(status)
    end
  end

  describe ".auth_capabilities" do
    it "delegates to Authentication module" do
      capabilities = {auth_type: :oauth, auth_url: true, exchange_code: true, refresh: true}
      expect(AgentHarness::Authentication).to receive(:auth_capabilities).with(:claude).and_return(capabilities)
      expect(AgentHarness.auth_capabilities(:claude)).to eq(capabilities)
    end
  end

  describe ".auth_url_supported?" do
    it "delegates to Authentication module" do
      expect(AgentHarness::Authentication).to receive(:auth_url_supported?).with(:claude).and_return(true)
      expect(AgentHarness.auth_url_supported?(:claude)).to be true
    end
  end

  describe ".auth_url" do
    it "delegates to Authentication module" do
      expect(AgentHarness::Authentication).to receive(:auth_url).with(:claude).and_return("https://example.com")
      expect(AgentHarness.auth_url(:claude)).to eq("https://example.com")
    end
  end

  describe ".exchange_code_supported?" do
    it "delegates to Authentication module" do
      expect(AgentHarness::Authentication).to receive(:exchange_code_supported?).with(:claude).and_return(true)
      expect(AgentHarness.exchange_code_supported?(:claude)).to be true
    end
  end

  describe ".exchange_code" do
    it "delegates to Authentication module" do
      expect(AgentHarness::Authentication).to receive(:exchange_code)
        .with(:claude, code: "abc", code_verifier: "xyz")
        .and_return({success: true, credentials: {}})
      expect(AgentHarness.exchange_code(:claude, code: "abc", code_verifier: "xyz"))
        .to eq({success: true, credentials: {}})
    end
  end

  describe ".refresh_auth_supported?" do
    it "delegates to Authentication module" do
      expect(AgentHarness::Authentication).to receive(:refresh_auth_supported?).with(:claude).and_return(true)
      expect(AgentHarness.refresh_auth_supported?(:claude)).to be true
    end
  end

  describe ".refresh_auth" do
    it "delegates to Authentication module" do
      expect(AgentHarness::Authentication).to receive(:refresh_auth).with(:claude, token: "abc").and_return({success: true})
      expect(AgentHarness.refresh_auth(:claude, token: "abc")).to eq({success: true})
    end
  end
end
