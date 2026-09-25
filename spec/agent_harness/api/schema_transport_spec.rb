# frozen_string_literal: true

require "spec_helper"

RSpec.describe AgentHarness::Api::ChatTransport do
  subject(:transport) do
    described_class.new(adapter: adapter, id_generator: -> { "attempt-1" }, sleeper: ->(_seconds) {})
  end

  let(:adapter) { instance_double(AgentHarness::Api::RubyLlmChatAdapter) }
  let(:schema) do
    {
      type: "object",
      properties: {
        name: {type: "string"},
        age: {type: "integer"}
      },
      required: %w[name age],
      additionalProperties: false
    }
  end
  let(:candidate) do
    {
      provider: :openai,
      model: "gpt-test",
      protocol: :responses,
      authentication_mode: :api_key,
      credentials: {api_key: "secret"}
    }
  end
  let(:request) do
    {
      request_id: "schema-request-1",
      operation: :schema,
      candidates: [candidate],
      messages: [{id: "user-1", role: :user, content: [{type: :text, text: "Generate a person"}]}],
      schema: schema,
      schema_name: "person",
      retry: {max_attempts: 1}
    }
  end
  let(:response) do
    {
      content: '{"name":"Ada","age":37}',
      model: "gpt-test",
      finish_reason: :stop,
      usage: {input_tokens: 10, output_tokens: 8, total_tokens: 18},
      tool_calls: []
    }
  end

  before do
    allow(adapter).to receive(:prepare).and_return(:prepared_chat)
    allow(adapter).to receive(:call).and_return(response)
  end

  it "exposes parsed data with the normal response metadata" do
    result = transport.call(request)

    expect(result).to include(
      status: :succeeded,
      content: '{"name":"Ada","age":37}',
      parsed: {"name" => "Ada", "age" => 37},
      provider: :openai,
      model: "gpt-test",
      protocol: :responses,
      authentication_mode: :api_key,
      finish_reason: :stop,
      usage: {input_tokens: 10, output_tokens: 8, total_tokens: 18},
      error: nil
    )
    expect(adapter).to have_received(:call).with(hash_including(
      schema: {name: "person", schema: schema}
    ))
    expect(adapter).to have_received(:prepare).with(hash_including(
      schema: {name: "person", schema: schema}
    ))
  end

  it "leaves strictness unset so the provider adapter can infer it for optional properties" do
    optional_schema = schema.merge(required: ["name"])

    transport.call(request.merge(schema: optional_schema))

    expect(adapter).to have_received(:call).with(hash_including(
      schema: {name: "person", schema: optional_schema}
    ))
  end

  it "preserves explicitly configured strictness in schema envelopes" do
    envelope = {name: "optional-person", schema: schema.merge(required: ["name"]), strict: false}

    transport.call(request.merge(schema: envelope))

    expect(adapter).to have_received(:call).with(hash_including(
      schema: hash_including(schema: envelope[:schema], strict: false)
    ))
  end

  it "returns invalid_json without retrying a successful provider response" do
    allow(adapter).to receive(:call).and_return(response.merge(content: "not json"))

    result = transport.call(request.merge(retry: {max_attempts: 3}))

    expect(result).to include(status: :failed, content: "not json", parsed: nil)
    expect(result[:error]).to include(category: :invalid_response, code: :invalid_json, retryable: false)
    expect(adapter).to have_received(:call).once
  end

  it "returns invalid_schema when required fields are missing" do
    allow(adapter).to receive(:call).and_return(response.merge(content: '{"name":"Ada"}'))

    result = transport.call(request)

    expect(result).to include(status: :failed, content: '{"name":"Ada"}', parsed: nil)
    expect(result[:error]).to include(category: :invalid_response, code: :invalid_schema, retryable: false)
  end

  it "returns truncated_output when generation reaches its output limit" do
    allow(adapter).to receive(:call).and_return(response.merge(content: '{"name":"Ada"', finish_reason: :max_tokens))

    result = transport.call(request)

    expect(result).to include(status: :failed, content: '{"name":"Ada"', parsed: nil)
    expect(result[:error]).to include(category: :invalid_response, code: :truncated_output, retryable: false)
  end

  it "returns refusal when the provider declines the schema request" do
    allow(adapter).to receive(:call).and_return(response.merge(content: "I cannot comply", refusal: true))

    result = transport.call(request)

    expect(result).to include(status: :failed, content: "I cannot comply", parsed: nil)
    expect(result[:error]).to include(category: :invalid_response, code: :refusal, retryable: false)
  end

  it "returns an explicit unsupported outcome for JSON-only mode" do
    result = transport.call(request.merge(schema_mode: :json_only))

    expect(result).to include(status: :failed, content: "", parsed: nil)
    expect(result[:error]).to include(category: :unsupported, code: :structured_output_not_supported,
      retryable: false)
    expect(adapter).not_to have_received(:call)
  end

  it "returns an explicit unsupported outcome for streamed schemas" do
    result = transport.call(request.merge(stream: true))

    expect(result).to include(status: :failed, content: "", parsed: nil)
    expect(result[:error]).to include(category: :unsupported, code: :structured_output_not_supported,
      retryable: false)
    expect(adapter).not_to have_received(:call)
  end

  it "requires a schema before making a provider request" do
    expect { transport.call(request.except(:schema)) }
      .to raise_error(ArgumentError, "schema is required for a schema operation")

    expect(adapter).not_to have_received(:call)
  end
end
