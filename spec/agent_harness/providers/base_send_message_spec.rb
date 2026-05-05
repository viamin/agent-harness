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

  let(:prompt_extension_class) do
    Class.new(AgentHarness::Extensions::Base) do
      def name
        :prompt_extension
      end

      def system_prompt_additions
        ["Research before answering."]
      end

      def on_message_after(context)
        response = context.response
        context.response = AgentHarness::Response.new(
          output: "#{response.output} [extended]",
          exit_code: response.exit_code,
          duration: response.duration,
          provider: response.provider,
          model: response.model,
          tokens: response.tokens,
          metadata: response.metadata,
          error: response.error
        )
      end
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

    it "injects translated sub-agent instructions into the prompt" do
      AgentHarness.configuration.register_tool(:read_file, test_provider: "read_file")
      AgentHarness.configure do |config|
        config.sub_agent(:code_reviewer,
          description: "Reviews code",
          instructions: "Review the provided changes",
          tools: [:read_file])
      end

      expect(mock_executor).to receive(:execute) do |command, **|
        expect(command).to include("Sub-agent role: code_reviewer\nDescription: Reviews code\n\nFollow these sub-agent instructions exactly:\nReview the provided changes\n\nUser task:\nHello")

        AgentHarness::CommandExecutor::Result.new(
          stdout: "response output",
          stderr: "",
          exit_code: 0,
          duration: 1.0
        )
      end

      provider.send_message(prompt: "Hello", sub_agent: :code_reviewer)
    end

    it "applies extension prompt additions and response hooks" do
      extension = prompt_extension_class.new
      AgentHarness.configuration.register_extension(extension)

      expect(mock_executor).to receive(:execute) do |command, **|
        expect(command).to include("Research before answering.\n\nHello")

        AgentHarness::CommandExecutor::Result.new(
          stdout: "response output",
          stderr: "",
          exit_code: 0,
          duration: 1.0
        )
      end

      response = provider.send_message(prompt: "Hello", extensions: [:prompt_extension])
      expect(response.output).to eq("response output [extended]")
    end

    it "prepends skill instructions and merges provider runtime overrides" do
      AgentHarness::Skills.register(:code_review, {
        description: "Reviews code",
        instructions: "Review the changed files before answering.",
        providers: {
          all: {
            model: "skill-model",
            flags: ["--from-skill"],
            env: {"SKILL_ENV" => "1"}
          }
        }
      })

      expect(mock_executor).to receive(:execute) do |command, env:, **|
        expect(command).to include("Review the changed files before answering.\n\nHello")
        expect(env).to include("SKILL_ENV" => "1")

        AgentHarness::CommandExecutor::Result.new(
          stdout: "response output",
          stderr: "",
          exit_code: 0,
          duration: 1.0
        )
      end

      response = provider.send_message(prompt: "Hello", skills: [:code_review])
      expect(response.model).to eq("skill-model")
    end

    it "merges skill mcp servers into message-mode options" do
      AgentHarness::Skills.register(:repo_access, {
        description: "Adds repo MCP access",
        instructions: "Use MCP when needed.",
        mcp_servers: [{name: "github", transport: "stdio", command: "npx", args: ["server-github"]}]
      })

      capable_provider_class = Class.new(test_provider_class) do
        def capabilities
          super.merge(mcp: true)
        end
      end
      capable_provider = capable_provider_class.new(config: config, executor: mock_executor)

      expect(capable_provider).to receive(:build_command).and_wrap_original do |original, prompt, options|
        expect(prompt).to include("Use MCP when needed.")
        expect(options[:mcp_servers].map(&:name)).to eq(["github"])
        original.call(prompt, options)
      end

      capable_provider.send_message(prompt: "Hello", skills: [:repo_access])
    end

    it "raises a skill-aware error when multiple skills define the same MCP server name" do
      AgentHarness::Skills.register(:repo_access, {
        description: "Adds repo MCP access",
        instructions: "Use repo MCP when needed.",
        mcp_servers: [{name: "github", transport: "stdio", command: "npx", args: ["repo-server"]}]
      })
      AgentHarness::Skills.register(:docs_access, {
        description: "Adds docs MCP access",
        instructions: "Use docs MCP when needed.",
        mcp_servers: [{name: "github", transport: "stdio", command: "npx", args: ["docs-server"]}]
      })

      capable_provider_class = Class.new(test_provider_class) do
        def capabilities
          super.merge(mcp: true)
        end
      end
      capable_provider = capable_provider_class.new(config: config, executor: mock_executor)

      expect {
        capable_provider.send_message(prompt: "Hello", skills: %i[repo_access docs_access])
      }.to raise_error(
        AgentHarness::ConfigurationError,
        /MCP server name conflict across explicit and skill servers: github \(skill: repo_access, skill: docs_access\)/
      )
    end

    it "rejects extensions with tools in message mode" do
      # Use a provider that supports tool_use so capability validation passes
      # and the message-mode rejection is what fires.
      capable_provider_class = Class.new(test_provider_class) do
        def capabilities
          super.merge(tool_use: true)
        end
      end
      capable_provider = capable_provider_class.new(config: config, executor: mock_executor)

      tool_extension = Class.new(AgentHarness::Extensions::Base) do
        def name = :tool_ext
        def tools = [{name: "web_search"}]
      end.new

      AgentHarness.configuration.register_extension(tool_extension)

      expect {
        capable_provider.send_message(prompt: "Hello", extensions: [:tool_ext])
      }.to raise_error(AgentHarness::ExtensionCompatibilityError, /not supported in message mode/)
    end

    it "rejects extensions with MCP servers in message mode" do
      capable_provider_class = Class.new(test_provider_class) do
        def capabilities
          super.merge(mcp: true)
        end
      end
      capable_provider = capable_provider_class.new(config: config, executor: mock_executor)

      mcp_extension = Class.new(AgentHarness::Extensions::Base) do
        def name = :mcp_ext
        def mcp_servers = [{name: "server", command: "npx server"}]
      end.new

      AgentHarness.configuration.register_extension(mcp_extension)

      expect {
        capable_provider.send_message(prompt: "Hello", extensions: [:mcp_ext])
      }.to raise_error(AgentHarness::ExtensionCompatibilityError, /MCP servers are not supported in message mode/)
    end

    it "resolves extensions from a custom configuration" do
      custom_config = AgentHarness::Configuration.new
      custom_ext = prompt_extension_class.new
      custom_config.register_extension(custom_ext)

      custom_provider = test_provider_class.new(
        config: config,
        executor: mock_executor,
        configuration: custom_config
      )

      expect(mock_executor).to receive(:execute) do |command, **|
        expect(command).to include("Research before answering.\n\nHello")

        AgentHarness::CommandExecutor::Result.new(
          stdout: "response output",
          stderr: "",
          exit_code: 0,
          duration: 1.0
        )
      end

      response = custom_provider.send_message(prompt: "Hello", extensions: [:prompt_extension])
      expect(response.output).to eq("response output [extended]")
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

  describe "idle timeout handling" do
    before do
      allow(mock_executor).to receive(:execute).and_raise(
        AgentHarness::IdleTimeoutError.new("Command exceeded idle timeout")
      )
    end

    it "preserves IdleTimeoutError" do
      expect { provider.send_message(prompt: "Hello") }.to raise_error(AgentHarness::IdleTimeoutError)
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

    it "preserves an explicit nil heartbeat interval" do
      expect(mock_executor).to receive(:execute).with(
        anything,
        hash_including(
          timeout: 120,
          on_heartbeat: kind_of(Proc),
          heartbeat_interval: nil
        )
      ).and_return(
        AgentHarness::CommandExecutor::Result.new(stdout: "ok", stderr: "", exit_code: 0, duration: 1.0)
      )

      provider.send_message(
        prompt: "Hello",
        on_heartbeat: ->(**_heartbeat) {},
        heartbeat_interval: nil
      )
    end

    it "does not override the executor heartbeat interval unless requested" do
      expect(mock_executor).to receive(:execute).with(
        anything,
        satisfy { |execution_options|
          execution_options[:timeout] == 120 &&
            execution_options[:on_heartbeat].is_a?(Proc) &&
            !execution_options.key?(:heartbeat_interval)
        }
      ).and_return(
        AgentHarness::CommandExecutor::Result.new(stdout: "ok", stderr: "", exit_code: 0, duration: 1.0)
      )

      provider.send_message(
        prompt: "Hello",
        on_heartbeat: ->(**_heartbeat) {}
      )
    end
  end

  describe "tools option on unsupported provider" do
    let(:logger) { double("Logger", debug: nil, warn: nil, error: nil) }

    subject(:provider) do
      test_provider_class.new(config: config, executor: mock_executor, logger: logger)
    end

    it "emits a warning when tools option is passed" do
      expect(logger).to receive(:warn).with(/tools option is not supported/)

      provider.send_message(prompt: "Hello", tools: :none)
    end

    it "still returns a successful response" do
      response = provider.send_message(prompt: "Hello", tools: :none)

      expect(response).to be_a(AgentHarness::Response)
      expect(response.output).to eq("response output")
    end

    it "does not warn when tools option is not provided" do
      expect(logger).not_to receive(:warn)

      provider.send_message(prompt: "Hello")
    end
  end
end
