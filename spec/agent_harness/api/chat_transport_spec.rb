# frozen_string_literal: true

require "spec_helper"

RSpec.describe AgentHarness::Api::ChatTransport do
  subject(:transport) do
    described_class.new(adapter: adapter, id_generator: id_generator, sleeper: ->(_seconds) {})
  end

  let(:adapter) { instance_double(AgentHarness::Api::RubyLlmChatAdapter) }
  let(:generated_ids) { %w[attempt-1 tool-1 tool-2 attempt-2] }
  let(:id_generator) { -> { generated_ids.shift } }
  let(:candidate) do
    {
      provider: :anthropic,
      model: "claude-test",
      protocol: :messages,
      authentication_mode: :api_key,
      credentials: {api_key: "secret-a"}
    }
  end
  let(:request) do
    {
      request_id: "request-1",
      operation: :chat,
      candidates: [candidate],
      messages: [
        {id: "system-1", role: :system, content: [{type: :text, text: "Be concise"}]},
        {id: "user-1", role: :user, content: [{type: :text, text: "Hello"}]}
      ],
      tools: [],
      retry: {max_attempts: 1}
    }
  end

  before do
    allow(adapter).to receive(:call)
  end

  it "returns normalized content, usage, and multiple tool calls" do
    allow(adapter).to receive(:call).and_return(
      content: "",
      model: "claude-test",
      finish_reason: :tool_calls,
      usage: {input_tokens: 12, output_tokens: 4, total_tokens: 16},
      tool_calls: [
        {provider_id: "call-a", name: "first", arguments_json: '{"x":1}'},
        {provider_id: "call-b", name: "second", arguments_json: '{"y":2}'}
      ]
    )

    result = transport.call(request)

    expect(result).to include(status: :succeeded, content: "", finish_reason: :tool_calls)
    expect(result[:tool_calls]).to eq([
      {id: "tool-1", provider_id: "call-a", name: "first", arguments_json: '{"x":1}', status: :completed},
      {id: "tool-2", provider_id: "call-b", name: "second", arguments_json: '{"y":2}', status: :completed}
    ])
    expect(result[:usage]).to eq(input_tokens: 12, output_tokens: 4, total_tokens: 16)
    expect(result[:attempts]).to contain_exactly(hash_including(
      usage: {input_tokens: 12, output_tokens: 4, total_tokens: 16},
      cost: nil, provider_reported: true
    ))
  end

  it "emits ordered text and exactly one explicit completion event" do
    events = []
    allow(adapter).to receive(:call) do |**args, &stream|
      stream.call(type: :text_delta, content: "hel")
      stream.call(type: :text_delta, content: "lo")
      {content: "hello", model: "claude-test", finish_reason: :stop, usage: nil, tool_calls: []}
    end

    result = transport.call(request.merge(stream: true), observer: ->(event) { events << event })

    expect(events.map { |event| event[:type] }).to eq(
      %i[response_started text_delta text_delta attempt_completed response_completed]
    )
    expect(events.map { |event| event[:sequence] }).to eq([1, 2, 3, 4, 5])
    expect(events.last[:result]).to eq(result)
  end

  it "does not retry or fall back after exposing partial output" do
    events = []
    second = candidate.merge(provider: :openai, model: "gpt-test", protocol: :chat_completions,
      credentials: {api_key: "secret-b"})
    allow(adapter).to receive(:call) do |**_args, &stream|
      stream.call(type: :text_delta, content: "abandoned")
      raise RubyLLM::ServiceUnavailableError, "unavailable"
    end

    result = transport.call(
      request.merge(candidates: [candidate, second], stream: true, retry: {max_attempts: 3},
        fallback: {on_error_categories: [:transient]}),
      observer: ->(event) { events << event }
    )

    expect(adapter).to have_received(:call).once
    expect(result).to include(status: :partial, content: "abandoned")
    expect(result[:error]).to include(category: :transient, retryable: false)
    expect(result[:attempts]).to contain_exactly(hash_including(error: hash_including(retryable: false)))
    expect(events.last[:type]).to eq(:response_failed)
  end

  it "preserves streamed usage when the provider fails" do
    events = []
    usage = {input_tokens: 12, output_tokens: 3, total_tokens: 15}
    allow(adapter).to receive(:call) do |**_args, &stream|
      stream.call(type: :usage_updated, input_tokens: 12, output_tokens: nil, total_tokens: nil)
      stream.call(type: :usage_updated, **usage)
      raise RubyLLM::ServiceUnavailableError, "unavailable"
    end

    result = transport.call(request.merge(stream: true), observer: ->(event) { events << event })

    expect(result).to include(status: :failed, usage: usage)
    expect(result[:attempts]).to contain_exactly(hash_including(status: :failed, usage: usage))
    expect(events.last).to include(type: :response_failed, result: hash_including(usage: usage))
  end

  it "preserves streamed usage when the provider cancels" do
    events = []
    usage = {input_tokens: 12, output_tokens: 1, total_tokens: 13}
    allow(adapter).to receive(:call) do |**_args, &stream|
      stream.call(type: :usage_updated, **usage)
      raise RubyLLM::CancelledError
    end

    result = transport.call(request.merge(stream: true), observer: ->(event) { events << event })

    expect(result).to include(status: :cancelled, usage: usage)
    expect(result[:attempts]).to contain_exactly(hash_including(status: :cancelled, usage: usage))
    expect(events.last).to include(type: :response_cancelled, result: hash_including(usage: usage))
  end

  it "falls back with isolated candidate credentials before retrying" do
    second = candidate.merge(provider: :openai, model: "gpt-test", protocol: :chat_completions,
      endpoint: "https://compatible.example/v1", headers: {"X-Route" => "tenant-b"},
      credentials: {api_key: "secret-b"})
    calls = 0
    allow(adapter).to receive(:call) do
      calls += 1
      raise RubyLLM::ServiceUnavailableError, "unavailable" if calls == 1

      {content: "ok", model: "gpt-test", finish_reason: :stop, usage: nil, tool_calls: []}
    end

    result = transport.call(request.merge(candidates: [candidate, second], retry: {max_attempts: 3},
      fallback: {on_error_categories: [:transient]}))

    expect(result).to include(status: :succeeded, provider: :openai, model: "gpt-test")
    expect(result[:attempts].map { |attempt| attempt.values_at(:provider, :model) }).to eq([
      [:anthropic, "claude-test"], [:openai, "gpt-test"]
    ])
    expect(adapter).to have_received(:call).with(hash_including(candidate: candidate)).ordered
    expect(adapter).to have_received(:call).with(hash_including(candidate: second)).ordered
  end

  it "notifies the observer before advancing to a fallback candidate" do
    events = []
    second = candidate.merge(provider: :openai, model: "gpt-test", protocol: :chat_completions,
      credentials: {api_key: "secret-b"})
    allow(adapter).to receive(:call).and_raise(RubyLLM::ServiceUnavailableError, "unavailable")

    transport.call(request.merge(candidates: [candidate, second], retry: {max_attempts: 2},
      fallback: {on_error_categories: [:transient]}), observer: ->(event) { events << event })

    fallback = events.find { |event| event[:type] == :fallback_selected }
    expect(fallback).to include(from: hash_including(provider: :anthropic),
      to: hash_including(provider: :openai), error: hash_including(category: :transient))
    expect(events.map { |event| event[:type] }).to eq(
      %i[response_started attempt_completed response_failed fallback_selected
        response_started attempt_completed response_failed]
    )
  end

  it "stops before fallback when its observer notification fails" do
    second = candidate.merge(provider: :openai, model: "gpt-test", protocol: :chat_completions,
      credentials: {api_key: "secret-b"})
    observer = lambda do |event|
      raise "fallback vetoed" if event[:type] == :fallback_selected
    end
    allow(adapter).to receive(:call).and_raise(RubyLLM::ServiceUnavailableError, "unavailable")

    expect do
      transport.call(request.merge(candidates: [candidate, second], retry: {max_attempts: 2},
        fallback: {on_error_categories: [:transient]}), observer: observer)
    end.to raise_error(described_class::ObserverError, /fallback vetoed/)

    expect(adapter).to have_received(:call).once
  end

  it "rechecks cancellation after notifying the observer about fallback" do
    cancelled = false
    second = candidate.merge(provider: :openai, model: "gpt-test", protocol: :chat_completions,
      credentials: {api_key: "secret-b"})
    observer = lambda do |event|
      cancelled = true if event[:type] == :fallback_selected
    end
    allow(adapter).to receive(:call).and_raise(RubyLLM::ServiceUnavailableError, "unavailable")

    result = transport.call(request.merge(candidates: [candidate, second], retry: {max_attempts: 2},
      fallback: {on_error_categories: [:transient]}, cancellation: -> { cancelled }), observer: observer)

    expect(result[:status]).to eq(:cancelled)
    expect(adapter).to have_received(:call).once
  end

  it "classifies unsupported media and malformed tool arguments explicitly" do
    errors = [
      AgentHarness::Api::RubyLlmChatAdapter::UnsupportedOptionError.new("unsupported media"),
      JSON::ParserError.new("malformed arguments")
    ]
    allow(adapter).to receive(:call) { raise errors.shift }

    unsupported = transport.call(request)
    invalid_response = transport.call(request)

    expect(unsupported[:error]).to include(category: :unsupported, code: :unsupported_capability)
    expect(invalid_response[:error]).to include(category: :invalid_response, code: :invalid_tool_arguments)
  end

  it "surfaces a failing observer directly without classifying it as a provider error" do
    received = []
    invocations = 0
    observer = ->(event) do
      invocations += 1
      raise "observer bug" if event[:type] == :text_delta

      received << event
    end
    allow(adapter).to receive(:call) do |**_args, &stream|
      stream.call(type: :text_delta, content: "hel")
      raise "the observer failure should have aborted the in-flight chat"
    end

    expect { transport.call(request.merge(stream: true), observer: observer) }
      .to raise_error(described_class::ObserverError) { |error| expect(error.cause.message).to eq("observer bug") }

    expect(adapter).to have_received(:call).once
    expect(invocations).to eq(2)
    expect(received.map { |event| event[:type] }).to eq(%i[response_started])
  end

  it "raises before any outbound request when the observer fails on response_started" do
    observer = ->(_event) { raise "observer bug" }

    expect { transport.call(request.merge(stream: true), observer: observer) }
      .to raise_error(described_class::ObserverError, /observer bug/)

    expect(adapter).not_to have_received(:call)
  end

  it "cancels before making an outbound request" do
    cancellation = -> { true }

    result = transport.call(request.merge(cancellation: cancellation))

    expect(adapter).not_to have_received(:call)
    expect(result).to include(status: :cancelled, error: hash_including(category: :cancelled, code: :cancelled))
  end

  it "bounds transient retries and never exposes provider error text" do
    allow(adapter).to receive(:call).and_raise(RubyLLM::RateLimitError, "secret-a was rejected")

    result = transport.call(request.merge(retry: {max_attempts: 2}))

    expect(adapter).to have_received(:call).twice
    expect(result[:error]).to include(category: :transient, code: :rate_limited, retryable: true)
    expect(result[:error].to_s).not_to include("secret-a")
  end

  it "reports every retry once with stable identity and completion-time cost" do
    events = []
    ids = %w[attempt-a attempt-b]
    accounting = {
      usage: {input_tokens: 10, output_tokens: 0, cache_read_tokens: 2},
      cost: {input: 0.001, output: 0.0, cache_read: 0.0001, total: 0.0011,
             source: :estimated, currency: "USD"},
      provider_reported: true
    }
    calls = 0
    retry_transport = described_class.new(adapter: adapter, id_generator: -> { ids.shift }, sleeper: ->(_seconds) {})
    allow(adapter).to receive(:call) do |on_accounting:, **|
      calls += 1
      on_accounting.call(accounting)
      raise RubyLLM::ServiceUnavailableError, "unavailable" if calls == 1

      {content: "ok", model: "claude-test", finish_reason: :stop,
       usage: accounting[:usage], tool_calls: []}
    end

    result = retry_transport.call(request.merge(retry: {max_attempts: 2}), observer: ->(event) { events << event })
    deliveries = events.select { |event| event[:type] == :attempt_completed }

    expect(result[:attempts].map { |attempt| attempt[:attempt_id] }).to eq(%w[attempt-a attempt-b])
    expect(result[:attempts].map { |attempt| attempt[:status] }).to eq(%i[failed succeeded])
    expect(deliveries.map { |event| event[:attempt] }).to eq(result[:attempts])
    expect(result[:usage]).to include(input_tokens: 20, output_tokens: 0, cache_read_tokens: 4)
    expect(result[:attempts].last[:cost]).to include(source: :estimated, total: 0.0011,
      priced_at: match(/Z\z/))
  end

  it "uses the base retry delay when no positive maximum delay is configured" do
    delays = []
    delayed_transport = described_class.new(adapter: adapter, id_generator: id_generator,
      sleeper: ->(seconds) { delays << seconds })
    allow(adapter).to receive(:call).and_raise(RubyLLM::RateLimitError, "rate limited")

    delayed_transport.call(request.merge(retry: {max_attempts: 2, base_delay_seconds: 0.1}))

    expect(delays.sum).to be_within(0.001).of(0.1)
  end

  it "classifies otherwise unmapped RubyLLM errors as unknown" do
    allow(adapter).to receive(:call).and_raise(RubyLLM::Error, "model not found")

    result = transport.call(request)

    expect(result[:error]).to include(category: :unknown, code: :unclassified_provider_error, retryable: false)
  end

  it "rejects reserved authentication header overrides" do
    invalid = candidate.merge(headers: {"x-api-key" => "other-secret"})

    expect { transport.call(request.merge(candidates: [invalid])) }
      .to raise_error(ArgumentError, /reserved header/i)
    expect(adapter).not_to have_received(:call)
  end

  {
    anthropic: [:messages, {}],
    openai: [:responses, {api_key: nil}]
  }.each do |provider, (protocol, credentials)|
    it "classifies a missing #{provider} API key as an invalid credential" do
      missing_credential = candidate.merge(provider: provider, protocol: protocol, credentials: credentials)
      result = described_class.new.call(request.merge(candidates: [missing_credential]))

      expect(result).to include(status: :failed,
        error: hash_including(category: :authentication, code: :invalid_credential, retryable: false))
    end
  end
end
