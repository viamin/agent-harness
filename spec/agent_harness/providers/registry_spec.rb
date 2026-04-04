# frozen_string_literal: true

RSpec.describe AgentHarness::Providers::Registry do
  let(:registry) { described_class.instance }

  before do
    registry.reset!
  end

  describe ".instance" do
    it "returns a singleton instance" do
      expect(described_class.instance).to be(described_class.instance)
    end
  end

  describe "#register" do
    let(:mock_provider) do
      Class.new do
        def self.provider_name
          :test_provider
        end

        def self.available?
          true
        end

        def self.binary_name
          "test"
        end
      end
    end

    it "registers a provider class" do
      registry.register(:test, mock_provider)
      expect(registry.registered?(:test)).to be true
    end

    it "registers aliases" do
      registry.register(:test, mock_provider, aliases: [:t, :testing])
      expect(registry.registered?(:t)).to be true
      expect(registry.registered?(:testing)).to be true
    end
  end

  describe "#get" do
    it "returns registered provider class" do
      # Force registration of builtin providers
      registry.send(:ensure_builtin_providers_registered)

      # Claude/anthropic should be registered
      expect { registry.get(:claude) }.not_to raise_error
    end

    it "raises ConfigurationError for unknown provider" do
      expect {
        registry.get(:nonexistent_provider_xyz)
      }.to raise_error(AgentHarness::ConfigurationError, /Unknown provider/)
    end
  end

  describe "#all" do
    it "returns all registered provider names" do
      registry.send(:ensure_builtin_providers_registered)
      all = registry.all

      expect(all).to be_an(Array)
      expect(all).to include(:claude)
    end
  end

  describe "#available" do
    it "returns only available providers" do
      registry.send(:ensure_builtin_providers_registered)
      available = registry.available

      expect(available).to be_an(Array)
      # Available providers depend on what CLIs are installed
    end
  end

  describe "#installation_contract" do
    it "returns install metadata for builtin providers that expose it" do
      contract = registry.installation_contract(:kilocode)

      expect(contract[:source]).to eq({
        type: :npm,
        package: "@kilocode/cli"
      })
      expect(contract[:binary_name]).to eq("kilo")
      expect(contract[:default_version]).to eq("7.1.3")
    end

    it "falls back to the legacy provider install contract API when needed" do
      contract = registry.installation_contract(:gemini, version: "0.35.3")

      expect(contract).to include(
        provider: :gemini,
        package_name: "@google/gemini-cli",
        resolved_version: "0.35.3"
      )
    end

    it "forwards target selection options to the provider" do
      contract = registry.installation_contract(:kilocode, version: "7.1.3")

      expect(contract[:install_command]).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "@kilocode/cli@7.1.3"]
      )
    end

    it "returns nil for registered providers without installation contract support" do
      provider_without_install_contract = Class.new do
        def self.provider_name
          :legacy_provider
        end

        def self.available?
          true
        end

        def self.binary_name
          "legacy"
        end
      end

      registry.register(:legacy_provider, provider_without_install_contract)

      expect(registry.installation_contract(:legacy_provider)).to be_nil
    end

    it "returns install metadata for providers with a generic contract" do
      contract = registry.installation_contract(:codex)

      expect(contract).to include(
        source: :npm,
        package_name: "@openai/codex",
        binary_name: "codex"
      )
    end

    it "raises ConfigurationError for unknown providers" do
      expect {
        registry.installation_contract(:nonexistent_provider_xyz)
      }.to raise_error(AgentHarness::ConfigurationError, /Unknown provider/)
    end

    it "returns nil for a registered provider without install metadata" do
      registry.register(:test, Class.new do
        def self.provider_name = :test
        def self.available? = true
        def self.binary_name = "test"
      end)

      expect(registry.installation_contract(:test)).to be_nil
    end
  end

  describe "#installation_contracts" do
    it "returns providers with installation contracts" do
      contracts = registry.installation_contracts

      expect(contracts).to include(:codex)
      expect(contracts[:codex][:install_command]).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "@openai/codex@0.116.0"]
      )
    end

    it "skips registered providers without install metadata" do
      registry.register(:test, Class.new do
        def self.provider_name = :test
        def self.available? = true
        def self.binary_name = "test"
      end)

      expect(registry.installation_contracts).not_to include(:test)
    end
  end

  describe "#provider_metadata" do
    it "returns metadata for builtin providers" do
      metadata = registry.provider_metadata(:claude)

      expect(metadata).to include(
        provider: :claude,
        canonical_provider: :claude,
        aliases: [:anthropic],
        binary_name: "claude"
      )
      expect(metadata[:auth]).to include(
        default_mode: :oauth,
        supported_modes: [:oauth],
        service: :anthropic,
        api_family: :anthropic
      )
      expect(metadata[:runtime]).to include(
        interface: :cli,
        requires_cli: true,
        installable: false,
        supports_mcp: true,
        supports_dangerous_mode: true
      )
      expect(metadata[:health_check]).to include(
        supports_registry_checks: true,
        lightweight: true
      )
    end

    it "resolves aliases to canonical provider metadata" do
      expect(registry.provider_metadata(:anthropic)).to eq(registry.provider_metadata(:claude))
    end

    it "returns fallback metadata for registry-compatible providers without adapter metadata" do
      legacy_provider = Class.new do
        def self.provider_name = :legacy_provider
        def self.available? = true
        def self.binary_name = "legacy"
      end

      registry.register(:legacy_provider, legacy_provider, aliases: [:legacy])

      metadata = registry.provider_metadata(:legacy)

      expect(metadata).to include(
        provider: :legacy_provider,
        canonical_provider: :legacy_provider,
        aliases: [:legacy],
        binary_name: "legacy"
      )
      expect(metadata[:auth]).to include(
        default_mode: nil,
        supported_modes: [],
        service: nil,
        api_family: nil
      )
      expect(metadata[:runtime]).to include(
        available: true,
        installable: false,
        supports_mcp: false,
        supports_sessions: false
      )
      expect(metadata[:health_check]).to include(
        supports_registry_checks: false,
        lightweight: false
      )
    end

    it "raises ConfigurationError for unknown providers" do
      expect {
        registry.provider_metadata(:nonexistent_provider_xyz)
      }.to raise_error(AgentHarness::ConfigurationError, /Unknown provider/)
    end
  end

  describe "#provider_metadata_catalog" do
    it "returns metadata for all registered providers" do
      catalog = registry.provider_metadata_catalog

      expect(catalog).to include(:claude, :codex, :gemini)
      expect(catalog[:codex][:auth]).to include(
        service: :openai,
        api_family: :openai
      )
    end
  end

  describe "#reset!" do
    it "clears all registrations" do
      registry.send(:ensure_builtin_providers_registered)
      registry.reset!

      # After reset, builtins should not be registered yet
      expect(registry.instance_variable_get(:@builtin_registered)).to be false
    end
  end
end
