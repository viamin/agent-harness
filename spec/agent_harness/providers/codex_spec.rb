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

      it "raises AuthenticationError for OAuth refresh token reuse failures" do
        allow(mock_executor).to receive(:execute).and_raise(
          StandardError.new(<<~ERROR)
            Failed to refresh token: 401 Unauthorized
            "message": "Your refresh token has already been used to generate a new access token. Please try signing in again."
            "code": "refresh_token_reused"
            Failed to refresh token: Your access token could not be refreshed because your refresh token was already used. Please log out and sign in again.
          ERROR
        )

        expect { provider.send_message(prompt: "Hello") }.to raise_error(AgentHarness::AuthenticationError) do |error|
          expect(error.provider).to eq(:codex)
        end
      end

      it "raises AuthenticationError for shorter OAuth refresh token reuse wording" do
        allow(mock_executor).to receive(:execute).and_raise(
          StandardError.new("Failed to refresh token: refresh token already used")
        )

        expect { provider.send_message(prompt: "Hello") }.to raise_error(AgentHarness::AuthenticationError) do |error|
          expect(error.provider).to eq(:codex)
        end
      end

      it "raises AuthenticationError for failed-refresh OAuth invalid_grant failures" do
        allow(mock_executor).to receive(:execute).and_raise(
          StandardError.new("Failed to refresh token because invalid_grant")
        )

        expect { provider.send_message(prompt: "Hello") }.to raise_error(AgentHarness::AuthenticationError) do |error|
          expect(error.provider).to eq(:codex)
        end
      end

      it "raises AuthenticationError for failed-refresh invalid refresh token wording" do
        allow(mock_executor).to receive(:execute).and_raise(
          StandardError.new("Failed to refresh token because refresh token is invalid.")
        )

        expect { provider.send_message(prompt: "Hello") }.to raise_error(AgentHarness::AuthenticationError) do |error|
          expect(error.provider).to eq(:codex)
        end
      end

      it "raises AuthenticationError for multiline failed-refresh OAuth invalid_client failures" do
        allow(mock_executor).to receive(:execute).and_raise(
          StandardError.new(<<~ERROR)
            Failed to refresh token:
            "code": "invalid_client"
          ERROR
        )

        expect { provider.send_message(prompt: "Hello") }.to raise_error(AgentHarness::AuthenticationError) do |error|
          expect(error.provider).to eq(:codex)
        end
      end

      it "raises AuthenticationError for multiline access-token refresh reuse failures" do
        allow(mock_executor).to receive(:execute).and_raise(
          StandardError.new(<<~ERROR)
            Your access token could not be refreshed because
            your refresh token was already used. Please log out and sign in again.
          ERROR
        )

        expect { provider.send_message(prompt: "Hello") }.to raise_error(AgentHarness::AuthenticationError) do |error|
          expect(error.provider).to eq(:codex)
        end
      end

      it "raises AuthenticationError for multiline access-token OAuth invalid_grant failures" do
        allow(mock_executor).to receive(:execute).and_raise(
          StandardError.new(<<~ERROR)
            Your access token could not be refreshed because
            invalid_grant
          ERROR
        )

        expect { provider.send_message(prompt: "Hello") }.to raise_error(AgentHarness::AuthenticationError) do |error|
          expect(error.provider).to eq(:codex)
        end
      end

      it "raises AuthenticationError for access-token invalid refresh token wording" do
        allow(mock_executor).to receive(:execute).and_raise(
          StandardError.new(
            "Your access token could not be refreshed because your refresh token is invalid."
          )
        )

        expect { provider.send_message(prompt: "Hello") }.to raise_error(AgentHarness::AuthenticationError) do |error|
          expect(error.provider).to eq(:codex)
        end
      end

      it "does not raise AuthenticationError for transient OAuth refresh failures" do
        allow(mock_executor).to receive(:execute).and_raise(
          StandardError.new(
            "Your access token could not be refreshed because the auth service was unavailable."
          )
        )

        expect { provider.send_message(prompt: "Hello") }
          .to raise_error(AgentHarness::ProviderError, /auth service was unavailable/)
      end

      it "does not raise AuthenticationError for authentication service refresh failures" do
        allow(mock_executor).to receive(:execute).and_raise(
          StandardError.new(
            "Your access token could not be refreshed because the authentication service was unavailable."
          )
        )

        expect { provider.send_message(prompt: "Hello") }
          .to raise_error(AgentHarness::ProviderError, /authentication service was unavailable/)
      end

      it "does not raise AuthenticationError for no-article authentication service refresh failures" do
        allow(mock_executor).to receive(:execute).and_raise(
          StandardError.new(
            "Your access token could not be refreshed because authentication service was unavailable."
          )
        )

        expect { provider.send_message(prompt: "Hello") }
          .to raise_error(AgentHarness::ProviderError, /authentication service was unavailable/)
      end

      it "does not raise AuthenticationError for authentication service is-unavailable refresh failures" do
        allow(mock_executor).to receive(:execute).and_raise(
          StandardError.new(
            "Your access token could not be refreshed because the authentication service is unavailable."
          )
        )

        expect { provider.send_message(prompt: "Hello") }
          .to raise_error(AgentHarness::ProviderError, /authentication service is unavailable/)
      end

      it "does not raise AuthenticationError for temporarily unavailable authentication service refresh failures" do
        allow(mock_executor).to receive(:execute).and_raise(
          StandardError.new(
            "Your access token could not be refreshed because the authentication service was temporarily unavailable."
          )
        )

        expect { provider.send_message(prompt: "Hello") }
          .to raise_error(AgentHarness::ProviderError, /authentication service was temporarily unavailable/)
      end

      it "does not raise AuthenticationError for multiline access-token authentication service refresh failures" do
        allow(mock_executor).to receive(:execute).and_raise(
          StandardError.new(<<~ERROR)
            Your access token could not be refreshed because
            the authentication service was unavailable.
          ERROR
        )

        expect { provider.send_message(prompt: "Hello") }
          .to raise_error(AgentHarness::ProviderError, /authentication service was unavailable/)
      end

      it "does not raise AuthenticationError for failed-refresh authentication service unavailable failures" do
        allow(mock_executor).to receive(:execute).and_raise(
          StandardError.new(
            "Failed to refresh token because the authentication service was unavailable."
          )
        )

        expect { provider.send_message(prompt: "Hello") }
          .to raise_error(AgentHarness::ProviderError, /authentication service was unavailable/)
      end

      it "does not raise AuthenticationError for multiline failed-refresh authentication service unavailable failures" do
        allow(mock_executor).to receive(:execute).and_raise(
          StandardError.new(<<~ERROR)
            Failed to refresh token:
            the authentication service was unavailable.
          ERROR
        )

        expect { provider.send_message(prompt: "Hello") }
          .to raise_error(AgentHarness::ProviderError, /authentication service was unavailable/)
      end

      it "does not raise AuthenticationError for failed-refresh temporarily unavailable failures" do
        allow(mock_executor).to receive(:execute).and_raise(
          StandardError.new(
            "Failed to refresh token because the authentication service was temporarily unavailable."
          )
        )

        expect { provider.send_message(prompt: "Hello") }
          .to raise_error(AgentHarness::ProviderError, /authentication service was temporarily unavailable/)
      end

      it "does not raise AuthenticationError for failed-refresh connection error failures" do
        allow(mock_executor).to receive(:execute).and_raise(
          StandardError.new(
            "Failed to refresh token because connection error while contacting oauth endpoint."
          )
        )

        expect { provider.send_message(prompt: "Hello") }
          .to raise_error(AgentHarness::ProviderError, /connection error while contacting oauth endpoint/)
      end

      it "raises TimeoutError for OAuth refresh timeout failures" do
        allow(mock_executor).to receive(:execute).and_raise(
          StandardError.new(
            "Your access token could not be refreshed because the auth service timed out."
          )
        )

        expect { provider.send_message(prompt: "Hello") }
          .to raise_error(AgentHarness::TimeoutError, /auth service timed out/)
      end

      it "raises TimeoutError for authentication service refresh timeout failures" do
        allow(mock_executor).to receive(:execute).and_raise(
          StandardError.new(
            "Your access token could not be refreshed because the authentication service timed out."
          )
        )

        expect { provider.send_message(prompt: "Hello") }
          .to raise_error(AgentHarness::TimeoutError, /authentication service timed out/)
      end

      it "raises TimeoutError for multiline access-token authentication service timeout failures" do
        allow(mock_executor).to receive(:execute).and_raise(
          StandardError.new(<<~ERROR)
            Your access token could not be refreshed because
            the authentication service timed out.
          ERROR
        )

        expect { provider.send_message(prompt: "Hello") }
          .to raise_error(AgentHarness::TimeoutError, /authentication service timed out/)
      end

      it "raises TimeoutError for multiline failed-refresh authentication service timeout failures" do
        allow(mock_executor).to receive(:execute).and_raise(
          StandardError.new(<<~ERROR)
            Failed to refresh token:
            the authentication service timed out.
          ERROR
        )

        expect { provider.send_message(prompt: "Hello") }
          .to raise_error(AgentHarness::TimeoutError, /authentication service timed out/)
      end

      it "raises TimeoutError for hyphenated authentication service refresh timeout failures" do
        allow(mock_executor).to receive(:execute).and_raise(
          StandardError.new(
            "Your access token could not be refreshed because the authentication service timed-out."
          )
        )

        expect { provider.send_message(prompt: "Hello") }
          .to raise_error(AgentHarness::TimeoutError, /authentication service timed-out/)
      end

      it "raises TimeoutError for failed-refresh authentication service timeout failures" do
        allow(mock_executor).to receive(:execute).and_raise(
          StandardError.new(
            "Failed to refresh token because the authentication service timed out."
          )
        )

        expect { provider.send_message(prompt: "Hello") }
          .to raise_error(AgentHarness::TimeoutError, /authentication service timed out/)
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

        it "treats empty item.completed text as the final output" do
          jsonl_output = [
            JSON.generate({"type" => "message.delta", "delta" => {"text" => "stale partial"}}),
            JSON.generate({"type" => "item.completed", "item" => {"type" => "message", "role" => "assistant", "text" => ""}}),
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

        it "falls back to item.completed content when text is empty" do
          jsonl_output = [
            JSON.generate({
              "type" => "item.completed",
              "item" => {
                "type" => "message",
                "role" => "assistant",
                "text" => "",
                "content" => [{"type" => "output_text", "text" => "completed fallback"}]
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
          expect(response.output).to eq("completed fallback")
          expect(response.tokens).to eq({input: 10, output: 5, total: 15})
        end

        it "prefers item.completed message when text is empty" do
          jsonl_output = [
            JSON.generate({
              "type" => "item.completed",
              "item" => {
                "type" => "message",
                "role" => "assistant",
                "text" => "",
                "message" => "completed message fallback"
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
          expect(response.output).to eq("completed message fallback")
          expect(response.tokens).to eq({input: 10, output: 5, total: 15})
        end

        it "returns only the final completed assistant text across multiple turns" do
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
          expect(response.output).to eq("second answer")
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

        it "ignores non-output content blocks when extracting completed message text" do
          jsonl_output = [
            JSON.generate({
              "type" => "item.completed",
              "item" => {
                "type" => "message",
                "role" => "assistant",
                "content" => [
                  {"type" => "reasoning", "text" => "internal reasoning"},
                  {"type" => "output_text", "text" => "visible answer"}
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
          expect(response.output).to eq("visible answer")
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

        it "extracts text from item.completed when item_type is assistant_message" do
          jsonl_output = [
            JSON.generate({
              "type" => "item.completed",
              "item" => {"item_type" => "assistant_message", "text" => "response from item_type"}
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
          expect(response.output).to eq("response from item_type")
          expect(response.tokens).to eq({input: 10, output: 5, total: 15})
        end

        it "ignores roleless item.completed assistant_message items with non-message types" do
          jsonl_output = [
            JSON.generate({
              "type" => "item.completed",
              "item" => {
                "type" => "tool_call",
                "item_type" => "assistant_message",
                "text" => "tool text"
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
          expect(response.output).to eq(jsonl_output)
          expect(response.tokens).to eq({input: 10, output: 5, total: 15})
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

        it "preserves raw output for non-agent_message item.completed events without assistant text" do
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
          expect(response.output).to eq(jsonl_output)
          expect(response.tokens).to eq({input: 10, output: 5, total: 15})
        end

        it "preserves raw output for item.completed events with explicit non-assistant role" do
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
          expect(response.output).to eq(jsonl_output)
          expect(response.tokens).to eq({input: 10, output: 5, total: 15})
        end

        it "ignores item.completed assistant-role events with non-message types" do
          jsonl_output = [
            JSON.generate({
              "type" => "item.completed",
              "item" => {"type" => "tool_call", "role" => "assistant", "text" => "tool text"}
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
          expect(response.output).to eq(jsonl_output)
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
          expect(response.output).to eq(jsonl_output)
          expect(response.tokens).to eq({input: 10, output: 5, total: 15})
        end

        it "ignores roleless agent_message items with non-assistant item_type" do
          jsonl_output = [
            JSON.generate({
              "type" => "item.completed",
              "item" => {
                "type" => "agent_message",
                "item_type" => "user_message",
                "text" => "user text"
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
          expect(response.output).to eq(jsonl_output)
          expect(response.tokens).to eq({input: 10, output: 5, total: 15})
        end
      end

      context "with wrapped JSONL event parsing" do
        it "extracts final assistant text from top-level agent_message events" do
          jsonl_output = [
            JSON.generate({"type" => "agent_message_delta", "message" => "partial"}),
            JSON.generate({"type" => "agent_message", "message" => "final top-level answer"}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 4,
                    "output_tokens" => 2
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
          expect(response.output).to eq("final top-level answer")
          expect(response.tokens).to eq({input: 4, output: 2, total: 6})
        end

        it "extracts text from top-level agent_message_delta content blocks" do
          jsonl_output = [
            JSON.generate({
              "type" => "agent_message_delta",
              "delta" => {
                "content" => [
                  {"type" => "reasoning", "text" => "internal"},
                  {"type" => "output_text", "text" => "top-level partial"}
                ]
              }
            }),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 4,
                    "output_tokens" => 2
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
          expect(response.output).to eq("top-level partial")
          expect(response.tokens).to eq({input: 4, output: 2, total: 6})
        end

        it "treats empty top-level agent_message text as the final output" do
          jsonl_output = [
            JSON.generate({"type" => "agent_message_delta", "message" => "stale partial"}),
            JSON.generate({"type" => "agent_message", "message" => ""}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 4,
                    "output_tokens" => 2
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
          expect(response.output).to eq("")
          expect(response.tokens).to eq({input: 4, output: 2, total: 6})
        end

        it "falls back to top-level agent_message content when message is empty" do
          jsonl_output = [
            JSON.generate({"type" => "agent_message_delta", "message" => "stale partial"}),
            JSON.generate({
              "type" => "agent_message",
              "message" => "",
              "content" => [{"type" => "output_text", "text" => "wrapped completed fallback"}]
            }),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 4,
                    "output_tokens" => 2
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
          expect(response.output).to eq("wrapped completed fallback")
          expect(response.tokens).to eq({input: 4, output: 2, total: 6})
        end

        it "prefers top-level agent_message message when text is empty" do
          jsonl_output = [
            JSON.generate({"type" => "agent_message_delta", "message" => "stale partial"}),
            JSON.generate({
              "type" => "agent_message",
              "text" => "",
              "message" => "wrapped message fallback"
            }),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 4,
                    "output_tokens" => 2
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
          expect(response.output).to eq("wrapped message fallback")
          expect(response.tokens).to eq({input: 4, output: 2, total: 6})
        end

        it "ignores top-level non-assistant agent_message events" do
          jsonl_output = [
            JSON.generate({"type" => "agent_message_delta", "role" => "user", "message" => "user partial"}),
            JSON.generate({"type" => "agent_message", "role" => "tool", "message" => "tool message"}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 4,
                    "output_tokens" => 2
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
          expect(response.output).to eq(jsonl_output)
          expect(response.tokens).to eq({input: 4, output: 2, total: 6})
        end

        it "ignores top-level assistant-role events with non-assistant item_type" do
          jsonl_output = [
            JSON.generate({"type" => "agent_message_delta", "role" => "assistant", "item_type" => "tool_message", "message" => "tool partial"}),
            JSON.generate({"type" => "agent_message", "role" => "assistant", "item_type" => "user_message", "message" => "user message"}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 4,
                    "output_tokens" => 2
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
          expect(response.output).to eq(jsonl_output)
          expect(response.tokens).to eq({input: 4, output: 2, total: 6})
        end

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

        it "extracts wrapped agent_message_delta content blocks" do
          jsonl_output = [
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "agent_message_delta",
                "delta" => {
                  "content" => [
                    {"type" => "reasoning", "text" => "internal"},
                    {"type" => "output_text", "text" => "wrapped partial"}
                  ]
                }
              }
            }),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 4,
                    "output_tokens" => 2
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
          expect(response.output).to eq("wrapped partial")
          expect(response.tokens).to eq({input: 4, output: 2, total: 6})
        end

        it "extracts wrapped agent_message_delta output_text_delta content blocks" do
          jsonl_output = [
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "agent_message_delta",
                "delta" => {
                  "content" => [
                    {"type" => "reasoning", "text" => "internal"},
                    {"type" => "output_text_delta", "text" => "wrapped delta partial"}
                  ]
                }
              }
            }),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 4,
                    "output_tokens" => 2
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
          expect(response.output).to eq("wrapped delta partial")
          expect(response.tokens).to eq({input: 4, output: 2, total: 6})
        end

        it "falls back to wrapped agent_message_delta content when message is empty" do
          jsonl_output = [
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "agent_message_delta",
                "message" => "",
                "content" => [
                  {"type" => "reasoning", "text" => "internal"},
                  {"type" => "output_text", "text" => "wrapped fallback partial"}
                ]
              }
            }),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 4,
                    "output_tokens" => 2
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
          expect(response.output).to eq("wrapped fallback partial")
          expect(response.tokens).to eq({input: 4, output: 2, total: 6})
        end

        it "preserves raw output when wrapped agent_message_delta content is empty and no later text is emitted" do
          jsonl_output = [
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "agent_message_delta",
                "message" => ""
              }
            }),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 50,
                    "output_tokens" => 10
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
          expect(response.output).to eq(jsonl_output)
          expect(response.tokens).to eq({input: 50, output: 10, total: 60})
        end

        it "extracts final assistant text from roleless wrapped agent_message payloads" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message_delta", "message" => "partial"}}),
            JSON.generate({
              "type" => "response_item",
              "payload" => {
                "type" => "agent_message",
                "message" => "final wrapped agent message"
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
          expect(response.output).to eq("final wrapped agent message")
        end

        it "extracts final assistant text from wrapped task_complete payloads" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message_delta", "message" => "partial "}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "task_complete",
                "last_agent_message" => "final wrapped task output"
              }
            }),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 9,
                    "output_tokens" => 4
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
          expect(response.output).to eq("final wrapped task output")
          expect(response.tokens).to eq({input: 9, output: 4, total: 13})
        end

        it "extracts final assistant text from top-level task_complete events" do
          jsonl_output = [
            JSON.generate({"type" => "agent_message_delta", "message" => "partial "}),
            JSON.generate({
              "type" => "task_complete",
              "last_agent_message" => {
                "role" => "assistant",
                "content" => [
                  {"type" => "reasoning", "text" => "internal"},
                  {"type" => "output_text", "text" => "final top-level task output"}
                ]
              }
            }),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 9, "output_tokens" => 4}})
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
          expect(response.output).to eq("final top-level task output")
          expect(response.tokens).to eq({input: 9, output: 4, total: 13})
        end

        it "treats empty top-level task_complete output as the final assistant message" do
          jsonl_output = [
            JSON.generate({"type" => "agent_message_delta", "message" => "partial "}),
            JSON.generate({
              "type" => "task_complete",
              "last_agent_message" => ""
            }),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 9, "output_tokens" => 4}})
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
          expect(response.tokens).to eq({input: 9, output: 4, total: 13})
        end

        it "falls back to top-level task_complete content when text is empty" do
          jsonl_output = [
            JSON.generate({"type" => "agent_message_delta", "message" => "partial "}),
            JSON.generate({
              "type" => "task_complete",
              "last_agent_message" => {
                "role" => "assistant",
                "text" => "",
                "content" => [
                  {"type" => "reasoning", "text" => "internal"},
                  {"type" => "output_text", "text" => "final top-level task fallback"}
                ]
              }
            }),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 9, "output_tokens" => 4}})
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
          expect(response.output).to eq("final top-level task fallback")
          expect(response.tokens).to eq({input: 9, output: 4, total: 13})
        end

        it "falls back to top-level task_complete content when message is empty" do
          jsonl_output = [
            JSON.generate({"type" => "agent_message_delta", "message" => "partial "}),
            JSON.generate({
              "type" => "task_complete",
              "last_agent_message" => {
                "role" => "assistant",
                "message" => "",
                "content" => [
                  {"type" => "reasoning", "text" => "internal"},
                  {"type" => "output_text", "text" => "final top-level task message fallback"}
                ]
              }
            }),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 9, "output_tokens" => 4}})
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
          expect(response.output).to eq("final top-level task message fallback")
          expect(response.tokens).to eq({input: 9, output: 4, total: 13})
        end

        it "extracts structured assistant content from top-level turn_complete events" do
          jsonl_output = [
            JSON.generate({"type" => "agent_message_delta", "message" => "partial "}),
            JSON.generate({
              "type" => "turn_complete",
              "last_agent_message" => {
                "role" => "assistant",
                "content" => [
                  {"type" => "reasoning", "text" => "internal"},
                  {"type" => "output_text", "text" => "final top-level turn output"}
                ]
              }
            }),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 7, "output_tokens" => 4}})
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
          expect(response.output).to eq("final top-level turn output")
          expect(response.tokens).to eq({input: 7, output: 4, total: 11})
        end

        it "extracts structured assistant content from top-level turn_complete assistant_message payloads" do
          jsonl_output = [
            JSON.generate({"type" => "agent_message_delta", "message" => "partial "}),
            JSON.generate({
              "type" => "turn_complete",
              "last_agent_message" => {
                "type" => "assistant_message",
                "content" => [
                  {"type" => "reasoning", "text" => "internal"},
                  {"type" => "output_text", "text" => "final top-level assistant_message turn output"}
                ]
              }
            }),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 7, "output_tokens" => 4}})
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
          expect(response.output).to eq("final top-level assistant_message turn output")
          expect(response.tokens).to eq({input: 7, output: 4, total: 11})
        end

        it "falls back to top-level turn_complete content when message is empty" do
          jsonl_output = [
            JSON.generate({"type" => "agent_message_delta", "message" => "partial "}),
            JSON.generate({
              "type" => "turn_complete",
              "last_agent_message" => {
                "role" => "assistant",
                "message" => "",
                "content" => [
                  {"type" => "reasoning", "text" => "internal"},
                  {"type" => "output_text", "text" => "final top-level turn fallback"}
                ]
              }
            }),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 7, "output_tokens" => 4}})
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
          expect(response.output).to eq("final top-level turn fallback")
          expect(response.tokens).to eq({input: 7, output: 4, total: 11})
        end

        it "falls back to top-level turn_complete content when text is empty" do
          jsonl_output = [
            JSON.generate({"type" => "agent_message_delta", "message" => "partial "}),
            JSON.generate({
              "type" => "turn_complete",
              "last_agent_message" => {
                "role" => "assistant",
                "text" => "",
                "content" => [
                  {"type" => "reasoning", "text" => "internal"},
                  {"type" => "output_text", "text" => "final top-level turn text fallback"}
                ]
              }
            }),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 7, "output_tokens" => 4}})
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
          expect(response.output).to eq("final top-level turn text fallback")
          expect(response.tokens).to eq({input: 7, output: 4, total: 11})
        end

        it "treats empty top-level turn_complete output as the final assistant message" do
          jsonl_output = [
            JSON.generate({"type" => "agent_message_delta", "message" => "partial "}),
            JSON.generate({
              "type" => "turn_complete",
              "last_agent_message" => ""
            }),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 7, "output_tokens" => 4}})
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
          expect(response.tokens).to eq({input: 7, output: 4, total: 11})
        end

        it "ignores non-message top-level task_complete payloads" do
          jsonl_output = [
            JSON.generate({"type" => "agent_message_delta", "message" => "partial "}),
            JSON.generate({
              "type" => "task_complete",
              "last_agent_message" => {
                "type" => "tool_call",
                "role" => "assistant",
                "content" => [
                  {"type" => "output_text", "text" => "tool output leak"}
                ]
              }
            }),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 9, "output_tokens" => 4}})
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
          expect(response.output).to eq("partial ")
          expect(response.tokens).to eq({input: 9, output: 4, total: 13})
        end

        it "extracts structured assistant content from wrapped task_complete payloads" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message_delta", "message" => "partial "}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "task_complete",
                "last_agent_message" => {
                  "role" => "assistant",
                  "content" => [
                    {"type" => "reasoning", "text" => "internal"},
                    {"type" => "output_text", "text" => "final structured task output"}
                  ]
                }
              }
            }),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 9,
                    "output_tokens" => 4
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
          expect(response.output).to eq("final structured task output")
          expect(response.tokens).to eq({input: 9, output: 4, total: 13})
        end

        it "extracts structured assistant content from wrapped task_complete assistant_message payloads" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message_delta", "message" => "partial "}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "task_complete",
                "last_agent_message" => {
                  "type" => "assistant_message",
                  "content" => [
                    {"type" => "reasoning", "text" => "internal"},
                    {"type" => "output_text", "text" => "final wrapped assistant_message task output"}
                  ]
                }
              }
            }),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 9,
                    "output_tokens" => 4
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
          expect(response.output).to eq("final wrapped assistant_message task output")
          expect(response.tokens).to eq({input: 9, output: 4, total: 13})
        end

        it "treats empty wrapped task_complete output as the final assistant message" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message_delta", "message" => "partial "}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "task_complete",
                "last_agent_message" => ""
              }
            }),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 9,
                    "output_tokens" => 4
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
          expect(response.output).to eq("")
          expect(response.tokens).to eq({input: 9, output: 4, total: 13})
        end

        it "falls back to wrapped task_complete content when text is empty" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message_delta", "message" => "partial "}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "task_complete",
                "last_agent_message" => {
                  "role" => "assistant",
                  "text" => "",
                  "content" => [
                    {"type" => "reasoning", "text" => "internal"},
                    {"type" => "output_text", "text" => "final wrapped task fallback"}
                  ]
                }
              }
            }),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 9,
                    "output_tokens" => 4
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
          expect(response.output).to eq("final wrapped task fallback")
          expect(response.tokens).to eq({input: 9, output: 4, total: 13})
        end

        it "falls back to wrapped task_complete content when message is empty" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message_delta", "message" => "partial "}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "task_complete",
                "last_agent_message" => {
                  "role" => "assistant",
                  "message" => "",
                  "content" => [
                    {"type" => "reasoning", "text" => "internal"},
                    {"type" => "output_text", "text" => "final wrapped task message fallback"}
                  ]
                }
              }
            }),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 9,
                    "output_tokens" => 4
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
          expect(response.output).to eq("final wrapped task message fallback")
          expect(response.tokens).to eq({input: 9, output: 4, total: 13})
        end

        it "ignores non-message structured task_complete payloads" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message_delta", "message" => "partial "}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "task_complete",
                "last_agent_message" => {
                  "type" => "tool_call",
                  "role" => "assistant",
                  "content" => [
                    {"type" => "output_text", "text" => "tool output leak"}
                  ]
                }
              }
            }),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 9,
                    "output_tokens" => 4
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
          expect(response.output).to eq("partial ")
          expect(response.tokens).to eq({input: 9, output: 4, total: 13})
        end

        it "extracts final assistant text from wrapped turn_complete payloads" do
          jsonl_output = [
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "turn_complete",
                "last_agent_message" => ""
              }
            }),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 3,
                    "output_tokens" => 2
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
          expect(response.output).to eq("")
          expect(response.tokens).to eq({input: 3, output: 2, total: 5})
        end

        it "treats empty wrapped turn_complete output as the final assistant message after partial output" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message_delta", "message" => "partial "}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "turn_complete",
                "last_agent_message" => ""
              }
            }),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 3,
                    "output_tokens" => 2
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
          expect(response.output).to eq("")
          expect(response.tokens).to eq({input: 3, output: 2, total: 5})
        end

        it "falls back to wrapped turn_complete content when message is empty" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message_delta", "message" => "partial "}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "turn_complete",
                "last_agent_message" => {
                  "role" => "assistant",
                  "message" => "",
                  "content" => [
                    {"type" => "reasoning", "text" => "internal"},
                    {"type" => "output_text", "text" => "final wrapped turn fallback"}
                  ]
                }
              }
            }),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 3,
                    "output_tokens" => 2
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
          expect(response.output).to eq("final wrapped turn fallback")
          expect(response.tokens).to eq({input: 3, output: 2, total: 5})
        end

        it "falls back to wrapped turn_complete content when text is empty" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message_delta", "message" => "partial "}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "turn_complete",
                "last_agent_message" => {
                  "role" => "assistant",
                  "text" => "",
                  "content" => [
                    {"type" => "reasoning", "text" => "internal"},
                    {"type" => "output_text", "text" => "final wrapped turn text fallback"}
                  ]
                }
              }
            }),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 3,
                    "output_tokens" => 2
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
          expect(response.output).to eq("final wrapped turn text fallback")
          expect(response.tokens).to eq({input: 3, output: 2, total: 5})
        end

        it "extracts structured assistant content from wrapped turn_complete payloads" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message_delta", "message" => "partial "}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "turn_complete",
                "last_agent_message" => {
                  "type" => "message",
                  "role" => "assistant",
                  "content" => [
                    {"type" => "reasoning", "text" => "hidden"},
                    {"type" => "output_text", "text" => "final wrapped turn"}
                  ]
                }
              }
            }),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 8,
                    "output_tokens" => 3
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
          expect(response.output).to eq("final wrapped turn")
          expect(response.tokens).to eq({input: 8, output: 3, total: 11})
        end

        it "ignores non-message top-level turn_complete payloads" do
          jsonl_output = [
            JSON.generate({"type" => "agent_message_delta", "message" => "partial "}),
            JSON.generate({
              "type" => "turn_complete",
              "last_agent_message" => {
                "type" => "tool_call",
                "role" => "assistant",
                "content" => [
                  {"type" => "output_text", "text" => "tool output leak"}
                ]
              }
            }),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 9, "output_tokens" => 4}})
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
          expect(response.output).to eq("partial ")
          expect(response.tokens).to eq({input: 9, output: 4, total: 13})
        end

        it "ignores non-message structured turn_complete payloads" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message_delta", "message" => "partial "}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "turn_complete",
                "last_agent_message" => {
                  "type" => "tool_call",
                  "role" => "assistant",
                  "content" => [
                    {"type" => "output_text", "text" => "tool output leak"}
                  ]
                }
              }
            }),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 9,
                    "output_tokens" => 4
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
          expect(response.output).to eq("partial ")
          expect(response.tokens).to eq({input: 9, output: 4, total: 13})
        end

        it "extracts final assistant text from response_item when item_type is assistant_message" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message_delta", "message" => "partial"}}),
            JSON.generate({
              "type" => "response_item",
              "payload" => {
                "item_type" => "assistant_message",
                "message" => "final assistant item_type message"
              }
            }),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 9, "output_tokens" => 4}})
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
          expect(response.output).to eq("final assistant item_type message")
          expect(response.tokens).to eq({input: 9, output: 4, total: 13})
        end

        it "extracts final assistant text from response_item assistant_message payloads without a type" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message_delta", "message" => "partial"}}),
            JSON.generate({
              "type" => "response_item",
              "payload" => {
                "role" => "assistant",
                "item_type" => "assistant_message",
                "message" => "final assistant item without type"
              }
            }),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 9, "output_tokens" => 4}})
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
          expect(response.output).to eq("final assistant item without type")
          expect(response.tokens).to eq({input: 9, output: 4, total: 13})
        end

        it "extracts final assistant text from typed response_item assistant_message payloads" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message_delta", "message" => "partial"}}),
            JSON.generate({
              "type" => "response_item",
              "payload" => {
                "type" => "assistant_message",
                "message" => "final typed assistant_message response item"
              }
            }),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 9, "output_tokens" => 4}})
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
          expect(response.output).to eq("final typed assistant_message response item")
          expect(response.tokens).to eq({input: 9, output: 4, total: 13})
        end

        it "ignores response_item assistant_message payloads with non-message types" do
          jsonl_output = [
            JSON.generate({
              "type" => "response_item",
              "payload" => {
                "type" => "tool_call",
                "item_type" => "assistant_message",
                "message" => "tool payload"
              }
            }),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 9, "output_tokens" => 4}})
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
          expect(response.output).to eq(jsonl_output)
          expect(response.tokens).to eq({input: 9, output: 4, total: 13})
        end

        it "ignores wrapped non-assistant agent_message events and deltas" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message_delta", "role" => "user", "message" => "user partial"}}),
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message", "role" => "tool", "message" => "tool message"}}),
            JSON.generate({"type" => "response_item", "payload" => {"type" => "message", "role" => "user", "content" => [{"type" => "output_text", "text" => "user final"}]}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "total_token_usage" => {
                    "input_tokens" => 4,
                    "output_tokens" => 2
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
          expect(response.output).to eq(jsonl_output)
          expect(response.tokens).to eq({input: 4, output: 2, total: 6})
        end

        it "ignores wrapped assistant-role payloads with non-assistant item_type" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message_delta", "role" => "assistant", "item_type" => "tool_message", "message" => "tool partial"}}),
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message", "role" => "assistant", "item_type" => "user_message", "message" => "user message"}}),
            JSON.generate({"type" => "response_item", "payload" => {"type" => "agent_message", "role" => "assistant", "item_type" => "tool_message", "message" => "tool final"}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "total_token_usage" => {
                    "input_tokens" => 4,
                    "output_tokens" => 2
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
          expect(response.output).to eq(jsonl_output)
          expect(response.tokens).to eq({input: 4, output: 2, total: 6})
        end

        it "ignores roleless wrapped payloads with non-assistant item_type" do
          jsonl_output = [
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "agent_message_delta",
                "item_type" => "user_message",
                "message" => "user partial"
              }
            }),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "agent_message",
                "item_type" => "tool_message",
                "message" => "tool message"
              }
            }),
            JSON.generate({
              "type" => "response_item",
              "payload" => {
                "type" => "agent_message",
                "item_type" => "user_message",
                "message" => "user final"
              }
            }),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "total_token_usage" => {
                    "input_tokens" => 4,
                    "output_tokens" => 2
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
          expect(response.output).to eq(jsonl_output)
          expect(response.tokens).to eq({input: 4, output: 2, total: 6})
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
                  "last_token_usage" => {
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
          expect(response.tokens).to eq({input: 72, output: 7, total: 79})
        end

        it "prefers per-turn wrapped usage over mismatched cumulative session totals" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message", "message" => "wrapped output"}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 42,
                    "output_tokens" => 7
                  },
                  "total_token_usage" => {
                    "input_tokens" => 420,
                    "output_tokens" => 70,
                    "total_tokens" => 600
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

        it "does not finalize a wrapped turn on token_count before later deltas" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message_delta", "message" => "hel"}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 42,
                    "output_tokens" => 7
                  }
                }
              }
            }),
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message_delta", "message" => "lo"}})
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
          expect(response.output).to eq("hello")
          expect(response.tokens).to eq({input: 42, output: 7, total: 49})
        end

        it "preserves a later finalized turn after wrapped token_count without a result field" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message", "message" => "first wrapped answer"}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 42,
                    "output_tokens" => 7
                  }
                }
              }
            }),
            JSON.generate({
              "type" => "response_item",
              "payload" => {
                "type" => "message",
                "role" => "assistant",
                "content" => [{"type" => "output_text", "text" => "second finalized answer"}]
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
          expect(response.output).to eq("second finalized answer")
          expect(response.tokens).to eq({input: 52, output: 12, total: 64})
        end

        it "preserves a later top-level agent_message turn after wrapped token_count without a result field" do
          jsonl_output = [
            JSON.generate({"type" => "agent_message", "message" => "first top-level answer"}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 42,
                    "output_tokens" => 7
                  }
                }
              }
            }),
            JSON.generate({"type" => "agent_message", "message" => "second top-level answer"}),
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
          expect(response.output).to eq("second top-level answer")
          expect(response.tokens).to eq({input: 52, output: 12, total: 64})
        end

        it "preserves a later top-level agent_message turn and folds cached tokens from turn.completed" do
          jsonl_output = [
            JSON.generate({"type" => "agent_message", "message" => "first top-level answer"}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 42,
                    "output_tokens" => 7
                  }
                }
              }
            }),
            JSON.generate({"type" => "agent_message", "message" => "second top-level answer"}),
            JSON.generate({"type" => "turn.completed", "usage" => {"cached_input_tokens" => 10}})
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
          expect(response.output).to eq("second top-level answer")
          expect(response.tokens).to eq({input: 52, output: 7, total: 59})
        end

        it "preserves a later wrapped agent_message turn and folds cached tokens from turn.completed" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message", "message" => "first wrapped answer"}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 42,
                    "output_tokens" => 7
                  }
                }
              }
            }),
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message", "message" => "second wrapped answer"}}),
            JSON.generate({"type" => "turn.completed", "usage" => {"cached_input_tokens" => 10}})
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
          expect(response.output).to eq("second wrapped answer")
          expect(response.tokens).to eq({input: 52, output: 7, total: 59})
        end

        it "commits wrapped usage before a new top-level delta turn with matching totals" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message", "message" => "first wrapped answer"}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 42,
                    "output_tokens" => 18,
                    "total_tokens" => 60
                  }
                }
              }
            }),
            JSON.generate({"type" => "message.delta", "delta" => {"text" => "second "}}),
            JSON.generate({"type" => "message.delta", "delta" => {"text" => "answer"}}),
            JSON.generate({
              "type" => "turn.completed",
              "usage" => {
                "input_tokens" => 42,
                "output_tokens" => 18,
                "total_tokens" => 60
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
          expect(response.output).to eq("second answer")
          expect(response.tokens).to eq({input: 84, output: 36, total: 120})
        end

        it "preserves wrapped output and folds cached tokens from turn.completed" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message", "message" => "wrapped answer"}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 42,
                    "output_tokens" => 7
                  }
                }
              }
            }),
            JSON.generate({"type" => "turn.completed", "usage" => {"cached_input_tokens" => 99}})
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
          expect(response.output).to eq("wrapped answer")
          expect(response.tokens).to eq({input: 141, output: 7, total: 148})
        end

        it "ignores malformed wrapped token counts without dropping parsed output" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message", "message" => "wrapped output"}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => {},
                    "output_tokens" => []
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
          expect(response.tokens).to be_nil
        end

        it "ignores negative wrapped token counts without dropping parsed output" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message", "message" => "wrapped output"}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => -5,
                    "output_tokens" => -1
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
          expect(response.tokens).to be_nil
        end

        it "preserves wrapped zero-usage reports and explicit total_tokens" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message", "message" => "wrapped output"}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
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

        it "returns only the final wrapped assistant text across multiple turns" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message", "message" => "first wrapped answer"}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 2,
                    "output_tokens" => 1
                  }
                }
              }
            }),
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message_delta", "message" => "ignored partial"}}),
            JSON.generate({
              "type" => "response_item",
              "payload" => {
                "type" => "message",
                "role" => "assistant",
                "content" => [{"type" => "output_text", "text" => "second wrapped answer"}]
              }
            }),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 3,
                    "output_tokens" => 4,
                    "reasoning_output_tokens" => 6,
                    "total_tokens" => 13
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
          expect(response.output).to eq("second wrapped answer")
          expect(response.tokens).to eq({input: 5, output: 5, total: 16})
          expect(response.total_tokens).to eq(16)
        end

        it "uses per-event wrapped token usage instead of summing cumulative snapshots" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message", "message" => "wrapped output"}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 2,
                    "output_tokens" => 1
                  },
                  "total_token_usage" => {
                    "input_tokens" => 2,
                    "output_tokens" => 1
                  }
                }
              }
            }),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 3,
                    "output_tokens" => 4
                  },
                  "total_token_usage" => {
                    "input_tokens" => 5,
                    "output_tokens" => 5
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
          expect(response.tokens).to eq({input: 5, output: 5, total: 10})
        end

        it "replaces repeated wrapped cumulative snapshots instead of summing them" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message", "message" => "wrapped output"}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 2,
                    "output_tokens" => 1
                  },
                  "total_token_usage" => {
                    "input_tokens" => 2,
                    "output_tokens" => 1
                  }
                }
              }
            }),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 5,
                    "output_tokens" => 5
                  },
                  "total_token_usage" => {
                    "input_tokens" => 5,
                    "output_tokens" => 5
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
          expect(response.tokens).to eq({input: 5, output: 5, total: 10})
        end

        it "does not treat repeated finalized wrapped agent_message events as new turns" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message", "message" => "draft wrapped output"}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "total_token_usage" => {
                    "input_tokens" => 70,
                    "output_tokens" => 30,
                    "total_tokens" => 100
                  }
                }
              }
            }),
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message", "message" => "final wrapped output"}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "total_token_usage" => {
                    "input_tokens" => 80,
                    "output_tokens" => 40,
                    "total_tokens" => 120
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
          expect(response.output).to eq("final wrapped output")
          expect(response.tokens).to eq({input: 80, output: 40, total: 120})
        end

        it "falls back to the latest wrapped cumulative snapshot when per-event usage is unavailable" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message", "message" => "wrapped output"}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "total_token_usage" => {
                    "input_tokens" => 2,
                    "output_tokens" => 1
                  }
                }
              }
            }),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "total_token_usage" => {
                    "input_tokens" => 5,
                    "output_tokens" => 5,
                    "total_tokens" => 12
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
          expect(response.tokens).to eq({input: 5, output: 5, total: 12})
          expect(response.total_tokens).to eq(12)
        end

        it "uses per-turn cached tokens when last_token_usage has only cached_input_tokens" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message", "message" => "wrapped output"}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "cached_input_tokens" => 9
                  },
                  "total_token_usage" => {
                    "input_tokens" => 5,
                    "output_tokens" => 5,
                    "total_tokens" => 12
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
          expect(response.tokens).to eq({input: 9, output: 0, total: 9})
          expect(response.total_tokens).to eq(9)
        end

        it "treats fallback wrapped cumulative snapshots as replacements after earlier deltas" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message", "message" => "wrapped output"}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 2,
                    "output_tokens" => 1
                  }
                }
              }
            }),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "total_token_usage" => {
                    "input_tokens" => 5,
                    "output_tokens" => 5,
                    "total_tokens" => 12
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
          expect(response.tokens).to eq({input: 5, output: 5, total: 12})
          expect(response.total_tokens).to eq(12)
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
          expect(response.tokens).to eq({input: 150, output: 25, total: 175})
          expect(response.input_tokens).to eq(150)
          expect(response.output_tokens).to eq(25)
          expect(response.total_tokens).to eq(175)
        end

        it "appends text across multiple message.delta events" do
          jsonl_output = [
            JSON.generate({"type" => "message.delta", "delta" => {"text" => "Hel"}}),
            JSON.generate({"type" => "message.delta", "delta" => {"text" => "lo"}}),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 100, "output_tokens" => 25}})
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
          expect(response.output).to eq("Hello")
          expect(response.tokens).to eq({input: 100, output: 25, total: 125})
        end

        it "extracts text from structured message.delta content blocks" do
          jsonl_output = [
            JSON.generate({
              "type" => "message.delta",
              "delta" => {
                "content" => [
                  {"type" => "reasoning", "text" => "internal"},
                  {"type" => "output_text", "text" => "Hello from blocks"}
                ]
              }
            }),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 100, "output_tokens" => 25}})
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
          expect(response.output).to eq("Hello from blocks")
          expect(response.tokens).to eq({input: 100, output: 25, total: 125})
        end

        it "falls back to structured message.delta content when text is empty" do
          jsonl_output = [
            JSON.generate({
              "type" => "message.delta",
              "delta" => {
                "text" => "",
                "content" => [
                  {"type" => "reasoning", "text" => "internal"},
                  {"type" => "output_text", "text" => "Hello from fallback blocks"}
                ]
              }
            }),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 100, "output_tokens" => 25}})
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
          expect(response.output).to eq("Hello from fallback blocks")
          expect(response.tokens).to eq({input: 100, output: 25, total: 125})
        end

        it "preserves raw output when message.delta text is empty and no later text is emitted" do
          jsonl_output = [
            JSON.generate({"type" => "message.delta", "delta" => {"text" => ""}}),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 100, "output_tokens" => 25}})
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
          expect(response.output).to eq(jsonl_output)
          expect(response.tokens).to eq({input: 100, output: 25, total: 125})
        end

        it "prefers explicit total_tokens from turn.completed usage" do
          jsonl_output = [
            JSON.generate({"type" => "message.delta", "delta" => {"text" => "Hello!"}}),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 100, "output_tokens" => 25, "total_tokens" => 140}})
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
          expect(response.tokens).to eq({input: 100, output: 25, total: 140})
          expect(response.total_tokens).to eq(140)
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

        it "aggregates consecutive turn.completed usage without intermediate deltas" do
          jsonl_output = [
            JSON.generate({"type" => "turn.completed", "result" => "Part 1", "usage" => {"input_tokens" => 50, "output_tokens" => 10}}),
            JSON.generate({"type" => "turn.completed", "result" => "Part 2", "usage" => {"input_tokens" => 60, "output_tokens" => 20}})
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
          expect(response.output).to eq("Part 2")
          expect(response.tokens).to eq({input: 110, output: 30, total: 140})
        end

        it "treats a later turn.completed without output as an empty final response" do
          jsonl_output = [
            JSON.generate({"type" => "message.delta", "delta" => {"text" => "Part 1"}}),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 50, "output_tokens" => 10}}),
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
          expect(response.output).to eq("")
          expect(response.tokens).to eq({input: 110, output: 30, total: 140})
        end

        it "treats a later turn.failed as an empty final response instead of reusing prior turn text" do
          jsonl_output = [
            JSON.generate({"type" => "turn.completed", "result" => "first answer", "usage" => {"input_tokens" => 50, "output_tokens" => 10}}),
            JSON.generate({"type" => "turn.failed", "usage" => {"input_tokens" => 60, "output_tokens" => 20}})
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
          expect(response.output).to eq("")
          expect(response.tokens).to eq({input: 110, output: 30, total: 140})
        end

        it "does not double-count wrapped token usage when the same turn later fails" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message_delta", "message" => "partial"}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 50,
                    "output_tokens" => 10
                  }
                }
              }
            }),
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message_delta", "message" => " output"}}),
            JSON.generate({"type" => "turn.failed", "usage" => {"input_tokens" => 50, "output_tokens" => 10}})
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
          expect(response.tokens).to eq({input: 50, output: 10, total: 60})
        end

        it "does not double-count wrapped usage when response_item finalizes the same failed turn" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message", "message" => "partial"}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 50,
                    "output_tokens" => 10
                  }
                }
              }
            }),
            JSON.generate({
              "type" => "response_item",
              "payload" => {
                "type" => "message",
                "role" => "assistant",
                "content" => [{"type" => "output_text", "text" => "final"}]
              }
            }),
            JSON.generate({"type" => "turn.failed", "usage" => {"input_tokens" => 50, "output_tokens" => 10}})
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
          expect(response.tokens).to eq({input: 50, output: 10, total: 60})
        end

        it "does not double-count wrapped usage when item.completed finalizes the same failed turn" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message", "message" => "partial"}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 50,
                    "output_tokens" => 10
                  }
                }
              }
            }),
            JSON.generate({"type" => "item.completed", "item" => {"type" => "message", "role" => "assistant", "text" => "final"}}),
            JSON.generate({"type" => "turn.failed", "usage" => {"input_tokens" => 50, "output_tokens" => 10}})
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
          expect(response.tokens).to eq({input: 50, output: 10, total: 60})
        end

        it "does not double-count wrapped usage when wrapped agent_message finalizes the same failed turn" do
          jsonl_output = [
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 50,
                    "output_tokens" => 10
                  }
                }
              }
            }),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "agent_message",
                "message" => "final"
              }
            }),
            JSON.generate({"type" => "turn.failed", "usage" => {"input_tokens" => 50, "output_tokens" => 10}})
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
          expect(response.tokens).to eq({input: 50, output: 10, total: 60})
        end

        it "does not double-count wrapped usage when repeated wrapped agent_message events finalize the same failed turn" do
          jsonl_output = [
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "agent_message_delta",
                "message" => "partial"
              }
            }),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 50,
                    "output_tokens" => 10
                  }
                }
              }
            }),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "agent_message",
                "message" => "first final"
              }
            }),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "agent_message",
                "message" => "second final"
              }
            }),
            JSON.generate({"type" => "turn.failed", "usage" => {"input_tokens" => 50, "output_tokens" => 10}})
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
          expect(response.tokens).to eq({input: 50, output: 10, total: 60})
        end

        it "does not double-count wrapped usage when agent_message finalizes the same failed turn" do
          jsonl_output = [
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 50,
                    "output_tokens" => 10
                  }
                }
              }
            }),
            JSON.generate({"type" => "agent_message", "message" => "final"}),
            JSON.generate({"type" => "turn.failed", "usage" => {"input_tokens" => 50, "output_tokens" => 10}})
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
          expect(response.tokens).to eq({input: 50, output: 10, total: 60})
        end

        it "does not double-count wrapped usage when repeated agent_message events finalize the same failed turn" do
          jsonl_output = [
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "agent_message_delta",
                "message" => "partial"
              }
            }),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 50,
                    "output_tokens" => 10
                  }
                }
              }
            }),
            JSON.generate({"type" => "agent_message", "message" => "first final"}),
            JSON.generate({"type" => "agent_message", "message" => "second final"}),
            JSON.generate({"type" => "turn.failed", "usage" => {"input_tokens" => 50, "output_tokens" => 10}})
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
          expect(response.tokens).to eq({input: 50, output: 10, total: 60})
        end

        it "commits pending wrapped usage before a later finalized turn fails with matching usage" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message", "message" => "first answer"}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 50,
                    "output_tokens" => 10
                  }
                }
              }
            }),
            JSON.generate({"type" => "agent_message", "message" => "second answer"}),
            JSON.generate({"type" => "turn.failed", "usage" => {"input_tokens" => 50, "output_tokens" => 10}})
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
          expect(response.tokens).to eq({input: 100, output: 20, total: 120})
        end

        it "does not double-count mixed wrapped and turn.completed usage for the same turn" do
          jsonl_output = [
            JSON.generate({"type" => "message.delta", "delta" => {"text" => "partial"}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 50,
                    "output_tokens" => 10
                  }
                }
              }
            }),
            JSON.generate({"type" => "turn.completed", "result" => "final answer", "usage" => {"input_tokens" => 50, "output_tokens" => 10}})
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
          expect(response.tokens).to eq({input: 50, output: 10, total: 60})
        end

        it "does not double-count wrapped usage when response_item finalizes the same turn" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message", "message" => "partial answer"}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 50,
                    "output_tokens" => 10
                  }
                }
              }
            }),
            JSON.generate({
              "type" => "response_item",
              "payload" => {
                "type" => "message",
                "role" => "assistant",
                "content" => [{"type" => "output_text", "text" => "final answer"}]
              }
            }),
            JSON.generate({"type" => "turn.completed", "result" => "final answer", "usage" => {"input_tokens" => 50, "output_tokens" => 10}})
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
          expect(response.tokens).to eq({input: 50, output: 10, total: 60})
        end

        it "does not double-count wrapped usage when item.completed finalizes the same turn" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message", "message" => "partial answer"}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 50,
                    "output_tokens" => 10
                  }
                }
              }
            }),
            JSON.generate({"type" => "item.completed", "item" => {"type" => "message", "role" => "assistant", "text" => "final answer"}}),
            JSON.generate({"type" => "turn.completed", "result" => "final answer", "usage" => {"input_tokens" => 50, "output_tokens" => 10}})
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
          expect(response.tokens).to eq({input: 50, output: 10, total: 60})
        end

        it "does not double-count mixed wrapped and turn.completed usage when one side only reports total_tokens" do
          jsonl_output = [
            JSON.generate({"type" => "message.delta", "delta" => {"text" => "partial"}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "total_token_usage" => {
                    "total_tokens" => 80
                  }
                }
              }
            }),
            JSON.generate({"type" => "turn.completed", "result" => "final answer", "usage" => {"input_tokens" => 50, "output_tokens" => 10, "total_tokens" => 80}})
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
          expect(response.tokens).to eq({input: 50, output: 10, total: 80})
        end

        it "merges wrapped token_count updates that arrive after turn.completed for the same turn" do
          jsonl_output = [
            JSON.generate({"type" => "message.delta", "delta" => {"text" => "partial"}}),
            JSON.generate({"type" => "turn.completed", "result" => "final answer", "usage" => {"input_tokens" => 50, "output_tokens" => 10}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "total_token_usage" => {
                    "input_tokens" => 50,
                    "output_tokens" => 10,
                    "total_tokens" => 80
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
          expect(response.output).to eq("final answer")
          expect(response.tokens).to eq({input: 50, output: 10, total: 80})
        end

        it "treats detailed wrapped token_count after a completed turn as a new turn when usage differs" do
          jsonl_output = [
            JSON.generate({"type" => "turn.completed", "result" => "first answer", "usage" => {"input_tokens" => 50, "output_tokens" => 10}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 60,
                    "output_tokens" => 20
                  }
                }
              }
            }),
            JSON.generate({"type" => "message.delta", "delta" => {"text" => "second"}}),
            JSON.generate({"type" => "turn.completed", "result" => "second", "usage" => {"input_tokens" => 60, "output_tokens" => 20}})
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
          expect(response.output).to eq("second")
          expect(response.tokens).to eq({input: 110, output: 30, total: 140})
        end

        it "treats detailed wrapped token_count after a total-only completed turn as a new turn when totals differ" do
          jsonl_output = [
            JSON.generate({"type" => "turn.completed", "result" => "first answer", "usage" => {"total_tokens" => 60}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 40,
                    "output_tokens" => 10
                  }
                }
              }
            }),
            JSON.generate({"type" => "message.delta", "delta" => {"text" => "second"}}),
            JSON.generate({"type" => "turn.completed", "result" => "second", "usage" => {"input_tokens" => 40, "output_tokens" => 10}})
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
          expect(response.output).to eq("second")
          expect(response.tokens).to eq({input: 40, output: 10, total: 110})
        end

        it "does not double-count mixed wrapped detailed usage when turn.completed only reports total_tokens" do
          jsonl_output = [
            JSON.generate({"type" => "message.delta", "delta" => {"text" => "partial"}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 50,
                    "output_tokens" => 10
                  }
                }
              }
            }),
            JSON.generate({"type" => "turn.completed", "result" => "final answer", "usage" => {"total_tokens" => 60}})
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
          expect(response.tokens).to eq({input: 50, output: 10, total: 60})
        end

        it "commits wrapped usage when a later turn.completed result indicates a new turn" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message", "message" => "first wrapped answer"}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "total_token_usage" => {
                    "total_tokens" => 60
                  }
                }
              }
            }),
            JSON.generate({"type" => "turn.completed", "result" => "second answer", "usage" => {"total_tokens" => 60}})
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
          expect(response.output).to eq("second answer")
          expect(response.tokens).to eq({input: 0, output: 0, total: 120})
        end

        it "commits wrapped usage before a new turn.completed turn begins" do
          jsonl_output = [
            JSON.generate({"type" => "event_msg", "payload" => {"type" => "agent_message", "message" => "first wrapped answer"}}),
            JSON.generate({
              "type" => "event_msg",
              "payload" => {
                "type" => "token_count",
                "info" => {
                  "last_token_usage" => {
                    "input_tokens" => 50,
                    "output_tokens" => 10
                  }
                }
              }
            }),
            JSON.generate({"type" => "turn.completed", "result" => "second answer", "usage" => {"input_tokens" => 60, "output_tokens" => 20}})
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
          expect(response.output).to eq("second answer")
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

        it "extracts result from turn.completed and folds cached tokens into usage" do
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
          expect(response.tokens).to eq({input: 100, output: 0, total: 100})
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

        it "treats an empty turn.completed result as the final output" do
          jsonl_output = [
            JSON.generate({"type" => "message.delta", "delta" => {"text" => "stale partial"}}),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => 10, "output_tokens" => 5}, "result" => ""})
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

        it "preserves raw output when JSONL contains only usage data" do
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
          expect(response.output).to eq(jsonl_output)
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

        it "falls back to raw output when JSONL contains no event objects" do
          raw_output = [
            "123",
            "null",
            "[1,2,3]"
          ].join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: raw_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq(raw_output)
          expect(response.tokens).to be_nil
        end

        it "folds cached_input_tokens into usage when it is the only token field" do
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
          expect(response.tokens).to eq({input: 50, output: 0, total: 50})
        end

        it "ignores malformed turn token counts without dropping parsed output" do
          jsonl_output = [
            JSON.generate({"type" => "message.delta", "delta" => {"text" => "Hello!"}}),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => {}, "output_tokens" => []}})
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

        it "ignores negative turn token counts without dropping parsed output" do
          jsonl_output = [
            JSON.generate({"type" => "message.delta", "delta" => {"text" => "Hello!"}}),
            JSON.generate({"type" => "turn.completed", "usage" => {"input_tokens" => -10, "output_tokens" => -2}})
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

      it "classifies OAuth refresh failures as auth_expired" do
        patterns = provider.error_patterns

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new('Failed to refresh token: "code": "refresh_token_reused"'),
            patterns
          )
        ).to eq(:auth_expired)

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new(
              "Your access token could not be refreshed because your refresh token has already been used. Please log out and sign in again."
            ),
            patterns
          )
        ).to eq(:auth_expired)

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new("Failed to refresh token: invalid_client"),
            patterns
          )
        ).to eq(:auth_expired)

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new("Failed to refresh token because invalid_grant"),
            patterns
          )
        ).to eq(:auth_expired)

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new("Failed to refresh token because refresh token is invalid."),
            patterns
          )
        ).to eq(:auth_expired)

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new(<<~ERROR),
              Failed to refresh token:
              "code": "invalid_grant"
            ERROR
            patterns
          )
        ).to eq(:auth_expired)

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new(<<~ERROR),
              Your access token could not be refreshed because
              your refresh token was already used. Please log out and sign in again.
            ERROR
            patterns
          )
        ).to eq(:auth_expired)

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new(<<~ERROR),
              Your access token could not be refreshed because
              invalid_client
            ERROR
            patterns
          )
        ).to eq(:auth_expired)

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new(
              "Your access token could not be refreshed because your refresh token is invalid."
            ),
            patterns
          )
        ).to eq(:auth_expired)
      end

      it "does not classify transient refresh failures as auth_expired" do
        patterns = provider.error_patterns

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new("Failed to refresh token: connection error while contacting oauth endpoint"),
            patterns
          )
        ).to eq(:transient)

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new(
              "Your access token could not be refreshed because the auth service was unavailable."
            ),
            patterns
          )
        ).to eq(:transient)

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new(
              "Your access token could not be refreshed because the authentication service was unavailable."
            ),
            patterns
          )
        ).to eq(:transient)

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new(
              "Your access token could not be refreshed because authentication service was unavailable."
            ),
            patterns
          )
        ).to eq(:transient)

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new(
              "Your access token could not be refreshed because the authentication service is unavailable."
            ),
            patterns
          )
        ).to eq(:transient)

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new(
              "Your access token could not be refreshed because the authentication service was temporarily unavailable."
            ),
            patterns
          )
        ).to eq(:transient)

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new(
              "Failed to refresh token because the authentication service was unavailable."
            ),
            patterns
          )
        ).to eq(:transient)

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new(
              "Failed to refresh token because the authentication service was temporarily unavailable."
            ),
            patterns
          )
        ).to eq(:transient)

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new(
              "Failed to refresh token because connection error while contacting oauth endpoint."
            ),
            patterns
          )
        ).to eq(:transient)

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new(<<~ERROR),
              Failed to refresh token:
              the authentication service was unavailable.
            ERROR
            patterns
          )
        ).to eq(:transient)

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new(<<~ERROR),
              Your access token could not be refreshed because
              the authentication service was unavailable.
            ERROR
            patterns
          )
        ).to eq(:transient)
      end

      it "does not classify generic re-login prompts as refresh auth failures" do
        patterns = provider.error_patterns

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new("Please log out and sign in again."),
            patterns
          )
        ).to eq(:unknown)
      end

      it "does not classify non-auth refresh failures as auth_expired" do
        patterns = provider.error_patterns

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new("Your access token could not be refreshed because the auth service timed out."),
            patterns
          )
        ).to eq(:timeout)

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new(
              "Your access token could not be refreshed because the authentication service timed out."
            ),
            patterns
          )
        ).to eq(:timeout)

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new(
              "Your access token could not be refreshed because the authentication service timed-out."
            ),
            patterns
          )
        ).to eq(:timeout)

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new(
              "Failed to refresh token because the authentication service timed out."
            ),
            patterns
          )
        ).to eq(:timeout)

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new(<<~ERROR),
              Failed to refresh token:
              the authentication service timed out.
            ERROR
            patterns
          )
        ).to eq(:timeout)

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new(<<~ERROR),
              Your access token could not be refreshed because
              the authentication service timed out.
            ERROR
            patterns
          )
        ).to eq(:timeout)
      end
    end

    describe "#smoke_test" do
      let(:mock_executor) { instance_double(AgentHarness::CommandExecutor) }
      subject(:provider) { described_class.new(executor: mock_executor) }

      it "normalizes OAuth refresh failures to auth_expired" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "",
            stderr: <<~ERROR,
              Failed to refresh token: 401 Unauthorized
              "code": "refresh_token_reused"
              Your access token could not be refreshed because your refresh token was already used. Please log out and sign in again.
            ERROR
            exit_code: 1,
            duration: 1.0
          )
        )

        result = provider.smoke_test

        expect(result[:ok]).to be false
        expect(result[:error_category]).to eq(:auth_expired)
      end

      it "normalizes failed-refresh OAuth invalid_grant failures to auth_expired" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "",
            stderr: "Failed to refresh token because invalid_grant",
            exit_code: 1,
            duration: 1.0
          )
        )

        result = provider.smoke_test

        expect(result[:ok]).to be false
        expect(result[:error_category]).to eq(:auth_expired)
      end

      it "normalizes failed-refresh invalid refresh token wording to auth_expired" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "",
            stderr: "Failed to refresh token because refresh token is invalid.",
            exit_code: 1,
            duration: 1.0
          )
        )

        result = provider.smoke_test

        expect(result[:ok]).to be false
        expect(result[:error_category]).to eq(:auth_expired)
      end

      it "normalizes multiline failed-refresh OAuth invalid_client failures to auth_expired" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "",
            stderr: <<~ERROR,
              Failed to refresh token:
              "code": "invalid_client"
            ERROR
            exit_code: 1,
            duration: 1.0
          )
        )

        result = provider.smoke_test

        expect(result[:ok]).to be false
        expect(result[:error_category]).to eq(:auth_expired)
      end

      it "normalizes multiline access-token refresh reuse failures to auth_expired" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "",
            stderr: <<~ERROR,
              Your access token could not be refreshed because
              your refresh token was already used. Please log out and sign in again.
            ERROR
            exit_code: 1,
            duration: 1.0
          )
        )

        result = provider.smoke_test

        expect(result[:ok]).to be false
        expect(result[:error_category]).to eq(:auth_expired)
      end

      it "normalizes multiline access-token OAuth invalid_client failures to auth_expired" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "",
            stderr: <<~ERROR,
              Your access token could not be refreshed because
              invalid_client
            ERROR
            exit_code: 1,
            duration: 1.0
          )
        )

        result = provider.smoke_test

        expect(result[:ok]).to be false
        expect(result[:error_category]).to eq(:auth_expired)
      end

      it "normalizes access-token invalid refresh token wording to auth_expired" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "",
            stderr: "Your access token could not be refreshed because your refresh token is invalid.",
            exit_code: 1,
            duration: 1.0
          )
        )

        result = provider.smoke_test

        expect(result[:ok]).to be false
        expect(result[:error_category]).to eq(:auth_expired)
      end

      it "keeps transient OAuth refresh failures retryable" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "",
            stderr: "Your access token could not be refreshed because the auth service was unavailable.",
            exit_code: 1,
            duration: 1.0
          )
        )

        result = provider.smoke_test

        expect(result[:ok]).to be false
        expect(result[:error_category]).to eq(:transient)
      end

      it "keeps authentication service refresh failures retryable" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "",
            stderr: "Your access token could not be refreshed because the authentication service was unavailable.",
            exit_code: 1,
            duration: 1.0
          )
        )

        result = provider.smoke_test

        expect(result[:ok]).to be false
        expect(result[:error_category]).to eq(:transient)
      end

      it "keeps no-article authentication service refresh failures retryable" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "",
            stderr: "Your access token could not be refreshed because authentication service was unavailable.",
            exit_code: 1,
            duration: 1.0
          )
        )

        result = provider.smoke_test

        expect(result[:ok]).to be false
        expect(result[:error_category]).to eq(:transient)
      end

      it "keeps authentication service is-unavailable refresh failures retryable" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "",
            stderr: "Your access token could not be refreshed because the authentication service is unavailable.",
            exit_code: 1,
            duration: 1.0
          )
        )

        result = provider.smoke_test

        expect(result[:ok]).to be false
        expect(result[:error_category]).to eq(:transient)
      end

      it "keeps temporarily unavailable authentication service refresh failures retryable" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "",
            stderr: "Your access token could not be refreshed because the authentication service was temporarily unavailable.",
            exit_code: 1,
            duration: 1.0
          )
        )

        result = provider.smoke_test

        expect(result[:ok]).to be false
        expect(result[:error_category]).to eq(:transient)
      end

      it "keeps multiline access-token authentication service refresh failures retryable" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "",
            stderr: <<~ERROR,
              Your access token could not be refreshed because
              the authentication service was unavailable.
            ERROR
            exit_code: 1,
            duration: 1.0
          )
        )

        result = provider.smoke_test

        expect(result[:ok]).to be false
        expect(result[:error_category]).to eq(:transient)
      end

      it "keeps failed-refresh authentication service unavailable failures retryable" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "",
            stderr: "Failed to refresh token because the authentication service was unavailable.",
            exit_code: 1,
            duration: 1.0
          )
        )

        result = provider.smoke_test

        expect(result[:ok]).to be false
        expect(result[:error_category]).to eq(:transient)
      end

      it "keeps multiline failed-refresh authentication service unavailable failures retryable" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "",
            stderr: <<~ERROR,
              Failed to refresh token:
              the authentication service was unavailable.
            ERROR
            exit_code: 1,
            duration: 1.0
          )
        )

        result = provider.smoke_test

        expect(result[:ok]).to be false
        expect(result[:error_category]).to eq(:transient)
      end

      it "keeps failed-refresh temporarily unavailable failures retryable" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "",
            stderr: "Failed to refresh token because the authentication service was temporarily unavailable.",
            exit_code: 1,
            duration: 1.0
          )
        )

        result = provider.smoke_test

        expect(result[:ok]).to be false
        expect(result[:error_category]).to eq(:transient)
      end

      it "keeps failed-refresh connection error failures retryable" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "",
            stderr: "Failed to refresh token because connection error while contacting oauth endpoint.",
            exit_code: 1,
            duration: 1.0
          )
        )

        result = provider.smoke_test

        expect(result[:ok]).to be false
        expect(result[:error_category]).to eq(:transient)
      end

      it "classifies OAuth refresh timeout failures as timeout" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "",
            stderr: "Your access token could not be refreshed because the auth service timed out.",
            exit_code: 1,
            duration: 1.0
          )
        )

        result = provider.smoke_test

        expect(result[:ok]).to be false
        expect(result[:error_category]).to eq(:timeout)
      end

      it "classifies authentication service refresh timeout failures as timeout" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "",
            stderr: "Your access token could not be refreshed because the authentication service timed out.",
            exit_code: 1,
            duration: 1.0
          )
        )

        result = provider.smoke_test

        expect(result[:ok]).to be false
        expect(result[:error_category]).to eq(:timeout)
      end

      it "classifies multiline access-token authentication service timeout failures as timeout" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "",
            stderr: <<~ERROR,
              Your access token could not be refreshed because
              the authentication service timed out.
            ERROR
            exit_code: 1,
            duration: 1.0
          )
        )

        result = provider.smoke_test

        expect(result[:ok]).to be false
        expect(result[:error_category]).to eq(:timeout)
      end

      it "classifies hyphenated authentication service refresh timeout failures as timeout" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "",
            stderr: "Your access token could not be refreshed because the authentication service timed-out.",
            exit_code: 1,
            duration: 1.0
          )
        )

        result = provider.smoke_test

        expect(result[:ok]).to be false
        expect(result[:error_category]).to eq(:timeout)
      end

      it "classifies failed-refresh authentication service timeout failures as timeout" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "",
            stderr: "Failed to refresh token because the authentication service timed out.",
            exit_code: 1,
            duration: 1.0
          )
        )

        result = provider.smoke_test

        expect(result[:ok]).to be false
        expect(result[:error_category]).to eq(:timeout)
      end

      it "classifies multiline failed-refresh authentication service timeout failures as timeout" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "",
            stderr: <<~ERROR,
              Failed to refresh token:
              the authentication service timed out.
            ERROR
            exit_code: 1,
            duration: 1.0
          )
        )

        result = provider.smoke_test

        expect(result[:ok]).to be false
        expect(result[:error_category]).to eq(:timeout)
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

  describe "#test_command_overrides" do
    it "returns codex-specific test flags" do
      provider = described_class.new
      expect(provider.test_command_overrides).to eq(["--skip-git-repo-check", "--output-last-message"])
    end
  end
end
