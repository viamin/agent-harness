# frozen_string_literal: true

RSpec.describe AgentHarness::Providers::Anthropic do
  describe ".provider_name" do
    it "returns :claude" do
      expect(described_class.provider_name).to eq(:claude)
    end
  end

  describe ".binary_name" do
    it "returns claude" do
      expect(described_class.binary_name).to eq("claude")
    end
  end

  describe ".install_contract" do
    it "exposes the official install contract" do
      contract = described_class.install_contract
      local_binary_path = "~/.local/bin/claude"

      expect(contract[:provider]).to eq(:claude)
      expect(contract[:binary_name]).to eq("claude")
      expect(contract[:binary_paths]).to include("/usr/local/bin/claude", local_binary_path, "claude")
      expect(contract.dig(:install, :strategy)).to eq(:shell)
      expect(contract.dig(:install, :command)).to eq("curl -fsSL https://claude.ai/install.sh | bash")
      expect(contract.dig(:install, :post_install_binary_path)).to eq(local_binary_path)
      expect(contract.dig(:supported_versions, :default)).to eq("latest")
      expect(contract.dig(:supported_versions, :requirement)).to eq("latest")
      expect(contract.dig(:supported_versions, :channel)).to eq("latest")
      expect(contract.dig(:runtime_contract, :available_via)).to eq(described_class.binary_name)
      expect(contract.dig(:runtime_contract, :build_command)).to eq(["claude", "--print", "--output-format=json"])
      expect(contract.dig(:runtime_contract, :required_features)).to include(
        "print_mode",
        "json_output",
        "mcp_config",
        "mcp_list",
        "dangerously_skip_permissions",
        "models_list"
      )
    end

    it "keeps runtime assumptions aligned with the provider command contract" do
      contract = described_class.install_contract
      config = AgentHarness::ProviderConfig.new(:claude)
      provider = described_class.new(config: config, executor: instance_double(AgentHarness::CommandExecutor))
      command = provider.send(:build_command, "prompt", {})
      contract_build_command = contract.dig(:runtime_contract, :build_command)

      expect(command.first(contract_build_command.length)).to eq(contract_build_command)
      expect(command[contract_build_command.length]).to eq("prompt")
    end
  end

  describe ".firewall_requirements" do
    it "returns required domains" do
      requirements = described_class.firewall_requirements

      expect(requirements[:domains]).to include("api.anthropic.com")
      expect(requirements[:domains]).to include("claude.ai")
      expect(requirements[:ip_ranges]).to eq([])
    end
  end

  describe ".instruction_file_paths" do
    it "returns CLAUDE.md" do
      paths = described_class.instruction_file_paths

      expect(paths.first[:path]).to eq("CLAUDE.md")
      expect(paths.first[:symlink]).to be true
    end
  end

  describe ".model_family" do
    it "strips date suffix" do
      expect(described_class.model_family("claude-3-5-sonnet-20241022")).to eq("claude-3-5-sonnet")
    end

    it "returns unchanged if no date suffix" do
      expect(described_class.model_family("claude-3-5-sonnet")).to eq("claude-3-5-sonnet")
    end
  end

  describe ".provider_model_name" do
    it "returns the family name unchanged" do
      expect(described_class.provider_model_name("claude-3-opus")).to eq("claude-3-opus")
    end
  end

  describe ".supports_model_family?" do
    it "returns true for Claude models" do
      expect(described_class.supports_model_family?("claude-3-5-sonnet")).to be true
      expect(described_class.supports_model_family?("claude-3-opus")).to be true
      expect(described_class.supports_model_family?("claude-3-haiku")).to be true
    end

    it "returns true for versioned models" do
      expect(described_class.supports_model_family?("claude-3-5-sonnet-20241022")).to be true
    end

    it "returns false for non-Claude models" do
      expect(described_class.supports_model_family?("gpt-4")).to be false
      expect(described_class.supports_model_family?("gemini-pro")).to be false
    end
  end

  describe ".available?" do
    let(:mock_executor) do
      instance_double(AgentHarness::CommandExecutor)
    end

    before do
      allow(AgentHarness.configuration).to receive(:command_executor).and_return(mock_executor)
    end

    it "returns true when claude binary exists" do
      allow(mock_executor).to receive(:which).with("claude").and_return("/usr/local/bin/claude")
      expect(described_class.available?).to be true
    end

    it "returns false when claude binary is missing" do
      allow(mock_executor).to receive(:which).with("claude").and_return(nil)
      expect(described_class.available?).to be false
    end
  end

  describe ".discover_models" do
    let(:mock_executor) do
      instance_double(AgentHarness::CommandExecutor)
    end

    before do
      allow(AgentHarness.configuration).to receive(:command_executor).and_return(mock_executor)
    end

    context "when claude is not available" do
      before do
        allow(mock_executor).to receive(:which).with("claude").and_return(nil)
      end

      it "returns empty array" do
        expect(described_class.discover_models).to eq([])
      end
    end

    context "when claude is available" do
      before do
        allow(mock_executor).to receive(:which).with("claude").and_return("/usr/local/bin/claude")
      end

      it "parses simple model list format" do
        allow(Open3).to receive(:capture3).and_return([
          "claude-3-5-sonnet-20241022\nclaude-3-opus-20240229\nclaude-3-haiku-20240307",
          "",
          double(success?: true)
        ])

        models = described_class.discover_models
        expect(models.size).to eq(3)
        expect(models.first[:name]).to eq("claude-3-5-sonnet-20241022")
        expect(models.first[:family]).to eq("claude-3-5-sonnet")
        expect(models.first[:tier]).to eq("standard")
      end

      it "parses table format with model names" do
        allow(Open3).to receive(:capture3).and_return([
          "Model Name          Version\nclaude-3-opus-20240229       latest",
          "",
          double(success?: true)
        ])

        models = described_class.discover_models
        expect(models.size).to eq(1)
        expect(models.first[:name]).to eq("claude-3-opus-20240229")
        expect(models.first[:tier]).to eq("advanced")
      end

      it "handles command failure" do
        allow(Open3).to receive(:capture3).and_return([
          "",
          "error",
          double(success?: false)
        ])

        expect(described_class.discover_models).to eq([])
      end

      it "handles exceptions" do
        allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)
        expect(described_class.discover_models).to eq([])
      end

      it "extracts capabilities correctly" do
        allow(Open3).to receive(:capture3).and_return([
          "claude-3-haiku-20240307",
          "",
          double(success?: true)
        ])

        models = described_class.discover_models
        expect(models.first[:capabilities]).to include("chat", "code")
        expect(models.first[:capabilities]).not_to include("vision")
        expect(models.first[:tier]).to eq("mini")
      end

      it "infers context window for claude-3 models" do
        allow(Open3).to receive(:capture3).and_return([
          "claude-3-opus-20240229",
          "",
          double(success?: true)
        ])

        models = described_class.discover_models
        expect(models.first[:context_window]).to eq(200_000)
      end
    end
  end

  describe "instance" do
    let(:config) do
      AgentHarness::ProviderConfig.new(:claude).tap do |c|
        c.model = "claude-3-5-sonnet"
        c.default_flags = ["--verbose"]
      end
    end

    let(:mock_executor) do
      instance_double(AgentHarness::CommandExecutor)
    end

    subject(:provider) { described_class.new(config: config, executor: mock_executor) }

    describe "#name" do
      it "returns anthropic" do
        expect(provider.name).to eq("anthropic")
      end
    end

    describe "#display_name" do
      it "returns Anthropic Claude CLI" do
        expect(provider.display_name).to eq("Anthropic Claude CLI")
      end
    end

    describe "#configuration_schema" do
      it "includes a model field" do
        schema = provider.configuration_schema
        model_field = schema[:fields].find { |f| f[:name] == :model }
        expect(model_field).not_to be_nil
        expect(model_field[:accepts_arbitrary]).to be false
      end

      it "uses oauth auth mode" do
        expect(provider.configuration_schema[:auth_modes]).to eq([:oauth])
      end

      it "is not openai compatible" do
        expect(provider.configuration_schema[:openai_compatible]).to be false
      end
    end

    describe "#capabilities" do
      it "includes expected capabilities" do
        caps = provider.capabilities

        expect(caps[:mcp]).to be true
        expect(caps[:dangerous_mode]).to be true
        expect(caps[:tool_use]).to be true
        expect(caps[:streaming]).to be true
        expect(caps[:file_upload]).to be true
        expect(caps[:vision]).to be true
        expect(caps[:json_mode]).to be true
      end
    end

    describe "#supports_mcp?" do
      it "returns true" do
        expect(provider.supports_mcp?).to be true
      end
    end

    describe "#supports_dangerous_mode?" do
      it "returns true" do
        expect(provider.supports_dangerous_mode?).to be true
      end
    end

    describe "#dangerous_mode_flags" do
      it "returns the skip permissions flag" do
        expect(provider.dangerous_mode_flags).to include("--dangerously-skip-permissions")
      end
    end

    describe "#auth_type" do
      it "returns :oauth" do
        expect(provider.auth_type).to eq(:oauth)
      end
    end

    describe "#error_patterns" do
      it "includes rate limit patterns" do
        patterns = provider.error_patterns
        expect(patterns[:rate_limited]).not_to be_empty
        expect(patterns[:rate_limited].any? { |p| p.match?("rate limit") }).to be true
      end

      it "includes auth patterns" do
        patterns = provider.error_patterns
        expect(patterns[:auth_expired]).not_to be_empty
      end

      it "matches session expired errors" do
        patterns = provider.error_patterns[:auth_expired]
        expect(patterns.any? { |p| p.match?("session expired") }).to be true
      end

      it "matches not logged in errors" do
        patterns = provider.error_patterns[:auth_expired]
        expect(patterns.any? { |p| p.match?("not logged in") }).to be true
      end

      it "matches login required errors" do
        patterns = provider.error_patterns[:auth_expired]
        expect(patterns.any? { |p| p.match?("login required") }).to be true
      end

      it "includes quota patterns" do
        patterns = provider.error_patterns
        expect(patterns[:quota_exceeded]).not_to be_empty
      end

      it "includes transient patterns" do
        patterns = provider.error_patterns
        expect(patterns[:transient]).not_to be_empty
      end

      it "includes permanent patterns" do
        patterns = provider.error_patterns
        expect(patterns[:permanent]).not_to be_empty
      end
    end

    describe "#fetch_mcp_servers" do
      before do
        allow(AgentHarness.configuration).to receive(:command_executor).and_return(mock_executor)
        allow(mock_executor).to receive(:which).with("claude").and_return("/usr/local/bin/claude")
      end

      context "when command succeeds with connected servers" do
        before do
          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: "Checking MCP server health...\nfilesystem: npx @modelcontextprotocol/server-filesystem - ✓ Connected\nmemory: npx @modelcontextprotocol/server-memory - ✗ Connection failed",
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )
        end

        it "parses servers correctly" do
          servers = provider.fetch_mcp_servers
          expect(servers.size).to eq(2)

          fs_server = servers.find { |s| s[:name] == "filesystem" }
          expect(fs_server[:status]).to eq("connected")
          expect(fs_server[:enabled]).to be true

          mem_server = servers.find { |s| s[:name] == "memory" }
          expect(mem_server[:status]).to eq("error")
          expect(mem_server[:enabled]).to be false
          expect(mem_server[:error]).to eq("Connection failed")
        end
      end

      context "when command fails" do
        before do
          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: "",
              stderr: "error",
              exit_code: 1,
              duration: 1.0
            )
          )
        end

        it "returns empty array" do
          expect(provider.fetch_mcp_servers).to eq([])
        end
      end

      context "when claude is not available" do
        before do
          allow(mock_executor).to receive(:which).with("claude").and_return(nil)
        end

        it "returns empty array" do
          expect(provider.fetch_mcp_servers).to eq([])
        end
      end
    end

    describe "#send_message" do
      context "with build_command" do
        it "includes print and output format flags" do
          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: '{"result":"response","usage":{"input_tokens":10,"output_tokens":5}}',
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          expect(mock_executor).to receive(:execute).with(
            array_including("--print", "--output-format=json"),
            anything
          )

          provider.send_message(prompt: "Hello")
        end

        it "includes model when configured" do
          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: '{"result":"response","usage":{"input_tokens":10,"output_tokens":5}}',
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          expect(mock_executor).to receive(:execute).with(
            array_including("--model", "claude-3-5-sonnet"),
            anything
          )

          provider.send_message(prompt: "Hello")
        end

        it "includes dangerous mode flags when requested" do
          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: '{"result":"response","usage":{"input_tokens":10,"output_tokens":5}}',
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          expect(mock_executor).to receive(:execute).with(
            array_including("--dangerously-skip-permissions"),
            anything
          )

          provider.send_message(prompt: "Hello", dangerous_mode: true)
        end

        it "includes default flags from config" do
          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: '{"result":"response","usage":{"input_tokens":10,"output_tokens":5}}',
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          expect(mock_executor).to receive(:execute).with(
            array_including("--verbose"),
            anything
          )

          provider.send_message(prompt: "Hello")
        end

        it "includes prompt at the end" do
          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: '{"result":"response","usage":{"input_tokens":10,"output_tokens":5}}',
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          expect(mock_executor).to receive(:execute).with(
            end_with("Hello world"),
            anything
          )

          provider.send_message(prompt: "Hello world")
        end
      end

      context "with parse_response" do
        it "classifies rate limit errors" do
          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: "Rate limit exceeded",
              stderr: "",
              exit_code: 1,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.error).to eq("Rate limit exceeded")
        end

        it "classifies session limit errors" do
          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: "Session limit reached",
              stderr: "",
              exit_code: 1,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.error).to eq("Rate limit exceeded")
        end

        it "classifies deprecation errors" do
          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: "Model has been deprecated",
              stderr: "",
              exit_code: 1,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.error).to eq("Model deprecated")
        end

        it "classifies authentication errors" do
          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: "OAuth token expired",
              stderr: "",
              exit_code: 1,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.error).to eq("Authentication error")
        end

        it "returns original message for unknown errors" do
          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: "Some other error occurred",
              stderr: "",
              exit_code: 1,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.error).to include("Some other error occurred")
        end
      end

      context "with auth error raising" do
        it "raises AuthenticationError with provider when executor raises auth error" do
          allow(mock_executor).to receive(:execute).and_raise(
            StandardError.new("oauth token expired")
          )

          expect { provider.send_message(prompt: "Hello") }.to raise_error(AgentHarness::AuthenticationError) do |error|
            expect(error.provider).to eq(:claude)
          end
        end
      end

      context "with token usage parsing" do
        it "extracts token usage from JSON output" do
          json_output = JSON.generate({
            "result" => "Hello! How can I help?",
            "usage" => {
              "input_tokens" => 100,
              "output_tokens" => 50
            }
          })

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: json_output,
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

        it "handles JSON output without usage data" do
          json_output = JSON.generate({
            "result" => "Hello!"
          })

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: json_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq("Hello!")
          expect(response.tokens).to be_nil
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

        it "handles JSON with cache token fields" do
          json_output = JSON.generate({
            "result" => "Cached response",
            "usage" => {
              "input_tokens" => 200,
              "output_tokens" => 75,
              "cache_creation_input_tokens" => 0,
              "cache_read_input_tokens" => 50
            }
          })

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: json_output,
              stderr: "",
              exit_code: 0,
              duration: 1.5
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.tokens).to eq({input: 200, output: 75, total: 275})
        end

        it "records tokens with the global token tracker" do
          json_output = JSON.generate({
            "result" => "Tracked response",
            "usage" => {
              "input_tokens" => 50,
              "output_tokens" => 25
            }
          })

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: json_output,
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

    describe "#execution_semantics" do
      it "returns the full provider contract" do
        semantics = provider.execution_semantics
        expect(semantics[:prompt_delivery]).to eq(:arg)
        expect(semantics[:output_format]).to eq(:json)
        expect(semantics[:sandbox_aware]).to be true
        expect(semantics[:uses_subcommand]).to be false
        expect(semantics[:non_interactive_flag]).to eq("--print")
        expect(semantics[:legitimate_exit_codes]).to eq([0])
        expect(semantics[:stderr_is_diagnostic]).to be true
        expect(semantics[:parses_rate_limit_reset]).to be false
      end
    end
  end
end
