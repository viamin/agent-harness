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

    it "does not allow alias ownership to move between providers" do
      other_provider = Class.new do
        def self.provider_name = :other_provider
        def self.available? = true
        def self.binary_name = "other"
      end

      registry.register(:first, mock_provider, aliases: [:shared])

      expect {
        registry.register(:second, other_provider, aliases: [:shared])
      }.to raise_error(AgentHarness::ConfigurationError, /Alias :shared conflicts with registered provider :first/)
    end

    it "rejects canonical provider names that conflict with an existing alias" do
      other_provider = Class.new do
        def self.provider_name = :other_provider
        def self.available? = true
        def self.binary_name = "other"
      end

      registry.register(:first, mock_provider, aliases: [:second])

      expect {
        registry.register(:second, other_provider)
      }.to raise_error(AgentHarness::ConfigurationError, /Provider :second conflicts with registered alias for :first/)
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

    it "does not eagerly bootstrap builtin providers during external registration" do
      expect {
        registry.register(:custom_provider, mock_provider)
      }.not_to raise_error

      expect(registry.instance_variable_get(:@providers)[:custom_provider]).to eq(mock_provider)
    end

    it "rejects canonical provider names that match reserved builtin aliases" do
      expect {
        registry.register(:anthropic, mock_provider)
      }.to raise_error(
        AgentHarness::ConfigurationError,
        /reserved as a builtin alias for :claude/
      )
    end

    it "rejects aliases that match reserved builtin aliases before bootstrap" do
      expect {
        registry.register(:custom_provider, mock_provider, aliases: [:anthropic])
      }.to raise_error(
        AgentHarness::ConfigurationError,
        /Alias :anthropic conflicts with registered provider :claude/
      )
    end

    it "rejects custom providers that shadow builtin canonical names" do
      expect {
        registry.register(:claude, mock_provider)
      }.to raise_error(AgentHarness::ConfigurationError, /reserved as a builtin canonical provider/)

      expect(registry.get(:claude)).to eq(AgentHarness::Providers::Anthropic)
    end

    it "rejects aliases that match builtin canonical provider names" do
      expect {
        registry.register(:custom_provider, mock_provider, aliases: [:claude])
      }.to raise_error(AgentHarness::ConfigurationError, /Alias :claude conflicts with registered provider :builtin_provider/)

      expect(registry.get(:claude)).to eq(AgentHarness::Providers::Anthropic)
      expect(registry.instance_variable_get(:@providers).key?(:custom_provider)).to eq(false)
      expect(registry.instance_variable_get(:@aliases).key?(:claude)).to eq(false)
      catalog = registry.provider_metadata_catalog
      expect(catalog.keys).to include(:claude)
    end

    it "still rejects aliases that conflict with builtin aliases after bootstrap" do
      registry.send(:ensure_builtin_providers_registered)

      expect {
        registry.register(:custom_provider, mock_provider, aliases: [:anthropic])
      }.to raise_error(AgentHarness::ConfigurationError, /Alias :anthropic conflicts with registered provider :claude/)
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

    it "uses a stable installation metadata shape across builtin providers" do
      codex_installation = registry.provider_metadata(:codex).dig(:runtime, :installation)
      gemini_installation = registry.provider_metadata(:gemini).dig(:runtime, :installation)
      kilocode_installation = registry.provider_metadata(:kilocode).dig(:runtime, :installation)

      [codex_installation, gemini_installation, kilocode_installation].each do |installation|
        expect(installation).to include(
          :provider,
          :source_type,
          :package_name,
          :default_version,
          :resolved_version,
          :supported_version_requirement,
          :binary_name,
          :install_command,
          :install_command_string
        )
      end

      expect(codex_installation).to include(
        provider: :codex,
        source_type: :npm,
        package_name: "@openai/codex",
        default_version: "0.116.0",
        resolved_version: "0.116.0",
        supported_version_requirement: ">= 0.116.0, < 0.117.0",
        binary_name: "codex",
        install_command: ["npm", "install", "-g", "--ignore-scripts", "@openai/codex@0.116.0"],
        install_command_string: "npm install -g --ignore-scripts @openai/codex@0.116.0"
      )
      expect(gemini_installation).to include(
        provider: :gemini,
        source_type: :npm,
        package_name: "@google/gemini-cli",
        default_version: "0.35.3",
        resolved_version: "0.35.3",
        supported_version_requirement: "= 0.35.3",
        binary_name: "gemini",
        install_command: ["npm", "install", "-g", "--ignore-scripts", "@google/gemini-cli@0.35.3"],
        install_command_string: "npm install -g --ignore-scripts @google/gemini-cli@0.35.3"
      )
      expect(kilocode_installation).to include(
        provider: :kilocode,
        source_type: :npm,
        package_name: "@kilocode/cli",
        default_version: "7.1.3",
        resolved_version: "7.1.3",
        supported_version_requirement: "= 7.1.3",
        binary_name: "kilo",
        install_command: ["npm", "install", "-g", "--ignore-scripts", "@kilocode/cli@7.1.3"],
        install_command_string: "npm install -g --ignore-scripts @kilocode/cli@7.1.3"
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
        installation: nil,
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
        default_mode: :api_key,
        supported_modes: [:api_key]
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

    it "publishes the registry canonical key for custom provider registrations" do
      custom_provider = Class.new do
        include AgentHarness::Providers::Adapter

        class << self
          def provider_name = :internal_provider_name
          def available? = true
          def binary_name = "internal-provider"
        end
      end

      registry.register(:external_provider_name, custom_provider, aliases: [:external_alias])

      metadata = registry.provider_metadata(:external_alias)

      expect(metadata).to include(
        provider: :external_provider_name,
        canonical_provider: :external_provider_name,
        aliases: [:external_alias],
        display_name: "External Provider Name"
      )
      expect(metadata[:identity]).to include(
        bot_usernames: ["external_provider_name", "external_alias"]
      )
    end

    it "does not allow adapter metadata overrides to forge registry identity fields" do
      custom_provider = Class.new do
        include AgentHarness::Providers::Adapter

        class << self
          def provider_name = :internal_provider_name
          def available? = true
          def binary_name = "internal-provider"

          def provider_metadata_overrides
            {
              provider: :forged_provider,
              canonical_provider: :forged_canonical_provider,
              aliases: [:forged_alias],
              binary_name: "forged-binary",
              identity: {
                bot_usernames: ["custom-bot"]
              }
            }
          end
        end
      end

      registry.register(:external_provider_name, custom_provider, aliases: [:external_alias])

      metadata = registry.provider_metadata(:external_alias)

      expect(metadata).to include(
        provider: :external_provider_name,
        canonical_provider: :external_provider_name,
        aliases: [:external_alias],
        binary_name: "internal-provider"
      )
      expect(metadata[:identity]).to eq(
        bot_usernames: ["custom-bot"]
      )
    end

    it "uses the registry canonical key for display when a custom provider inherits Base defaults" do
      custom_provider = Class.new(AgentHarness::Providers::Base) do
        class << self
          def provider_name = :internal_provider_name
          def available? = true
          def binary_name = "internal-provider"
        end
      end

      registry.register(:external_provider_name, custom_provider, aliases: [:external_alias])

      metadata = registry.provider_metadata(:external_alias)

      expect(metadata).to include(
        provider: :external_provider_name,
        canonical_provider: :external_provider_name,
        aliases: [:external_alias],
        display_name: "External Provider Name"
      )
    end

    it "does not report auth checks for custom Anthropic registrations unsupported by Authentication" do
      registry.register(:external_provider_name, AgentHarness::Providers::Anthropic, aliases: [:external_alias])

      metadata = registry.provider_metadata(:external_provider_name)

      expect(metadata[:health_check]).to include(
        supports_registry_checks: true,
        auth_check_supported: false
      )
    end

    it "does not report auth checks for custom oauth providers without auth_status" do
      custom_oauth_provider = Class.new do
        include AgentHarness::Providers::Adapter

        class << self
          def provider_name = :custom_oauth_provider
          def available? = true
          def binary_name = "custom-oauth"
        end

        def initialize(config: nil)
          @config = config
        end

        def auth_type
          :oauth
        end
      end

      registry.register(:custom_oauth_provider, custom_oauth_provider)

      metadata = registry.provider_metadata(:custom_oauth_provider)

      expect(metadata[:health_check]).to include(
        supports_registry_checks: true,
        auth_check_supported: false
      )
    end

    it "preserves Anthropic bot identities for custom registrations" do
      registry.register(:external_provider_name, AgentHarness::Providers::Anthropic, aliases: [:external_alias])

      metadata = registry.provider_metadata(:external_alias)

      expect(metadata).to include(
        provider: :external_provider_name,
        canonical_provider: :external_provider_name,
        aliases: [:external_alias]
      )
      expect(metadata[:identity]).to eq(
        bot_usernames: ["claude", "anthropic"]
      )
    end

    it "uses canonical-name config for custom registrations when requested-name config is absent" do
      custom_provider = Class.new do
        include AgentHarness::Providers::Adapter

        class << self
          def provider_name = :internal_provider_name
          def available? = true
          def binary_name = "internal-provider"
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
      end

      AgentHarness.configuration.providers[:external_provider_name] =
        AgentHarness::ProviderConfig.new(:external_provider_name)
      registry.register(:external_provider_name, custom_provider, aliases: [:external_alias])

      metadata = registry.provider_metadata(:external_alias)

      expect(metadata[:configuration]).to include(
        fields: [{name: :external_provider_name, type: :string}],
        auth_modes: [:api_key],
        openai_compatible: false
      )
    ensure
      AgentHarness.configuration.providers.delete(:external_provider_name)
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
        supports_registry_checks: true,
        provider_status: false,
        configuration_validation: false,
        lightweight: true
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

    it "falls back to default sections when instance metadata hooks raise" do
      provider_with_raising_hooks = Class.new do
        include AgentHarness::Providers::Adapter

        class << self
          def provider_name = :provider_with_raising_hooks
          def available? = true
          def binary_name = "raising-hooks"
        end

        def initialize(config: nil)
          @config = config
        end

        def configuration_schema
          raise "boom"
        end

        def execution_semantics
          raise "boom"
        end

        def capabilities
          raise "boom"
        end
      end

      logger = instance_double("Logger", debug: nil)
      allow(AgentHarness).to receive(:logger).and_return(logger)
      registry.register(:provider_with_raising_hooks, provider_with_raising_hooks)

      metadata = registry.provider_metadata(:provider_with_raising_hooks)

      expect(metadata[:configuration]).to eq(
        fields: [],
        auth_modes: [:api_key],
        openai_compatible: false
      )
      expect(metadata[:runtime]).to include(
        prompt_delivery: :arg,
        output_format: :text,
        sandbox_aware: false,
        uses_subcommand: false
      )
      expect(metadata[:capabilities]).to eq(
        streaming: false,
        file_upload: false,
        vision: false,
        tool_use: false,
        json_mode: false,
        mcp: false,
        dangerous_mode: false
      )
      expect(logger).to have_received(:debug).with(
        include("Falling back to default configuration_schema metadata for provider_with_raising_hooks: RuntimeError")
      )
      expect(logger).to have_received(:debug).with(
        include("Falling back to default execution_semantics metadata for provider_with_raising_hooks: RuntimeError")
      )
      expect(logger).to have_received(:debug).with(
        include("Falling back to default capabilities metadata for provider_with_raising_hooks: RuntimeError")
      )
    end

    it "raises ConfigurationError for unknown providers" do
      expect {
        registry.provider_metadata(:nonexistent_provider_xyz)
      }.to raise_error(AgentHarness::ConfigurationError, /Unknown provider/)
    end

    it "raises ConfigurationError for unknown providers with refresh: true" do
      expect {
        registry.provider_metadata(:nonexistent_provider_xyz, refresh: true)
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

    it "clears registry metadata caches once before a full catalog refresh" do
      registry.provider_metadata_catalog

      allow(registry).to receive(:clear_registry_metadata_cache!).and_call_original
      allow(registry).to receive(:invalidate_provider_metadata_cache!).and_call_original

      registry.provider_metadata_catalog(refresh: true)

      expect(registry).to have_received(:clear_registry_metadata_cache!).once
      expect(registry).not_to have_received(:invalidate_provider_metadata_cache!)
    end

    it "caches full metadata across catalog reads and returns defensive copies" do
      metadata_provider = Class.new do
        class << self
          attr_accessor :provider_metadata_calls

          def provider_name = :metadata_provider
          def available? = true
          def binary_name = "metadata"

          def provider_metadata(**)
            self.provider_metadata_calls ||= 0
            self.provider_metadata_calls += 1

            {
              provider: :metadata_provider,
              canonical_provider: :metadata_provider,
              aliases: [],
              display_name: "Metadata Provider",
              binary_name: "metadata",
              auth: {
                default_mode: nil,
                supported_modes: [],
                service: nil,
                api_family: nil
              },
              runtime: {
                interface: :cli,
                requires_cli: true,
                available: true,
                installable: false,
                installation: nil,
                prompt_delivery: nil,
                output_format: nil,
                sandbox_aware: nil,
                uses_subcommand: nil,
                supports_mcp: false,
                supported_mcp_transports: [],
                supports_sessions: false,
                supports_dangerous_mode: false
              },
              configuration: {
                fields: [],
                auth_modes: [],
                openai_compatible: false
              },
              capabilities: {
                streaming: false,
                file_upload: false,
                vision: false,
                tool_use: false,
                json_mode: false,
                mcp: false,
                dangerous_mode: false
              },
              health_check: {
                supports_registry_checks: false,
                auth_check_supported: false,
                provider_status: false,
                configuration_validation: false,
                lightweight: false
              },
              identity: {
                bot_usernames: ["metadata_provider"]
              }
            }
          end
        end
      end

      registry.register(:metadata_provider, metadata_provider)

      first_catalog = registry.provider_metadata_catalog
      first_catalog[:metadata_provider][:identity][:bot_usernames] << "mutated"

      second_catalog = registry.provider_metadata_catalog

      expect(metadata_provider.provider_metadata_calls).to eq(1)
      expect(second_catalog[:metadata_provider][:identity]).to eq(
        bot_usernames: ["metadata_provider"]
      )

      registry.provider_metadata_catalog(refresh: true)

      expect(metadata_provider.provider_metadata_calls).to eq(2)
    end

    it "returns defensive copies for mutable string leaves" do
      metadata = registry.provider_metadata(:codex)
      original_display_name = metadata[:display_name].dup
      metadata[:display_name].replace("Mutated display")

      expect(registry.provider_metadata(:codex)[:display_name]).to eq(original_display_name)
    end

    it "keeps catalog enumeration stable when display_name or auth_type hooks raise" do
      unstable_metadata_provider = Class.new do
        include AgentHarness::Providers::Adapter

        class << self
          def provider_name = :unstable_metadata_provider
          def available? = true
          def binary_name = "unstable-metadata"
        end

        def initialize(config: nil)
          @config = config
        end

        def configuration_schema
          {
            fields: [],
            auth_modes: %i[api_key oauth],
            openai_compatible: false
          }
        end

        def display_name
          raise "boom"
        end

        def auth_type
          raise "boom"
        end
      end

      registry.register(:unstable_metadata_provider, unstable_metadata_provider)

      metadata = registry.provider_metadata_catalog.fetch(:unstable_metadata_provider)

      expect(metadata[:display_name]).to eq("Unstable Metadata Provider")
      expect(metadata[:auth]).to include(
        default_mode: :api_key,
        supported_modes: %i[api_key oauth]
      )
    end

    it "invalidates the cached catalog when a single provider metadata entry is refreshed" do
      metadata_provider = Class.new do
        class << self
          attr_accessor :available_flag

          def provider_name = :metadata_provider
          def available? = available_flag
          def binary_name = "metadata"
        end
      end
      metadata_provider.available_flag = true

      registry.register(:metadata_provider, metadata_provider)

      expect(registry.provider_metadata_catalog.dig(:metadata_provider, :runtime, :available)).to be true

      metadata_provider.available_flag = false

      expect(registry.provider_metadata(:metadata_provider, refresh: true).dig(:runtime, :available)).to be false
      expect(registry.provider_metadata_catalog.dig(:metadata_provider, :runtime, :available)).to be false
    end

    it "invalidates sibling cache entries for the same canonical provider on refresh" do
      metadata_provider = Class.new do
        class << self
          attr_accessor :available_flag

          def provider_name = :metadata_provider
          def available? = available_flag
          def binary_name = "metadata"
        end
      end
      metadata_provider.available_flag = true

      registry.register(:metadata_provider, metadata_provider, aliases: [:metadata_alias])

      expect(registry.provider_metadata(:metadata_provider).dig(:runtime, :available)).to be true
      expect(registry.provider_metadata(:metadata_alias).dig(:runtime, :available)).to be true
      expect(registry.provider_metadata_catalog.dig(:metadata_provider, :runtime, :available)).to be true

      metadata_provider.available_flag = false

      expect(registry.provider_metadata(:metadata_alias, refresh: true).dig(:runtime, :available)).to be false
      expect(registry.provider_metadata(:metadata_provider).dig(:runtime, :available)).to be false
      expect(registry.provider_metadata_catalog.dig(:metadata_provider, :runtime, :available)).to be false
    end

    it "invalidates sibling auth metadata caches for the same canonical provider on refresh" do
      metadata_provider = Class.new do
        include AgentHarness::Providers::Adapter

        class << self
          def provider_name = :auth_cache_provider
          def available? = true
          def binary_name = "metadata"
        end

        def initialize(config: nil)
          @config = config
        end
      end

      provider_config = AgentHarness::ProviderConfig.new(:auth_cache_provider)
      AgentHarness.configuration.providers[:auth_cache_provider] = provider_config
      registry.register(:auth_cache_provider, metadata_provider, aliases: [:metadata_alias])

      initial = registry.provider_metadata(:auth_cache_provider).dig(:runtime, :available)
      initial_alias = registry.provider_metadata(:metadata_alias).dig(:runtime, :available)

      expect(initial).to eq(initial_alias)

      allow(metadata_provider).to receive(:available?).and_return(!initial)

      refreshed = registry.provider_metadata(:metadata_alias, refresh: true).dig(:runtime, :available)
      canonical = registry.provider_metadata(:auth_cache_provider).dig(:runtime, :available)

      expect(refreshed).to eq(!initial)
      expect(canonical).to eq(!initial)
    ensure
      AgentHarness.configuration.providers.delete(:auth_cache_provider)
    end

    it "clears alias-scoped auth metadata caches during full catalog refresh" do
      metadata_provider = Class.new do
        include AgentHarness::Providers::Adapter

        class << self
          def provider_name = :auth_cache_provider
          def available? = true
          def binary_name = "metadata"
        end

        def initialize(config: nil)
          @config = config
        end
      end

      provider_config = AgentHarness::ProviderConfig.new(:auth_cache_provider)
      AgentHarness.configuration.providers[:auth_cache_provider] = provider_config
      registry.register(:auth_cache_provider, metadata_provider, aliases: [:metadata_alias])

      initial = registry.provider_metadata(:metadata_alias).dig(:runtime, :available)
      initial_canonical = registry.provider_metadata(:auth_cache_provider).dig(:runtime, :available)

      expect(initial).to eq(initial_canonical)

      allow(metadata_provider).to receive(:available?).and_return(!initial)
      registry.provider_metadata_catalog(refresh: true)

      expect(registry.provider_metadata(:metadata_alias).dig(:runtime, :available)).to eq(!initial)
      expect(registry.provider_metadata(:auth_cache_provider).dig(:runtime, :available)).to eq(!initial)
    ensure
      AgentHarness.configuration.providers.delete(:auth_cache_provider)
    end
  end

  describe "#smoke_test_contract" do
    it "returns a provider smoke-test contract" do
      contract = registry.smoke_test_contract(:codex)

      expect(contract).to include(
        prompt: "Reply with exactly OK.",
        timeout: 30,
        require_output: true
      )
    end

    it "returns smoke test contract for github_copilot" do
      expect(registry.smoke_test_contract(:github_copilot)).to eq(AgentHarness::Providers::GithubCopilot::SMOKE_TEST_CONTRACT)
    end

    it "raises ConfigurationError for an unknown provider" do
      expect {
        registry.smoke_test_contract(:nonexistent_provider_xyz)
      }.to raise_error(AgentHarness::ConfigurationError, /Unknown provider/)
    end

    it "returns nil for a registered provider without smoke-test metadata" do
      registry.register(:test, Class.new do
        def self.provider_name = :test
        def self.available? = true
        def self.binary_name = "test"
      end)

      expect(registry.smoke_test_contract(:test)).to be_nil
    end
  end

  describe "#smoke_test_contracts" do
    it "returns providers with smoke-test contracts" do
      contracts = registry.smoke_test_contracts

      expect(contracts).to include(:codex)
      expect(contracts).to include(:github_copilot)
      expect(contracts[:codex][:prompt]).to eq("Reply with exactly OK.")
    end

    it "skips registered providers without smoke-test metadata" do
      registry.register(:test, Class.new do
        def self.provider_name = :test
        def self.available? = true
        def self.binary_name = "test"
      end)

      expect(registry.smoke_test_contracts).not_to include(:test)
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
