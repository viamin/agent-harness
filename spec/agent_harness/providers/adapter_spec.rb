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
