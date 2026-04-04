# frozen_string_literal: true

RSpec.describe AgentHarness::Providers::Base, "#send_message" do
  let(:mock_executor) do
    instance_double(AgentHarness::CommandExecutor).tap do |executor|
      allow(executor).to receive(:execute).and_return(
        AgentHarness::CommandExecutor::Result.new(
          stdout: "response output",
          stderr: "",
          exit_code: 0,
          duration: 1.0
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

      def name
        "test_provider"
      end

      protected

      def build_command(prompt, options)
        cmd = [self.class.binary_name, "--prompt", prompt]
        cmd += ["--model", @config.model] if @config.model
        cmd
      end

      def default_timeout
        60
      end
    end
  end

  let(:config) do
    AgentHarness::ProviderConfig.new(:test_provider).tap do |c|
      c.model = "test-model"
      c.timeout = 120
    end
  end

  subject(:provider) { test_provider_class.new(config: config, executor: mock_executor) }

  describe "successful execution" do
    it "returns a Response object" do
      response = provider.send_message(prompt: "Hello")
      expect(response).to be_a(AgentHarness::Response)
    end

    it "includes output from command" do
      response = provider.send_message(prompt: "Hello")
      expect(response.output).to eq("response output")
    end

    it "includes exit code" do
      response = provider.send_message(prompt: "Hello")
      expect(response.exit_code).to eq(0)
    end

    it "includes provider name" do
      response = provider.send_message(prompt: "Hello")
      expect(response.provider).to eq(:test_provider)
    end

    it "includes model" do
      response = provider.send_message(prompt: "Hello")
      expect(response.model).to eq("test-model")
    end

    it "is successful" do
      response = provider.send_message(prompt: "Hello")
      expect(response.success?).to be true
    end
  end

  describe "failed execution" do
    before do
      allow(mock_executor).to receive(:execute).and_return(
        AgentHarness::CommandExecutor::Result.new(
          stdout: "",
          stderr: "error message",
          exit_code: 1,
          duration: 1.0
        )
      )
    end

    it "returns a failed response" do
      response = provider.send_message(prompt: "Hello")
      expect(response.failed?).to be true
    end

    it "includes error information" do
      response = provider.send_message(prompt: "Hello")
      expect(response.error).not_to be_nil
    end
  end

  describe "combined stdout+stderr error classification" do
    it "combines stderr and stdout when both are present" do
      allow(mock_executor).to receive(:execute).and_return(
        AgentHarness::CommandExecutor::Result.new(
          stdout: "stdout error detail",
          stderr: "stderr error detail",
          exit_code: 1,
          duration: 1.0
        )
      )

      response = provider.send_message(prompt: "Hello")
      expect(response.error).to include("stderr error detail")
      expect(response.error).to include("stdout error detail")
    end

    it "uses only stdout when stderr is empty" do
      allow(mock_executor).to receive(:execute).and_return(
        AgentHarness::CommandExecutor::Result.new(
          stdout: "stdout-only error",
          stderr: "",
          exit_code: 1,
          duration: 1.0
        )
      )

      response = provider.send_message(prompt: "Hello")
      expect(response.error).to eq("stdout-only error")
    end

    it "uses only stderr when stdout is empty" do
      allow(mock_executor).to receive(:execute).and_return(
        AgentHarness::CommandExecutor::Result.new(
          stdout: "",
          stderr: "stderr-only error",
          exit_code: 1,
          duration: 1.0
        )
      )

      response = provider.send_message(prompt: "Hello")
      expect(response.error).to eq("stderr-only error")
    end

    it "returns nil error when both streams are empty" do
      allow(mock_executor).to receive(:execute).and_return(
        AgentHarness::CommandExecutor::Result.new(
          stdout: "",
          stderr: "",
          exit_code: 1,
          duration: 1.0
        )
      )

      response = provider.send_message(prompt: "Hello")
      expect(response.error).to be_nil
    end
  end

  describe "timeout handling" do
    before do
      allow(mock_executor).to receive(:execute).and_raise(
        AgentHarness::TimeoutError.new("Command timed out")
      )
    end

    it "raises TimeoutError" do
      expect { provider.send_message(prompt: "Hello") }.to raise_error(AgentHarness::TimeoutError)
    end
  end

  describe "rate limit handling" do
    before do
      allow(mock_executor).to receive(:execute).and_raise(
        StandardError.new("rate limit exceeded")
      )
    end

    it "raises RateLimitError" do
      expect { provider.send_message(prompt: "Hello") }.to raise_error(AgentHarness::RateLimitError)
    end
  end

  describe "auth error handling" do
    before do
      allow(mock_executor).to receive(:execute).and_raise(
        StandardError.new("unauthorized - invalid api key")
      )
    end

    it "raises AuthenticationError" do
      expect { provider.send_message(prompt: "Hello") }.to raise_error(AgentHarness::AuthenticationError)
    end

    it "includes provider name in AuthenticationError" do
      expect { provider.send_message(prompt: "Hello") }.to raise_error(AgentHarness::AuthenticationError) do |error|
        expect(error.provider).to eq(:test_provider)
      end
    end
  end

  describe "generic error handling" do
    before do
      allow(mock_executor).to receive(:execute).and_raise(
        StandardError.new("something went wrong")
      )
    end

    it "raises ProviderError" do
      expect { provider.send_message(prompt: "Hello") }.to raise_error(AgentHarness::ProviderError)
    end
  end

  describe "timeout option" do
    it "uses config timeout" do
      expect(mock_executor).to receive(:execute).with(
        anything,
        hash_including(timeout: 120)
      ).and_return(
        AgentHarness::CommandExecutor::Result.new(stdout: "ok", stderr: "", exit_code: 0, duration: 1.0)
      )

      provider.send_message(prompt: "Hello")
    end

    it "uses option timeout when provided" do
      expect(mock_executor).to receive(:execute).with(
        anything,
        hash_including(timeout: 300)
      ).and_return(
        AgentHarness::CommandExecutor::Result.new(stdout: "ok", stderr: "", exit_code: 0, duration: 1.0)
      )

      provider.send_message(prompt: "Hello", timeout: 300)
    end
  end

  describe "execution hooks" do
    it "passes through idle timeout and streaming callbacks" do
      observer = Object.new

      expect(mock_executor).to receive(:execute).with(
        anything,
        hash_including(
          timeout: 120,
          idle_timeout: 30,
          on_stdout_chunk: kind_of(Proc),
          on_stderr_chunk: kind_of(Proc),
          on_heartbeat: kind_of(Proc),
          heartbeat_interval: 5,
          observer: observer
        )
      ).and_return(
        AgentHarness::CommandExecutor::Result.new(stdout: "ok", stderr: "", exit_code: 0, duration: 1.0)
      )

      provider.send_message(
        prompt: "Hello",
        idle_timeout: 30,
        on_stdout_chunk: ->(_chunk) {},
        on_stderr_chunk: ->(_chunk) {},
        on_heartbeat: ->(**_heartbeat) {},
        heartbeat_interval: 5,
        execution_observer: observer
      )
    end
  end
end
