# frozen_string_literal: true

RSpec.describe AgentHarness::Providers::Opencode do
  describe ".provider_name" do
    it "returns :opencode" do
      expect(described_class.provider_name).to eq(:opencode)
    end
  end

  describe ".binary_name" do
    it "returns opencode" do
      expect(described_class.binary_name).to eq("opencode")
    end
  end

  describe ".installation_contract" do
    it "exposes OpenCode CLI install metadata" do
      contract = described_class.installation_contract

      expect(contract).to include(
        source: :npm,
        package_name: "opencode-ai",
        version: "1.3.2",
        binary_name: "opencode"
      )
      expect(contract[:package]).to eq("opencode-ai@1.3.2")
      expect(contract[:supported_versions]).to eq(["1.3.2"])
      expect(contract[:version_requirement]).to eq([">= 1.3.2", "< 1.4.0"])
      expect(contract[:install_command]).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "opencode-ai@1.3.2"]
      )
    end

    it "keeps the runtime binary aligned with the install contract" do
      contract = described_class.installation_contract

      expect(contract[:binary_name]).to eq(described_class.binary_name)
    end

    it "supports explicit versions within the advertised requirement" do
      contract = described_class.installation_contract(version: "1.3.9")

      expect(contract[:version]).to eq("1.3.9")
      expect(contract[:install_command]).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "opencode-ai@1.3.9"]
      )
    end

    it "rejects versions outside the advertised requirement" do
      expect {
        described_class.installation_contract(version: "1.4.0")
      }.to raise_error(ArgumentError, /Unsupported OpenCode CLI version/)
    end

    it "deep-freezes nested contract values" do
      contract = described_class.installation_contract

      expect { contract[:install_command_prefix] << "opencode-ai" }.to raise_error(FrozenError)
      expect { contract[:install_command] << "opencode-ai" }.to raise_error(FrozenError)
      expect { contract[:supported_versions] << "1.3.1" }.to raise_error(FrozenError)
      expect { contract[:version_requirement] << ">= 1.3.1" }.to raise_error(FrozenError)
    end
  end

  describe ".install_command" do
    it "builds the default install command from the contract" do
      expect(described_class.install_command).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "opencode-ai@1.3.2"]
      )
    end

    it "supports explicit version overrides" do
      expect(described_class.install_command(version: "1.3.9")).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "opencode-ai@1.3.9"]
      )
    end

    it "rejects unsupported version overrides" do
      expect {
        described_class.install_command(version: "1.3.1")
      }.to raise_error(ArgumentError, /Unsupported OpenCode CLI version/)
    end
  end

  describe ".firewall_requirements" do
    it "returns required domains" do
      requirements = described_class.firewall_requirements
      expect(requirements[:domains]).to include("api.openai.com")
    end
  end

  describe ".instruction_file_paths" do
    it "returns empty array" do
      expect(described_class.instruction_file_paths).to eq([])
    end
  end

  describe ".discover_models" do
    it "returns empty when not available" do
      allow(described_class).to receive(:available?).and_return(false)
      expect(described_class.discover_models).to eq([])
    end
  end

  describe "instance" do
    let(:mock_executor) do
      instance_double(AgentHarness::CommandExecutor)
    end

    subject(:provider) { described_class.new(executor: mock_executor) }

    describe "#name" do
      it "returns opencode" do
        expect(provider.name).to eq("opencode")
      end
    end

    describe "#display_name" do
      it "returns OpenCode CLI" do
        expect(provider.display_name).to eq("OpenCode CLI")
      end
    end

    describe "#configuration_schema" do
      it "has no configurable fields" do
        schema = provider.configuration_schema
        expect(schema[:fields]).to eq([])
      end

      it "reports openai_compatible as true" do
        expect(provider.configuration_schema[:openai_compatible]).to be true
      end

      it "uses api_key auth mode" do
        expect(provider.configuration_schema[:auth_modes]).to eq([:api_key])
      end
    end

    describe "#capabilities" do
      it "returns minimal capabilities" do
        caps = provider.capabilities
        expect(caps[:streaming]).to be false
        expect(caps[:mcp]).to be false
      end
    end

    describe "#send_message" do
      it "executes opencode run with the prompt" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        expect(mock_executor).to receive(:execute).with(
          ["opencode", "run", "Hello"],
          anything
        )

        provider.send_message(prompt: "Hello")
      end

      it "uses the install contract binary in the runtime command" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        binary = described_class.installation_contract[:binary_name]

        expect(mock_executor).to receive(:execute).with(
          [binary, "run", "Hello"],
          anything
        )

        provider.send_message(prompt: "Hello")
      end
    end

    describe "#error_patterns" do
      it "includes rate limit patterns" do
        expect(provider.error_patterns[:rate_limited]).not_to be_empty
      end

      it "includes auth patterns" do
        expect(provider.error_patterns[:auth_expired]).not_to be_empty
      end

      it "includes quota patterns" do
        expect(provider.error_patterns[:quota_exceeded]).not_to be_empty
      end

      it "includes transient patterns" do
        expect(provider.error_patterns[:transient]).not_to be_empty
      end
    end

    describe "#execution_semantics" do
      it "reports uses_subcommand as true" do
        expect(provider.execution_semantics[:uses_subcommand]).to be true
      end
    end
  end
end
