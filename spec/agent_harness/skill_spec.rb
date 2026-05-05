# frozen_string_literal: true

RSpec.describe AgentHarness::Skill do
  describe ".from_hash" do
    it "builds a canonical skill definition" do
      skill = described_class.from_hash(
        name: "code-review",
        description: "Review code",
        instructions: "Inspect the diff",
        trigger: "when reviewing code",
        tools: [:read_file],
        mcp_servers: [{name: "github", transport: "http", url: "https://example.test/mcp"}],
        providers: {
          all: {flags: ["--verbose"]},
          codex: {model: "gpt-5-codex"}
        }
      )

      expect(skill.name).to eq(:code_review)
      expect(skill.description).to eq("Review code")
      expect(skill.instructions).to eq("Inspect the diff")
      expect(skill.trigger).to eq("when reviewing code")
      expect(skill.tools).to eq([:read_file])
      expect(skill.mcp_servers).to eq([{name: "github", transport: "http", url: "https://example.test/mcp"}])
      expect(skill.provider_override_for(:codex)).to eq(flags: ["--verbose"], model: "gpt-5-codex")
    end

    it "requires the name, description, and instructions" do
      expect {
        described_class.from_hash(description: "Missing name", instructions: "Body")
      }.to raise_error(AgentHarness::ConfigurationError, /name is required/)
    end

    it "validates provider references" do
      expect {
        described_class.from_hash(
          name: "bad-provider",
          description: "Bad",
          instructions: "Body",
          providers: {unknown_provider: {model: "x"}}
        )
      }.to raise_error(AgentHarness::ConfigurationError, /Unknown provider/)
    end
  end

  describe ".load_file" do
    it "loads markdown frontmatter and body" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "SKILL.md")
        File.write(path, <<~MARKDOWN)
          ---
          name: code-review
          description: Review code
          providers:
            codex:
              flags:
                - --full-auto
          ---
          Review the pull request carefully.
        MARKDOWN

        skill = described_class.load_file(path)
        expect(skill.name).to eq(:code_review)
        expect(skill.instructions).to eq("Review the pull request carefully.")
        expect(skill.provider_override_for(:codex)).to eq(flags: ["--full-auto"])
        expect(skill.source_path).to eq(path)
      end
    end

    it "rejects markdown without frontmatter" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "SKILL.md")
        File.write(path, "# No frontmatter")

        expect {
          described_class.load_file(path)
        }.to raise_error(AgentHarness::ConfigurationError, /must begin with YAML frontmatter/)
      end
    end
  end
end
