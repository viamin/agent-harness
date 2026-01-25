# frozen_string_literal: true

RSpec.describe AgentHarness::Providers::Gemini do
  describe ".provider_name" do
    it "returns :gemini" do
      expect(described_class.provider_name).to eq(:gemini)
    end
  end

  describe ".binary_name" do
    it "returns gemini" do
      expect(described_class.binary_name).to eq("gemini")
    end
  end

  describe ".available?" do
    let(:mock_executor) { instance_double(AgentHarness::CommandExecutor) }

    before do
      allow(AgentHarness.configuration).to receive(:command_executor).and_return(mock_executor)
    end

    it "returns true when gemini binary exists" do
      allow(mock_executor).to receive(:which).with("gemini").and_return("/usr/local/bin/gemini")
      expect(described_class.available?).to be true
    end

    it "returns false when gemini binary is missing" do
      allow(mock_executor).to receive(:which).with("gemini").and_return(nil)
      expect(described_class.available?).to be false
    end
  end

  describe ".firewall_requirements" do
    it "returns required domains" do
      requirements = described_class.firewall_requirements
      expect(requirements[:domains]).to include("generativelanguage.googleapis.com")
      expect(requirements[:ip_ranges]).to eq([])
    end
  end

  describe ".instruction_file_paths" do
    it "returns GEMINI.md" do
      paths = described_class.instruction_file_paths
      expect(paths.first[:path]).to eq("GEMINI.md")
    end
  end

  describe ".discover_models" do
    let(:mock_executor) { instance_double(AgentHarness::CommandExecutor) }

    before do
      allow(AgentHarness.configuration).to receive(:command_executor).and_return(mock_executor)
    end

    context "when gemini is available" do
      before do
        allow(mock_executor).to receive(:which).with("gemini").and_return("/usr/local/bin/gemini")
      end

      it "returns predefined models" do
        models = described_class.discover_models
        expect(models.size).to eq(4)
        expect(models.first[:name]).to eq("gemini-2.0-flash")
      end
    end

    context "when gemini is not available" do
      before do
        allow(mock_executor).to receive(:which).with("gemini").and_return(nil)
      end

      it "returns empty array" do
        expect(described_class.discover_models).to eq([])
      end
    end
  end

  describe ".model_family" do
    it "strips version suffix" do
      expect(described_class.model_family("gemini-1.5-pro-001")).to eq("gemini-1.5-pro")
    end

    it "returns unchanged if no version suffix" do
      expect(described_class.model_family("gemini-1.5-pro")).to eq("gemini-1.5-pro")
    end
  end

  describe ".provider_model_name" do
    it "returns family name unchanged" do
      expect(described_class.provider_model_name("gemini-1.5-pro")).to eq("gemini-1.5-pro")
    end
  end

  describe ".supports_model_family?" do
    it "returns true for models matching the pattern" do
      expect(described_class.supports_model_family?("gemini-1.5-pro")).to be true
      expect(described_class.supports_model_family?("gemini-2.0-flash")).to be true
    end

    it "returns true for any model starting with gemini-" do
      expect(described_class.supports_model_family?("gemini-custom")).to be true
    end

    it "returns false for non-Gemini models" do
      expect(described_class.supports_model_family?("claude-3-sonnet")).to be false
      expect(described_class.supports_model_family?("gpt-4")).to be false
    end
  end

  describe "instance" do
    let(:mock_executor) { instance_double(AgentHarness::CommandExecutor) }

    let(:config) do
      AgentHarness::ProviderConfig.new(:gemini).tap do |c|
        c.model = "gemini-1.5-pro"
        c.default_flags = ["--verbose"]
      end
    end

    subject(:provider) { described_class.new(config: config, executor: mock_executor) }

    describe "#name" do
      it "returns gemini" do
        expect(provider.name).to eq("gemini")
      end
    end

    describe "#display_name" do
      it "returns Google Gemini" do
        expect(provider.display_name).to eq("Google Gemini")
      end
    end

    describe "#capabilities" do
      it "includes expected capabilities" do
        caps = provider.capabilities
        expect(caps[:vision]).to be true
        expect(caps[:tool_use]).to be true
        expect(caps[:streaming]).to be true
        expect(caps[:mcp]).to be false
      end
    end

    describe "#error_patterns" do
      it "includes rate limit patterns" do
        patterns = provider.error_patterns
        expect(patterns[:rate_limited]).not_to be_empty
      end

      it "includes auth patterns" do
        patterns = provider.error_patterns
        expect(patterns[:auth_expired]).not_to be_empty
      end
    end

    describe "#send_message" do
      it "includes model when configured" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        expect(mock_executor).to receive(:execute).with(
          array_including("--model", "gemini-1.5-pro"),
          anything
        )

        provider.send_message(prompt: "Hello")
      end

      it "includes default flags" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        expect(mock_executor).to receive(:execute).with(
          array_including("--verbose"),
          anything
        )

        provider.send_message(prompt: "Hello")
      end

      context "without model configured" do
        let(:config) { AgentHarness::ProviderConfig.new(:gemini) }

        it "does not include model flag" do
          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: "response",
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          expect(mock_executor).to receive(:execute) do |cmd, _opts|
            expect(cmd).not_to include("--model")
          end.and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: "response",
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          provider.send_message(prompt: "Hello")
        end
      end
    end
  end
end
