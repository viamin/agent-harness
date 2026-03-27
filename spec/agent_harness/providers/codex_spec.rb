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

      it "builds command with exec subcommand and positional prompt" do
        expect(mock_executor).to receive(:execute).with(
          ["codex", "exec", "Hello"],
          anything
        ).and_return(success_result)

        provider.send_message(prompt: "Hello")
      end

      it "includes session flags when session is provided" do
        expect(mock_executor).to receive(:execute).with(
          ["codex", "exec", "--session", "session-123", "Hello"],
          anything
        ).and_return(success_result)

        provider.send_message(prompt: "Hello", session: "session-123")
      end

      it "returns a Response object" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response output",
            stderr: "",
            exit_code: 0,
            duration: 1.5
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response).to be_a(AgentHarness::Response)
        expect(response.output).to eq("response output")
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
