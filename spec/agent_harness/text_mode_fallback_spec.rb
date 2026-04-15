# frozen_string_literal: true

RSpec.describe "Text mode CLI fallback" do
  let(:mock_executor) { instance_double(AgentHarness::CommandExecutor) }
  let(:config) { AgentHarness::ProviderConfig.new(:claude) }

  let(:success_result) do
    AgentHarness::CommandExecutor::Result.new(
      stdout: '{"result":"response","usage":{"input_tokens":10,"output_tokens":5}}',
      stderr: "",
      exit_code: 0,
      duration: 1.0
    )
  end

  describe "provider that does not support text mode" do
    # Use Anthropic but test via Base's fallback path by creating a provider
    # that does NOT override supports_text_mode? (it defaults to false).
    let(:provider_class) do
      Class.new(AgentHarness::Providers::Base) do
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

        def supports_tool_control?
          true
        end

        protected

        def build_command(prompt, options)
          cmd = ["test-cli", "--print"]
          if options[:tools] == :none
            cmd += ["--no-tools"]
          end
          cmd << prompt
          cmd
        end
      end
    end

    let(:provider) do
      provider_class.new(config: config, executor: mock_executor)
    end

    it "does not support text mode" do
      expect(provider.supports_text_mode?).to be false
    end

    it "falls back to CLI with tools: :none when mode: :text is requested" do
      expect(mock_executor).to receive(:execute) do |cmd, **_opts|
        expect(cmd).to include("--no-tools")
        success_result
      end

      provider.send_message(prompt: "Summarize", mode: :text)
    end

    it "strips the mode option before forwarding to the CLI path" do
      expect(mock_executor).to receive(:execute) do |cmd, **_opts|
        # The mode option should not appear in the command
        expect(cmd).not_to include("--mode")
        expect(cmd).not_to include(":text")
        success_result
      end

      provider.send_message(prompt: "Summarize", mode: :text)
    end

    it "returns a valid Response" do
      allow(mock_executor).to receive(:execute).and_return(success_result)

      response = provider.send_message(prompt: "Summarize", mode: :text)

      expect(response).to be_a(AgentHarness::Response)
      expect(response.success?).to be true
    end
  end

  describe "Anthropic provider with text mode" do
    let(:anthropic_config) do
      AgentHarness::ProviderConfig.new(:claude).tap do |c|
        c.model = "claude-3-5-sonnet"
      end
    end

    let(:anthropic_provider) do
      AgentHarness::Providers::Anthropic.new(config: anthropic_config, executor: mock_executor)
    end

    it "supports text mode" do
      expect(anthropic_provider.supports_text_mode?).to be true
    end

    it "routes to HTTP transport (not CLI) when mode: :text and API key is set" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return("sk-ant-test")

      http_response = instance_double(Net::HTTPOK,
        code: "200",
        body: JSON.generate({
          "content" => [{"type" => "text", "text" => "HTTP response"}],
          "usage" => {"input_tokens" => 10, "output_tokens" => 5}
        }))

      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:request).and_return(http_response)

      # CLI executor should NOT be called
      expect(mock_executor).not_to receive(:execute)

      response = anthropic_provider.send_message(prompt: "Summarize", mode: :text)
      expect(response.output).to eq("HTTP response")
      expect(response.metadata[:transport]).to eq(:http)
    end

    it "uses CLI normally when mode is not :text" do
      allow(mock_executor).to receive(:execute).and_return(success_result)

      # Should use CLI, not HTTP
      expect(mock_executor).to receive(:execute).with(
        array_including("claude", "--print"),
        anything
      )

      anthropic_provider.send_message(prompt: "Hello")
    end
  end
end
