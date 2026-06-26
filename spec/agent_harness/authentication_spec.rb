# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe AgentHarness::Authentication do
  let(:tmp_dir) { Dir.mktmpdir }
  let(:credentials_path) { File.join(tmp_dir, ".credentials.json") }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(tmp_dir)
  end

  after do
    FileUtils.rm_rf(tmp_dir)
  end

  describe ".auth_valid?" do
    context "with valid Claude credentials" do
      before do
        File.write(credentials_path, JSON.generate({
          "oauth_token" => "valid-token",
          "expiresAt" => (Time.now + 3600).to_i
        }))
      end

      it "returns true" do
        expect(described_class.auth_valid?(:claude)).to be true
      end
    end

    context "with expired Claude credentials" do
      before do
        File.write(credentials_path, JSON.generate({
          "oauth_token" => "expired-token",
          "expiresAt" => (Time.now - 3600).to_i
        }))
      end

      it "returns false" do
        expect(described_class.auth_valid?(:claude)).to be false
      end
    end

    context "with no credentials file" do
      it "returns false" do
        expect(described_class.auth_valid?(:claude)).to be false
      end
    end

    context "with API key provider" do
      it "returns false when no provider-specific check is implemented" do
        expect(described_class.auth_valid?(:aider)).to be false
      end
    end

    context "with OAuth provider lacking auth check implementation" do
      it "returns false instead of nil" do
        result = described_class.auth_valid?(:cursor)
        expect(result).to be false
        expect(result).not_to be_nil
      end
    end
  end

  describe ".auth_status" do
    context "for Claude provider" do
      it "returns valid status with token present" do
        File.write(credentials_path, JSON.generate({
          "oauth_token" => "test-token"
        }))

        status = described_class.auth_status(:claude)
        expect(status[:valid]).to be true
        expect(status[:error]).to be_nil
      end

      it "returns expired status when token is expired" do
        expired_time = Time.now - 3600
        File.write(credentials_path, JSON.generate({
          "oauth_token" => "expired-token",
          "expiresAt" => expired_time.to_i
        }))

        status = described_class.auth_status(:claude)
        expect(status[:valid]).to be false
        expect(status[:error]).to eq("Session expired")
        expect(status[:expires_at]).to be_a(Time)
      end

      it "returns invalid status with no credentials" do
        status = described_class.auth_status(:claude)
        expect(status[:valid]).to be false
        expect(status[:error]).to eq("No credentials found")
      end

      it "returns invalid status with empty credentials" do
        File.write(credentials_path, JSON.generate({}))

        status = described_class.auth_status(:claude)
        expect(status[:valid]).to be false
        expect(status[:error]).to eq("No authentication token found")
      end

      it "returns invalid status with empty string oauth_token" do
        File.write(credentials_path, JSON.generate({
          "oauth_token" => ""
        }))

        status = described_class.auth_status(:claude)
        expect(status[:valid]).to be false
        expect(status[:error]).to eq("No authentication token found")
      end

      it "returns invalid status with blank apiKey" do
        File.write(credentials_path, JSON.generate({
          "apiKey" => "   "
        }))

        status = described_class.auth_status(:claude)
        expect(status[:valid]).to be false
        expect(status[:error]).to eq("No authentication token found")
      end

      it "falls back to apiKey when oauth_token is empty" do
        File.write(credentials_path, JSON.generate({
          "oauth_token" => "",
          "apiKey" => "sk-ant-valid"
        }))

        status = described_class.auth_status(:claude)
        expect(status[:valid]).to be true
      end

      it "falls back to apiKey when oauth_token is blank" do
        File.write(credentials_path, JSON.generate({
          "oauth_token" => "   ",
          "apiKey" => "sk-ant-valid"
        }))

        status = described_class.auth_status(:claude)
        expect(status[:valid]).to be true
      end

      it "handles apiKey credential format" do
        File.write(credentials_path, JSON.generate({
          "apiKey" => "sk-ant-test"
        }))

        status = described_class.auth_status(:claude)
        expect(status[:valid]).to be true
      end

      it "accepts :anthropic alias" do
        File.write(credentials_path, JSON.generate({
          "oauth_token" => "test-token"
        }))

        status = described_class.auth_status(:anthropic)
        expect(status[:valid]).to be true
      end

      context "with native claudeAiOauth shape" do
        it "returns valid status with accessToken present" do
          File.write(credentials_path, JSON.generate({
            "claudeAiOauth" => {
              "accessToken" => "native-token",
              "refreshToken" => "refresh-token",
              "expiresAt" => (Time.now + 3600).to_i,
              "scopes" => ["user:read"],
              "subscriptionType" => "pro"
            }
          }))

          status = described_class.auth_status(:claude)
          expect(status[:valid]).to be true
          expect(status[:expires_at]).to be_a(Time)
          expect(status[:error]).to be_nil
        end

        it "returns expired status when claudeAiOauth token is expired" do
          File.write(credentials_path, JSON.generate({
            "claudeAiOauth" => {
              "accessToken" => "expired-native-token",
              "expiresAt" => (Time.now - 3600).to_i
            }
          }))

          status = described_class.auth_status(:claude)
          expect(status[:valid]).to be false
          expect(status[:error]).to eq("Session expired")
        end

        it "returns invalid when claudeAiOauth has no accessToken" do
          File.write(credentials_path, JSON.generate({
            "claudeAiOauth" => {
              "refreshToken" => "refresh-only"
            }
          }))

          status = described_class.auth_status(:claude)
          expect(status[:valid]).to be false
          expect(status[:error]).to eq("No authentication token found")
        end

        it "returns invalid when claudeAiOauth accessToken is blank" do
          File.write(credentials_path, JSON.generate({
            "claudeAiOauth" => {
              "accessToken" => "   "
            }
          }))

          status = described_class.auth_status(:claude)
          expect(status[:valid]).to be false
          expect(status[:error]).to eq("No authentication token found")
        end

        it "prefers claudeAiOauth over top-level oauth_token" do
          File.write(credentials_path, JSON.generate({
            "claudeAiOauth" => {
              "accessToken" => "native-token",
              "expiresAt" => (Time.now + 3600).to_i
            },
            "oauth_token" => "legacy-token",
            "expiresAt" => (Time.now - 3600).to_i
          }))

          status = described_class.auth_status(:claude)
          # Should use the native (valid) token, not the legacy (expired) one
          expect(status[:valid]).to be true
        end

        it "falls back to top-level token when claudeAiOauth accessToken is blank" do
          File.write(credentials_path, JSON.generate({
            "claudeAiOauth" => {
              "accessToken" => ""
            },
            "oauth_token" => "fallback-token"
          }))

          status = described_class.auth_status(:claude)
          expect(status[:valid]).to be true
        end

        it "handles non-hash claudeAiOauth value gracefully" do
          File.write(credentials_path, JSON.generate({
            "claudeAiOauth" => "not-a-hash",
            "oauth_token" => "fallback-token"
          }))

          status = described_class.auth_status(:claude)
          expect(status[:valid]).to be true
        end
      end

      it "returns specific error for invalid JSON in credentials file" do
        File.write(credentials_path, "not json")

        status = described_class.auth_status(:claude)
        expect(status[:valid]).to be false
        expect(status[:error]).to include("Invalid JSON")
      end

      it "returns specific error for permission denied on credentials file" do
        File.write(credentials_path, JSON.generate({"oauth_token" => "test"}))
        File.chmod(0o000, credentials_path)

        status = described_class.auth_status(:claude)
        expect(status[:valid]).to be false
        expect(status[:error]).to include("Permission denied")
      ensure
        File.chmod(0o644, credentials_path)
      end
    end

    context "for API key provider" do
      it "returns not-implemented status when no provider-specific check exists" do
        status = described_class.auth_status(:aider)
        expect(status[:valid]).to be false
        expect(status[:expires_at]).to be_nil
        expect(status[:error]).to include("not implemented")
      end
    end

    context "for a custom provider that only accepts config keyword construction" do
      let(:provider_class) do
        Class.new do
          include AgentHarness::Providers::Adapter

          class << self
            def provider_name = :subset_safe_provider
            def available? = true
            def binary_name = "subset-safe"
          end

          def initialize(config: nil)
            @config = config
          end

          def auth_status
            {valid: @config.name == :subset_safe_provider, expires_at: nil, error: nil}
          end
        end
      end

      before do
        AgentHarness::Providers::Registry.instance.reset!
        AgentHarness::Providers::Registry.instance.register(:subset_safe_provider, provider_class)
        AgentHarness.configuration.providers[:subset_safe_provider] =
          AgentHarness::ProviderConfig.new(:subset_safe_provider)
      end

      after do
        AgentHarness.configuration.providers.delete(:subset_safe_provider)
      end

      it "uses the safe subset constructor for auth resolution" do
        status = described_class.auth_status(:subset_safe_provider)

        expect(status).to eq(valid: true, expires_at: nil, error: nil)
      end

      it "falls back to canonical config when called through an alias" do
        AgentHarness::Providers::Registry.instance.register(
          :subset_safe_provider,
          provider_class,
          aliases: [:subset_safe_alias]
        )

        status = described_class.auth_status(:subset_safe_alias)

        expect(status).to eq(valid: true, expires_at: nil, error: nil)
      end

      it "does not fall back to provider class canonical name config" do
        malicious_provider_name = :custom_auth_provider
        malicious_class = Class.new do
          include AgentHarness::Providers::Adapter

          class << self
            def provider_name = :claude
            def available? = true
            def binary_name = "custom-auth-provider"
          end

          def initialize(config: nil)
            @config = config
          end

          def auth_status
            {
              valid: @config.nil? || @config.name != :claude,
              expires_at: nil,
              error: nil
            }
          end
        end

        malicious_provider_config = AgentHarness::ProviderConfig.new(:claude)

        AgentHarness::Providers::Registry.instance.reset!
        AgentHarness::Providers::Registry.instance.register(malicious_provider_name, malicious_class)
        AgentHarness.configuration.providers[:claude] = malicious_provider_config

        status = described_class.auth_status(malicious_provider_name)

        expect(status).to eq(valid: true, expires_at: nil, error: nil)
      ensure
        AgentHarness::Providers::Registry.instance.reset!
        AgentHarness.configuration.providers.delete(:claude)
      end
    end

    context "for a config-only provider that needs executor at runtime" do
      let(:config_only_class) do
        Class.new do
          include AgentHarness::Providers::Adapter

          class << self
            def provider_name = :config_only_auth_provider
            def available? = true
            def binary_name = "config-only-auth"
          end

          def initialize(config: nil)
            @config = config
          end

          def auth_status
            # Verify executor is available even though the constructor
            # only accepts config:
            {valid: respond_to?(:executor), expires_at: nil, error: nil}
          end
        end
      end

      before do
        AgentHarness::Providers::Registry.instance.reset!
        AgentHarness::Providers::Registry.instance.register(:config_only_auth_provider, config_only_class)
        AgentHarness.configuration.providers[:config_only_auth_provider] =
          AgentHarness::ProviderConfig.new(:config_only_auth_provider)
      end

      after do
        AgentHarness.configuration.providers.delete(:config_only_auth_provider)
      end

      it "backfills executor on providers that accept only a keyword subset" do
        status = described_class.auth_status(:config_only_auth_provider)

        expect(status).to eq(valid: true, expires_at: nil, error: nil)
      end
    end

    context "for a custom provider with extra optional constructor keywords" do
      let(:provider_class) do
        Class.new do
          include AgentHarness::Providers::Adapter

          class << self
            def provider_name = :optional_keyword_provider
            def available? = true
            def binary_name = "optional-keyword"
          end

          def initialize(config: nil, timeout: 30)
            @config = config
            @timeout = timeout
          end

          def auth_status
            {
              valid: @config.name == :optional_keyword_provider && @timeout == 30,
              expires_at: nil,
              error: nil
            }
          end
        end
      end

      before do
        AgentHarness::Providers::Registry.instance.reset!
        AgentHarness::Providers::Registry.instance.register(:optional_keyword_provider, provider_class)
        AgentHarness.configuration.providers[:optional_keyword_provider] =
          AgentHarness::ProviderConfig.new(:optional_keyword_provider)
      end

      after do
        AgentHarness.configuration.providers.delete(:optional_keyword_provider)
      end

      it "omits unsupported kwargs and still resolves auth status" do
        status = described_class.auth_status(:optional_keyword_provider)

        expect(status).to eq(valid: true, expires_at: nil, error: nil)
      end
    end

    context "for Gemini provider" do
      let(:gemini_tmp_dir) { Dir.mktmpdir }
      let(:gemini_credentials_path) { File.join(gemini_tmp_dir, "credentials.json") }

      before do
        allow(ENV).to receive(:[]).with("GEMINI_CONFIG_DIR").and_return(gemini_tmp_dir)
        allow(ENV).to receive(:[]).with("GEMINI_API_KEY").and_return(nil)
        allow(ENV).to receive(:[]).with("GOOGLE_API_KEY").and_return(nil)
      end

      after do
        FileUtils.rm_rf(gemini_tmp_dir)
      end

      it "returns valid when GEMINI_API_KEY is set" do
        allow(ENV).to receive(:[]).with("GEMINI_API_KEY").and_return("AIza-test")

        status = described_class.auth_status(:gemini)
        expect(status[:valid]).to be true
      end

      it "returns valid when OAuth credentials exist" do
        File.write(gemini_credentials_path, JSON.generate({
          "access_token" => "ya29.test-token",
          "expires_at" => (Time.now + 3600).to_i
        }))

        status = described_class.auth_status(:gemini)
        expect(status[:valid]).to be true
      end

      it "returns invalid when no credentials found" do
        status = described_class.auth_status(:gemini)
        expect(status[:valid]).to be false
        expect(status[:error]).to include("No Gemini credentials")
      end

      it "returns invalid when credentials are expired" do
        File.write(gemini_credentials_path, JSON.generate({
          "access_token" => "ya29.expired",
          "expires_at" => (Time.now - 3600).to_i
        }))

        status = described_class.auth_status(:gemini)
        expect(status[:valid]).to be false
        expect(status[:error]).to include("expired")
      end
    end

    context "for Codex provider" do
      let(:codex_tmp_dir) { Dir.mktmpdir }
      let(:codex_config_path) { File.join(codex_tmp_dir, "config.json") }

      before do
        allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return(nil)
        allow(ENV).to receive(:[]).with("CODEX_CONFIG_DIR").and_return(codex_tmp_dir)
      end

      after do
        FileUtils.rm_rf(codex_tmp_dir)
      end

      it "returns valid when OPENAI_API_KEY is set" do
        allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return("sk-test-key")

        status = described_class.auth_status(:codex)
        expect(status[:valid]).to be true
      end

      it "returns valid when config file has API key" do
        File.write(codex_config_path, JSON.generate({"api_key" => "sk-config-key"}))

        status = described_class.auth_status(:codex)
        expect(status[:valid]).to be true
      end

      it "returns invalid when no credentials found" do
        status = described_class.auth_status(:codex)
        expect(status[:valid]).to be false
        expect(status[:error]).to include("No OpenAI API key")
      end

      it "returns invalid when OPENAI_API_KEY has wrong format" do
        allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return("invalid-format")

        status = described_class.auth_status(:codex)
        expect(status[:valid]).to be false
        expect(status[:error]).to include("does not appear to be a valid")
      end
    end
  end

  describe ".auth_url" do
    context "for Claude provider" do
      it "returns the OAuth URL" do
        url = described_class.auth_url(:claude)
        expect(url).to include("claude.ai/oauth")
      end
    end

    context "for API key provider" do
      it "raises UnsupportedAuthFlowError with provider auth details" do
        expect { described_class.auth_url(:aider) }
          .to raise_error(AgentHarness::UnsupportedAuthFlowError, /Provider aider uses api_key auth/)
      end

      it "raises an AgentHarness::Error subclass" do
        expect { described_class.auth_url(:aider) }.to raise_error(AgentHarness::Error)
      end
    end

    context "for OAuth provider without URL generation support" do
      it "raises UnsupportedAuthFlowError with implementation details" do
        expect { described_class.auth_url(:cursor) }
          .to raise_error(AgentHarness::UnsupportedAuthFlowError, /OAuth URL generation is not yet implemented/)
      end
    end
  end

  describe ".auth_capabilities" do
    it "returns supported OAuth flows for Claude" do
      expect(described_class.auth_capabilities(:claude)).to eq(
        auth_type: :oauth,
        auth_url: true,
        exchange_code: true,
        refresh: true
      )
    end

    it "returns supported OAuth flows for the Anthropic alias" do
      expect(described_class.auth_capabilities(:anthropic)).to eq(
        auth_type: :oauth,
        auth_url: true,
        exchange_code: true,
        refresh: true
      )
    end

    it "returns unsupported OAuth flows for API key providers" do
      expect(described_class.auth_capabilities(:codex)).to eq(
        auth_type: :api_key,
        auth_url: false,
        exchange_code: false,
        refresh: false
      )
    end

    it "returns unsupported OAuth flows for OAuth providers without flow implementations" do
      expect(described_class.auth_capabilities(:cursor)).to eq(
        auth_type: :oauth,
        auth_url: false,
        exchange_code: false,
        refresh: false
      )
    end

    it "raises ProviderNotFoundError for unknown providers" do
      expect { described_class.auth_capabilities(:unknown_provider) }
        .to raise_error(AgentHarness::ProviderNotFoundError, "Unknown provider: unknown_provider")
    end
  end

  describe ".auth_url_supported?" do
    it "returns true for Claude without invoking auth_url" do
      expect(described_class).not_to receive(:auth_url)

      expect(described_class.auth_url_supported?(:claude)).to be true
    end

    it "returns true for the Anthropic alias" do
      expect(described_class.auth_url_supported?(:anthropic)).to be true
    end

    it "returns false for API key providers" do
      expect(described_class.auth_url_supported?(:codex)).to be false
    end

    it "returns false for OAuth providers without URL generation implementations" do
      expect(described_class.auth_url_supported?(:cursor)).to be false
    end

    it "raises ProviderNotFoundError for unknown providers" do
      expect { described_class.auth_url_supported?(:unknown_provider) }
        .to raise_error(AgentHarness::ProviderNotFoundError, "Unknown provider: unknown_provider")
    end
  end

  describe ".exchange_code_supported?" do
    it "returns true for Claude" do
      expect(described_class.exchange_code_supported?(:claude)).to be true
    end

    it "returns true for the Anthropic alias" do
      expect(described_class.exchange_code_supported?(:anthropic)).to be true
    end

    it "returns false for API key providers" do
      expect(described_class.exchange_code_supported?(:codex)).to be false
    end

    it "returns false for OAuth providers without exchange implementations" do
      expect(described_class.exchange_code_supported?(:cursor)).to be false
    end

    it "raises ProviderNotFoundError for unknown providers" do
      expect { described_class.exchange_code_supported?(:unknown_provider) }
        .to raise_error(AgentHarness::ProviderNotFoundError, "Unknown provider: unknown_provider")
    end
  end

  describe ".exchange_code" do
    context "for Claude provider" do
      let(:token_response_body) do
        {
          "access_token" => "new-access-token",
          "refresh_token" => "new-refresh-token",
          "expires_in" => 3600,
          "token_type" => "Bearer"
        }
      end

      def stub_token_request(status: 200, body: token_response_body.to_json)
        http = instance_double(Net::HTTP)
        response = instance_double(Net::HTTPResponse, code: status.to_s, body: body)
        allow(response).to receive(:is_a?).with(anything).and_return(false)
        allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(status >= 200 && status < 300)

        allow(Net::HTTP).to receive(:start)
          .with("claude.ai", 443, use_ssl: true)
          .and_yield(http)
        allow(http).to receive(:open_timeout=)
        allow(http).to receive(:read_timeout=)
        allow(http).to receive(:request).and_return(response)
        http
      end

      it "exchanges code for tokens and stores credentials" do
        stub_token_request

        result = described_class.exchange_code(:claude, code: "auth-code-123", code_verifier: "verifier-456")

        expect(result[:success]).to be true
        expect(result[:credentials]["access_token"]).to eq("new-access-token")

        credentials = JSON.parse(File.read(credentials_path))
        expect(credentials["oauth_token"]).to eq("new-access-token")
        expect(credentials["refreshToken"]).to eq("new-refresh-token")
        expect(credentials["expiresAt"]).not_to be_nil
      end

      it "returns success with the token data" do
        stub_token_request

        result = described_class.exchange_code(:claude, code: "auth-code-123", code_verifier: "verifier-456")

        expect(result[:success]).to be true
        expect(result[:credentials]).to eq(token_response_body)
      end

      it "sends correct request body" do
        http = stub_token_request

        expect(http).to receive(:request) do |req|
          body = JSON.parse(req.body)
          expect(body["grant_type"]).to eq("authorization_code")
          expect(body["client_id"]).to eq("9d1c250a-e61b-44d9-88ed-5944d1962f5e")
          expect(body["redirect_uri"]).to eq("https://console.anthropic.com/oauth/code/callback")
          expect(body["code"]).to eq("auth-code-123")
          expect(body["code_verifier"]).to eq("verifier-456")
          expect(req.content_type).to eq("application/json")

          response = instance_double(Net::HTTPResponse, code: "200", body: token_response_body.to_json)
          allow(response).to receive(:is_a?).with(anything).and_return(false)
          allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
          response
        end

        described_class.exchange_code(:claude, code: "auth-code-123", code_verifier: "verifier-456")
      end

      it "strips whitespace from code and code_verifier" do
        http = stub_token_request

        expect(http).to receive(:request) do |req|
          body = JSON.parse(req.body)
          expect(body["code"]).to eq("auth-code-123")
          expect(body["code_verifier"]).to eq("verifier-456")

          response = instance_double(Net::HTTPResponse, code: "200", body: token_response_body.to_json)
          allow(response).to receive(:is_a?).with(anything).and_return(false)
          allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
          response
        end

        described_class.exchange_code(:claude, code: "  auth-code-123  ", code_verifier: "  verifier-456  ")
      end

      it "accepts :anthropic alias" do
        stub_token_request

        result = described_class.exchange_code(:anthropic, code: "auth-code-123", code_verifier: "verifier-456")
        expect(result[:success]).to be true
      end

      it "preserves existing credentials" do
        stub_token_request
        File.write(credentials_path, JSON.generate({"existing_key" => "existing_value"}))

        described_class.exchange_code(:claude, code: "auth-code-123", code_verifier: "verifier-456")

        credentials = JSON.parse(File.read(credentials_path))
        expect(credentials["existing_key"]).to eq("existing_value")
        expect(credentials["oauth_token"]).to eq("new-access-token")
      end

      it "updates claudeAiOauth shape when present" do
        stub_token_request
        File.write(credentials_path, JSON.generate({
          "claudeAiOauth" => {
            "accessToken" => "old-token",
            "refreshToken" => "old-refresh",
            "scopes" => ["user:read"]
          }
        }))

        described_class.exchange_code(:claude, code: "auth-code-123", code_verifier: "verifier-456")

        credentials = JSON.parse(File.read(credentials_path))
        expect(credentials["claudeAiOauth"]["accessToken"]).to eq("new-access-token")
        expect(credentials["claudeAiOauth"]["refreshToken"]).to eq("new-refresh-token")
        expect(credentials["claudeAiOauth"]["scopes"]).to eq(["user:read"])
        expect(credentials).not_to have_key("oauth_token")
      end

      it "does not write top-level oauth_token when claudeAiOauth exists" do
        stub_token_request
        File.write(credentials_path, JSON.generate({
          "claudeAiOauth" => {"accessToken" => "old"}
        }))

        described_class.exchange_code(:claude, code: "auth-code-123", code_verifier: "verifier-456")

        credentials = JSON.parse(File.read(credentials_path))
        expect(credentials["claudeAiOauth"]["accessToken"]).to eq("new-access-token")
        expect(credentials).not_to have_key("oauth_token")
        expect(credentials).not_to have_key("refreshToken")
      end

      it "sets restrictive file permissions on credentials file" do
        stub_token_request

        described_class.exchange_code(:claude, code: "auth-code-123", code_verifier: "verifier-456")

        mode = File.stat(credentials_path).mode & 0o777
        expect(mode).to eq(0o600)
      end

      it "stores credentials without refresh_token when not provided" do
        no_refresh_response = token_response_body.reject { |k| k == "refresh_token" }
        stub_token_request(body: no_refresh_response.to_json)

        described_class.exchange_code(:claude, code: "auth-code-123", code_verifier: "verifier-456")

        credentials = JSON.parse(File.read(credentials_path))
        expect(credentials).not_to have_key("refreshToken")
      end

      it "raises ArgumentError without code" do
        expect { described_class.exchange_code(:claude, code: nil, code_verifier: "verifier") }
          .to raise_error(ArgumentError, /code must be a non-empty string/)
      end

      it "raises ArgumentError with empty code" do
        expect { described_class.exchange_code(:claude, code: "", code_verifier: "verifier") }
          .to raise_error(ArgumentError, /code must be a non-empty string/)
      end

      it "raises ArgumentError with blank code" do
        expect { described_class.exchange_code(:claude, code: "   ", code_verifier: "verifier") }
          .to raise_error(ArgumentError, /code must be a non-empty string/)
      end

      it "raises ArgumentError without code_verifier" do
        expect { described_class.exchange_code(:claude, code: "code", code_verifier: nil) }
          .to raise_error(ArgumentError, /code_verifier must be a non-empty string/)
      end

      it "raises ArgumentError with empty code_verifier" do
        expect { described_class.exchange_code(:claude, code: "code", code_verifier: "") }
          .to raise_error(ArgumentError, /code_verifier must be a non-empty string/)
      end

      it "raises AuthenticationError on HTTP failure" do
        stub_token_request(status: 400, body: {error: "invalid_grant"}.to_json)

        expect { described_class.exchange_code(:claude, code: "bad-code", code_verifier: "verifier") }
          .to raise_error(AgentHarness::AuthenticationError, /PKCE code exchange failed.*invalid_grant/)
      end

      it "raises AuthenticationError with non-JSON error response" do
        stub_token_request(status: 500, body: "Internal Server Error")

        expect { described_class.exchange_code(:claude, code: "code", code_verifier: "verifier") }
          .to raise_error(AgentHarness::AuthenticationError, /PKCE code exchange failed.*500/)
      end
    end

    context "for API key provider" do
      it "raises UnsupportedAuthFlowError with provider auth details" do
        expect { described_class.exchange_code(:aider, code: "code", code_verifier: "verifier") }
          .to raise_error(AgentHarness::UnsupportedAuthFlowError, /Provider aider uses api_key auth/)
      end

      it "raises an AgentHarness::Error subclass" do
        expect { described_class.exchange_code(:aider, code: "code", code_verifier: "verifier") }
          .to raise_error(AgentHarness::Error)
      end
    end

    context "for OAuth provider without code exchange support" do
      it "raises UnsupportedAuthFlowError with implementation details" do
        expect { described_class.exchange_code(:cursor, code: "code", code_verifier: "verifier") }
          .to raise_error(AgentHarness::UnsupportedAuthFlowError, /PKCE code exchange is not yet implemented/)
      end
    end
  end

  describe ".refresh_auth_supported?" do
    it "returns true for Claude without invoking refresh_auth" do
      expect(described_class).not_to receive(:refresh_auth)

      expect(described_class.refresh_auth_supported?(:claude)).to be true
    end

    it "returns true for the Anthropic alias" do
      expect(described_class.refresh_auth_supported?(:anthropic)).to be true
    end

    it "returns false for API key providers" do
      expect(described_class.refresh_auth_supported?(:codex)).to be false
    end

    it "returns false for OAuth providers without refresh implementations" do
      expect(described_class.refresh_auth_supported?(:cursor)).to be false
    end

    it "raises ProviderNotFoundError for unknown providers" do
      expect { described_class.refresh_auth_supported?(:unknown_provider) }
        .to raise_error(AgentHarness::ProviderNotFoundError, "Unknown provider: unknown_provider")
    end
  end

  describe ".refresh_auth" do
    context "for Claude provider" do
      it "stores a token in credentials" do
        described_class.refresh_auth(:claude, token: "new-token")

        credentials = JSON.parse(File.read(credentials_path))
        expect(credentials["oauth_token"]).to eq("new-token")
      end

      it "returns success" do
        result = described_class.refresh_auth(:claude, token: "new-token")
        expect(result[:success]).to be true
      end

      it "raises ArgumentError without token" do
        expect { described_class.refresh_auth(:claude) }.to raise_error(ArgumentError, /token must be a non-empty string/)
      end

      it "raises ArgumentError with empty string token" do
        expect { described_class.refresh_auth(:claude, token: "") }.to raise_error(ArgumentError, /token must be a non-empty string/)
      end

      it "raises ArgumentError with whitespace-only token" do
        expect { described_class.refresh_auth(:claude, token: "   ") }.to raise_error(ArgumentError, /token must be a non-empty string/)
      end

      it "strips whitespace from token before storing" do
        described_class.refresh_auth(:claude, token: "  new-token  ")

        credentials = JSON.parse(File.read(credentials_path))
        expect(credentials["oauth_token"]).to eq("new-token")
      end

      it "creates credentials directory if missing" do
        nested_dir = File.join(tmp_dir, "nested", "dir")
        allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(nested_dir)

        described_class.refresh_auth(:claude, token: "new-token")

        expect(File.exist?(File.join(nested_dir, ".credentials.json"))).to be true
      end

      it "preserves existing credentials" do
        File.write(credentials_path, JSON.generate({"existing_key" => "existing_value"}))

        described_class.refresh_auth(:claude, token: "new-token")

        credentials = JSON.parse(File.read(credentials_path))
        expect(credentials["existing_key"]).to eq("existing_value")
        expect(credentials["oauth_token"]).to eq("new-token")
      end

      context "with native claudeAiOauth shape" do
        it "updates accessToken within claudeAiOauth" do
          File.write(credentials_path, JSON.generate({
            "claudeAiOauth" => {
              "accessToken" => "old-native-token",
              "refreshToken" => "refresh-token",
              "expiresAt" => (Time.now - 3600).to_i,
              "scopes" => ["user:read"],
              "subscriptionType" => "pro"
            }
          }))

          described_class.refresh_auth(:claude, token: "new-native-token")

          credentials = JSON.parse(File.read(credentials_path))
          expect(credentials["claudeAiOauth"]["accessToken"]).to eq("new-native-token")
          expect(credentials["claudeAiOauth"]["refreshToken"]).to eq("refresh-token")
          expect(credentials["claudeAiOauth"]["scopes"]).to eq(["user:read"])
          expect(credentials["claudeAiOauth"]).not_to have_key("expiresAt")
          # Should not create a top-level oauth_token
          expect(credentials).not_to have_key("oauth_token")
        end

        it "does not write top-level oauth_token when claudeAiOauth exists" do
          File.write(credentials_path, JSON.generate({
            "claudeAiOauth" => {
              "accessToken" => "old-token"
            }
          }))

          described_class.refresh_auth(:claude, token: "new-token")

          credentials = JSON.parse(File.read(credentials_path))
          expect(credentials).not_to have_key("oauth_token")
          expect(credentials["claudeAiOauth"]["accessToken"]).to eq("new-token")
        end
      end

      it "clears expiry metadata so refreshed tokens are not treated as expired" do
        File.write(credentials_path, JSON.generate({
          "oauth_token" => "old-token",
          "expiresAt" => (Time.now - 3600).to_i,
          "expires_at" => (Time.now - 3600).iso8601
        }))

        described_class.refresh_auth(:claude, token: "new-token")

        credentials = JSON.parse(File.read(credentials_path))
        expect(credentials["oauth_token"]).to eq("new-token")
        expect(credentials).not_to have_key("expiresAt")
        expect(credentials).not_to have_key("expires_at")

        # Verify auth_status now reports valid after refresh
        status = described_class.auth_status(:claude)
        expect(status[:valid]).to be true
      end

      it "sets restrictive file permissions on credentials file" do
        described_class.refresh_auth(:claude, token: "new-token")

        mode = File.stat(credentials_path).mode & 0o777
        expect(mode).to eq(0o600)
      end
    end

    context "for API key provider" do
      it "raises UnsupportedAuthFlowError with provider auth details" do
        expect { described_class.refresh_auth(:aider, token: "key") }
          .to raise_error(AgentHarness::UnsupportedAuthFlowError, /Provider aider uses api_key auth/)
      end

      it "raises an AgentHarness::Error subclass" do
        expect { described_class.refresh_auth(:aider, token: "key") }.to raise_error(AgentHarness::Error)
      end
    end

    context "for OAuth provider without credential refresh support" do
      it "raises UnsupportedAuthFlowError with implementation details" do
        expect { described_class.refresh_auth(:cursor, token: "key") }
          .to raise_error(AgentHarness::UnsupportedAuthFlowError, /Credential refresh is not yet implemented/)
      end
    end
  end
end
