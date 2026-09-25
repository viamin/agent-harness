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
  end

  it "emits ordered text and exactly one explicit completion event" do
    events = []
    allow(adapter).to receive(:call) do |**args, &stream|
      stream.call(type: :text_delta, content: "hel")
      stream.call(type: :text_delta, content: "lo")
      {content: "hello", model: "claude-test", finish_reason: :stop, usage: nil, tool_calls: []}
    end

    result = transport.call(request.merge(stream: true), observer: ->(event) { events << event })

    expect(events.map { |event| event[:type] }).to eq(%i[response_started text_delta text_delta response_completed])
    expect(events.map { |event| event[:sequence] }).to eq([1, 2, 3, 4])
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
    expect(events.last[:type]).to eq(:response_failed)
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
    expect(adapter).to have_received(:call).with(hash_including(candidate: candidate)).ordered
    expect(adapter).to have_received(:call).with(hash_including(candidate: second)).ordered
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

  it "rejects reserved authentication header overrides" do
    invalid = candidate.merge(headers: {"x-api-key" => "other-secret"})

    expect { transport.call(request.merge(candidates: [invalid])) }
      .to raise_error(ArgumentError, /reserved header/i)
    expect(adapter).not_to have_received(:call)
  end
end
