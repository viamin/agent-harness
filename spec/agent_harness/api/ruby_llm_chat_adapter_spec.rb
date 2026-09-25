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
end
