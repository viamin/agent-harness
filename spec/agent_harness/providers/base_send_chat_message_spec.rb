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
    end
  end

  let(:config) do
    AgentHarness::ProviderConfig.new(:test_provider).tap do |c|
      c.model = "test-model"
    end
  end

  subject(:provider) { test_provider_class.new(config: config, executor: mock_executor) }

  it "raises NotImplementedError by default" do
    expect {
      provider.send_chat_message(messages: [{role: "user", content: "Hello"}])
    }.to raise_error(NotImplementedError, /test_provider does not support chat messages/)
  end
end
