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

    it "normalizes aliases consistently at registration time" do
      registry.register(:test, mock_provider, aliases: [" legacy ", :legacy, "", " ", :test])

      expect(registry.registered?(:legacy)).to be true
      expect(registry.provider_metadata(:test)[:aliases]).to eq([:legacy])
    end

    it "replaces stale aliases when a provider is re-registered" do
      registry.register(:test, mock_provider, aliases: [:t, :testing])
      registry.register(:test, mock_provider, aliases: [:renamed])

      expect(registry.registered?(:t)).to be false
      expect(registry.registered?(:testing)).to be false
      expect(registry.registered?(:renamed)).to be true
      expect(registry.provider_metadata(:test)[:aliases]).to eq([:renamed])
    end

    it "evicts aliases from the previous provider when ownership changes" do
      other_provider = Class.new do
        def self.provider_name = :other_provider
        def self.available? = true
        def self.binary_name = "other"
      end

      registry.register(:first, mock_provider, aliases: [:shared])
      registry.register(:second, other_provider, aliases: [:shared])

      expect(registry.get(:shared)).to be(other_provider)
      expect(registry.provider_metadata(:first)[:aliases]).to eq([])
      expect(registry.provider_metadata(:second)[:aliases]).to eq([:shared])
    end

    it "drops an alias claim when that identifier becomes a canonical provider name" do
      other_provider = Class.new do
        def self.provider_name = :other_provider
        def self.available? = true
        def self.binary_name = "other"
      end

      registry.register(:first, mock_provider, aliases: [:second])
      registry.register(:second, other_provider)

      expect(registry.get(:second)).to be(other_provider)
      expect(registry.provider_metadata(:first)[:aliases]).to eq([])
      expect(registry.provider_metadata(:second)[:provider]).to eq(:second)
    end

    it "rejects aliases that conflict with another canonical provider name" do
      other_provider = Class.new do
        def self.provider_name = :other_provider
        def self.available? = true
        def self.binary_name = "other"
      end

      registry.register(:first, mock_provider)

      expect {
        registry.register(:second, other_provider, aliases: [:first])
      }.to raise_error(AgentHarness::ConfigurationError, /Alias :first conflicts with registered provider :first/)
    end

    it "clears adapter metadata caches when a provider is re-registered" do
      adapter_provider = Class.new do
        include AgentHarness::Providers::Adapter

        class << self
          attr_accessor :available_flag
          attr_accessor :auth_type_value

          def provider_name = :adapter_provider
          def available? = available_flag
          def binary_name = "adapter"
        end
        def initialize(config: nil)
          @config = config
        end

        def auth_type
          self.class.auth_type_value
        end

        def name
          "adapter_provider"
        end
      end
      adapter_provider.available_flag = true
      adapter_provider.auth_type_value = :api_key

      registry.register(:adapter_provider, adapter_provider)
      metadata = registry.provider_metadata(:adapter_provider)

      expect(metadata[:runtime][:available]).to be true
      expect(metadata[:health_check][:auth_check_supported]).to be false

      adapter_provider.available_flag = false
      adapter_provider.auth_type_value = :oauth
      registry.register(:adapter_provider, adapter_provider)

      metadata = registry.provider_metadata(:adapter_provider)

      expect(metadata[:runtime][:available]).to be false
      expect(metadata[:health_check][:auth_check_supported]).to be false
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

    it "forwards target selection options to providers with generic contracts" do
      contract = registry.installation_contract(:opencode, version: "1.3.9")

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
      contract = registry.installation_contract(:opencode, version: " 1.3.9 ")

      expect(contract).to include(
        package_name: "opencode-ai",
        version: "1.3.9",
        binary_name: "opencode"
      )
      expect(contract[:install_command]).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "opencode-ai@1.3.9"]
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

      expect(contracts).to include(:codex, :opencode)
      expect(contracts[:codex][:install_command]).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "@openai/codex@0.116.0"]
      )
      expect(contracts[:opencode][:install_command]).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "opencode-ai@1.3.2"]
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
        auth_check_supported: true,
        lightweight: true
      )
      expect(metadata[:identity]).to eq(
        bot_usernames: ["claude", "anthropic"]
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
      expect(metadata[:identity]).to eq(
        bot_usernames: ["legacy_provider", "legacy"]
      )
    end

    it "returns copied aliases in fallback metadata" do
      legacy_provider = Class.new do
        def self.provider_name = :legacy_provider
        def self.available? = true
        def self.binary_name = "legacy"
      end

      registry.register(:legacy_provider, legacy_provider, aliases: [:legacy])

      metadata = registry.provider_metadata(:legacy_provider)
      metadata[:aliases] << :mutated

      expect(registry.provider_metadata(:legacy_provider)[:aliases]).to eq([:legacy])
    end

    it "normalizes fallback aliases exposed through metadata" do
      legacy_provider = Class.new do
        def self.provider_name = :legacy_provider
        def self.available? = true
        def self.binary_name = "legacy"
      end

      registry.register(:legacy_provider, legacy_provider, aliases: [:legacy, " legacy ", :legacy_provider])

      metadata = registry.provider_metadata(:legacy_provider)

      expect(metadata[:aliases]).to eq([:legacy])
      expect(metadata[:identity]).to eq(
        bot_usernames: ["legacy_provider", "legacy"]
      )
    end

    it "returns adapter metadata even when the provider requires constructor arguments" do
      required_initializer_provider = Class.new do
        include AgentHarness::Providers::Adapter

        class << self
          def provider_name = :required_initializer_provider
          def available? = true
          def binary_name = "required"
        end

        def initialize(required:)
          @required = required
        end
      end

      registry.register(:required_initializer_provider, required_initializer_provider, aliases: [:required])

      metadata = registry.provider_metadata(:required)

      expect(metadata).to include(
        provider: :required_initializer_provider,
        canonical_provider: :required_initializer_provider,
        aliases: [:required],
        binary_name: "required"
      )
      expect(metadata[:auth]).to include(
        default_mode: nil,
        supported_modes: []
      )
      expect(metadata[:health_check]).to include(
        supports_registry_checks: false,
        auth_check_supported: false,
        provider_status: false,
        configuration_validation: false,
        lightweight: false
      )
      expect(metadata[:identity]).to eq(
        bot_usernames: ["required_initializer_provider", "required"]
      )
    end

    it "uses registry-compatible construction to expose instance metadata" do
      registry_compatible_provider = Class.new do
        include AgentHarness::Providers::Adapter

        class << self
          def provider_name = :registry_compatible_provider
          def available? = true
          def binary_name = "registry-compatible"
        end

        def initialize(config: nil, executor: nil, logger: nil)
          @config = config
          @executor = executor
          @logger = logger
        end

        def display_name
          "Registry compatible provider"
        end

        def auth_type
          :oauth
        end

        def configuration_schema
          {
            fields: [{name: :workspace, type: :string}],
            auth_modes: [:oauth],
            openai_compatible: false
          }
        end

        def execution_semantics
          {
            prompt_delivery: :stdin,
            output_format: :json,
            sandbox_aware: true,
            uses_subcommand: true
          }
        end

        def capabilities
          {
            streaming: true,
            tool_use: true
          }
        end
      end

      command_executor = instance_double("AgentHarness::CommandExecutor")
      allow(AgentHarness.configuration).to receive(:command_executor).and_return(command_executor)
      allow(AgentHarness).to receive(:logger).and_return(instance_double("Logger", debug: nil))

      registry.register(:registry_compatible_provider, registry_compatible_provider, aliases: [:registry_compatible])

      metadata = registry.provider_metadata(:registry_compatible)

      expect(metadata).to include(
        display_name: "Registry compatible provider"
      )
      expect(metadata[:auth]).to include(
        default_mode: :oauth,
        supported_modes: [:oauth]
      )
      expect(metadata[:runtime]).to include(
        prompt_delivery: :stdin,
        output_format: :json,
        sandbox_aware: true,
        uses_subcommand: true
      )
      expect(metadata[:configuration]).to include(
        fields: [{name: :workspace, type: :string}],
        auth_modes: [:oauth],
        openai_compatible: false
      )
      expect(metadata[:capabilities]).to include(
        streaming: true,
        tool_use: true
      )
      expect(metadata[:health_check]).to include(
        supports_registry_checks: true,
        lightweight: true
      )
    end

    it "prefers alias-keyed config when metadata is requested through an alias" do
      alias_sensitive_provider = Class.new do
        include AgentHarness::Providers::Adapter

        class << self
          def provider_name = :alias_sensitive_provider
          def available? = true
          def binary_name = "alias-sensitive"
        end

        def initialize(config: nil)
          @config = config
        end

        def configuration_schema
          {
            fields: [{name: @config.name, type: :string}],
            auth_modes: [:api_key],
            openai_compatible: false
          }
        end

        def execution_semantics
          {
            prompt_delivery: @config.name,
            output_format: :text,
            sandbox_aware: false,
            uses_subcommand: false
          }
        end
      end

      AgentHarness.configuration.provider(:alias_sensitive_provider) { |config| config.enabled = true }
      AgentHarness.configuration.provider(:alias_name) { |config| config.enabled = true }
      registry.register(:alias_sensitive_provider, alias_sensitive_provider, aliases: [:alias_name])

      metadata = registry.provider_metadata(:alias_name)

      expect(metadata[:configuration]).to include(
        fields: [{name: :alias_name, type: :string}],
        auth_modes: [:api_key],
        openai_compatible: false
      )
      expect(metadata[:runtime]).to include(
        prompt_delivery: :alias_name
      )
    end

    it "exposes instance metadata for providers that only accept a registry keyword subset" do
      metadata_compatible_provider = Class.new do
        include AgentHarness::Providers::Adapter

        class << self
          def provider_name = :metadata_compatible_provider
          def available? = true
          def binary_name = "metadata-compatible"
        end

        def initialize(config: nil)
          @config = config
        end

        def auth_type
          :oauth
        end

        def configuration_schema
          {
            fields: [{name: :workspace, type: :string}],
            auth_modes: [:oauth],
            openai_compatible: false
          }
        end
      end

      registry.register(:metadata_compatible_provider, metadata_compatible_provider, aliases: [:metadata_compatible])

      metadata = registry.provider_metadata(:metadata_compatible)

      expect(metadata[:auth]).to include(
        default_mode: :oauth,
        supported_modes: [:oauth]
      )
      expect(metadata[:configuration]).to include(
        fields: [{name: :workspace, type: :string}],
        auth_modes: [:oauth],
        openai_compatible: false
      )
      expect(metadata[:health_check]).to include(
        supports_registry_checks: false,
        provider_status: false,
        configuration_validation: false,
        lightweight: false
      )
    end

    it "preserves the stable metadata shape for providers that return partial instance metadata" do
      partial_metadata_provider = Class.new do
        include AgentHarness::Providers::Adapter

        class << self
          def provider_name = :partial_metadata_provider
          def available? = true
          def binary_name = "partial-metadata"
        end

        def initialize(config: nil)
          @config = config
        end

        def configuration_schema
          {
            auth_modes: [:oauth]
          }
        end

        def execution_semantics
          {
            prompt_delivery: :stdin
          }
        end

        def capabilities
          {
            streaming: true
          }
        end
      end

      registry.register(:partial_metadata_provider, partial_metadata_provider)

      metadata = registry.provider_metadata(:partial_metadata_provider)

      expect(metadata[:configuration]).to eq(
        fields: [],
        auth_modes: [:oauth],
        openai_compatible: false
      )
      expect(metadata[:runtime]).to include(
        prompt_delivery: :stdin,
        output_format: :text,
        sandbox_aware: false,
        uses_subcommand: false
      )
      expect(metadata[:capabilities]).to eq(
        streaming: true,
        file_upload: false,
        vision: false,
        tool_use: false,
        json_mode: false,
        mcp: false,
        dangerous_mode: false
      )
    end

    it "raises ConfigurationError for unknown providers" do
      expect {
        registry.provider_metadata(:nonexistent_provider_xyz)
      }.to raise_error(AgentHarness::ConfigurationError, /Unknown provider/)
    end

    it "caches fallback availability until explicitly refreshed" do
      legacy_provider = Class.new do
        class << self
          attr_accessor :available_calls

          def provider_name = :legacy_provider

          def available?
            self.available_calls ||= 0
            self.available_calls += 1
            true
          end

          def binary_name = "legacy"
        end
      end

      registry.register(:legacy_provider, legacy_provider, aliases: [:legacy])

      expect(registry.provider_metadata(:legacy)[:runtime][:available]).to be true
      expect(registry.provider_metadata(:legacy)[:runtime][:available]).to be true
      expect(legacy_provider.available_calls).to eq(1)

      expect(registry.provider_metadata(:legacy, refresh: true)[:runtime][:available]).to be true
      expect(legacy_provider.available_calls).to eq(2)
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
      expect(catalog[:codex][:identity]).to eq(
        bot_usernames: ["codex"]
      )
      expect(catalog[:github_copilot][:identity]).to eq(
        bot_usernames: ["github-copilot[bot]"]
      )
    end

    it "reuses cached fallback availability across catalog reads" do
      legacy_provider = Class.new do
        class << self
          attr_accessor :available_calls

          def provider_name = :legacy_provider

          def available?
            self.available_calls ||= 0
            self.available_calls += 1
            true
          end

          def binary_name = "legacy"
        end
      end

      registry.register(:legacy_provider, legacy_provider)

      registry.provider_metadata_catalog
      registry.provider_metadata_catalog

      expect(legacy_provider.available_calls).to eq(1)

      registry.provider_metadata_catalog(refresh: true)

      expect(legacy_provider.available_calls).to eq(2)
    end
  end

  describe "#reset!" do
    it "clears all registrations" do
      registry.send(:ensure_builtin_providers_registered)
      registry.reset!

      # After reset, builtins should not be registered yet
      expect(registry.instance_variable_get(:@builtin_registered)).to be false
    end

    it "clears adapter metadata caches" do
      adapter_provider = Class.new do
        include AgentHarness::Providers::Adapter

        class << self
          attr_accessor :available_flag
          attr_accessor :auth_type_value

          def provider_name = :adapter_provider
          def available? = available_flag
          def binary_name = "adapter"
        end
        def initialize(config: nil)
          @config = config
        end

        def auth_type
          self.class.auth_type_value
        end

        def name
          "adapter_provider"
        end
      end
      adapter_provider.available_flag = true
      adapter_provider.auth_type_value = :api_key

      registry.register(:adapter_provider, adapter_provider)
      metadata = registry.provider_metadata(:adapter_provider)

      expect(metadata[:runtime][:available]).to be true
      expect(metadata[:health_check][:auth_check_supported]).to be false

      adapter_provider.available_flag = false
      adapter_provider.auth_type_value = :oauth
      registry.reset!
      registry.register(:adapter_provider, adapter_provider)

      metadata = registry.provider_metadata(:adapter_provider)

      expect(metadata[:runtime][:available]).to be false
      expect(metadata[:health_check][:auth_check_supported]).to be false
    end
  end
end
