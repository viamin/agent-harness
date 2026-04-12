# frozen_string_literal: true

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
        command = provider.send(:build_command, "hello", {})

        expect(command.first).to eq(contract[:binary_name])
        expect(command).to include(provider.execution_semantics[:non_interactive_flag])
      end

      it "includes --llm-history-file when llm_history_path is set" do
        provider.instance_variable_set(:@llm_history_path, "/tmp/test_history.jsonl")
        command = provider.send(:build_command, "hello", {})

        expect(command).to include("--llm-history-file", "/tmp/test_history.jsonl")
      ensure
        provider.instance_variable_set(:@llm_history_path, nil)
      end

      it "does not include --llm-history-file when llm_history_path is nil" do
        provider.instance_variable_set(:@llm_history_path, nil)
        command = provider.send(:build_command, "hello", {})

        expect(command).not_to include("--llm-history-file")
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

      it "extracts OpenAI-format tokens from the history file" do
        allow(mock_executor).to receive(:execute) do |cmd, **kwargs|
          history_path = cmd[cmd.index("--llm-history-file") + 1]
          File.write(history_path, <<~JSONL)
            {"role":"user","content":"hello"}
            {"role":"assistant","content":"world","usage":{"prompt_tokens":10,"completion_tokens":20,"total_tokens":30}}
          JSONL
          result
        end

        response = provider.send_message(prompt: "hello")
        expect(response.tokens).to eq({input: 10, output: 20, total: 30})
      end

      it "extracts Anthropic-format tokens from the history file" do
        allow(mock_executor).to receive(:execute) do |cmd, **kwargs|
          history_path = cmd[cmd.index("--llm-history-file") + 1]
          File.write(history_path, <<~JSONL)
            {"role":"user","content":"hello"}
            {"role":"assistant","content":"world","usage":{"input_tokens":15,"output_tokens":25}}
          JSONL
          result
        end

        response = provider.send_message(prompt: "hello")
        expect(response.tokens).to eq({input: 15, output: 25, total: 40})
      end

      it "aggregates tokens across multiple responses" do
        allow(mock_executor).to receive(:execute) do |cmd, **kwargs|
          history_path = cmd[cmd.index("--llm-history-file") + 1]
          File.write(history_path, <<~JSONL)
            {"role":"assistant","usage":{"prompt_tokens":10,"completion_tokens":5}}
            {"role":"assistant","usage":{"prompt_tokens":20,"completion_tokens":10}}
          JSONL
          result
        end

        response = provider.send_message(prompt: "hello")
        expect(response.tokens).to eq({input: 30, output: 15, total: 45})
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
          File.write(history_path, <<~JSONL)
            {"role":"user","content":"hello"}
            {"role":"assistant","content":"world"}
          JSONL
          result
        end

        response = provider.send_message(prompt: "hello")
        expect(response.tokens).to be_nil
      end

      it "returns nil tokens when history file does not exist" do
        response = provider.send_message(prompt: "hello")
        expect(response.tokens).to be_nil
      end

      it "handles malformed JSON lines gracefully" do
        allow(mock_executor).to receive(:execute) do |cmd, **kwargs|
          history_path = cmd[cmd.index("--llm-history-file") + 1]
          File.write(history_path, <<~JSONL)
            not-json
            {"role":"assistant","usage":{"prompt_tokens":10,"completion_tokens":20}}
            {broken
          JSONL
          result
        end

        response = provider.send_message(prompt: "hello")
        expect(response.tokens).to eq({input: 10, output: 20, total: 30})
      end

      it "extracts usage from nested response objects" do
        allow(mock_executor).to receive(:execute) do |cmd, **kwargs|
          history_path = cmd[cmd.index("--llm-history-file") + 1]
          File.write(history_path, <<~JSONL)
            {"response":{"usage":{"input_tokens":5,"output_tokens":8}}}
          JSONL
          result
        end

        response = provider.send_message(prompt: "hello")
        expect(response.tokens).to eq({input: 5, output: 8, total: 13})
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
          path = File.join(dir, "history.jsonl")
          File.write(path, '{"usage":{"prompt_tokens":100,"completion_tokens":50}}')
          provider.instance_variable_set(:@llm_history_path, path)

          response = provider.send(:parse_response, result, duration: 1.0)
          expect(response.output).to eq("response text")
          expect(response.exit_code).to eq(0)
          expect(response.tokens).to eq({input: 100, output: 50, total: 150})
        end
      ensure
        provider.instance_variable_set(:@llm_history_path, nil)
      end

      it "returns the base response unchanged when no tokens are found" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "history.jsonl")
          File.write(path, '{"role":"user","content":"hello"}')
          provider.instance_variable_set(:@llm_history_path, path)

          response = provider.send(:parse_response, result, duration: 1.0)
          expect(response.output).to eq("response text")
          expect(response.tokens).to be_nil
        end
      ensure
        provider.instance_variable_set(:@llm_history_path, nil)
      end
    end
  end
end
