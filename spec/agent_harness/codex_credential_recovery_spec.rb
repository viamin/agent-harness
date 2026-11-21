# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe AgentHarness::CodexCredentialRecovery do
  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "auth.json") }
  let(:now) { Time.utc(2026, 11, 21, 4, 23) }
  let(:clock) { class_double(Time, now: now) }
  let(:http) { instance_double(Net::HTTP) }
  let(:http_factory) { class_double(Net::HTTP, new: http) }

  before do
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    write_credentials
  end

  after { FileUtils.rm_rf(dir) }

  def jwt(account_id:, expires_at: now + 3600)
    payload = Base64.urlsafe_encode64(JSON.generate(
      "https://api.openai.com/auth" => {"chatgpt_account_id" => account_id},
      "exp" => expires_at.to_i
    ), padding: false)
    "header.#{payload}.signature"
  end

  def write_credentials(overrides = {})
    credentials = {
      "auth_mode" => "chatgpt",
      "OPENAI_API_KEY" => nil,
      "tokens" => {
        "id_token" => jwt(account_id: "acct-1", expires_at: now - 60),
        "access_token" => jwt(account_id: "acct-1", expires_at: now - 60),
        "refresh_token" => "old-refresh",
        "account_id" => "acct-1"
      },
      "last_refresh" => "2026-11-20T00:00:00Z",
      "native_extra" => {"preserved" => true}
    }.merge(overrides)
    File.write(path, JSON.generate(credentials))
  end

  def response(status: 200, body: {})
    value = instance_double(Net::HTTPResponse, code: status.to_s, body: JSON.generate(body))
    allow(value).to receive(:is_a?).and_return(false)
    allow(value).to receive(:is_a?).with(Net::HTTPSuccess).and_return(status.between?(200, 299))
    value
  end

  def recovery(timeout: 30)
    described_class.new(credentials_path: path, timeout: timeout, http_factory: http_factory, clock: clock)
  end

  it "refreshes native Codex OAuth credentials with identity and expiry metadata" do
    access_token = jwt(account_id: "acct-1")
    allow(http).to receive(:request).and_return(response(body: {
      "access_token" => access_token,
      "id_token" => access_token,
      "refresh_token" => "rotated-refresh"
    }))

    result = recovery.call

    expect(result).to include(account_id: "acct-1", expires_at: now + 3600, auth_mode: :subscription)
    expect(result[:generation]).to match(/\A[0-9a-f]{64}\z/)
    expect(result[:credentials]["tokens"]["refresh_token"]).to eq("rotated-refresh")
    persisted = JSON.parse(File.read(path))
    expect(persisted["native_extra"]).to eq("preserved" => true)
    expect(persisted["auth_mode"]).to eq("chatgpt")
    expect(File.stat(path).mode & 0o777).to eq(0o600)
  end

  it "uses one bounded request with the native public client contract" do
    allow(http).to receive(:request).and_return(response(body: {"access_token" => jwt(account_id: "acct-1")}))

    expect(http).to receive(:open_timeout=).with(10)
    expect(http).to receive(:read_timeout=).with(12)
    expect(http).to receive(:request).once do |request|
      body = JSON.parse(request.body)
      expect(body).to eq(
        "grant_type" => "refresh_token",
        "refresh_token" => "old-refresh",
        "client_id" => described_class::CLIENT_ID
      )
      response(body: {"access_token" => jwt(account_id: "acct-1")})
    end

    recovery(timeout: 12).call
  end

  it "preserves the prior refresh token when the provider does not rotate it" do
    allow(http).to receive(:request).and_return(response(body: {"access_token" => jwt(account_id: "acct-1")}))
    expect(recovery.call[:credentials].dig("tokens", "refresh_token")).to eq("old-refresh")
  end

  it "rejects API-key material without making a request" do
    write_credentials("OPENAI_API_KEY" => "synthetic-key", "tokens" => nil)
    expect(http).not_to receive(:request)
    expect { recovery.call }.to raise_error(AgentHarness::AuthenticationError) { |error|
      expect(error.error_code).to eq(:api_key_credential)
      expect(error.message).not_to include("synthetic-key")
    }
  end

  it "rejects non-managed native auth modes without making a request" do
    write_credentials("auth_mode" => "chatgptAuthTokens")
    expect(http).not_to receive(:request)
    expect { recovery.call }.to raise_error(AgentHarness::AuthenticationError) { |error|
      expect(error.error_code).to eq(:unsupported_auth_mode)
    }
  end

  it "requires an explicitly selected absolute store" do
    expect { described_class.new(credentials_path: "auth.json", http_factory: http_factory) }
      .to raise_error(ArgumentError, /explicit absolute path/)
  end

  it "leaves prior material intact for missing refresh material" do
    write_credentials("tokens" => {"access_token" => "old-access", "account_id" => "acct-1"})
    before = File.binread(path)
    expect { recovery.call }.to raise_error(AgentHarness::AuthenticationError) { |error|
      expect(error.error_code).to eq(:missing_refresh_material)
    }
    expect(File.binread(path)).to eq(before)
  end

  it "classifies rotated, revoked, and expired refresh-token rejection without response leakage" do
    {
      "refresh_token_reused" => :refresh_token_reused,
      "refresh_token_invalidated" => :refresh_token_revoked,
      "refresh_token_expired" => :refresh_token_expired
    }.each do |provider_code, expected|
      allow(http).to receive(:request).and_return(response(status: 401, body: {
        "error" => {"code" => provider_code},
        "secret_detail" => "must-not-leak"
      }))
      expect { recovery.call }.to raise_error(AgentHarness::AuthenticationError) { |error|
        expect(error.error_code).to eq(expected)
        expect(error.message).not_to include(provider_code, "must-not-leak")
      }
    end
  end

  it "classifies malformed and transport replies and leaves the store intact" do
    before = File.binread(path)
    malformed = instance_double(Net::HTTPResponse, code: "200", body: "not-json")
    allow(malformed).to receive(:is_a?).and_return(false)
    allow(malformed).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
    allow(http).to receive(:request).and_return(malformed)
    expect { recovery.call }.to raise_error(AgentHarness::AuthenticationError) { |error|
      expect(error.error_code).to eq(:malformed_response)
    }
    allow(http).to receive(:request).and_raise(Net::ReadTimeout.new("synthetic secret"))
    expect { recovery.call }.to raise_error(AgentHarness::AuthenticationError) { |error|
      expect(error.error_code).to eq(:deadline_exceeded)
      expect(error.message).not_to include("synthetic secret")
    }
    expect(File.binread(path)).to eq(before)
  end

  it "does not persist a successful reply without reliable expiry metadata" do
    before = File.binread(path)
    token = jwt(account_id: "acct-1", expires_at: now + 3600)
    payload = Base64.urlsafe_encode64(JSON.generate(
      "https://api.openai.com/auth" => {"chatgpt_account_id" => "acct-1"}
    ), padding: false)
    allow(http).to receive(:request).and_return(response(body: {
      "access_token" => "header.#{payload}.signature",
      "id_token" => token
    }))

    expect { recovery.call }.to raise_error(AgentHarness::AuthenticationError) { |error|
      expect(error.error_code).to eq(:malformed_response)
    }
    expect(File.binread(path)).to eq(before)
  end

  it "does not overwrite a newer credential generation" do
    replacement = JSON.generate("auth_mode" => "chatgpt", "tokens" => {"refresh_token" => "newer"})
    allow(http).to receive(:request) do
      File.write(path, replacement)
      response(body: {"access_token" => jwt(account_id: "acct-1")})
    end
    expect { recovery.call }.to raise_error(AgentHarness::AuthenticationError) { |error|
      expect(error.error_code).to eq(:credential_generation_changed)
    }
    expect(File.binread(path)).to eq(replacement)
  end

  it "rejects a response for another account without changing the store" do
    before = File.binread(path)
    allow(http).to receive(:request).and_return(response(body: {"access_token" => jwt(account_id: "acct-2")}))
    expect { recovery.call }.to raise_error(AgentHarness::AuthenticationError) { |error|
      expect(error.error_code).to eq(:identity_mismatch)
    }
    expect(File.binread(path)).to eq(before)
  end
  it "requires an authorized account identity in the selected material" do
    write_credentials("tokens" => {
      "id_token" => jwt(account_id: nil, expires_at: now - 60),
      "access_token" => jwt(account_id: nil, expires_at: now - 60),
      "refresh_token" => "old-refresh"
    })
    expect(http).not_to receive(:request)
    expect { recovery.call }.to raise_error(AgentHarness::AuthenticationError) { |error|
      expect(error.error_code).to eq(:missing_account_identity)
    }
  end
end
