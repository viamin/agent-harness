# frozen_string_literal: true

require "spec_helper"

# Streaming is the documented continuation path for reasoning models, and
# RubyLLM builds a streamed message from its stream accumulator instead of a
# parsed response body, so these run the real provider protocol over a stubbed
# Responses endpoint rather than standing in for the message shape.
RSpec.describe AgentHarness::Api::ChatTransport, "streamed Responses continuation" do
  subject(:transport) { described_class.new }

  let(:candidate) do
    {
      provider: :openai, model: "gpt-5.6-luna", protocol: :responses,
      authentication_mode: :api_key, credentials: {api_key: "request-secret"}
    }
  end
  let(:tool) do
    {
      name: "lookup_number", description: "Returns the English name of an integer",
      input_schema: {type: "object", properties: {number: {type: "integer"}}, required: ["number"],
                     additionalProperties: false}
    }
  end
  let(:user_message) { {role: :user, content: "Call lookup_number with 7, then report its result."} }
  let(:requests) { [] }

  it "captures the encrypted reasoning and function-call items of a streamed tool call" do
    stub_responses(tool_call_stream)

    result = transport.call(request(messages: [user_message]))

    expect(result).to include(status: :succeeded, usage: {input_tokens: 10, output_tokens: 5, total_tokens: 15})
    expect(result[:tool_calls]).to contain_exactly(
      hash_including(provider_id: "call-1", name: "lookup_number", arguments_json: '{"number":7}')
    )
    expect(result[:provider_state]).to eq(protocol: :responses, output: [
      {"type" => "reasoning", "summary" => [], "encrypted_content" => "encrypted-reasoning"},
      {"type" => "function_call", "call_id" => "call-1", "name" => "lookup_number", "arguments" => '{"number":7}'}
    ])
  end

  it "replays the reasoning item and the provider call id with the tool result" do
    stub_responses(tool_call_stream, text_stream("seven"))
    first = transport.call(request(messages: [user_message]))
    call = first[:tool_calls].fetch(0)

    result = transport.call(request(messages: [
      user_message,
      {role: :assistant, content: first[:content], tool_calls: [call], provider_state: first[:provider_state]},
      {role: :tool, content: "seven", tool_call_id: call.fetch(:id)}
    ]))

    expect(result).to include(status: :succeeded, content: "seven")
    expect(sent_inputs.last).to eq([
      {"role" => "user", "content" => "Call lookup_number with 7, then report its result."},
      {"type" => "reasoning", "summary" => [], "encrypted_content" => "encrypted-reasoning"},
      {"type" => "function_call", "call_id" => "call-1", "name" => "lookup_number", "arguments" => '{"number":7}'},
      {"type" => "function_call_output", "call_id" => "call-1", "output" => "seven"}
    ])
  end

  private

  def request(messages:)
    {
      request_id: "streamed-continuation", operation: :chat, candidates: [candidate], messages: messages,
      tools: [tool], stream: true, retry: {max_attempts: 1}
    }
  end

  def stub_responses(*streams)
    bodies = streams.map { |body| {body: body, headers: {"Content-Type" => "text/event-stream"}} }
    stub_request(:post, "https://api.openai.com/v1/responses")
      .with { |request| record_request(request) }
      .to_return(bodies)
  end

  def record_request(request)
    requests << request.body
    true
  end

  def sent_inputs
    requests.map { |body| JSON.parse(body)["input"] }
  end

  def stream(*events)
    (events.map { |event| "data: #{JSON.generate(event)}\n\n" } << "data: [DONE]\n\n").join
  end

  def tool_call_stream
    stream(
      {"type" => "response.created",
       "response" => {"id" => "resp-1", "model" => "gpt-5.6-luna", "status" => "in_progress"}},
      {"type" => "response.output_item.added", "output_index" => 0,
       "item" => {"type" => "reasoning", "id" => "rs-1", "summary" => []}},
      {"type" => "response.output_item.done", "output_index" => 0,
       "item" => {"type" => "reasoning", "id" => "rs-1", "summary" => [],
                  "encrypted_content" => "encrypted-reasoning"}},
      {"type" => "response.output_item.added", "output_index" => 1,
       "item" => {"type" => "function_call", "call_id" => "call-1", "name" => "lookup_number", "arguments" => ""}},
      {"type" => "response.function_call_arguments.delta", "output_index" => 1, "delta" => '{"number":7}'},
      {"type" => "response.output_item.done", "output_index" => 1,
       "item" => {"type" => "function_call", "call_id" => "call-1", "name" => "lookup_number",
                  "arguments" => '{"number":7}'}},
      {"type" => "response.completed",
       "response" => {"id" => "resp-1", "model" => "gpt-5.6-luna", "status" => "completed",
                      "output" => [
                        {"type" => "reasoning", "id" => "rs-1", "summary" => [],
                         "encrypted_content" => "encrypted-reasoning"},
                        {"type" => "function_call", "id" => "fc-1", "call_id" => "call-1", "name" => "lookup_number",
                         "arguments" => '{"number":7}', "status" => "completed"}
                      ],
                      "usage" => {"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}}}
    )
  end

  def text_stream(text)
    stream(
      {"type" => "response.output_item.added", "output_index" => 0,
       "item" => {"type" => "message", "id" => "msg-1", "role" => "assistant", "content" => []}},
      {"type" => "response.output_text.delta", "output_index" => 0, "content_index" => 0, "delta" => text},
      {"type" => "response.completed",
       "response" => {"id" => "resp-2", "model" => "gpt-5.6-luna", "status" => "completed",
                      "output" => [{"type" => "message", "id" => "msg-1", "role" => "assistant", "status" => "completed",
                                    "content" => [{"type" => "output_text", "text" => text, "annotations" => []}]}],
                      "usage" => {"input_tokens" => 12, "output_tokens" => 3, "total_tokens" => 15}}}
    )
  end
end
