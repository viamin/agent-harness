# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe AgentHarness::Providers::Codex do
  describe ".provider_name" do
    it "returns :codex" do
      expect(described_class.provider_name).to eq(:codex)
    end
  end

  describe ".binary_name" do
    it "returns codex" do
      expect(described_class.binary_name).to eq("codex")
    end
  end

  describe ".installation_contract" do
    it "exposes Codex CLI install metadata" do
      contract = described_class.installation_contract

      expect(contract).to include(
        source: :npm,
        package_name: "@openai/codex",
        version: "0.116.0",
        binary_name: "codex"
      )
      expect(contract[:package]).to eq("@openai/codex@0.116.0")
      expect(contract[:supported_versions]).to eq(["0.116.0"])
      expect(contract[:version_requirement]).to eq([">= 0.116.0", "< 0.117.0"])
      expect(contract[:install_command]).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "@openai/codex@0.116.0"]
      )
    end

    it "keeps the runtime binary aligned with the install contract" do
      contract = described_class.installation_contract

      expect(contract[:binary_name]).to eq(described_class.binary_name)
    end

    it "supports explicit version selection through the published contract API" do
      contract = described_class.installation_contract(version: "0.116.5")

      expect(contract).to include(
        package: "@openai/codex@0.116.5",
        version: "0.116.5"
      )
      expect(contract[:supported_versions]).to eq(["0.116.5"])
      expect(contract[:install_command]).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "@openai/codex@0.116.5"]
      )
    end

    it "deep-freezes nested contract values" do
      contract = described_class.installation_contract

      expect { contract[:install_command_prefix] << "codex" }.to raise_error(FrozenError)
      expect { contract[:install_command] << "codex" }.to raise_error(FrozenError)
      expect { contract[:supported_versions] << "0.115.0" }.to raise_error(FrozenError)
      expect { contract[:version_requirement] << ">= 0.115.0" }.to raise_error(FrozenError)
    end
  end

  describe ".install_command" do
    it "builds the default install command from the contract" do
      expect(described_class.install_command).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "@openai/codex@0.116.0"]
      )
    end

    it "supports explicit version overrides" do
      expect(described_class.install_command(version: "0.116.5")).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "@openai/codex@0.116.5"]
      )
    end

    it "rejects unsupported explicit version overrides" do
      expect {
        described_class.install_command(version: "0.115.0")
      }.to raise_error(ArgumentError, /Unsupported Codex CLI version "0.115.0"/)
    end

    it "rejects malformed version strings with a provider-specific message" do
      expect {
        described_class.installation_contract(version: "not-a-version")
      }.to raise_error(ArgumentError, /Unsupported Codex CLI version/)
    end

    it "rejects nil version" do
      expect {
        described_class.installation_contract(version: nil)
      }.to raise_error(ArgumentError, /Unsupported Codex CLI version/)
    end

    it "rejects empty version" do
      expect {
        described_class.installation_contract(version: "")
      }.to raise_error(ArgumentError, /Unsupported Codex CLI version/)
    end

    it "normalizes padded version strings in the install command and contract" do
      contract = described_class.installation_contract(version: " 0.116.5 ")

      expect(contract[:version]).to eq("0.116.5")
      expect(contract[:install_command]).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "@openai/codex@0.116.5"]
      )
    end
  end

  describe ".firewall_requirements" do
    it "returns required domains" do
      requirements = described_class.firewall_requirements
      expect(requirements[:domains]).to include("api.openai.com")
    end
  end

  describe "instance" do
    subject(:provider) { described_class.new }

    describe "#name" do
      it "returns codex" do
        expect(provider.name).to eq("codex")
      end
    end

    describe "#display_name" do
      it "returns OpenAI Codex CLI" do
        expect(provider.display_name).to eq("OpenAI Codex CLI")
      end
    end

    describe "#configuration_schema" do
      it "has no configurable fields" do
        schema = provider.configuration_schema
        expect(schema[:fields]).to eq([])
      end

      it "reports openai_compatible as true" do
        expect(provider.configuration_schema[:openai_compatible]).to be true
      end

      it "uses api_key auth mode" do
        expect(provider.configuration_schema[:auth_modes]).to eq([:api_key])
      end
    end

    describe "#supports_sessions?" do
      it "returns true" do
        expect(provider.supports_sessions?).to be true
      end
    end

    describe "#session_flags" do
      it "returns session flags when session provided" do
        flags = provider.session_flags("session-123")
        expect(flags).to eq(["--session", "session-123"])
      end

      it "returns empty when no session" do
        expect(provider.session_flags(nil)).to eq([])
      end
    end

    describe "#supports_dangerous_mode?" do
      it "returns true" do
        expect(provider.supports_dangerous_mode?).to be true
      end
    end

    describe "#dangerous_mode_flags" do
      it "returns --full-auto" do
        expect(provider.dangerous_mode_flags).to eq(["--full-auto"])
      end
    end

    describe "#execution_semantics" do
      it "reports sandbox_aware as true" do
        expect(provider.execution_semantics[:sandbox_aware]).to be true
      end

      it "reports uses_subcommand as true" do
        expect(provider.execution_semantics[:uses_subcommand]).to be true
      end

      it "reports output_format as json" do
        expect(provider.execution_semantics[:output_format]).to eq(:json)
      end
    end

    describe "#send_message" do
      let(:mock_executor) { instance_double(AgentHarness::CommandExecutor) }
      subject(:provider) { described_class.new(executor: mock_executor) }
      let(:success_result) do
        AgentHarness::CommandExecutor::Result.new(
          stdout: "response",
          stderr: "",
          exit_code: 0,
          duration: 1.0
        )
      end

      it "builds command with exec subcommand, --json flag, and positional prompt" do
        expect(mock_executor).to receive(:execute).with(
          ["codex", "exec", "--json", "Hello"],
          anything
        ).and_return(success_result)

        provider.send_message(prompt: "Hello")
      end

      it "includes session flags when session is provided" do
        expect(mock_executor).to receive(:execute).with(
          ["codex", "exec", "--json", "--session", "session-123", "Hello"],
          anything
        ).and_return(success_result)

        provider.send_message(prompt: "Hello", session: "session-123")
      end

      context "when running inside a Docker container" do
        let(:docker_executor) { instance_double(AgentHarness::DockerCommandExecutor) }
        subject(:provider) { described_class.new(executor: docker_executor) }

        it "includes --full-auto to skip nested sandboxing" do
          allow(docker_executor).to receive(:is_a?).with(AgentHarness::DockerCommandExecutor).and_return(true)
          expect(docker_executor).to receive(:execute).with(
            ["codex", "exec", "--json", "--full-auto", "Hello"],
            anything
          ).and_return(success_result)

          provider.send_message(prompt: "Hello")
        end

        it "uses only the bypass flag when externally sandboxed, skipping --full-auto" do
          allow(docker_executor).to receive(:is_a?).with(AgentHarness::DockerCommandExecutor).and_return(true)
          expect(docker_executor).to receive(:execute).with(
            ["codex", "exec", "--json", "--dangerously-bypass-approvals-and-sandbox", "Hello"],
            anything
          ).and_return(success_result)

          provider.send_message(prompt: "Hello", externally_sandboxed: true)
        end
      end

      context "when dangerous_mode is requested" do
        it "includes --full-auto" do
          expect(mock_executor).to receive(:execute).with(
            ["codex", "exec", "--json", "--full-auto", "Hello"],
            anything
          ).and_return(success_result)

          provider.send_message(prompt: "Hello", dangerous_mode: true)
        end
      end

      context "with non-Array default_flags" do
        let(:config_with_string_flags) do
          AgentHarness::ProviderConfig.new(:codex).tap do |c|
            c.default_flags = "--quiet"
          end
        end
        let(:provider_with_string_flags) { described_class.new(config: config_with_string_flags, executor: mock_executor) }

        it "raises an error" do
          expect { provider_with_string_flags.send_message(prompt: "Hello") }.to raise_error(
            AgentHarness::ProviderError, /default_flags must be an array/
          )
        end
      end

      context "with default_flags configured" do
        let(:config_with_flags) do
          AgentHarness::ProviderConfig.new(:codex).tap do |c|
            c.default_flags = ["--quiet", "--no-color"]
          end
        end
        let(:provider_with_flags) { described_class.new(config: config_with_flags, executor: mock_executor) }

        it "includes default_flags in the command" do
          expect(mock_executor).to receive(:execute).with(
            ["codex", "exec", "--json", "--quiet", "--no-color", "Hello"],
            anything
          ).and_return(success_result)

          provider_with_flags.send_message(prompt: "Hello")
        end
      end

      context "with default_flags containing --full-auto and externally_sandboxed" do
        let(:config_with_full_auto) do
          AgentHarness::ProviderConfig.new(:codex).tap do |c|
            c.default_flags = ["--full-auto", "--quiet"]
            c.externally_sandboxed = true
          end
        end
        let(:provider_with_full_auto) { described_class.new(config: config_with_full_auto, executor: mock_executor) }

        it "strips --full-auto from default_flags to avoid sandbox mode conflict" do
          expect(mock_executor).to receive(:execute).with(
            ["codex", "exec", "--json", "--quiet", "--dangerously-bypass-approvals-and-sandbox", "Hello"],
            anything
          ).and_return(success_result)

          provider_with_full_auto.send_message(prompt: "Hello")
        end
      end

      it "returns a Response object" do
        jsonl_output = [
          JSON.generate({"type" => "message.delta", "delta" => {"text" => "response output"}}),
          JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 10, "output_tokens" => 5}})
        ].join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: jsonl_output,
            stderr: "",
            exit_code: 0,
            duration: 1.5
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response).to be_a(AgentHarness::Response)
        expect(response.output).to eq("response output")
      end

      it "preserves legitimate_exit_codes metadata on responses" do
        allow(mock_executor).to receive(:execute).and_return(success_result)

        response = provider.send_message(prompt: "Hello")
        expect(response.metadata[:legitimate_exit_codes]).to eq([0])
      end

      context "with dangerous_mode option" do
        it "includes --full-auto flag" do
          expect(mock_executor).to receive(:execute).with(
            ["codex", "exec", "--json", "--full-auto", "Hello"],
            anything
          ).and_return(success_result)

          provider.send_message(prompt: "Hello", dangerous_mode: true)
        end
      end

      context "with externally_sandboxed option" do
        it "includes bypass flag compatible with current codex cli" do
          expect(mock_executor).to receive(:execute).with(
            ["codex", "exec", "--json", "--dangerously-bypass-approvals-and-sandbox", "Hello"],
            anything
          ).and_return(success_result)

          provider.send_message(prompt: "Hello", externally_sandboxed: true)
        end
      end

      context "with externally_sandboxed config" do
        let(:sandboxed_config) do
          AgentHarness::ProviderConfig.new(:codex).tap do |c|
            c.externally_sandboxed = true
          end
        end
        let(:sandboxed_provider) { described_class.new(config: sandboxed_config, executor: mock_executor) }

        it "includes bypass flag from config" do
          expect(mock_executor).to receive(:execute).with(
            ["codex", "exec", "--json", "--dangerously-bypass-approvals-and-sandbox", "Hello"],
            anything
          ).and_return(success_result)

          sandboxed_provider.send_message(prompt: "Hello")
        end
      end

      context "with both dangerous_mode and externally_sandboxed" do
        it "uses only the bypass flag, skipping --full-auto to avoid sandbox mode conflict" do
          expect(mock_executor).to receive(:execute).with(
            ["codex", "exec", "--json", "--dangerously-bypass-approvals-and-sandbox", "Hello"],
            anything
          ).and_return(success_result)

          provider.send_message(prompt: "Hello", dangerous_mode: true, externally_sandboxed: true)
        end
      end

      context "with externally_sandboxed: false overriding config" do
        let(:sandboxed_config) do
          AgentHarness::ProviderConfig.new(:codex).tap do |c|
            c.externally_sandboxed = true
          end
        end
        let(:sandboxed_provider) { described_class.new(config: sandboxed_config, executor: mock_executor) }

        it "does not include bypass flag when per-call option is false" do
          expect(mock_executor).to receive(:execute).with(
            ["codex", "exec", "--json", "Hello"],
            anything
          ).and_return(success_result)

          sandboxed_provider.send_message(prompt: "Hello", externally_sandboxed: false)
        end
      end

      context "when sandbox failure is detected in stderr with exit_code 0" do
        it "returns a failed response" do
          sandbox_failure_result = AgentHarness::CommandExecutor::Result.new(
            stdout: "",
            stderr: "bwrap: No permissions to create a new namespace",
            exit_code: 0,
            duration: 1.0
          )

          allow(mock_executor).to receive(:execute).and_return(sandbox_failure_result)

          response = provider.send_message(prompt: "Hello")
          expect(response).to be_a(AgentHarness::Response)
          expect(response.success?).to be false
          expect(response.exit_code).not_to eq(0)
          expect(response.error).to include("Sandbox failure detected")
        end

        it "preserves parsed token data in sandbox failure response" do
          jsonl_output = [
            JSON.generate({"type" => "message.delta", "delta" => {"text" => "response"}}),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 50, "output_tokens" => 25}})
          ].join("\n")

          sandbox_failure_result = AgentHarness::CommandExecutor::Result.new(
            stdout: jsonl_output,
            stderr: "bwrap: No permissions to create a new namespace",
            exit_code: 0,
            duration: 1.0
          )

          allow(mock_executor).to receive(:execute).and_return(sandbox_failure_result)

          response = provider.send_message(prompt: "Hello")
          expect(response.success?).to be false
          expect(response.output).to eq("response")
          expect(response.tokens).to eq({input: 50, output: 25, total: 75})
        end
      end

      context "with item.completed event parsing" do
        it "extracts text from item.completed.item.text" do
          jsonl_output = [
            JSON.generate({"type" => "item.completed", "item" => {"type" => "message", "role" => "assistant", "text" => "final response"}}),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 10, "output_tokens" => 5}})
          ].join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq("final response")
        end

        it "extracts text from item.completed item content array" do
          jsonl_output = [
            JSON.generate({
              "type" => "item.completed",
              "item" => {
                "type" => "message",
                "role" => "assistant",
                "content" => [
                  {"type" => "output_text", "text" => "part one "},
                  {"type" => "output_text", "text" => "part two"}
                ]
              }
            }),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 10, "output_tokens" => 5}})
          ].join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq("part one part two")
        end

        it "prefers item.completed text over message.delta when both present" do
          jsonl_output = [
            JSON.generate({"type" => "message.delta", "delta" => {"text" => "streaming partial"}}),
            JSON.generate({"type" => "item.completed", "item" => {"type" => "message", "role" => "assistant", "text" => "complete answer"}}),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 10, "output_tokens" => 5}})
          ].join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq("complete answer")
        end

        it "prefers turn.completed result over item.completed text" do
          jsonl_output = [
            JSON.generate({"type" => "item.completed", "item" => {"type" => "message", "role" => "assistant", "text" => "item text"}}),
            JSON.generate({"type" => "turn.completed", "result" => "turn result", "usage" => {"input_tokens" => 10, "output_tokens" => 5}})
          ].join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq("turn result")
        end

        it "preserves completed assistant text across multiple turns" do
          jsonl_output = [
            JSON.generate({"type" => "item.completed", "item" => {"type" => "message", "role" => "assistant", "text" => "first answer"}}),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 10, "output_tokens" => 5}}),
            JSON.generate({"type" => "item.completed", "item" => {"type" => "message", "role" => "assistant", "text" => "second answer"}}),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 8, "output_tokens" => 4}})
          ].join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq("first answersecond answer")
          expect(response.tokens).to eq({input: 18, output: 9, total: 27})
        end

        it "handles item.completed with only content array and no text field" do
          jsonl_output = [
            JSON.generate({
              "type" => "item.completed",
              "item" => {
                "type" => "message",
                "role" => "assistant",
                "content" => [{"type" => "output_text", "text" => "from content array"}]
              }
            }),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 10, "output_tokens" => 5}})
          ].join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq("from content array")
        end

        it "prefers item text over content array when both are present" do
          jsonl_output = [
            JSON.generate({
              "type" => "item.completed",
              "item" => {
                "type" => "message",
                "role" => "assistant",
                "text" => "text field value",
                "content" => [{"type" => "output_text", "text" => "content array value"}]
              }
            }),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 10, "output_tokens" => 5}})
          ].join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq("text field value")
        end

        it "extracts text from item.completed when role field is absent" do
          jsonl_output = [
            JSON.generate({
              "type" => "item.completed",
              "item" => {"type" => "agent_message", "text" => "response without role"}
            }),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 10, "output_tokens" => 5}})
          ].join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq("response without role")
        end

        it "extracts text from item.completed content array when role field is nil" do
          jsonl_output = [
            JSON.generate({
              "type" => "item.completed",
              "item" => {
                "type" => "agent_message",
                "content" => [{"type" => "output_text", "text" => "content without role"}]
              }
            }),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 10, "output_tokens" => 5}})
          ].join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq("content without role")
        end

        it "returns empty normalized output for non-agent_message item.completed events without a role" do
          jsonl_output = [
            JSON.generate({
              "type" => "item.completed",
              "item" => {"type" => "reasoning", "text" => "internal reasoning"}
            }),
            JSON.generate({
              "type" => "item.completed",
              "item" => {"type" => "tool_call", "text" => "tool output"}
            }),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 10, "output_tokens" => 5}})
          ].join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq("")
          expect(response.tokens).to eq({input: 10, output: 5, total: 15})
        end

        it "returns empty normalized output for item.completed events with explicit non-assistant role" do
          jsonl_output = [
            JSON.generate({
              "type" => "item.completed",
              "item" => {"type" => "message", "role" => "user", "text" => "user text"}
            }),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 10, "output_tokens" => 5}})
          ].join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq("")
          expect(response.tokens).to eq({input: 10, output: 5, total: 15})
        end

        it "ignores agent_message items with explicit non-assistant roles" do
          jsonl_output = [
            JSON.generate({
              "type" => "item.completed",
              "item" => {"type" => "agent_message", "role" => "tool", "text" => "tool text"}
            }),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 10, "output_tokens" => 5}})
          ].join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq("")
          expect(response.tokens).to eq({input: 10, output: 5, total: 15})
        end
      end

      context "with wrapped JSONL event parsing" do
        it "extracts final assistant text from response_item events" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message_delta", "message" => "partial"}}),
            JSON.generate({
              "type" => "response_item",
              "payload" => {
                "type" => "message",
                "role" => "assistant",
                "content" => [{"type" => "output_text", "text" => "final wrapped answer"}]
              }
            })
          ].join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq("final wrapped answer")
        end

        it "extracts token usage from wrapped token_count events" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "token_count", "info" => nil}}),
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message", "message" => "wrapped output"}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "total_token_usage" => {
                    "input_tokens" => 42,
                    "cached_input_tokens" => 30,
                    "output_tokens" => 7
                  }
                }
              }
            })
          ].join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq("wrapped output")
          expect(response.tokens).to eq({input: 42, output: 7, total: 49})
        end

        it "preserves wrapped zero-usage reports and explicit total_tokens" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message", "message" => "wrapped output"}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "total_token_usage" => {
                    "input_tokens" => 0,
                    "output_tokens" => 0,
                    "reasoning_output_tokens" => 17,
                    "total_tokens" => 17
                  }
                }
              }
            })
          ].join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq("wrapped output")
          expect(response.tokens).to eq({input: 0, output: 0, total: 17})
          expect(response.total_tokens).to eq(17)
        end
      end

      context "with token usage parsing" do
        it "extracts token usage from JSONL turn.completed events" do
          jsonl_output = [
            JSON.generate({"type" => "message.delta", "delta" => {"text" => "Hello!"}}),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 100, "cached_input_tokens" => 50, "output_tokens" => 25}})
          ].join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq("Hello!")
          expect(response.tokens).to eq({input: 100, output: 25, total: 125})
          expect(response.input_tokens).to eq(100)
          expect(response.output_tokens).to eq(25)
          expect(response.total_tokens).to eq(125)
        end

        it "aggregates token usage across multiple turns" do
          jsonl_output = [
            JSON.generate({"type" => "message.delta", "delta" => {"text" => "Part 1"}}),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 50, "output_tokens" => 10}}),
            JSON.generate({"type" => "message.delta", "delta" => {"text" => "Part 2"}}),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 60, "output_tokens" => 20}})
          ].join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 2.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.tokens).to eq({input: 110, output: 30, total: 140})
        end

        it "preserves zero-usage token reports from turn.completed events" do
          jsonl_output = [
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 0, "output_tokens" => 0}})
          ].join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.tokens).to eq({input: 0, output: 0, total: 0})
        end

        it "extracts result from turn.completed when usage lacks token fields" do
          jsonl_output = [
            JSON.generate({"type" => "message.delta", "delta" => {"text" => "partial"}}),
            JSON.generate({"type" => "turn.completed", "usage" => {"cached_input_tokens" => 100}, "result" => "final answer"})
          ].join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq("final answer")
          expect(response.tokens).to be_nil
        end

        it "extracts text from turn.completed result field" do
          jsonl_output = [
            JSON.generate({"type" => "message.delta", "delta" => {"text" => "partial"}}),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 10, "output_tokens" => 5}, "result" => "final answer"})
          ].join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq("final answer")
        end

        it "handles JSONL output without usage data" do
          jsonl_output = [
            JSON.generate({"type" => "message.delta", "delta" => {"text" => "Hello!"}}),
            JSON.generate({"type" => "turn.completed"})
          ].join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq("Hello!")
          expect(response.tokens).to be_nil
        end

        it "returns empty normalized output when JSONL contains only usage data" do
          jsonl_output = [
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 10, "output_tokens" => 5}})
          ].join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq("")
          expect(response.tokens).to eq({input: 10, output: 5, total: 15})
        end

        it "handles non-JSON output gracefully with nil tokens" do
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

        it "handles empty output gracefully" do
          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: "",
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq("")
          expect(response.tokens).to be_nil
        end

        it "handles mixed JSONL and non-JSON lines" do
          jsonl_output = [
            "some debug line",
            JSON.generate({"type" => "message.delta", "delta" => {"text" => "result"}}),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 10, "output_tokens" => 5}}),
            "another non-json line"
          ].join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq("result")
          expect(response.tokens).to eq({input: 10, output: 5, total: 15})
        end

        it "skips non-Hash JSON values in JSONL lines" do
          jsonl_output = [
            "123",
            "null",
            "true",
            JSON.generate({"type" => "message.delta", "delta" => {"text" => "after scalars"}}),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 5, "output_tokens" => 3}})
          ].join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq("after scalars")
          expect(response.tokens).to eq({input: 5, output: 3, total: 8})
        end

        it "returns nil tokens when usage hash has no token fields" do
          jsonl_output = [
            JSON.generate({"type" => "message.delta", "delta" => {"text" => "Hello!"}}),
            JSON.generate({"type" => "turn.completed", "usage" => {"cached_input_tokens" => 50}})
          ].join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: jsonl_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq("Hello!")
          expect(response.tokens).to be_nil
        end

        it "records tokens with the global token tracker" do
          jsonl_output = [
            JSON.generate({"type" => "message.delta", "delta" => {"text" => "Tracked"}}),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 50, "output_tokens" => 25}})
          ].join("\n")

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
    end

    describe "#supports_dangerous_mode?" do
      it "returns true" do
        expect(provider.supports_dangerous_mode?).to be true
      end
    end

    describe "#dangerous_mode_flags" do
      it "returns the full-auto flag" do
        expect(provider.dangerous_mode_flags).to eq(["--full-auto"])
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

      it "includes quota patterns" do
        patterns = provider.error_patterns
        expect(patterns[:quota_exceeded]).not_to be_empty
      end

      it "includes sandbox failure patterns" do
        patterns = provider.error_patterns
        expect(patterns[:sandbox_failure]).not_to be_empty
        expect(patterns[:sandbox_failure].any? { |p| "bwrap: No permissions to create a new namespace" =~ p }).to be true
      end

      it "does not misclassify embedded numeric substrings as HTTP status codes" do
        patterns = provider.error_patterns
        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new("request id 401234 failed"),
            patterns
          )
        ).to eq(:unknown)

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new("request id 4294967295 failed"),
            patterns
          )
        ).to eq(:unknown)
      end
    end

    describe "#auth_status" do
      let(:tmp_dir) { Dir.mktmpdir }
      let(:config_path) { File.join(tmp_dir, "config.json") }

      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return(nil)
        allow(ENV).to receive(:[]).with("CODEX_CONFIG_DIR").and_return(tmp_dir)
      end

      after do
        FileUtils.rm_rf(tmp_dir)
      end

      context "with OPENAI_API_KEY set" do
        before do
          allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return("sk-test-key-123")
        end

        it "returns valid with api_key auth method" do
          status = provider.auth_status
          expect(status[:valid]).to be true
          expect(status[:auth_method]).to eq(:api_key)
        end
      end

      context "with invalid OPENAI_API_KEY format" do
        before do
          allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return("invalid-key")
        end

        it "returns invalid with format error" do
          status = provider.auth_status
          expect(status[:valid]).to be false
          expect(status[:error]).to include("does not appear to be a valid")
        end

        it "includes auth_method key" do
          status = provider.auth_status
          expect(status).to have_key(:auth_method)
        end
      end

      context "with blank OPENAI_API_KEY" do
        before do
          allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return("   ")
        end

        it "does not treat blank key as valid" do
          status = provider.auth_status
          expect(status[:valid]).to be false
        end
      end

      context "with valid config file" do
        before do
          File.write(config_path, JSON.generate({"api_key" => "sk-config-key"}))
        end

        it "returns valid with config_file auth method" do
          status = provider.auth_status
          expect(status[:valid]).to be true
          expect(status[:auth_method]).to eq(:config_file)
        end
      end

      context "with apiKey format in config file" do
        before do
          File.write(config_path, JSON.generate({"apiKey" => "sk-config-key"}))
        end

        it "returns valid" do
          status = provider.auth_status
          expect(status[:valid]).to be true
        end
      end

      context "with OPENAI_API_KEY key in config file" do
        before do
          File.write(config_path, JSON.generate({"OPENAI_API_KEY" => "sk-config-key"}))
        end

        it "returns valid" do
          status = provider.auth_status
          expect(status[:valid]).to be true
        end
      end

      context "with no credentials" do
        it "returns invalid with helpful message" do
          status = provider.auth_status
          expect(status[:valid]).to be false
          expect(status[:error]).to include("No OpenAI API key")
          expect(status[:error]).to include("OPENAI_API_KEY")
        end

        it "includes auth_method key" do
          status = provider.auth_status
          expect(status).to have_key(:auth_method)
        end
      end

      context "with non-Hash JSON in config file" do
        before do
          File.write(config_path, JSON.generate(["not", "a", "hash"]))
        end

        it "returns invalid with no credentials message" do
          status = provider.auth_status
          expect(status[:valid]).to be false
          expect(status[:error]).to include("No OpenAI API key")
        end
      end

      context "with empty key in config file" do
        before do
          File.write(config_path, JSON.generate({"api_key" => ""}))
        end

        it "returns invalid" do
          status = provider.auth_status
          expect(status[:valid]).to be false
        end
      end

      context "with invalid JSON in config file" do
        before do
          File.write(config_path, "not json")
        end

        it "returns invalid with JSON error" do
          status = provider.auth_status
          expect(status[:valid]).to be false
          expect(status[:error]).to include("Invalid JSON")
        end
      end

      context "with permission denied on config file" do
        before do
          File.write(config_path, JSON.generate({"api_key" => "sk-test"}))
          File.chmod(0o000, config_path)
        end

        after do
          File.chmod(0o644, config_path)
        end

        it "returns invalid with permission error" do
          status = provider.auth_status
          expect(status[:valid]).to be false
          expect(status[:error]).to include("Permission denied")
        end
      end
    end

    describe "#health_status" do
      let(:tmp_codex_config_dir) { Dir.mktmpdir }

      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return("sk-test-key")
        allow(ENV).to receive(:[]).with("CODEX_CONFIG_DIR").and_return(tmp_codex_config_dir)
      end

      after do
        FileUtils.remove_entry(tmp_codex_config_dir) if tmp_codex_config_dir && Dir.exist?(tmp_codex_config_dir)
      end

      context "when CLI is available and authenticated" do
        before do
          allow(described_class).to receive(:available?).and_return(true)
        end

        it "returns healthy" do
          status = provider.health_status
          expect(status[:healthy]).to be true
          expect(status[:message]).to include("available and authenticated")
        end
      end

      context "when CLI is not available" do
        before do
          allow(described_class).to receive(:available?).and_return(false)
        end

        it "returns unhealthy" do
          status = provider.health_status
          expect(status[:healthy]).to be false
          expect(status[:message]).to include("not found in PATH")
        end
      end

      context "when not authenticated" do
        before do
          allow(described_class).to receive(:available?).and_return(true)
          allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return(nil)
        end

        it "returns unhealthy with auth error" do
          status = provider.health_status
          expect(status[:healthy]).to be false
          expect(status[:message]).to include("No OpenAI API key")
        end
      end
    end

    describe "#validate_config" do
      context "with valid config" do
        it "returns valid" do
          result = provider.validate_config
          expect(result[:valid]).to be true
          expect(result[:errors]).to be_empty
        end
      end

      context "with non-Array default_flags" do
        let(:bad_executor) { instance_double(AgentHarness::CommandExecutor) }
        let(:config_with_string_flags) do
          AgentHarness::ProviderConfig.new(:codex).tap do |c|
            c.default_flags = "--verbose"
          end
        end
        let(:provider_with_string_flags) do
          described_class.new(config: config_with_string_flags, executor: bad_executor)
        end

        it "returns invalid" do
          result = provider_with_string_flags.validate_config
          expect(result[:valid]).to be false
          expect(result[:errors].first).to include("must be an array")
        end
      end

      context "with non-string default_flags" do
        let(:bad_executor) { instance_double(AgentHarness::CommandExecutor) }
        let(:config_with_bad_flags) do
          AgentHarness::ProviderConfig.new(:codex).tap do |c|
            c.default_flags = ["--verbose", 123]
          end
        end
        let(:provider_with_bad_flags) do
          described_class.new(config: config_with_bad_flags, executor: bad_executor)
        end

        it "returns invalid" do
          result = provider_with_bad_flags.validate_config
          expect(result[:valid]).to be false
          expect(result[:errors].first).to include("non-string")
        end
      end
    end
  end
end
