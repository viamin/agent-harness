# frozen_string_literal: true

RSpec.describe AgentHarness::SubAgentConfig do
  describe ".from_hash" do
    it "builds a canonical sub-agent config" do
      config = described_class.from_hash(
        "name" => "code_reviewer",
        "description" => "Reviews code",
        "instructions" => "Analyze code changes",
        "model" => "default",
        "tools" => [:read_file, :grep],
        "constraints" => {"max_tokens" => 4096}
      )

      expect(config.name).to eq(:code_reviewer)
      expect(config.description).to eq("Reviews code")
      expect(config.instructions).to eq("Analyze code changes")
      expect(config.model).to eq("default")
      expect(config.tools).to eq([:read_file, :grep])
      expect(config.constraints).to eq({"max_tokens" => 4096})
    end

    it "raises on missing required fields" do
      expect {
        described_class.from_hash(name: "broken", instructions: "Missing description")
      }.to raise_error(AgentHarness::ConfigurationError, /description is required/)
    end

    it "raises when name is missing" do
      expect {
        described_class.from_hash(description: "desc", instructions: "inst")
      }.to raise_error(AgentHarness::ConfigurationError, /name is required/)
    end

    it "raises when instructions is missing" do
      expect {
        described_class.from_hash(name: "broken", description: "desc")
      }.to raise_error(AgentHarness::ConfigurationError, /instructions is required/)
    end

    it "raises on non-Hash input" do
      expect {
        described_class.from_hash("not a hash")
      }.to raise_error(AgentHarness::ConfigurationError, /must be a Hash/)
    end

    it "accepts Symbol keys" do
      config = described_class.from_hash(
        name: :test_agent,
        description: "Test",
        instructions: "Do testing"
      )

      expect(config.name).to eq(:test_agent)
    end

    it "accepts all optional fields" do
      config = described_class.from_hash(
        name: "orchestrator",
        description: "Orchestrates agents",
        instructions: "Route tasks",
        model: "powerful",
        tools: [:read_file],
        mcp_servers: [:github],
        constraints: {max_turns: 10},
        handoff_conditions: [{trigger: "done", target: :reviewer}],
        type: :router,
        sub_agents: [:reviewer, :writer],
        routing: {strategy: :llm_choice}
      )

      expect(config.type).to eq(:router)
      expect(config.sub_agents).to eq([:reviewer, :writer])
      expect(config.routing).to eq({strategy: :llm_choice})
      expect(config.handoff_conditions).to eq([{trigger: "done", target: :reviewer}])
    end
  end

  describe "#initialize" do
    it "normalizes name with spaces to underscored symbol" do
      config = described_class.new(
        name: "code reviewer",
        description: "Reviews code",
        instructions: "Review changes"
      )

      expect(config.name).to eq(:code_reviewer)
    end

    it "defaults model to 'default'" do
      config = described_class.new(
        name: "test",
        description: "Test",
        instructions: "Test"
      )

      expect(config.model).to eq("default")
    end

    it "defaults model to 'default' when nil" do
      config = described_class.new(
        name: "test",
        description: "Test",
        instructions: "Test",
        model: nil
      )

      expect(config.model).to eq("default")
    end

    it "defaults arrays and hashes to empty frozen values" do
      config = described_class.new(
        name: "test",
        description: "Test",
        instructions: "Test"
      )

      expect(config.tools).to eq([])
      expect(config.tools).to be_frozen
      expect(config.mcp_servers).to eq([])
      expect(config.mcp_servers).to be_frozen
      expect(config.constraints).to eq({})
      expect(config.constraints).to be_frozen
      expect(config.handoff_conditions).to eq([])
      expect(config.handoff_conditions).to be_frozen
      expect(config.sub_agents).to eq([])
      expect(config.sub_agents).to be_frozen
    end

    it "freezes provided arrays and hashes" do
      config = described_class.new(
        name: "test",
        description: "Test",
        instructions: "Test",
        tools: [:read_file],
        constraints: {max_tokens: 4096}
      )

      expect(config.tools).to be_frozen
      expect(config.constraints).to be_frozen
    end

    it "raises when tools is not an Array" do
      expect {
        described_class.new(
          name: "test",
          description: "Test",
          instructions: "Test",
          tools: "not_an_array"
        )
      }.to raise_error(AgentHarness::ConfigurationError, /tools must be an Array/)
    end

    it "raises when constraints is not a Hash" do
      expect {
        described_class.new(
          name: "test",
          description: "Test",
          instructions: "Test",
          constraints: "not_a_hash"
        )
      }.to raise_error(AgentHarness::ConfigurationError, /constraints must be a Hash/)
    end

    it "raises when name is empty" do
      expect {
        described_class.new(
          name: "  ",
          description: "Test",
          instructions: "Test"
        )
      }.to raise_error(AgentHarness::ConfigurationError, /name is required/)
    end

    it "sets type to nil by default" do
      config = described_class.new(
        name: "test",
        description: "Test",
        instructions: "Test"
      )

      expect(config.type).to be_nil
    end

    it "sets routing to nil by default" do
      config = described_class.new(
        name: "test",
        description: "Test",
        instructions: "Test"
      )

      expect(config.routing).to be_nil
    end

    it "freezes routing when provided" do
      config = described_class.new(
        name: "test",
        description: "Test",
        instructions: "Test",
        routing: {strategy: :llm_choice}
      )

      expect(config.routing).to be_frozen
    end
  end

  describe "#to_h" do
    it "returns a hash representation with all fields" do
      config = described_class.new(
        name: "code_reviewer",
        description: "Reviews code",
        instructions: "Review changes",
        model: "fast",
        tools: [:read_file],
        mcp_servers: [:github],
        constraints: {max_tokens: 4096}
      )

      hash = config.to_h
      expect(hash[:name]).to eq(:code_reviewer)
      expect(hash[:description]).to eq("Reviews code")
      expect(hash[:instructions]).to eq("Review changes")
      expect(hash[:model]).to eq("fast")
      expect(hash[:tools]).to eq([:read_file])
      expect(hash[:mcp_servers]).to eq([:github])
      expect(hash[:constraints]).to eq({max_tokens: 4096})
    end

    it "omits nil fields via compact" do
      config = described_class.new(
        name: "test",
        description: "Test",
        instructions: "Test"
      )

      hash = config.to_h
      expect(hash).not_to have_key(:type)
      expect(hash).not_to have_key(:routing)
    end

    it "returns defensive copies" do
      config = described_class.new(
        name: "test",
        description: "Test",
        instructions: "Test",
        tools: [:read_file]
      )

      hash = config.to_h
      hash[:tools] << :write_file

      expect(config.tools).to eq([:read_file])
    end
  end
end
