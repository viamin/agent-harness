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
  end

  describe "Instance methods" do
    describe "#send_message" do
      it "returns a Response" do
        response = adapter.send_message(prompt: "test")
        expect(response).to be_a(AgentHarness::Response)
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
  end
end
