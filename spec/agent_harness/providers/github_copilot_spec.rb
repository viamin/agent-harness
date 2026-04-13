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
        allow(provider).to receive(:copilot_cli_supports_json_output?).and_return(true)
        semantics = provider.execution_semantics
        expect(semantics[:prompt_delivery]).to eq(:arg)
        expect(semantics[:output_format]).to eq(:json)
        expect(semantics[:sandbox_aware]).to be false
        expect(semantics[:uses_subcommand]).to be true
        expect(semantics[:non_interactive_flag]).to be_nil
        expect(semantics[:legitimate_exit_codes]).to eq([0])
        expect(semantics[:stderr_is_diagnostic]).to be true
        expect(semantics[:parses_rate_limit_reset]).to be false
      end

      it "reports legacy text output when the installed CLI lacks JSON mode" do
        allow(provider).to receive(:copilot_cli_supports_json_output?).and_return(false)

        expect(provider.execution_semantics[:output_format]).to eq(:text)
      end
    end

    describe "#build_command" do
      it "places the subcommand, prompt, and output-format flag before optional flags" do
        allow(provider).to receive(:copilot_cli_supports_json_output?).and_return(true)
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
        allow(provider).to receive(:copilot_cli_supports_json_output?).and_return(true)
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
        allow(provider).to receive(:copilot_cli_supports_json_output?).and_return(true)
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
        allow(provider).to receive(:copilot_cli_supports_json_output?).and_return(true)
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

      it "omits the output-format flag when the installed CLI is too old" do
        allow(provider).to receive(:copilot_cli_supports_json_output?).and_return(false)
        command = provider.send(:build_command, "Hello", {})

        expect(command).to eq([
          "github-copilot-cli",
          "what-the-shell",
          "Hello"
        ])
      end

      it "falls back to legacy text output when version detection fails" do
        executor = instance_double(AgentHarness::CommandExecutor)
        allow(executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {}
        ).and_raise(StandardError, "version probe failed")
        provider = described_class.new(executor: executor)

        command = provider.send(:build_command, "Hello", {})

        expect(command).to eq([
          "github-copilot-cli",
          "what-the-shell",
          "Hello"
        ])
      end
    end

    describe "#send_message" do
      it "re-probes JSON support with the request runtime env before building the command" do
        executor = instance_double(AgentHarness::CommandExecutor)
        provider = described_class.new(executor: executor)
        legacy_runtime = AgentHarness::ProviderRuntime.new(env: {"PATH" => "/tmp/legacy-copilot/bin"})

        allow(executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {}
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "github-copilot-cli 0.0.422\n",
            stderr: "",
            exit_code: 0
          )
        )
        allow(executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {"PATH" => "/tmp/legacy-copilot/bin"}
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "github-copilot-cli 0.0.421\n",
            stderr: "",
            exit_code: 0
          )
        )
        allow(executor).to receive(:execute).with(
          ["github-copilot-cli", "what-the-shell", "Hello"],
          timeout: 300,
          env: {"PATH" => "/tmp/legacy-copilot/bin"}
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "echo legacy\n",
            stderr: "",
            exit_code: 0
          )
        )

        expect(provider.send(:copilot_cli_supports_json_output?)).to be true

        response = provider.send(
          :send_message,
          prompt: "Hello",
          provider_runtime: legacy_runtime
        )

        expect(response.output).to eq("echo legacy\n")
      end

      it "maps malformed provider_runtime env errors through provider error handling" do
        expect {
          provider.send_message(prompt: "Hello", provider_runtime: {env: "bad"})
        }.to raise_error(AgentHarness::ProviderError, /env must be a Hash/)
      end
    end

    describe "#parse_response" do
      let(:provider) { described_class.new }

      def make_result(stdout:, stderr: "", exit_code: 0)
        AgentHarness::CommandExecutor::Result.new(
          stdout: stdout, stderr: stderr, exit_code: exit_code
        )
      end

      before do
        allow(provider).to receive(:copilot_cli_supports_json_output?).and_return(true)
      end

      it "aggregates text from event envelope data.content" do
        jsonl = <<~JSONL
          {"type":"assistant","data":{"content":"Hello"}}
          {"type":"assistant.message","data":{"content":" world"}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("Hello world")
        expect(response.error).to be_nil
      end

      it "aggregates text from assistant.message_delta deltaContent chunks" do
        jsonl = <<~JSONL
          {"type":"assistant.message_delta","data":{"deltaContent":"Hello"}}
          {"type":"assistant.message_delta","data":{"deltaContent":" world"}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("Hello world")
        expect(response.error).to be_nil
      end

      it "prefers the final assistant.message over preceding delta chunks" do
        jsonl = <<~JSONL
          {"type":"assistant.message_delta","data":{"deltaContent":"Hel"}}
          {"type":"assistant.message_delta","data":{"deltaContent":"lo"}}
          {"type":"assistant.message","data":{"content":"Hello"}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("Hello")
        expect(response.error).to be_nil
      end

      it "keeps delta chunks when the trailing assistant.message content is empty" do
        jsonl = <<~JSONL
          {"type":"assistant.message_delta","data":{"deltaContent":"Hel"}}
          {"type":"assistant.message_delta","data":{"deltaContent":"lo"}}
          {"type":"assistant.message","data":{"content":""}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("Hello")
        expect(response.error).to be_nil
      end

      it "prefers the final assistant.message over preceding delta chunks even when literal stdout intervenes" do
        jsonl = <<~JSONL
          {"type":"assistant.message_delta","data":{"deltaContent":"Hel"}}
          note from tool
          {"type":"assistant.message","data":{"content":"Hello"}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("note from tool\nHello")
        expect(response.error).to be_nil
      end

      it "preserves assistant.message_delta output when no final assistant.message is emitted" do
        jsonl = <<~JSONL
          {"type":"assistant.message_delta","data":{"deltaContent":"partial"}}
          {"type":"assistant.message_delta","data":{"deltaContent":" reply"}}
        JSONL
        result = make_result(stdout: jsonl, stderr: "interrupted", exit_code: 1)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("partial reply")
        expect(response.error).to eq("interrupted\n#{jsonl.strip}")
      end

      it "ignores envelope content from non-assistant reply events" do
        jsonl = <<~JSONL
          {"type":"assistant.reasoning","data":{"content":"scratchpad"}}
          {"type":"user.message","data":{"content":"user prompt"}}
          {"type":"system.message","data":{"content":"system prompt"}}
          {"type":"assistant.message","data":{"content":"final answer"}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("final answer")
      end

      it "suppresses Copilot control-event namespaces from rendered output" do
        jsonl = <<~JSONL
          {"type":"tool.execution_start","data":{"tool":"bash"}}
          {"type":"permission.requested","data":{"scope":"tools"}}
          {"type":"user_input.requested","data":{"prompt":"confirm"}}
          {"type":"elicitation.requested","data":{"fields":["path"]}}
          {"type":"exit_plan_mode.requested","data":{"reason":"done"}}
          {"type":"skill.started","data":{"name":"planner"}}
          {"type":"subagent.started","data":{"name":"planner"}}
          {"type":"external_tool.finished","data":{"name":"shell"}}
          {"type":"command.completed","data":{"argv":["ls"]}}
          {"type":"abort","data":{"reason":"interrupted"}}
          {"type":"assistant.message","data":{"content":"final answer"}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("final answer")
      end

      it "suppresses exact Copilot root control event types from rendered output" do
        jsonl = <<~JSONL
          {"type":"user","data":{"content":"user prompt"}}
          {"type":"system","data":{"content":"system prompt"}}
          {"type":"tool","data":{"name":"bash"}}
          {"type":"command","data":{"argv":["ls"]}}
          {"type":"assistant.message","data":{"content":"final answer"}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("final answer")
      end

      it "ignores typed top-level content on malformed control events" do
        jsonl = <<~JSONL
          {"type":"assistant.reasoning","content":"scratchpad"}
          {"type":"assistant.message","data":{"content":"final answer"}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("final answer")
      end

      it "preserves literal typed JSON objects that are not Copilot control events" do
        jsonl = <<~JSONL
          {"type":"record","value":1}
          {"type":"assistant.message","data":{"content":"final answer"}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("{\"type\":\"record\",\"value\":1}\nfinal answer")
      end

      it "preserves literal typed JSON objects with top-level content that are not Copilot control events" do
        jsonl = <<~JSONL
          {"type":"record","content":"literal payload"}
          {"type":"assistant.message","data":{"content":"final answer"}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("{\"type\":\"record\",\"content\":\"literal payload\"}\nfinal answer")
      end

      it "preserves unknown typed JSON usage objects literally and ignores their token payloads" do
        jsonl = <<~JSONL
          {"type":"record","usage":{"input_tokens":99,"output_tokens":77}}
          {"type":"assistant.message","data":{"content":"final answer"}}
          {"type":"usage","data":{"inputTokens":4,"outputTokens":2}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("{\"type\":\"record\",\"usage\":{\"input_tokens\":99,\"output_tokens\":77}}\nfinal answer")
        expect(response.tokens).to eq({input: 4, output: 2, total: 6})
      end

      it "ignores non-string event content values" do
        jsonl = <<~JSONL
          {"type":"assistant.message","data":{"content":["not","text"]}}
          {"type":"assistant.message","data":{"content":"ok"}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("ok")
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

      it "ignores top-level token payloads on typed objects without envelope data" do
        jsonl = <<~JSONL
          {"type":"assistant.reasoning","usage":{"input_tokens":99,"output_tokens":1}}
          {"type":"assistant.message","data":{"content":"ok"}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("ok")
        expect(response.tokens).to be_nil
      end

      it "ignores top-level token payloads on non-assistant role objects" do
        jsonl = <<~JSONL
          {"role":"user","usage":{"input_tokens":99,"output_tokens":1}}
          {"role":"assistant","content":"ok"}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("ok")
        expect(response.tokens).to be_nil
      end

      it "ignores top-level token payloads on non-assistant nested message objects" do
        jsonl = <<~JSONL
          {"message":{"role":"system","content":"prompt"},"tokens":{"input_tokens":99,"output_tokens":1}}
          {"message":{"role":"assistant","content":"ok"}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("ok")
        expect(response.tokens).to be_nil
      end

      it "falls back to assistant.message token fields when usage events are absent" do
        jsonl = '{"type":"assistant.message","data":{"content":"hi","inputTokens":10,"outputTokens":5}}'
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("hi")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
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

      it "ignores top-level non-assistant role content objects" do
        jsonl = <<~JSONL
          {"role":"user","content":"user prompt"}
          {"role":"assistant","content":"assistant reply"}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("assistant reply")
      end

      it "ignores top-level non-assistant nested message content objects" do
        jsonl = <<~JSONL
          {"message":{"role":"system","content":"system prompt"}}
          {"message":{"role":"assistant","content":"assistant reply"}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("assistant reply")
      end

      it "ignores sibling top-level content on non-assistant nested message objects" do
        jsonl = <<~JSONL
          {"content":"user prompt","message":{"role":"system"}}
          {"content":"assistant reply","message":{"role":"assistant"}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("assistant reply")
      end

      it "ignores sibling top-level output on non-assistant nested message objects" do
        jsonl = <<~JSONL
          {"output":"user prompt","message":{"role":"user"}}
          {"output":"assistant reply","message":{"role":"assistant"}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("assistant reply")
      end

      it "falls back to raw stdout when no JSONL text is found" do
        result = make_result(stdout: "raw output here")
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("raw output here")
      end

      it "sets error when command fails" do
        result = make_result(stdout: "out", stderr: "err text", exit_code: 1)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.error).to eq("err text\nout")
      end

      it "preserves unparseable plain-text lines alongside assistant replies" do
        jsonl = "not json\n{\"type\":\"assistant\",\"data\":{\"content\":\"ok\"}}\n"
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("not json\nok")
      end

      it "preserves plain-text stdout when mixed with structured control events" do
        jsonl = <<~JSONL
          {"type":"usage","data":{"inputTokens":3,"outputTokens":4}}
          literal shell text
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("literal shell text\n")
        expect(response.tokens).to eq({input: 3, output: 4, total: 7})
      end

      it "preserves plain-text stdout alongside assistant reply events" do
        jsonl = <<~JSONL
          preface
          {"type":"assistant.message","data":{"content":"echo hello"}}
          epilogue
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("preface\necho hello\nepilogue\n")
      end

      it "preserves blank stdout lines alongside assistant reply events" do
        jsonl = "preface\n\n{\"type\":\"assistant.message\",\"data\":{\"content\":\"echo hello\"}}\n\n"
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("preface\n\necho hello\n\n")
      end

      it "preserves literal JSON object stdout alongside assistant reply events" do
        jsonl = <<~JSONL
          {"argv":["echo","hello"]}
          {"type":"assistant.message","data":{"content":"echo hello"}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("{\"argv\":[\"echo\",\"hello\"]}\necho hello")
      end

      it "preserves literal JSON objects with non-string content fields" do
        jsonl = <<~JSONL
          {"content":["echo","hello"]}
          {"type":"assistant.message","data":{"content":"echo hello"}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("{\"content\":[\"echo\",\"hello\"]}\necho hello")
      end

      it "preserves literal JSON objects with malformed top-level usage payloads" do
        jsonl = <<~JSONL
          {"usage":"invalid"}
          {"type":"assistant.message","data":{"content":"echo hello"}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("{\"usage\":\"invalid\"}\necho hello")
        expect(response.tokens).to be_nil
      end

      it "preserves malformed top-level usage hashes when token extraction fails" do
        jsonl = <<~JSONL
          {"usage":{"input_tokens":{}}}
          {"type":"assistant.message","data":{"content":"echo hello"}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("{\"usage\":{\"input_tokens\":{}}}\necho hello")
        expect(response.tokens).to be_nil
      end

      it "preserves empty top-level tokens hashes as literal JSON output" do
        jsonl = <<~JSONL
          {"tokens":{}}
          {"type":"assistant.message","data":{"content":"echo hello"}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("{\"tokens\":{}}\necho hello")
        expect(response.tokens).to be_nil
      end

      it "preserves line boundaries around literal JSON after assistant reply events" do
        jsonl = <<~JSONL
          {"type":"assistant.message","data":{"content":"echo hello"}}
          {"argv":["echo","hello"]}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("echo hello\n{\"argv\":[\"echo\",\"hello\"]}\n")
      end

      it "does not add a leading newline after empty assistant events before literal output" do
        jsonl = <<~JSONL
          {"type":"assistant.message","data":{"content":""}}
          literal output
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("literal output\n")
      end

      it "ignores scalar JSON lines when extracting text" do
        jsonl = "true\n1\n{\"type\":\"assistant\",\"data\":{\"content\":\"ok\"}}\n"
        result = make_result(stdout: jsonl)
        response = nil

        expect { response = provider.send(:parse_response, result, duration: 1.0) }.not_to raise_error
        expect(response.output).to eq("true\n1\nok")
      end

      it "ignores scalar JSON lines when no structured events are present" do
        result = make_result(stdout: "true\n")
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("true\n")
        expect(response.tokens).to be_nil
      end

      it "preserves scalar JSON stdout alongside structured control events" do
        jsonl = <<~JSONL
          {"type":"usage","data":{"inputTokens":3,"outputTokens":4}}
          true
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("true\n")
        expect(response.tokens).to eq({input: 3, output: 4, total: 7})
      end

      it "prefers usage events over assistant reply token fields when both are present" do
        jsonl = <<~JSONL
          {"type":"assistant.message","data":{"content":"hi","inputTokens":10,"outputTokens":5}}
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

      it "extracts tokens from session.shutdown model metrics" do
        jsonl = <<~JSONL
          {"type":"session.shutdown","data":{"modelMetrics":{"gpt-4o":{"usage":{"inputTokens":7,"outputTokens":3}}}}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.tokens).to eq({input: 7, output: 3, total: 10})
      end

      it "sums session.shutdown token totals across model metrics" do
        jsonl = <<~JSONL
          {"type":"session.shutdown","data":{"modelMetrics":{"gpt-4o":{"usage":{"inputTokens":7,"outputTokens":3}},"gpt-4o-mini":{"usage":{"inputTokens":2,"outputTokens":5}}}}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.tokens).to eq({input: 9, output: 8, total: 17})
      end

      it "prefers streamed usage events over session.shutdown totals" do
        jsonl = <<~JSONL
          {"type":"usage","data":{"inputTokens":3,"outputTokens":2}}
          {"type":"assistant.usage","data":{"inputTokens":4,"outputTokens":1}}
          {"type":"session.shutdown","data":{"modelMetrics":{"gpt-4o":{"usage":{"inputTokens":9,"outputTokens":8}}}}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.tokens).to eq({input: 7, output: 3, total: 10})
      end

      it "falls back per metric from session.shutdown only when streamed usage omits values" do
        jsonl = <<~JSONL
          {"type":"usage","data":{"inputTokens":3}}
          {"type":"session.shutdown","data":{"modelMetrics":{"gpt-4o":{"usage":{"inputTokens":9,"outputTokens":8}}}}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.tokens).to eq({input: 3, output: 8, total: 11})
      end

      it "prefers streamed usage metrics when session.shutdown values are also present" do
        jsonl = <<~JSONL
          {"type":"usage","data":{"inputTokens":3,"outputTokens":2}}
          {"type":"session.shutdown","data":{"modelMetrics":{"gpt-4o":{"usage":{"inputTokens":[],"outputTokens":8}}}}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.tokens).to eq({input: 3, output: 2, total: 5})
      end

      it "falls back to assistant reply token fields before session.shutdown totals" do
        jsonl = <<~JSONL
          {"type":"assistant.message","data":{"content":"echo hello","inputTokens":3,"outputTokens":2}}
          {"type":"session.shutdown","data":{"modelMetrics":{"gpt-4o":{"usage":{"inputTokens":9,"outputTokens":8}}}}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("echo hello")
        expect(response.tokens).to eq({input: 3, output: 2, total: 5})
      end

      it "falls back to session.shutdown totals when per-turn token data is absent" do
        jsonl = <<~JSONL
          {"type":"assistant.message","data":{"content":"echo hello"}}
          {"type":"session.shutdown","data":{"modelMetrics":{"gpt-4o":{"usage":{"inputTokens":9,"outputTokens":8}}}}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("echo hello")
        expect(response.tokens).to eq({input: 9, output: 8, total: 17})
      end

      it "ignores malformed session.shutdown model metrics" do
        jsonl = <<~JSONL
          {"type":"session.shutdown","data":{"modelMetrics":{"gpt-4o":{"usage":"bad"},"gpt-4o-mini":true}}}
          {"type":"assistant.message","data":{"content":"ok"}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("ok")
        expect(response.tokens).to be_nil
      end

      it "ignores token fields on non-reply, non-usage envelope events" do
        jsonl = '{"type":"assistant.reasoning","data":{"content":"hi","inputTokens":10,"outputTokens":5}}'
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("")
        expect(response.tokens).to be_nil
      end

      it "does not surface structured usage events as raw output when no reply text is present" do
        jsonl = '{"type":"usage","data":{"inputTokens":3,"outputTokens":4}}'
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("")
        expect(response.tokens).to eq({input: 3, output: 4, total: 7})
      end

      it "sums assistant reply token payloads when multiple reply events include tokens" do
        jsonl = <<~JSONL
          {"type":"assistant","data":{"content":"Hello","inputTokens":3,"outputTokens":2}}
          {"type":"assistant.message","data":{"content":" world","inputTokens":10,"outputTokens":5}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("Hello world")
        expect(response.tokens).to eq({input: 13, output: 7, total: 20})
      end

      it "returns nil tokens when no usage data present" do
        jsonl = '{"type":"assistant","data":{"content":"hi"}}'
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.tokens).to be_nil
      end

      it "extracts snake_case token fields from usage events" do
        jsonl = '{"type":"usage","data":{"input_tokens":3,"output_tokens":4}}'
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.tokens).to eq({input: 3, output: 4, total: 7})
      end

      it "does not double-count mixed token aliases on usage events" do
        jsonl = '{"type":"usage","data":{"inputTokens":3,"input_tokens":9,"outputTokens":4,"output_tokens":8}}'
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.tokens).to eq({input: 3, output: 4, total: 7})
      end

      it "prefers present zero-valued camelCase aliases on usage events" do
        jsonl = '{"type":"usage","data":{"inputTokens":0,"input_tokens":9,"outputTokens":4,"output_tokens":8}}'
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.tokens).to eq({input: 0, output: 4, total: 4})
      end

      it "falls back to secondary aliases when the preferred usage-event aliases are malformed" do
        jsonl = '{"type":"usage","data":{"inputTokens":1.5,"input_tokens":9,"outputTokens":[],"output_tokens":8}}'
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.tokens).to eq({input: 9, output: 8, total: 17})
      end

      it "ignores malformed token values on usage events" do
        jsonl = <<~JSONL
          {"type":"usage","data":{"inputTokens":true,"outputTokens":[]}}
          {"type":"assistant.message","data":{"content":"ok"}}
        JSONL
        result = make_result(stdout: jsonl)
        response = nil

        expect { response = provider.send(:parse_response, result, duration: 1.0) }.not_to raise_error
        expect(response.output).to eq("ok")
        expect(response.tokens).to be_nil
      end

      it "ignores fractional and negative token values on usage events" do
        jsonl = <<~JSONL
          {"type":"usage","data":{"inputTokens":1.5,"outputTokens":-2}}
          {"type":"assistant.message","data":{"content":"ok"}}
        JSONL
        result = make_result(stdout: jsonl)
        response = nil

        expect { response = provider.send(:parse_response, result, duration: 1.0) }.not_to raise_error
        expect(response.output).to eq("ok")
        expect(response.tokens).to be_nil
      end

      it "ignores invalid usage-event token aliases when the sibling metric is valid" do
        jsonl = '{"type":"usage","data":{"inputTokens":1.5,"outputTokens":6}}'
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.tokens).to eq({input: 0, output: 6, total: 6})
      end

      it "extracts tokens from top-level tokens key" do
        jsonl = '{"tokens":{"input_tokens":2,"output_tokens":6}}'
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.tokens).to eq({input: 2, output: 6, total: 8})
      end

      it "falls back to top-level tokens when usage is present but empty" do
        jsonl = '{"usage":{},"tokens":{"input_tokens":2,"output_tokens":6}}'
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.tokens).to eq({input: 2, output: 6, total: 8})
      end

      it "falls back to top-level tokens when usage is present but malformed" do
        jsonl = '{"usage":{"input_tokens":{}},"tokens":{"input_tokens":2,"output_tokens":6}}'
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("")
        expect(response.tokens).to eq({input: 2, output: 6, total: 8})
      end

      it "falls back to top-level tokens for metrics missing from usage" do
        jsonl = '{"usage":{"input_tokens":2},"tokens":{"output_tokens":6}}'
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.tokens).to eq({input: 2, output: 6, total: 8})
      end

      it "falls back to top-level tokens for metrics invalid in usage" do
        jsonl = '{"usage":{"input_tokens":{},"output_tokens":6},"tokens":{"input_tokens":2,"output_tokens":9}}'
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.tokens).to eq({input: 2, output: 6, total: 8})
      end

      it "extracts tokens from top-level camelCase usage fields" do
        jsonl = '{"usage":{"inputTokens":9,"outputTokens":1}}'
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.tokens).to eq({input: 9, output: 1, total: 10})
      end

      it "extracts tokens from top-level input/output shorthand fields" do
        jsonl = '{"usage":{"input":4,"output":7}}'
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.tokens).to eq({input: 4, output: 7, total: 11})
      end

      it "does not double-count mixed token aliases in top-level usage payloads" do
        jsonl = '{"usage":{"input_tokens":4,"inputTokens":9,"input":12,"output_tokens":7,"outputTokens":10,"output":15}}'
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.tokens).to eq({input: 4, output: 7, total: 11})
      end

      it "prefers present zero-valued canonical aliases in top-level usage payloads" do
        jsonl = '{"usage":{"input_tokens":0,"inputTokens":9,"input":12,"output_tokens":7,"outputTokens":10,"output":15}}'
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.tokens).to eq({input: 0, output: 7, total: 7})
      end

      it "falls back to secondary aliases when the preferred top-level usage aliases are malformed" do
        jsonl = '{"usage":{"input_tokens":{},"inputTokens":9,"output_tokens":"-2","outputTokens":8}}'
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.tokens).to eq({input: 9, output: 8, total: 17})
      end

      it "ignores malformed token values in top-level usage payloads" do
        jsonl = <<~JSONL
          {"usage":{"input_tokens":{},"output_tokens":false}}
          {"output":"ok"}
        JSONL
        result = make_result(stdout: jsonl)
        response = nil

        expect { response = provider.send(:parse_response, result, duration: 1.0) }.not_to raise_error
        expect(response.output).to eq("{\"usage\":{\"input_tokens\":{},\"output_tokens\":false}}\nok")
        expect(response.tokens).to be_nil
      end

      it "ignores fractional and negative token values in top-level usage payloads" do
        jsonl = <<~JSONL
          {"usage":{"input_tokens":1.5,"output_tokens":"-2"}}
          {"output":"ok"}
        JSONL
        result = make_result(stdout: jsonl)
        response = nil

        expect { response = provider.send(:parse_response, result, duration: 1.0) }.not_to raise_error
        expect(response.output).to eq("{\"usage\":{\"input_tokens\":1.5,\"output_tokens\":\"-2\"}}\nok")
        expect(response.tokens).to be_nil
      end

      it "ignores invalid top-level token aliases when the sibling metric is valid" do
        jsonl = '{"usage":{"input_tokens":"-2","output_tokens":6}}'
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.tokens).to eq({input: 0, output: 6, total: 6})
      end

      it "handles nil stdout gracefully" do
        result = make_result(stdout: nil, exit_code: 0)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq("")
        expect(response.error).to be_nil
      end

      it "sets error from stdout only when stderr is empty" do
        result = make_result(stdout: "stdout error", stderr: "", exit_code: 1)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.error).to eq("stdout error")
      end

      it "sets error from stderr only when stdout is empty" do
        result = make_result(stdout: "", stderr: "stderr error", exit_code: 1)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.error).to eq("stderr error")
      end

      it "preserves legitimate exit codes on the response metadata" do
        allow(provider).to receive(:execution_semantics).and_return(
          provider.execution_semantics.merge(legitimate_exit_codes: [0, 2])
        )
        result = make_result(stdout: "partial success", exit_code: 2)
        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.metadata[:legitimate_exit_codes]).to eq([0, 2])
        expect(response).to be_success
      end

      it "processes a full conversation with text and usage events" do
        jsonl = <<~JSONL
          {"type":"assistant","data":{"content":"Hello"}}
          {"type":"assistant","data":{"content":" world!"}}
          {"type":"usage","data":{"inputTokens":50,"outputTokens":25}}
        JSONL
        result = make_result(stdout: jsonl)
        response = provider.send(:parse_response, result, duration: 2.5)

        expect(response.output).to eq("Hello world!")
        expect(response.tokens).to eq({input: 50, output: 25, total: 75})
        expect(response.error).to be_nil
      end

      it "treats stdout as plain text when JSON output is unsupported" do
        allow(provider).to receive(:copilot_cli_supports_json_output?).and_return(false)
        result = make_result(stdout: '{"content":"literal shell text"}')

        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.output).to eq('{"content":"literal shell text"}')
        expect(response.tokens).to be_nil
      end

      it "uses base error parsing for legacy text mode" do
        allow(provider).to receive(:copilot_cli_supports_json_output?).and_return(false)
        result = make_result(stdout: "partial output", stderr: "fatal error", exit_code: 1)

        response = provider.send(:parse_response, result, duration: 1.0)

        expect(response.error).to eq("fatal error\npartial output")
        expect(response.metadata[:legitimate_exit_codes]).to eq([0])
      end
    end

    describe "#copilot_cli_supports_json_output?" do
      it "returns true for CLI versions that support JSON output" do
        executor = instance_double(AgentHarness::CommandExecutor)
        allow(executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {}
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "github-copilot-cli 0.0.422\n",
            stderr: "",
            exit_code: 0
          )
        )
        provider = described_class.new(executor: executor)

        expect(provider.send(:copilot_cli_supports_json_output?)).to be true
      end

      it "returns false for CLI versions older than JSON output support" do
        executor = instance_double(AgentHarness::CommandExecutor)
        allow(executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {}
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "github-copilot-cli 0.0.421\n",
            stderr: "",
            exit_code: 0
          )
        )
        provider = described_class.new(executor: executor)

        expect(provider.send(:copilot_cli_supports_json_output?)).to be false
      end

      it "caches the detected version capability" do
        executor = instance_double(AgentHarness::CommandExecutor)
        allow(executor).to receive(:execute).once.with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {}
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "github-copilot-cli 0.0.422\n",
            stderr: "",
            exit_code: 0
          )
        )
        provider = described_class.new(executor: executor)

        2.times { provider.send(:copilot_cli_supports_json_output?) }
      end

      it "caches unknown version support as false" do
        executor = instance_double(AgentHarness::CommandExecutor)
        allow(executor).to receive(:execute).once.with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {}
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "github-copilot-cli development build\n",
            stderr: "",
            exit_code: 0
          )
        )
        provider = described_class.new(executor: executor)

        expect(provider.send(:copilot_cli_supports_json_output?)).to be false
        expect(provider.send(:copilot_cli_supports_json_output?)).to be false
      end

      it "caches capability independently for each probe environment" do
        executor = instance_double(AgentHarness::CommandExecutor)
        allow(executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {"PATH" => "/tmp/new-copilot/bin"}
        ).once.and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "github-copilot-cli 0.0.422\n",
            stderr: "",
            exit_code: 0
          )
        )
        allow(executor).to receive(:execute).with(
          ["github-copilot-cli", "--version"],
          timeout: 5,
          env: {"PATH" => "/tmp/old-copilot/bin"}
        ).once.and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "github-copilot-cli 0.0.421\n",
            stderr: "",
            exit_code: 0
          )
        )
        provider = described_class.new(executor: executor)

        env_a = {"PATH" => "/tmp/new-copilot/bin"}
        env_b = {"PATH" => "/tmp/old-copilot/bin"}

        2.times { expect(provider.send(:copilot_cli_supports_json_output?, env: env_a)).to be true }
        2.times { expect(provider.send(:copilot_cli_supports_json_output?, env: env_b)).to be false }
      end
    end

    describe "request probe env scoping" do
      it "stores the probe env thread-locally per provider instance" do
        provider = described_class.new
        thread_envs = Queue.new
        release_threads = Queue.new

        threads = [
          Thread.new do
            provider.send(:with_request_probe_env, {"PATH" => "/tmp/thread-a"}) do
              thread_envs << provider.send(:current_probe_env)
              release_threads.pop
            end
            thread_envs << provider.send(:current_probe_env)
          end,
          Thread.new do
            provider.send(:with_request_probe_env, {"PATH" => "/tmp/thread-b"}) do
              thread_envs << provider.send(:current_probe_env)
              release_threads.pop
            end
            thread_envs << provider.send(:current_probe_env)
          end
        ]

        observed_envs = 2.times.map { thread_envs.pop }
        expect(observed_envs).to contain_exactly(
          {"PATH" => "/tmp/thread-a"},
          {"PATH" => "/tmp/thread-b"}
        )
        expect(provider.send(:current_probe_env)).to eq({})

        2.times { release_threads << true }
        threads.each(&:join)

        reset_envs = 2.times.map { thread_envs.pop }
        expect(reset_envs).to all(eq({}))
        expect(Thread.current.thread_variable_get(described_class::REQUEST_PROBE_ENV_STACK_KEY)).to be_nil
      end
    end
  end
end
