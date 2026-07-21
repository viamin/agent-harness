# frozen_string_literal: true

require "logger"
require "net/http"

RSpec.describe AgentHarness::OpenAICompatibleTransport do
  let(:base_url) { "https://api.openai.com/v1" }
  let(:api_key) { "sk-test-key-123" }
  let(:model) { "gpt-4o" }
  let(:logger) { instance_double(Logger, debug: nil, error: nil, warn: nil) }
  let(:transport) { described_class.new(base_url: base_url, api_key: api_key, model: model, logger: logger) }

  def stub_api_response(status:, body:)
    http_response = instance_double(Net::HTTPOK,
      code: status.to_s,
      body: JSON.generate(body))
    allow(http_response).to receive(:each_header).and_return({})
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
    allow(http_response).to receive(:each_header).and_return({})
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
    allow(http_response).to receive(:each_header).and_return({})

    allow(http).to receive(:request) do |_req, &block|
      allow(http_response).to receive(:read_body) do |&body_block|
        chunks.each { |chunk| body_block.call(chunk) }
      end
      block.call(http_response)
    end

    http
  end

  describe "#chat" do
    context "non-streaming successful response" do
      it "returns a Response with extracted text content" do
        stub_api_response(status: 200, body: {
          "id" => "chatcmpl-123",
          "object" => "chat.completion",
          "model" => "gpt-4o",
          "choices" => [
            {"index" => 0, "message" => {"role" => "assistant", "content" => "Hello, world!"}, "finish_reason" => "stop"}
          ],
          "usage" => {"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
        })

        response = transport.chat(messages: [{role: "user", content: "Say hello"}])

        expect(response).to be_a(AgentHarness::Response)
        expect(response.output).to eq("Hello, world!")
        expect(response.success?).to be true
        expect(response.exit_code).to eq(0)
        expect(response.provider).to eq(:openai_compatible)
        expect(response.model).to eq("gpt-4o")
        expect(response.metadata[:transport]).to eq(:http)
        expect(response.metadata[:stream]).to be false
      end

      it "extracts token usage" do
        stub_api_response(status: 200, body: {
          "choices" => [{"message" => {"content" => "response"}}],
          "usage" => {"prompt_tokens" => 100, "completion_tokens" => 50, "total_tokens" => 150}
        })

        response = transport.chat(messages: [{role: "user", content: "prompt"}])

        expect(response.tokens).to eq({input: 100, output: 50, total: 150})
        expect(response.input_tokens).to eq(100)
        expect(response.output_tokens).to eq(50)
        expect(response.total_tokens).to eq(150)
      end

      it "preserves response headers in metadata" do
        http_response = instance_double(Net::HTTPOK,
          code: "200",
          body: JSON.generate({
            "choices" => [{"message" => {"content" => "ok"}}],
            "usage" => {"prompt_tokens" => 1, "completion_tokens" => 1}
          }))
        allow(http_response).to receive(:each_header).and_yield("x-ratelimit-limit-tokens", "1000")
          .and_yield("x-ratelimit-remaining-tokens", "900")

        http = instance_double(Net::HTTP)
        allow(Net::HTTP).to receive(:new).and_return(http)
        allow(http).to receive(:use_ssl=)
        allow(http).to receive(:open_timeout=)
        allow(http).to receive(:read_timeout=)
        allow(http).to receive(:request).and_return(http_response)

        response = transport.chat(messages: [{role: "user", content: "prompt"}])

        expect(response.metadata[:headers]).to include(
          "x-ratelimit-limit-tokens" => "1000",
          "x-ratelimit-remaining-tokens" => "900"
        )
      end

      it "handles missing content" do
        stub_api_response(status: 200, body: {
          "choices" => [{"message" => {"role" => "assistant"}}],
          "usage" => {"prompt_tokens" => 10, "completion_tokens" => 0}
        })

        response = transport.chat(messages: [{role: "user", content: "prompt"}])

        expect(response.output).to eq("")
      end

      it "handles empty choices" do
        stub_api_response(status: 200, body: {
          "choices" => [],
          "usage" => {"prompt_tokens" => 10, "completion_tokens" => 0}
        })

        response = transport.chat(messages: [{role: "user", content: "prompt"}])

        expect(response.output).to eq("")
      end

      it "handles missing usage data" do
        stub_api_response(status: 200, body: {
          "choices" => [{"message" => {"content" => "response"}}]
        })

        response = transport.chat(messages: [{role: "user", content: "prompt"}])

        expect(response.tokens).to be_nil
      end

      it "sends correct headers" do
        http = stub_api_response(status: 200, body: {
          "choices" => [{"message" => {"content" => "ok"}}],
          "usage" => {"prompt_tokens" => 1, "completion_tokens" => 1}
        })

        expect(http).to receive(:request) do |req|
          expect(req["Content-Type"]).to eq("application/json")
          expect(req["Authorization"]).to eq("Bearer sk-test-key-123")
          expect(req["User-Agent"]).to eq("AgentHarness/1.0")

          body = JSON.parse(req.body)
          expect(body["messages"]).to eq([{"role" => "user", "content" => "test prompt"}])
          expect(body["model"]).to eq("gpt-4o")
          expect(body["max_tokens"]).to eq(4096)

          instance_double(Net::HTTPOK,
            code: "200",
            body: JSON.generate({
              "choices" => [{"message" => {"content" => "ok"}}],
              "usage" => {"prompt_tokens" => 1, "completion_tokens" => 1}
            }))
        end

        transport.chat(messages: [{role: "user", content: "test prompt"}])
      end

      it "includes temperature when provided" do
        http = stub_api_response(status: 200, body: {
          "choices" => [{"message" => {"content" => "ok"}}],
          "usage" => {"prompt_tokens" => 1, "completion_tokens" => 1}
        })

        expect(http).to receive(:request) do |req|
          body = JSON.parse(req.body)
          expect(body["temperature"]).to eq(0.7)

          instance_double(Net::HTTPOK,
            code: "200",
            body: JSON.generate({
              "choices" => [{"message" => {"content" => "ok"}}],
              "usage" => {"prompt_tokens" => 1, "completion_tokens" => 1}
            }))
        end

        transport.chat(messages: [{role: "user", content: "prompt"}], temperature: 0.7)
      end

      it "records duration" do
        stub_api_response(status: 200, body: {
          "choices" => [{"message" => {"content" => "ok"}}],
          "usage" => {"prompt_tokens" => 1, "completion_tokens" => 1}
        })

        response = transport.chat(messages: [{role: "user", content: "prompt"}])

        expect(response.duration).to be_a(Float)
        expect(response.duration).to be >= 0
      end

      it "preserves a per-request model override when the response omits model" do
        stub_api_response(status: 200, body: {
          "choices" => [{"message" => {"content" => "ok"}}],
          "usage" => {"prompt_tokens" => 1, "completion_tokens" => 1}
        })

        response = transport.chat(
          messages: [{role: "user", content: "prompt"}],
          model: "gpt-4.1-mini"
        )

        expect(response.model).to eq("gpt-4.1-mini")
      end
    end

    context "tool calling" do
      it "sends tools in request body" do
        tools = [
          {
            type: "function",
            function: {
              name: "list_projects",
              description: "List user's projects",
              parameters: {type: "object", properties: {}, required: []}
            }
          }
        ]

        http = stub_api_response(status: 200, body: {
          "choices" => [{"message" => {"content" => "ok"}}],
          "usage" => {"prompt_tokens" => 1, "completion_tokens" => 1}
        })

        expect(http).to receive(:request) do |req|
          body = JSON.parse(req.body)
          expect(body["tools"]).to be_a(Array)
          expect(body["tools"][0]["type"]).to eq("function")
          expect(body["tools"][0]["function"]["name"]).to eq("list_projects")

          instance_double(Net::HTTPOK,
            code: "200",
            body: JSON.generate({
              "choices" => [{"message" => {"content" => "ok"}}],
              "usage" => {"prompt_tokens" => 1, "completion_tokens" => 1}
            }))
        end

        transport.chat(messages: [{role: "user", content: "prompt"}], tools: tools)
      end

      it "extracts tool calls from response" do
        stub_api_response(status: 200, body: {
          "choices" => [{
            "message" => {
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                {
                  "id" => "call_abc123",
                  "type" => "function",
                  "function" => {
                    "name" => "list_projects",
                    "arguments" => '{"status":"active"}'
                  }
                }
              ]
            }
          }],
          "usage" => {"prompt_tokens" => 20, "completion_tokens" => 15}
        })

        response = transport.chat(messages: [{role: "user", content: "List my projects"}])

        expect(response.metadata[:tool_calls]).to eq([
          {id: "call_abc123", name: "list_projects", arguments: '{"status":"active"}'}
        ])
      end
    end

    context "streaming" do
      it "yields text chunks and returns accumulated response" do
        chunks = [
          "data: #{JSON.generate({"choices" => [{"delta" => {"role" => "assistant"}}], "model" => "gpt-4o"})}\n\n",
          "data: #{JSON.generate({"choices" => [{"delta" => {"content" => "Hello"}}]})}\n\n",
          "data: #{JSON.generate({"choices" => [{"delta" => {"content" => ", world!"}}]})}\n\n",
          "data: #{JSON.generate({"usage" => {"prompt_tokens" => 10, "completion_tokens" => 5}})}\n\n",
          "data: [DONE]\n\n"
        ]

        stub_streaming_response(status: 200, chunks: chunks)

        received_chunks = []
        response = transport.chat(
          messages: [{role: "user", content: "Say hello"}],
          stream: true
        ) { |chunk| received_chunks << chunk }

        text_chunks = received_chunks.select { |c| c[:type] == :text }
        expect(text_chunks.map { |c| c[:content] }).to eq(["Hello", ", world!"])

        usage_chunks = received_chunks.select { |c| c[:type] == :usage }
        expect(usage_chunks.length).to eq(1)
        expect(usage_chunks[0]).to eq({type: :usage, input_tokens: 10, output_tokens: 5})

        done_chunks = received_chunks.select { |c| c[:type] == :done }
        expect(done_chunks.length).to eq(1)
        expect(done_chunks[0]).to eq({type: :done})

        expect(response.output).to eq("Hello, world!")
        expect(response.success?).to be true
        expect(response.metadata[:stream]).to be true
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "preserves a per-request model override when streamed events omit model" do
        chunks = [
          "data: #{JSON.generate({"choices" => [{"delta" => {"content" => "Hello"}}]})}\n\n",
          "data: #{JSON.generate({"usage" => {"prompt_tokens" => 10, "completion_tokens" => 5}})}\n\n",
          "data: [DONE]\n\n"
        ]

        stub_streaming_response(status: 200, chunks: chunks)

        response = transport.chat(
          messages: [{role: "user", content: "Say hello"}],
          model: "gpt-4.1-mini",
          stream: true
        ) { |_chunk| }

        expect(response.model).to eq("gpt-4.1-mini")
      end

      it "handles streamed tool calls with structured chunk types" do
        chunks = [
          "data: #{JSON.generate({
            "choices" => [{"delta" => {"role" => "assistant", "tool_calls" => [{"index" => 0, "id" => "call_abc", "function" => {"name" => "get_weather", "arguments" => ""}}]}}]
          })}\n\n",
          "data: #{JSON.generate({
            "choices" => [{"delta" => {"tool_calls" => [{"index" => 0, "function" => {"arguments" => '{"loc'}}]}}]
          })}\n\n",
          "data: #{JSON.generate({
            "choices" => [{"delta" => {"tool_calls" => [{"index" => 0, "function" => {"arguments" => 'ation":"NYC"}'}}]}}]
          })}\n\n",
          "data: #{JSON.generate({
            "choices" => [{"delta" => {}, "finish_reason" => "tool_calls"}]
          })}\n\n",
          "data: #{JSON.generate({"usage" => {"prompt_tokens" => 15, "completion_tokens" => 10}})}\n\n",
          "data: [DONE]\n\n"
        ]

        stub_streaming_response(status: 200, chunks: chunks)

        received_chunks = []
        response = transport.chat(
          messages: [{role: "user", content: "Weather?"}],
          stream: true
        ) { |chunk| received_chunks << chunk }

        start_chunks = received_chunks.select { |c| c[:type] == :tool_call_start }
        expect(start_chunks.length).to eq(1)
        expect(start_chunks[0]).to eq({type: :tool_call_start, id: "call_abc", name: "get_weather"})

        delta_chunks = received_chunks.select { |c| c[:type] == :tool_call_delta }
        expect(delta_chunks.length).to eq(2)
        expect(delta_chunks[0]).to eq({type: :tool_call_delta, id: "call_abc", arguments: '{"loc'})
        expect(delta_chunks[1]).to eq({type: :tool_call_delta, id: "call_abc", arguments: 'ation":"NYC"}'})

        complete_chunks = received_chunks.select { |c| c[:type] == :tool_call_complete }
        expect(complete_chunks.length).to eq(1)
        expect(complete_chunks[0]).to eq({
          type: :tool_call_complete, id: "call_abc",
          name: "get_weather", arguments: '{"location":"NYC"}'
        })

        expect(response.metadata[:tool_calls]).to eq([
          {id: "call_abc", name: "get_weather", arguments: '{"location":"NYC"}'}
        ])
      end

      it "sends stream and stream_options in request body" do
        chunks = [
          "data: #{JSON.generate({"choices" => [{"delta" => {"content" => "ok"}}]})}\n\n",
          "data: #{JSON.generate({"usage" => {"prompt_tokens" => 1, "completion_tokens" => 1}})}\n\n",
          "data: [DONE]\n\n"
        ]

        http = stub_streaming_response(status: 200, chunks: chunks)

        expect(http).to receive(:request) do |req, &block|
          body = JSON.parse(req.body)
          expect(body["stream"]).to be true
          expect(body["stream_options"]).to eq({"include_usage" => true})

          http_response = instance_double(Net::HTTPOK, code: "200")
          allow(http_response).to receive(:read_body) do |&body_block|
            chunks.each { |chunk| body_block.call(chunk) }
          end
          block.call(http_response)
        end

        transport.chat(
          messages: [{role: "user", content: "prompt"}],
          stream: true
        ) { |_chunk| }
      end

      it "delivers events to on_chat_chunk proc" do
        chunks = [
          "data: #{JSON.generate({"choices" => [{"delta" => {"content" => "Hi"}}]})}\n\n",
          "data: #{JSON.generate({"usage" => {"prompt_tokens" => 5, "completion_tokens" => 2}})}\n\n",
          "data: [DONE]\n\n"
        ]

        stub_streaming_response(status: 200, chunks: chunks)

        received = []
        transport.chat(
          messages: [{role: "user", content: "prompt"}],
          stream: true,
          on_chat_chunk: proc { |chunk| received << chunk }
        )

        expect(received.map { |c| c[:type] }).to eq([:text, :usage, :done])
        expect(received[0][:content]).to eq("Hi")
      end

      it "delivers events to observer responding to on_chat_chunk" do
        chunks = [
          "data: #{JSON.generate({"choices" => [{"delta" => {"content" => "Hi"}}]})}\n\n",
          "data: #{JSON.generate({"usage" => {"prompt_tokens" => 5, "completion_tokens" => 2}})}\n\n",
          "data: [DONE]\n\n"
        ]

        stub_streaming_response(status: 200, chunks: chunks)

        observer = double("observer")
        allow(observer).to receive(:respond_to?).and_return(false)
        allow(observer).to receive(:respond_to?).with(:on_chat_chunk).and_return(true)
        allow(observer).to receive(:on_chat_chunk)

        transport.chat(
          messages: [{role: "user", content: "prompt"}],
          stream: true,
          observer: observer
        )

        expect(observer).to have_received(:on_chat_chunk).with({type: :text, content: "Hi"})
        expect(observer).to have_received(:on_chat_chunk).with({type: :usage, input_tokens: 5, output_tokens: 2})
        expect(observer).to have_received(:on_chat_chunk).with({type: :done})
      end

      it "delivers events to block, on_chat_chunk, and observer simultaneously" do
        chunks = [
          "data: #{JSON.generate({"choices" => [{"delta" => {"content" => "Hi"}}]})}\n\n",
          "data: #{JSON.generate({"usage" => {"prompt_tokens" => 5, "completion_tokens" => 2}})}\n\n",
          "data: [DONE]\n\n"
        ]

        stub_streaming_response(status: 200, chunks: chunks)

        block_received = []
        proc_received = []
        observer = double("observer")
        allow(observer).to receive(:respond_to?).and_return(false)
        allow(observer).to receive(:respond_to?).with(:on_chat_chunk).and_return(true)
        allow(observer).to receive(:on_chat_chunk)

        transport.chat(
          messages: [{role: "user", content: "prompt"}],
          stream: true,
          on_chat_chunk: proc { |chunk| proc_received << chunk },
          observer: observer
        ) { |chunk| block_received << chunk }

        expect(block_received.length).to eq(3)
        expect(proc_received.length).to eq(3)
        expect(observer).to have_received(:on_chat_chunk).exactly(3).times
      end

      it "falls back to a non-streaming request when no stream receiver is attached" do
        http = stub_api_response(status: 200, body: {
          "choices" => [{"message" => {"content" => "ok"}}],
          "usage" => {"prompt_tokens" => 1, "completion_tokens" => 1}
        })

        expect(http).to receive(:request) do |req|
          body = JSON.parse(req.body)
          expect(body).not_to have_key("stream")
          expect(body).not_to have_key("stream_options")

          instance_double(Net::HTTPOK,
            code: "200",
            body: JSON.generate({
              "choices" => [{"message" => {"content" => "ok"}}],
              "usage" => {"prompt_tokens" => 1, "completion_tokens" => 1}
            }))
        end

        response = transport.chat(
          messages: [{role: "user", content: "prompt"}],
          stream: true
        )

        expect(response.output).to eq("ok")
        expect(response.metadata[:stream]).to be false
      end
    end

    context "error responses" do
      it "raises AuthenticationError on 401" do
        stub_api_response(status: 401, body: {
          "error" => {"message" => "Incorrect API key provided", "type" => "invalid_request_error"}
        })

        expect { transport.chat(messages: [{role: "user", content: "prompt"}]) }
          .to raise_error(AgentHarness::AuthenticationError, /Incorrect API key/) do |error|
            expect(error.provider).to eq(:openai_compatible)
          end
      end

      it "raises AuthenticationError on 403" do
        stub_api_response(status: 403, body: {
          "error" => {"message" => "access denied", "type" => "forbidden"}
        })

        expect { transport.chat(messages: [{role: "user", content: "prompt"}]) }
          .to raise_error(AgentHarness::AuthenticationError, /access denied/)
      end

      it "raises RateLimitError on 429" do
        stub_api_response(status: 429, body: {
          "error" => {"message" => "Rate limit reached", "type" => "rate_limit_error"}
        })

        expect { transport.chat(messages: [{role: "user", content: "prompt"}]) }
          .to raise_error(AgentHarness::RateLimitError, /Rate limit/)
      end

      it "raises ProviderError on 400" do
        stub_api_response(status: 400, body: {
          "error" => {"message" => "invalid model", "type" => "invalid_request_error"}
        })

        expect { transport.chat(messages: [{role: "user", content: "prompt"}]) }
          .to raise_error(AgentHarness::ProviderError, /invalid model/)
      end

      it "raises ProviderError on 500" do
        stub_api_response(status: 500, body: {
          "error" => {"message" => "internal error", "type" => "server_error"}
        })

        expect { transport.chat(messages: [{role: "user", content: "prompt"}]) }
          .to raise_error(AgentHarness::ProviderError, /internal error/)
      end

      it "raises ProviderError on 503" do
        stub_api_response(status: 503, body: {
          "error" => {"message" => "service unavailable"}
        })

        expect { transport.chat(messages: [{role: "user", content: "prompt"}]) }
          .to raise_error(AgentHarness::ProviderError, /service unavailable/)
      end

      it "handles non-JSON error responses" do
        stub_raw_api_response(status: 502, body_string: "Bad Gateway")

        expect { transport.chat(messages: [{role: "user", content: "prompt"}]) }
          .to raise_error(AgentHarness::ProviderError, /Bad Gateway/)
      end

      it "raises ProviderError for unexpected status codes" do
        stub_api_response(status: 418, body: {
          "error" => {"message" => "I'm a teapot"}
        })

        expect { transport.chat(messages: [{role: "user", content: "prompt"}]) }
          .to raise_error(AgentHarness::ProviderError, /418/)
      end

      it "raises errors for streaming error responses" do
        http = instance_double(Net::HTTP)
        allow(Net::HTTP).to receive(:new).and_return(http)
        allow(http).to receive(:use_ssl=)
        allow(http).to receive(:open_timeout=)
        allow(http).to receive(:read_timeout=)

        error_body = JSON.generate({"error" => {"message" => "Incorrect API key"}})
        http_response = instance_double(Net::HTTPOK, code: "401")
        allow(http_response).to receive(:read_body).and_return(error_body)

        allow(http).to receive(:request) do |_req, &block|
          block.call(http_response)
        end

        expect {
          transport.chat(
            messages: [{role: "user", content: "prompt"}],
            stream: true
          ) { |_chunk| }
        }.to raise_error(AgentHarness::AuthenticationError, /Incorrect API key/)
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

        expect { transport.chat(messages: [{role: "user", content: "prompt"}]) }
          .to raise_error(AgentHarness::TimeoutError, /connection timed out/)
      end

      it "raises TimeoutError on read timeout" do
        http = instance_double(Net::HTTP)
        allow(Net::HTTP).to receive(:new).and_return(http)
        allow(http).to receive(:use_ssl=)
        allow(http).to receive(:open_timeout=)
        allow(http).to receive(:read_timeout=)
        allow(http).to receive(:request).and_raise(Net::ReadTimeout.new("read timed out"))

        expect { transport.chat(messages: [{role: "user", content: "prompt"}]) }
          .to raise_error(AgentHarness::TimeoutError, /read timed out/)
      end

      it "raises ProviderError on connection refused" do
        http = instance_double(Net::HTTP)
        allow(Net::HTTP).to receive(:new).and_return(http)
        allow(http).to receive(:use_ssl=)
        allow(http).to receive(:open_timeout=)
        allow(http).to receive(:read_timeout=)
        allow(http).to receive(:request).and_raise(Errno::ECONNREFUSED)

        expect { transport.chat(messages: [{role: "user", content: "prompt"}]) }
          .to raise_error(AgentHarness::ProviderError, /connection error/i)
      end

      it "raises ProviderError on socket error" do
        http = instance_double(Net::HTTP)
        allow(Net::HTTP).to receive(:new).and_return(http)
        allow(http).to receive(:use_ssl=)
        allow(http).to receive(:open_timeout=)
        allow(http).to receive(:read_timeout=)
        allow(http).to receive(:request).and_raise(SocketError.new("getaddrinfo: Name or service not known"))

        expect { transport.chat(messages: [{role: "user", content: "prompt"}]) }
          .to raise_error(AgentHarness::ProviderError, /connection error/i)
      end
    end

    context "multi-turn messages" do
      it "sends full message array including tool results" do
        messages = [
          {role: "system", content: "You are a helpful assistant"},
          {role: "user", content: "What's the weather?"},
          {role: "assistant", content: nil, tool_calls: [
            {id: "call_1", type: "function", function: {name: "get_weather", arguments: '{"location":"NYC"}'}}
          ]},
          {role: "tool", tool_call_id: "call_1", content: '{"temp": 72}'},
          {role: "assistant", content: "It's 72 degrees in NYC."}
        ]

        http = stub_api_response(status: 200, body: {
          "choices" => [{"message" => {"content" => "Anything else?"}}],
          "usage" => {"prompt_tokens" => 50, "completion_tokens" => 5}
        })

        expect(http).to receive(:request) do |req|
          body = JSON.parse(req.body)
          expect(body["messages"].length).to eq(5)
          expect(body["messages"][0]["role"]).to eq("system")
          expect(body["messages"][3]["role"]).to eq("tool")

          instance_double(Net::HTTPOK,
            code: "200",
            body: JSON.generate({
              "choices" => [{"message" => {"content" => "Anything else?"}}],
              "usage" => {"prompt_tokens" => 50, "completion_tokens" => 5}
            }))
        end

        transport.chat(messages: messages)
      end
    end

    context "GitHub Models compatibility" do
      it "works with GitHub Models base URL" do
        github_transport = described_class.new(
          base_url: "https://models.inference.ai.azure.com",
          api_key: "ghp_test_token",
          model: "gpt-4o"
        )

        http = stub_api_response(status: 200, body: {
          "choices" => [{"message" => {"content" => "Hello from GitHub Models!"}}],
          "usage" => {"prompt_tokens" => 5, "completion_tokens" => 5}
        })

        expect(http).to receive(:request) do |req|
          expect(req["Authorization"]).to eq("Bearer ghp_test_token")

          instance_double(Net::HTTPOK,
            code: "200",
            body: JSON.generate({
              "choices" => [{"message" => {"content" => "Hello from GitHub Models!"}}],
              "usage" => {"prompt_tokens" => 5, "completion_tokens" => 5}
            }))
        end

        response = github_transport.chat(messages: [{role: "user", content: "Hi"}])

        expect(response.output).to eq("Hello from GitHub Models!")
      end
    end

    context "base_url handling" do
      it "strips trailing slash from base_url" do
        transport_with_slash = described_class.new(
          base_url: "https://api.openai.com/v1/",
          api_key: api_key,
          model: model
        )

        http = stub_api_response(status: 200, body: {
          "choices" => [{"message" => {"content" => "ok"}}],
          "usage" => {"prompt_tokens" => 1, "completion_tokens" => 1}
        })

        expect(http).to receive(:request) do |req|
          expect(req.path).to eq("/v1/chat/completions")

          instance_double(Net::HTTPOK,
            code: "200",
            body: JSON.generate({
              "choices" => [{"message" => {"content" => "ok"}}],
              "usage" => {"prompt_tokens" => 1, "completion_tokens" => 1}
            }))
        end

        transport_with_slash.chat(messages: [{role: "user", content: "prompt"}])
      end
    end
  end
end
