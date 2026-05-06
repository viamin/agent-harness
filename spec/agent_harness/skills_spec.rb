# frozen_string_literal: true

RSpec.describe AgentHarness::Skills do
  def write_skill(root, folder, body)
    skill_dir = File.join(root, folder)
    FileUtils.mkdir_p(skill_dir)
    File.write(File.join(skill_dir, "SKILL.md"), body)
  end

  describe ".discover" do
    it "loads skills from home, shared, and project skill directories with project precedence" do
      Dir.mktmpdir do |home|
        Dir.mktmpdir do |cwd|
          write_skill(
            File.join(home, ".agent-harness", "skills"),
            "code-review",
            <<~MARKDOWN
              ---
              name: code-review
              description: Global review
              ---
              Global instructions
            MARKDOWN
          )
          write_skill(
            File.join(cwd, ".agents", "skills"),
            "shared-review",
            <<~MARKDOWN
              ---
              name: shared-review
              description: Shared review
              ---
              Shared instructions
            MARKDOWN
          )
          write_skill(
            File.join(cwd, ".agent-harness", "skills"),
            "code-review",
            <<~MARKDOWN
              ---
              name: code-review
              description: Project review
              ---
              Project instructions
            MARKDOWN
          )

          skills = described_class.discover(cwd: cwd, home: home)
          names = skills.map(&:name)

          expect(names).to include(:code_review, :shared_review)
          expect(described_class.find(:code_review, cwd: cwd, home: home).description).to eq("Project review")
        end
      end
    end

    it "finds skills using hyphenated names" do
      Dir.mktmpdir do |home|
        Dir.mktmpdir do |cwd|
          write_skill(
            File.join(cwd, ".agent-harness", "skills"),
            "code-review",
            <<~MARKDOWN
              ---
              name: code-review
              description: Review skill
              ---
              Review instructions
            MARKDOWN
          )

          skill = described_class.find("code-review", cwd: cwd, home: home)
          expect(skill.name).to eq(:code_review)
          expect(skill.description).to eq("Review skill")
        end
      end
    end

    it "supports programmatic registration overriding discovered skills" do
      Dir.mktmpdir do |home|
        Dir.mktmpdir do |cwd|
          write_skill(
            File.join(cwd, ".agent-harness", "skills"),
            "code-review",
            <<~MARKDOWN
              ---
              name: code-review
              description: Project review
              ---
              Project instructions
            MARKDOWN
          )

          described_class.register(:code_review, {
            description: "Registered review",
            instructions: "Registered instructions"
          })

          skill = described_class.find(:code_review, cwd: cwd, home: home)
          expect(skill.description).to eq("Registered review")
          expect(skill.instructions).to eq("Registered instructions")
        end
      end
    end
  end
end
