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

      it "handles invalid JSON in credentials file" do
        File.write(credentials_path, "not json")

        status = described_class.auth_status(:claude)
        expect(status[:valid]).to be false
        expect(status[:error]).to eq("No credentials found")
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
  end

  describe ".auth_url" do
    context "for Claude provider" do
      it "returns the OAuth URL" do
        url = described_class.auth_url(:claude)
        expect(url).to include("claude.ai/oauth")
      end
    end

    context "for API key provider" do
      it "raises NotImplementedError" do
        expect { described_class.auth_url(:aider) }.to raise_error(NotImplementedError, /api_key/)
      end
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

      it "sets restrictive file permissions on credentials file" do
        described_class.refresh_auth(:claude, token: "new-token")

        mode = File.stat(credentials_path).mode & 0o777
        expect(mode).to eq(0o600)
      end
    end

    context "for API key provider" do
      it "raises NotImplementedError" do
        expect { described_class.refresh_auth(:aider, token: "key") }.to raise_error(NotImplementedError, /api_key/)
      end
    end
  end
end
