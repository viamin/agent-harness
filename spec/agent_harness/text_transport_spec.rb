# frozen_string_literal: true

require "logger"
require "net/http"

RSpec.describe AgentHarness::TextTransport do
  let(:api_key) { "sk-ant-test-key-123" }
  let(:logger) { instance_double(Logger, debug: nil, error: nil, warn: nil) }
  let(:transport) { described_class.new(api_key: api_key, logger: logger) }

  def stub_api_response(status:, body:)
    http_response = instance_double(Net::HTTPOK,
      code: status.to_s,
      body: JSON.generate(body))
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:request).and_return(http_response)
    http
  end

  def stub_raw_api_response(status:, body_string:)
    http_response = instance_double(Net::HTTPOK,
      code: status.to_s,
      body: body_string)
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:request).and_return(http_response)
    http
  end

  def stub_streaming_response(status:, chunks:)
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)

    http_response = instance_double(Net::HTTPOK, code: status.to_s)

    allow(http).to receive(:request) do |_req, &block|
      allow(http_response).to receive(:read_body) do |&body_block|
        chunks.each { |chunk| body_block.call(chunk) }
      end
      block.call(http_response)
    end

    http
  end

  describe "#send_message" do
    context "successful response" do
      it "returns a Response with extracted text content" do
        stub_api_response(status: 200, body: {
          "id" => "msg_123",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-sonnet-4-20250514",
          "content" => [
            {"type" => "text", "text" => "Hello, world!"}
          ],
          "usage" => {
            "input_tokens" => 10,
            "output_tokens" => 5
          }
        })

        response = transport.send_message("Say hello")

        expect(response).to be_a(AgentHarness::Response)
        expect(response.output).to eq("Hello, world!")
        expect(response.success?).to be true
        expect(response.exit_code).to eq(0)
        expect(response.provider).to eq(:claude)
        expect(response.model).to eq("claude-sonnet-4-20250514")
        expect(response.metadata[:transport]).to eq(:http)
      end

      it "extracts token usage" do
        stub_api_response(status: 200, body: {
          "content" => [{"type" => "text", "text" => "response"}],
          "usage" => {"input_tokens" => 100, "output_tokens" => 50}
        })

        response = transport.send_message("prompt")

        expect(response.tokens).to eq({input: 100, output: 50, total: 150})
        expect(response.input_tokens).to eq(100)
        expect(response.output_tokens).to eq(50)
        expect(response.total_tokens).to eq(150)
      end

      it "handles multiple text content blocks" do
        stub_api_response(status: 200, body: {
          "content" => [
            {"type" => "text", "text" => "Part 1. "},
            {"type" => "text", "text" => "Part 2."}
          ],
          "usage" => {"input_tokens" => 10, "output_tokens" => 10}
        })

        response = transport.send_message("prompt")

        expect(response.output).to eq("Part 1. Part 2.")
      end

      it "preserves Anthropic tool calls in response metadata" do
        stub_api_response(status: 200, body: {
          "content" => [
            {"type" => "text", "text" => "I'll check."},
            {"type" => "tool_use", "id" => "toolu_123", "name" => "get_weather", "input" => {"location" => "NYC"}}
          ],
          "usage" => {"input_tokens" => 10, "output_tokens" => 4}
        })

        response = transport.chat(messages: [{role: "user", content: "What's the weather?"}])

        expect(response.output).to eq("I'll check.")
        expect(response.metadata[:tool_calls]).to eq([
          {id: "toolu_123", name: "get_weather", arguments: '{"location":"NYC"}'}
        ])
      end

      it "handles empty content array" do
        stub_api_response(status: 200, body: {
          "content" => [],
          "usage" => {"input_tokens" => 10, "output_tokens" => 0}
        })

        response = transport.send_message("prompt")

        expect(response.output).to eq("")
      end

      it "handles missing usage data" do
        stub_api_response(status: 200, body: {
          "content" => [{"type" => "text", "text" => "response"}]
        })

        response = transport.send_message("prompt")

        expect(response.tokens).to be_nil
      end

      it "sends the correct headers" do
        http = stub_api_response(status: 200, body: {
          "content" => [{"type" => "text", "text" => "ok"}],
          "usage" => {"input_tokens" => 1, "output_tokens" => 1}
        })

        expect(http).to receive(:request) do |req|
          expect(req["Content-Type"]).to eq("application/json")
          expect(req["x-api-key"]).to eq(api_key)
          expect(req["anthropic-version"]).to eq("2023-06-01")

          body = JSON.parse(req.body)
          expect(body["messages"]).to eq([{"role" => "user", "content" => "test prompt"}])
          expect(body["model"]).to eq("claude-sonnet-4-20250514")
          expect(body["max_tokens"]).to eq(4096)

          instance_double(Net::HTTPOK,
            code: "200",
            body: JSON.generate({
              "content" => [{"type" => "text", "text" => "ok"}],
              "usage" => {"input_tokens" => 1, "output_tokens" => 1}
            }))
        end

        transport.send_message("test prompt")
      end

      it "uses custom model and max_tokens when provided" do
        http = stub_api_response(status: 200, body: {
          "content" => [{"type" => "text", "text" => "ok"}],
          "usage" => {"input_tokens" => 1, "output_tokens" => 1}
        })

        expect(http).to receive(:request) do |req|
          body = JSON.parse(req.body)
          expect(body["model"]).to eq("claude-3-opus-20240229")
          expect(body["max_tokens"]).to eq(8192)

          instance_double(Net::HTTPOK,
            code: "200",
            body: JSON.generate({
              "content" => [{"type" => "text", "text" => "ok"}],
              "model" => "claude-3-opus-20240229",
              "usage" => {"input_tokens" => 1, "output_tokens" => 1}
            }))
        end

        transport.send_message("prompt", model: "claude-3-opus-20240229", max_tokens: 8192)
      end

      it "records duration" do
        stub_api_response(status: 200, body: {
          "content" => [{"type" => "text", "text" => "ok"}],
          "usage" => {"input_tokens" => 1, "output_tokens" => 1}
        })

        response = transport.send_message("prompt")

        expect(response.duration).to be_a(Float)
        expect(response.duration).to be >= 0
      end
    end

    context "error responses" do
      it "raises AuthenticationError on 401" do
        stub_api_response(status: 401, body: {
          "error" => {"type" => "authentication_error", "message" => "invalid x-api-key"}
        })

        expect { transport.send_message("prompt") }
          .to raise_error(AgentHarness::AuthenticationError, /invalid x-api-key/) do |error|
            expect(error.provider).to eq(:claude)
          end
      end

      it "raises AuthenticationError on 403" do
        stub_api_response(status: 403, body: {
          "error" => {"type" => "forbidden", "message" => "access denied"}
        })

        expect { transport.send_message("prompt") }
          .to raise_error(AgentHarness::AuthenticationError, /access denied/)
      end

      it "raises RateLimitError on 429" do
        stub_api_response(status: 429, body: {
          "error" => {"type" => "rate_limit_error", "message" => "too many requests"}
        })

        expect { transport.send_message("prompt") }
          .to raise_error(AgentHarness::RateLimitError, /too many requests/)
      end

      it "raises ProviderError on 400" do
        stub_api_response(status: 400, body: {
          "error" => {"type" => "invalid_request_error", "message" => "invalid model"}
        })

        expect { transport.send_message("prompt") }
          .to raise_error(AgentHarness::ProviderError, /invalid model/)
      end

      it "raises ProviderError on 500" do
        stub_api_response(status: 500, body: {
          "error" => {"type" => "api_error", "message" => "internal error"}
        })

        expect { transport.send_message("prompt") }
          .to raise_error(AgentHarness::ProviderError, /internal error/)
      end

      it "raises ProviderError on 529 (overloaded)" do
        stub_api_response(status: 529, body: {
          "error" => {"type" => "overloaded_error", "message" => "API is overloaded"}
        })

        expect { transport.send_message("prompt") }
          .to raise_error(AgentHarness::ProviderError, /overloaded/)
      end

      it "handles non-JSON error responses" do
        stub_raw_api_response(status: 502, body_string: "Bad Gateway")

        expect { transport.send_message("prompt") }
          .to raise_error(AgentHarness::ProviderError, /Bad Gateway/)
      end

      it "raises ProviderError for unexpected status codes" do
        stub_api_response(status: 418, body: {
          "error" => {"message" => "I'm a teapot"}
        })

        expect { transport.send_message("prompt") }
          .to raise_error(AgentHarness::ProviderError, /418/)
      end
    end

    context "network errors" do
      it "raises TimeoutError on open timeout" do
        http = instance_double(Net::HTTP)
        allow(Net::HTTP).to receive(:new).and_return(http)
        allow(http).to receive(:use_ssl=)
        allow(http).to receive(:open_timeout=)
        allow(http).to receive(:read_timeout=)
        allow(http).to receive(:request).and_raise(Net::OpenTimeout.new("connection timed out"))

        expect { transport.send_message("prompt") }
          .to raise_error(AgentHarness::TimeoutError, /connection timed out/)
      end

      it "raises TimeoutError on read timeout" do
        http = instance_double(Net::HTTP)
        allow(Net::HTTP).to receive(:new).and_return(http)
        allow(http).to receive(:use_ssl=)
        allow(http).to receive(:open_timeout=)
        allow(http).to receive(:read_timeout=)
        allow(http).to receive(:request).and_raise(Net::ReadTimeout.new("read timed out"))

        expect { transport.send_message("prompt") }
          .to raise_error(AgentHarness::TimeoutError, /read timed out/)
      end

      it "raises ProviderError on connection refused" do
        http = instance_double(Net::HTTP)
        allow(Net::HTTP).to receive(:new).and_return(http)
        allow(http).to receive(:use_ssl=)
        allow(http).to receive(:open_timeout=)
        allow(http).to receive(:read_timeout=)
        allow(http).to receive(:request).and_raise(Errno::ECONNREFUSED)

        expect { transport.send_message("prompt") }
          .to raise_error(AgentHarness::ProviderError, /connection error/i)
      end

      it "raises ProviderError on socket error" do
        http = instance_double(Net::HTTP)
        allow(Net::HTTP).to receive(:new).and_return(http)
        allow(http).to receive(:use_ssl=)
        allow(http).to receive(:open_timeout=)
        allow(http).to receive(:read_timeout=)
        allow(http).to receive(:request).and_raise(SocketError.new("getaddrinfo: Name or service not known"))

        expect { transport.send_message("prompt") }
          .to raise_error(AgentHarness::ProviderError, /connection error/i)
      end
    end

    context "timeout configuration" do
      it "sets open_timeout to minimum of timeout and 30" do
        http = instance_double(Net::HTTP)
        allow(Net::HTTP).to receive(:new).and_return(http)
        allow(http).to receive(:use_ssl=)
        allow(http).to receive(:read_timeout=)
        allow(http).to receive(:request).and_return(
          instance_double(Net::HTTPOK,
            code: "200",
            body: JSON.generate({"content" => [], "usage" => {"input_tokens" => 0, "output_tokens" => 0}}))
        )

        expect(http).to receive(:open_timeout=).with(30)

        transport.send_message("prompt", timeout: 120)
      end

      it "uses timeout value for open_timeout when less than 30" do
        http = instance_double(Net::HTTP)
        allow(Net::HTTP).to receive(:new).and_return(http)
        allow(http).to receive(:use_ssl=)
        allow(http).to receive(:read_timeout=)
        allow(http).to receive(:request).and_return(
          instance_double(Net::HTTPOK,
            code: "200",
            body: JSON.generate({"content" => [], "usage" => {"input_tokens" => 0, "output_tokens" => 0}}))
        )

        expect(http).to receive(:open_timeout=).with(10)

        transport.send_message("prompt", timeout: 10)
      end
    end
  end

  describe "#chat" do
    context "streaming" do
      it "yields text and usage chunks and returns the accumulated response" do
        chunks = [
          "event: message_start\n",
          "data: #{JSON.generate({"type" => "message_start", "message" => {"model" => "claude-sonnet-4-20250514", "usage" => {"input_tokens" => 9}}})}\n\n",
          "event: content_block_delta\n",
          "data: #{JSON.generate({"type" => "content_block_delta", "delta" => {"type" => "text_delta", "text" => "Hi"}})}\n\n",
          "event: content_block_delta\n",
          "data: #{JSON.generate({"type" => "content_block_delta", "delta" => {"type" => "text_delta", "text" => " there"}})}\n\n",
          "event: message_delta\n",
          "data: #{JSON.generate({"type" => "message_delta", "usage" => {"output_tokens" => 3}})}\n\n",
          "event: message_stop\n",
          "data: #{JSON.generate({"type" => "message_stop"})}\n\n"
        ]

        stub_streaming_response(status: 200, chunks: chunks)

        received = []
        response = transport.chat(
          messages: [{role: "user", content: "Hello"}],
          stream: true
        ) { |chunk| received << chunk }

        expect(received).to eq([
          {type: :text, content: "Hi"},
          {type: :text, content: " there"},
          {type: :usage, input_tokens: 9, output_tokens: 3},
          {type: :done}
        ])
        expect(response.output).to eq("Hi there")
        expect(response.model).to eq("claude-sonnet-4-20250514")
        expect(response.tokens).to eq({input: 9, output: 3, total: 12})
        expect(response.metadata).to include(transport: :http, stream: true)
      end

      it "yields Anthropic tool call chunks and stores the completed tool call" do
        chunks = [
          "event: content_block_start\n",
          "data: #{JSON.generate({"type" => "content_block_start", "index" => 0, "content_block" => {"type" => "tool_use", "id" => "toolu_123", "name" => "get_weather", "input" => {}}})}\n\n",
          "event: content_block_delta\n",
          "data: #{JSON.generate({"type" => "content_block_delta", "index" => 0, "delta" => {"type" => "input_json_delta", "partial_json" => "{\"loc"}})}\n\n",
          "event: content_block_delta\n",
          "data: #{JSON.generate({"type" => "content_block_delta", "index" => 0, "delta" => {"type" => "input_json_delta", "partial_json" => "ation\":\"NYC\"}"}})}\n\n",
          "event: content_block_stop\n",
          "data: #{JSON.generate({"type" => "content_block_stop", "index" => 0})}\n\n",
          "event: message_stop\n",
          "data: #{JSON.generate({"type" => "message_stop"})}\n\n"
        ]

        stub_streaming_response(status: 200, chunks: chunks)

        received = []
        response = transport.chat(
          messages: [{role: "user", content: "What's the weather?"}],
          stream: true
        ) { |chunk| received << chunk }

        expect(received).to include(
          {type: :tool_call_start, id: "toolu_123", name: "get_weather"},
          {type: :tool_call_delta, id: "toolu_123", arguments: "{\"loc"},
          {type: :tool_call_delta, id: "toolu_123", arguments: "ation\":\"NYC\"}"},
          {type: :tool_call_complete, id: "toolu_123", name: "get_weather", arguments: '{"location":"NYC"}'},
          {type: :done}
        )
        expect(response.metadata[:tool_calls]).to eq([
          {id: "toolu_123", name: "get_weather", arguments: '{"location":"NYC"}'}
        ])
      end

      it "delivers chunks to on_chat_chunk and observer" do
        chunks = [
          "event: content_block_delta\n",
          "data: #{JSON.generate({"type" => "content_block_delta", "delta" => {"type" => "text_delta", "text" => "Hi"}})}\n\n",
          "event: message_stop\n",
          "data: #{JSON.generate({"type" => "message_stop"})}\n\n"
        ]

        stub_streaming_response(status: 200, chunks: chunks)

        proc_received = []
        observer = double("observer")
        allow(observer).to receive(:respond_to?).and_return(false)
        allow(observer).to receive(:respond_to?).with(:on_chat_chunk).and_return(true)
        allow(observer).to receive(:on_chat_chunk)

        transport.chat(
          messages: [{role: "user", content: "Hello"}],
          stream: true,
          on_chat_chunk: proc { |chunk| proc_received << chunk },
          observer: observer
        )

        expect(proc_received.map { |chunk| chunk[:type] }).to eq([:text, :done])
        expect(observer).to have_received(:on_chat_chunk).with({type: :text, content: "Hi"})
        expect(observer).to have_received(:on_chat_chunk).with({type: :done})
      end

      it "falls back to a non-streaming request when no stream receiver is attached" do
        http = stub_api_response(status: 200, body: {
          "content" => [{"type" => "text", "text" => "ok"}],
          "model" => "claude-sonnet-4-20250514",
          "usage" => {"input_tokens" => 1, "output_tokens" => 1}
        })

        expect(http).to receive(:request) do |req|
          body = JSON.parse(req.body)
          expect(body).not_to have_key("stream")

          instance_double(Net::HTTPOK,
            code: "200",
            body: JSON.generate({
              "content" => [{"type" => "text", "text" => "ok"}],
              "model" => "claude-sonnet-4-20250514",
              "usage" => {"input_tokens" => 1, "output_tokens" => 1}
            }))
        end

        response = transport.chat(
          messages: [{role: "user", content: "Hello"}],
          stream: true
        )

        expect(response.output).to eq("ok")
        expect(response.metadata[:transport]).to eq(:http)
        expect(response.metadata[:stream]).to be_nil
      end
    end
  end
end
