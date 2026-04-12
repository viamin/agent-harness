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
        allow(provider).to receive(:instance_variable_get).with(:@aider_history_tempfile).and_return(nil)
        command = provider.send(:build_command, "hello", {})

        expect(command.first).to eq(contract[:binary_name])
        expect(command).to include(provider.execution_semantics[:non_interactive_flag])
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
        if command.include?("cat")
          history_path = provider.instance_variable_get(:@aider_history_path)
          if history_path && command.last == history_path
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
        elsif command.include?("rm")
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
          array_including("rm", "-f"),
          anything
        )
        expect(provider.instance_variable_get(:@aider_history_path)).to be_nil
      end

      it "cleans up the container history file even when execution fails" do
        main_execution = true
        allow(docker_executor).to receive(:execute) do |command, **_opts|
          if main_execution && !command.include?("cat") && !command.include?("rm")
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
    end
  end
end
