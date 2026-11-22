# frozen_string_literal: true

require "spec_helper"

RSpec.describe "the gem publication workflow" do
  subject(:workflow) { File.read(File.expand_path("../../.github/workflows/publish.yml", __dir__)) }

  it "uses the repository Ruby toolchain and preserves pinned trusted publishing boundaries" do
    ruby_version = File.read(File.expand_path("../../.tool-versions", __dir__)).split.fetch(1)

    expect(workflow).to include("ruby-version: #{ruby_version}")
    expect(workflow).to include("id-token: write", "contents: write", "persist-credentials: false")
    expect(workflow).to match(%r{uses: rubygems/release-gem@[0-9a-f]{40}})
    expect(workflow).to match(%r{uses: ruby/setup-ruby@[0-9a-f]{40}})
  end

  it "skips an immutable matching release and replaces the private-API checker with bounded verification" do
    expect(workflow).to include("await-release: false")
    expect(workflow).to include("steps.existing.outputs.published != 'true'")
    expect(workflow).to include("--attempts 30 --interval 10")
    expect(workflow).not_to match(/^\s+run:.*rubygems-await/)
  end

  it "provides a verification-only retry path that cannot publish the immutable release" do
    expect(workflow).to include("workflow_dispatch:", "Verify an existing immutable release without publishing")
    expect(workflow).to include("if: github.event_name != 'workflow_dispatch' && steps.existing.outputs.published != 'true'")
    expect(workflow).to include("VERIFY_VERSION: ${{ inputs.version }}", "--version \"$VERIFY_VERSION\"")
  end
end
