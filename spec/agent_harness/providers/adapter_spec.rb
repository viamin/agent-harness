# frozen_string_literal: true

RSpec.describe AgentHarness::Providers::Adapter do
  let(:adapter_class) do
    Class.new do
      include AgentHarness::Providers::Adapter

      class << self
        def provider_name
          :test_adapter
        end

        def available?
          true
        end

        def binary_name
          "test"
        end
      end

      def send_message(prompt:, **options)
        AgentHarness::Response.new(
          output: "response",
          exit_code: 0,
          duration: 1.0,
          provider: :test_adapter
        )
      end
    end
  end

  let(:adapter) { adapter_class.new }
  let(:installing_adapter_class) do
    Class.new do
      include AgentHarness::Providers::Adapter

      class << self
        def provider_name
          :installing_adapter
        end

        def available?
          true
        end

        def binary_name
          "installer"
        end

        def installation_contract
          {
            package: "@scope/pkg@1.0.0",
            package_name: "@scope/pkg",
            install_command_prefix: ["npm", "install", "-g"],
            install_command: ["npm", "install", "-g", "@scope/pkg@1.0.0"]
          }
        end
      end
    end
  end

  let(:required_initializer_adapter_class) do
    Class.new do
      include AgentHarness::Providers::Adapter

      class << self
        def provider_name
          :required_initializer_adapter
        end

        def available?
          true
        end

        def binary_name
          "required"
        end
      end

      def initialize(required:)
        @required = required
      end
    end
  end

  let(:registry_compatible_adapter_class) do
    Class.new do
      include AgentHarness::Providers::Adapter

      class << self
        def provider_name
          :registry_compatible_adapter
        end

        def available?
          true
        end

        def binary_name
          "registry-compatible"
        end
      end

      def initialize(config: nil, executor: nil, logger: nil)
        @config = config
        @executor = executor
        @logger = logger
      end

      def display_name
        "Registry compatible adapter"
      end

      def auth_type
        :oauth
      end

      def configuration_schema
        {
          fields: [{name: :workspace, type: :string}],
          auth_modes: [:oauth],
          openai_compatible: true
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

      def supports_mcp?
        true
      end

      def supported_mcp_transports
        [:stdio]
      end

      def supports_sessions?
        true
      end

      def supports_dangerous_mode?
        true
      end
    end
  end

  let(:metadata_compatible_adapter_class) do
    Class.new do
      include AgentHarness::Providers::Adapter

      class << self
        def provider_name
          :metadata_compatible_adapter
        end

        def available?
          true
        end

        def binary_name
          "metadata-compatible"
        end
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
  end

  let(:config_sensitive_adapter_class) do
    Class.new do
      include AgentHarness::Providers::Adapter

      class << self
        def provider_name
          :config_sensitive_adapter
        end

        def available?
          true
        end

        def binary_name
          "config-sensitive"
        end
      end

      def initialize(config:)
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
          prompt_delivery: @config.name
        }
      end
    end
  end

  let(:oauth_supported_adapter_class) do
    Class.new do
      include AgentHarness::Providers::Adapter

      class << self
        def provider_name
          :oauth_supported_adapter
        end

        def available?
          true
        end

        def binary_name
          "oauth-supported"
        end
      end

      def initialize(config: nil, executor: nil, logger: nil)
        @config = config
        @executor = executor
        @logger = logger
      end

      def name
        "claude"
      end

      def auth_type
        :oauth
      end
    end
  end

  let(:api_key_adapter_class) do
    Class.new do
      include AgentHarness::Providers::Adapter

      class << self
        def provider_name
          :api_key_adapter
        end

        def available?
          true
        end

        def binary_name
          "api-key"
        end
      end

      def initialize(config: nil, executor: nil, logger: nil)
        @config = config
        @executor = executor
        @logger = logger
      end

      def auth_type
        :api_key
      end
    end
  end

  let(:explicit_auth_status_adapter_class) do
    Class.new do
      include AgentHarness::Providers::Adapter

      class << self
        def provider_name
          :explicit_auth_status_adapter
        end

        def available?
          true
        end

        def binary_name
          "explicit-auth-status"
        end
      end

      def initialize(config: nil, executor: nil, logger: nil)
        @config = config
        @executor = executor
        @logger = logger
      end

      def auth_type
        :oauth
      end

      def auth_status
        {authenticated: true}
      end
    end
  end

  let(:auth_status_cached_adapter_class) do
    Class.new do
      include AgentHarness::Providers::Adapter

      class << self
        attr_accessor :initialization_count

        def provider_name
          :auth_status_cached_adapter
        end

        def available?
          true
        end

        def binary_name
          "auth-status-cached"
        end
      end

      self.initialization_count = 0

      def initialize(config: nil, executor: nil, logger: nil)
        self.class.initialization_count += 1
        @config = config
        @executor = executor
        @logger = logger
      end

      def auth_type
        :api_key
      end
    end
  end

  let(:raising_metadata_adapter_class) do
    Class.new do
      include AgentHarness::Providers::Adapter

      class << self
        def provider_name
          :raising_metadata_adapter
        end

        def available?
          true
        end

        def binary_name
          "raising-metadata"
        end
      end

      def initialize(config: nil)
        raise ArgumentError, "invalid config"
      end
    end
  end

  let(:package_only_installing_adapter_class) do
    Class.new do
      include AgentHarness::Providers::Adapter

      class << self
        def provider_name
          :package_only_installing_adapter
        end

        def available?
          true
        end

        def binary_name
          "installer"
        end

        def installation_contract
          {
            package: "@scope/pkg@1.0.0",
            install_command_prefix: ["npm", "install", "-g"],
            install_command: ["npm", "install", "-g", "@scope/pkg@1.0.0"]
          }
        end
      end
    end
  end

  let(:legacy_install_contract_adapter_class) do
    Class.new do
      include AgentHarness::Providers::Adapter

      class << self
        def provider_name
          :legacy_install_contract_adapter
        end

        def available?
          true
        end

        def binary_name
          "legacy-installer"
        end

        def install_contract(version: "1.0.0")
          {
            package_name: "@scope/legacy-installer",
            binary_name: binary_name,
            resolved_version: version
          }
        end
      end
    end
  end

  describe "ClassMethods" do
    describe ".provider_name" do
      it "returns the provider name" do
        expect(adapter_class.provider_name).to eq(:test_adapter)
      end
    end

    describe ".available?" do
      it "returns availability" do
        expect(adapter_class.available?).to be true
      end
    end

    describe ".binary_name" do
      it "returns the binary name" do
        expect(adapter_class.binary_name).to eq("test")
      end
    end

    describe ".install_contract" do
      it "returns nil by default" do
        expect(adapter_class.install_contract).to be_nil
      end

      it "accepts an optional version keyword and still returns nil" do
        expect(adapter_class.install_contract(version: "1.2.3")).to be_nil
      end
    end

    describe ".firewall_requirements" do
      it "returns default empty requirements" do
        expect(adapter_class.firewall_requirements).to eq({domains: [], ip_ranges: []})
      end
    end

    describe ".instruction_file_paths" do
      it "returns empty array by default" do
        expect(adapter_class.instruction_file_paths).to eq([])
      end
    end

    describe ".discover_models" do
      it "returns empty array by default" do
        expect(adapter_class.discover_models).to eq([])
      end
    end

    describe ".installation_contract" do
      it "returns nil by default" do
        expect(adapter_class.installation_contract).to be_nil
      end

      it "ignores forwarded keyword arguments by default" do
        expect(adapter_class.installation_contract(version: "1.2.3")).to be_nil
      end

      it "falls back to the legacy install_contract API" do
        expect(legacy_install_contract_adapter_class.installation_contract).to include(
          package_name: "@scope/legacy-installer",
          resolved_version: "1.0.0"
        )
      end

      it "forwards the version option to the legacy install_contract API" do
        expect(legacy_install_contract_adapter_class.installation_contract(version: "2.3.4")).to include(
          resolved_version: "2.3.4"
        )
      end
    end

    describe ".provider_metadata" do
      it "returns a stable metadata contract" do
        metadata = adapter_class.provider_metadata(aliases: [:test_alias])

        expect(metadata).to include(
          provider: :test_adapter,
          canonical_provider: :test_adapter,
          aliases: [:test_alias],
          display_name: "Test adapter",
          binary_name: "test"
        )
        expect(metadata[:auth]).to include(
          default_mode: :api_key,
          supported_modes: [:api_key],
          service: :test_adapter,
          api_family: :test_adapter
        )
        expect(metadata[:runtime]).to include(
          interface: :cli,
          requires_cli: true,
          available: true,
          installable: false,
          prompt_delivery: :arg,
          output_format: :text,
          sandbox_aware: false,
          uses_subcommand: false,
          supports_mcp: false,
          supports_sessions: false,
          supports_dangerous_mode: false
        )
        expect(metadata[:runtime][:supported_mcp_transports]).to eq([])
        expect(metadata[:configuration]).to include(
          fields: [],
          auth_modes: [:api_key],
          openai_compatible: false
        )
        expect(metadata[:capabilities]).to include(
          streaming: false,
          mcp: false
        )
        expect(metadata[:health_check]).to include(
          supports_registry_checks: false,
          provider_status: false,
          configuration_validation: false,
          lightweight: false
        )
        expect(metadata[:identity]).to eq(
          bot_usernames: ["test_adapter", "test_alias"]
        )
      end

      it "reports registry checks for adapters with a compatible initializer contract" do
        command_executor = instance_double("AgentHarness::CommandExecutor")
        allow(AgentHarness.configuration).to receive(:command_executor).and_return(command_executor)
        allow(AgentHarness).to receive(:logger).and_return(instance_double("Logger"))

        metadata = registry_compatible_adapter_class.provider_metadata

        expect(metadata).to include(
          display_name: "Registry compatible adapter"
        )
        expect(metadata[:auth]).to include(
          default_mode: :oauth,
          supported_modes: [:oauth],
          api_family: :openai
        )
        expect(metadata[:runtime]).to include(
          prompt_delivery: :stdin,
          output_format: :json,
          sandbox_aware: true,
          uses_subcommand: true,
          supports_mcp: true,
          supports_sessions: true,
          supports_dangerous_mode: true
        )
        expect(metadata[:runtime][:supported_mcp_transports]).to eq([:stdio])
        expect(metadata[:configuration]).to include(
          fields: [{name: :workspace, type: :string}],
          auth_modes: [:oauth],
          openai_compatible: true
        )
        expect(metadata[:capabilities]).to include(
          streaming: true,
          tool_use: true
        )
        expect(metadata[:health_check]).to include(
          supports_registry_checks: true,
          auth_check_supported: false,
          provider_status: false,
          configuration_validation: false,
          lightweight: true
        )
      end

      it "does not report auth checks for api key adapters without auth_status support" do
        metadata = api_key_adapter_class.provider_metadata

        expect(metadata[:health_check]).to include(
          auth_check_supported: false
        )
      end

      it "reports auth checks for adapters that implement auth_status directly" do
        metadata = explicit_auth_status_adapter_class.provider_metadata

        expect(metadata[:health_check]).to include(
          auth_check_supported: true
        )
      end

      it "reports auth checks for supported oauth providers" do
        metadata = oauth_supported_adapter_class.provider_metadata

        expect(metadata[:health_check]).to include(
          auth_check_supported: false
        )
      end

      it "does not report auth checks for subset-safe adapters that cannot satisfy the runtime auth constructor" do
        subset_safe_auth_adapter_class = Class.new do
          include AgentHarness::Providers::Adapter

          class << self
            def provider_name
              :subset_safe_auth_adapter
            end

            def available?
              true
            end

            def binary_name
              "subset-safe-auth"
            end
          end

          def initialize(config: nil)
            @config = config
          end

          def auth_type
            :oauth
          end

          def auth_status
            {valid: true, expires_at: nil, error: nil}
          end
        end

        metadata = subset_safe_auth_adapter_class.provider_metadata

        expect(metadata[:health_check]).to include(
          supports_registry_checks: false,
          auth_check_supported: false
        )
      end

      it "does not require parameterless construction to expose metadata" do
        metadata = required_initializer_adapter_class.provider_metadata(aliases: [:required_alias])

        expect(metadata).to include(
          provider: :required_initializer_adapter,
          canonical_provider: :required_initializer_adapter,
          aliases: [:required_alias],
          display_name: "Required initializer adapter",
          binary_name: "required"
        )
        expect(metadata[:auth]).to include(
          default_mode: :api_key,
          supported_modes: [:api_key],
          service: :required_initializer_adapter,
          api_family: :required_initializer_adapter
        )
        expect(metadata[:runtime]).to include(
          available: true,
          installable: false,
          supports_mcp: false,
          supports_sessions: false,
          supports_dangerous_mode: false
        )
        expect(metadata[:configuration]).to include(
          fields: [],
          auth_modes: [:api_key],
          openai_compatible: false
        )
        expect(metadata[:identity]).to eq(
          bot_usernames: ["required_initializer_adapter", "required_alias"]
        )
        expect(metadata[:health_check]).to include(
          supports_registry_checks: false,
          provider_status: false,
          configuration_validation: false,
          lightweight: false
        )
      end

      it "instantiates metadata for adapters that accept a registry keyword subset" do
        metadata = metadata_compatible_adapter_class.provider_metadata(aliases: [:metadata_alias])

        expect(metadata).to include(
          display_name: "Metadata compatible adapter"
        )
        expect(metadata[:auth]).to include(
          default_mode: :oauth,
          supported_modes: [:oauth],
          api_family: :metadata_compatible_adapter
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
        expect(metadata[:identity]).to eq(
          bot_usernames: ["metadata_compatible_adapter", "metadata_alias"]
        )
      end

      it "passes a real provider config into metadata-safe adapter construction" do
        provider_config = AgentHarness::ProviderConfig.new(:config_sensitive_adapter)
        AgentHarness.configuration.providers[:config_sensitive_adapter] = provider_config

        metadata = config_sensitive_adapter_class.provider_metadata

        expect(metadata[:configuration]).to include(
          fields: [{name: :config_sensitive_adapter, type: :string}],
          auth_modes: [:api_key],
          openai_compatible: false
        )
        expect(metadata[:runtime]).to include(
          prompt_delivery: :config_sensitive_adapter
        )
      ensure
        AgentHarness.configuration.providers.delete(:config_sensitive_adapter)
      end

      it "falls back to default metadata when safe construction raises" do
        logger = instance_double("Logger", debug: nil)
        allow(AgentHarness).to receive(:logger).and_return(logger)

        metadata = raising_metadata_adapter_class.provider_metadata(aliases: [:raising_alias])

        expect(metadata).to include(
          provider: :raising_metadata_adapter,
          canonical_provider: :raising_metadata_adapter,
          aliases: [:raising_alias],
          display_name: "Raising metadata adapter",
          binary_name: "raising-metadata"
        )
        expect(metadata[:auth]).to include(
          default_mode: :api_key,
          supported_modes: [:api_key]
        )
        expect(metadata[:configuration]).to include(
          fields: [],
          auth_modes: [:api_key],
          openai_compatible: false
        )
        expect(logger).to have_received(:debug).with(
          include("Falling back to default metadata for raising_metadata_adapter: ArgumentError: invalid config")
        )
      end

      it "caches runtime availability until explicitly refreshed" do
        calls = 0
        allow(adapter_class).to receive(:available?) do
          calls += 1
          true
        end

        expect(adapter_class.provider_metadata[:runtime][:available]).to be true
        expect(adapter_class.provider_metadata[:runtime][:available]).to be true
        expect(calls).to eq(1)

        expect(adapter_class.provider_metadata(refresh: true)[:runtime][:available]).to be true
        expect(calls).to eq(2)
      end

      it "memoizes auth status availability for repeated checks" do
        expect(auth_status_cached_adapter_class.send(:auth_status_available?)).to be false
        expect(auth_status_cached_adapter_class.send(:auth_status_available?)).to be false
        expect(auth_status_cached_adapter_class.initialization_count).to eq(1)
      end

      it "normalizes direct alias input into a stable contract" do
        metadata = adapter_class.provider_metadata(
          aliases: [:test_alias, " test_alias ", :test_adapter, " ", nil, "second_alias"]
        )

        expect(metadata[:aliases]).to eq([:test_alias, :second_alias])
        expect(metadata[:identity]).to eq(
          bot_usernames: ["test_adapter", "test_alias", "second_alias"]
        )
      end
    end

    describe ".install_command" do
      it "returns nil by default" do
        expect(adapter_class.install_command).to be_nil
      end

      it "returns the contract install_command when no override is provided" do
        expect(installing_adapter_class.install_command).to eq(
          ["npm", "install", "-g", "@scope/pkg@1.0.0"]
        )
      end

      it "builds an explicit version override from package_name" do
        expect(installing_adapter_class.install_command(version: "1.2.3")).to eq(
          ["npm", "install", "-g", "@scope/pkg@1.2.3"]
        )
      end

      it "raises when version override is requested without package_name" do
        expect {
          package_only_installing_adapter_class.install_command(version: "1.2.3")
        }.to raise_error(ArgumentError, /must define :package_name/)
      end
    end
  end

  describe "Instance methods" do
    describe "#send_message" do
      it "returns a Response" do
        response = adapter.send_message(prompt: "test")
        expect(response).to be_a(AgentHarness::Response)
      end
    end

    describe "#configuration_schema" do
      it "returns a hash with required keys" do
        schema = adapter.configuration_schema
        expect(schema).to be_a(Hash)
        expect(schema).to have_key(:fields)
        expect(schema).to have_key(:auth_modes)
        expect(schema).to have_key(:openai_compatible)
      end

      it "returns empty fields by default" do
        expect(adapter.configuration_schema[:fields]).to eq([])
      end

      it "returns api_key auth mode by default" do
        expect(adapter.configuration_schema[:auth_modes]).to eq([:api_key])
      end

      it "derives auth_modes from auth_type" do
        allow(adapter).to receive(:auth_type).and_return(:oauth)
        expect(adapter.configuration_schema[:auth_modes]).to eq([:oauth])
      end

      it "returns false for openai_compatible by default" do
        expect(adapter.configuration_schema[:openai_compatible]).to be false
      end
    end

    describe "#capabilities" do
      it "returns default capabilities" do
        caps = adapter.capabilities
        expect(caps).to be_a(Hash)
        expect(caps).to have_key(:streaming)
        expect(caps).to have_key(:mcp)
      end
    end

    describe "#error_patterns" do
      it "returns empty hash by default" do
        expect(adapter.error_patterns).to eq({})
      end
    end

    describe "#auth_type" do
      it "returns :api_key by default" do
        expect(adapter.auth_type).to eq(:api_key)
      end
    end

    describe "#supports_mcp?" do
      it "returns false by default" do
        expect(adapter.supports_mcp?).to be false
      end
    end

    describe "#fetch_mcp_servers" do
      it "returns empty array by default" do
        expect(adapter.fetch_mcp_servers).to eq([])
      end
    end

    describe "#supports_dangerous_mode?" do
      it "returns false by default" do
        expect(adapter.supports_dangerous_mode?).to be false
      end
    end

    describe "#dangerous_mode_flags" do
      it "returns empty array by default" do
        expect(adapter.dangerous_mode_flags).to eq([])
      end
    end

    describe "#supports_sessions?" do
      it "returns false by default" do
        expect(adapter.supports_sessions?).to be false
      end
    end

    describe "#session_flags" do
      it "returns empty array by default" do
        expect(adapter.session_flags("session-123")).to eq([])
      end
    end

    describe "#validate_config" do
      it "returns valid by default" do
        result = adapter.validate_config
        expect(result[:valid]).to be true
        expect(result[:errors]).to eq([])
      end
    end

    describe "#health_status" do
      it "returns healthy by default" do
        status = adapter.health_status
        expect(status[:healthy]).to be true
        expect(status[:message]).to eq("OK")
      end
    end

    describe "#execution_semantics" do
      it "returns a hash with required keys" do
        semantics = adapter.execution_semantics
        expect(semantics).to be_a(Hash)
        expect(semantics).to have_key(:prompt_delivery)
        expect(semantics).to have_key(:output_format)
        expect(semantics).to have_key(:sandbox_aware)
        expect(semantics).to have_key(:uses_subcommand)
        expect(semantics).to have_key(:non_interactive_flag)
        expect(semantics).to have_key(:legitimate_exit_codes)
        expect(semantics).to have_key(:stderr_is_diagnostic)
        expect(semantics).to have_key(:parses_rate_limit_reset)
      end

      it "returns sensible defaults" do
        semantics = adapter.execution_semantics
        expect(semantics[:prompt_delivery]).to eq(:arg)
        expect(semantics[:output_format]).to eq(:text)
        expect(semantics[:sandbox_aware]).to be false
        expect(semantics[:legitimate_exit_codes]).to eq([0])
      end
    end

    describe "#parse_rate_limit_reset" do
      it "returns nil by default" do
        expect(adapter.parse_rate_limit_reset("rate limit exceeded")).to be_nil
      end
    end
  end
end
