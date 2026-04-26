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
      expect(config.tools).to eq([:read_file, :grep])
      expect(config.constraints).to eq({"max_tokens" => 4096})
    end

    it "raises on missing required fields" do
      expect {
        described_class.from_hash(name: "broken", instructions: "Missing description")
      }.to raise_error(AgentHarness::ConfigurationError, /description is required/)
    end
  end
end
