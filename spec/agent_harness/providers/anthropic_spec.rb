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

  describe ".parse_cli_json_envelope" do
    it "extracts output, tokens, and metadata from a success envelope" do
      envelope = JSON.generate({
        "type" => "result",
        "subtype" => "success",
        "is_error" => false,
        "duration_ms" => 3588,
        "duration_api_ms" => 388_349,
        "num_turns" => 1,
        "result" => "Hello! How can I help?",
        "stop_reason" => "end_turn",
        "session_id" => "sess-abc-123",
        "total_cost_usd" => 2.28,
        "terminal_reason" => "completed",
        "usage" => {"input_tokens" => 100, "output_tokens" => 50}
      })

      parsed = described_class.parse_cli_json_envelope(envelope)

      expect(parsed[:output]).to eq("Hello! How can I help?")
      expect(parsed[:error]).to be_nil
      expect(parsed[:tokens]).to eq({input: 100, output: 50, total: 150})
      expect(parsed[:metadata][:cost_usd]).to eq(2.28)
      expect(parsed[:metadata][:session_id]).to eq("sess-abc-123")
      expect(parsed[:metadata][:stop_reason]).to eq("end_turn")
      expect(parsed[:metadata][:terminal_reason]).to eq("completed")
      expect(parsed[:metadata][:num_turns]).to eq(1)
      expect(parsed[:metadata][:duration_ms]).to eq(3588)
      expect(parsed[:metadata][:duration_api_ms]).to eq(388_349)
    end

    it "surfaces is_error envelopes as errors" do
      envelope = JSON.generate({
        "type" => "result",
        "is_error" => true,
        "result" => "Rate limit exceeded for this model"
      })

      parsed = described_class.parse_cli_json_envelope(envelope)

      expect(parsed[:output]).to eq("Rate limit exceeded for this model")
      expect(parsed[:error]).to eq("Rate limit exceeded")
    end

    it "returns nil for non-JSON input" do
      expect(described_class.parse_cli_json_envelope("not json")).to be_nil
    end

    it "returns nil for nil input" do
      expect(described_class.parse_cli_json_envelope(nil)).to be_nil
    end

    it "returns nil for empty input" do
      expect(described_class.parse_cli_json_envelope("")).to be_nil
    end

    it "returns nil for JSON without a result field" do
      expect(described_class.parse_cli_json_envelope('{"foo":"bar"}')).to be_nil
    end

    it "strips streaming session events before parsing" do
      envelope = [
        '{"type":"session.mcp_servers_loading","server":"playwright"}',
        '{"type":"session.mcp_servers_loaded"}',
        JSON.generate({
          "type" => "result",
          "result" => "analysis result",
          "usage" => {"input_tokens" => 10, "output_tokens" => 5}
        })
      ].join("\n")

      parsed = described_class.parse_cli_json_envelope(envelope)

      expect(parsed[:output]).to eq("analysis result")
      expect(parsed[:tokens]).to eq({input: 10, output: 5, total: 15})
    end

    it "strips truncated streaming session events before parsing" do
      envelope = [
        '{"type":"session.mcp_servers_loa',
        JSON.generate({
          "type" => "result",
          "result" => "analysis result",
          "usage" => {"input_tokens" => 10, "output_tokens" => 5}
        })
      ].join("\n")

      parsed = described_class.parse_cli_json_envelope(envelope)

      expect(parsed[:output]).to eq("analysis result")
    end

    it "returns nil when only streaming events are present" do
      output = '{"type":"session.mcp_servers_loading"}'

      expect(described_class.parse_cli_json_envelope(output)).to be_nil
    end
  end

  describe ".install_contract" do
    it "exposes the official install contract" do
      contract = described_class.install_contract

      expect(contract[:provider]).to eq(:claude)
      expect(contract[:binary_name]).to eq("claude")
      expect(contract[:binary_paths]).to eq(["$HOME/.local/bin/claude", "claude"])
      expect(contract.dig(:install, :strategy)).to eq(:shell)
      expect(contract.dig(:install, :command)).to eq(
        "tmp_script=$(mktemp) && trap 'rm -f \"$tmp_script\"' EXIT && curl -fsSL https://claude.ai/install.sh -o \"$tmp_script\" && bash \"$tmp_script\" 2.1.238"
      )
      expect(contract.dig(:install, :warning)).to eq(
        "Review the downloaded installer before execution and verify any published checksum or signature metadata when available."
      )
      expect(contract.dig(:install, :post_install_binary_path)).to eq("$HOME/.local/bin/claude")
      expect(contract.dig(:supported_versions, :default)).to eq("2.1.238")
      expect(contract.dig(:supported_versions, :requirement)).to eq(">= 2.1.238, < 2.2.0")
      expect(contract.dig(:supported_versions, :channel)).to eq("stable")
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

      expect(contract.dig(:install, :post_install_binary_path)).to eq(contract[:binary_paths].first)
      expect(command.first(contract_build_command.length)).to eq(contract_build_command)
      expect(command).to include(a_string_starting_with("--mcp-config="))
      expect(command.last).to eq("prompt")
    end

    it "does not include a root-only copy step in the install command" do
      contract = described_class.install_contract

      expect(contract.dig(:install, :command)).not_to include("/usr/local/bin")
      expect(contract.dig(:install, :command)).not_to include("cp -L")
    end

    it "pins the installer target to the documented supported version" do
      contract = described_class.install_contract

      expect(contract.dig(:install, :command)).to include("bash \"$tmp_script\" #{contract.dig(:supported_versions, :default)}")
    end

    it "accepts an optional version override" do
      contract = described_class.install_contract(version: "2.1.239")

      expect(contract.dig(:install, :command)).to include("bash \"$tmp_script\" 2.1.239")
    end

    it "accepts semver with pre-release suffix" do
      contract = described_class.install_contract(version: "2.2.0-beta.1")

      expect(contract.dig(:install, :command)).to include("bash \"$tmp_script\" 2.2.0-beta.1")
    end

    it "accepts channel tokens like 'latest' and 'stable'" do
      %w[latest stable].each do |channel|
        contract = described_class.install_contract(version: channel)

        expect(contract.dig(:install, :command)).to include("bash \"$tmp_script\" #{channel}")
      end
    end

    it "warns that channel tokens are not pinned and may fall outside the supported range" do
      %w[latest stable].each do |channel|
        contract = described_class.install_contract(version: channel)

        expect(contract.dig(:install, :warning)).to include("Channel '#{channel}' is not pinned")
        expect(contract.dig(:install, :warning)).to include("outside the supported range")
        expect(contract.dig(:install, :version_not_pinned)).to be true
      end
    end

    it "does not include a channel warning for pinned versions" do
      contract = described_class.install_contract

      expect(contract.dig(:install, :warning)).not_to include("not pinned")
      expect(contract.dig(:install, :version_not_pinned)).to be false
    end

    it "rejects versions outside the supported range" do
      expect { described_class.install_contract(version: "9.0.0") }
        .to raise_error(ArgumentError, /outside the supported range/)

      expect { described_class.install_contract(version: "1.0.0") }
        .to raise_error(ArgumentError, /outside the supported range/)
    end

    it "rejects versions containing shell metacharacters" do
      expect { described_class.install_contract(version: "2.1.92; rm -rf /") }
        .to raise_error(ArgumentError, /Invalid version/)
    end

    it "rejects arbitrary strings that are not semver or channel tokens" do
      expect { described_class.install_contract(version: "$(whoami)") }
        .to raise_error(ArgumentError, /Invalid version/)
    end

    it "rejects empty version" do
      expect { described_class.install_contract(version: "") }
        .to raise_error(ArgumentError, /Invalid version/)
    end

    it "rejects whitespace-only version" do
      expect { described_class.install_contract(version: "   ") }
        .to raise_error(ArgumentError, /Invalid version/)
    end

    it "rejects non-String version types with ArgumentError instead of NoMethodError" do
      expect { described_class.install_contract(version: :latest) }
        .to raise_error(ArgumentError, /Invalid version/)

      expect { described_class.install_contract(version: 123) }
        .to raise_error(ArgumentError, /Invalid version/)
    end

    it "normalizes padded version strings in the install command" do
      contract = described_class.install_contract(version: " 2.1.239 ")

      expect(contract.dig(:install, :command)).to include("bash \"$tmp_script\" 2.1.239")
      expect(contract.dig(:install, :command)).not_to include(" 2.1.239 ")
    end

    it "normalizes padded channel tokens and emits the channel warning" do
      contract = described_class.install_contract(version: " latest ")

      expect(contract.dig(:install, :command)).to include("bash \"$tmp_script\" latest")
      expect(contract.dig(:install, :warning)).to include("Channel 'latest' is not pinned")
      expect(contract.dig(:install, :version_not_pinned)).to be true
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

    describe "#supports_token_counting?" do
      it "returns true" do
        expect(provider.supports_token_counting?).to be true
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

    describe "#update_quota_from_headers" do
      it "returns nil when no rate-limit headers are present" do
        expect(provider.update_quota_from_headers({})).to be_nil
      end

      it "parses Anthropic ratelimit headers into a QuotaStatus" do
        headers = {
          "anthropic-ratelimit-tokens-limit" => "100000",
          "anthropic-ratelimit-tokens-remaining" => "75000",
          "anthropic-ratelimit-tokens-reset" => "2026-07-21T05:00:00Z"
        }

        status = provider.update_quota_from_headers(headers)

        expect(status).to be_a(AgentHarness::QuotaStatus)
        expect(status.available?).to be true
        expect(status.limit).to eq(100_000)
        expect(status.remaining).to eq(75_000)
        expect(status.unit).to eq(:tokens)
        expect(status.reset_at).to eq(Time.utc(2026, 7, 21, 5, 0, 0))
      end

      it "tolerates a missing reset header" do
        headers = {
          "anthropic-ratelimit-tokens-limit" => "100000",
          "anthropic-ratelimit-tokens-remaining" => "75000"
        }

        status = provider.update_quota_from_headers(headers)
        expect(status.reset_at).to be_nil
      end

      it "tolerates a reset header that is not a valid RFC 3339 timestamp" do
        headers = {
          "anthropic-ratelimit-tokens-limit" => "100000",
          "anthropic-ratelimit-tokens-remaining" => "75000",
          "anthropic-ratelimit-tokens-reset" => "not-a-timestamp"
        }

        status = provider.update_quota_from_headers(headers)
        expect(status.reset_at).to be_nil
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

      it "does not misclassify embedded numeric substrings as HTTP status codes" do
        patterns = provider.error_patterns
        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new("request id 4294967295 failed"),
            patterns
          )
        ).to eq(:unknown)

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new("trace code 40123 emitted"),
            patterns
          )
        ).to eq(:unknown)

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new("build 50321 aborted"),
            patterns
          )
        ).to eq(:unknown)

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new("job 1502 failed"),
            patterns
          )
        ).to eq(:unknown)

        expect(
          AgentHarness::ErrorTaxonomy.classify(
            StandardError.new("task 50401 completed"),
            patterns
          )
        ).to eq(:unknown)
      end
    end

    describe "#error_classification_patterns" do
      it "includes abort patterns for free tier" do
        patterns = provider.error_classification_patterns
        expect(patterns[:abort]).not_to be_empty
        expect(patterns[:abort].any? { |p| "free tier limit reached" =~ p }).to be true
        expect(patterns[:abort].any? { |p| "please upgrade to a paid plan" =~ p }).to be true
      end

      it "inherits shared quota patterns from base" do
        patterns = provider.error_classification_patterns
        expect(patterns[:quota]).not_to be_empty
      end

      it "has empty auth_expired and authentication arrays" do
        patterns = provider.error_classification_patterns
        expect(patterns[:auth_expired]).to eq([])
        expect(patterns[:authentication]).to eq([])
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

        it "includes model from provider_runtime when config.model is nil" do
          config_no_model = AgentHarness::ProviderConfig.new(:claude).tap do |c|
            c.model = nil
            c.default_flags = ["--verbose"]
          end
          provider_no_model = described_class.new(config: config_no_model, executor: mock_executor)
          runtime = AgentHarness::ProviderRuntime.new(model: "claude-opus-4-6")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: '{"result":"response","usage":{"input_tokens":10,"output_tokens":5}}',
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          expect(mock_executor).to receive(:execute).with(
            array_including("--model", "claude-opus-4-6"),
            anything
          )

          provider_no_model.send_message(prompt: "Hello", provider_runtime: runtime)
        end

        it "prefers config.model over provider_runtime.model" do
          runtime = AgentHarness::ProviderRuntime.new(model: "claude-opus-4-6")

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

          provider.send_message(prompt: "Hello", provider_runtime: runtime)
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

        it "raises AuthenticationError for auth-related error output" do
          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: "OAuth token expired",
              stderr: "",
              exit_code: 1,
              duration: 1.0
            )
          )

          expect {
            provider.send_message(prompt: "Hello")
          }.to raise_error(AgentHarness::AuthenticationError) do |error|
            expect(error.provider).to eq(:claude)
            expect(error.message).to include("OAuth token expired")
          end
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

        it "strips streaming session events and parses the envelope" do
          stdout = [
            '{"type":"session.mcp_servers_loading","server":"playwright"}',
            '{"type":"session.mcp_servers_loaded"}',
            JSON.generate({
              "result" => "analysis result",
              "usage" => {"input_tokens" => 10, "output_tokens" => 5}
            })
          ].join("\n")

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: stdout,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq("analysis result")
          expect(response.tokens).to eq({input: 10, output: 5, total: 15})
        end

        it "handles truncated streaming events mixed with the envelope" do
          stdout = '{"type":"session.mcp_servers_loa' + "\n" + JSON.generate({
            "result" => "analysis result",
            "usage" => {"input_tokens" => 10, "output_tokens" => 5}
          })

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: stdout,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq("analysis result")
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

      context "with is_error envelope" do
        it "surfaces is_error as a provider error" do
          json_output = JSON.generate({
            "type" => "result",
            "subtype" => "error",
            "is_error" => true,
            "result" => "Rate limit exceeded for this model",
            "usage" => {"input_tokens" => 10, "output_tokens" => 0}
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
          expect(response.error).to eq("Rate limit exceeded")
          expect(response.output).to eq("Rate limit exceeded for this model")
        end

        it "raises AuthenticationError for auth-related is_error envelopes" do
          json_output = JSON.generate({
            "type" => "result",
            "is_error" => true,
            "result" => "Authentication failed: oauth token expired"
          })

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: json_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          expect {
            provider.send_message(prompt: "Hello")
          }.to raise_error(AgentHarness::AuthenticationError) do |error|
            expect(error.provider).to eq(:claude)
            expect(error.message).to include("Authentication failed")
          end
        end

        it "raises AuthenticationError for the native not-logged-in envelope" do
          # Observed envelope from Claude CLI: subtype claims "success" while
          # is_error signals failure and the process exits nonzero.
          json_output = JSON.generate({
            "type" => "result",
            "subtype" => "success",
            "is_error" => true,
            "result" => "Not logged in · Please run /login",
            "exit_code" => 1
          })

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: json_output,
              stderr: "",
              exit_code: 1,
              duration: 1.0
            )
          )

          expect {
            provider.send_message(prompt: "Hello")
          }.to raise_error(AgentHarness::AuthenticationError) do |error|
            expect(error.provider).to eq(:claude)
            expect(error.message).to include("Not logged in")
          end
        end

        it "raises AuthenticationError even when subtype is success and is_error is true" do
          # Guard against trusting subtype: "success" over is_error: true.
          json_output = JSON.generate({
            "type" => "result",
            "subtype" => "success",
            "is_error" => true,
            "result" => "Please run /login to authenticate"
          })

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: json_output,
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          expect {
            provider.send_message(prompt: "Hello")
          }.to raise_error(AgentHarness::AuthenticationError)
        end

        it "uses generic error for unclassified is_error envelopes" do
          json_output = JSON.generate({
            "type" => "result",
            "is_error" => true,
            "result" => "Something unexpected happened"
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
          expect(response.error).to eq("Something unexpected happened")
        end
      end

      context "with envelope metadata extraction" do
        it "extracts structured metadata from the JSON envelope" do
          json_output = JSON.generate({
            "type" => "result",
            "subtype" => "success",
            "is_error" => false,
            "duration_ms" => 3588,
            "duration_api_ms" => 388_349,
            "num_turns" => 1,
            "result" => "Hello! How can I help?",
            "stop_reason" => "end_turn",
            "session_id" => "abc-123",
            "total_cost_usd" => 2.28,
            "terminal_reason" => "completed",
            "usage" => {"input_tokens" => 100, "output_tokens" => 50}
          })

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: json_output,
              stderr: "",
              exit_code: 0,
              duration: 3.5
            )
          )

          response = provider.send_message(prompt: "Hello")
          expect(response.output).to eq("Hello! How can I help?")
          expect(response.metadata[:cost_usd]).to eq(2.28)
          expect(response.metadata[:session_id]).to eq("abc-123")
          expect(response.metadata[:stop_reason]).to eq("end_turn")
          expect(response.metadata[:terminal_reason]).to eq("completed")
          expect(response.metadata[:num_turns]).to eq(1)
          expect(response.metadata[:duration_ms]).to eq(3588)
          expect(response.metadata[:duration_api_ms]).to eq(388_349)
        end

        it "handles envelopes with partial metadata" do
          json_output = JSON.generate({
            "result" => "Hello!",
            "session_id" => "xyz-456"
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
          expect(response.metadata[:session_id]).to eq("xyz-456")
          expect(response.metadata[:cost_usd]).to be_nil
        end
      end
    end

    describe "#supports_tool_control?" do
      it "returns true" do
        expect(provider.supports_tool_control?).to be true
      end
    end

    describe "tool control via tools option" do
      let(:success_result) do
        AgentHarness::CommandExecutor::Result.new(
          stdout: '{"result":"response","usage":{"input_tokens":10,"output_tokens":5}}',
          stderr: "",
          exit_code: 0,
          duration: 1.0
        )
      end

      before do
        allow(mock_executor).to receive(:execute).and_return(success_result)
      end

      context "when tools: :none" do
        it "includes --permission-mode plan flag" do
          expect(mock_executor).to receive(:execute).with(
            array_including("--permission-mode", "plan"),
            anything
          )

          provider.send_message(prompt: "Summarize this", tools: :none)
        end

        it "includes --disallowedTools for all CLI tools" do
          allow(mock_executor).to receive(:execute) do |cmd, **_opts|
            disallowed_flag = cmd.find { |arg| arg.start_with?("--disallowedTools=") }
            expect(disallowed_flag).not_to be_nil, "Expected command to include --disallowedTools= flag"
            tool_list = disallowed_flag.sub("--disallowedTools=", "").split(",")
            AgentHarness::Providers::Anthropic::ALL_CLI_TOOLS.each do |tool|
              expect(tool_list).to include(tool),
                "Expected --disallowedTools to include #{tool}"
            end
            success_result
          end

          provider.send_message(prompt: "Summarize this", tools: :none)
        end

        it "disallows all known CLI tools" do
          expected_tools = %w[Agent Bash Read Edit Write Grep Glob WebFetch WebSearch TodoWrite NotebookEdit]

          allow(mock_executor).to receive(:execute) do |cmd, **_opts|
            disallowed_flag = cmd.find { |arg| arg.start_with?("--disallowedTools=") }
            tool_list = disallowed_flag.sub("--disallowedTools=", "").split(",")
            expected_tools.each do |tool|
              expect(tool_list).to include(tool)
            end
            success_result
          end

          provider.send_message(prompt: "Summarize this", tools: :none)
        end
      end

      context "when tools: is an explicit list" do
        it "includes --disallowedTools only for the specified tools" do
          allow(mock_executor).to receive(:execute) do |cmd, **_opts|
            disallowed_flag = cmd.find { |arg| arg.start_with?("--disallowedTools=") }
            expect(disallowed_flag).not_to be_nil
            expect(disallowed_flag).to eq("--disallowedTools=Bash,Read")
            expect(cmd.join(" ")).not_to include("Edit")
            success_result
          end

          provider.send_message(prompt: "Hello", tools: %w[Bash Read])
        end

        it "includes --permission-mode plan flag" do
          expect(mock_executor).to receive(:execute).with(
            array_including("--permission-mode", "plan"),
            anything
          )

          provider.send_message(prompt: "Hello", tools: %w[Bash])
        end
      end

      context "when tools option is not provided" do
        it "does not include --disallowedTools or --permission-mode" do
          allow(mock_executor).to receive(:execute) do |cmd, **_opts|
            expect(cmd).not_to include("--disallowedTools")
            expect(cmd).not_to include("--permission-mode")
            success_result
          end

          provider.send_message(prompt: "Hello")
        end

        it "raises when a skill defines message-mode tools" do
          AgentHarness.configuration.register_tool(:read_file, anthropic: "Read")
          AgentHarness::Skills.register(:code_review, {
            description: "Reviews code",
            instructions: "Review the changed files before answering.",
            tools: [:read_file]
          })

          expect {
            provider.send_message(prompt: "Hello", skills: [:code_review])
          }.to raise_error(
            AgentHarness::ConfigurationError,
            /does not support message-mode tool injection/
          )
        end
      end

      context "when tools: is an empty array" do
        it "does not include --disallowedTools or --permission-mode" do
          allow(mock_executor).to receive(:execute) do |cmd, **_opts|
            expect(cmd).not_to include("--disallowedTools")
            expect(cmd).not_to include("--permission-mode")
            success_result
          end

          provider.send_message(prompt: "Hello", tools: [])
        end
      end

      context "when tools: :none combined with dangerous_mode: true" do
        it "includes --disallowedTools but omits --permission-mode plan" do
          allow(mock_executor).to receive(:execute) do |cmd, **_opts|
            disallowed_flag = cmd.find { |arg| arg.start_with?("--disallowedTools=") }
            expect(disallowed_flag).not_to be_nil
            tool_list = disallowed_flag.sub("--disallowedTools=", "").split(",")
            AgentHarness::Providers::Anthropic::ALL_CLI_TOOLS.each do |tool|
              expect(tool_list).to include(tool)
            end
            expect(cmd).not_to include("--permission-mode")
            expect(cmd).to include("--dangerously-skip-permissions")
            success_result
          end

          provider.send_message(prompt: "Hello", tools: :none, dangerous_mode: true)
        end
      end
    end

    describe "#supports_text_mode?" do
      it "returns true" do
        expect(provider.supports_text_mode?).to be true
      end
    end

    describe "text mode (mode: :text)" do
      context "with ANTHROPIC_API_KEY set" do
        let(:api_key) { "sk-ant-test-key-456" }

        before do
          allow(ENV).to receive(:[]).and_call_original
          allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return(api_key)
        end

        it "sends via HTTP transport instead of CLI" do
          http_response = instance_double(Net::HTTPOK,
            code: "200",
            body: JSON.generate({
              "content" => [{"type" => "text", "text" => "HTTP response"}],
              "model" => "claude-sonnet-4-20250514",
              "usage" => {"input_tokens" => 20, "output_tokens" => 10}
            }))

          http = instance_double(Net::HTTP)
          allow(Net::HTTP).to receive(:new).and_return(http)
          allow(http).to receive(:use_ssl=)
          allow(http).to receive(:open_timeout=)
          allow(http).to receive(:read_timeout=)
          allow(http).to receive(:request).and_return(http_response)

          # CLI executor should NOT be called
          expect(mock_executor).not_to receive(:execute)

          response = provider.send_message(prompt: "Summarize this", mode: :text)

          expect(response.output).to eq("HTTP response")
          expect(response.success?).to be true
          expect(response.provider).to eq(:claude)
          expect(response.metadata[:transport]).to eq(:http)
        end

        it "does not expose a CLI execution plan" do
          expect(mock_executor).not_to receive(:execute)

          expect {
            provider.plan_execution(prompt: "Summarize this", mode: :text)
          }.to raise_error(
            AgentHarness::ProviderError,
            /does not produce a CLI execution plan/
          )
        end

        it "extracts tokens from HTTP response" do
          http_response = instance_double(Net::HTTPOK,
            code: "200",
            body: JSON.generate({
              "content" => [{"type" => "text", "text" => "response"}],
              "usage" => {"input_tokens" => 50, "output_tokens" => 25}
            }))

          http = instance_double(Net::HTTP)
          allow(Net::HTTP).to receive(:new).and_return(http)
          allow(http).to receive(:use_ssl=)
          allow(http).to receive(:open_timeout=)
          allow(http).to receive(:read_timeout=)
          allow(http).to receive(:request).and_return(http_response)

          response = provider.send_message(prompt: "prompt", mode: :text)

          expect(response.tokens).to eq({input: 50, output: 25, total: 75})
        end

        it "attaches a QuotaStatus parsed from rate-limit response headers" do
          http_response = instance_double(Net::HTTPOK,
            code: "200",
            body: JSON.generate({
              "content" => [{"type" => "text", "text" => "response"}],
              "usage" => {"input_tokens" => 1, "output_tokens" => 1}
            }))
          allow(http_response).to receive(:each_header)
            .and_yield("anthropic-ratelimit-tokens-limit", "100000")
            .and_yield("anthropic-ratelimit-tokens-remaining", "75000")
            .and_yield("anthropic-ratelimit-tokens-reset", "2026-07-21T05:00:00Z")

          http = instance_double(Net::HTTP)
          allow(Net::HTTP).to receive(:new).and_return(http)
          allow(http).to receive(:use_ssl=)
          allow(http).to receive(:open_timeout=)
          allow(http).to receive(:read_timeout=)
          allow(http).to receive(:request).and_return(http_response)

          response = provider.send_message(prompt: "prompt", mode: :text)

          quota_status = response.metadata[:quota_status]
          expect(quota_status).to be_a(AgentHarness::QuotaStatus)
          expect(quota_status.available?).to be true
          expect(quota_status.limit).to eq(100_000)
          expect(quota_status.remaining).to eq(75_000)
          expect(quota_status.unit).to eq(:tokens)
          expect(quota_status.reset_at).to eq(Time.utc(2026, 7, 21, 5, 0, 0))
        end

        it "leaves quota_status unset when no rate-limit headers are present" do
          http_response = instance_double(Net::HTTPOK,
            code: "200",
            body: JSON.generate({
              "content" => [{"type" => "text", "text" => "response"}],
              "usage" => {"input_tokens" => 1, "output_tokens" => 1}
            }))
          allow(http_response).to receive(:each_header).and_yield("content-type", "application/json")

          http = instance_double(Net::HTTP)
          allow(Net::HTTP).to receive(:new).and_return(http)
          allow(http).to receive(:use_ssl=)
          allow(http).to receive(:open_timeout=)
          allow(http).to receive(:read_timeout=)
          allow(http).to receive(:request).and_return(http_response)

          response = provider.send_message(prompt: "prompt", mode: :text)

          expect(response.metadata).not_to have_key(:quota_status)
        end

        it "records tokens with the global token tracker" do
          http_response = instance_double(Net::HTTPOK,
            code: "200",
            body: JSON.generate({
              "content" => [{"type" => "text", "text" => "response"}],
              "usage" => {"input_tokens" => 30, "output_tokens" => 15}
            }))

          http = instance_double(Net::HTTP)
          allow(Net::HTTP).to receive(:new).and_return(http)
          allow(http).to receive(:use_ssl=)
          allow(http).to receive(:open_timeout=)
          allow(http).to receive(:read_timeout=)
          allow(http).to receive(:request).and_return(http_response)

          tracker = AgentHarness.token_tracker
          tracker.clear!

          provider.send_message(prompt: "prompt", mode: :text)

          summary = tracker.summary
          expect(summary[:total_input_tokens]).to eq(30)
          expect(summary[:total_output_tokens]).to eq(15)
          expect(summary[:total_tokens]).to eq(45)
        end

        it "uses configured model" do
          http = instance_double(Net::HTTP)
          allow(Net::HTTP).to receive(:new).and_return(http)
          allow(http).to receive(:use_ssl=)
          allow(http).to receive(:open_timeout=)
          allow(http).to receive(:read_timeout=)

          expect(http).to receive(:request) do |req|
            body = JSON.parse(req.body)
            expect(body["model"]).to eq("claude-3-5-sonnet")

            instance_double(Net::HTTPOK,
              code: "200",
              body: JSON.generate({
                "content" => [{"type" => "text", "text" => "ok"}],
                "model" => "claude-3-5-sonnet",
                "usage" => {"input_tokens" => 1, "output_tokens" => 1}
              }))
          end

          provider.send_message(prompt: "prompt", mode: :text)
        end

        it "applies skill instructions before HTTP text-mode dispatch" do
          AgentHarness::Skills.register(:code_review, {
            description: "Reviews code",
            instructions: "Review the changed files before answering."
          })

          http = instance_double(Net::HTTP)
          allow(Net::HTTP).to receive(:new).and_return(http)
          allow(http).to receive(:use_ssl=)
          allow(http).to receive(:open_timeout=)
          allow(http).to receive(:read_timeout=)

          expect(http).to receive(:request) do |req|
            body = JSON.parse(req.body)
            expect(body.dig("messages", 0, "content")).to eq(
              "Review the changed files before answering.\n\nprompt"
            )

            instance_double(Net::HTTPOK,
              code: "200",
              body: JSON.generate({
                "content" => [{"type" => "text", "text" => "ok"}],
                "model" => "claude-sonnet-4-20250514",
                "usage" => {"input_tokens" => 1, "output_tokens" => 1}
              }))
          end

          provider.send_message(prompt: "prompt", mode: :text, skills: [:code_review])
        end

        it "raises AuthenticationError on 401 from API" do
          http_response = instance_double(Net::HTTPOK,
            code: "401",
            body: JSON.generate({
              "error" => {"type" => "authentication_error", "message" => "invalid api key"}
            }))

          http = instance_double(Net::HTTP)
          allow(Net::HTTP).to receive(:new).and_return(http)
          allow(http).to receive(:use_ssl=)
          allow(http).to receive(:open_timeout=)
          allow(http).to receive(:read_timeout=)
          allow(http).to receive(:request).and_return(http_response)

          expect { provider.send_message(prompt: "prompt", mode: :text) }
            .to raise_error(AgentHarness::AuthenticationError)
        end

        it "raises RateLimitError on 429 from API" do
          http_response = instance_double(Net::HTTPOK,
            code: "429",
            body: JSON.generate({
              "error" => {"type" => "rate_limit_error", "message" => "rate limited"}
            }))

          http = instance_double(Net::HTTP)
          allow(Net::HTTP).to receive(:new).and_return(http)
          allow(http).to receive(:use_ssl=)
          allow(http).to receive(:open_timeout=)
          allow(http).to receive(:read_timeout=)
          allow(http).to receive(:request).and_return(http_response)

          expect { provider.send_message(prompt: "prompt", mode: :text) }
            .to raise_error(AgentHarness::RateLimitError)
        end
      end

      context "without ANTHROPIC_API_KEY" do
        before do
          allow(ENV).to receive(:[]).and_call_original
          allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return(nil)
        end

        it "raises AuthMismatchError" do
          expect { provider.send_message(prompt: "prompt", mode: :text) }
            .to raise_error(AgentHarness::AuthMismatchError, /ANTHROPIC_API_KEY/) do |error|
              expect(error.provider).to eq(:claude)
            end
        end

        it "includes guidance about billing in the error message" do
          expect { provider.send_message(prompt: "prompt", mode: :text) }
            .to raise_error(AgentHarness::AuthMismatchError, /billing/)
        end
      end

      context "with empty ANTHROPIC_API_KEY" do
        before do
          allow(ENV).to receive(:[]).and_call_original
          allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return("   ")
        end

        it "raises AuthMismatchError" do
          expect { provider.send_message(prompt: "prompt", mode: :text) }
            .to raise_error(AgentHarness::AuthMismatchError)
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

    describe "#parse_container_output" do
      it "parses JSON envelope output into a Response" do
        envelope = JSON.generate({
          "type" => "result",
          "subtype" => "success",
          "result" => "Hello from Claude",
          "usage" => {"input_tokens" => 10, "output_tokens" => 5}
        })

        response = provider.parse_container_output(
          stdout: envelope,
          stderr: "",
          exit_code: 0,
          duration: 2.5
        )

        expect(response).to be_a(AgentHarness::Response)
        expect(response.output).to eq("Hello from Claude")
        expect(response.success?).to be true
        expect(response.duration).to eq(2.5)
      end

      it "captures errors for failed exit codes" do
        response = provider.parse_container_output(
          stdout: "",
          stderr: "something went wrong",
          exit_code: 1,
          duration: 0.5
        )

        expect(response.failed?).to be true
        expect(response.error).to be_a(String)
        expect(response.error).not_to be_empty
      end

      it "raises AuthenticationError when the envelope reports not logged in" do
        envelope = JSON.generate({
          "type" => "result",
          "subtype" => "success",
          "is_error" => true,
          "result" => "Not logged in · Please run /login",
          "exit_code" => 1
        })

        expect {
          provider.parse_container_output(
            stdout: envelope,
            stderr: "",
            exit_code: 1,
            duration: 0.5
          )
        }.to raise_error(AgentHarness::AuthenticationError) do |error|
          expect(error.provider).to eq(:claude)
          expect(error.message).to include("Not logged in")
        end
      end
    end
  end
end
