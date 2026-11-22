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

  # Mocked HTTP whose successful reply lands only after +delay+ seconds, so the
  # recovery deadline expires mid-request without any live refresh material.
  def stub_delayed_exchange(delay:)
    http = stub_exchange
    response = http.request(nil)
    allow(http).to receive(:request) do
      sleep(delay)
      response
    end
    http
  end

  # Hold the real adjacent lock, releasing it after +after+ seconds so the
  # recovery spends part of its budget waiting on genuine lock contention.
  def hold_lock_then_release(after:)
    lock = File.open("#{credential_path}.lock", File::RDWR | File::CREAT, 0o600)
    lock.flock(File::LOCK_EX)
    Thread.new do
      sleep(after)
      lock.flock(File::LOCK_UN)
      lock.close
    end
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

  it "returns the committed result when the deadline fires immediately after rename" do
    write_credentials
    selected_generation = generation
    stub_exchange
    original_rename = File.method(:rename)
    timeout_injected = false
    allow(File).to receive(:rename).and_call_original
    allow(File).to receive(:rename) do |source, destination|
      original_rename.call(source, destination).tap do
        next unless destination == credential_path && !timeout_injected

        timeout_injected = true
        Thread.current.raise(Timeout::Error)
      end
    end

    result = AgentHarness.exchange_refresh_token(
      :codex,
      credential_path: credential_path,
      expected_generation: selected_generation,
      expected_account_id: account_id
    )

    expect(timeout_injected).to be true
    expect(result[:metadata][:generation]).to eq(generation)
    expect(result[:credentials]).to eq(JSON.parse(File.read(credential_path)))
    expect(result.dig(:credentials, "tokens", "refresh_token")).to eq("refresh-rotated")
  end

  it "returns the committed result when a bare caller watchdog fires after rename" do
    write_credentials
    selected_generation = generation
    stub_exchange
    original_rename = File.method(:rename)
    rename_completed = false
    allow(File).to receive(:rename).and_call_original
    allow(File).to receive(:rename) do |source, destination|
      original_rename.call(source, destination).tap do
        next unless destination == credential_path

        rename_completed = true
        sleep(0.18)
      end
    end

    result = Timeout.timeout(0.1) do
      AgentHarness.exchange_refresh_token(
        :codex,
        credential_path: credential_path,
        expected_generation: selected_generation,
        expected_account_id: account_id,
        timeout: 1
      )
    end

    expect(rename_completed).to be true
    expect(result[:metadata][:generation]).to eq(generation)
    expect(result[:credentials]).to eq(JSON.parse(File.read(credential_path)))
    expect(result.dig(:credentials, "tokens", "refresh_token")).to eq("refresh-rotated")
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

  [Net::OpenTimeout, Net::ReadTimeout].each do |timeout_class|
    it "classifies #{timeout_class} as a transport failure" do
      write_credentials
      before = File.binread(credential_path)
      http = stub_exchange
      allow(http).to receive(:request).and_raise(timeout_class, "synthetic refresh-old")

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

  it "preserves a bare caller cancellation before commit and releases the lock" do
    write_credentials
    before = File.binread(credential_path)

    File.open("#{credential_path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      expect {
        Timeout.timeout(0.02) do
          AgentHarness.exchange_refresh_token(
            :codex,
            credential_path: credential_path,
            expected_generation: generation,
            expected_account_id: account_id,
            timeout: 1
          )
        end
      }.to raise_error(Timeout::Error, /execution expired/)
    end

    expect(File.binread(credential_path)).to eq(before)
    File.open("#{credential_path}.lock", File::RDWR | File::CREAT, 0o600) do |probe|
      expect(probe.flock(File::LOCK_EX | File::LOCK_NB)).to be_truthy
    end
  end

  it "yields a typed deadline error, never a leaked Timeout::ExitException, when lock release and HTTP both outlast the budget" do
    write_credentials
    before = File.binread(credential_path)
    stub_delayed_exchange(delay: 0.08)
    releaser = hold_lock_then_release(after: 0.06)

    begin
      expect {
        AgentHarness.exchange_refresh_token(
          :codex,
          credential_path: credential_path,
          expected_generation: generation,
          expected_account_id: account_id,
          timeout: 0.1
        )
      }.to raise_error(AgentHarness::AuthenticationError) { |error|
        expect(error.error_code).to eq(:deadline_exceeded)
        serialized = "#{error.message} #{error.context.inspect}"
        expect(serialized).not_to include("refresh-old")
        expect(serialized).not_to include("refresh-rotated")
      }
    ensure
      releaser.join
    end

    expect(File.binread(credential_path)).to eq(before)
  end

  it "yields a typed deadline error for the combined-delay case under a longer caller watchdog" do
    write_credentials
    before = File.binread(credential_path)
    stub_delayed_exchange(delay: 0.08)
    releaser = hold_lock_then_release(after: 0.06)

    begin
      expect {
        Timeout.timeout(5, Timeout::Error) do
          AgentHarness.exchange_refresh_token(
            :codex,
            credential_path: credential_path,
            expected_generation: generation,
            expected_account_id: account_id,
            timeout: 0.1
          )
        end
      }.to raise_error(AgentHarness::AuthenticationError) { |error|
        expect(error.error_code).to eq(:deadline_exceeded)
      }
    ensure
      releaser.join
    end

    expect(File.binread(credential_path)).to eq(before)
  end

  it "returns the committed result and releases the lock when a bare caller watchdog fires during lock cleanup" do
    write_credentials
    original_generation = generation
    stub_delayed_exchange(delay: 0.05)
    releaser = hold_lock_then_release(after: 0.05)

    # Slow only the recovery's lock-file close so the longer bare caller
    # deadline (Timeout.timeout(5), which interrupts with Timeout::ExitException)
    # provably fires while that close is in progress.
    original_open = File.method(:open)
    interception_armed = true
    lock_closed = false
    allow(File).to receive(:open) do |path, *rest, **kwargs, &block|
      if interception_armed && block && path == "#{credential_path}.lock"
        original_open.call(path, *rest, **kwargs) do |lock|
          allow(lock).to receive(:close).and_wrap_original do |close|
            sleep(5.3)
            close.call
            lock_closed = true
          end
          block.call(lock)
        end
      else
        original_open.call(path, *rest, **kwargs, &block)
      end
    end

    # A stranded lock descriptor is only finalized by GC, so keep GC from
    # masking an unreleased flock until the promptness probe has run.
    gc_was_disabled = GC.disable
    begin
      committed_result = Timeout.timeout(5) do
        AgentHarness.exchange_refresh_token(
          :codex,
          credential_path: credential_path,
          expected_generation: original_generation,
          expected_account_id: account_id,
          timeout: 7
        )
      end

      interception_armed = false
      expect(lock_closed).to be true
      expect(committed_result.dig(:credentials, "tokens", "refresh_token")).to eq("refresh-rotated")
      expect(committed_result[:metadata][:generation]).to eq(generation)
      prompt = File.open("#{credential_path}.lock", File::RDWR | File::CREAT, 0o600) do |probe|
        probe.flock(File::LOCK_EX | File::LOCK_NB)
      end
      expect(prompt).to be_truthy
    ensure
      GC.enable unless gc_was_disabled
      interception_armed = false
      releaser.join
    end

    stored = JSON.parse(File.binread(credential_path))
    expect(stored.dig("tokens", "refresh_token")).to eq("refresh-rotated")
    expect(stored.dig("tokens", "account_id")).to eq(account_id)
    expect(stored["caller_metadata"]).to eq("lease" => "preserve-me")
    expect(stored["auth_mode"]).to eq("chatgpt")

    resumed_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = AgentHarness.exchange_refresh_token(
      :codex,
      credential_path: credential_path,
      expected_generation: generation,
      expected_account_id: account_id,
      timeout: 2
    )
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - resumed_at).to be < 1.5
    expect(result[:credentials].dig("tokens", "refresh_token")).to eq("refresh-rotated")
    expect(result[:metadata][:generation]).to eq(generation)
  end

  it "rejects a blocking non-regular credential path within the recovery deadline" do
    File.mkfifo(credential_path, 0o600)

    expect(Net::HTTP).not_to receive(:new)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect {
      AgentHarness.exchange_refresh_token(
        :codex,
        credential_path: credential_path,
        expected_generation: "0" * 64,
        expected_account_id: account_id,
        timeout: 0.02
      )
    }.to raise_error(AgentHarness::AuthenticationError) { |error|
      expect(error.error_code).to eq(:invalid_native_credentials)
    }
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at).to be < 0.5
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
