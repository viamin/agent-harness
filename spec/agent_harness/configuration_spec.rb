# frozen_string_literal: true

RSpec.describe AgentHarness::Configuration do
  subject(:config) { described_class.new }

  describe "#initialize" do
    it "sets default values" do
      expect(config.default_provider).to eq(:cursor)
      expect(config.log_level).to eq(:info)
      expect(config.fallback_providers).to eq([])
      expect(config.default_timeout).to eq(300)
    end
  end

  describe "#provider" do
    it "configures a provider" do
      config.provider(:claude) do |p|
        p.enabled = true
        p.timeout = 600
        p.models = ["claude-3-5-sonnet"]
      end

      expect(config.providers[:claude]).to be_a(AgentHarness::ProviderConfig)
      expect(config.providers[:claude].enabled).to be true
      expect(config.providers[:claude].timeout).to eq(600)
      expect(config.providers[:claude].models).to eq(["claude-3-5-sonnet"])
    end
  end

  describe "#orchestration" do
    it "configures orchestration settings" do
      config.orchestration do |orch|
        orch.enabled = false
        orch.auto_switch_on_error = false

        orch.circuit_breaker do |cb|
          cb.failure_threshold = 10
          cb.timeout = 600
        end

        orch.retry do |r|
          r.max_attempts = 5
          r.base_delay = 2.0
        end
      end

      expect(config.orchestration_config.enabled).to be false
      expect(config.orchestration_config.auto_switch_on_error).to be false
      expect(config.orchestration_config.circuit_breaker_config.failure_threshold).to eq(10)
      expect(config.orchestration_config.retry_config.max_attempts).to eq(5)
    end
  end

  describe "#register_provider" do
    it "registers a custom provider class" do
      custom_class = Class.new
      config.register_provider(:custom, custom_class)

      expect(config.custom_provider_classes[:custom]).to eq(custom_class)
    end
  end

  describe "#sub_agent" do
    it "registers a canonical sub-agent config" do
      config.sub_agent(:code_reviewer,
        description: "Reviews code",
        instructions: "Review the provided changes",
        model: "fast",
        tools: [:read_file])

      sub_agent = config.sub_agents[:code_reviewer]
      expect(sub_agent).to be_a(AgentHarness::SubAgentConfig)
      expect(sub_agent.model).to eq("fast")
      expect(sub_agent.tools).to eq([:read_file])
    end

    it "accepts a block to modify attributes" do
      config.sub_agent(:flexible) do |attrs|
        attrs[:description] = "Flexible agent"
        attrs[:instructions] = "Be flexible"
        attrs[:tools] = [:read_file, :write_file]
      end

      sub_agent = config.sub_agents[:flexible]
      expect(sub_agent.description).to eq("Flexible agent")
      expect(sub_agent.tools).to eq([:read_file, :write_file])
    end
  end

  describe "#load_sub_agents" do
    it "loads sub-agents from a YAML file" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "agents.yml")
        File.write(path, <<~YAML)
          agents:
            - name: loaded_agent
              description: Loaded from file
              instructions: Follow instructions
        YAML

        config.load_sub_agents(path)
        expect(config.sub_agents[:loaded_agent]).to be_a(AgentHarness::SubAgentConfig)
        expect(config.sub_agents[:loaded_agent].description).to eq("Loaded from file")
      end
    end
  end

  describe "#register_tool" do
    it "stores provider-specific tool mappings" do
      config.register_tool(:read_file, anthropic: "Read", openai: {type: "function", name: "read_file"})

      tool = config.tool_registry.fetch(:read_file)
      expect(tool.mapping_for(:anthropic)).to eq("Read")
      expect(tool.mapping_for(:openai)).to eq({type: "function", name: "read_file"})
    end
  end

  describe "#register_mcp_server" do
    it "stores named MCP servers" do
      config.register_mcp_server(:github, transport: "http", url: "https://example.test/mcp")

      expect(config.mcp_servers[:github]).to be_a(AgentHarness::McpServer)
      expect(config.mcp_servers[:github].url).to eq("https://example.test/mcp")
    end
  end

  describe "#resolve_sub_agent" do
    it "resolves registered sub-agents by name" do
      config.sub_agent(:test_writer,
        description: "Writes tests",
        instructions: "Write tests for the code")

      expect(config.resolve_sub_agent(:test_writer).name).to eq(:test_writer)
    end

    it "resolves by string name" do
      config.sub_agent(:test_writer,
        description: "Writes tests",
        instructions: "Write tests for the code")

      expect(config.resolve_sub_agent("test_writer").name).to eq(:test_writer)
    end

    it "accepts inline hash definitions" do
      sub_agent = config.resolve_sub_agent(
        name: "docs_generator",
        description: "Writes docs",
        instructions: "Document the code"
      )

      expect(sub_agent).to be_a(AgentHarness::SubAgentConfig)
      expect(sub_agent.name).to eq(:docs_generator)
    end

    it "passes through SubAgentConfig objects" do
      original = AgentHarness::SubAgentConfig.new(
        name: "passthrough",
        description: "Passthrough",
        instructions: "Pass through"
      )

      expect(config.resolve_sub_agent(original)).to be(original)
    end

    it "returns nil for nil reference" do
      expect(config.resolve_sub_agent(nil)).to be_nil
    end

    it "raises on unknown sub-agent name" do
      expect {
        config.resolve_sub_agent(:nonexistent)
      }.to raise_error(AgentHarness::ConfigurationError, /Unknown sub-agent/)
    end
  end

  describe "#on_tokens_used" do
    it "registers a callback" do
      callback_called = false
      config.on_tokens_used { callback_called = true }

      config.callbacks.emit(:tokens_used, {})
      expect(callback_called).to be true
    end
  end

  describe "#on_provider_switch" do
    it "registers a callback" do
      event_data = nil
      config.on_provider_switch { |data| event_data = data }

      config.callbacks.emit(:provider_switch, {from: :claude, to: :cursor})
      expect(event_data).to eq({from: :claude, to: :cursor})
    end
  end

  describe "#validate!" do
    it "raises error when no providers configured" do
      expect { config.validate! }.to raise_error(AgentHarness::ConfigurationError, /No providers configured/)
    end

    it "raises error when default provider not configured" do
      config.provider(:claude) { |p| p.enabled = true }
      config.default_provider = :gemini

      expect { config.validate! }.to raise_error(AgentHarness::ConfigurationError, /Default provider/)
    end

    it "does not raise when properly configured" do
      config.provider(:cursor) { |p| p.enabled = true }

      expect { config.validate! }.not_to raise_error
    end
  end
end
