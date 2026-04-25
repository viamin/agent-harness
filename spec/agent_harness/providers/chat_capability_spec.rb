# frozen_string_literal: true

require "logger"
require "net/http"

RSpec.describe "Provider chat capability" do
  let(:logger) { instance_double(Logger, debug: nil, error: nil, warn: nil) }
  let(:executor) do
    instance_double(AgentHarness::CommandExecutor, which: "/usr/bin/test")
  end

  before do
    allow(AgentHarness.configuration).to receive(:command_executor).and_return(executor)
    allow(AgentHarness).to receive(:logger).and_return(logger)
  end

  describe "Adapter interface defaults" do
    let(:provider_class) do
      Class.new(AgentHarness::Providers::Base) do
        class << self
          def provider_name = :test_provider
          def binary_name = "test-cli"
          def available? = true
        end
      end
    end

    let(:provider) { provider_class.new(config: AgentHarness::ProviderConfig.new(:test_provider), logger: logger) }

    it "supports_chat? returns false by default" do
      expect(provider.supports_chat?).to be false
    end

    it "chat_transport returns nil by default" do
      expect(provider.chat_transport).to be_nil
    end

    it "send_chat_message raises ProviderError when chat not supported" do
      expect {
        provider.send_chat_message(conversation: [{role: "user", content: "hello"}])
      }.to raise_error(AgentHarness::ProviderError, /does not support chat mode/)
    end
  end

  describe AgentHarness::Providers::GithubCopilot do
    let(:config) { AgentHarness::ProviderConfig.new(:github_copilot) }
    let(:provider) { described_class.new(config: config, executor: executor, logger: logger) }

    describe ".supports_chat?" do
      it "returns true" do
        expect(described_class.supports_chat?).to be true
      end
    end

    describe "#supports_chat?" do
      it "returns true" do
        expect(provider.supports_chat?).to be true
      end
    end

    describe "#chat_models" do
      it "returns available chat models" do
        expect(provider.chat_models).to include("gpt-4o", "gpt-4o-mini")
      end
    end

    describe "#chat_transport" do
      before do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("GITHUB_TOKEN").and_return("ghp_test123")
        allow(ENV).to receive(:[]).with("GH_TOKEN").and_return(nil)
      end

      it "returns an OpenAICompatibleTransport" do
        transport = provider.chat_transport
        expect(transport).to be_a(AgentHarness::OpenAICompatibleTransport)
      end

      it "memoizes the transport" do
        transport1 = provider.chat_transport
        transport2 = provider.chat_transport
        expect(transport1).to be(transport2)
      end
    end

    describe "#chat_transport_type" do
      it "returns :openai_compatible without triggering authentication" do
        expect(provider.chat_transport_type).to eq(:openai_compatible)
      end
    end

    describe "#send_chat_message" do
      let(:mock_transport) { instance_double(AgentHarness::OpenAICompatibleTransport) }
      let(:response) do
        AgentHarness::Response.new(
          output: "Hello from GitHub Models!",
          exit_code: 0,
          duration: 1.0,
          provider: :openai_compatible,
          model: "gpt-4o",
          tokens: {input: 10, output: 5, total: 15},
          metadata: {transport: :http}
        )
      end

      before do
        allow(provider).to receive(:chat_transport).and_return(mock_transport)
        allow(mock_transport).to receive(:chat).and_return(response)
        allow(AgentHarness.token_tracker).to receive(:record)
      end

      it "sends conversation history to the transport" do
        conversation = [
          {role: "user", content: "Hello"},
          {role: "assistant", content: "Hi there!"},
          {role: "user", content: "How are you?"}
        ]

        expect(mock_transport).to receive(:chat) do |**kwargs|
          expect(kwargs[:messages]).to eq([
            {role: "user", content: "Hello"},
            {role: "assistant", content: "Hi there!"},
            {role: "user", content: "How are you?"}
          ])
          expect(kwargs[:tools]).to be_nil
          expect(kwargs[:stream]).to be false
          response
        end

        result = provider.send_chat_message(conversation: conversation)
        expect(result.output).to eq("Hello from GitHub Models!")
      end

      it "passes tools to the transport" do
        tools = [{type: "function", function: {name: "get_weather"}}]

        expect(mock_transport).to receive(:chat).with(
          hash_including(tools: tools)
        ).and_return(response)

        provider.send_chat_message(
          conversation: [{role: "user", content: "What's the weather?"}],
          tools: tools
        )
      end

      it "supports streaming mode" do
        chunks = []
        expect(mock_transport).to receive(:chat).with(
          hash_including(stream: true)
        ).and_return(response)

        provider.send_chat_message(
          conversation: [{role: "user", content: "Hello"}],
          stream: true
        ) { |chunk| chunks << chunk }
      end

      it "tracks tokens from the response" do
        expect(AgentHarness.token_tracker).to receive(:record).with(
          hash_including(input_tokens: 10, output_tokens: 5)
        )

        provider.send_chat_message(conversation: [{role: "user", content: "Hello"}])
      end

      it "passes runtime chat_max_tokens to the transport" do
        runtime = AgentHarness::ProviderRuntime.new(chat_max_tokens: 512)

        expect(mock_transport).to receive(:chat).with(
          hash_including(max_tokens: 512)
        ).and_return(response)

        provider.send_chat_message(
          conversation: [{role: "user", content: "Hello"}],
          provider_runtime: runtime
        )
      end

      it "passes runtime chat_model to the transport" do
        runtime = AgentHarness::ProviderRuntime.new(chat_model: "gpt-4o-mini")

        expect(mock_transport).to receive(:chat).with(
          hash_including(model: "gpt-4o-mini")
        ).and_return(response)

        provider.send_chat_message(
          conversation: [{role: "user", content: "Hello"}],
          provider_runtime: runtime
        )
      end

      it "passes runtime model to the transport when chat_model is not set" do
        runtime = AgentHarness::ProviderRuntime.new(model: "gpt-4-turbo")

        expect(mock_transport).to receive(:chat).with(
          hash_including(model: "gpt-4-turbo")
        ).and_return(response)

        provider.send_chat_message(
          conversation: [{role: "user", content: "Hello"}],
          provider_runtime: runtime
        )
      end

      it "uses a runtime chat transport when chat overrides are provided" do
        runtime = AgentHarness::ProviderRuntime.new(
          chat_base_url: "https://example.test/v1",
          chat_api_key: "ghp_runtime"
        )
        runtime_transport = instance_double(AgentHarness::OpenAICompatibleTransport)

        expect(provider).to receive(:build_runtime_chat_transport).with(runtime).and_return(runtime_transport)
        expect(runtime_transport).to receive(:chat).and_return(response)
        expect(provider).not_to receive(:chat_transport)

        provider.send_chat_message(
          conversation: [{role: "user", content: "Hello"}],
          provider_runtime: runtime
        )
      end
    end

    describe "#resolve_chat_api_key" do
      it "raises AuthenticationError when no token is available" do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("GITHUB_TOKEN").and_return(nil)
        allow(ENV).to receive(:[]).with("GH_TOKEN").and_return(nil)

        expect {
          provider.send(:resolve_chat_api_key)
        }.to raise_error(AgentHarness::AuthenticationError, /GITHUB_TOKEN/)
      end

      it "uses GITHUB_TOKEN when available" do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("GITHUB_TOKEN").and_return("ghp_test123")

        expect(provider.send(:resolve_chat_api_key)).to eq("ghp_test123")
      end

      it "falls back to GH_TOKEN" do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("GITHUB_TOKEN").and_return(nil)
        allow(ENV).to receive(:[]).with("GH_TOKEN").and_return("ghp_fallback")

        expect(provider.send(:resolve_chat_api_key)).to eq("ghp_fallback")
      end
    end
  end

  describe AgentHarness::Providers::Anthropic do
    let(:config) { AgentHarness::ProviderConfig.new(:claude) }
    let(:provider) { described_class.new(config: config, executor: executor, logger: logger) }

    describe ".supports_chat?" do
      it "returns true" do
        expect(described_class.supports_chat?).to be true
      end
    end

    describe "#supports_chat?" do
      it "returns true" do
        expect(provider.supports_chat?).to be true
      end
    end

    describe "#chat_models" do
      it "returns available chat models" do
        expect(provider.chat_models).to include("claude-sonnet-4-20250514")
      end
    end

    describe "#chat_transport" do
      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return("sk-ant-test123")
      end

      it "returns a TextTransport" do
        transport = provider.chat_transport
        expect(transport).to be_a(AgentHarness::TextTransport)
      end

      it "memoizes the transport" do
        transport1 = provider.chat_transport
        transport2 = provider.chat_transport
        expect(transport1).to be(transport2)
      end
    end

    describe "#chat_transport_type" do
      it "returns :anthropic without triggering authentication" do
        expect(provider.chat_transport_type).to eq(:anthropic)
      end
    end

    describe "#send_chat_message" do
      let(:mock_transport) { instance_double(AgentHarness::TextTransport) }
      let(:response) do
        AgentHarness::Response.new(
          output: "Hello from Anthropic!",
          exit_code: 0,
          duration: 1.5,
          provider: :claude,
          model: "claude-sonnet-4-20250514",
          tokens: {input: 20, output: 10, total: 30},
          metadata: {transport: :http}
        )
      end

      before do
        allow(provider).to receive(:chat_transport).and_return(mock_transport)
        allow(mock_transport).to receive(:chat).and_return(response)
        allow(AgentHarness.token_tracker).to receive(:record)
      end

      it "sends conversation history to the transport" do
        conversation = [
          {role: "system", content: "You are helpful."},
          {role: "user", content: "Hello"},
          {role: "assistant", content: "Hi!"},
          {role: "user", content: "Tell me more."}
        ]

        expect(mock_transport).to receive(:chat) do |**kwargs|
          expect(kwargs[:messages]).to eq([
            {role: "system", content: "You are helpful."},
            {role: "user", content: "Hello"},
            {role: "assistant", content: "Hi!"},
            {role: "user", content: "Tell me more."}
          ])
          expect(kwargs[:tools]).to be_nil
          expect(kwargs[:stream]).to be false
          response
        end

        result = provider.send_chat_message(conversation: conversation)
        expect(result.output).to eq("Hello from Anthropic!")
      end

      it "passes tools to the transport" do
        tools = [{name: "calculator", description: "Does math"}]

        expect(mock_transport).to receive(:chat).with(
          hash_including(tools: tools)
        ).and_return(response)

        provider.send_chat_message(
          conversation: [{role: "user", content: "Calculate 2+2"}],
          tools: tools
        )
      end

      it "passes runtime model override to the transport" do
        runtime = AgentHarness::ProviderRuntime.new(model: "claude-opus-4-20250514")

        expect(mock_transport).to receive(:chat).with(
          hash_including(model: "claude-opus-4-20250514")
        ).and_return(response)

        result = provider.send_chat_message(
          conversation: [{role: "user", content: "Hello"}],
          provider_runtime: runtime
        )

        expect(result.model).to eq("claude-sonnet-4-20250514")
      end

      it "uses a runtime chat transport when chat overrides are provided" do
        runtime = AgentHarness::ProviderRuntime.new(
          chat_base_url: "https://anthropic.example.test/v1/messages",
          chat_api_key: "sk-runtime"
        )
        runtime_transport = instance_double(AgentHarness::TextTransport)

        expect(provider).to receive(:build_runtime_chat_transport).with(runtime).and_return(runtime_transport)
        expect(runtime_transport).to receive(:chat).and_return(response)
        expect(provider).not_to receive(:chat_transport)

        provider.send_chat_message(
          conversation: [{role: "user", content: "Hello"}],
          provider_runtime: runtime
        )
      end

      it "raises AuthenticationError when no API key" do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return(nil)

        real_provider = described_class.new(config: config, executor: executor, logger: logger)

        expect {
          real_provider.send_chat_message(conversation: [{role: "user", content: "Hello"}])
        }.to raise_error(AgentHarness::AuthMismatchError, /ANTHROPIC_API_KEY/)
      end
    end
  end

  describe AgentHarness::TextTransport do
    let(:transport) { described_class.new(api_key: "sk-ant-test", logger: logger) }

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

    describe "#chat" do
      it "sends multi-turn messages and returns a Response" do
        stub_api_response(status: 200, body: {
          "content" => [{"type" => "text", "text" => "I'm doing well!"}],
          "model" => "claude-sonnet-4-20250514",
          "usage" => {"input_tokens" => 25, "output_tokens" => 8}
        })

        response = transport.chat(messages: [
          {role: "user", content: "Hello"},
          {role: "assistant", content: "Hi there!"},
          {role: "user", content: "How are you?"}
        ])

        expect(response).to be_a(AgentHarness::Response)
        expect(response.output).to eq("I'm doing well!")
        expect(response.tokens[:input]).to eq(25)
        expect(response.tokens[:output]).to eq(8)
      end

      it "separates system messages from conversation" do
        http = stub_api_response(status: 200, body: {
          "content" => [{"type" => "text", "text" => "OK"}],
          "model" => "claude-sonnet-4-20250514",
          "usage" => {"input_tokens" => 10, "output_tokens" => 2}
        })

        allow(http).to receive(:request) do |req|
          body = JSON.parse(req.body)
          expect(body["system"]).to eq("Be helpful.")
          expect(body["messages"].length).to eq(1)
          expect(body["messages"][0]["role"]).to eq("user")

          instance_double(Net::HTTPOK,
            code: "200",
            body: JSON.generate({
              "content" => [{"type" => "text", "text" => "OK"}],
              "model" => "claude-sonnet-4-20250514",
              "usage" => {"input_tokens" => 10, "output_tokens" => 2}
            }))
        end

        transport.chat(messages: [
          {role: "system", content: "Be helpful."},
          {role: "user", content: "Hello"}
        ])
      end

      it "uses model override when provided" do
        http = stub_api_response(status: 200, body: {
          "content" => [{"type" => "text", "text" => "OK"}],
          "model" => "claude-opus-4-20250514",
          "usage" => {"input_tokens" => 10, "output_tokens" => 2}
        })

        allow(http).to receive(:request) do |req|
          body = JSON.parse(req.body)
          expect(body["model"]).to eq("claude-opus-4-20250514")

          instance_double(Net::HTTPOK,
            code: "200",
            body: JSON.generate({
              "content" => [{"type" => "text", "text" => "OK"}],
              "model" => "claude-opus-4-20250514",
              "usage" => {"input_tokens" => 10, "output_tokens" => 2}
            }))
        end

        response = transport.chat(
          messages: [{role: "user", content: "Hello"}],
          model: "claude-opus-4-20250514"
        )
        expect(response.model).to eq("claude-opus-4-20250514")
      end

      it "includes tools in the request body when provided" do
        http = stub_api_response(status: 200, body: {
          "content" => [{"type" => "text", "text" => "OK"}],
          "model" => "claude-sonnet-4-20250514",
          "usage" => {"input_tokens" => 10, "output_tokens" => 2}
        })

        tools = [
          {name: "calculator", description: "Math tool", input_schema: {type: "object"}}
        ]

        allow(http).to receive(:request) do |req|
          body = JSON.parse(req.body)
          expect(body["tools"]).not_to be_nil

          instance_double(Net::HTTPOK,
            code: "200",
            body: JSON.generate({
              "content" => [{"type" => "text", "text" => "OK"}],
              "model" => "claude-sonnet-4-20250514",
              "usage" => {"input_tokens" => 10, "output_tokens" => 2}
            }))
        end

        transport.chat(messages: [{role: "user", content: "Hi"}], tools: tools)
      end

      it "raises when streaming is requested" do
        expect {
          transport.chat(
            messages: [{role: "user", content: "Hello"}],
            stream: true
          ) { |_chunk| nil }
        }.to raise_error(AgentHarness::ProviderError, /streaming is not implemented/)
      end
    end
  end

  describe AgentHarness::ProviderRuntime do
    it "accepts chat-specific fields" do
      runtime = described_class.new(
        chat_base_url: "https://custom.api.com",
        chat_model: "gpt-4o",
        chat_api_key: "sk-test",
        chat_max_tokens: 2048
      )

      expect(runtime.chat_base_url).to eq("https://custom.api.com")
      expect(runtime.chat_model).to eq("gpt-4o")
      expect(runtime.chat_api_key).to eq("sk-test")
      expect(runtime.chat_max_tokens).to eq(2048)
    end

    it "defaults chat fields to nil" do
      runtime = described_class.new
      expect(runtime.chat_base_url).to be_nil
      expect(runtime.chat_model).to be_nil
      expect(runtime.chat_api_key).to be_nil
      expect(runtime.chat_max_tokens).to be_nil
    end

    it "includes chat fields in empty? check" do
      runtime = described_class.new(chat_model: "gpt-4o")
      expect(runtime.empty?).to be false
    end

    it "round-trips chat fields through from_hash" do
      runtime = described_class.from_hash(
        chat_base_url: "https://api.example.com",
        chat_model: "gpt-4o",
        chat_api_key: "key",
        chat_max_tokens: 1024
      )

      expect(runtime.chat_base_url).to eq("https://api.example.com")
      expect(runtime.chat_model).to eq("gpt-4o")
      expect(runtime.chat_api_key).to eq("key")
      expect(runtime.chat_max_tokens).to eq(1024)
    end

    it "validates chat_max_tokens is Integer or nil" do
      expect {
        described_class.new(chat_max_tokens: "not_a_number")
      }.to raise_error(ArgumentError, /chat_max_tokens/)
    end
  end
end
