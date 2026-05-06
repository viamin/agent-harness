# frozen_string_literal: true

RSpec.describe AgentHarness::Providers::GithubCopilot do
  describe ".binary_name" do
    it "returns the modern copilot binary" do
      expect(described_class.binary_name).to eq("copilot")
    end
  end

  describe ".available?" do
    let(:executor) { instance_double(AgentHarness::CommandExecutor) }

    before do
      allow(AgentHarness.configuration).to receive(:command_executor).and_return(executor)
    end

    it "returns true when the modern copilot binary is present" do
      allow(executor).to receive(:which).with("copilot").and_return("/usr/bin/copilot")

      expect(described_class.available?).to be true
    end

    it "returns false when only the legacy binary is present" do
      allow(executor).to receive(:which).with("copilot").and_return(nil)

      expect(described_class.available?).to be false
    end
  end

  describe ".installation_contract" do
    it "exposes npm install metadata for the modern CLI" do
      contract = described_class.installation_contract

      expect(contract).to include(
        source: :npm,
        package_name: "@github/copilot",
        binary_name: "copilot"
      )
      expect(contract[:install_command]).to eq(["npm", "install", "-g", "@github/copilot"])
      expect(contract[:version]).to be_nil
    end

    it "supports an explicit version override" do
      contract = described_class.installation_contract(version: "1.0.0")

      expect(contract[:package]).to eq("@github/copilot@1.0.0")
      expect(contract[:version]).to eq("1.0.0")
      expect(contract[:install_command]).to eq(["npm", "install", "-g", "@github/copilot@1.0.0"])
    end
  end

  describe "instance" do
    let(:executor) { instance_double(AgentHarness::CommandExecutor) }
    let(:config) { AgentHarness::ProviderConfig.new(:github_copilot) }

    subject(:provider) { described_class.new(config: config, executor: executor) }

    describe "#capabilities" do
      it "advertises json, MCP, and dangerous mode support" do
        expect(provider.capabilities).to include(
          json_mode: true,
          mcp: true,
          dangerous_mode: true,
          tool_use: true
        )
      end
    end

    describe "#execution_semantics" do
      it "declares non-interactive autopilot json execution" do
        expect(provider.execution_semantics).to include(
          prompt_delivery: :arg,
          output_format: :json,
          non_interactive_flag: "--autopilot",
          uses_subcommand: false
        )
      end
    end

    describe "#api_key_env_var_names" do
      it "includes modern Copilot auth env vars" do
        expect(provider.api_key_env_var_names).to eq(["COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"])
      end
    end

    describe "#subscription_unset_vars" do
      it "unsets env vars that would override stored subscription auth" do
        expect(provider.subscription_unset_vars).to include(
          "COPILOT_GITHUB_TOKEN",
          "GH_TOKEN",
          "GITHUB_TOKEN",
          "COPILOT_PROVIDER_API_KEY",
          "COPILOT_PROVIDER_BASE_URL"
        )
      end
    end

    describe "#build_command" do
      it "builds an autopilot command with full permissions and json output" do
        command = provider.send(:build_command, "Hello", {})

        expect(command).to eq([
          "copilot",
          "--autopilot",
          "--yolo",
          "--max-autopilot-continues",
          "50",
          "--output-format",
          "json",
          "-p",
          "Hello"
        ])
      end

      it "includes configured and runtime model overrides and runtime flags" do
        config.model = "gpt-4o"
        runtime = AgentHarness::ProviderRuntime.new(model: "gpt-4o-mini", flags: ["--stream=off"])

        command = provider.send(:build_command, "Hello", {provider_runtime: runtime})

        expect(command).to eq([
          "copilot",
          "--autopilot",
          "--yolo",
          "--max-autopilot-continues",
          "50",
          "--output-format",
          "json",
          "--model",
          "gpt-4o-mini",
          "--stream=off",
          "-p",
          "Hello"
        ])
      end

      it "accepts runtime metadata for the autopilot continuation limit" do
        runtime = AgentHarness::ProviderRuntime.new(metadata: {max_autopilot_continues: 12})

        command = provider.send(:build_command, "Hello", {provider_runtime: runtime})

        expect(command[4]).to eq("12")
      end

      it "adds request-scoped MCP configuration" do
        server = AgentHarness::McpServer.new(
          name: "filesystem",
          transport: "stdio",
          command: "npx",
          args: ["-y", "@modelcontextprotocol/server-filesystem", "/workspace"]
        )
        allow(provider).to receive(:write_mcp_config_file).and_return("/tmp/copilot-mcp.json")

        command = provider.send(:build_command, "Hello", {mcp_servers: [server]})

        expect(command).to include("--additional-mcp-config", "@/tmp/copilot-mcp.json")
      end
    end

    describe "#plan_execution" do
      it "returns a command, env, and preparation tuple" do
        plan = provider.plan_execution(prompt: "Hello")

        expect(plan).to eq(
          command: [
            "copilot",
            "--autopilot",
            "--yolo",
            "--max-autopilot-continues",
            "50",
            "--output-format",
            "json",
            "-p",
            "Hello"
          ],
          env: {"COPILOT_ALLOW_ALL" => "true"},
          preparation: nil
        )
      end
    end

    describe "#send_message" do
      it "executes the autopilot command and parses JSON output" do
        result = AgentHarness::CommandExecutor::Result.new(
          stdout: [
            '{"type":"assistant.message","message":{"role":"assistant","content":"OK"}}',
            '{"type":"session.shutdown","usage":{"input_tokens":10,"output_tokens":5}}'
          ].join("\n"),
          stderr: "",
          exit_code: 0,
          duration: 0.2
        )

        expect(executor).to receive(:execute).with(
          [
            "copilot",
            "--autopilot",
            "--yolo",
            "--max-autopilot-continues",
            "50",
            "--output-format",
            "json",
            "-p",
            "Reply with exactly OK."
          ],
          hash_including(env: {"COPILOT_ALLOW_ALL" => "true"})
        ).and_return(result)

        response = provider.send_message(prompt: "Reply with exactly OK.")

        expect(response.output).to eq("OK")
        expect(response.tokens).to eq(input: 10, output: 5, total: 15)
      end
    end

    describe "#parse_container_output" do
      it "parses JSONL output into text and token usage" do
        response = provider.parse_container_output(
          stdout: [
            '{"type":"assistant.message","message":{"role":"assistant","content":"result text"}}',
            '{"type":"session.shutdown","usage":{"input_tokens":10,"output_tokens":5}}'
          ].join("\n"),
          exit_code: 0,
          duration: 2.0
        )

        expect(response.output).to eq("result text")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "keeps plain text output when JSON parsing is not possible" do
        response = provider.parse_container_output(stdout: "plain text", exit_code: 0, duration: 1.0)

        expect(response.output).to eq("plain text")
      end

      it "merges snapshot with trailing delta events" do
        response = provider.parse_container_output(
          stdout: [
            '{"type":"assistant.message","message":{"role":"assistant","content":"Hello"}}',
            '{"type":"assistant.delta","message":{"role":"assistant","deltaContent":" world!"}}'
          ].join("\n"),
          exit_code: 0,
          duration: 1.0
        )

        expect(response.output).to eq("Hello world!")
      end

      it "extracts tokens from per-model modelMetrics trees" do
        response = provider.parse_container_output(
          stdout: [
            '{"type":"assistant.message","message":{"role":"assistant","content":"OK"}}',
            '{"type":"session.shutdown","data":{"modelMetrics":{"gpt-4o":{"usage":{"inputTokens":44,"outputTokens":11}}}}}'
          ].join("\n"),
          exit_code: 0,
          duration: 1.0
        )

        expect(response.tokens).to eq({input: 44, output: 11, total: 55})
      end

      it "surfaces non-zero exit codes as failures" do
        response = provider.parse_container_output(
          stdout: "",
          stderr: "continuation limit reached",
          exit_code: 1,
          duration: 0.5
        )

        expect(response).to be_failed
        expect(response.error).to include("continuation limit reached")
      end
    end

    describe "#resolve_chat_api_key" do
      it "prefers COPILOT_GITHUB_TOKEN over other token env vars" do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("COPILOT_GITHUB_TOKEN").and_return("ghu_copilot")
        allow(ENV).to receive(:[]).with("GH_TOKEN").and_return("ghu_gh")
        allow(ENV).to receive(:[]).with("GITHUB_TOKEN").and_return("ghu_github")

        expect(provider.send(:resolve_chat_api_key)).to eq("ghu_copilot")
      end
    end
  end
end
