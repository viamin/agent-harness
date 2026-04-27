# frozen_string_literal: true

RSpec.describe AgentHarness::Providers::Base, "#send_chat_message" do
  let(:mock_executor) do
    instance_double(AgentHarness::CommandExecutor).tap do |executor|
      allow(executor).to receive(:execute).and_return(
        AgentHarness::CommandExecutor::Result.new(
          stdout: "", stderr: "", exit_code: 0, duration: 1.0
        )
      )
    end
  end

  let(:test_provider_class) do
    Class.new(described_class) do
      class << self
        def provider_name
          :test_provider
        end

        def binary_name
          "test-cli"
        end

        def available?
          true
        end
      end

      protected

      def build_command(prompt, options)
        [self.class.binary_name, "--prompt", prompt]
      end

      def default_timeout
        60
      end

      def supports_chat?
        true
      end

      def capabilities
        super.merge(tool_use: true)
      end

      attr_reader :chat_transport

      def set_chat_transport(transport)
        @chat_transport = transport
      end

      public :supports_chat?, :capabilities, :chat_transport
    end
  end

  let(:config) do
    AgentHarness::ProviderConfig.new(:test_provider).tap do |c|
      c.model = "test-model"
    end
  end

  subject(:provider) { test_provider_class.new(config: config, executor: mock_executor) }

  it "raises ProviderError by default when chat is unsupported" do
    unsupported_provider = Class.new(described_class) do
      class << self
        def provider_name
          :unsupported_provider
        end
      end
    end.new

    expect {
      unsupported_provider.send_chat_message(messages: [{role: "user", content: "Hello"}])
    }.to raise_error(AgentHarness::ProviderError, /does not support chat mode/)
  end

  it "applies extension hooks to chat messages and tool definitions" do
    extension = Class.new(AgentHarness::Extensions::Base) do
      def name
        :chat_extension
      end

      def system_prompt_additions
        ["Always research first."]
      end

      def tools
        [{type: "function", function: {name: "web_search"}}]
      end

      def on_tools_available(context)
        context.metadata[:tool_hook_called] = true
      end
    end.new

    AgentHarness.configuration.register_extension(extension)

    transport = instance_double("chat transport")
    provider.send(:set_chat_transport, transport)

    expect(transport).to receive(:chat) do |messages:, tools:, **|
      expect(messages.first).to eq({role: "system", content: "Always research first."})
      expect(tools).to eq([{type: "function", function: {name: "web_search"}}])

      AgentHarness::Response.new(
        output: "done",
        exit_code: 0,
        duration: 1.0,
        provider: :test_provider,
        model: "test-model"
      )
    end

    response = provider.send_chat_message(
      conversation: [{role: "user", content: "Hello"}],
      extensions: [:chat_extension]
    )

    expect(response.output).to eq("done")
  end
end
