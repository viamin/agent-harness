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
    it "exposes Oh My Pi CLI install metadata pinned to 17.3.5" do
      contract = described_class.installation_contract

      expect(contract).to include(
        source: :npm,
        package_name: "@oh-my-pi/pi-coding-agent",
        version: "17.3.5",
        binary_name: "omp"
      )
      expect(contract[:package]).to eq("@oh-my-pi/pi-coding-agent@17.3.5")
      expect(contract[:supported_versions]).to eq(["17.3.5"])
      expect(contract[:version_requirement]).to eq(["= 17.3.5"])
      expect(contract[:install_command]).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "@oh-my-pi/pi-coding-agent@17.3.5"]
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
      contract = described_class.installation_contract(version: " 17.3.5 ")

      expect(contract[:version]).to eq("17.3.5")
      expect(contract[:install_command]).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "@oh-my-pi/pi-coding-agent@17.3.5"]
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

    describe "#smoke_test_contract" do
      it "exposes a deterministic contract suitable for container health probes" do
        contract = provider.smoke_test_contract

        expect(contract).to include(
          prompt: "Reply with exactly OK.",
          expected_output: "OK",
          timeout: 30,
          require_output: true,
          success_message: "Oh My Pi smoke test passed"
        )
      end

      it "does not share the base default contract object" do
        expect(provider.smoke_test_contract).not_to eq(
          AgentHarness::Providers::Base::DEFAULT_SMOKE_TEST_CONTRACT
        )
      end
    end

    describe "#error_patterns" do
      let(:patterns) { provider.error_patterns }

      it "classifies model-not-found output distinctly from transient failures" do
        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new("Error: model claude-fake-9 not found"),
            patterns
          )
        ).to eq(:model_not_found)

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new("connection reset by peer"),
            patterns
          )
        ).to eq(:transient)
      end

      it "classifies auth-expiration output as auth_expired" do
        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new("Your session has expired. Please log in again."),
            patterns
          )
        ).to eq(:auth_expired)

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new("Request failed with 401 Unauthorized"),
            patterns
          )
        ).to eq(:auth_expired)
      end

      it "classifies rate-limit and quota output" do
        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new("Rate limit exceeded (429)"),
            patterns
          )
        ).to eq(:rate_limited)

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new("Weekly/Monthly limit exhausted"),
            patterns
          )
        ).to eq(:quota_exceeded)
      end
    end

    describe "#error_classification_patterns" do
      it "surfaces auth, model, and quota groups for downstream consumers" do
        patterns = provider.error_classification_patterns

        expect(patterns[:auth_expired]).not_to be_empty
        expect(patterns[:authentication]).not_to be_empty
        expect(patterns[:model_not_found]).not_to be_empty
        expect(patterns[:quota]).not_to be_empty

        expect(patterns[:authentication].any? { |p| "API key not set for provider" =~ p }).to be true
      end

      it "preserves the inherited credit/balance quota vocabulary from multi-provider backends" do
        patterns = provider.error_classification_patterns

        # omp routes to multi-provider backends that emit credit/balance
        # phrasing beyond the shared COMMON_ERROR_PATTERNS quota set. The
        # inherited `:quota` set must remain intact rather than being replaced
        # by the narrower COMMON_ERROR_PATTERNS set.
        aggregate_failures do
          expect(patterns[:quota].any? { |p| "requires more credits" =~ p }).to be true
          expect(patterns[:quota].any? { |p| "insufficient credits" =~ p }).to be true
          expect(patterns[:quota].any? { |p| "insufficient balance" =~ p }).to be true
          expect(patterns[:quota].any? { |p| "spend limit reached" =~ p }).to be true
          expect(patterns[:quota].any? { |p| "billing limit exceeded" =~ p }).to be true
          expect(patterns[:quota].any? { |p| "Weekly/Monthly limit exhausted" =~ p }).to be true
        end
      end
    end

    describe "#noisy_error_patterns" do
      it "matches Oh My Pi startup banner noise" do
        patterns = provider.noisy_error_patterns

        expect(patterns.any? { |p| "Oh My Pi v17.3.5" =~ p }).to be true
        expect(patterns.any? { |p| "Bun v1.3.14" =~ p }).to be true
        expect(patterns.any? { |p| "Fetching model..." =~ p }).to be true
      end
    end

    describe "#translate_error" do
      it "translates model resolution failures" do
        translated = provider.translate_error("Error: model gpt-fake not found")
        expect(translated).to eq("Oh My Pi could not resolve the requested model. Check --model/--provider.")
      end

      it "translates missing API key output" do
        translated = provider.translate_error("API key not set for selected provider")
        expect(translated).to eq("Oh My Pi API key not set for the selected provider.")
      end

      it "passes through unrecognized messages" do
        expect(provider.translate_error("something else")).to eq("something else")
      end
    end

    describe "#supports_sessions?" do
      it "reports sessions as unsupported because runs are stateless" do
        expect(provider.supports_sessions?).to be false
      end
    end

    describe "#api_key_env_var_names and related auth metadata" do
      it "lists the multi-provider backend API-key env vars" do
        expect(provider.api_key_env_var_names).to include(
          "ANTHROPIC_API_KEY",
          "OPENAI_API_KEY",
          "GEMINI_API_KEY"
        )
      end

      it "does not unset unknown proxy vars when a caller supplies its own key" do
        expect(provider.api_key_unset_vars).to eq([])
      end

      it "unsets backend API-key env vars when running against a subscription session" do
        expect(provider.subscription_unset_vars).to eq(provider.api_key_env_var_names)
      end
    end

    describe "#plan_execution" do
      it "returns a runnable omp command without executing" do
        expect(mock_executor).not_to receive(:execute)

        plan = provider.plan_execution(prompt: "Hello")

        expect(plan).to eq(
          command: ["omp", "--no-session", "-p", "Hello"],
          env: {},
          preparation: nil
        )
      end

      it "honors provider and model runtime overrides in the plan" do
        runtime = AgentHarness::ProviderRuntime.new(
          api_provider: "openai",
          model: "gpt-4.1",
          flags: ["--quiet-startup"],
          env: {"OPENAI_API_KEY" => "sk-test"}
        )

        expect(mock_executor).not_to receive(:execute)

        plan = provider.plan_execution(prompt: "Hello", provider_runtime: runtime)

        expect(plan[:command]).to eq(
          ["omp", "--no-session", "--quiet-startup", "--provider", "openai", "--model", "gpt-4.1", "-p", "Hello"]
        )
        expect(plan[:env]).to eq("OPENAI_API_KEY" => "sk-test")
        expect(plan[:preparation]).to be_nil
      end

      it "exposes backend API keys through env without touching the Pi credential store" do
        runtime = AgentHarness::ProviderRuntime.new(
          api_provider: "anthropic",
          env: {"ANTHROPIC_API_KEY" => "sk-omp"}
        )

        expect(mock_executor).not_to receive(:execute)

        plan = provider.plan_execution(prompt: "Hello", provider_runtime: runtime)

        expect(plan[:env]).to eq("ANTHROPIC_API_KEY" => "sk-omp")
      end

      it "leaves no side effects when planning with tools disabled" do
        expect(mock_executor).not_to receive(:execute)

        plan = provider.plan_execution(prompt: "Hello", tools: :none)

        expect(plan[:command]).to eq(["omp", "--no-session", "--no-tools", "-p", "Hello"])
      end
    end

    describe "#smoke_test" do
      it "passes when the CLI returns the expected output" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "OK",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        result = provider.smoke_test

        expect(result).to include(
          ok: true,
          status: "ok",
          message: "Oh My Pi smoke test passed",
          error_category: nil,
          output: "OK",
          exit_code: 0
        )
      end

      it "classifies auth-expired failure output from the contract prompt" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "",
            stderr: "Your session has expired. Please log in again.",
            exit_code: 1,
            duration: 1.0
          )
        )

        result = provider.smoke_test

        expect(result[:ok]).to be false
        expect(result[:status]).to eq("error")
        expect(result[:error_category]).to eq(:auth_expired)
      end

      it "classifies model-not-found failure output emitted alongside startup banner noise" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "",
            stderr: "Oh My Pi v17.3.5\nError: model claude-fake not found",
            exit_code: 1,
            duration: 1.0
          )
        )

        result = provider.smoke_test

        expect(result[:ok]).to be false
        expect(result[:error_category]).to eq(:model_not_found)
        expect(result[:message]).to match(/model claude-fake not found/)
        # The banner is exposed for downstream noisy-pattern filtering rather
        # than masked by the harness classification step.
        expect(provider.noisy_error_patterns.any? { |p| "Oh My Pi v17.3.5" =~ p }).to be true
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
        version: "17.3.5",
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
        api_family: :multi_provider,
        api_key_source: :provider_runtime_env
      )
      expect(pi_metadata[:auth]).to include(
        service: :pi,
        api_family: :multi_provider
      )

      # omp runs stateless: callers pass backend API keys per request through
      # ProviderRuntime#env. The harness has no omp credential store, so
      # provider metadata must not advertise one (see auth_status below).
      expect(omp_metadata[:auth]).not_to have_key(:credential_store)

      # Consistent with the metadata: harness-managed auth status is not
      # implemented for omp, so callers cannot infer session auth support.
      auth_status = AgentHarness::Authentication.auth_status(:omp)
      expect(auth_status[:valid]).to be false
      expect(auth_status[:error]).to match(/not implemented/i)
    end

    it "encodes MCP and session runtime decisions through provider metadata" do
      omp_metadata = AgentHarness.provider_metadata(:omp)

      expect(omp_metadata[:capabilities][:mcp]).to be false
      expect(omp_metadata[:runtime][:supports_mcp]).to be false
      expect(omp_metadata[:runtime][:supports_sessions]).to be false
    end

    it "surfaces the omp smoke-test contract through the registry" do
      registry = AgentHarness::Providers::Registry.instance

      contract = registry.smoke_test_contract(:omp)
      expect(contract).to include(
        prompt: "Reply with exactly OK.",
        expected_output: "OK",
        timeout: 30,
        success_message: "Oh My Pi smoke test passed"
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
