# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "tmpdir"

RSpec.describe "Codex managed credential recovery" do
  let(:tmp_dir) { Dir.mktmpdir }
  let(:credential_path) { File.join(tmp_dir, "auth.json") }
  let(:account_id) { "acct-selected" }
  let(:expires_at) { Time.now.to_i - 60 }

  after { FileUtils.rm_rf(tmp_dir) }

  def jwt(claims)
    payload = Base64.urlsafe_encode64(JSON.generate(claims), padding: false)
    "header.#{payload}.signature"
  end

  def jwt_payload(json)
    payload = Base64.urlsafe_encode64(json, padding: false)
    "header.#{payload}.signature"
  end

  def native_credentials(refresh_token: "refresh-old", access_token: nil)
    access_token ||= jwt("exp" => expires_at, "https://api.openai.com/auth" => {
      "chatgpt_account_id" => account_id,
      "chatgpt_plan_type" => "plus"
    })
    {
      "auth_mode" => "chatgpt",
      "OPENAI_API_KEY" => nil,
      "tokens" => {
        "id_token" => jwt("https://api.openai.com/auth" => {"chatgpt_account_id" => account_id}),
        "access_token" => access_token,
        "refresh_token" => refresh_token,
        "account_id" => account_id
      },
      "last_refresh" => "2026-11-20T00:00:00Z",
      "caller_metadata" => {"lease" => "preserve-me"}
    }
  end

  def write_credentials(credentials = native_credentials)
    File.write(credential_path, JSON.generate(credentials))
    File.chmod(0o600, credential_path)
  end

  def generation
    Digest::SHA256.file(credential_path).hexdigest
  end

  def stub_exchange(status: 200, body: nil, raw_body: nil)
    body ||= {
      "access_token" => jwt("exp" => Time.now.to_i + 3600, "https://api.openai.com/auth" => {
        "chatgpt_account_id" => account_id,
        "chatgpt_plan_type" => "plus"
      }),
      "id_token" => jwt("https://api.openai.com/auth" => {"chatgpt_account_id" => account_id}),
      "refresh_token" => "refresh-rotated"
    }
    response = instance_double(Net::HTTPResponse, code: status.to_s, body: raw_body || JSON.generate(body))
    allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(status.between?(200, 299))
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:write_timeout=)
    allow(http).to receive(:request).and_return(response)
    http
  end

  it "advertises only the implemented explicit Codex exchange" do
    expect(AgentHarness.auth_capabilities(:codex)).to include(
      auth_type: :api_key,
      exchange: true,
      managed_oauth_recovery: true,
      auth_url: false,
      exchange_code: false,
      refresh: false
    )
    expect(AgentHarness.exchange_refresh_token_supported?(:codex)).to be true
    expect(AgentHarness.exchange_refresh_token_supported?(:aider)).to be false
  end

  it "inspects explicitly selected native material without exposing tokens" do
    write_credentials

    metadata = AgentHarness.credential_metadata(:codex, credential_path: credential_path)

    expect(metadata).to include(
      provider: :codex,
      billing_mode: :chatgpt_subscription,
      account_id: account_id,
      expires_at: Time.at(expires_at).utc,
      expired: true,
      refreshable: true,
      generation: generation
    )
    expect(metadata.to_s).not_to include("refresh-old")
  end

  it "classifies malformed selected material without exposing its body" do
    File.write(credential_path, "{refresh-old")

    expect {
      AgentHarness.credential_metadata(:codex, credential_path: credential_path)
    }.to raise_error(AgentHarness::AuthenticationError) { |error|
      expect(error.error_code).to eq(:invalid_native_credentials)
      expect(error.message).not_to include("refresh-old")
    }
  end

  [nil, false, [], {"https://api.openai.com/auth" => "invalid"}].each do |claims|
    it "safely inspects a #{claims.class} JWT payload" do
      write_credentials(native_credentials(access_token: jwt(claims)))

      metadata = AgentHarness.credential_metadata(:codex, credential_path: credential_path)

      expect(metadata).to include(expires_at: nil, expired: nil)
    end
  end

  ["1e999", (10**100).to_s].each do |expiry|
    it "safely inspects an unusable numeric expiry" do
      claims = %({"exp":#{expiry},"https://api.openai.com/auth":{"chatgpt_account_id":"#{account_id}"}})
      write_credentials(native_credentials(access_token: jwt_payload(claims)))

      metadata = AgentHarness.credential_metadata(:codex, credential_path: credential_path)

      expect(metadata).to include(expires_at: nil, expired: nil)
    end
  end

  it "atomically preserves native shape and rotated reusable material" do
    write_credentials
    original_generation = generation
    http = stub_exchange

    expect(http).to receive(:request) do |request|
      expect(JSON.parse(request.body)).to eq(
        "grant_type" => "refresh_token",
        "refresh_token" => "refresh-old",
        "client_id" => "app_EMoamEEZ73f0CkXaXp7hrann",
        "refresh_reason" => "unauthorized"
      )
      instance_double(Net::HTTPResponse, code: "200", body: JSON.generate({
        "access_token" => jwt("exp" => Time.now.to_i + 3600, "https://api.openai.com/auth" => {
          "chatgpt_account_id" => account_id,
          "chatgpt_plan_type" => "plus"
        }),
        "refresh_token" => "refresh-rotated"
      })).tap { |response| allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true) }
    end

    result = AgentHarness.exchange_refresh_token(
      :codex,
      credential_path: credential_path,
      expected_generation: original_generation,
      expected_account_id: account_id,
      timeout: 2
    )

    stored = JSON.parse(File.read(credential_path))
    expect(stored.dig("tokens", "refresh_token")).to eq("refresh-rotated")
    expect(stored.dig("tokens", "id_token")).to eq(native_credentials.dig("tokens", "id_token"))
    expect(stored.dig("tokens", "account_id")).to eq(account_id)
    expect(stored["caller_metadata"]).to eq("lease" => "preserve-me")
    expect(stored["auth_mode"]).to eq("chatgpt")
    expect(File.stat(credential_path).mode & 0o777).to eq(0o600)
    expect(result[:credentials]).to eq(stored)
    expect(result[:metadata]).to include(account_id: account_id, expired: false, refreshable: true)
    expect(result[:metadata][:generation]).not_to eq(original_generation)
    expect(result[:metadata][:generation]).to eq(generation)
  end

  it "rejects API-key material without contacting the provider" do
    write_credentials("auth_mode" => "apikey", "OPENAI_API_KEY" => "synthetic-key")

    expect(Net::HTTP).not_to receive(:new)
    expect {
      AgentHarness.exchange_refresh_token(
        :codex,
        credential_path: credential_path,
        expected_generation: generation,
        expected_account_id: account_id
      )
    }.to raise_error(AgentHarness::AuthenticationError) { |error|
      expect(error.error_code).to eq(:unsupported_credential_type)
      expect(error.message).not_to include("synthetic-key")
    }
  end

  it "classifies missing refresh material without contacting the provider" do
    write_credentials(native_credentials(refresh_token: ""))

    expect(Net::HTTP).not_to receive(:new)
    expect {
      AgentHarness.exchange_refresh_token(
        :codex,
        credential_path: credential_path,
        expected_generation: generation,
        expected_account_id: account_id
      )
    }.to raise_error(AgentHarness::AuthenticationError) { |error|
      expect(error.error_code).to eq(:missing_refresh_material)
    }
  end

  it "rejects unapproved OAuth provenance without contacting its authority" do
    credentials = native_credentials
    credentials.fetch("tokens")["oauth_provenance"] = {
      "issuer" => "https://attacker.example",
      "client_id" => "untrusted-client"
    }
    write_credentials(credentials)

    expect(Net::HTTP).not_to receive(:new)
    expect {
      AgentHarness.exchange_refresh_token(
        :codex,
        credential_path: credential_path,
        expected_generation: generation,
        expected_account_id: account_id
      )
    }.to raise_error(AgentHarness::AuthenticationError) { |error|
      expect(error.error_code).to eq(:invalid_native_credentials)
      expect(error.message).not_to include("attacker.example", "untrusted-client")
    }
  end

  it "does not overwrite a newer generation after exchange" do
    write_credentials
    selected_generation = generation
    http = stub_exchange
    expect(http).to receive(:request) do
      File.write(credential_path, JSON.generate(native_credentials(refresh_token: "newer-refresh")))
      response = instance_double(Net::HTTPResponse, code: "200", body: JSON.generate({
        "access_token" => jwt("exp" => Time.now.to_i + 3600, "https://api.openai.com/auth" => {
          "chatgpt_account_id" => account_id
        })
      }))
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      response
    end

    expect {
      AgentHarness.exchange_refresh_token(
        :codex,
        credential_path: credential_path,
        expected_generation: selected_generation,
        expected_account_id: account_id
      )
    }.to raise_error(AgentHarness::AuthenticationError) { |error|
      expect(error.error_code).to eq(:concurrent_update)
    }
    expect(JSON.parse(File.read(credential_path)).dig("tokens", "refresh_token")).to eq("newer-refresh")
  end

  it "rechecks the generation at the atomic commit boundary" do
    write_credentials
    selected_generation = generation
    newer = native_credentials(refresh_token: "newer-refresh")
    stub_exchange
    original_chmod = File.method(:chmod)
    allow(File).to receive(:chmod).and_call_original
    expect(File).to receive(:chmod).with(0o600, a_string_matching(/\.auth/)) do |mode, path|
      File.write(credential_path, JSON.generate(newer))
      original_chmod.call(mode, path)
    end

    expect {
      AgentHarness.exchange_refresh_token(
        :codex,
        credential_path: credential_path,
        expected_generation: selected_generation,
        expected_account_id: account_id
      )
    }.to raise_error(AgentHarness::AuthenticationError) { |error|
      expect(error.error_code).to eq(:concurrent_update)
    }
    expect(JSON.parse(File.read(credential_path)).dig("tokens", "refresh_token")).to eq("newer-refresh")
  end

  it "restores an in-place write that enters immediately before the rename" do
    write_credentials
    selected_generation = generation
    newer = native_credentials(refresh_token: "newer-refresh")
    newer_bytes = JSON.generate(newer)
    stub_exchange
    original_rename = File.method(:rename)
    injected = false
    allow(File).to receive(:rename).and_call_original
    allow(File).to receive(:rename) do |source, destination|
      if !injected && File.basename(source).start_with?(".auth") && !File.basename(source).start_with?(".auth-snapshot")
        injected = true
        File.write(credential_path, newer_bytes)
      end
      original_rename.call(source, destination)
    end

    expect {
      AgentHarness.exchange_refresh_token(
        :codex,
        credential_path: credential_path,
        expected_generation: selected_generation,
        expected_account_id: account_id
      )
    }.to raise_error(AgentHarness::AuthenticationError) { |error|
      expect(error.error_code).to eq(:concurrent_update)
    }
    expect(injected).to be true
    expect(File.binread(credential_path)).to eq(newer_bytes)
  end

  {
    "refresh_token_expired" => :refresh_token_expired,
    "refresh_token_reused" => :refresh_token_reused,
    "refresh_token_invalidated" => :refresh_token_revoked,
    "invalid_grant" => :invalid_refresh_token
  }.each do |provider_code, category|
    it "classifies #{provider_code} without leaking the provider response" do
      write_credentials
      before = File.binread(credential_path)
      stub_exchange(status: 400, body: {
        "error" => provider_code,
        "error_description" => "secret response refresh-old"
      })

      expect {
        AgentHarness.exchange_refresh_token(
          :codex,
          credential_path: credential_path,
          expected_generation: generation,
          expected_account_id: account_id
        )
      }.to raise_error(AgentHarness::AuthenticationError) { |error|
        expect(error.error_code).to eq(category)
        expect(error.message).not_to include("secret response", "refresh-old", provider_code)
      }
      expect(File.binread(credential_path)).to eq(before)
    end
  end

  {
    "refresh_token_expired" => :refresh_token_expired,
    "refresh_token_reused" => :refresh_token_reused,
    "refresh_token_invalidated" => :refresh_token_revoked
  }.each do |provider_code, category|
    it "classifies nested #{provider_code} without leaking the provider response" do
      write_credentials
      before = File.binread(credential_path)
      stub_exchange(status: 400, body: {
        "error" => {"code" => provider_code, "message" => "secret response refresh-old"}
      })

      expect {
        AgentHarness.exchange_refresh_token(
          :codex,
          credential_path: credential_path,
          expected_generation: generation,
          expected_account_id: account_id
        )
      }.to raise_error(AgentHarness::AuthenticationError) { |error|
        expect(error.error_code).to eq(category)
        expect(error.message).not_to include("secret response", "refresh-old", provider_code)
      }
      expect(File.binread(credential_path)).to eq(before)
    end
  end

  it "rejects malformed success replies and leaves prior material intact" do
    write_credentials
    before = File.binread(credential_path)
    stub_exchange(body: {"refresh_token" => "rotated-without-access"})

    expect {
      AgentHarness.exchange_refresh_token(
        :codex,
        credential_path: credential_path,
        expected_generation: generation,
        expected_account_id: account_id
      )
    }.to raise_error(AgentHarness::AuthenticationError) { |error|
      expect(error.error_code).to eq(:malformed_response)
      expect(error.message).not_to include("rotated-without-access")
    }
    expect(File.binread(credential_path)).to eq(before)
  end

  it "classifies a non-JSON failure reply as provider rejection" do
    write_credentials
    before = File.binread(credential_path)
    stub_exchange(status: 502, raw_body: "<html>secret refresh-old</html>")

    expect {
      AgentHarness.exchange_refresh_token(
        :codex,
        credential_path: credential_path,
        expected_generation: generation,
        expected_account_id: account_id
      )
    }.to raise_error(AgentHarness::AuthenticationError) { |error|
      expect(error.error_code).to eq(:provider_rejected)
      expect(error.message).not_to include("secret", "refresh-old")
    }
    expect(File.binread(credential_path)).to eq(before)
  end

  it "rejects an identity change and leaves prior material intact" do
    write_credentials
    before = File.binread(credential_path)
    stub_exchange(body: {
      "access_token" => jwt("exp" => Time.now.to_i + 3600, "https://api.openai.com/auth" => {
        "chatgpt_account_id" => "different-account"
      })
    })

    expect {
      AgentHarness.exchange_refresh_token(
        :codex,
        credential_path: credential_path,
        expected_generation: generation,
        expected_account_id: account_id
      )
    }.to raise_error(AgentHarness::AuthenticationError) { |error|
      expect(error.error_code).to eq(:identity_mismatch)
    }
    expect(File.binread(credential_path)).to eq(before)
  end

  it "classifies transport failures without exposing exception details" do
    write_credentials
    before = File.binread(credential_path)
    http = stub_exchange
    allow(http).to receive(:request).and_raise(Errno::ECONNRESET, "synthetic refresh-old")

    expect {
      AgentHarness.exchange_refresh_token(
        :codex,
        credential_path: credential_path,
        expected_generation: generation,
        expected_account_id: account_id
      )
    }.to raise_error(AgentHarness::AuthenticationError) { |error|
      expect(error.error_code).to eq(:transport_failure)
      expect(error.message).not_to include("synthetic", "refresh-old")
    }
    expect(File.binread(credential_path)).to eq(before)
  end

  it "classifies TLS failures without exposing exception details" do
    write_credentials
    before = File.binread(credential_path)
    http = stub_exchange
    allow(http).to receive(:request).and_raise(OpenSSL::SSL::SSLError, "certificate secret refresh-old")

    expect {
      AgentHarness.exchange_refresh_token(
        :codex,
        credential_path: credential_path,
        expected_generation: generation,
        expected_account_id: account_id
      )
    }.to raise_error(AgentHarness::AuthenticationError) { |error|
      expect(error.error_code).to eq(:transport_failure)
      expect(error.message).not_to include("certificate", "secret", "refresh-old")
    }
    expect(File.binread(credential_path)).to eq(before)
  end

  it "classifies a deadline without changing prior material" do
    write_credentials
    before = File.binread(credential_path)
    http = stub_exchange
    allow(http).to receive(:request).and_raise(Timeout::Error)

    expect {
      AgentHarness.exchange_refresh_token(
        :codex,
        credential_path: credential_path,
        expected_generation: generation,
        expected_account_id: account_id,
        timeout: 1
      )
    }.to raise_error(AgentHarness::AuthenticationError) { |error|
      expect(error.error_code).to eq(:deadline_exceeded)
    }
    expect(File.binread(credential_path)).to eq(before)
  end

  it "bounds lock contention with the recovery deadline" do
    write_credentials
    before = File.binread(credential_path)

    File.open("#{credential_path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect {
        AgentHarness.exchange_refresh_token(
          :codex,
          credential_path: credential_path,
          expected_generation: generation,
          expected_account_id: account_id,
          timeout: 0.02
        )
      }.to raise_error(AgentHarness::AuthenticationError) { |error|
        expect(error.error_code).to eq(:deadline_exceeded)
      }
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at).to be < 0.5
    end
    expect(File.binread(credential_path)).to eq(before)
  end

  [nil, false, [], {"https://api.openai.com/auth" => "invalid"}].each do |claims|
    it "rejects a #{claims.class} refreshed JWT payload without changing credentials" do
      write_credentials
      before = File.binread(credential_path)
      stub_exchange(body: {"access_token" => jwt(claims)})

      expect {
        AgentHarness.exchange_refresh_token(
          :codex,
          credential_path: credential_path,
          expected_generation: generation,
          expected_account_id: account_id
        )
      }.to raise_error(AgentHarness::AuthenticationError) { |error|
        expect(error.error_code).to eq(:malformed_response)
      }
      expect(File.binread(credential_path)).to eq(before)
    end
  end

  ["1e999", (10**100).to_s].each do |expiry|
    it "rejects an unusable refreshed numeric expiry without changing credentials" do
      write_credentials
      before = File.binread(credential_path)
      claims = %({"exp":#{expiry},"https://api.openai.com/auth":{"chatgpt_account_id":"#{account_id}"}})
      stub_exchange(body: {"access_token" => jwt_payload(claims)})

      expect {
        AgentHarness.exchange_refresh_token(
          :codex,
          credential_path: credential_path,
          expected_generation: generation,
          expected_account_id: account_id
        )
      }.to raise_error(AgentHarness::AuthenticationError) { |error|
        expect(error.error_code).to eq(:malformed_response)
      }
      expect(File.binread(credential_path)).to eq(before)
    end
  end

  it "requires an explicit path, generation, identity, and finite deadline" do
    expect {
      AgentHarness.exchange_refresh_token(:codex)
    }.to raise_error(ArgumentError, /credential_path/)

    write_credentials
    expect {
      AgentHarness.exchange_refresh_token(
        :codex,
        credential_path: credential_path,
        expected_generation: generation,
        expected_account_id: account_id,
        timeout: 0
      )
    }.to raise_error(ArgumentError, /timeout/)
  end
end
