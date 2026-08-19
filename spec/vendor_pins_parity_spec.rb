# frozen_string_literal: true

require "json"

# omp and pi are lazy-loaded via the provider registry, so require them
# explicitly for the parity constants below.
require "agent_harness/providers/omp"
require "agent_harness/providers/pi"

# Parity between the Dependabot-visible version oracles in vendor/pins/ and
# the Ruby constants each provider ships with. See vendor/pins/README.md and
# issue #336.
#
# The oracle manifests and the provider constants are two sides of the same
# fact. Dependabot only ever edits the manifest side; the step-2 sync workflow
# rewrites the Ruby constant. This spec is the linchpin that fails until the
# two agree, so a manifest bump that hasn't been mirrored into code (or a code
# bump that hasn't been mirrored into the manifest) can never merge.
RSpec.describe "vendor/pins CLI version oracles" do
  repo_root = File.expand_path("..", __dir__)
  pins_dir = File.join(repo_root, "vendor", "pins")

  # provider_dir     - directory under vendor/pins/
  # manifest         - relative manifest path (for failure messages)
  # oracle           - hash of { npm-or-pip package name => provider constant }
  npm_cases = {
    "claude" => {
      manifest: "package.json",
      packages: {"@anthropic-ai/claude-code" => AgentHarness::Providers::Anthropic::SUPPORTED_CLI_VERSION}
    },
    "codex" => {
      manifest: "package.json",
      packages: {"@openai/codex" => AgentHarness::Providers::Codex::SUPPORTED_CLI_VERSION}
    },
    "opencode" => {
      manifest: "package.json",
      packages: {"opencode-ai" => AgentHarness::Providers::Opencode::SUPPORTED_CLI_VERSION}
    },
    "gemini" => {
      manifest: "package.json",
      packages: {"@google/gemini-cli" => AgentHarness::Providers::Gemini::SUPPORTED_CLI_VERSION}
    },
    "pi" => {
      manifest: "package.json",
      packages: {"@mariozechner/pi-coding-agent" => AgentHarness::Providers::Pi::SUPPORTED_CLI_VERSION}
    },
    "omp" => {
      manifest: "package.json",
      packages: {
        "@oh-my-pi/pi-coding-agent" => AgentHarness::Providers::OhMyPi::SUPPORTED_CLI_VERSION,
        "bun" => AgentHarness::Providers::OhMyPi::SUPPORTED_BUN_VERSION
      }
    },
    "kilocode" => {
      manifest: "package.json",
      packages: {"@kilocode/cli" => AgentHarness::Providers::Kilocode::DEFAULT_VERSION}
    }
  }

  pip_cases = {
    "aider" => {
      manifest: "requirements.txt",
      packages: {"aider-chat" => AgentHarness::Providers::Aider::SUPPORTED_CLI_VERSION}
    }
  }

  describe "npm manifests" do
    npm_cases.each do |provider_dir, spec_data|
      context "vendor/pins/#{provider_dir}/#{spec_data[:manifest]}" do
        let(:manifest_path) { File.join(pins_dir, provider_dir, spec_data[:manifest]) }
        let(:manifest) { JSON.parse(File.read(manifest_path)) }
        let(:dev_dependencies) { manifest.fetch("devDependencies", {}) }

        it "exists as a devDependencies-only manifest" do
          expect(File).to exist(manifest_path),
            "expected #{manifest_path} to exist as a Dependabot version oracle"
          expect(manifest["private"]).to eq(true),
            "manifest must be marked private so it can never be published"
          expect(manifest["dependencies"]).to be_nil,
            "oracle manifests must only use devDependencies; runtime dependencies are never installed"
        end

        spec_data[:packages].each do |package, expected_version|
          it "pins #{package} to #{expected_version} (matching the provider constant)" do
            expect(dev_dependencies[package]).to eq(expected_version),
              "vendor/pins/#{provider_dir}/#{spec_data[:manifest]} pins #{package} to " \
              "#{dev_dependencies[package].inspect}, but the provider constant is " \
              "#{expected_version.inspect}. Update whichever one is stale so the manifest " \
              "and provider constant agree (see vendor/pins/README.md)."
          end
        end
      end
    end
  end

  describe "pip manifests" do
    pip_cases.each do |provider_dir, spec_data|
      context "vendor/pins/#{provider_dir}/#{spec_data[:manifest]}" do
        let(:manifest_path) { File.join(pins_dir, provider_dir, spec_data[:manifest]) }
        let(:pinned_versions) do
          File.readlines(manifest_path, chomp: true).each_with_object({}) do |line, acc|
            stripped = line.strip
            next if stripped.empty? || stripped.start_with?("#")

            name, version = stripped.split("==", 2)
            acc[name.strip] = version.strip if name && version
          end
        end

        it "exists" do
          expect(File).to exist(manifest_path),
            "expected #{manifest_path} to exist as a Dependabot version oracle"
        end

        spec_data[:packages].each do |package, expected_version|
          it "pins #{package} to #{expected_version} (matching the provider constant)" do
            expect(pinned_versions[package]).to eq(expected_version),
              "vendor/pins/#{provider_dir}/#{spec_data[:manifest]} pins #{package} to " \
              "#{pinned_versions[package].inspect}, but the provider constant is " \
              "#{expected_version.inspect}. Update whichever one is stale so the manifest " \
              "and provider constant agree (see vendor/pins/README.md)."
          end
        end
      end
    end
  end
end
