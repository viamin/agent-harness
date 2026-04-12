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

    it "rejects malformed version strings with a provider-specific message" do
      expect {
        described_class.installation_contract(version: "not-a-version")
      }.to raise_error(ArgumentError, /Unsupported Kilocode CLI version/)
    end

    it "rejects nil version" do
      expect {
        described_class.installation_contract(version: nil)
      }.to raise_error(ArgumentError, /Unsupported Kilocode CLI version/)
    end

    it "rejects empty version" do
      expect {
        described_class.installation_contract(version: "")
      }.to raise_error(ArgumentError, /Unsupported Kilocode CLI version/)
    end

    it "preserves non-String version in error message" do
      expect {
        described_class.installation_contract(version: 42)
      }.to raise_error(ArgumentError, /Unsupported Kilocode CLI version 42/)
    end

    it "normalizes padded version strings in the install command" do
      contract = described_class.installation_contract(version: " 7.1.3 ")

      expect(contract[:install_command]).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "@kilocode/cli@7.1.3"]
      )
    end
  end

  describe ".install_command" do
    it "returns the install command for the default supported version" do
      expect(described_class.install_command).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "@kilocode/cli@7.1.3"]
      )
    end

    it "supports an explicit supported version" do
      expect(described_class.install_command(version: "7.1.3")).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "@kilocode/cli@7.1.3"]
      )
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

      it "executes kilo run with --format json and the prompt" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: '{"result":"response"}',
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        expect(mock_executor).to receive(:execute).with(
          ["kilo", "run", "--format", "json", "Hello"],
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

      it "reports output_format as json" do
        expect(provider.execution_semantics[:output_format]).to eq(:json)
      end
    end

    context "with token usage parsing" do
      it "extracts token usage from JSON output" do
        json_output = JSON.generate({
          "result" => "Hello! How can I help?",
          "usage" => {
            "input_tokens" => 100,
            "output_tokens" => 50
          }
        })

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: json_output,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Hello! How can I help?")
        expect(response.tokens).to eq({input: 100, output: 50, total: 150})
        expect(response.input_tokens).to eq(100)
        expect(response.output_tokens).to eq(50)
        expect(response.total_tokens).to eq(150)
      end

      it "handles JSON output without usage data" do
        json_output = JSON.generate({
          "result" => "Hello!"
        })

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: json_output,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Hello!")
        expect(response.tokens).to be_nil
      end

      it "handles non-JSON output gracefully" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "plain text response",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("plain text response")
        expect(response.tokens).to be_nil
      end

      it "handles JSON with usage containing only input tokens" do
        json_output = JSON.generate({
          "result" => "Response text",
          "usage" => {
            "input_tokens" => 80
          }
        })

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: json_output,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 80, output: 0, total: 80})
      end

      it "handles JSON with usage containing only output tokens" do
        json_output = JSON.generate({
          "result" => "Response text",
          "usage" => {
            "output_tokens" => 30
          }
        })

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: json_output,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 0, output: 30, total: 30})
      end

      it "extracts text from 'text' field when 'result' is absent" do
        json_output = JSON.generate({
          "text" => "Text field response",
          "usage" => {
            "input_tokens" => 10,
            "output_tokens" => 5
          }
        })

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: json_output,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Text field response")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "records tokens with the global token tracker" do
        json_output = JSON.generate({
          "result" => "Tracked response",
          "usage" => {
            "input_tokens" => 50,
            "output_tokens" => 25
          }
        })

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: json_output,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        tracker = AgentHarness.token_tracker
        tracker.clear!

        provider.send_message(prompt: "Hello")

        summary = tracker.summary
        expect(summary[:total_input_tokens]).to eq(50)
        expect(summary[:total_output_tokens]).to eq(25)
        expect(summary[:total_tokens]).to eq(75)
      end

      it "classifies errors on non-zero exit code" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "",
            stderr: "rate limit exceeded",
            exit_code: 1,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.failed?).to be true
        expect(response.error).to eq("rate limit exceeded")
      end
    end
  end
end
