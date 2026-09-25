# frozen_string_literal: true

RSpec.describe "AgentHarness embeddings" do
  let(:direct_endpoint) { "https://api.openai.com/v1" }
  let(:proxy_endpoint) { "https://proxy.example/v1" }
  let(:embedding_url) { "#{direct_endpoint}/embeddings" }
  let(:credentials) { {api_key: "tenant-secret"} }

  def fixture(name)
    File.read(File.expand_path("../fixtures/embeddings/#{name}.json", __dir__))
  end

  def embed(inputs: ["first", "second"], **options)
    AgentHarness.embed(
      inputs: inputs,
      model: "text-embedding-3-small",
      credentials: credentials,
      endpoint: direct_endpoint,
      **options
    )
  end

  it "returns an empty result without making an HTTP request" do
    result = embed(inputs: [])

    expect(result.vectors).to eq([])
    expect(result.usage).to eq(input_tokens: nil)
    expect(result.attempts).to eq([])
    expect(a_request(:post, embedding_url)).not_to have_been_made
  end

  it "returns vectors in input order with provider-reported batch usage" do
    stub_request(:post, embedding_url).to_return(body: fixture("success"), headers: {"Content-Type" => "application/json"})

    result = embed(dimensions: 2)

    expect(result.vectors).to eq([[0.1, 0.2], [0.3, 0.4]])
    expect(result.usage).to eq(input_tokens: 7)
    expect(result.per_vector_usage).to be_nil
    expect(result.attempts).to contain_exactly(include(
      attempt_id: start_with("attempt_"), number: 1, provider: :openai,
      status: :succeeded, usage: {input_tokens: 7, output_tokens: nil, total_tokens: 7},
      provider_reported: true, error: nil
    ))
    expect(a_request(:post, embedding_url).with do |request|
      JSON.parse(request.body) == {
        "input" => ["first", "second"], "model" => "text-embedding-3-small", "dimensions" => 2
      }
    end).to have_been_made.once
  end

  it "preserves unknown provider usage" do
    stub_request(:post, embedding_url)
      .to_return(body: fixture("success_without_usage"), headers: {"Content-Type" => "application/json"})

    expect(embed(inputs: ["one"]).usage).to eq(input_tokens: nil)
  end

  it "rejects malformed results rather than returning a partial batch" do
    stub_request(:post, embedding_url).to_return(body: fixture("malformed"), headers: {"Content-Type" => "application/json"})

    expect { embed }.to raise_error(AgentHarness::MalformedEmbeddingError)
  end

  it "rejects duplicate and missing response indices" do
    stub_request(:post, embedding_url)
      .to_return(body: fixture("malformed_indices"), headers: {"Content-Type" => "application/json"})

    expect { embed }.to raise_error(AgentHarness::MalformedEmbeddingError, /indices/)
  end

  it "rejects response rows without integer indices" do
    payloads = [JSON.parse(fixture("success")), JSON.parse(fixture("success"))]
    payloads.first["data"].first.delete("index")
    payloads.last["data"].first["index"] = "1"

    payloads.each do |payload|
      stub_request(:post, embedding_url)
        .to_return(body: JSON.generate(payload), headers: {"Content-Type" => "application/json"})

      expect { embed }.to raise_error(AgentHarness::MalformedEmbeddingError, /indices/)
    end
  end

  it "uses request-local credentials, custom endpoints, and extra headers" do
    proxy_url = "#{proxy_endpoint}/embeddings"
    request = stub_request(:post, proxy_url)
      .with(headers: {"Authorization" => "Bearer proxy-secret", "X-Tenant" => "tenant-42"})
      .to_return(body: fixture("success_without_usage"), headers: {"Content-Type" => "application/json"})

    result = AgentHarness.embed(
      inputs: ["one"], model: "text-embedding-3-small",
      credentials: {api_key: "proxy-secret"}, endpoint: proxy_endpoint,
      headers: {"X-Tenant" => "tenant-42"}
    )

    expect(result.vectors).to eq([[0.1, 0.2]])
    expect(request).to have_been_requested.once
    expect(RubyLLM.config.openai_api_key).to be_nil
  end

  it "isolates credentials across concurrent requests" do
    request = stub_request(:post, embedding_url)
      .with { |http_request| %w[Bearer\ tenant-a Bearer\ tenant-b].include?(http_request.headers["Authorization"]) }
      .to_return(body: fixture("success_without_usage"), headers: {"Content-Type" => "application/json"})

    threads = %w[tenant-a tenant-b].map do |api_key|
      Thread.new do
        AgentHarness.embed(
          inputs: [api_key], model: "text-embedding-3-small",
          credentials: {api_key: api_key}, endpoint: direct_endpoint
        )
      end
    end

    expect(threads.map(&:value).map(&:vectors)).to eq([[[0.1, 0.2]], [[0.1, 0.2]]])
    expect(request).to have_been_requested.twice
    expect(RubyLLM.config.openai_api_key).to be_nil
  end

  it "does not allow extra headers to override explicit credentials" do
    expect do
      embed(headers: {"authorization" => "Bearer another-secret"})
    end.to raise_error(ArgumentError, /Authorization/)
  end

  it "validates attempt reporting options before making a request" do
    expect { embed(request_id: "") }.to raise_error(ArgumentError, /request_id/)
    expect { embed(observer: Object.new) }.to raise_error(ArgumentError, /observer/)
    expect(a_request(:post, embedding_url)).not_to have_been_made
  end

  it "classifies HTTP 401 as authentication failure without retrying" do
    request = stub_request(:post, embedding_url)
      .to_return(status: 401, body: '{"error":{"message":"denied"}}', headers: {"Content-Type" => "application/json"})

    expect { embed(max_attempts: 3) }.to raise_error(AgentHarness::AuthenticationError) do |error|
      expect([error.error_category, error.error_code]).to eq([:authentication, :invalid_credential])
    end
    expect(request).to have_been_requested.once
  end

  it "classifies HTTP 403 as authorization failure without retrying" do
    request = stub_request(:post, embedding_url)
      .to_return(status: 403, body: '{"error":{"message":"denied"}}', headers: {"Content-Type" => "application/json"})

    expect { embed(max_attempts: 3) }.to raise_error(AgentHarness::AuthorizationError) do |error|
      expect([error.error_category, error.error_code]).to eq([:authorization, :permission_denied])
    end
    expect(request).to have_been_requested.once
  end

  it "classifies other provider response errors as provider failures" do
    stub_request(:post, embedding_url)
      .to_return(status: 404, body: '{"error":{"message":"unknown model"}}', headers: {"Content-Type" => "application/json"})

    expect { embed(max_attempts: 1) }.to raise_error(AgentHarness::ProviderError) do |error|
      expect(error.original_error).to be_a(RubyLLM::Error)
    end
  end

  it "honors Retry-After and bounds rate-limit retries" do
    request = stub_request(:post, embedding_url)
      .to_return(status: 429, body: '{"error":{"message":"slow down"}}', headers: {"Retry-After" => "0"})

    expect { embed(max_attempts: 2) }.to raise_error(AgentHarness::RateLimitError)
    expect(request).to have_been_requested.twice
  end

  it "converts Retry-After seconds to an absolute reset time" do
    now = Time.utc(2026, 9, 25, 12)
    allow(Time).to receive(:now).and_return(now)
    stub_request(:post, embedding_url)
      .to_return(status: 429, body: '{"error":{"message":"slow down"}}', headers: {"Retry-After" => "60"})

    expect { embed(max_attempts: 1) }.to raise_error(AgentHarness::RateLimitError) do |error|
      expect(error.reset_time).to eq(now + 60)
    end
  end

  it "preserves provider Retry-After delays above the backoff cap" do
    now = Time.utc(2026, 9, 25, 12)
    allow(Time).to receive(:now).and_return(now)
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(100, 159, 160)
    expect_any_instance_of(AgentHarness::Embeddings).to receive(:sleep).with(0.05).once
    stub_request(:post, embedding_url)
      .to_return(
        {status: 429, body: '{"error":{"message":"slow down"}}', headers: {"Retry-After" => "60"}},
        {body: fixture("success"), headers: {"Content-Type" => "application/json"}}
      )

    expect(embed(max_attempts: 2).vectors).to eq([[0.1, 0.2], [0.3, 0.4]])
  end

  it "uses an HTTP-date Retry-After value as the absolute reset time" do
    reset_time = Time.utc(2026, 9, 25, 12, 1)
    stub_request(:post, embedding_url)
      .to_return(status: 429, body: '{"error":{"message":"slow down"}}', headers: {"Retry-After" => reset_time.httpdate})

    expect { embed(max_attempts: 1) }.to raise_error(AgentHarness::RateLimitError) do |error|
      expect(error.reset_time).to eq(reset_time)
    end
  end

  it "classifies timeouts after bounded retries" do
    request = stub_request(:post, embedding_url).to_timeout

    expect { embed(timeout: 0.01, max_attempts: 2) }.to raise_error(AgentHarness::TimeoutError)
    expect(request).to have_been_requested.twice
  end

  it "retries transient server failures up to the supplied bound" do
    request = stub_request(:post, embedding_url)
      .to_return({status: 503}, {body: fixture("success"), headers: {"Content-Type" => "application/json"}})

    reports = []
    result = embed(max_attempts: 2, request_id: "embedding-request", observer: ->(report) { reports << report })

    expect(result.vectors).to eq([[0.1, 0.2], [0.3, 0.4]])
    expect(result.attempts).to eq(reports)
    expect(reports.map { |report| report[:status] }).to eq([:failed, :succeeded])
    expect(reports.map { |report| report[:number] }).to eq([1, 2])
    expect(reports.map { |report| report[:request_id] }).to eq(%w[embedding-request embedding-request])
    expect(reports.map { |report| report[:attempt_id] }.uniq.length).to eq(2)
    expect(reports.first[:error]).to eq(category: :transient, code: :service_unavailable)
    expect(request).to have_been_requested.twice
  end

  it "reports terminal failed attempts to the observer" do
    reports = []
    stub_request(:post, embedding_url)
      .to_return(status: 401, body: '{"error":{"message":"denied"}}', headers: {"Content-Type" => "application/json"})

    expect { embed(observer: ->(report) { reports << report }) }.to raise_error(AgentHarness::AuthenticationError)
    expect(reports).to contain_exactly(include(
      status: :failed, error: {category: :authentication, code: :invalid_credential}
    ))
  end

  it "stops before a cancelled attempt" do
    cancelled = false
    request = stub_request(:post, embedding_url).to_return do
      cancelled = true
      {status: 503}
    end

    expect { embed(max_attempts: 3, cancellation: -> { cancelled }) }
      .to raise_error(AgentHarness::CancelledError)
    expect(request).to have_been_requested.once
  end
end
