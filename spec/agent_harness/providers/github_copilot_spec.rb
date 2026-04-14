# frozen_string_literal: true

RSpec.describe AgentHarness::Providers::GithubCopilot do
  describe ".provider_name" do
    it "returns :github_copilot" do
      expect(described_class.provider_name).to eq(:github_copilot)
    end
  end

  describe ".binary_name" do
    it "returns github-copilot-cli" do
      expect(described_class.binary_name).to eq("github-copilot-cli")
    end
  end

  describe ".firewall_requirements" do
    it "returns required domains" do
      requirements = described_class.firewall_requirements
      expect(requirements[:domains]).to include("api.githubcopilot.com")
    end
  end

  describe ".instruction_file_paths" do
    it "returns copilot-instructions.md" do
      paths = described_class.instruction_file_paths
      expect(paths.first[:path]).to eq(".github/copilot-instructions.md")
    end
  end

  describe ".provider_metadata_overrides" do
    it "exposes the GitHub bot actor identity for downstream metadata consumers" do
      expect(described_class.provider_metadata_overrides).to include(
        identity: {
          bot_usernames: ["github-copilot[bot]"]
        }
      )
    end
  end

  describe ".provider_metadata" do
    let(:metadata_executor) do
      instance_double(
        AgentHarness::CommandExecutor,
        which: "/usr/bin/github-copilot-cli"
      )
    end

    before do
      allow(AgentHarness.configuration).to receive(:command_executor).and_return(metadata_executor)
      allow(metadata_executor).to receive(:execute).with(
        ["github-copilot-cli", "--version"],
        timeout: 5,
        env: {}
      ).and_return(
        AgentHarness::CommandExecutor::Result.new(
          stdout: "github-copilot-cli 0.0.422",
          stderr: "",
          exit_code: 0,
          duration: 0.1
        )
      )
    end

    it "publishes the runtime token-counting contract for programmatic prompt mode" do
      metadata = described_class.provider_metadata

      expect(metadata[:runtime]).to include(
        output_format: :text,
        supports_token_counting: true,
        supports_dangerous_mode: true
      )
      expect(metadata[:capabilities]).to include(
        tool_use: true,
        dangerous_mode: true
      )
    end

    it "reports token counting as unavailable without probing when the CLI is missing" do
      allow(metadata_executor).to receive(:which).with("github-copilot-cli").and_return(nil)
      expect(metadata_executor).not_to receive(:execute).with(["github-copilot-cli", "--version"], any_args)

      metadata = described_class.provider_metadata(refresh: true)

      expect(metadata[:runtime]).to include(
        available: false,
        output_format: :text,
        supports_token_counting: false,
        supports_dangerous_mode: true
      )
      expect(metadata[:capabilities]).to include(
        tool_use: true,
        dangerous_mode: true
      )
    end

    it "reports token counting as unavailable when the installed CLI lacks JSON output support" do
      allow(metadata_executor).to receive(:execute).with(
        ["github-copilot-cli", "--version"],
        timeout: 5,
        env: {}
      ).and_return(
        AgentHarness::CommandExecutor::Result.new(
          stdout: "github-copilot-cli 0.0.421",
          stderr: "",
          exit_code: 0,
          duration: 0.1
        )
      )

      metadata = described_class.provider_metadata(refresh: true)

      expect(metadata[:runtime]).to include(
        available: true,
        output_format: :text,
        supports_token_counting: false,
        supports_dangerous_mode: true
      )
      expect(metadata[:capabilities]).to include(
        tool_use: true,
        dangerous_mode: true
      )
    end
  end

  describe ".smoke_test_contract" do
    it "returns a Copilot-specific contract that requires the exact OK response" do
      contract = described_class.smoke_test_contract
      expect(contract).to eq(AgentHarness::Providers::GithubCopilot::SMOKE_TEST_CONTRACT)
      expect(contract[:prompt]).to eq("Reply with exactly OK.")
      expect(contract[:expected_output]).to eq("OK")
      expect(contract[:require_output]).to be true
    end
  end

  describe ".supports_model_family?" do
    it "returns true for GPT models" do
      expect(described_class.supports_model_family?("gpt-4o")).to be true
      expect(described_class.supports_model_family?("gpt-4-turbo")).to be true
    end

    it "returns false for non-GPT models" do
      expect(described_class.supports_model_family?("claude-3-sonnet")).to be false
    end
  end

  describe "instance" do
    let(:mock_executor) do
      instance_double(AgentHarness::CommandExecutor)
    end

    let(:config) { AgentHarness::ProviderConfig.new(:github_copilot) }
    let(:version_result) do
      AgentHarness::CommandExecutor::Result.new(
        stdout: "github-copilot-cli 0.0.422",
        stderr: "",
        exit_code: 0,
        duration: 0.1
      )
    end

    subject(:provider) { described_class.new(config: config, executor: mock_executor) }

    before do
      allow(mock_executor).to receive(:which).with("github-copilot-cli").and_return("/usr/bin/github-copilot-cli")
      allow(mock_executor).to receive(:execute).with(
        ["github-copilot-cli", "--version"],
        timeout: 5,
        env: {}
      ).and_return(version_result)
    end

    describe "#name" do
      it "returns github_copilot" do
        expect(provider.name).to eq("github_copilot")
      end
    end

    describe "#display_name" do
      it "returns GitHub Copilot CLI" do
        expect(provider.display_name).to eq("GitHub Copilot CLI")
      end
    end

    describe "#configuration_schema" do
      it "includes an optional model field" do
        expect(provider.configuration_schema[:fields]).to include(
          hash_including(
            name: :model,
            type: :string,
            required: false,
            accepts_arbitrary: true
          )
        )
      end

      it "uses oauth auth mode" do
        expect(provider.configuration_schema[:auth_modes]).to eq([:oauth])
      end

      it "is not openai compatible" do
        expect(provider.configuration_schema[:openai_compatible]).to be false
      end
    end

    describe "#capabilities" do
      it "advertises dangerous_mode as an explicit opt-in capability" do
        expect(provider.capabilities[:dangerous_mode]).to be true
      end
    end

    describe "#supports_dangerous_mode?" do
      it "returns true" do
        expect(provider.supports_dangerous_mode?).to be true
      end
    end

    describe "#dangerous_mode_flags" do
      it "uses --allow-all for JSON-capable CLIs" do
        expect(provider.dangerous_mode_flags).to eq(["--allow-all"])
      end

      it "uses --allow-all-tools for older CLIs" do
        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {}
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "github-copilot-cli 0.0.421",
            stderr: "",
            exit_code: 0,
            duration: 0.1
          )
        )

        expect(provider.dangerous_mode_flags).to eq(["--allow-all-tools"])
      end
    end

    describe "#supports_sessions?" do
      it "returns true" do
        expect(provider.supports_sessions?).to be true
      end
    end

    describe "#session_flags" do
      it "returns resume flags when session provided" do
        flags = provider.session_flags("session-123")
        expect(flags).to eq(["--resume", "session-123"])
      end

      it "returns empty when no session" do
        expect(provider.session_flags(nil)).to eq([])
        expect(provider.session_flags("")).to eq([])
      end
    end

    describe "#auth_type" do
      it "returns :oauth" do
        expect(provider.auth_type).to eq(:oauth)
      end
    end

    describe "#supports_token_counting?" do
      it "returns true" do
        expect(provider.supports_token_counting?).to be true
      end

      it "returns false without probing when the CLI is unavailable" do
        allow(mock_executor).to receive(:which).with("github-copilot-cli").and_return(nil)
        expect(mock_executor).not_to receive(:execute).with(["github-copilot-cli", "--version"], any_args)

        expect(provider.supports_token_counting?).to be false
      end

      it "returns false when the installed CLI does not support JSON output" do
        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {}
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "github-copilot-cli 0.0.421",
            stderr: "",
            exit_code: 0,
            duration: 0.1
          )
        )

        expect(provider.supports_token_counting?).to be false
      end

      it "returns false when the version probe fails" do
        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {}
        ).and_raise(StandardError, "temporary failure")

        expect(provider.supports_token_counting?).to be false
      end

      it "returns false when the version probe output is unparsable" do
        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {}
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "github-copilot-cli version unknown",
            stderr: "",
            exit_code: 0,
            duration: 0.1
          )
        )

        expect(provider.supports_token_counting?).to be false
      end

      it "hashes explicit probe path overrides in the version cache key" do
        env = {"PATH" => "/tmp/request-secret/bin", "PATHEXT" => ".EXE:.CMD"}
        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: env
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "github-copilot-cli 0.0.422",
            stderr: "",
            exit_code: 0,
            duration: 0.1
          )
        )

        expect(provider.send(:supports_json_output_format?, env: env)).to be true

        cache_keys = provider.instance_variable_get(:@copilot_cli_versions).keys

        expect(cache_keys.flatten).not_to include("/tmp/request-secret/bin", ".EXE:.CMD")
        expect(cache_keys).to include([
          [:path_override, a_string_matching(/\A\h{64}\z/)],
          [:pathext_override, a_string_matching(/\A\h{64}\z/)]
        ])
      end
    end

    describe "#error_patterns" do
      it "includes auth patterns" do
        patterns = provider.error_patterns
        expect(patterns[:auth_expired]).not_to be_empty
      end
    end

    describe "#execution_semantics" do
      it "returns the full provider contract" do
        semantics = provider.execution_semantics
        expect(semantics[:prompt_delivery]).to eq(:arg)
        expect(semantics[:output_format]).to eq(:text)
        expect(semantics[:sandbox_aware]).to be false
        expect(semantics[:uses_subcommand]).to be false
        expect(semantics[:non_interactive_flag]).to eq("-p")
        expect(semantics[:legitimate_exit_codes]).to eq([0])
        expect(semantics[:stderr_is_diagnostic]).to be true
        expect(semantics[:parses_rate_limit_reset]).to be false
      end
    end

    describe "#build_command" do
      it "retries CLI version detection after transient failures" do
        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {}
        ).and_raise(StandardError, "temporary failure").once

        first_command = provider.send(:build_command, "Hello", {})
        expect(first_command).to eq([
          "github-copilot-cli",
          "-p",
          "Hello",
          "-s"
        ])

        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {}
        ).and_return(version_result)

        second_command = provider.send(:build_command, "Hello", {})
        expect(second_command).to eq([
          "github-copilot-cli",
          "-p",
          "Hello",
          "--output-format",
          "json"
        ])
      end

      it "includes --output-format json by default" do
        command = provider.send(:build_command, "Hello", {})

        expect(command).to eq([
          "github-copilot-cli",
          "-p",
          "Hello",
          "--output-format",
          "json"
        ])
      end

      it "includes configured model when present" do
        configured_provider = described_class.new(
          config: AgentHarness::ProviderConfig.new(:github_copilot).tap { |cfg| cfg.model = "gpt-4o-mini" },
          executor: mock_executor
        )

        command = configured_provider.send(:build_command, "Hello", {})

        expect(command).to eq([
          "github-copilot-cli",
          "-p",
          "Hello",
          "--output-format",
          "json",
          "--model",
          "gpt-4o-mini"
        ])
      end

      it "omits whitespace-only configured models" do
        configured_provider = described_class.new(
          config: AgentHarness::ProviderConfig.new(:github_copilot).tap { |cfg| cfg.model = "   " },
          executor: mock_executor
        )

        command = configured_provider.send(:build_command, "Hello", {})

        expect(command).to eq([
          "github-copilot-cli",
          "-p",
          "Hello",
          "--output-format",
          "json"
        ])
      end

      it "prefers provider_runtime model over configured model" do
        configured_provider = described_class.new(
          config: AgentHarness::ProviderConfig.new(:github_copilot).tap { |cfg| cfg.model = "gpt-4o" },
          executor: mock_executor
        )
        runtime = AgentHarness::ProviderRuntime.new(model: "gpt-4o-mini")

        command = configured_provider.send(:build_command, "Hello", {provider_runtime: runtime})

        expect(command).to eq([
          "github-copilot-cli",
          "-p",
          "Hello",
          "--output-format",
          "json",
          "--model",
          "gpt-4o-mini"
        ])
      end

      it "falls back to the configured model when provider_runtime model is blank" do
        configured_provider = described_class.new(
          config: AgentHarness::ProviderConfig.new(:github_copilot).tap { |cfg| cfg.model = "gpt-4o" },
          executor: mock_executor
        )
        runtime = AgentHarness::ProviderRuntime.new(model: "   ")

        command = configured_provider.send(:build_command, "Hello", {provider_runtime: runtime})

        expect(command).to eq([
          "github-copilot-cli",
          "-p",
          "Hello",
          "--output-format",
          "json",
          "--model",
          "gpt-4o"
        ])
      end

      it "falls back to silent prompt mode without probing when the CLI is unavailable" do
        allow(mock_executor).to receive(:which).with("github-copilot-cli").and_return(nil)
        expect(mock_executor).not_to receive(:execute).with(["github-copilot-cli", "--version"], any_args)

        command = provider.send(:build_command, "Hello", {})

        expect(command).to eq([
          "github-copilot-cli",
          "-p",
          "Hello",
          "-s"
        ])
      end

      it "omits --output-format json on older CLI versions" do
        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {}
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "github-copilot-cli 0.0.421",
            stderr: "",
            exit_code: 0,
            duration: 0.1
          )
        )

        command = provider.send(:build_command, "Hello", {})

        expect(command).to eq([
          "github-copilot-cli",
          "-p",
          "Hello",
          "-s"
        ])
      end

      it "preserves runtime model overrides on the older CLI fallback path" do
        runtime = AgentHarness::ProviderRuntime.new(model: "gpt-4o-mini")

        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {}
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "github-copilot-cli 0.0.421",
            stderr: "",
            exit_code: 0,
            duration: 0.1
          )
        )

        command = provider.send(:build_command, "Hello", {provider_runtime: runtime})

        expect(command).to eq([
          "github-copilot-cli",
          "-p",
          "Hello",
          "-s",
          "--model",
          "gpt-4o-mini"
        ])
      end

      it "includes the configured model on the older CLI fallback path" do
        configured_provider = described_class.new(
          config: AgentHarness::ProviderConfig.new(:github_copilot).tap { |cfg| cfg.model = "gpt-4o-mini" },
          executor: mock_executor
        )

        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {}
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "github-copilot-cli 0.0.421",
            stderr: "",
            exit_code: 0,
            duration: 0.1
          )
        )

        command = configured_provider.send(:build_command, "Hello", {})

        expect(command).to eq([
          "github-copilot-cli",
          "-p",
          "Hello",
          "-s",
          "--model",
          "gpt-4o-mini"
        ])
      end

      it "keeps session flags on the older CLI fallback path" do
        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {}
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "github-copilot-cli 0.0.421",
            stderr: "",
            exit_code: 0,
            duration: 0.1
          )
        )

        command = provider.send(:build_command, "Hello", {session: "session-123"})

        expect(command).to eq([
          "github-copilot-cli",
          "-p",
          "Hello",
          "-s",
          "--resume",
          "session-123"
        ])
      end

      it "memoizes parsed CLI versions after a successful probe" do
        2.times { provider.send(:build_command, "Hello", {}) }

        expect(mock_executor).to have_received(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {}
        ).once
      end

      it "probes the Copilot CLI version with the same runtime env as the request command" do
        runtime = AgentHarness::ProviderRuntime.new(
          env: {"PATH" => "/custom/copilot/bin"},
          unset_env: ["GITHUB_COPILOT_TOKEN"]
        )

        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {"PATH" => "/custom/copilot/bin", "GITHUB_COPILOT_TOKEN" => nil}
        ).and_return(version_result)

        command = provider.send(:build_command, "Hello", {provider_runtime: runtime})

        expect(command).to eq([
          "github-copilot-cli",
          "-p",
          "Hello",
          "--output-format",
          "json"
        ])
      end

      it "caches CLI versions per effective runtime env" do
        legacy_runtime = AgentHarness::ProviderRuntime.new(env: {"PATH" => "/legacy/copilot/bin"})
        json_runtime = AgentHarness::ProviderRuntime.new(env: {"PATH" => "/json/copilot/bin"})

        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {"PATH" => "/legacy/copilot/bin"}
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "github-copilot-cli 0.0.421",
            stderr: "",
            exit_code: 0,
            duration: 0.1
          )
        )

        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {"PATH" => "/json/copilot/bin"}
        ).and_return(version_result)

        legacy_command = provider.send(:build_command, "Hello", {provider_runtime: legacy_runtime})
        json_command = provider.send(:build_command, "Hello", {provider_runtime: json_runtime})

        expect(legacy_command).to eq([
          "github-copilot-cli",
          "-p",
          "Hello",
          "-s"
        ])
        expect(json_command).to eq([
          "github-copilot-cli",
          "-p",
          "Hello",
          "--output-format",
          "json"
        ])
      end

      it "does not key the version cache on unrelated runtime secrets" do
        first_runtime = AgentHarness::ProviderRuntime.new(
          env: {"PATH" => "/json/copilot/bin", "GITHUB_TOKEN" => "secret-one"}
        )
        second_runtime = AgentHarness::ProviderRuntime.new(
          env: {"PATH" => "/json/copilot/bin", "GITHUB_TOKEN" => "secret-two"}
        )

        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {"PATH" => "/json/copilot/bin", "GITHUB_TOKEN" => "secret-one"}
        ).and_return(version_result)

        first_command = provider.send(:build_command, "Hello", {provider_runtime: first_runtime})
        second_command = provider.send(:build_command, "Hello", {provider_runtime: second_runtime})

        expect(first_command).to eq([
          "github-copilot-cli",
          "-p",
          "Hello",
          "--output-format",
          "json"
        ])
        expect(second_command).to eq(first_command)
        expect(mock_executor).to have_received(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {"PATH" => "/json/copilot/bin", "GITHUB_TOKEN" => "secret-one"}
        ).once

        cache_keys = provider.instance_variable_get(:@copilot_cli_versions).keys
        expect(cache_keys.flatten).not_to include("/json/copilot/bin", "secret-one", "secret-two")
        expect(cache_keys).to contain_exactly([
          [:path_override, a_string_matching(/\A\h{64}\z/)],
          :inherited_pathext
        ])
      end

      it "retries CLI version detection after an unparsable probe result" do
        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {}
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "github-copilot-cli version unknown",
            stderr: "",
            exit_code: 0,
            duration: 0.1
          ),
          version_result
        )

        first_command = provider.send(:build_command, "Hello", {})
        second_command = provider.send(:build_command, "Hello", {})

        expect(first_command).to eq([
          "github-copilot-cli",
          "-p",
          "Hello",
          "-s"
        ])
        expect(second_command).to eq([
          "github-copilot-cli",
          "-p",
          "Hello",
          "--output-format",
          "json"
        ])
      end

      it "does not add tool approval flags by default" do
        command = provider.send(:build_command, "Hello", {})

        expect(command).to eq([
          "github-copilot-cli",
          "-p",
          "Hello",
          "--output-format",
          "json"
        ])
      end

      it "keeps session flags without tool approval by default" do
        command = provider.send(:build_command, "Hello", {session: "session-123"})

        expect(command).to eq([
          "github-copilot-cli",
          "-p",
          "Hello",
          "--output-format",
          "json",
          "--resume",
          "session-123"
        ])
      end

      it "adds blanket approval only when dangerous_mode is requested" do
        command = provider.send(:build_command, "Hello", {session: "session-123", dangerous_mode: true})

        expect(command).to eq([
          "github-copilot-cli",
          "-p",
          "Hello",
          "--output-format",
          "json",
          "--allow-all",
          "--resume",
          "session-123"
        ])
      end

      it "adds blanket approval to the older CLI fallback path only when dangerous_mode is requested" do
        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {}
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "github-copilot-cli 0.0.421",
            stderr: "",
            exit_code: 0,
            duration: 0.1
          )
        )

        command = provider.send(:build_command, "Hello", {session: "session-123", dangerous_mode: true})

        expect(command).to eq([
          "github-copilot-cli",
          "-p",
          "Hello",
          "-s",
          "--allow-all-tools",
          "--resume",
          "session-123"
        ])
      end
    end

    describe "#send_message" do
      it "sends prompt in non-interactive mode with JSON output" do
        jsonl_output = [
          {"text" => "response"},
          {"usage" => {"input_tokens" => 10, "output_tokens" => 5}}
        ].map { |o| JSON.generate(o) }.join("\n")

        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {}
        ).and_return(version_result)

        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "-p", "Hello", "--output-format", "json"],
          anything
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: jsonl_output,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        expect(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "-p", "Hello", "--output-format", "json"],
          anything
        )

        provider.send_message(prompt: "Hello")
      end

      it "uses the same runtime env for the version probe and prompt command" do
        runtime = AgentHarness::ProviderRuntime.new(
          env: {"PATH" => "/custom/copilot/bin"},
          unset_env: ["GITHUB_COPILOT_TOKEN"]
        )
        jsonl_output = [
          {"text" => "response"},
          {"usage" => {"input_tokens" => 10, "output_tokens" => 5}}
        ].map { |o| JSON.generate(o) }.join("\n")
        request_env = {"PATH" => "/custom/copilot/bin", "GITHUB_COPILOT_TOKEN" => nil}

        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: request_env
        ).and_return(version_result)

        expect(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "-p", "Hello", "--output-format", "json"],
          hash_including(env: request_env)
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: jsonl_output,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        provider.send_message(prompt: "Hello", provider_runtime: runtime)
      end

      it "passes provider_runtime model to the Copilot command" do
        runtime = AgentHarness::ProviderRuntime.new(model: "gpt-4o-mini")
        jsonl_output = [
          {"text" => "response"},
          {"usage" => {"input_tokens" => 10, "output_tokens" => 5}}
        ].map { |o| JSON.generate(o) }.join("\n")

        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {}
        ).and_return(version_result)

        expect(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--model", "gpt-4o-mini"],
          anything
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: jsonl_output,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        provider.send_message(prompt: "Hello", provider_runtime: runtime)
      end

      it "uses the remaining request timeout budget for the prompt command and includes probe time in duration" do
        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 2,
          env: {}
        ).and_return(version_result)

        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "-p", "Hello", "--output-format", "json"],
          hash_including(timeout: 1.25)
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "plain text response",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        times = [
          Time.utc(2026, 4, 12, 0, 0, 0),
          Time.utc(2026, 4, 12, 0, 0, 0, 750_000),
          Time.utc(2026, 4, 12, 0, 0, 1, 500_000)
        ]
        allow(Time).to receive(:now).and_return(*times)

        response = provider.send_message(prompt: "Hello", timeout: 2)

        expect(response.duration).to eq(1.5)
      end

      it "times out before execution if the version probe exhausts the request budget" do
        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 1,
          env: {}
        ).and_return(version_result)

        times = [
          Time.utc(2026, 4, 12, 0, 0, 0),
          Time.utc(2026, 4, 12, 0, 0, 1)
        ]
        allow(Time).to receive(:now).and_return(*times)

        expect do
          provider.send_message(prompt: "Hello", timeout: 1)
        end.to raise_error(AgentHarness::TimeoutError, "Command timed out before execution started")
      end

      it "fails fast on non-positive timeout before probing the CLI version" do
        expect do
          provider.send_message(prompt: "Hello", timeout: 0)
        end.to raise_error(AgentHarness::TimeoutError, "Command timed out before execution started")

        expect(mock_executor).not_to have_received(:execute).with(
          ["github-copilot-cli", "--version"],
          any_args
        )
      end

      it "falls back to plain prompt mode when JSON output is unsupported" do
        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {}
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "github-copilot-cli 0.0.421",
            stderr: "",
            exit_code: 0,
            duration: 0.1
          )
        )

        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "-p", "Hello", "-s"],
          anything
        ).and_return(
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

      it "passes runtime model overrides through the older CLI fallback path" do
        runtime = AgentHarness::ProviderRuntime.new(model: "gpt-4o-mini")

        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {}
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "github-copilot-cli 0.0.421",
            stderr: "",
            exit_code: 0,
            duration: 0.1
          )
        )

        expect(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "-p", "Hello", "-s", "--model", "gpt-4o-mini"],
          anything
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "plain text response",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello", provider_runtime: runtime)
        expect(response.output).to eq("plain text response")
        expect(response.model).to eq("gpt-4o-mini")
      end

      it "passes the configured model through the older CLI fallback path" do
        configured_provider = described_class.new(
          config: AgentHarness::ProviderConfig.new(:github_copilot).tap { |cfg| cfg.model = "gpt-4o-mini" },
          executor: mock_executor
        )

        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {}
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "github-copilot-cli 0.0.421",
            stderr: "",
            exit_code: 0,
            duration: 0.1
          )
        )

        expect(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "-p", "Hello", "-s", "--model", "gpt-4o-mini"],
          anything
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "plain text response",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = configured_provider.send_message(prompt: "Hello")
        expect(response.output).to eq("plain text response")
        expect(response.model).to eq("gpt-4o-mini")
      end

      it "skips the version probe during send_message when the CLI is unavailable" do
        allow(mock_executor).to receive(:which).with("github-copilot-cli").and_return(nil)
        expect(mock_executor).not_to receive(:execute).with(["github-copilot-cli", "--version"], any_args)

        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "-p", "Hello", "-s"],
          anything
        ).and_return(
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

      it "does not decode plain-text fallback output that happens to be valid JSON" do
        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {}
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "github-copilot-cli 0.0.421",
            stderr: "",
            exit_code: 0,
            duration: 0.1
          )
        )

        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "-p", "Hello", "-s"],
          anything
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: JSON.generate({"text" => "plain text response"}),
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("{\"text\":\"plain text response\"}")
        expect(response.tokens).to be_nil
      end

      context "with dangerous_mode option" do
        it "adds blanket tool approval to the JSON output command" do
          jsonl_output = [
            {"text" => "response"},
            {"usage" => {"input_tokens" => 10, "output_tokens" => 5}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          expect(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          )

          provider.send_message(prompt: "Hello", dangerous_mode: true)
        end

        it "adds blanket tool approval to the plain-text fallback command" do
          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: "github-copilot-cli 0.0.421",
              stderr: "",
              exit_code: 0,
              duration: 0.1
            )
          )

          expect(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "-s", "--allow-all-tools", "--resume", "session-123"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: "plain text response",
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true, session: "session-123")
          expect(response.output).to eq("plain text response")
          expect(response.tokens).to be_nil
        end
      end

      context "with token usage parsing" do
        it "extracts token usage from JSONL output with usage in separate line" do
          jsonl_output = [
            {"text" => "Hello! How can I help?"},
            {"usage" => {"input_tokens" => 100, "output_tokens" => 50}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("Hello! How can I help?")
          expect(response.tokens).to eq({input: 100, output: 50, total: 150})
          expect(response.input_tokens).to eq(100)
          expect(response.output_tokens).to eq(50)
          expect(response.total_tokens).to eq(150)
        end

        it "does not use silent mode on JSON output commands so usage remains available" do
          jsonl_output = [
            {"text" => "response"},
            {"usage" => {"input_tokens" => 10, "output_tokens" => 5}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          provider.send_message(prompt: "Hello", dangerous_mode: true)

          expect(mock_executor).to have_received(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          )
        end

        it "extracts token usage from JSONL output with prompt_tokens format" do
          jsonl_output = [
            {"text" => "response"},
            {"usage" => {"prompt_tokens" => 200, "completion_tokens" => 75}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.tokens).to eq({input: 200, output: 75, total: 275})
        end

        it "extracts usage from nested message.usage" do
          jsonl_output = [
            {"text" => "response"},
            {"message" => {"usage" => {"input_tokens" => 30, "output_tokens" => 15}}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.tokens).to eq({input: 30, output: 15, total: 45})
        end

        it "prefers the most complete direct usage payload within a single JSONL event" do
          jsonl_output = [
            {"text" => "response"},
            {"usage" => {"input_tokens" => 10}, "message" => {"usage" => {"input_tokens" => 10, "output_tokens" => 5}}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("response")
          expect(response.tokens).to eq({input: 10, output: 5, total: 15})
        end

        it "extracts assistant text from event payload content and delta content" do
          jsonl_output = [
            {"type" => "assistant.message", "data" => {"content" => "Hello"}},
            {"type" => "assistant.delta", "data" => {"deltaContent" => " world"}},
            {"type" => "assistant.delta", "data" => {"deltaContent" => "!"}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("Hello world!")
          expect(response.tokens).to be_nil
        end

        it "extracts assistant text from snake_case delta_content payloads" do
          jsonl_output = [
            {"type" => "assistant.message", "data" => {"content" => "Hello"}},
            {"type" => "assistant.delta", "data" => {"delta_content" => " world"}},
            {"type" => "assistant.delta", "data" => {"delta_content" => "!"}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("Hello world!")
          expect(response.tokens).to be_nil
        end

        it "prefers a later full-message snapshot over earlier delta fragments" do
          jsonl_output = [
            {"type" => "assistant.message", "data" => {"content" => "Hel"}},
            {"type" => "assistant.delta", "data" => {"deltaContent" => "lo"}},
            {"type" => "turn.completed", "data" => {"message" => {"content" => "Hello"}}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("Hello")
          expect(response.tokens).to be_nil
        end

        it "prefers a later full-message snapshot over earlier partial snapshots" do
          jsonl_output = [
            {"type" => "assistant.message", "data" => {"content" => "Hello"}},
            {"type" => "turn.completed", "data" => {"message" => {"content" => "Hello world"}}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("Hello world")
          expect(response.tokens).to be_nil
        end

        it "prefers a later shorter full-message snapshot over an earlier longer partial snapshot" do
          jsonl_output = [
            {"type" => "assistant.message", "data" => {"content" => "Hello world"}},
            {"type" => "turn.completed", "data" => {"message" => {"content" => "Hello"}}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("Hello")
          expect(response.tokens).to be_nil
        end

        it "prefers a later corrected full-message snapshot over an earlier same-length snapshot" do
          jsonl_output = [
            {"type" => "assistant.message", "data" => {"content" => "Hxllo"}},
            {"type" => "turn.completed", "data" => {"message" => {"content" => "Hello"}}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("Hello")
          expect(response.tokens).to be_nil
        end

        it "prefers a later corrected full-message snapshot even when the replacement length changes" do
          jsonl_output = [
            {"type" => "assistant.message", "data" => {"content" => "Hxllo"}},
            {"type" => "turn.completed", "data" => {"message" => {"content" => "Hello!"}}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("Hello!")
          expect(response.tokens).to be_nil
        end

        it "treats later untyped wrapped message snapshots as authoritative replacements" do
          jsonl_output = [
            {"message" => {"content" => "Hxllo"}},
            {"message" => {"content" => "Hello"}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("Hello")
          expect(response.tokens).to be_nil
        end

        it "treats later wrapped data.message snapshots as authoritative replacements" do
          jsonl_output = [
            {"data" => {"message" => {"content" => "Hxllo"}}},
            {"data" => {"message" => {"content" => "Hello"}}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("Hello")
          expect(response.tokens).to be_nil
        end

        it "does not duplicate identical back-to-back full snapshots" do
          jsonl_output = [
            {"type" => "assistant.message", "data" => {"content" => "OK"}},
            {"type" => "turn.completed", "data" => {"message" => {"content" => "OK"}}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("OK")
          expect(response.tokens).to be_nil
        end

        it "extracts assistant text from structured content parts" do
          jsonl_output = [
            {"type" => "assistant.message", "data" => {"content" => [{"text" => "Hello"}, {"text" => " world"}]}},
            {"type" => "assistant.delta", "data" => {"deltaContent" => "!"}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("Hello world!")
          expect(response.tokens).to be_nil
        end

        it "extracts assistant text from nested message content payloads" do
          jsonl_output = [
            {"message" => {"content" => [{"text" => "Hello"}, {"text" => " world"}]}},
            {"data" => {"message" => {"content" => "!"}}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("Hello world!")
          expect(response.tokens).to be_nil
        end

        it "extracts assistant text from wrapped parts payloads" do
          jsonl_output = [
            {"data" => {"message" => {"content" => {"parts" => [{"text" => "Hello"}, {"text" => " world"}]}}}},
            {"data" => {"delta" => {"parts" => [{"text" => "!"}]}}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("Hello world!")
          expect(response.tokens).to be_nil
        end

        it "extracts token usage from usage event payload camelCase fields" do
          jsonl_output = [
            {"type" => "assistant.message", "data" => {"content" => "response"}},
            {"type" => "usage", "data" => {"inputTokens" => 44, "outputTokens" => 11}},
            {"type" => "usage", "data" => {"promptTokens" => "6", "completionTokens" => 4}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("response")
          expect(response.tokens).to eq({input: 50, output: 15, total: 65})
        end

        it "extracts token usage from event envelopes that wrap counts under data.usage" do
          jsonl_output = [
            {"type" => "assistant.message", "data" => {"content" => "response"}},
            {"type" => "turn.completed", "data" => {"usage" => {"inputTokens" => 44, "outputTokens" => 11}}},
            {"type" => "turn.completed", "data" => {"usage" => {"promptTokens" => "6", "completionTokens" => 4}}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("response")
          expect(response.tokens).to eq({input: 50, output: 15, total: 65})
        end

        it "extracts token usage from top-level tokens payloads" do
          jsonl_output = [
            {"type" => "assistant.message", "data" => {"content" => "response"}},
            {"tokens" => {"input_tokens" => 44, "output_tokens" => 11}},
            {"tokens" => {"promptTokens" => "6", "completionTokens" => 4}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("response")
          expect(response.tokens).to eq({input: 50, output: 15, total: 65})
        end

        it "extracts token usage from wrapped tokens payloads" do
          jsonl_output = [
            {"type" => "assistant.message", "data" => {"content" => "response"}},
            {"type" => "turn.completed", "data" => {"tokens" => {"input_tokens" => 44, "output_tokens" => 11}}},
            {"message" => {"tokens" => {"promptTokens" => "6", "completionTokens" => 4}}},
            {"data" => {"message" => {"tokens" => {"inputTokens" => 5, "outputTokens" => 1}}}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("response")
          expect(response.tokens).to eq({input: 55, output: 16, total: 71})
        end

        it "extracts token usage from wrapped direct token payloads" do
          jsonl_output = [
            {"type" => "assistant.message", "data" => {"content" => "response"}},
            {"message" => {"input_tokens" => 44, "output_tokens" => 11}},
            {"data" => {"message" => {"promptTokens" => "6", "completionTokens" => 4}}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("response")
          expect(response.tokens).to eq({input: 50, output: 15, total: 65})
        end

        it "extracts token usage from shutdown metrics payloads" do
          jsonl_output = [
            {"type" => "assistant.message", "data" => {"content" => "response"}},
            {"type" => "session.shutdown", "data" => {"modelMetrics" => {"inputTokens" => 44, "outputTokens" => 11}}},
            {"type" => "session.shutdown", "data" => {"model_metrics" => {"promptTokens" => "6", "completionTokens" => 4}}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("response")
          expect(response.tokens).to eq({input: 50, output: 15, total: 65})
        end

        it "preserves explicit zero-token shutdown metrics" do
          jsonl_output = [
            {"type" => "assistant.message", "data" => {"content" => "response"}},
            {"type" => "session.shutdown", "data" => {"modelMetrics" => {"inputTokens" => 0, "outputTokens" => 0}}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("response")
          expect(response.tokens).to eq({input: 0, output: 0, total: 0})
        end

        it "extracts token usage from per-model shutdown metrics payloads" do
          jsonl_output = [
            {"type" => "assistant.message", "data" => {"content" => "response"}},
            {"type" => "session.shutdown", "data" => {"modelMetrics" => {"gpt-4o" => {"usage" => {"inputTokens" => 44, "outputTokens" => 11}}}}},
            {"type" => "session.shutdown", "data" => {"model_metrics" => {"gpt-4o-mini" => {"usage" => {"promptTokens" => "6", "completionTokens" => 4}}}}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("response")
          expect(response.tokens).to eq({input: 50, output: 15, total: 65})
        end

        it "aggregates all model entries within a single shutdown metrics payload" do
          jsonl_output = [
            {"type" => "assistant.message", "data" => {"content" => "response"}},
            {
              "type" => "session.shutdown",
              "data" => {
                "modelMetrics" => {
                  "gpt-4o" => {"usage" => {"inputTokens" => 44, "outputTokens" => 11}},
                  "gpt-4o-mini" => {"usage" => {"promptTokens" => "6", "completionTokens" => 4}}
                }
              }
            }
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("response")
          expect(response.tokens).to eq({input: 50, output: 15, total: 65})
        end

        it "extracts token usage from wrapped shutdown metrics payloads" do
          jsonl_output = [
            {"type" => "assistant.message", "data" => {"content" => "response"}},
            {"message" => {"modelMetrics" => {"inputTokens" => 44, "outputTokens" => 11}}},
            {"data" => {"message" => {"model_metrics" => {"promptTokens" => "6", "completionTokens" => 4}}}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("response")
          expect(response.tokens).to eq({input: 50, output: 15, total: 65})
        end

        it "prefers authoritative shutdown totals over overlapping granular usage events" do
          jsonl_output = [
            {"type" => "assistant.message", "data" => {"content" => "response"}},
            {"type" => "usage", "data" => {"inputTokens" => 44, "outputTokens" => 11}},
            {"type" => "usage", "data" => {"promptTokens" => "6", "completionTokens" => 4}},
            {"type" => "session.shutdown", "data" => {"modelMetrics" => {"inputTokens" => 50, "outputTokens" => 15}}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("response")
          expect(response.tokens).to eq({input: 50, output: 15, total: 65})
        end

        it "supplements incomplete shutdown totals with granular usage events" do
          jsonl_output = [
            {"type" => "assistant.message", "data" => {"content" => "response"}},
            {"type" => "usage", "data" => {"inputTokens" => 100}},
            {"type" => "session.shutdown", "data" => {"outputTokens" => 50}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("response")
          expect(response.tokens).to eq({input: 100, output: 50, total: 150})
        end

        it "ignores malformed direct usage hashes when wrapped shutdown metrics are present" do
          jsonl_output = [
            {"type" => "assistant.message", "data" => {"content" => "response"}},
            {
              "usage" => {"status" => "ignored"},
              "data" => {
                "modelMetrics" => {
                  "gpt-4o" => {"usage" => {"inputTokens" => 44, "outputTokens" => 11}}
                }
              }
            },
            {
              "tokens" => {"status" => "ignored"},
              "message" => {
                "model_metrics" => {
                  "gpt-4o-mini" => {"usage" => {"promptTokens" => "6", "completionTokens" => 4}}
                }
              }
            }
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("response")
          expect(response.tokens).to eq({input: 50, output: 15, total: 65})
        end

        it "falls back to wrapped shutdown metrics when direct usage has unparseable token values" do
          jsonl_output = [
            {"type" => "assistant.message", "data" => {"content" => "response"}},
            {
              "usage" => {"input_tokens" => "not-a-number", "output_tokens" => []},
              "data" => {
                "modelMetrics" => {
                  "gpt-4o" => {"usage" => {"inputTokens" => 44, "outputTokens" => 11}}
                }
              }
            },
            {
              "tokens" => {"promptTokens" => {}, "completionTokens" => "NaN"},
              "message" => {
                "model_metrics" => {
                  "gpt-4o-mini" => {"usage" => {"promptTokens" => "6", "completionTokens" => 4}}
                }
              }
            }
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("response")
          expect(response.tokens).to eq({input: 50, output: 15, total: 65})
        end

        it "falls back to wrapped shutdown metrics when direct usage has negative token values" do
          jsonl_output = [
            {"type" => "assistant.message", "data" => {"content" => "response"}},
            {
              "usage" => {"input_tokens" => -10, "output_tokens" => 11},
              "data" => {
                "modelMetrics" => {
                  "gpt-4o" => {"usage" => {"inputTokens" => 44, "outputTokens" => 11}}
                }
              }
            },
            {
              "tokens" => {"promptTokens" => "6", "completionTokens" => -4},
              "message" => {
                "model_metrics" => {
                  "gpt-4o-mini" => {"usage" => {"promptTokens" => "6", "completionTokens" => 4}}
                }
              }
            }
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("response")
          expect(response.tokens).to eq({input: 50, output: 15, total: 65})
        end

        it "prefers fuller wrapped shutdown metrics over a partial direct usage payload in the same event" do
          jsonl_output = [
            {"type" => "assistant.message", "data" => {"content" => "response"}},
            {
              "type" => "session.shutdown",
              "usage" => {"input_tokens" => 10},
              "data" => {
                "modelMetrics" => {
                  "gpt-4o" => {"usage" => {"inputTokens" => 10, "outputTokens" => 5}},
                  "gpt-4o-mini" => {"usage" => {"promptTokens" => "6", "completionTokens" => 4}}
                }
              }
            }
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("response")
          expect(response.tokens).to eq({input: 16, output: 9, total: 25})
        end

        it "filters non-assistant envelopes before reconstructing Copilot output" do
          jsonl_output = [
            {"type" => "user_input", "data" => {"content" => "User prompt"}},
            {"type" => "system", "data" => {"content" => "System instructions"}},
            {"type" => "assistant.delta", "data" => {"deltaContent" => "Hello"}},
            {"type" => "assistant.delta", "data" => {"deltaContent" => " world"}},
            {"type" => "turn.completed", "data" => {"usage" => {"inputTokens" => 12, "outputTokens" => 3}}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("Hello world")
          expect(response.tokens).to eq({input: 12, output: 3, total: 15})
        end

        it "filters non-assistant envelopes when role is nested directly under data" do
          jsonl_output = [
            {"data" => {"role" => "user", "content" => "User prompt"}},
            {"data" => {"role" => "system", "content" => "System instructions"}},
            {"data" => {"role" => "assistant", "content" => "Hello"}},
            {"data" => {"role" => "assistant", "content" => " world"}},
            {"type" => "turn.completed", "data" => {"usage" => {"inputTokens" => 12, "outputTokens" => 3}}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("Hello world")
          expect(response.tokens).to eq({input: 12, output: 3, total: 15})
        end

        it "filters non-assistant role envelopes nested under message payloads" do
          jsonl_output = [
            {"message" => {"role" => "user", "content" => "User prompt"}},
            {"data" => {"message" => {"role" => "system", "content" => "System instructions"}}},
            {"message" => {"role" => "assistant", "content" => "Hello"}},
            {"data" => {"message" => {"role" => "assistant", "content" => " world"}}},
            {"type" => "turn.completed", "data" => {"usage" => {"inputTokens" => 12, "outputTokens" => 3}}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("Hello world")
          expect(response.tokens).to eq({input: 12, output: 3, total: 15})
        end

        it "filters non-assistant role envelopes nested directly under data payloads" do
          jsonl_output = [
            {"data" => {"role" => "user", "content" => "User prompt"}},
            {"data" => {"role" => "system", "content" => "System instructions"}},
            {"data" => {"role" => "assistant", "content" => "Hello"}},
            {"data" => {"role" => "assistant", "content" => " world"}},
            {"type" => "turn.completed", "data" => {"usage" => {"inputTokens" => 12, "outputTokens" => 3}}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("Hello world")
          expect(response.tokens).to eq({input: 12, output: 3, total: 15})
        end

        it "ignores non-hash JSONL entries while preserving valid token usage" do
          jsonl_output = [
            {"text" => "response"},
            ["unexpected entry"],
            {"usage" => {"input_tokens" => 30, "output_tokens" => 15}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("response")
          expect(response.tokens).to eq({input: 30, output: 15, total: 45})
        end

        it "skips malformed scalar envelopes while preserving assistant output and tokens" do
          jsonl_output = [
            {"type" => "assistant.message", "data" => "unexpected scalar"},
            {"data" => {"role" => "assistant", "content" => "Hello"}},
            {"type" => "turn.completed", "data" => {"usage" => {"inputTokens" => 12, "outputTokens" => 3}}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("Hello")
          expect(response.tokens).to eq({input: 12, output: 3, total: 15})
        end

        it "skips malformed token counts while preserving valid JSONL usage lines" do
          jsonl_output = [
            {"text" => "response"},
            {"usage" => {"input_tokens" => "not-a-number", "output_tokens" => {}}},
            {"usage" => {"prompt_tokens" => "20", "completion_tokens" => 5}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("response")
          expect(response.tokens).to eq({input: 20, output: 5, total: 25})
        end

        it "rejects negative token values while preserving later valid usage lines" do
          jsonl_output = [
            {"text" => "response"},
            {"usage" => {"input_tokens" => "-2", "output_tokens" => -1}},
            {"usage" => {"prompt_tokens" => "20", "completion_tokens" => 5}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("response")
          expect(response.tokens).to eq({input: 20, output: 5, total: 25})
        end

        it "skips unparseable JSONL lines instead of discarding the entire output" do
          jsonl_output = [
            JSON.generate({"text" => "hello"}),
            "NOT VALID JSON {{{",
            JSON.generate({"usage" => {"input_tokens" => 10, "output_tokens" => 5}})
          ].join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("hello")
          expect(response.tokens).to eq({input: 10, output: 5, total: 15})
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

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("plain text response")
          expect(response.tokens).to be_nil
        end

        it "falls back to plain text when output mixes raw text with JSON lines" do
          mixed_output = [
            "plain text response",
            JSON.generate({"usage" => {"input_tokens" => 20, "output_tokens" => 5}})
          ].join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: mixed_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq(mixed_output)
          expect(response.tokens).to be_nil
        end

        it "handles JSONL without usage data" do
          jsonl_output = [
            {"text" => "Hello!"},
            {"text" => " World!"}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq("Hello! World!")
          expect(response.tokens).to be_nil
        end

        it "records tokens with the global token tracker" do
          jsonl_output = [
            {"text" => "Tracked response"},
            {"usage" => {"input_tokens" => 50, "output_tokens" => 25}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          tracker = AgentHarness.token_tracker
          tracker.clear!

          provider.send_message(prompt: "Hello", dangerous_mode: true)

          summary = tracker.summary
          expect(summary[:total_input_tokens]).to eq(50)
          expect(summary[:total_output_tokens]).to eq(25)
          expect(summary[:total_tokens]).to eq(75)
        end
      end

      context "error handling" do
        it "preserves provider_runtime model overrides on the JSON output path" do
          runtime = AgentHarness::ProviderRuntime.new(model: "gpt-4o-mini")
          jsonl_output = [
            {"text" => "response"},
            {"usage" => {"input_tokens" => 10, "output_tokens" => 5}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--model", "gpt-4o-mini", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true, provider_runtime: runtime)
          expect(response.model).to eq("gpt-4o-mini")
          expect(response.tokens).to eq({input: 10, output: 5, total: 15})
        end

        it "classifies error from combined output on failure" do
          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: "",
              stderr: "not authorized",
              exit_code: 1,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.error).to include("not authorized")
        end

        it "preserves raw JSON-mode output and skips token extraction on failure" do
          jsonl_output = [
            {"text" => "response"},
            {"usage" => {"input_tokens" => 10, "output_tokens" => 5}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "--version"],
            timeout: 5,
            env: {}
          ).and_return(version_result)

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "not authorized",
              exit_code: 1,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.output).to eq(jsonl_output)
          expect(response.tokens).to be_nil
          expect(response.error).to include("not authorized")
        end

        it "preserves base response metadata" do
          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: "plain text response",
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello", dangerous_mode: true)
          expect(response.metadata).to eq({legitimate_exit_codes: [0]})
        end

        it "preserves the configured model when provider_runtime model is blank" do
          configured_provider = described_class.new(
            config: AgentHarness::ProviderConfig.new(:github_copilot).tap { |cfg| cfg.model = "gpt-4o-mini" },
            executor: mock_executor
          )
          runtime = AgentHarness::ProviderRuntime.new(model: "  ")

          allow(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--model", "gpt-4o-mini"],
            anything
          ).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: JSON.generate({"text" => "Hello"}),
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = configured_provider.send_message(prompt: "Hello", provider_runtime: runtime)

          expect(response.model).to eq("gpt-4o-mini")
        end
      end
    end

    describe "#smoke_test" do
      it "passes on JSON-capable CLIs by extracting the exact OK response from JSONL output" do
        jsonl_output = [
          {"text" => "OK"},
          {"usage" => {"input_tokens" => 1, "output_tokens" => 1}}
        ].map { |o| JSON.generate(o) }.join("\n")

        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "-p", "Reply with exactly OK.", "--output-format", "json"],
          anything
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: jsonl_output,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        result = provider.smoke_test

        expect(result).to include(
          ok: true,
          status: "ok",
          message: "Smoke test passed",
          output: "OK",
          exit_code: 0
        )
      end

      it "passes on JSON-capable CLIs when Copilot returns event envelopes" do
        jsonl_output = [
          {"type" => "assistant.message", "data" => {"content" => "O"}},
          {"type" => "assistant.delta", "data" => {"deltaContent" => "K"}},
          {"type" => "usage", "data" => {"inputTokens" => 1, "outputTokens" => 1}}
        ].map { |o| JSON.generate(o) }.join("\n")

        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "-p", "Reply with exactly OK.", "--output-format", "json"],
          anything
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: jsonl_output,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        result = provider.smoke_test

        expect(result).to include(
          ok: true,
          status: "ok",
          message: "Smoke test passed",
          output: "OK",
          exit_code: 0
        )
      end

      it "uses silent prompt mode on older CLIs so the exact OK contract still passes" do
        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {}
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "github-copilot-cli 0.0.421",
            stderr: "",
            exit_code: 0,
            duration: 0.1
          )
        )

        expect(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "-p", "Reply with exactly OK.", "-s"],
          anything
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "OK\n",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        result = provider.smoke_test

        expect(result).to include(
          ok: true,
          status: "ok",
          message: "Smoke test passed",
          output: "OK",
          exit_code: 0
        )
      end
    end
  end
end
