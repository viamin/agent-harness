# frozen_string_literal: true

RSpec.describe AgentHarness::SubAgentTranslator do
  let(:config) do
    AgentHarness::SubAgentConfig.new(
      name: :code_reviewer,
      description: "Reviews code",
      instructions: "Review the provided changes",
      model: "fast",
      tools: [:read_file],
      mcp_servers: [:github],
      constraints: {max_tokens: 4096}
    )
  end

  before do
    AgentHarness.configuration.register_tool(:read_file,
      anthropic: "Read",
      openai: {type: "function", name: "read_file"},
      google: "read_file",
      claude_code: "Read",
      codex: "read_file",
      pi: "read_file")
    AgentHarness.configuration.register_mcp_server(:github, transport: "http", url: "https://example.test/mcp")
  end

  describe ".for_provider" do
    it "translates for Anthropic" do
      translated = described_class.for_provider(:anthropic, config)

      expect(translated[:provider]).to eq(:anthropic)
      expect(translated[:format]).to eq(:agent_sdk)
      expect(translated[:agent][:name]).to eq("code_reviewer")
      expect(translated[:agent][:description]).to eq("Reviews code")
      expect(translated[:agent][:instructions]).to eq("Review the provided changes")
      expect(translated[:agent][:model]).to eq("fast")
      expect(translated[:agent][:tools]).to eq(["Read"])
      expect(translated[:agent][:mcp_servers].first[:name]).to eq("github")
      expect(translated[:agent][:constraints]).to eq({max_tokens: 4096})
      expect(translated[:runtime_instructions]).to include("Sub-agent role: code_reviewer")
    end

    it "translates for OpenAI" do
      translated = described_class.for_provider(:openai, config)

      expect(translated[:provider]).to eq(:openai)
      expect(translated[:format]).to eq(:responses)
      expect(translated[:assistant][:name]).to eq("code_reviewer")
      expect(translated[:assistant][:tools]).to eq([{type: "function", name: "read_file"}])
      expect(translated[:assistant][:metadata][:constraints]).to eq({max_tokens: 4096})
      expect(translated[:assistant][:metadata][:mcp_servers].first[:name]).to eq("github")
    end

    it "translates for Google" do
      translated = described_class.for_provider(:google, config)

      expect(translated[:provider]).to eq(:google)
      expect(translated[:format]).to eq(:adk)
      expect(translated[:agent][:name]).to eq("code_reviewer")
      expect(translated[:agent][:instruction]).to eq("Review the provided changes")
      expect(translated[:agent][:tools]).to eq(["read_file"])
      expect(translated[:agent][:mcp_servers].first[:name]).to eq("github")
    end

    it "builds markdown definitions for Claude Code" do
      translated = described_class.for_provider(:claude_code, config)

      expect(translated[:provider]).to eq(:claude_code)
      expect(translated[:format]).to eq(:markdown)
      expect(translated[:content]).to include("name: code_reviewer")
      expect(translated[:content]).to include("Review the provided changes")
      expect(translated[:runtime_instructions]).to include("Sub-agent role: code_reviewer")
    end

    it "translates for Codex" do
      translated = described_class.for_provider(:codex, config)

      expect(translated[:provider]).to eq(:codex)
      expect(translated[:format]).to eq(:delegated_prompt)
      expect(translated[:definition][:name]).to eq("code_reviewer")
      expect(translated[:definition][:instructions]).to eq("Review the provided changes")
      expect(translated[:definition][:tools]).to eq(["read_file"])
      expect(translated[:definition][:mcp_servers].first[:name]).to eq("github")
    end

    it "translates for Pi" do
      translated = described_class.for_provider(:pi, config)

      expect(translated[:provider]).to eq(:pi)
      expect(translated[:format]).to eq(:skill_markdown)
      expect(translated[:content]).to include("name: code_reviewer")
      expect(translated[:content]).to include("Review the provided changes")
    end

    it "produces generic format for unknown providers" do
      translated = described_class.for_provider(:some_other_provider, config)

      expect(translated[:provider]).to eq(:some_other_provider)
      expect(translated[:format]).to eq(:generic)
      expect(translated[:definition][:name]).to eq("code_reviewer")
      expect(translated[:definition][:instructions]).to eq("Review the provided changes")
    end

    it "normalizes :claude alias to :anthropic" do
      translated = described_class.for_provider(:claude, config)

      expect(translated[:provider]).to eq(:anthropic)
      expect(translated[:format]).to eq(:agent_sdk)
    end

    it "normalizes :gemini alias to :google" do
      translated = described_class.for_provider(:gemini, config)

      expect(translated[:provider]).to eq(:google)
      expect(translated[:format]).to eq(:adk)
    end

    it "accepts a Hash instead of SubAgentConfig" do
      translated = described_class.for_provider(:anthropic, {
        name: "test_agent",
        description: "Test agent",
        instructions: "Do testing",
        tools: [:read_file]
      })

      expect(translated[:agent][:name]).to eq("test_agent")
      expect(translated[:agent][:tools]).to eq(["Read"])
    end

    it "raises on invalid config type" do
      expect {
        described_class.for_provider(:anthropic, "not a config")
      }.to raise_error(AgentHarness::ConfigurationError, /must be a SubAgentConfig or Hash/)
    end

    it "raises on unknown tool reference" do
      config_with_unknown_tool = AgentHarness::SubAgentConfig.new(
        name: :test,
        description: "Test",
        instructions: "Test",
        tools: [:nonexistent_tool]
      )

      expect {
        described_class.for_provider(:anthropic, config_with_unknown_tool)
      }.to raise_error(AgentHarness::ConfigurationError, /Unknown tool/)
    end

    it "raises on unknown MCP server reference" do
      config_with_unknown_server = AgentHarness::SubAgentConfig.new(
        name: :test,
        description: "Test",
        instructions: "Test",
        mcp_servers: [:nonexistent_server]
      )

      expect {
        described_class.for_provider(:anthropic, config_with_unknown_server)
      }.to raise_error(AgentHarness::ConfigurationError, /Unknown MCP server/)
    end

    it "passes through Hash tool definitions without resolving" do
      config_with_hash_tool = AgentHarness::SubAgentConfig.new(
        name: :test,
        description: "Test",
        instructions: "Test",
        tools: [{type: "custom", name: "my_tool"}]
      )

      translated = described_class.for_provider(:anthropic, config_with_hash_tool)
      expect(translated[:agent][:tools]).to eq([{type: "custom", name: "my_tool"}])
    end

    it "falls back to tool name string when provider mapping is nil" do
      AgentHarness.configuration.register_tool(:special_tool, anthropic: "SpecialTool")

      config_no_mapping = AgentHarness::SubAgentConfig.new(
        name: :test,
        description: "Test",
        instructions: "Test",
        tools: [:special_tool]
      )

      # openai has no mapping for :special_tool
      translated = described_class.for_provider(:openai, config_no_mapping)
      expect(translated[:assistant][:tools]).to eq(["special_tool"])
    end

    it "includes runtime instructions in all formats" do
      providers = [:anthropic, :openai, :google, :claude_code, :codex, :pi, :unknown_provider]

      providers.each do |provider_name|
        translated = described_class.for_provider(provider_name, config)
        expect(translated[:runtime_instructions]).to include("Sub-agent role: code_reviewer"),
          "Expected runtime_instructions for provider #{provider_name}"
        expect(translated[:runtime_instructions]).to include("Reviews code"),
          "Expected description in runtime_instructions for provider #{provider_name}"
      end
    end

    it "omits empty fields in Claude Code markdown frontmatter" do
      minimal_config = AgentHarness::SubAgentConfig.new(
        name: :minimal,
        description: "Minimal agent",
        instructions: "Do minimal things"
      )

      translated = described_class.for_provider(:claude_code, minimal_config,
        tool_registry: AgentHarness.configuration.tool_registry,
        mcp_servers: AgentHarness.configuration.mcp_servers)
      expect(translated[:content]).not_to include("tools:")
      expect(translated[:content]).not_to include("mcp_servers:")
      expect(translated[:content]).not_to include("constraints:")
    end

    it "accepts McpServer objects in the config" do
      server = AgentHarness::McpServer.new(name: "inline", transport: "http", url: "https://inline.test/mcp")

      config_with_server = AgentHarness::SubAgentConfig.new(
        name: :test,
        description: "Test",
        instructions: "Test",
        mcp_servers: [server]
      )

      translated = described_class.for_provider(:anthropic, config_with_server)
      expect(translated[:agent][:mcp_servers].first[:name]).to eq("inline")
    end
  end
end
