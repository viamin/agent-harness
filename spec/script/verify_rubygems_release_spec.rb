# frozen_string_literal: true

require "spec_helper"
require_relative "../../script/verify_rubygems_release"

RSpec.describe AgentHarness::ReleaseVerification::Verifier do
  let(:artifact) do
    AgentHarness::ReleaseVerification::Artifact.new(
      name: "agent-harness", version: "0.46.2", sha256: "c026bd3457a765ab599cb0446dc182f200d7797da4bb817b8ab35ca7d90ef170"
    )
  end
  let(:client) { instance_double(AgentHarness::ReleaseVerification::HttpClient) }
  let(:sleeper) { instance_double(Proc, call: nil) }
  subject(:verifier) { described_class.new(client: client, sleeper: sleeper, api_root: "https://example.test/api") }

  def response(code, body = "")
    Struct.new(:code, :body).new(code.to_s, body)
  end

  def metadata(sha: artifact.sha256, version: artifact.version)
    JSON.generate("version" => version, "sha" => sha)
  end

  it "reproduces the removed private cache method failure without publishing" do
    cache = Class.new.new
    legacy_checker = -> { cache.dependencies }

    expect { legacy_checker.call }.to raise_error(NoMethodError, /dependencies/)
  end

  it "polls a finite number of times while an indexed version propagates" do
    allow(client).to receive(:get).and_return(response(404), response(404), response(200, metadata))

    expect(verifier.verify(artifact, attempts: 3, interval: 0.5)).to include("Verified published", artifact.sha256)
    expect(sleeper).to have_received(:call).with(0.5).twice
  end

  it "reports bounded propagation lag without claiming the artifact is absent" do
    allow(client).to receive(:get).and_return(response(404))

    expect { verifier.verify(artifact, attempts: 2, interval: 0) }
      .to raise_error(AgentHarness::ReleaseVerification::PropagationPending, /may still be propagating/)
  end

  it "fails closed when the immutable published checksum differs" do
    allow(client).to receive(:get).and_return(response(200, metadata(sha: "a" * 64)))

    expect { verifier.verify(artifact, attempts: 1, interval: 0) }
      .to raise_error(AgentHarness::ReleaseVerification::ChecksumMismatch, /already published.*not local/m)
  end

  it "distinguishes public API incompatibility" do
    allow(client).to receive(:get).and_return(response(200, JSON.generate("version" => artifact.version)))

    expect { verifier.verify(artifact, attempts: 1, interval: 0) }
      .to raise_error(AgentHarness::ReleaseVerification::ApiCompatibilityError, /public API schema/)
  end

  [
    nil,
    [],
    "metadata",
    {"version" => "0.46.2", "sha" => nil},
    {"version" => "0.46.2", "sha" => 123},
    {"version" => nil, "sha" => "a" * 64},
    {"version" => 46.2, "sha" => "a" * 64}
  ].each do |malformed_metadata|
    it "reports malformed metadata #{malformed_metadata.inspect} as public API incompatibility" do
      allow(client).to receive(:get).and_return(response(200, JSON.generate(malformed_metadata)))

      expect { verifier.verify(artifact, attempts: 1, interval: 0) }
        .to raise_error(AgentHarness::ReleaseVerification::ApiCompatibilityError, /public API schema/)
    end
  end

  it "distinguishes authentication failures" do
    allow(client).to receive(:get).and_return(response(403))

    expect { verifier.verify(artifact, attempts: 1, interval: 0) }
      .to raise_error(AgentHarness::ReleaseVerification::AuthenticationError, /rejected verification/)
  end

  it "distinguishes transport failures" do
    allow(client).to receive(:get).and_raise(AgentHarness::ReleaseVerification::TransportError, "connection reset")

    expect { verifier.verify(artifact, attempts: 1, interval: 0) }
      .to raise_error(AgentHarness::ReleaseVerification::TransportError, /connection reset/)
  end
end
