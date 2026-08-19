# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"

require_relative "../script/sync-cli-pins"

# In-sync versions and the exact requirement right-hand sides as they appear
# in the real provider files, keyed by "<provider_dir>/<package>".
FIXTURE_PINS = {
  "claude/@anthropic-ai/claude-code" => ["2.1.92", "Gem::Requirement.new(\">= \#{SUPPORTED_CLI_VERSION}\", \"< 2.2.0\").freeze"],
  "codex/@openai/codex" => ["0.122.0", "Gem::Requirement.new(\">= \#{SUPPORTED_CLI_VERSION}\", \"< 0.123.0\").freeze"],
  "opencode/opencode-ai" => ["1.18.9", "Gem::Requirement.new(\">= \#{SUPPORTED_CLI_VERSION}\", \"< 2.0.0\").freeze"],
  "gemini/@google/gemini-cli" => ["0.35.3", "Gem::Requirement.new(\"= \#{SUPPORTED_CLI_VERSION}\").freeze"],
  "pi/@mariozechner/pi-coding-agent" => ["0.73.0", "Gem::Requirement.new(\"= \#{SUPPORTED_CLI_VERSION}\").freeze"],
  "omp/@oh-my-pi/pi-coding-agent" => ["17.0.1", "Gem::Requirement.new(\"= \#{SUPPORTED_CLI_VERSION}\").freeze"],
  "omp/bun" => ["1.3.14", "\">= \#{SUPPORTED_BUN_VERSION}\".freeze"],
  "kilocode/@kilocode/cli" => ["7.4.16", "\"= \#{DEFAULT_VERSION}\""],
  "aider/aider-chat" => ["0.86.2", "Gem::Requirement.new(\">= \#{SUPPORTED_CLI_VERSION}\", \"< 0.87.0\").freeze"]
}.freeze

# Behavior of script/sync-cli-pins.rb — the step-2 sync that rewrites the
# provider SUPPORTED_*_VERSION constants from the Dependabot pin manifests
# (see vendor/pins/README.md and issue #337). The fixtures below mirror the
# constant/requirement shapes of the real provider sources.
RSpec.describe CliPinSync do
  let(:repo_root) { @tmpdir }

  around do |example|
    Dir.mktmpdir("cli-pin-sync-spec") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  before { write_fixtures }

  def pin(key)
    CliPinSync::PINS.find { |candidate| key_for(candidate) == key }
  end

  def key_for(pin)
    "#{pin.provider_dir}/#{pin.package}"
  end

  def write_fixtures
    CliPinSync::PINS.group_by(&:provider_file).each do |file, file_pins|
      constants = file_pins.map do |p|
        version, requirement = FIXTURE_PINS.fetch(key_for(p))
        "      #{p.constant} = \"#{version}\"\n" \
          "      #{p.requirement_name} = #{requirement}\n"
      end.join
      write_file(file, <<~RUBY)
        # frozen_string_literal: true

        module AgentHarness
          module Providers
            class Fixture < Base
              UNRELATED_VERSION = "0.0.1"
        #{constants}
              def noop; end
            end
          end
        end
      RUBY
    end
    CliPinSync::PINS.group_by { |p| [p.provider_dir, p.manifest] }.each do |(dir, manifest), manifest_pins|
      versions = manifest_pins.to_h { |p| [p.package, FIXTURE_PINS.fetch(key_for(p)).first] }
      if manifest == "requirements.txt"
        write_file("vendor/pins/#{dir}/requirements.txt", versions.map { |pkg, v| "#{pkg}==#{v}\n" }.join)
      else
        body = {"name" => "agent-harness-pin-#{dir}", "private" => true, "devDependencies" => versions}
        write_file("vendor/pins/#{dir}/#{manifest}", "#{JSON.pretty_generate(body)}\n")
      end
    end
  end

  def write_file(relative_path, content)
    path = File.join(repo_root, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def read_file(relative_path)
    File.read(File.join(repo_root, relative_path))
  end

  def bump_manifest(key, version)
    p = pin(key)
    if p.manifest == "requirements.txt"
      content = read_file("vendor/pins/#{p.provider_dir}/requirements.txt")
      write_file("vendor/pins/#{p.provider_dir}/requirements.txt", content.sub(/==\s*\d[^\s]*/, "==#{version}"))
    else
      manifest = JSON.parse(read_file("vendor/pins/#{p.provider_dir}/package.json"))
      manifest["devDependencies"][p.package] = version
      write_file("vendor/pins/#{p.provider_dir}/package.json", "#{JSON.pretty_generate(manifest)}\n")
    end
  end

  describe "an in-range bump" do
    it "rewrites the constant from the manifest" do
      bump_manifest("opencode/opencode-ai", "1.18.10")

      summary = described_class.new(repo_root).call

      expect(read_file("lib/agent_harness/providers/opencode.rb"))
        .to include('SUPPORTED_CLI_VERSION = "1.18.10"')
      expect(summary).to include("lib/agent_harness/providers/opencode.rb: SUPPORTED_CLI_VERSION 1.18.9 -> 1.18.10")
    end

    it "rewrites pip pins from requirements.txt" do
      bump_manifest("aider/aider-chat", "0.86.3")

      described_class.new(repo_root).call

      expect(read_file("lib/agent_harness/providers/aider.rb"))
        .to include('SUPPORTED_CLI_VERSION = "0.86.3"')
    end

    it "rewrites the bun runtime pin without touching sibling constants" do
      bump_manifest("omp/bun", "1.3.15")

      described_class.new(repo_root).call

      source = read_file("lib/agent_harness/providers/omp.rb")
      expect(source).to include('SUPPORTED_BUN_VERSION = "1.3.15"')
      expect(source).to include('SUPPORTED_CLI_VERSION = "17.0.1"')
    end

    it "leaves unrelated constants and other providers untouched" do
      bump_manifest("claude/@anthropic-ai/claude-code", "2.1.93")
      before = Dir[File.join(repo_root, "**/*.{rb,json,txt}")].sort.to_h { |f| [f, File.read(f)] }

      described_class.new(repo_root).call

      after = Dir[File.join(repo_root, "**/*.{rb,json,txt}")].sort.to_h { |f| [f, File.read(f)] }
      expect(after["#{repo_root}/lib/agent_harness/providers/anthropic.rb"])
        .to include('SUPPORTED_CLI_VERSION = "2.1.93"')
      changed = before.reject { |f, c| after[f] == c }.keys - ["#{repo_root}/lib/agent_harness/providers/anthropic.rb"]
      expect(changed).to eq([])
    end
  end

  describe "an already-synced tree" do
    it "is a no-op and reports in sync" do
      before = Dir[File.join(repo_root, "**/*.{rb,json,txt}")].sort.to_h { |f| [f, File.read(f)] }

      summary = described_class.new(repo_root).call

      expect(summary).to eq("vendor/pins manifests and provider constants are in sync")
      after = Dir[File.join(repo_root, "**/*.{rb,json,txt}")].sort.to_h { |f| [f, File.read(f)] }
      expect(after).to eq(before)
    end
  end

  describe "a bump outside the requirement" do
    it "blocks, raises a comment-ready message, and writes nothing" do
      bump_manifest("codex/@openai/codex", "0.123.0")
      before = Dir[File.join(repo_root, "**/*.{rb,json,txt}")].sort.to_h { |f| [f, File.read(f)] }

      expect { described_class.new(repo_root).call }
        .to raise_error(CliPinSync::BlockedBump) do |error|
        expect(error.message).to include("< 0.123.0")
        expect(error.message).to include("@openai/codex")
        expect(error.message).to include(CliPinSync::BLOCKED_COMMENT_MARKER)
      end

      after = Dir[File.join(repo_root, "**/*.{rb,json,txt}")].sort.to_h { |f| [f, File.read(f)] }
      expect(after).to eq(before)
    end

    it "blocks exact-pin providers (gemini `= requirement`)" do
      bump_manifest("gemini/@google/gemini-cli", "0.35.4")

      expect { described_class.new(repo_root).call }.to raise_error(CliPinSync::BlockedBump)
    end

    it "blocks kilocode's string-form requirement" do
      bump_manifest("kilocode/@kilocode/cli", "7.4.17")

      expect { described_class.new(repo_root).call }
        .to raise_error(CliPinSync::BlockedBump, /= 7\.4\.16/)
    end

    it "never partially syncs when another provider is blocked" do
      bump_manifest("opencode/opencode-ai", "1.18.10")
      bump_manifest("codex/@openai/codex", "0.123.0")

      expect { described_class.new(repo_root).call }.to raise_error(CliPinSync::BlockedBump)
      expect(read_file("lib/agent_harness/providers/opencode.rb"))
        .to include('SUPPORTED_CLI_VERSION = "1.18.9"')
    end
  end

  describe "structural drift" do
    it "fails loudly when the manifest loses its exact pin" do
      manifest = JSON.parse(read_file("vendor/pins/opencode/package.json"))
      manifest["devDependencies"]["opencode-ai"] = "^1.18.10"
      write_file("vendor/pins/opencode/package.json", JSON.pretty_generate(manifest))

      expect { described_class.new(repo_root).call }
        .to raise_error(CliPinSync::SyncError, /unparseable version/)
    end

    it "fails loudly when the provider loses its requirement assignment" do
      source = read_file("lib/agent_harness/providers/opencode.rb")
        .gsub(/^\s*SUPPORTED_CLI_REQUIREMENT.*$/, "")
      write_file("lib/agent_harness/providers/opencode.rb", source)
      bump_manifest("opencode/opencode-ai", "1.18.10")

      expect { described_class.new(repo_root).call }
        .to raise_error(CliPinSync::SyncError, /SUPPORTED_CLI_REQUIREMENT/)
    end

    it "fails loudly when the requirement spans multiple lines with a first-line literal" do
      source = read_file("lib/agent_harness/providers/opencode.rb").sub(
        /^(\s*)SUPPORTED_CLI_REQUIREMENT\s*=\s*.*$/,
        "\\1SUPPORTED_CLI_REQUIREMENT = Gem::Requirement.new(\">= \#{SUPPORTED_CLI_VERSION}\",\n\\1  \"< 2.0.0\").freeze"
      )
      write_file("lib/agent_harness/providers/opencode.rb", source)
      bump_manifest("opencode/opencode-ai", "2.5.0")

      expect { described_class.new(repo_root).call }
        .to raise_error(CliPinSync::SyncError, /continues on the next line/)
    end
  end

  describe "the executable wrapper" do
    let(:script) { File.expand_path("../script/sync-cli-pins.rb", __dir__) }
    let(:comment_file) { File.join(repo_root, "blocked-comment.md") }

    it "exits 0 and prints the summary on an in-sync tree" do
      _out, err, status = Open3.capture3(RbConfig.ruby, script, repo_root)

      expect(status.exitstatus).to eq(0)
      expect(err).to eq("")
    end

    it "exits 1 and writes the PR comment file on a blocked bump" do
      bump_manifest("codex/@openai/codex", "0.123.0")

      _out, err, status = Open3.capture3(
        {"CLI_PIN_SYNC_COMMENT_FILE" => comment_file},
        RbConfig.ruby, script, repo_root
      )

      expect(status.exitstatus).to eq(1)
      expect(err).to include("CLI pin sync blocked")
      expect(File.read(comment_file)).to include(CliPinSync::BLOCKED_COMMENT_MARKER)
    end
  end
end

RSpec.describe "CliPinSync::PINS inventory" do
  let(:repo_root) { File.expand_path("..", __dir__) }

  it "covers exactly the provider directories under vendor/pins" do
    dirs = Dir.children(File.join(repo_root, "vendor", "pins")).select do |entry|
      File.directory?(File.join(repo_root, "vendor", "pins", entry))
    end.sort

    expect(CliPinSync::PINS.map(&:provider_dir).uniq.sort).to eq(dirs)
  end

  it "watches every package each manifest pins" do
    CliPinSync::PINS.group_by(&:provider_dir).each do |dir, pins|
      path = File.join(repo_root, "vendor", "pins", dir, pins.first.manifest)
      pinned = if pins.first.manifest == "requirements.txt"
        File.readlines(path, chomp: true).reject { |line| line.strip.empty? || line.start_with?("#") }
          .map { |line| line.split("==", 2).first.strip }.sort
      else
        JSON.parse(File.read(path)).fetch("devDependencies").keys.sort
      end
      expect(pins.map(&:package).sort).to eq(pinned),
        "vendor/pins/#{dir} pins #{pinned.inspect}, but the sync script watches #{pins.map(&:package).sort.inspect}"
    end
  end

  it "is a no-op against the real repository (parity currently holds)" do
    summary = CliPinSync.new(repo_root).call

    expect(summary).to eq("vendor/pins manifests and provider constants are in sync")
  end
end
