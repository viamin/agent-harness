# frozen_string_literal: true

require "spec_helper"

if ENV["AGENT_HARNESS_LIVE_OPENAI"] == "1"
  RSpec.describe "OpenAI Responses reasoning tool continuation", :live do
    it "streams a tool call and continues with its result" do
      WebMock.allow_net_connect!
      transport = AgentHarness::Api::ChatTransport.new
      candidate = {
        provider: :openai,
        model: "gpt-5.6-luna",
        protocol: :responses,
        authentication_mode: :api_key,
        credentials: {api_key: ENV.fetch("OPENAI_API_KEY")}
      }
      tool = {
        name: "lookup_number",
        description: "Returns the English name of an integer",
        input_schema: {
          type: "object",
          properties: {number: {type: "integer"}},
          required: ["number"],
          additionalProperties: false
        }
      }
      user_message = {role: :user, content: "Call lookup_number with 7, then report its result."}

      first = transport.call(request(candidate, [user_message], [tool], "live-tool-call"))
      call = first.fetch(:tool_calls).fetch(0)
      continuation = [
        user_message,
        {role: :assistant, content: first[:content], tool_calls: [call], provider_state: first[:provider_state]},
        {role: :tool, content: "seven", tool_call_id: call.fetch(:id)}
      ]
      second = transport.call(request(candidate, continuation, [tool], "live-tool-result"))

      expect(first).to include(status: :succeeded, provider_state: hash_including(protocol: :responses))
      expect(call).to include(provider_id: a_string_matching(/\S/), arguments_json: a_string_matching(/7/))
      expect(second).to include(status: :succeeded)
      expect(second[:content]).to match(/seven/i)
      expect(first[:usage]).to include(:input_tokens, :output_tokens)
      expect(second[:usage]).to include(:input_tokens, :output_tokens)
    ensure
      WebMock.disable_net_connect!
    end

    def request(candidate, messages, tools, request_id)
      {
        request_id: request_id,
        operation: :chat,
        candidates: [candidate],
        messages: messages,
        tools: tools,
        stream: true,
        retry: {max_attempts: 1}
      }
    end
  end
end
