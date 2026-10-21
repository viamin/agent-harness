# frozen_string_literal: true

require "spec_helper"

RSpec.describe AgentHarness::Api::ProviderErrorDetail do
  it "accepts the structured provider tools and reasoning diagnostic" do
    message = "Function tools with reasoning_effort are not supported for gpt-5.6-luna in /v1/chat/completions. " \
      "To use function tools, use /v1/responses or set reasoning_effort to 'none'."
    response = Faraday::Response.new(status: 400, body: JSON.generate(error: {message: message}))

    expect(described_class.call(RubyLLM::BadRequestError.new(message, response: response))).to eq(message)
  end

  it "rejects raw and mismatched provider response messages" do
    response = Faraday::Response.new(status: 400, body: "upstream failed")
    error = RubyLLM::BadRequestError.new("upstream failed", response: response)

    expect(described_class.call(error)).to be_nil
  end

  it "rejects arbitrary local error text" do
    error = AgentHarness::Api::RubyLlmChatAdapter::UnsupportedOptionError.new(
      "unsupported content type: patient-diagnosis-HIV"
    )

    expect(described_class.call(error)).to be_nil
  end
end
