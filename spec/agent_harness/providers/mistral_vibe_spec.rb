# frozen_string_literal: true

RSpec.describe AgentHarness::Providers::MistralVibe do
  describe ".provider_name" do
    it "returns :mistral_vibe" do
      expect(described_class.provider_name).to eq(:mistral_vibe)
    end
  end

  describe ".binary_name" do
    it "returns mistral-vibe" do
      expect(described_class.binary_name).to eq("mistral-vibe")
    end
  end

  describe ".firewall_requirements" do
    it "returns Mistral API domain" do
      requirements = described_class.firewall_requirements
      expect(requirements[:domains]).to eq(["api.mistral.ai"])
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
      it "returns mistral_vibe" do
        expect(provider.name).to eq("mistral_vibe")
      end
    end

    describe "#display_name" do
      it "returns Mistral Vibe CLI" do
        expect(provider.display_name).to eq("Mistral Vibe CLI")
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
      it "executes mistral-vibe run with the prompt" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        expect(mock_executor).to receive(:execute).with(
          ["mistral-vibe", "run", "Hello"],
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
