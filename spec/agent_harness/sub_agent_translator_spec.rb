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

  it "translates for Anthropic" do
    translated = described_class.for_provider(:anthropic, config)

    expect(translated[:format]).to eq(:agent_sdk)
    expect(translated[:agent][:tools]).to eq(["Read"])
    expect(translated[:agent][:mcp_servers].first[:name]).to eq("github")
  end

  it "translates for OpenAI" do
    translated = described_class.for_provider(:openai, config)

    expect(translated[:format]).to eq(:responses)
    expect(translated[:assistant][:tools]).to eq([{type: "function", name: "read_file"}])
    expect(translated[:assistant][:metadata][:constraints]).to eq({max_tokens: 4096})
  end

  it "builds markdown definitions for Claude Code" do
    translated = described_class.for_provider(:claude_code, config)

    expect(translated[:format]).to eq(:markdown)
    expect(translated[:content]).to include("name: code_reviewer")
    expect(translated[:content]).to include("Review the provided changes")
  end
end
