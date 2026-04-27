# frozen_string_literal: true

require "tmpdir"

RSpec.describe AgentHarness::SubAgentFileLoader do
  describe ".load" do
    it "loads YAML sub-agent definitions" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "sub_agents.yml")
        File.write(path, <<~YAML)
          agents:
            - name: code_reviewer
              description: Reviews code
              instructions: Review the provided changes
              model: default
              tools:
                - read_file
        YAML

        agents = described_class.load(path)
        expect(agents.map(&:name)).to eq([:code_reviewer])
        expect(agents.first.tools).to eq(["read_file"])
      end
    end

    it "loads multiple agents from YAML" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "sub_agents.yml")
        File.write(path, <<~YAML)
          agents:
            - name: reviewer
              description: Reviews code
              instructions: Review changes
            - name: writer
              description: Writes tests
              instructions: Write tests
        YAML

        agents = described_class.load(path)
        expect(agents.map(&:name)).to eq([:reviewer, :writer])
      end
    end

    it "loads a single agent YAML without agents wrapper" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "single.yml")
        File.write(path, <<~YAML)
          name: solo_agent
          description: A single agent
          instructions: Do the thing
        YAML

        agents = described_class.load(path)
        expect(agents.length).to eq(1)
        expect(agents.first.name).to eq(:solo_agent)
      end
    end

    it "loads Markdown frontmatter definitions" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "code_reviewer.md")
        File.write(path, <<~MARKDOWN)
          ---
          name: code_reviewer
          description: Reviews code
          model: default
          tools:
            - read_file
          ---
          Review the provided changes carefully.
        MARKDOWN

        agents = described_class.load(path)
        expect(agents.first.name).to eq(:code_reviewer)
        expect(agents.first.instructions).to eq("Review the provided changes carefully.")
      end
    end

    it "uses body as instructions in Markdown when frontmatter lacks instructions" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "agent.md")
        File.write(path, <<~MARKDOWN)
          ---
          name: helper
          description: Helps with tasks
          ---
          You are a helpful assistant. Do your best.
        MARKDOWN

        agents = described_class.load(path)
        expect(agents.first.instructions).to eq("You are a helpful assistant. Do your best.")
      end
    end

    it "raises on unsupported file format" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "agents.txt")
        File.write(path, "not supported")

        expect {
          described_class.load(path)
        }.to raise_error(AgentHarness::ConfigurationError, /Unsupported sub-agent definition format/)
      end
    end

    it "raises on invalid YAML syntax" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "broken.yml")
        File.write(path, "  invalid:\n\tyaml: [")

        expect {
          described_class.load(path)
        }.to raise_error(AgentHarness::ConfigurationError, /Invalid YAML/)
      end
    end

    it "raises when YAML is not a Hash" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "array.yml")
        File.write(path, "- item1\n- item2\n")

        expect {
          described_class.load(path)
        }.to raise_error(AgentHarness::ConfigurationError, /YAML sub-agent definition must be a Hash/)
      end
    end

    it "raises when Markdown has no frontmatter" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "no_front.md")
        File.write(path, "Just plain markdown content")

        expect {
          described_class.load(path)
        }.to raise_error(AgentHarness::ConfigurationError, /require YAML frontmatter/)
      end
    end

    it "supports .yaml extension" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "sub_agents.yaml")
        File.write(path, <<~YAML)
          name: yaml_agent
          description: Agent from .yaml file
          instructions: Do things
        YAML

        agents = described_class.load(path)
        expect(agents.first.name).to eq(:yaml_agent)
      end
    end

    it "supports .markdown extension" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "agent.markdown")
        File.write(path, <<~MARKDOWN)
          ---
          name: md_agent
          description: Markdown agent
          ---
          Do the work.
        MARKDOWN

        agents = described_class.load(path)
        expect(agents.first.name).to eq(:md_agent)
      end
    end
  end
end
