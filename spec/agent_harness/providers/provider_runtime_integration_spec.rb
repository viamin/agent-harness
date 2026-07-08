# frozen_string_literal: true

RSpec.describe "ProviderRuntime integration" do
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

  let(:success_result) do
    AgentHarness::CommandExecutor::Result.new(
      stdout: "ok",
      stderr: "",
      exit_code: 0,
      duration: 1.0
    )
  end

  shared_examples "runtime env passthrough" do
    it "passes runtime env vars to the executor" do
      runtime = AgentHarness::ProviderRuntime.new(
        env: {"CUSTOM_KEY" => "custom_value"}
      )

      expect(mock_executor).to receive(:execute).with(
        anything,
        hash_including(env: hash_including("CUSTOM_KEY" => "custom_value"))
      ).and_return(success_result)

      provider.send_message(prompt: "Hello", provider_runtime: runtime)
    end

    it "works without a provider_runtime" do
      expect(mock_executor).to receive(:execute).with(
        anything,
        hash_including(env: {})
      ).and_return(success_result)

      provider.send_message(prompt: "Hello")
    end

    it "passes unset env vars as nil overrides to the executor" do
      runtime = AgentHarness::ProviderRuntime.new(
        env: {"CUSTOM_KEY" => "custom_value"},
        unset_env: [:OPENAI_BASE_URL]
      )

      expect(mock_executor).to receive(:execute).with(
        anything,
        hash_including(env: hash_including("CUSTOM_KEY" => "custom_value", "OPENAI_BASE_URL" => nil))
      ).and_return(success_result)

      provider.send_message(prompt: "Hello", provider_runtime: runtime)
    end
  end

  shared_examples "runtime hash coercion" do
    it "coerces a plain Hash into a ProviderRuntime" do
      expect(mock_executor).to receive(:execute).with(
        anything,
        hash_including(env: hash_including("MY_VAR" => "value"))
      ).and_return(success_result)

      provider.send_message(
        prompt: "Hello",
        provider_runtime: {env: {"MY_VAR" => "value"}}
      )
    end
  end

  describe AgentHarness::Providers::Base do
    let(:test_provider_class) do
      Class.new(described_class) do
        class << self
          def provider_name
            :test_runtime
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
          [self.class.binary_name, prompt]
        end
      end
    end

    let(:provider) { test_provider_class.new(executor: mock_executor) }

    include_examples "runtime env passthrough"
    include_examples "runtime hash coercion"

    it "sets model on response from runtime when config model is nil" do
      runtime = AgentHarness::ProviderRuntime.new(model: "gpt-5-turbo")

      allow(mock_executor).to receive(:execute).and_return(success_result)

      response = provider.send_message(prompt: "Hello", provider_runtime: runtime)
      expect(response.model).to eq("gpt-5-turbo")
    end

    it "records runtime model in token tracking when config model is nil" do
      runtime = AgentHarness::ProviderRuntime.new(model: "gpt-5-turbo")

      # Build a response with tokens so track_tokens is invoked
      token_response = AgentHarness::Response.new(
        output: "ok",
        exit_code: 0,
        duration: 1.0,
        provider: :test_runtime,
        model: nil,
        tokens: {input: 10, output: 20, total: 30}
      )

      allow(mock_executor).to receive(:execute).and_return(success_result)
      allow(provider).to receive(:parse_response).and_return(token_response)

      tracker = instance_double(AgentHarness::TokenTracker)
      allow(AgentHarness).to receive(:token_tracker).and_return(tracker)
      allow(tracker).to receive(:record)

      provider.send_message(prompt: "Hello", provider_runtime: runtime)

      expect(tracker).to have_received(:record).with(
        hash_including(model: "gpt-5-turbo")
      )
    end

    it "keeps config model when runtime model is nil" do
      config = AgentHarness::ProviderConfig.new(:test_runtime)
      config.model = "config-model"
      provider_with_model = test_provider_class.new(config: config, executor: mock_executor)

      allow(mock_executor).to receive(:execute).and_return(success_result)

      response = provider_with_model.send_message(prompt: "Hello", provider_runtime: {})
      expect(response.model).to eq("config-model")
    end

    it "prefers runtime model over config model when both are set" do
      config = AgentHarness::ProviderConfig.new(:test_runtime)
      config.model = "config-model"
      provider_with_model = test_provider_class.new(config: config, executor: mock_executor)

      runtime = AgentHarness::ProviderRuntime.new(model: "runtime-model")

      allow(mock_executor).to receive(:execute).and_return(success_result)

      response = provider_with_model.send_message(prompt: "Hello", provider_runtime: runtime)
      expect(response.model).to eq("runtime-model")
    end

    it "treats a blank runtime model as absent in the response metadata" do
      config = AgentHarness::ProviderConfig.new(:test_runtime)
      config.model = "config-model"
      provider_with_model = test_provider_class.new(config: config, executor: mock_executor)
      runtime = AgentHarness::ProviderRuntime.new(model: "   ")

      allow(mock_executor).to receive(:execute).and_return(success_result)

      response = provider_with_model.send_message(prompt: "Hello", provider_runtime: runtime)
      expect(response.model).to eq("config-model")
    end

    it "records the configured model when the runtime model is blank" do
      config = AgentHarness::ProviderConfig.new(:test_runtime)
      config.model = "config-model"
      provider_with_model = test_provider_class.new(config: config, executor: mock_executor)
      runtime = AgentHarness::ProviderRuntime.new(model: "   ")

      token_response = AgentHarness::Response.new(
        output: "ok",
        exit_code: 0,
        duration: 1.0,
        provider: :test_runtime,
        model: "config-model",
        tokens: {input: 10, output: 20, total: 30}
      )

      allow(mock_executor).to receive(:execute).and_return(success_result)
      allow(provider_with_model).to receive(:parse_response).and_return(token_response)

      tracker = instance_double(AgentHarness::TokenTracker)
      allow(AgentHarness).to receive(:token_tracker).and_return(tracker)
      allow(tracker).to receive(:record)

      provider_with_model.send_message(prompt: "Hello", provider_runtime: runtime)

      expect(tracker).to have_received(:record).with(
        hash_including(model: "config-model")
      )
    end

    it "does not leak inherited host env into executor overrides" do
      runtime = AgentHarness::ProviderRuntime.new(env: {"CUSTOM_KEY" => "custom_value"})

      expect(mock_executor).to receive(:execute) do |_command, options|
        expect(options.fetch(:env)).to eq("CUSTOM_KEY" => "custom_value")
        success_result
      end

      provider.send_message(prompt: "Hello", provider_runtime: runtime)
    end

    it "keeps legacy executors working when no preparation is needed" do
      seen = nil
      legacy_executor = Object.new
      legacy_executor.define_singleton_method(:execute) do |command, timeout:, env:|
        seen = {
          command: command,
          timeout: timeout,
          env: env
        }

        AgentHarness::CommandExecutor::Result.new(
          stdout: "ok",
          stderr: "",
          exit_code: 0,
          duration: 1.0
        )
      end

      response = test_provider_class.new(executor: legacy_executor).send_message(prompt: "Hello")
      expect(response.output).to eq("ok")
      expect(seen).to eq(command: ["test-cli", "Hello"], timeout: 300, env: {})
    end

    it "fails loudly for legacy executors that do not accept preparation" do
      legacy_executor = Object.new
      legacy_executor.define_singleton_method(:execute) do |command, timeout:, env:|
        raise ArgumentError, "unknown keyword: :preparation"
      end

      provider_with_legacy_executor = Class.new(test_provider_class) do
        protected

        def build_execution_preparation(_options)
          AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: "/tmp/test-runtime.json", content: "{\"ok\":true}"}]
          )
        end
      end.new(executor: legacy_executor)

      expect {
        provider_with_legacy_executor.send_message(prompt: "Hello")
      }.to raise_error(
        AgentHarness::ProviderError,
        /must accept the preparation: keyword argument/
      )
    end
  end

  describe AgentHarness::Providers::Opencode do
    let(:provider) { described_class.new(executor: mock_executor) }

    include_examples "runtime env passthrough"
    include_examples "runtime hash coercion"

    it "sets OPENAI_BASE_URL from runtime base_url" do
      runtime = AgentHarness::ProviderRuntime.new(
        base_url: "https://openrouter.ai/api/v1"
      )

      expect(mock_executor).to receive(:execute).with(
        anything,
        hash_including(env: hash_including("OPENAI_BASE_URL" => "https://openrouter.ai/api/v1"))
      ).and_return(success_result)

      provider.send_message(prompt: "Hello", provider_runtime: runtime)
    end

    it "appends runtime flags to the command" do
      runtime = AgentHarness::ProviderRuntime.new(
        flags: ["--verbose"]
      )

      expect(mock_executor).to receive(:execute).with(
        ["opencode", "run", "--verbose", "Hello"],
        anything
      ).and_return(success_result)

      provider.send_message(prompt: "Hello", provider_runtime: runtime)
    end

    it "builds full OpenRouter routing command" do
      runtime = AgentHarness::ProviderRuntime.new(
        model: "anthropic/claude-opus-4.1",
        base_url: "https://openrouter.ai/api/v1",
        api_provider: "openrouter",
        env: {"OPENROUTER_API_KEY" => "sk-or-123"}
      )

      expect(mock_executor).to receive(:execute).with(
        ["opencode", "run", "Write tests"],
        hash_including(env: hash_including(
          "OPENAI_BASE_URL" => "https://openrouter.ai/api/v1",
          "OPENROUTER_API_KEY" => "sk-or-123"
        ))
      ).and_return(success_result)

      response = provider.send_message(prompt: "Write tests", provider_runtime: runtime)
      expect(response.model).to eq("anthropic/claude-opus-4.1")
    end

    it "derives structured runtime preparation for config-file bootstrap from normalized runtime fields" do
      runtime = AgentHarness::ProviderRuntime.new(
        model: "anthropic/claude-opus-4.1",
        base_url: "https://openrouter.ai/api/v1",
        api_provider: "openrouter",
        metadata: {
          config: {
            theme: "system"
          }
        }
      )

      expect(mock_executor).to receive(:execute).with(
        ["opencode", "run", "Write tests"],
        hash_including(
          preparation: have_attributes(
            file_writes: [
              have_attributes(
                path: "~/.config/opencode/opencode.json",
                content: include(
                  "\"provider\": \"openrouter\"",
                  "\"model\": \"anthropic/claude-opus-4.1\"",
                  "\"baseURL\": \"https://openrouter.ai/api/v1\"",
                  "\"permission\": {",
                  "\"external_directory\": {",
                  "\"/tmp/**\": \"allow\"",
                  "\"theme\": \"system\""
                ),
                mode: 0o600
              )
            ]
          )
        )
      ).and_return(success_result)

      provider.send_message(prompt: "Write tests", provider_runtime: runtime)
    end
  end

  describe AgentHarness::Providers::Cursor do
    let(:provider) { described_class.new(executor: mock_executor) }
    let(:cursor_binary) { described_class.binary_name }

    it "passes runtime env vars to the executor" do
      runtime = AgentHarness::ProviderRuntime.new(
        env: {"CUSTOM_KEY" => "custom_value"}
      )

      expect(mock_executor).to receive(:execute).with(
        anything,
        hash_including(env: hash_including("CUSTOM_KEY" => "custom_value"))
      ).and_return(success_result)

      provider.send_message(prompt: "Hello", provider_runtime: runtime)
    end

    it "works without a provider_runtime" do
      expect(mock_executor).to receive(:execute).with(
        anything,
        hash_including(env: {})
      ).and_return(success_result)

      provider.send_message(prompt: "Hello")
    end

    it "coerces a plain Hash into a ProviderRuntime" do
      expect(mock_executor).to receive(:execute).with(
        anything,
        hash_including(env: hash_including("MY_VAR" => "value"))
      ).and_return(success_result)

      provider.send_message(
        prompt: "Hello",
        provider_runtime: {env: {"MY_VAR" => "value"}}
      )
    end

    it "appends runtime flags to the command" do
      runtime = AgentHarness::ProviderRuntime.new(flags: ["--verbose"])

      expect(mock_executor).to receive(:execute).with(
        [cursor_binary, "-p", "--verbose"],
        anything
      ).and_return(success_result)

      provider.send_message(prompt: "Hello", provider_runtime: runtime)
    end

    it "sets model on response from runtime when response model is nil" do
      runtime = AgentHarness::ProviderRuntime.new(model: "gpt-5-turbo")

      allow(mock_executor).to receive(:execute).and_return(success_result)

      response = provider.send_message(prompt: "Hello", provider_runtime: runtime)
      expect(response.model).to eq("gpt-5-turbo")
    end

    it "still sends prompt via stdin" do
      runtime = AgentHarness::ProviderRuntime.new(
        env: {"CUSTOM_KEY" => "value"},
        flags: ["--debug"]
      )

      expect(mock_executor).to receive(:execute).with(
        [cursor_binary, "-p", "--debug"],
        hash_including(stdin_data: "Hello", env: hash_including("CUSTOM_KEY" => "value"))
      ).and_return(success_result)

      provider.send_message(prompt: "Hello", provider_runtime: runtime)
    end

    it "keeps stdin-based legacy executors working when no preparation is needed" do
      seen = nil
      legacy_executor = Object.new
      legacy_executor.define_singleton_method(:execute) do |command, timeout:, env:, stdin_data: nil|
        seen = {
          command: command,
          timeout: timeout,
          env: env,
          stdin_data: stdin_data
        }

        AgentHarness::CommandExecutor::Result.new(
          stdout: stdin_data,
          stderr: "",
          exit_code: 0,
          duration: 1.0
        )
      end

      response = described_class.new(executor: legacy_executor).send_message(prompt: "Hello")
      expect(response.output).to eq("Hello")
      expect(seen).to eq(
        command: ["cursor-agent", "-p"],
        timeout: 300,
        env: {},
        stdin_data: "Hello"
      )
    end
  end

  describe AgentHarness::Providers::Codex do
    let(:provider) { described_class.new(executor: mock_executor) }

    include_examples "runtime env passthrough"
    include_examples "runtime hash coercion"

    it "sets OPENAI_BASE_URL from runtime base_url" do
      runtime = AgentHarness::ProviderRuntime.new(
        base_url: "https://openrouter.ai/api/v1"
      )

      expect(mock_executor).to receive(:execute).with(
        anything,
        hash_including(env: hash_including("OPENAI_BASE_URL" => "https://openrouter.ai/api/v1"))
      ).and_return(success_result)

      provider.send_message(prompt: "Hello", provider_runtime: runtime)
    end

    it "adds --model flag from runtime model" do
      runtime = AgentHarness::ProviderRuntime.new(model: "o3-pro")

      expect(mock_executor).to receive(:execute).with(
        array_including("--model", "o3-pro"),
        anything
      ).and_return(success_result)

      provider.send_message(prompt: "Hello", provider_runtime: runtime)
    end

    it "appends runtime flags to the command" do
      runtime = AgentHarness::ProviderRuntime.new(flags: ["--quiet"])

      expect(mock_executor).to receive(:execute).with(
        array_including("--quiet"),
        anything
      ).and_return(success_result)

      provider.send_message(prompt: "Hello", provider_runtime: runtime)
    end

    it "combines runtime with existing options" do
      runtime = AgentHarness::ProviderRuntime.new(
        model: "o3-pro",
        env: {"CUSTOM_VAR" => "value"}
      )

      expect(mock_executor).to receive(:execute).with(
        array_including("codex", "exec", "--model", "o3-pro"),
        hash_including(env: hash_including("CUSTOM_VAR" => "value"))
      ).and_return(success_result)

      provider.send_message(
        prompt: "Hello",
        session: "sess-123",
        provider_runtime: runtime
      )
    end
  end

  describe AgentHarness::Providers::Cursor do
    let(:provider_class) do
      Class.new(described_class) do
        protected

        def build_execution_preparation(_options)
          AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: "/tmp/cursor-runtime.json", content: "{\"ok\":true}"}]
          )
        end
      end
    end
    let(:provider) { provider_class.new(executor: legacy_executor) }
    let(:legacy_executor) do
      Object.new.tap do |executor|
        executor.define_singleton_method(:execute) do |command, timeout:, env:, stdin_data: nil|
          AgentHarness::CommandExecutor::Result.new(
            stdout: stdin_data,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        end
      end
    end

    it "fails loudly for legacy executors that do not accept preparation" do
      runtime = AgentHarness::ProviderRuntime.new(
        metadata: {config: {"theme" => "system"}}
      )

      expect {
        provider.send_message(prompt: "Hello", provider_runtime: runtime)
      }.to raise_error(
        AgentHarness::ProviderError,
        /must accept the preparation: keyword argument/
      )
    end
  end

  describe AgentHarness::Providers::Aider do
    let(:provider) { described_class.new(executor: mock_executor) }

    include_examples "runtime env passthrough"
    include_examples "runtime hash coercion"

    it "appends runtime flags without dropping the llm history flag" do
      runtime = AgentHarness::ProviderRuntime.new(flags: ["--map-tokens", "0"])

      expect(mock_executor).to receive(:execute).with(
        array_including("aider", "--yes", "--llm-history-file", "--map-tokens", "0", "--message", "Hello"),
        anything
      ).and_return(success_result)

      provider.send_message(prompt: "Hello", provider_runtime: runtime)
    end

    it "rejects runtime flags that try to override llm history output" do
      runtime = AgentHarness::ProviderRuntime.new(flags: ["--llm-history-file", "/tmp/override.log"])

      expect(mock_executor).not_to receive(:execute)

      expect {
        provider.send_message(prompt: "Hello", provider_runtime: runtime)
      }.to raise_error(
        AgentHarness::ProviderError,
        /provider-managed flags: --llm-history-file \/tmp\/override\.log/
      )
    end

    it "sets model on response from runtime when config model is nil" do
      runtime = AgentHarness::ProviderRuntime.new(model: "gpt-5-turbo")

      allow(mock_executor).to receive(:execute).and_return(success_result)

      response = provider.send_message(prompt: "Hello", provider_runtime: runtime)
      expect(response.model).to eq("gpt-5-turbo")
    end
  end
end
