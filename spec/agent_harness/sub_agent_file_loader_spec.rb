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
  end
end
