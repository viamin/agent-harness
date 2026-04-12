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
      allow(mock_executor).to receive(:execute).with(
        ["github-copilot-cli", "--version"],
        timeout: 5
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
      it "has no configurable fields" do
        expect(provider.configuration_schema[:fields]).to be_empty
      end

      it "uses oauth auth mode" do
        expect(provider.configuration_schema[:auth_modes]).to eq([:oauth])
      end

      it "is not openai compatible" do
        expect(provider.configuration_schema[:openai_compatible]).to be false
      end
    end

    describe "#supports_dangerous_mode?" do
      it "returns true" do
        expect(provider.supports_dangerous_mode?).to be true
      end
    end

    describe "#dangerous_mode_flags" do
      it "returns allow-all-tools flag" do
        expect(provider.dangerous_mode_flags).to include("--allow-all-tools")
      end
    end

    describe "#capabilities" do
      it "advertises dangerous_mode as an opt-in capability" do
        expect(provider.capabilities[:dangerous_mode]).to be true
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
        expect(semantics[:output_format]).to eq(:json)
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
          timeout: 5
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
          timeout: 5
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

      it "omits --output-format json on older CLI versions" do
        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5
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

      it "memoizes parsed CLI versions after a successful probe" do
        2.times { provider.send(:build_command, "Hello", {}) }

        expect(mock_executor).to have_received(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5
        ).once
      end

      it "retries CLI version detection after an unparsable probe result" do
        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5
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

      it "does not include dangerous-mode flags by default" do
        command = provider.send(:build_command, "Hello", {})

        expect(command).to eq([
          "github-copilot-cli",
          "-p",
          "Hello",
          "--output-format",
          "json"
        ])
      end

      it "includes session flags without dangerous-mode flags by default" do
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

      it "adds allow-all-tools when dangerous_mode is passed" do
        command = provider.send(:build_command, "Hello", {session: "session-123", dangerous_mode: true})

        expect(command).to eq([
          "github-copilot-cli",
          "-p",
          "Hello",
          "--output-format",
          "json",
          "--allow-all-tools",
          "--resume",
          "session-123"
        ])
      end
    end

    describe "#send_message" do
      before do
        allow(provider).to receive(:supports_json_output_format?).and_return(true)
      end

      it "sends prompt in non-interactive mode with JSON output" do
        jsonl_output = [
          {"text" => "response"},
          {"usage" => {"input_tokens" => 10, "output_tokens" => 5}}
        ].map { |o| JSON.generate(o) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
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

      it "falls back to plain prompt mode when JSON output is unsupported" do
        allow(provider).to receive(:supports_json_output_format?).and_return(false)

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

      context "with dangerous_mode" do
        it "adds allow-all-tools" do
          jsonl_output = [
            {"text" => "response"},
            {"usage" => {"input_tokens" => 10, "output_tokens" => 5}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          expect(mock_executor).to receive(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json", "--allow-all-tools"],
            anything
          )

          provider.send_message(prompt: "Hello", dangerous_mode: true)
        end
      end

      context "with token usage parsing" do
        it "extracts token usage from JSONL output with usage in separate line" do
          jsonl_output = [
            {"text" => "Hello! How can I help?"},
            {"usage" => {"input_tokens" => 100, "output_tokens" => 50}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
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

        it "does not use silent mode on JSON output commands so usage remains available" do
          jsonl_output = [
            {"text" => "response"},
            {"usage" => {"input_tokens" => 10, "output_tokens" => 5}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          provider.send_message(prompt: "Hello")

          expect(mock_executor).to have_received(:execute).with(
            ["github-copilot-cli", "-p", "Hello", "--output-format", "json"],
            anything
          )
        end

        it "extracts token usage from JSONL output with prompt_tokens format" do
          jsonl_output = [
            {"text" => "response"},
            {"usage" => {"prompt_tokens" => 200, "completion_tokens" => 75}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.tokens).to eq({input: 200, output: 75, total: 275})
        end

        it "extracts usage from nested message.usage" do
          jsonl_output = [
            {"text" => "response"},
            {"message" => {"usage" => {"input_tokens" => 30, "output_tokens" => 15}}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.tokens).to eq({input: 30, output: 15, total: 45})
        end

        it "ignores non-hash JSONL entries while preserving valid token usage" do
          jsonl_output = [
            {"text" => "response"},
            ["unexpected entry"],
            {"usage" => {"input_tokens" => 30, "output_tokens" => 15}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq("response")
          expect(response.tokens).to eq({input: 30, output: 15, total: 45})
        end

        it "skips malformed token counts while preserving valid JSONL usage lines" do
          jsonl_output = [
            {"text" => "response"},
            {"usage" => {"input_tokens" => "not-a-number", "output_tokens" => {}}},
            {"usage" => {"prompt_tokens" => "20", "completion_tokens" => 5}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq("response")
          expect(response.tokens).to eq({input: 20, output: 5, total: 25})
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

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq(mixed_output)
          expect(response.tokens).to be_nil
        end

        it "handles JSONL without usage data" do
          jsonl_output = [
            {"text" => "Hello!"},
            {"text" => " World!"}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq("Hello! World!")
          expect(response.tokens).to be_nil
        end

        it "records tokens with the global token tracker" do
          jsonl_output = [
            {"text" => "Tracked response"},
            {"usage" => {"input_tokens" => 50, "output_tokens" => 25}}
          ].map { |o| JSON.generate(o) }.join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
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
      end

      context "error handling" do
        it "classifies error from combined output on failure" do
          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: "",
              stderr: "not authorized",
              exit_code: 1,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
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

          response = provider.send_message(prompt: "Hello")
          expect(response.metadata).to eq({legitimate_exit_codes: [0]})
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

      it "uses silent prompt mode on older CLIs so the exact OK contract still passes" do
        allow(mock_executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5
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
