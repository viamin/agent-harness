# frozen_string_literal: true

require "spec_helper"

RSpec.describe AgentHarness::Api::RubyLlmChatAdapter do
  subject(:adapter) { described_class.new }

  let(:chat) do
    instance_double(RubyLLM::Chat, {
      "messages=" => nil,
      "with_tools" => nil,
      "with_headers" => nil,
      "with_max_output_tokens" => nil,
      "with_temperature" => nil,
      "generate" => response
    })
  end
  let(:context) { instance_double(RubyLLM::Context, chat: chat) }
  let(:response) do
    instance_double(RubyLLM::Message, content: "ok", model: "private-model", finish_reason: :stop,
      tokens: nil, tool_calls: nil)
  end
  let(:config_class) do
    Struct.new(:anthropic_api_key, :anthropic_api_base, :openai_api_key, :openai_api_base,
      :max_retries, :request_timeout)
  end

  before do
    allow(RubyLLM).to receive(:context) do |&configuration|
      @configured = config_class.new
      configuration.call(@configured)
      context
    end
  end

  it "uses an isolated Anthropic context, Messages protocol, and exact output limit" do
    result = adapter.call(
      candidate: {
        provider: :anthropic, model: "private-model", protocol: :messages,
        credentials: {api_key: "request-secret"}, endpoint: "https://proxy.example",
        headers: {"X-Tenant" => "tenant-1"}
      },
      messages: [{role: :system, content: [{type: :text, text: "Rules"}]}],
      tools: [], max_output_tokens: 321, temperature: nil, stream: false,
      timeout: {read_seconds: 9}, cancellation: nil
    )

    expect(@configured.to_h).to include(anthropic_api_key: "request-secret", anthropic_api_base: "https://proxy.example",
      max_retries: 0, request_timeout: 9)
    expect(context).to have_received(:chat).with(model: "private-model", provider: :anthropic,
      protocol: :anthropic, assume_model_exists: true)
    expect(chat).to have_received(:messages=).with([{role: :system, content: "Rules"}])
    expect(chat).to have_received(:with_headers).with("X-Tenant" => "tenant-1")
    expect(chat).to have_received(:with_max_output_tokens).with(321)
    expect(result).to include(content: "ok", model: "private-model")
  end

  it "selects Chat Completions explicitly for a compatible OpenAI endpoint" do
    adapter.call(
      candidate: {
        provider: :openai, model: "compatible-model", protocol: :chat_completions,
        credentials: {api_key: "compatible-secret"}, endpoint: "https://compatible.example/v1"
      },
      messages: [{role: :user, content: "hello"}], tools: [], max_output_tokens: nil,
      temperature: nil, stream: false, timeout: nil, cancellation: nil
    )

    expect(@configured.to_h).to include(openai_api_key: "compatible-secret",
      openai_api_base: "https://compatible.example/v1", max_retries: 0)
    expect(context).to have_received(:chat).with(model: "compatible-model", provider: :openai,
      protocol: :chat_completions, assume_model_exists: true)
  end

  it "joins interleaved multi-chunk Anthropic tool calls by stream index" do
    candidate = {provider: :anthropic, model: "private-model", protocol: :messages,
                 credentials: {api_key: "request-secret"}}
    chunks = [
      chunk(tool_calls: {0 => tool_call(id: "toolu_a", name: "lookup")}),
      chunk(tool_calls: {0 => tool_call(arguments: '{"qu')}),
      chunk(tool_calls: {1 => tool_call(id: "toolu_b", name: "fetch")}),
      chunk(tool_calls: {0 => tool_call(arguments: 'ery":"Ruby"}')}),
      chunk(tool_calls: {1 => tool_call(arguments: '{"id":7}')})
    ]
    final = final_response(tool_calls: {
      "toolu_a" => tool_call(id: "toolu_a", name: "lookup", arguments: {"query" => "Ruby"}),
      "toolu_b" => tool_call(id: "toolu_b", name: "fetch", arguments: {"id" => 7})
    })

    events = streamed_events(candidate, chunks, final)

    expect(events).to eq([
      {type: :tool_call_started, provider_id: "toolu_a", name: "lookup"},
      {type: :tool_call_delta, provider_id: "toolu_a", arguments_json: '{"qu'},
      {type: :tool_call_started, provider_id: "toolu_b", name: "fetch"},
      {type: :tool_call_delta, provider_id: "toolu_a", arguments_json: 'ery":"Ruby"}'},
      {type: :tool_call_delta, provider_id: "toolu_b", arguments_json: '{"id":7}'},
      {type: :tool_call_completed, provider_id: "toolu_a", name: "lookup", arguments_json: '{"query":"Ruby"}'},
      {type: :tool_call_completed, provider_id: "toolu_b", name: "fetch", arguments_json: '{"id":7}'}
    ])
  end

  it "joins multi-chunk Responses tool calls by output index" do
    candidate = {provider: :openai, model: "private-model", protocol: :responses,
                 credentials: {api_key: "request-secret"}}
    chunks = [
      chunk(tool_calls: {1 => tool_call(id: "call_resp", name: "lookup", arguments: "")}),
      chunk(tool_calls: {1 => tool_call(arguments: '{"query"')}),
      chunk(tool_calls: {1 => tool_call(arguments: ':"Ruby"}')})
    ]
    final = final_response(tool_calls: {
      "call_resp" => tool_call(id: "call_resp", name: "lookup", arguments: {"query" => "Ruby"})
    })

    events = streamed_events(candidate, chunks, final)

    expect(events).to eq([
      {type: :tool_call_started, provider_id: "call_resp", name: "lookup"},
      {type: :tool_call_delta, provider_id: "call_resp", arguments_json: '{"query"'},
      {type: :tool_call_delta, provider_id: "call_resp", arguments_json: ':"Ruby"}'},
      {type: :tool_call_completed, provider_id: "call_resp", name: "lookup", arguments_json: '{"query":"Ruby"}'}
    ])
  end

  it "joins multi-chunk Chat Completions tool calls by tool index" do
    candidate = {provider: :openai, model: "compatible-model", protocol: :chat_completions,
                 credentials: {api_key: "request-secret"}}
    chunks = [
      chunk(tool_calls: {0 => tool_call(id: "call_cc", name: "lookup", arguments: '{"que')}),
      chunk(tool_calls: {0 => tool_call(arguments: 'ry":"Ruby"}')})
    ]
    final = final_response(tool_calls: {
      "call_cc" => tool_call(id: "call_cc", name: "lookup", arguments: {"query" => "Ruby"})
    })

    events = streamed_events(candidate, chunks, final)

    expect(events).to eq([
      {type: :tool_call_started, provider_id: "call_cc", name: "lookup"},
      {type: :tool_call_delta, provider_id: "call_cc", arguments_json: '{"que'},
      {type: :tool_call_delta, provider_id: "call_cc", arguments_json: 'ry":"Ruby"}'},
      {type: :tool_call_completed, provider_id: "call_cc", name: "lookup", arguments_json: '{"query":"Ruby"}'}
    ])
    fragments = events.filter_map { |event| event[:arguments_json] if event[:type] == :tool_call_delta }
    expect(fragments.join).to eq('{"query":"Ruby"}')
  end

  it "emits cumulative usage_updated events without duplicate reports" do
    candidate = {provider: :anthropic, model: "private-model", protocol: :messages,
                 credentials: {api_key: "request-secret"}}
    chunks = [
      chunk(content: "he", input_tokens: 10),
      chunk,
      chunk(output_tokens: 2),
      chunk(output_tokens: 2),
      chunk(output_tokens: 5)
    ]
    final = final_response(content: "hello", tool_calls: {},
      tokens: RubyLLM::Tokens.new(input: 10, output: 5))

    events = streamed_events(candidate, chunks, final)

    expect(events).to eq([
      {type: :text_delta, content: "he"},
      {type: :usage_updated, input_tokens: 10, output_tokens: nil, total_tokens: nil},
      {type: :usage_updated, input_tokens: 10, output_tokens: 2, total_tokens: 12},
      {type: :usage_updated, input_tokens: 10, output_tokens: 5, total_tokens: 15}
    ])
    expect(@streamed_result).to include(usage: {input_tokens: 10, output_tokens: 5, total_tokens: 15})
  end

  it "leaves usage nil when the provider reports no token counts" do
    candidate = {provider: :openai, model: "private-model", protocol: :responses,
                 credentials: {api_key: "request-secret"}}
    final = final_response(content: "ok", tool_calls: {})

    streamed_events(candidate, [chunk(content: "ok")], final)

    expect(@streamed_result).to include(usage: nil)
  end

  private

  def chunk(content: nil, tool_calls: nil, input_tokens: nil, output_tokens: nil)
    RubyLLM::Chunk.new(role: :assistant, content: content, tool_calls: tool_calls,
      input_tokens: input_tokens, output_tokens: output_tokens)
  end

  def tool_call(id: nil, name: nil, arguments: nil)
    RubyLLM::ToolCall.new(id: id, name: name, arguments: arguments || {})
  end

  def final_response(content: "", tool_calls: {}, tokens: nil)
    RubyLLM::Message.new(role: :assistant, content: content, model: "private-model",
      finish_reason: :tool_calls, tool_calls: tool_calls, tokens: tokens)
  end

  def streamed_events(candidate, chunks, final_response)
    allow(chat).to receive(:generate) do |&block|
      chunks.each { |stream_chunk| block.call(stream_chunk) }
      final_response
    end
    @streamed_events = []
    @streamed_result = adapter.call(candidate: candidate, messages: [], tools: [], max_output_tokens: nil,
      temperature: nil, stream: true, timeout: nil, cancellation: nil) { |event| @streamed_events << event }
    @streamed_events
  end
end
