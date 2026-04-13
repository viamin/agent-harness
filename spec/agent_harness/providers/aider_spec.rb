# frozen_string_literal: true

require "shellwords"
require "tmpdir"

RSpec.describe AgentHarness::Providers::Aider do
  describe ".provider_name" do
    it "returns :aider" do
      expect(described_class.provider_name).to eq(:aider)
    end
  end

  describe ".binary_name" do
    it "returns aider" do
      expect(described_class.binary_name).to eq("aider")
    end
  end

  describe ".installation_contract" do
    it "exposes Aider CLI install metadata" do
      contract = described_class.installation_contract

      expect(contract).to include(
        source: :uv_tool,
        bootstrap_source: :pip,
        bootstrap_package: "uv==0.8.17",
        package_name: "aider-chat",
        version: "0.86.2",
        binary_name: "aider",
        binary_path: "/usr/local/bin/aider"
      )
      expect(contract[:install_environment]).to eq(
        "UV_TOOL_BIN_DIR" => "/usr/local/bin",
        "UV_TOOL_DIR" => "/opt/uv/tools",
        "UV_PYTHON_INSTALL_DIR" => "/opt/uv/python"
      )
      expect(contract[:bootstrap_commands]).to eq(
        [["python3", "-m", "pip", "install", "--no-cache-dir", "--break-system-packages", "uv==0.8.17"]]
      )
      expect(contract[:install_command]).to eq(
        ["uv", "tool", "install", "--force", "--python", "python3.12", "--with", "pip", "aider-chat==0.86.2"]
      )
    end

    it "keeps runtime binary expectations aligned with the install contract" do
      contract = described_class.installation_contract

      expect(contract[:binary_name]).to eq(described_class.binary_name)
      expect(File.basename(contract[:binary_path])).to eq(described_class.binary_name)

      # Verify the advertised binary_path is inside the directory the install
      # environment actually targets, so a stray binary earlier on PATH cannot
      # shadow the one the contract promises to provision.
      tool_bin_dir = contract[:install_environment]["UV_TOOL_BIN_DIR"]
      expect(File.dirname(contract[:binary_path])).to eq(tool_bin_dir)
    end

    it "supports explicit version selection through the published contract API" do
      contract = described_class.installation_contract(version: "0.86.5")

      expect(contract).to include(
        package: "aider-chat==0.86.5",
        version: "0.86.5"
      )
      expect(contract[:supported_versions]).to eq(["0.86.5"])
      expect(contract[:install_command]).to eq(
        ["uv", "tool", "install", "--force", "--python", "python3.12", "--with", "pip", "aider-chat==0.86.5"]
      )
    end

    it "rejects unsupported version selection through the contract API" do
      expect {
        described_class.installation_contract(version: "0.85.0")
      }.to raise_error(ArgumentError, /Unsupported Aider CLI version "0.85.0"/)
    end

    it "rejects malformed version strings with a provider-specific message" do
      expect {
        described_class.installation_contract(version: "not-a-version")
      }.to raise_error(ArgumentError, /Unsupported Aider CLI version/)
    end

    it "rejects nil version" do
      expect {
        described_class.installation_contract(version: nil)
      }.to raise_error(ArgumentError, /Unsupported Aider CLI version/)
    end

    it "rejects empty version" do
      expect {
        described_class.installation_contract(version: "")
      }.to raise_error(ArgumentError, /Unsupported Aider CLI version/)
    end

    it "normalizes padded version strings in the install command and contract" do
      contract = described_class.installation_contract(version: " 0.86.5 ")

      expect(contract[:version]).to eq("0.86.5")
      expect(contract[:install_command]).to eq(
        ["uv", "tool", "install", "--force", "--python", "python3.12", "--with", "pip", "aider-chat==0.86.5"]
      )
    end

    it "freezes nested command arrays" do
      contract = described_class.installation_contract

      expect { contract[:bootstrap_commands] << ["echo"] }.to raise_error(FrozenError)
      expect { contract[:bootstrap_commands].first << "uv" }.to raise_error(FrozenError)
      expect { contract[:install_command_prefix] << "aider" }.to raise_error(FrozenError)
      expect { contract[:install_command] << "aider" }.to raise_error(FrozenError)
    end
  end

  describe ".install_command" do
    it "builds the default install command from the contract" do
      expect(described_class.install_command).to eq(
        ["uv", "tool", "install", "--force", "--python", "python3.12", "--with", "pip", "aider-chat==0.86.2"]
      )
    end

    it "supports explicit version overrides using aider-chat==version formatting" do
      expect(described_class.install_command(version: "0.86.5")).to eq(
        ["uv", "tool", "install", "--force", "--python", "python3.12", "--with", "pip", "aider-chat==0.86.5"]
      )
    end

    it "rejects unsupported explicit version overrides" do
      expect {
        described_class.install_command(version: "999.0.0")
      }.to raise_error(ArgumentError, /Unsupported Aider CLI version "999.0.0"/)
    end
  end

  describe ".firewall_requirements" do
    it "returns required domains" do
      requirements = described_class.firewall_requirements
      expect(requirements[:domains]).to include("api.openai.com")
      expect(requirements[:domains]).to include("api.anthropic.com")
    end
  end

  describe ".instruction_file_paths" do
    it "returns aider config" do
      paths = described_class.instruction_file_paths
      expect(paths.first[:path]).to eq(".aider.conf.yml")
    end
  end

  describe "instance" do
    subject(:provider) { described_class.new }

    describe "#name" do
      it "returns aider" do
        expect(provider.name).to eq("aider")
      end
    end

    describe "#display_name" do
      it "returns Aider" do
        expect(provider.display_name).to eq("Aider")
      end
    end

    describe "#configuration_schema" do
      it "includes a model field that accepts arbitrary values" do
        schema = provider.configuration_schema
        model_field = schema[:fields].find { |f| f[:name] == :model }
        expect(model_field).not_to be_nil
        expect(model_field[:accepts_arbitrary]).to be true
      end

      it "uses api_key auth mode" do
        expect(provider.configuration_schema[:auth_modes]).to eq([:api_key])
      end

      it "is not openai compatible" do
        expect(provider.configuration_schema[:openai_compatible]).to be false
      end
    end

    describe "#capabilities" do
      it "includes streaming" do
        expect(provider.capabilities[:streaming]).to be true
      end
    end

    describe "#supports_sessions?" do
      it "returns true" do
        expect(provider.supports_sessions?).to be true
      end
    end

    describe "#session_flags" do
      it "returns restore flags when session provided" do
        flags = provider.session_flags("session-123")
        expect(flags).to eq(["--restore-chat-history", "session-123"])
      end
    end

    describe "#auth_type" do
      it "returns :api_key" do
        expect(provider.auth_type).to eq(:api_key)
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

      it "includes transient patterns" do
        patterns = provider.error_patterns
        expect(patterns[:transient]).not_to be_empty
      end
    end

    describe "#execution_semantics" do
      it "reports prompt delivery as :flag" do
        expect(provider.execution_semantics[:prompt_delivery]).to eq(:flag)
      end

      it "reports non_interactive_flag as --yes" do
        expect(provider.execution_semantics[:non_interactive_flag]).to eq("--yes")
      end
    end

    describe "#build_command" do
      it "uses the install contract binary name and non-interactive flag" do
        contract = described_class.installation_contract
        allow(provider).to receive(:instance_variable_get).with(:@aider_history_tempfile).and_return(nil)
        command = provider.send(:build_command, "hello", {})

        expect(command.first).to eq(contract[:binary_name])
        expect(command).to include(provider.execution_semantics[:non_interactive_flag])
      end

      it "includes --llm-history-file when llm_history_path is set" do
        command = provider.send(:build_command, "hello", llm_history_path: "/tmp/test_history.log")

        expect(command).to include("--llm-history-file", "/tmp/test_history.log")
      end

      it "does not include --llm-history-file when llm_history_path is nil" do
        command = provider.send(:build_command, "hello", {})

        expect(command).not_to include("--llm-history-file")
      end

      it "prefers the runtime model over the configured model" do
        provider.configure(model: "configured-model")
        runtime = AgentHarness::ProviderRuntime.new(model: "runtime-model")

        command = provider.send(:build_command, "hello", provider_runtime: runtime)

        expect(command).to include("--model", "runtime-model")
        expect(command).not_to include("configured-model")
      end

      it "appends runtime flags after provider flags" do
        runtime = AgentHarness::ProviderRuntime.new(flags: ["--map-tokens", "0"])

        command = provider.send(:build_command, "hello", provider_runtime: runtime)

        expect(command).to include("--map-tokens", "0")
      end

      it "rejects runtime flags that override the provider-managed history path" do
        runtime = AgentHarness::ProviderRuntime.new(flags: ["--llm-history-file", "/tmp/override.log"])

        expect {
          provider.send(:build_command, "hello", provider_runtime: runtime, llm_history_path: "/tmp/request.log")
        }.to raise_error(ArgumentError, /provider-managed flags: --llm-history-file \/tmp\/override\.log/)
      end

      it "rejects runtime flags that use inline history-file assignment" do
        runtime = AgentHarness::ProviderRuntime.new(flags: ["--llm-history-file=/tmp/override.log"])

        expect {
          provider.send(:build_command, "hello", provider_runtime: runtime, llm_history_path: "/tmp/request.log")
        }.to raise_error(ArgumentError, /provider-managed flags: --llm-history-file=\/tmp\/override\.log/)
      end
    end

    describe "#send_message" do
      let(:mock_executor) do
        instance_double(AgentHarness::CommandExecutor)
      end
      let(:provider) { described_class.new(executor: mock_executor) }
      let(:result) do
        AgentHarness::CommandExecutor::Result.new(
          stdout: "response text",
          stderr: "",
          exit_code: 0
        )
      end

      before do
        allow(mock_executor).to receive(:execute).and_return(result)
      end

      it "creates an llm history file flag in the command" do
        expect(mock_executor).to receive(:execute) do |cmd, **kwargs|
          expect(cmd).to include("--llm-history-file")
          result
        end

        provider.send_message(prompt: "hello")
      end

      it "cleans up the temp history file after execution" do
        history_path = nil
        allow(mock_executor).to receive(:execute) do |cmd, **kwargs|
          history_path = cmd[cmd.index("--llm-history-file") + 1]
          File.write(history_path, "")
          result
        end

        provider.send_message(prompt: "hello")
        expect(File.exist?(history_path)).to be false
      end

      it "cleans up the temp history file even when execution fails" do
        history_path = nil
        allow(mock_executor).to receive(:execute) do |cmd, **kwargs|
          history_path = cmd[cmd.index("--llm-history-file") + 1]
          File.write(history_path, "")
          raise Timeout::Error, "timed out"
        end

        expect { provider.send_message(prompt: "hello") }.to raise_error(AgentHarness::TimeoutError)
        expect(File.exist?(history_path)).to be false
      end

      it "extracts tokens from plain-text usage reports in the history file" do
        allow(mock_executor).to receive(:execute) do |cmd, **kwargs|
          history_path = cmd[cmd.index("--llm-history-file") + 1]
          File.write(history_path, <<~TEXT)
            TO LLM 2026-04-12T00:00:00
            -------
            USER hello
            LLM RESPONSE 2026-04-12T00:00:01
            ASSISTANT world

            Tokens: 10 sent, 20 received.
          TEXT
          result
        end

        response = provider.send_message(prompt: "hello")
        expect(response.tokens).to eq({input: 10, output: 20, total: 30})
      end

      it "parses comma-delimited token counts from command output when history lacks usage" do
        allow(mock_executor).to receive(:execute) do |cmd, **kwargs|
          history_path = cmd[cmd.index("--llm-history-file") + 1]
          File.write(history_path, <<~TEXT)
            TO LLM 2026-04-12T00:00:00
            -------
            USER hello
          TEXT
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response text\n\nTokens: 1,500 sent, 250 received.\n",
            stderr: "",
            exit_code: 0
          )
        end

        response = provider.send_message(prompt: "hello")
        expect(response.tokens).to eq({input: 1500, output: 250, total: 1750})
      end

      it "parses abbreviated token counts with cache segments from command output" do
        allow(mock_executor).to receive(:execute) do |cmd, **kwargs|
          history_path = cmd[cmd.index("--llm-history-file") + 1]
          File.write(history_path, "")
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response text\n\nTokens: 2.9k sent, 7.6k cache write, 31 received.\n",
            stderr: "",
            exit_code: 0
          )
        end

        response = provider.send_message(prompt: "hello")
        expect(response.tokens).to eq({input: 2900, output: 31, total: 2931})
      end

      it "parses token counts when aider includes trailing cost text" do
        allow(mock_executor).to receive(:execute) do |cmd, **kwargs|
          history_path = cmd[cmd.index("--llm-history-file") + 1]
          File.write(history_path, "")
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response text\n\nTokens: 1,500 sent, 250 received. Cost: $0.0012 message, $0.0045 session.\n",
            stderr: "",
            exit_code: 0
          )
        end

        response = provider.send_message(prompt: "hello")
        expect(response.tokens).to eq({input: 1500, output: 250, total: 1750})
      end

      it "uses the last token report when multiple usage lines are present" do
        allow(mock_executor).to receive(:execute) do |cmd, **kwargs|
          history_path = cmd[cmd.index("--llm-history-file") + 1]
          File.write(history_path, <<~TEXT)
            ASSISTANT world

            Tokens: 10 sent, 5 received.
            Tokens: 20 sent, 10 received.
          TEXT
          result
        end

        response = provider.send_message(prompt: "hello")
        expect(response.tokens).to eq({input: 20, output: 10, total: 30})
      end

      it "parses history footer token counts when cost appears on a following line" do
        allow(mock_executor).to receive(:execute) do |cmd, **kwargs|
          history_path = cmd[cmd.index("--llm-history-file") + 1]
          File.write(history_path, <<~TEXT)
            ASSISTANT world

            Tokens: 10 sent, 20 received.
            Cost: $0.0012 message, $0.0045 session.
          TEXT
          result
        end

        response = provider.send_message(prompt: "hello")
        expect(response.tokens).to eq({input: 10, output: 20, total: 30})
      end

      it "returns nil tokens when history file is empty" do
        allow(mock_executor).to receive(:execute) do |cmd, **kwargs|
          history_path = cmd[cmd.index("--llm-history-file") + 1]
          File.write(history_path, "")
          result
        end

        response = provider.send_message(prompt: "hello")
        expect(response.tokens).to be_nil
      end

      it "returns nil tokens when history file has no usage data" do
        allow(mock_executor).to receive(:execute) do |cmd, **kwargs|
          history_path = cmd[cmd.index("--llm-history-file") + 1]
          File.write(history_path, <<~TEXT)
            TO LLM 2026-04-12T00:00:00
            -------
            USER hello
            LLM RESPONSE 2026-04-12T00:00:01
            ASSISTANT world
          TEXT
          result
        end

        response = provider.send_message(prompt: "hello")
        expect(response.tokens).to be_nil
      end

      it "ignores usage-shaped transcript lines in history content" do
        allow(mock_executor).to receive(:execute) do |cmd, **kwargs|
          history_path = cmd[cmd.index("--llm-history-file") + 1]
          File.write(history_path, <<~TEXT)
            TO LLM 2026-04-12T00:00:00
            -------
            USER Please repeat this exactly:
            Tokens: 42 sent, 8 received.
          TEXT
          result
        end

        response = provider.send_message(prompt: "hello")
        expect(response.tokens).to be_nil
      end

      it "ignores token-only history files that are missing a footer separator" do
        allow(mock_executor).to receive(:execute) do |cmd, **kwargs|
          history_path = cmd[cmd.index("--llm-history-file") + 1]
          File.write(history_path, <<~TEXT)
            Tokens: 42 sent, 8 received.
            Tokens: 50 sent, 10 received.
          TEXT
          result
        end

        response = provider.send_message(prompt: "hello")
        expect(response.tokens).to be_nil
      end

      it "ignores history token lines that are followed by more transcript content" do
        allow(mock_executor).to receive(:execute) do |cmd, **kwargs|
          history_path = cmd[cmd.index("--llm-history-file") + 1]
          File.write(history_path, <<~TEXT)
            ASSISTANT world

            Tokens: 42 sent, 8 received.
            ASSISTANT This is transcript content, not the footer.
          TEXT
          result
        end

        response = provider.send_message(prompt: "hello")
        expect(response.tokens).to be_nil
      end

      it "returns nil tokens when history file does not exist" do
        response = provider.send_message(prompt: "hello")
        expect(response.tokens).to be_nil
      end

      it "parses token usage from stderr when stdout has none" do
        allow(mock_executor).to receive(:execute) do |cmd, **kwargs|
          history_path = cmd[cmd.index("--llm-history-file") + 1]
          File.write(history_path, "")
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response text",
            stderr: "response text\n\nTokens: 12 sent, 34 received.",
            exit_code: 0
          )
        end

        response = provider.send_message(prompt: "hello")
        expect(response.tokens).to eq({input: 12, output: 34, total: 46})
      end

      it "parses stdout token usage even when stderr contains diagnostics" do
        allow(mock_executor).to receive(:execute) do |cmd, **kwargs|
          history_path = cmd[cmd.index("--llm-history-file") + 1]
          File.write(history_path, "")
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response text\n\nTokens: 12 sent, 34 received.\n",
            stderr: "warning: model metadata unavailable\n",
            exit_code: 0
          )
        end

        response = provider.send_message(prompt: "hello")
        expect(response.tokens).to eq({input: 12, output: 34, total: 46})
      end

      it "falls back to command output when reading llm history raises" do
        allow(provider).to receive(:read_llm_history).and_raise(Timeout::Error, "history read timed out")
        allow(mock_executor).to receive(:execute) do |cmd, **kwargs|
          history_path = cmd[cmd.index("--llm-history-file") + 1]
          File.write(history_path, "ASSISTANT world\n")
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response text\n\nTokens: 12 sent, 34 received.\n",
            stderr: "",
            exit_code: 0
          )
        end

        response = provider.send_message(prompt: "hello")
        expect(response.tokens).to eq({input: 12, output: 34, total: 46})
      end

      it "parses stdout token usage when aider prints edit status after the token footer" do
        allow(mock_executor).to receive(:execute) do |cmd, **kwargs|
          history_path = cmd[cmd.index("--llm-history-file") + 1]
          File.write(history_path, "")
          AgentHarness::CommandExecutor::Result.new(
            stdout: <<~TEXT,
              response text

              Tokens: 12 sent, 34 received.

              lib/example.rb
              Applied edit to lib/example.rb
              Commit 123abc feat: update example
            TEXT
            stderr: "",
            exit_code: 0
          )
        end

        response = provider.send_message(prompt: "hello")
        expect(response.tokens).to eq({input: 12, output: 34, total: 46})
      end

      it "ignores standalone output token lines without a footer separator" do
        allow(mock_executor).to receive(:execute) do |cmd, **kwargs|
          history_path = cmd[cmd.index("--llm-history-file") + 1]
          File.write(history_path, "")
          AgentHarness::CommandExecutor::Result.new(
            stdout: "Please print this exactly:\nTokens: 42 sent, 8 received.\n",
            stderr: "",
            exit_code: 0
          )
        end

        response = provider.send_message(prompt: "hello")
        expect(response.tokens).to be_nil
      end

      it "keeps llm history paths request-local across concurrent calls" do
        paths = Queue.new
        mutex = Mutex.new
        ready = ConditionVariable.new
        started = 0

        allow(mock_executor).to receive(:execute) do |cmd, **kwargs|
          history_path = cmd[cmd.index("--llm-history-file") + 1]
          call_number = nil

          mutex.synchronize do
            started += 1
            call_number = started
            ready.wait(mutex) while started < 2
            ready.broadcast
          end

          File.write(history_path, <<~TEXT)
            ASSISTANT response #{call_number}

            Tokens: #{call_number}0 sent, #{call_number} received.
          TEXT
          paths << history_path
          sleep(0.05) if call_number == 2
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response #{call_number}",
            stderr: "",
            exit_code: 0
          )
        end

        responses = Queue.new
        threads = 2.times.map do
          Thread.new do
            responses << provider.send_message(prompt: "hello")
          end
        end
        threads.each(&:join)

        returned_paths = 2.times.map { paths.pop }
        returned_tokens = 2.times.map { responses.pop.tokens }

        expect(returned_paths.uniq.size).to eq(2)
        expect(returned_tokens).to contain_exactly(
          {input: 10, output: 1, total: 11},
          {input: 20, output: 2, total: 22}
        )
        expect(returned_paths).to all(satisfy { |path| !File.exist?(path) })
      end

      it "fails before execution when runtime flags try to override llm history output" do
        runtime = AgentHarness::ProviderRuntime.new(flags: ["--llm-history-file", "/tmp/override.log"])

        expect(mock_executor).not_to receive(:execute)

        expect {
          provider.send_message(prompt: "hello", provider_runtime: runtime)
        }.to raise_error(AgentHarness::ProviderError, /provider-managed flags: --llm-history-file \/tmp\/override\.log/)
      end

      context "with DockerCommandExecutor" do
        let(:docker_executor) { instance_double(AgentHarness::DockerCommandExecutor) }
        let(:provider) { described_class.new(executor: docker_executor) }

        before do
          allow(docker_executor).to receive(:is_a?).with(AgentHarness::DockerCommandExecutor).and_return(true)
        end

        it "reads and cleans up the history file inside the container" do
          history_path = nil
          calls = []
          allow(docker_executor).to receive(:execute) do |cmd, **kwargs|
            calls << [cmd, kwargs]

            if cmd.first == "aider"
              history_path = cmd[cmd.index("--llm-history-file") + 1]
              result
            elsif cmd[2].start_with?("if [ -s ")
              AgentHarness::CommandExecutor::Result.new(
                stdout: "ASSISTANT world\n\nTokens: 10 sent, 20 received.\n",
                stderr: "",
                exit_code: 0
              )
            else
              AgentHarness::CommandExecutor::Result.new(
                stdout: "",
                stderr: "",
                exit_code: 0
              )
            end
          end

          response = provider.send_message(prompt: "hello")

          expect(calls.size).to eq(3)
          expect(calls[0]).to match(
            [
              array_including("aider", "--llm-history-file"),
              hash_including(timeout: be_within(0.01).of(600))
            ]
          )
          expect(history_path).to start_with("/tmp/aider_llm_history_")
          expect(calls[1]).to eq(
            [
              ["sh", "-lc", "if [ -s #{Shellwords.escape(history_path)} ]; then cat #{Shellwords.escape(history_path)}; fi"],
              {timeout: 10}
            ]
          )
          expect(calls[2]).to eq(
            [
              ["sh", "-lc", "rm -f -- #{Shellwords.escape(history_path)}"],
              {timeout: 10}
            ]
          )
          expect(response.tokens).to eq({input: 10, output: 20, total: 30})
        end
      end
    end

    describe "#parse_response with llm history" do
      let(:result) do
        AgentHarness::CommandExecutor::Result.new(
          stdout: "response text",
          stderr: "",
          exit_code: 0
        )
      end

      it "augments the base response with tokens from the history file" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "history.log")
          File.write(path, "ASSISTANT world\n\nTokens: 100 sent, 50 received.")

          response = provider.send(:parse_response, result, duration: 1.0, llm_history_path: path)
          expect(response.output).to eq("response text")
          expect(response.exit_code).to eq(0)
          expect(response.tokens).to eq({input: 100, output: 50, total: 150})
        end
      end

      it "returns the base response unchanged when no tokens are found" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "history.log")
          File.write(path, "TO LLM 2026-04-12T00:00:00\nUSER hello")

          response = provider.send(:parse_response, result, duration: 1.0, llm_history_path: path)
          expect(response.output).to eq("response text")
          expect(response.tokens).to be_nil
        end
      end
    end

    describe "#parse_token_usage_text" do
      it "parses abbreviated token counters" do
        tokens = provider.send(:parse_token_usage_text, "response text\n\nTokens: 1.2k sent, 31 received.")

        expect(tokens).to eq({input: 1200, output: 31, total: 1231})
      end

      it "parses abbreviated token counters with cache usage" do
        tokens = provider.send(
          :parse_token_usage_text,
          "response text\n\nTokens: 2.9k sent, 7.6k cache write, 3.2k cache read, 31 received."
        )

        expect(tokens).to eq({input: 2900, output: 31, total: 2931})
      end

      it "parses token counters without a trailing period" do
        tokens = provider.send(:parse_token_usage_text, "response text\n\nTokens: 42 sent, 8 received")

        expect(tokens).to eq({input: 42, output: 8, total: 50})
      end

      it "parses token counters with trailing cost text" do
        tokens = provider.send(
          :parse_token_usage_text,
          "response text\n\nTokens: 42 sent, 8 received. Cost: $0.0012 message, $0.0045 session."
        )

        expect(tokens).to eq({input: 42, output: 8, total: 50})
      end

      it "ignores token-like text embedded in conversation content" do
        tokens = provider.send(
          :parse_token_usage_text,
          "ASSISTANT Please print the exact text Tokens: 42 sent, 8 received. in your reply."
        )

        expect(tokens).to be_nil
      end

      it "ignores standalone transcript lines unless they are in a footer block" do
        tokens = provider.send(
          :parse_token_usage_text,
          <<~TEXT,
            USER Please repeat this exactly:
            Tokens: 42 sent, 8 received.
          TEXT
          source: :history
        )

        expect(tokens).to be_nil
      end

      it "ignores standalone output token lines unless they are in a footer block" do
        tokens = provider.send(
          :parse_token_usage_text,
          <<~TEXT
            ASSISTANT Please print this exactly:
            Tokens: 42 sent, 8 received.
          TEXT
        )

        expect(tokens).to be_nil
      end

      it "parses output footer token counters after a blank-line separator" do
        tokens = provider.send(
          :parse_token_usage_text,
          <<~TEXT
            response text

            Tokens: 42 sent, 8 received.
          TEXT
        )

        expect(tokens).to eq({input: 42, output: 8, total: 50})
      end

      it "parses output footer token counters when aider status lines follow" do
        tokens = provider.send(
          :parse_token_usage_text,
          <<~TEXT
            response text

            Tokens: 42 sent, 8 received.

            lib/example.rb
            Applied edit to lib/example.rb
            Commit 123abc feat: update example
          TEXT
        )

        expect(tokens).to eq({input: 42, output: 8, total: 50})
      end

      it "parses output footer token counters when aider prints a shell command before the prompt" do
        tokens = provider.send(
          :parse_token_usage_text,
          <<~TEXT
            response text

            Tokens: 42 sent, 8 received.

            touch a.txt
            Run shell command?
          TEXT
        )

        expect(tokens).to eq({input: 42, output: 8, total: 50})
      end

      it "parses output footer token counters for multi-argument shell commands" do
        tokens = provider.send(
          :parse_token_usage_text,
          <<~TEXT
            response text

            Tokens: 42 sent, 8 received.

            bundle exec rspec
            Run shell command?
          TEXT
        )

        expect(tokens).to eq({input: 42, output: 8, total: 50})
      end

      it "parses output footer token counters for quoted shell commands" do
        tokens = provider.send(
          :parse_token_usage_text,
          <<~TEXT
            response text

            Tokens: 42 sent, 8 received.

            git commit -m "fix bug"
            Run shell command?
          TEXT
        )

        expect(tokens).to eq({input: 42, output: 8, total: 50})
      end

      it "parses output footer token counters for non-whitelisted shell commands with shell-like arguments" do
        tokens = provider.send(
          :parse_token_usage_text,
          <<~TEXT
            response text

            Tokens: 42 sent, 8 received.

            pytest -q
            Run shell command?
          TEXT
        )

        expect(tokens).to eq({input: 42, output: 8, total: 50})
      end

      it "parses output footer token counters for script-path shell commands" do
        tokens = provider.send(
          :parse_token_usage_text,
          <<~TEXT
            response text

            Tokens: 42 sent, 8 received.

            ./scripts/test.sh --help
            Run shell command?
          TEXT
        )

        expect(tokens).to eq({input: 42, output: 8, total: 50})
      end

      it "parses output footer token counters when aider prints a committing status line" do
        tokens = provider.send(
          :parse_token_usage_text,
          <<~TEXT
            response text

            Tokens: 42 sent, 8 received.

            Committing lib/example.rb before applying edits.
            Applied edit to lib/example.rb
          TEXT
        )

        expect(tokens).to eq({input: 42, output: 8, total: 50})
      end

      it "ignores capitalized status lines before a shell prompt" do
        tokens = provider.send(
          :parse_token_usage_text,
          <<~TEXT
            response text

            Tokens: 42 sent, 8 received.

            Done
            Run shell command?
          TEXT
        )

        expect(tokens).to be_nil
      end

      it "ignores lowercase prose-like lines before a shell prompt" do
        tokens = provider.send(
          :parse_token_usage_text,
          <<~TEXT
            response text

            Tokens: 42 sent, 8 received.

            thanks
            Run shell command?
          TEXT
        )

        expect(tokens).to be_nil
      end

      it "still ignores output token counters followed by arbitrary prose" do
        tokens = provider.send(
          :parse_token_usage_text,
          <<~TEXT
            response text

            Tokens: 42 sent, 8 received.
            Here is more assistant prose after the token line.
          TEXT
        )

        expect(tokens).to be_nil
      end

      it "ignores output token counters followed by prose before a shell prompt" do
        tokens = provider.send(
          :parse_token_usage_text,
          <<~TEXT
            response text

            Tokens: 42 sent, 8 received.
            Here is a sentence.
            Run shell command?
          TEXT
        )

        expect(tokens).to be_nil
      end

      it "ignores output token counters followed by a one-word status line" do
        tokens = provider.send(
          :parse_token_usage_text,
          <<~TEXT
            response text

            Tokens: 42 sent, 8 received.
            OK
          TEXT
        )

        expect(tokens).to be_nil
      end

      it "ignores output token counters followed by status-like lines ending in a period" do
        tokens = provider.send(
          :parse_token_usage_text,
          <<~TEXT
            response text

            Tokens: 42 sent, 8 received.
            Done.
          TEXT
        )

        expect(tokens).to be_nil
      end

      it "parses history footer token counters after a blank-line separator" do
        tokens = provider.send(
          :parse_token_usage_text,
          <<~TEXT,
            ASSISTANT world

            Tokens: 42 sent, 8 received. Cost: $0.0012 message, $0.0045 session.
          TEXT
          source: :history
        )

        expect(tokens).to eq({input: 42, output: 8, total: 50})
      end

      it "parses history footer token counters when cost is on the next line" do
        tokens = provider.send(
          :parse_token_usage_text,
          <<~TEXT,
            ASSISTANT world

            Tokens: 42 sent, 8 received.
            Cost: $0.0012 message, $0.0045 session.
          TEXT
          source: :history
        )

        expect(tokens).to eq({input: 42, output: 8, total: 50})
      end

      it "ignores token-only history content without a blank-line footer separator" do
        tokens = provider.send(
          :parse_token_usage_text,
          <<~TEXT,
            Tokens: 42 sent, 8 received.
            Tokens: 50 sent, 10 received.
          TEXT
          source: :history
        )

        expect(tokens).to be_nil
      end

      it "ignores history token counters when later transcript lines follow" do
        tokens = provider.send(
          :parse_token_usage_text,
          <<~TEXT,
            ASSISTANT world

            Tokens: 42 sent, 8 received.
            ASSISTANT This is transcript content, not the footer.
          TEXT
          source: :history
        )

        expect(tokens).to be_nil
      end
    end

    describe "#supports_token_counting?" do
      it "returns true" do
        expect(provider.supports_token_counting?).to be true
      end
    end
  end

  describe "instance with executor" do
    let(:mock_executor) do
      instance_double(AgentHarness::CommandExecutor)
    end

    let(:config) do
      AgentHarness::ProviderConfig.new(:aider).tap do |c|
        c.model = "gpt-4o"
      end
    end

    subject(:provider) { described_class.new(config: config, executor: mock_executor) }

    describe "#send_message" do
      it "includes --llm-history-file in the command" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        expect(mock_executor).to receive(:execute).with(
          array_including("--llm-history-file"),
          anything
        )

        provider.send_message(prompt: "Hello")
      end

      it "creates the local history file before execution starts" do
        allow(mock_executor).to receive(:execute) do |_cmd, _opts|
          tempfile = provider.instance_variable_get(:@aider_history_tempfile)
          expect(tempfile).not_to be_nil
          expect(File.exist?(tempfile.path)).to be true

          AgentHarness::CommandExecutor::Result.new(
            stdout: "response",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        end

        provider.send_message(prompt: "Hello")
      end

      it "cleans up the history tempfile after execution" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        provider.send_message(prompt: "Hello")
        expect(provider.instance_variable_get(:@aider_history_tempfile)).to be_nil
        expect(provider.instance_variable_get(:@aider_history_path)).to be_nil
      end

      it "cleans up the history tempfile even when execution fails" do
        allow(mock_executor).to receive(:execute).and_raise(StandardError.new("something went wrong"))

        expect {
          provider.send_message(prompt: "Hello")
        }.to raise_error(AgentHarness::ProviderError)

        expect(provider.instance_variable_get(:@aider_history_tempfile)).to be_nil
        expect(provider.instance_variable_get(:@aider_history_path)).to be_nil
      end

      it "fails before reserving a history file when timeout is non-positive" do
        expect(provider).not_to receive(:prepare_llm_history_file!)
        expect(mock_executor).not_to receive(:execute)

        expect {
          provider.send_message(prompt: "Hello", timeout: 0)
        }.to raise_error(AgentHarness::TimeoutError, "Command timed out before execution started")

        expect(provider.instance_variable_get(:@aider_history_tempfile)).to be_nil
        expect(provider.instance_variable_get(:@aider_history_path)).to be_nil
      end

      it "times out before execution if history-file setup exhausts the request budget" do
        allow(provider).to receive(:prepare_llm_history_file!).and_return("/tmp/aider_history")
        expect(mock_executor).not_to receive(:execute)

        times = [
          Time.utc(2026, 4, 13, 0, 0, 0),
          Time.utc(2026, 4, 13, 0, 0, 1)
        ]
        allow(Time).to receive(:now).and_return(*times)

        expect {
          provider.send_message(prompt: "Hello", timeout: 1)
        }.to raise_error(AgentHarness::TimeoutError, "Command timed out before execution started")
      end

      it "does not clear a newer local history handle when cleaning up an older path" do
        older_path = provider.send(:prepare_llm_history_file!)
        newer_path = provider.send(:prepare_llm_history_file!)

        expect(provider.instance_variable_get(:@aider_history_tempfile)&.path).to eq(newer_path)

        provider.send(:cleanup_llm_history_file!, older_path)

        expect(provider.instance_variable_get(:@aider_history_tempfile)&.path).to eq(newer_path)

        provider.send(:cleanup_llm_history_file!, newer_path)

        expect(provider.instance_variable_get(:@aider_history_tempfile)).to be_nil
      end

      context "with token usage from history file" do
        it "extracts tokens from OpenAI-format history" do
          allow(mock_executor).to receive(:execute) do |_cmd, _opts|
            tempfile = provider.instance_variable_get(:@aider_history_tempfile)
            history_path = tempfile.path if tempfile
            if history_path
              File.write(history_path, JSON.generate([
                {"usage" => {"prompt_tokens" => 100, "completion_tokens" => 50, "total_tokens" => 150}}
              ]))
            end

            AgentHarness::CommandExecutor::Result.new(
              stdout: "response text",
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          end

          response = provider.send_message(prompt: "Hello")
          expect(response.tokens).to eq({input: 100, output: 50, total: 150})
          expect(response.output).to eq("response text")
        end

        it "extracts tokens from Anthropic-format history" do
          allow(mock_executor).to receive(:execute) do |_cmd, _opts|
            tempfile = provider.instance_variable_get(:@aider_history_tempfile)
            path = tempfile.path if tempfile
            if path
              File.write(path, JSON.generate([
                {"usage" => {"input_tokens" => 200, "output_tokens" => 75}}
              ]))
            end

            AgentHarness::CommandExecutor::Result.new(
              stdout: "response text",
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          end

          response = provider.send_message(prompt: "Hello")
          expect(response.tokens).to eq({input: 200, output: 75, total: 275})
        end

        it "aggregates tokens from multiple history entries" do
          allow(mock_executor).to receive(:execute) do |_cmd, _opts|
            tempfile = provider.instance_variable_get(:@aider_history_tempfile)
            path = tempfile.path if tempfile
            if path
              File.write(path, JSON.generate([
                {"usage" => {"prompt_tokens" => 100, "completion_tokens" => 50}},
                {"usage" => {"prompt_tokens" => 50, "completion_tokens" => 25}}
              ]))
            end

            AgentHarness::CommandExecutor::Result.new(
              stdout: "response text",
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          end

          response = provider.send_message(prompt: "Hello")
          expect(response.tokens).to eq({input: 150, output: 75, total: 225})
        end

        it "extracts tokens from nested response.usage format" do
          allow(mock_executor).to receive(:execute) do |_cmd, _opts|
            tempfile = provider.instance_variable_get(:@aider_history_tempfile)
            path = tempfile.path if tempfile
            if path
              File.write(path, JSON.generate([
                {"response" => {"usage" => {"prompt_tokens" => 80, "completion_tokens" => 40}}}
              ]))
            end

            AgentHarness::CommandExecutor::Result.new(
              stdout: "response text",
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          end

          response = provider.send_message(prompt: "Hello")
          expect(response.tokens).to eq({input: 80, output: 40, total: 120})
        end

        it "returns nil tokens when history file is empty" do
          allow(mock_executor).to receive(:execute) do |_cmd, _opts|
            tempfile = provider.instance_variable_get(:@aider_history_tempfile)
            path = tempfile.path if tempfile
            File.write(path, "") if path

            AgentHarness::CommandExecutor::Result.new(
              stdout: "response text",
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          end

          response = provider.send_message(prompt: "Hello")
          expect(response.tokens).to be_nil
        end

        it "returns nil tokens when history file has no usage data" do
          allow(mock_executor).to receive(:execute) do |_cmd, _opts|
            tempfile = provider.instance_variable_get(:@aider_history_tempfile)
            path = tempfile.path if tempfile
            if path
              File.write(path, JSON.generate([{"content" => "no usage here"}]))
            end

            AgentHarness::CommandExecutor::Result.new(
              stdout: "response text",
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          end

          response = provider.send_message(prompt: "Hello")
          expect(response.tokens).to be_nil
        end

        it "ignores non-hash history entries while aggregating valid usage data" do
          allow(mock_executor).to receive(:execute) do |_cmd, _opts|
            tempfile = provider.instance_variable_get(:@aider_history_tempfile)
            path = tempfile.path if tempfile
            if path
              File.write(path, JSON.generate([
                "unexpected entry",
                {"usage" => {"prompt_tokens" => 60, "completion_tokens" => 20}}
              ]))
            end

            AgentHarness::CommandExecutor::Result.new(
              stdout: "response text",
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          end

          response = provider.send_message(prompt: "Hello")
          expect(response.tokens).to eq({input: 60, output: 20, total: 80})
        end

        it "skips malformed token counts while preserving valid history entries" do
          allow(mock_executor).to receive(:execute) do |_cmd, _opts|
            tempfile = provider.instance_variable_get(:@aider_history_tempfile)
            path = tempfile.path if tempfile
            if path
              File.write(path, JSON.generate([
                {"usage" => {"prompt_tokens" => "not-a-number", "completion_tokens" => []}},
                {"usage" => {"prompt_tokens" => "40", "completion_tokens" => 10}}
              ]))
            end

            AgentHarness::CommandExecutor::Result.new(
              stdout: "response text",
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          end

          response = provider.send_message(prompt: "Hello")
          expect(response.tokens).to eq({input: 40, output: 10, total: 50})
        end

        it "does not partially aggregate mixed plain-text history content" do
          allow(mock_executor).to receive(:execute) do |_cmd, _opts|
            tempfile = provider.instance_variable_get(:@aider_history_tempfile)
            path = tempfile.path if tempfile
            if path
              File.write(path, <<~HISTORY)
                conversation transcript
                {"usage":{"prompt_tokens":40,"completion_tokens":10}}
              HISTORY
            end

            AgentHarness::CommandExecutor::Result.new(
              stdout: "response text",
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          end

          response = provider.send_message(prompt: "Hello")
          expect(response.tokens).to be_nil
        end

        it "records tokens with the global token tracker" do
          allow(mock_executor).to receive(:execute) do |_cmd, _opts|
            tempfile = provider.instance_variable_get(:@aider_history_tempfile)
            path = tempfile.path if tempfile
            if path
              File.write(path, JSON.generate([
                {"usage" => {"prompt_tokens" => 50, "completion_tokens" => 25}}
              ]))
            end

            AgentHarness::CommandExecutor::Result.new(
              stdout: "response text",
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          end

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
  end

  describe "instance with Docker executor" do
    let(:docker_executor) do
      instance_double(AgentHarness::CommandExecutor)
    end

    let(:config) do
      AgentHarness::ProviderConfig.new(:aider).tap do |c|
        c.model = "gpt-4o"
      end
    end

    subject(:provider) { described_class.new(config: config, executor: docker_executor) }

    before do
      allow(provider).to receive(:sandboxed_environment?).and_return(true)
    end

    before do
      allow(docker_executor).to receive(:execute) do |command, **_opts|
        if command[0..1] == ["sh", "-lc"] && command.last.include?("cat")
          history_path = provider.instance_variable_get(:@aider_history_path)
          if history_path && command.last.include?(Shellwords.escape(history_path))
            AgentHarness::CommandExecutor::Result.new(
              stdout: JSON.generate([
                {"usage" => {"prompt_tokens" => 100, "completion_tokens" => 50}}
              ]),
              stderr: "",
              exit_code: 0,
              duration: 0.1
            )
          else
            AgentHarness::CommandExecutor::Result.new(
              stdout: "",
              stderr: "",
              exit_code: 1,
              duration: 0.1
            )
          end
        elsif command[0..1] == ["sh", "-lc"] && command.last.include?("rm -f --")
          AgentHarness::CommandExecutor::Result.new(
            stdout: "",
            stderr: "",
            exit_code: 0,
            duration: 0.1
          )
        else
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response text",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        end
      end
    end

    describe "#send_message" do
      it "uses a container-local path for --llm-history-file" do
        aider_command = nil
        allow(docker_executor).to receive(:execute) do |command, **_opts|
          aider_command ||= command if command.is_a?(Array) && command.first == "aider"
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response text",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        end

        provider.send_message(prompt: "Hello")

        history_flag_idx = aider_command.index("--llm-history-file")
        expect(history_flag_idx).not_to be_nil
        history_path = aider_command[history_flag_idx + 1]
        expect(history_path).to match(%r{/tmp/aider_llm_history_[a-f0-9]+\.json})
      end

      it "extracts tokens by reading history from the container" do
        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 100, output: 50, total: 150})
      end

      it "cleans up the container history file after execution" do
        provider.send_message(prompt: "Hello")

        expect(docker_executor).to have_received(:execute).with(
          ["sh", "-lc", a_string_starting_with("rm -f -- /tmp/aider_llm_history_")],
          anything
        )
        expect(provider.instance_variable_get(:@aider_history_path)).to be_nil
      end

      it "cleans up the container history file even when execution fails" do
        main_execution = true
        allow(docker_executor).to receive(:execute) do |command, **_opts|
          if main_execution && !(command[0..1] == ["sh", "-lc"] && command.last.include?("cat")) &&
              !(command[0..1] == ["sh", "-lc"] && command.last.include?("rm -f --"))
            main_execution = false
            raise StandardError, "container error"
          end
          AgentHarness::CommandExecutor::Result.new(
            stdout: "",
            stderr: "",
            exit_code: 0,
            duration: 0.1
          )
        end

        expect {
          provider.send_message(prompt: "Hello")
        }.to raise_error(AgentHarness::ProviderError)

        expect(provider.instance_variable_get(:@aider_history_path)).to be_nil
      end

      it "fails before reserving a container history path when timeout is non-positive" do
        expect(provider).not_to receive(:prepare_llm_history_file!)
        expect(docker_executor).not_to receive(:execute)

        expect {
          provider.send_message(prompt: "Hello", timeout: 0)
        }.to raise_error(AgentHarness::TimeoutError, "Command timed out before execution started")

        expect(provider.instance_variable_get(:@aider_history_path)).to be_nil
      end

      it "times out before container execution if history-path setup exhausts the request budget" do
        allow(provider).to receive(:prepare_llm_history_file!).and_return("/tmp/aider_history")
        expect(docker_executor).to receive(:execute).with(
          ["sh", "-lc", "rm -f -- /tmp/aider_history"],
          timeout: 10
        ).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "",
            stderr: "",
            exit_code: 0,
            duration: 0.1
          )
        )

        times = [
          Time.utc(2026, 4, 13, 0, 0, 0),
          Time.utc(2026, 4, 13, 0, 0, 1)
        ]
        allow(Time).to receive(:now).and_return(*times)

        expect {
          provider.send_message(prompt: "Hello", timeout: 1)
        }.to raise_error(AgentHarness::TimeoutError, "Command timed out before execution started")
      end

      it "does not clear a newer container history path when cleaning up an older path" do
        older_path = provider.send(:prepare_llm_history_file!)
        newer_path = provider.send(:prepare_llm_history_file!)

        expect(provider.instance_variable_get(:@aider_history_path)).to eq(newer_path)

        provider.send(:cleanup_llm_history_file!, older_path)

        expect(provider.instance_variable_get(:@aider_history_path)).to eq(newer_path)

        provider.send(:cleanup_llm_history_file!, newer_path)

        expect(provider.instance_variable_get(:@aider_history_path)).to be_nil
      end
    end
  end
end
