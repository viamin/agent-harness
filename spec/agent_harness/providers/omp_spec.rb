# frozen_string_literal: true

require "agent_harness/providers/omp"
require "agent_harness/providers/pi"

RSpec.describe AgentHarness::Providers::OhMyPi do
  describe ".provider_name" do
    it "returns :omp" do
      expect(described_class.provider_name).to eq(:omp)
    end

    it "is distinct from the Pi provider key" do
      expect(described_class.provider_name).not_to eq(AgentHarness::Providers::Pi.provider_name)
    end
  end

  describe ".binary_name" do
    it "returns omp" do
      expect(described_class.binary_name).to eq("omp")
    end
  end

  describe ".installation_contract" do
    it "exposes Oh My Pi CLI install metadata pinned to 17.0.1" do
      contract = described_class.installation_contract

      expect(contract).to include(
        source: :npm,
        package_name: "@oh-my-pi/pi-coding-agent",
        version: "17.0.1",
        binary_name: "omp"
      )
      expect(contract[:package]).to eq("@oh-my-pi/pi-coding-agent@17.0.1")
      expect(contract[:supported_versions]).to eq(["17.0.1"])
      expect(contract[:version_requirement]).to eq(["= 17.0.1"])
      expect(contract[:install_command]).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "@oh-my-pi/pi-coding-agent@17.0.1"]
      )
    end

    it "includes Bun runtime requirements so consumers can provision Bun first" do
      contract = described_class.installation_contract

      bun = contract[:runtime_requirements].find { |req| req[:name] == :bun }
      expect(bun).to include(
        binary_name: "bun",
        pinned_version: "1.3.14",
        version_requirement: ">= 1.3.14",
        source: :script,
        install_script_url: "https://bun.sh/install"
      )
      expect(bun[:install_command]).to eq(
        ["sh", "-c", "curl -fsSL https://bun.sh/install | BUN_VERSION=1.3.14 bash"]
      )
      expect(bun[:install_command_string]).to eq(
        "curl -fsSL https://bun.sh/install | BUN_VERSION=1.3.14 bash"
      )
    end

    it "rejects unsupported versions" do
      expect {
        described_class.installation_contract(version: "16.0.0")
      }.to raise_error(ArgumentError, /Unsupported Oh My Pi CLI version "16.0.0"/)
    end

    it "normalizes surrounding whitespace in supported versions" do
      contract = described_class.installation_contract(version: " 17.0.1 ")

      expect(contract[:version]).to eq("17.0.1")
      expect(contract[:install_command]).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "@oh-my-pi/pi-coding-agent@17.0.1"]
      )
    end
  end

  describe ".bun_runtime_contract" do
    it "exposes a pinned Bun install command and requirement" do
      bun = described_class.bun_runtime_contract

      expect(bun).to include(
        name: :bun,
        binary_name: "bun",
        pinned_version: "1.3.14",
        version_requirement: ">= 1.3.14",
        source: :script,
        install_script_url: "https://bun.sh/install",
        install_command: ["sh", "-c", "curl -fsSL https://bun.sh/install | BUN_VERSION=1.3.14 bash"],
        install_command_string: "curl -fsSL https://bun.sh/install | BUN_VERSION=1.3.14 bash"
      )
    end

    it "does not advertise a broken npm --ignore-scripts install for Bun" do
      bun = described_class.bun_runtime_contract

      # The bun npm package relies on its postinstall script to fetch the
      # platform binary; --ignore-scripts would leave Linux/macOS without a
      # working bun binary. The contract must provision Bun some other way.
      expect(bun[:source]).not_to eq(:npm)
      joined = Array(bun[:install_command]).join(" ")
      expect(joined).not_to include("--ignore-scripts")
      expect(joined).to include("bun.sh/install")
    end
  end

  describe ".firewall_requirements" do
    it "returns Oh My Pi domains" do
      requirements = described_class.firewall_requirements

      expect(requirements[:domains]).to eq(["pi.dev"])
      expect(requirements[:ip_ranges]).to eq([])
    end
  end

  describe ".instruction_file_paths" do
    it "returns Oh My Pi instruction files" do
      expect(described_class.instruction_file_paths).to eq([
        {
          path: "AGENTS.md",
          description: "Oh My Pi agent instructions",
          symlink: false
        },
        {
          path: "SYSTEM.md",
          description: "Oh My Pi system prompt override",
          symlink: false
        }
      ])
    end
  end

  describe "instance" do
    let(:mock_executor) { instance_double(AgentHarness::CommandExecutor) }

    let(:config) { AgentHarness::ProviderConfig.new(:omp) }

    subject(:provider) { described_class.new(config: config, executor: mock_executor) }

    describe "#display_name" do
      it "returns Oh My Pi" do
        expect(provider.display_name).to eq("Oh My Pi")
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
      it "executes omp in print mode without session persistence" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        expect(mock_executor).to receive(:execute).with(
          ["omp", "--no-session", "-p", "Hello"],
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
          ["omp", "--no-session", "--quiet-startup", "--provider", "openai", "--model", "gpt-4.1", "-p", "Hello"],
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
          ["omp", "--no-session", "--provider", "anthropic", "--model", "claude-opus", "-p", "Hello"],
          anything
        )

        provider.send_message(prompt: "Hello")
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
          ["omp", "--no-session", "--no-tools", "-p", "Hello"],
          anything
        )

        provider.send_message(prompt: "Hello", tools: :none)
      end
    end
  end

  describe "registry integration" do
    it "is registered alongside :pi" do
      registry = AgentHarness::Providers::Registry.instance

      expect(registry.registered?(:omp)).to be true
      expect(registry.registered?(:pi)).to be true
      expect(registry.get(:omp)).to eq(described_class)
      expect(registry.get(:pi)).to eq(AgentHarness::Providers::Pi)
    end

    it "exposes a canonical installation contract through the registry" do
      registry = AgentHarness::Providers::Registry.instance

      contract = registry.installation_contract(:omp)
      expect(contract).to include(
        source: :npm,
        package_name: "@oh-my-pi/pi-coding-agent",
        version: "17.0.1",
        binary_name: "omp"
      )
    end

    it "does not alias Oh My Pi metadata over Pi metadata" do
      registry = AgentHarness::Providers::Registry.instance

      omp_metadata = registry.provider_metadata(:omp)
      pi_metadata = registry.provider_metadata(:pi)

      expect(omp_metadata[:provider]).to eq(:omp)
      expect(omp_metadata[:canonical_provider]).to eq(:omp)
      expect(omp_metadata[:binary_name]).to eq("omp")
      expect(omp_metadata[:display_name]).to eq("Oh My Pi")

      expect(pi_metadata[:provider]).to eq(:pi)
      expect(pi_metadata[:binary_name]).to eq("pi")
      expect(pi_metadata[:display_name]).to eq("Pi Coding Agent")

      expect(omp_metadata[:auth]).to include(
        service: :omp,
        api_family: :multi_provider
      )
      expect(pi_metadata[:auth]).to include(
        service: :pi,
        api_family: :multi_provider
      )
    end

    it "surfaces the Bun runtime requirement through registry provider metadata" do
      registry = AgentHarness::Providers::Registry.instance

      installation = registry.provider_metadata(:omp).dig(:runtime, :installation)
      expect(installation).not_to be_nil

      runtime_requirements = installation[:runtime_requirements]
      expect(runtime_requirements).to be_an(Array)

      bun = runtime_requirements.find { |req| req[:name] == :bun }
      expect(bun).to include(
        binary_name: "bun",
        pinned_version: "1.3.14",
        version_requirement: ">= 1.3.14",
        source: :script,
        install_script_url: "https://bun.sh/install"
      )
      expect(bun[:install_command]).to eq(
        ["sh", "-c", "curl -fsSL https://bun.sh/install | BUN_VERSION=1.3.14 bash"]
      )
    end

    it "surfaces the Bun runtime requirement through AgentHarness.provider_metadata" do
      installation = AgentHarness.provider_metadata(:omp).dig(:runtime, :installation)
      expect(installation).not_to be_nil

      bun = installation[:runtime_requirements].find { |req| req[:name] == :bun }
      expect(bun).to include(
        binary_name: "bun",
        pinned_version: "1.3.14",
        version_requirement: ">= 1.3.14",
        install_script_url: "https://bun.sh/install"
      )
    end
  end
end
