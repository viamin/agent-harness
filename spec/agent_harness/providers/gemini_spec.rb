# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe AgentHarness::Providers::Gemini do
  describe ".provider_name" do
    it "returns :gemini" do
      expect(described_class.provider_name).to eq(:gemini)
    end
  end

  describe ".binary_name" do
    it "returns gemini" do
      expect(described_class.binary_name).to eq("gemini")
    end
  end

  describe ".available?" do
    let(:mock_executor) { instance_double(AgentHarness::CommandExecutor) }

    before do
      allow(AgentHarness.configuration).to receive(:command_executor).and_return(mock_executor)
    end

    it "returns true when gemini binary exists" do
      allow(mock_executor).to receive(:which).with("gemini").and_return("/usr/local/bin/gemini")
      expect(described_class.available?).to be true
    end

    it "returns false when gemini binary is missing" do
      allow(mock_executor).to receive(:which).with("gemini").and_return(nil)
      expect(described_class.available?).to be false
    end
  end

  describe ".firewall_requirements" do
    it "returns required domains" do
      requirements = described_class.firewall_requirements
      expect(requirements[:domains]).to include("generativelanguage.googleapis.com")
      expect(requirements[:ip_ranges]).to eq([])
    end
  end

  describe ".instruction_file_paths" do
    it "returns GEMINI.md" do
      paths = described_class.instruction_file_paths
      expect(paths.first[:path]).to eq("GEMINI.md")
    end
  end

  describe ".discover_models" do
    let(:mock_executor) { instance_double(AgentHarness::CommandExecutor) }

    before do
      allow(AgentHarness.configuration).to receive(:command_executor).and_return(mock_executor)
    end

    context "when gemini is available" do
      before do
        allow(mock_executor).to receive(:which).with("gemini").and_return("/usr/local/bin/gemini")
      end

      it "returns predefined models" do
        models = described_class.discover_models
        expect(models.size).to eq(4)
        expect(models.first[:name]).to eq("gemini-2.0-flash")
      end
    end

    context "when gemini is not available" do
      before do
        allow(mock_executor).to receive(:which).with("gemini").and_return(nil)
      end

      it "returns empty array" do
        expect(described_class.discover_models).to eq([])
      end
    end
  end

  describe ".model_family" do
    it "strips version suffix" do
      expect(described_class.model_family("gemini-1.5-pro-001")).to eq("gemini-1.5-pro")
    end

    it "returns unchanged if no version suffix" do
      expect(described_class.model_family("gemini-1.5-pro")).to eq("gemini-1.5-pro")
    end
  end

  describe ".provider_model_name" do
    it "returns family name unchanged" do
      expect(described_class.provider_model_name("gemini-1.5-pro")).to eq("gemini-1.5-pro")
    end
  end

  describe ".supports_model_family?" do
    it "returns true for models matching the pattern" do
      expect(described_class.supports_model_family?("gemini-1.5-pro")).to be true
      expect(described_class.supports_model_family?("gemini-2.0-flash")).to be true
    end

    it "returns true for any model starting with gemini-" do
      expect(described_class.supports_model_family?("gemini-custom")).to be true
    end

    it "returns false for non-Gemini models" do
      expect(described_class.supports_model_family?("claude-3-sonnet")).to be false
      expect(described_class.supports_model_family?("gpt-4")).to be false
    end
  end

  describe "instance" do
    let(:mock_executor) { instance_double(AgentHarness::CommandExecutor) }

    let(:config) do
      AgentHarness::ProviderConfig.new(:gemini).tap do |c|
        c.model = "gemini-1.5-pro"
        c.default_flags = ["--verbose"]
      end
    end

    subject(:provider) { described_class.new(config: config, executor: mock_executor) }

    describe "#name" do
      it "returns gemini" do
        expect(provider.name).to eq("gemini")
      end
    end

    describe "#display_name" do
      it "returns Google Gemini" do
        expect(provider.display_name).to eq("Google Gemini")
      end
    end

    describe "#capabilities" do
      it "includes expected capabilities" do
        caps = provider.capabilities
        expect(caps[:vision]).to be true
        expect(caps[:tool_use]).to be true
        expect(caps[:streaming]).to be true
        expect(caps[:mcp]).to be false
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
      end

      it "includes auth patterns" do
        patterns = provider.error_patterns
        expect(patterns[:auth_expired]).not_to be_empty
      end
    end

    describe "#send_message" do
      it "includes model when configured" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        expect(mock_executor).to receive(:execute).with(
          array_including("--model", "gemini-1.5-pro"),
          anything
        )

        provider.send_message(prompt: "Hello")
      end

      it "includes default flags" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response",
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

      context "with non-Array default_flags" do
        let(:config) do
          AgentHarness::ProviderConfig.new(:gemini).tap do |c|
            c.model = "gemini-1.5-pro"
            c.default_flags = "--verbose"
          end
        end

        it "raises an error" do
          expect { provider.send_message(prompt: "Hello") }.to raise_error(
            AgentHarness::ProviderError, /default_flags must be an array/
          )
        end
      end

      context "without model configured" do
        let(:config) { AgentHarness::ProviderConfig.new(:gemini) }

        it "does not include model flag" do
          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: "response",
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          expect(mock_executor).to receive(:execute) do |cmd, _opts|
            expect(cmd).not_to include("--model")
          end.and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: "response",
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          provider.send_message(prompt: "Hello")
        end
      end
    end

    describe "#auth_status" do
      let(:tmp_dir) { Dir.mktmpdir }
      let(:credentials_path) { File.join(tmp_dir, "credentials.json") }

      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("GEMINI_CONFIG_DIR").and_return(tmp_dir)
        allow(ENV).to receive(:[]).with("GEMINI_API_KEY").and_return(nil)
        allow(ENV).to receive(:[]).with("GOOGLE_API_KEY").and_return(nil)
      end

      after do
        FileUtils.rm_rf(tmp_dir)
      end

      context "with GEMINI_API_KEY set" do
        before do
          allow(ENV).to receive(:[]).with("GEMINI_API_KEY").and_return("AIza-test-key")
        end

        it "returns valid with api_key auth method" do
          status = provider.auth_status
          expect(status[:valid]).to be true
          expect(status[:auth_method]).to eq(:api_key)
        end
      end

      context "with GOOGLE_API_KEY set" do
        before do
          allow(ENV).to receive(:[]).with("GOOGLE_API_KEY").and_return("AIza-test-key")
        end

        it "returns valid with api_key auth method" do
          status = provider.auth_status
          expect(status[:valid]).to be true
          expect(status[:auth_method]).to eq(:api_key)
        end
      end

      context "with blank GEMINI_API_KEY" do
        before do
          allow(ENV).to receive(:[]).with("GEMINI_API_KEY").and_return("   ")
        end

        it "does not treat blank key as valid" do
          status = provider.auth_status
          expect(status[:valid]).to be false
        end

        context "when GOOGLE_API_KEY is set" do
          before do
            allow(ENV).to receive(:[]).with("GOOGLE_API_KEY").and_return("AIza-fallback-key")
          end

          it "falls back to GOOGLE_API_KEY" do
            status = provider.auth_status
            expect(status[:valid]).to be true
            expect(status[:auth_method]).to eq(:api_key)
          end
        end
      end

      context "with valid OAuth credentials file" do
        before do
          File.write(credentials_path, JSON.generate({
            "access_token" => "ya29.test-token",
            "expires_at" => (Time.now + 3600).to_i
          }))
        end

        it "returns valid with oauth auth method" do
          status = provider.auth_status
          expect(status[:valid]).to be true
          expect(status[:auth_method]).to eq(:oauth)
          expect(status[:expires_at]).to be_a(Time)
        end
      end

      context "with expired OAuth credentials" do
        before do
          File.write(credentials_path, JSON.generate({
            "access_token" => "ya29.expired-token",
            "expires_at" => (Time.now - 3600).to_i
          }))
        end

        it "returns invalid with expiry error" do
          status = provider.auth_status
          expect(status[:valid]).to be false
          expect(status[:error]).to include("expired")
          expect(status[:error]).to include("gemini auth login")
        end
      end

      context "with no credentials" do
        it "returns invalid with helpful message" do
          status = provider.auth_status
          expect(status[:valid]).to be false
          expect(status[:error]).to include("No Gemini credentials")
          expect(status[:error]).to include("GEMINI_API_KEY")
          expect(status[:error]).to include("GOOGLE_API_KEY")
        end
      end

      context "with empty token in credentials file" do
        before do
          File.write(credentials_path, JSON.generate({
            "access_token" => ""
          }))
        end

        it "returns invalid" do
          status = provider.auth_status
          expect(status[:valid]).to be false
          expect(status[:error]).to include("No authentication token")
        end
      end

      context "with invalid JSON in credentials file" do
        before do
          File.write(credentials_path, "not json")
        end

        it "returns invalid with JSON error" do
          status = provider.auth_status
          expect(status[:valid]).to be false
          expect(status[:error]).to include("Invalid JSON")
        end
      end

      context "with permission denied on credentials file" do
        before do
          File.write(credentials_path, JSON.generate({"access_token" => "test"}))
          File.chmod(0o000, credentials_path)
        end

        after do
          File.chmod(0o644, credentials_path)
        end

        it "returns invalid with permission error" do
          status = provider.auth_status
          expect(status[:valid]).to be false
          expect(status[:error]).to include("Permission denied")
        end
      end

      context "with non-Hash JSON in credentials file" do
        before do
          File.write(credentials_path, JSON.generate(["not", "a", "hash"]))
        end

        it "returns invalid with no credentials message" do
          status = provider.auth_status
          expect(status[:valid]).to be false
          expect(status[:error]).to include("No Gemini credentials")
        end
      end

      context "with oauth_token key instead of access_token" do
        before do
          File.write(credentials_path, JSON.generate({
            "oauth_token" => "ya29.test-token"
          }))
        end

        it "returns valid" do
          status = provider.auth_status
          expect(status[:valid]).to be true
        end
      end
    end

    describe "#health_status" do
      let(:tmp_gemini_config_dir) { Dir.mktmpdir }

      after do
        FileUtils.remove_entry(tmp_gemini_config_dir) if tmp_gemini_config_dir && Dir.exist?(tmp_gemini_config_dir)
      end

      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("GEMINI_API_KEY").and_return("test-key")
        allow(ENV).to receive(:[]).with("GOOGLE_API_KEY").and_return(nil)
        allow(ENV).to receive(:[]).with("GEMINI_CONFIG_DIR").and_return(tmp_gemini_config_dir)
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
          allow(ENV).to receive(:[]).with("GEMINI_API_KEY").and_return(nil)
          allow(ENV).to receive(:[]).with("GOOGLE_API_KEY").and_return(nil)
        end

        it "returns unhealthy with auth error" do
          status = provider.health_status
          expect(status[:healthy]).to be false
          expect(status[:message]).to include("No Gemini credentials")
        end
      end
    end

    describe "#validate_config" do
      context "with valid model" do
        it "returns valid" do
          result = provider.validate_config
          expect(result[:valid]).to be true
          expect(result[:errors]).to be_empty
        end
      end

      context "with unrecognized model" do
        let(:config) do
          AgentHarness::ProviderConfig.new(:gemini).tap do |c|
            c.model = "gpt-4"
          end
        end

        it "returns invalid with error" do
          result = provider.validate_config
          expect(result[:valid]).to be false
          expect(result[:errors].first).to include("Unrecognized model")
        end
      end

      context "with no model configured" do
        let(:config) { AgentHarness::ProviderConfig.new(:gemini) }

        it "returns valid" do
          result = provider.validate_config
          expect(result[:valid]).to be true
        end
      end

      context "with non-Array default_flags" do
        let(:config) do
          AgentHarness::ProviderConfig.new(:gemini).tap do |c|
            c.default_flags = "--verbose"
          end
        end

        it "returns invalid" do
          result = provider.validate_config
          expect(result[:valid]).to be false
          expect(result[:errors].first).to include("must be an array")
        end
      end

      context "with non-string default_flags" do
        let(:config) do
          AgentHarness::ProviderConfig.new(:gemini).tap do |c|
            c.default_flags = ["--verbose", 123]
          end
        end

        it "returns invalid" do
          result = provider.validate_config
          expect(result[:valid]).to be false
          expect(result[:errors].first).to include("non-string")
        end
      end
    end

    describe "#execution_semantics" do
      it "returns the full provider contract" do
        semantics = provider.execution_semantics
        expect(semantics[:prompt_delivery]).to eq(:flag)
        expect(semantics[:output_format]).to eq(:text)
        expect(semantics[:sandbox_aware]).to be false
        expect(semantics[:uses_subcommand]).to be false
        expect(semantics[:non_interactive_flag]).to be_nil
        expect(semantics[:legitimate_exit_codes]).to eq([0])
        expect(semantics[:stderr_is_diagnostic]).to be true
        expect(semantics[:parses_rate_limit_reset]).to be false
      end
    end
  end
end
