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
    it "returns a Copilot-specific contract without expected_output" do
      contract = described_class.smoke_test_contract
      expect(contract).to eq(AgentHarness::Providers::GithubCopilot::SMOKE_TEST_CONTRACT)
      expect(contract[:expected_output]).to be_nil
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
    subject(:provider) { described_class.new }

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
        expect(semantics[:uses_subcommand]).to be true
        expect(semantics[:non_interactive_flag]).to be_nil
        expect(semantics[:legitimate_exit_codes]).to eq([0])
        expect(semantics[:stderr_is_diagnostic]).to be true
        expect(semantics[:parses_rate_limit_reset]).to be false
      end
    end

    describe "#build_command" do
      it "places the subcommand, prompt, and output-format flag before optional flags" do
        command = provider.send(:build_command, "Hello", {})

        expect(command).to eq([
          "github-copilot-cli",
          "what-the-shell",
          "Hello",
          "--output-format",
          "json"
        ])
      end

      it "adds dangerous mode flags only when explicitly requested" do
        command = provider.send(:build_command, "Hello", {dangerous_mode: true})

        expect(command).to eq([
          "github-copilot-cli",
          "what-the-shell",
          "Hello",
          "--output-format",
          "json",
          "--allow-all-tools"
        ])
      end

      it "appends session resume flags after the prompt and any dangerous mode flags" do
        command = provider.send(:build_command, "Hello", {session: "session-123"})

        expect(command).to eq([
          "github-copilot-cli",
          "what-the-shell",
          "Hello",
          "--output-format",
          "json",
          "--resume",
          "session-123"
        ])
      end

      it "appends session resume flags after dangerous mode flags when both are provided" do
        command = provider.send(:build_command, "Hello", {dangerous_mode: true, session: "session-123"})

        expect(command).to eq([
          "github-copilot-cli",
          "what-the-shell",
          "Hello",
          "--output-format",
          "json",
          "--allow-all-tools",
          "--resume",
          "session-123"
        ])
      end
    end

    describe "#parse_response" do
      let(:provider) { described_class.new }

      def make_result(stdout:, stderr: "", exit_code: 0)
        AgentHarness::CommandExecutor::Result.new(
          stdout: stdout, stderr: stderr, exit_code: exit_code
        )
      end

      it "aggregates text from event envelope data.content" do
        jsonl = <<~JSONL
          {"type":"assistant","data":{"content":"Hello"}}
          {"type":"assistant","data":{"content":" world"}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("Hello world")
        expect(response.error).to be_nil
      end

      it "extracts tokens from event envelope camelCase fields" do
        jsonl = <<~JSONL
          {"type":"assistant","data":{"content":"hi"}}
          {"type":"usage","data":{"inputTokens":10,"outputTokens":20}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.tokens).to eq({input: 10, output: 20, total: 30})
      end

      it "extracts tokens from top-level usage snake_case fields" do
        jsonl = '{"usage":{"input_tokens":5,"output_tokens":8}}'
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.tokens).to eq({input: 5, output: 8, total: 13})
      end

      it "extracts text from top-level output key" do
        jsonl = '{"output":"plain output"}'
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("plain output")
      end

      it "extracts text from top-level content key" do
        jsonl = '{"content":"content output"}'
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("content output")
      end

      it "extracts text from nested message.content" do
        jsonl = '{"message":{"content":"nested output"}}'
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("nested output")
      end

      it "falls back to raw stdout when no JSONL text is found" do
        result = make_result(stdout: "raw output here")
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("raw output here")
      end

      it "sets error when command fails" do
        result = make_result(stdout: "out", stderr: "err text", exit_code: 1)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.error).to eq("out\nerr text")
      end

      it "skips unparseable lines" do
        jsonl = "not json\n{\"type\":\"assistant\",\"data\":{\"content\":\"ok\"}}\n"
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("ok")
      end

      it "does not double-count tokens when message and usage events both carry token fields" do
        jsonl = <<~JSONL
          {"type":"assistant","data":{"content":"hi","inputTokens":10,"outputTokens":5}}
          {"type":"usage","data":{"inputTokens":10,"outputTokens":5}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "counts tokens from assistant.usage events" do
        jsonl = <<~JSONL
          {"type":"assistant.usage","data":{"inputTokens":7,"outputTokens":3}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.tokens).to eq({input: 7, output: 3, total: 10})
      end

      it "ignores token fields on non-usage envelope events" do
        jsonl = '{"type":"assistant","data":{"content":"hi","inputTokens":10,"outputTokens":5}}'
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("hi")
        expect(response.tokens).to be_nil
      end

      it "returns nil tokens when no usage data present" do
        jsonl = '{"type":"assistant","data":{"content":"hi"}}'
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.tokens).to be_nil
      end
    end
  end
end
