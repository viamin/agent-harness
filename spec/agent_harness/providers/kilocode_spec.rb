# frozen_string_literal: true

RSpec.describe AgentHarness::Providers::Kilocode do
  describe ".provider_name" do
    it "returns :kilocode" do
      expect(described_class.provider_name).to eq(:kilocode)
    end
  end

  describe ".binary_name" do
    it "returns kilo" do
      expect(described_class.binary_name).to eq("kilo")
    end
  end

  describe ".installation_contract" do
    it "returns the upstream install contract" do
      contract = described_class.installation_contract

      expect(contract[:source]).to eq({
        type: :npm,
        package: "@kilocode/cli"
      })
      expect(contract[:install_command]).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "@kilocode/cli@7.1.3"]
      )
      expect(contract[:binary_name]).to eq("kilo")
      expect(contract[:default_version]).to eq("7.1.3")
      expect(contract[:supported_version_requirement]).to eq("= 7.1.3")
    end

    it "can render an install command for an explicitly supported target" do
      contract = described_class.installation_contract(version: "7.1.3")

      expect(contract[:install_command]).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "@kilocode/cli@7.1.3"]
      )
    end

    it "rejects unsupported versions" do
      expect {
        described_class.installation_contract(version: "7.1.2")
      }.to raise_error(ArgumentError, /Unsupported Kilocode CLI version/)
    end
  end

  describe ".firewall_requirements" do
    it "returns empty arrays" do
      requirements = described_class.firewall_requirements
      expect(requirements[:domains]).to eq([])
      expect(requirements[:ip_ranges]).to eq([])
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
      it "returns kilocode" do
        expect(provider.name).to eq("kilocode")
      end
    end

    describe "#display_name" do
      it "returns Kilocode CLI" do
        expect(provider.display_name).to eq("Kilocode CLI")
      end
    end

    describe "#configuration_schema" do
      it "returns defaults with no configurable fields" do
        schema = provider.configuration_schema
        expect(schema[:fields]).to be_empty
        expect(schema[:auth_modes]).to eq([:api_key])
        expect(schema[:openai_compatible]).to be false
      end
    end

    describe "#capabilities" do
      it "returns minimal capabilities" do
        caps = provider.capabilities
        expect(caps[:streaming]).to be false
        expect(caps[:mcp]).to be false
        expect(caps[:dangerous_mode]).to be false
      end
    end

    describe "#send_message" do
      it "keeps the runtime binary aligned with the installation contract" do
        expect(described_class.installation_contract[:binary_name]).to eq(described_class.binary_name)
      end

      it "executes kilo run with the prompt" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        expect(mock_executor).to receive(:execute).with(
          ["kilo", "run", "Hello"],
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
