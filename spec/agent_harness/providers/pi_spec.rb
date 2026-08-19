# frozen_string_literal: true

require "agent_harness/providers/pi"

RSpec.describe AgentHarness::Providers::Pi do
  describe ".provider_name" do
    it "returns :pi" do
      expect(described_class.provider_name).to eq(:pi)
    end
  end

  describe ".binary_name" do
    it "returns pi" do
      expect(described_class.binary_name).to eq("pi")
    end
  end

  describe ".installation_contract" do
    it "exposes Pi CLI install metadata" do
      contract = described_class.installation_contract

      expect(contract).to include(
        source: :npm,
        package_name: "@mariozechner/pi-coding-agent",
        version: "0.73.1",
        binary_name: "pi"
      )
      expect(contract[:package]).to eq("@mariozechner/pi-coding-agent@0.73.1")
      expect(contract[:supported_versions]).to eq(["0.73.1"])
      expect(contract[:version_requirement]).to eq(["= 0.73.1"])
      expect(contract[:install_command]).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "@mariozechner/pi-coding-agent@0.73.1"]
      )
    end

    it "rejects unsupported versions" do
      expect {
        described_class.installation_contract(version: "0.73.0")
      }.to raise_error(ArgumentError, /Unsupported Pi CLI version "0.73.0"/)
    end

    it "normalizes surrounding whitespace in supported versions" do
      contract = described_class.installation_contract(version: " 0.73.1 ")

      expect(contract[:version]).to eq("0.73.1")
      expect(contract[:install_command]).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "@mariozechner/pi-coding-agent@0.73.1"]
      )
    end
  end

  describe ".firewall_requirements" do
    it "returns Pi domains" do
      requirements = described_class.firewall_requirements

      expect(requirements[:domains]).to eq(["pi.dev"])
      expect(requirements[:ip_ranges]).to eq([])
    end
  end

  describe ".instruction_file_paths" do
    it "returns Pi instruction files" do
      expect(described_class.instruction_file_paths).to eq([
        {
          path: "AGENTS.md",
          description: "Pi agent instructions",
          symlink: false
        },
        {
          path: "SYSTEM.md",
          description: "Pi system prompt override",
          symlink: false
        }
      ])
    end
  end

  describe "instance" do
    let(:mock_executor) { instance_double(AgentHarness::CommandExecutor) }

    let(:config) { AgentHarness::ProviderConfig.new(:pi) }

    subject(:provider) { described_class.new(config: config, executor: mock_executor) }

    describe "#display_name" do
      it "returns Pi Coding Agent" do
        expect(provider.display_name).to eq("Pi Coding Agent")
      end
    end

    describe "#configuration_schema" do
      it "supports api key and oauth auth modes" do
        expect(provider.configuration_schema[:auth_modes]).to eq(%i[api_key oauth])
      end
    end

    describe "#capabilities" do
      it "reports tool support without json mode" do
        caps = provider.capabilities

        expect(caps[:json_mode]).to be false
        expect(caps[:tool_use]).to be true
        expect(caps[:vision]).to be true
      end
    end

    describe "#execution_semantics" do
      it "declares text output via print mode" do
        expect(provider.execution_semantics).to include(
          output_format: :text,
          non_interactive_flag: "-p"
        )
      end
    end

    describe "#send_message" do
      it "executes pi in print mode without session persistence" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        expect(mock_executor).to receive(:execute).with(
          ["pi", "--no-session", "-p", "Hello"],
          anything
        )

        provider.send_message(prompt: "Hello")
      end

      it "passes runtime provider, model, and flags through to the CLI" do
        runtime = AgentHarness::ProviderRuntime.new(
          api_provider: "openai",
          model: "gpt-4.1",
          flags: ["--quiet-startup"]
        )

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        expect(mock_executor).to receive(:execute).with(
          ["pi", "--no-session", "--quiet-startup", "--provider", "openai", "--model", "gpt-4.1", "-p", "Hello"],
          anything
        )

        provider.send_message(prompt: "Hello", provider_runtime: runtime)
      end

      it "treats blank runtime provider and model overrides as absent" do
        config.provider = "anthropic"
        config.model = "claude-opus"
        runtime = AgentHarness::ProviderRuntime.new(
          api_provider: "   ",
          model: "   "
        )

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        expect(mock_executor).to receive(:execute).with(
          ["pi", "--no-session", "--provider", "anthropic", "--model", "claude-opus", "-p", "Hello"],
          anything
        )

        provider.send_message(prompt: "Hello", provider_runtime: runtime)
      end

      it "uses configured provider and model when runtime overrides are absent" do
        config.provider = "anthropic"
        config.model = "claude-opus"

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        expect(mock_executor).to receive(:execute).with(
          ["pi", "--no-session", "--provider", "anthropic", "--model", "claude-opus", "-p", "Hello"],
          anything
        )

        provider.send_message(prompt: "Hello")
      end

      it "includes configured default flags in the CLI command" do
        config.default_flags = ["--quiet-startup", "--log-level", "debug"]

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        expect(mock_executor).to receive(:execute).with(
          ["pi", "--no-session", "--quiet-startup", "--log-level", "debug", "-p", "Hello"],
          anything
        )

        provider.send_message(prompt: "Hello")
      end

      it "appends runtime flags after configured default flags" do
        config.default_flags = ["--provider", "anthropic", "--model", "claude-opus"]
        runtime = AgentHarness::ProviderRuntime.new(
          api_provider: "openai",
          model: "gpt-4.1",
          flags: ["--provider", "openai", "--model", "gpt-4.1"]
        )

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        expect(mock_executor).to receive(:execute).with(
          [
            "pi",
            "--no-session",
            "--provider",
            "anthropic",
            "--model",
            "claude-opus",
            "--provider",
            "openai",
            "--model",
            "gpt-4.1",
            "--provider",
            "openai",
            "--model",
            "gpt-4.1",
            "-p",
            "Hello"
          ],
          anything
        )

        provider.send_message(prompt: "Hello", provider_runtime: runtime)
      end

      it "prefers runtime provider and model over configured defaults" do
        config.provider = "anthropic"
        config.model = "claude-opus"
        runtime = AgentHarness::ProviderRuntime.new(
          api_provider: "openai",
          model: "gpt-4.1"
        )

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        expect(mock_executor).to receive(:execute).with(
          ["pi", "--no-session", "--provider", "openai", "--model", "gpt-4.1", "-p", "Hello"],
          anything
        )

        provider.send_message(prompt: "Hello", provider_runtime: runtime)
      end

      it "disables tools when requested" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        expect(mock_executor).to receive(:execute).with(
          ["pi", "--no-session", "--no-tools", "-p", "Hello"],
          anything
        )

        provider.send_message(prompt: "Hello", tools: :none)
      end
    end
  end
end
