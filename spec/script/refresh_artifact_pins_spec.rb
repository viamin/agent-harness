# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "open3"

require_relative "../../script/refresh-artifact-pins"

# End-to-end coverage for the script's Cursor PR flow: branch, commit,
# push, and PR creation all go through real `git` against a bare origin,
# with `gh` replaced by a recording fake. Regression-guards the flow
# review threads from #353: the script must actually commit and push via
# git (`gh` has no push), handle slash-containing branch names, and be
# idempotent on re-runs for the same build.

CURSOR_FIXTURE = <<~RUBY
  # frozen_string_literal: true

  module AgentHarness
    module Providers
      class Cursor < Base
        INSTALL_BUILD = "2026.03.30-a5d3e17"
        INSTALL_LINUX_X64_PACKAGE_SHA256 = "e0d4b611db111d2dbe76474386271bff3e1dbb2cc6ddf527f9d5d5801b2ce2a0"
      end
    end
  end
RUBY

NEW_BUILD = "2027.01.01-abcdef0"
NEW_SHA256 = "f" * 64
BRANCH = "dependabot/cursor-pin-#{NEW_BUILD}"

# Records every `gh` invocation; `pr list` answers from a canned queue
# so tests can simulate a PR already being open.
class FakeGithubCli
  attr_reader :calls, :messages

  def initialize(pr_numbers: [])
    @pr_numbers = pr_numbers.dup
    @calls = []
    @messages = []
  end

  def call(*args)
    @calls << args
    return @pr_numbers.shift.to_s if args[0] == "pr" && args[1] == "list"

    ""
  end

  def print(message)
    @messages << message
  end
end

RSpec.describe AgentHarness::CliPinRefresh::ScriptRunner do
  around do |example|
    Dir.mktmpdir("cursor-pin-runner-") do |sandbox|
      @sandbox = sandbox
      example.run
    end
  end

  before do
    remote_path = File.join(@sandbox, "remote.git")
    repo_root = File.join(@sandbox, "repo")
    cursor_path = File.join(repo_root, "lib", "agent_harness", "providers", "cursor.rb")

    FileUtils.mkdir_p(remote_path)
    git(remote_path, "init", "--bare", "-b", "main")
    FileUtils.mkdir_p(File.dirname(cursor_path))
    File.write(cursor_path, CURSOR_FIXTURE)
    git(repo_root, "init", "-b", "main")
    git(repo_root, "add", ".")
    git(repo_root, "-c", "user.name=Spec", "-c", "user.email=spec@example.test",
      "commit", "-m", "chore: seed cursor pin")
    git(repo_root, "remote", "add", "origin", remote_path)
    git(repo_root, "push", "-q", "origin", "main")
  end

  let(:repo_root) { File.join(@sandbox, "repo") }
  let(:remote_path) { File.join(@sandbox, "remote.git") }
  let(:github_cli) { FakeGithubCli.new }

  let(:runner) do
    described_class.new(
      repo_root: repo_root,
      github_cli: github_cli,
      git_cli: AgentHarness::CliPinRefresh::GitCli.new(repo_root: repo_root)
    )
  end

  let(:changed_result) do
    AgentHarness::CliPinRefresh::Result.new(
      status: :changed,
      details: {
        build: NEW_BUILD,
        sha256: NEW_SHA256,
        artifact_url: "https://downloads.cursor.com/lab/#{NEW_BUILD}/linux/x64/agent-cli-package.tar.gz",
        release_url: "https://github.com/cursor/agent/releases/tag/v#{NEW_BUILD}",
        previous_build: "2026.03.30-a5d3e17",
        previous_sha256: "e0d4b611db111d2dbe76474386271bff3e1dbb2cc6ddf527f9d5d5801b2ce2a0"
      }
    )
  end

  let(:unchanged_result) { AgentHarness::CliPinRefresh::Result.new(status: :unchanged, details: {}) }

  before do
    allow(runner).to receive(:refresh_cursor).and_return(changed_result)
    allow(runner).to receive(:check_claude_oracle).and_return(unchanged_result)
    allow(runner).to receive(:sweep_parity).and_return(unchanged_result)
  end

  def git(dir, *args)
    output, status = Open3.capture2e("git", "-C", dir, *args)
    raise "git #{args.join(" ")} failed (exit #{status.exitstatus}): #{output}" unless status.success?

    output
  end

  def remote_branch_sha(branch)
    git(repo_root, "ls-remote", "origin", "refs/heads/#{branch}").split.first
  end

  def pr_create_call(calls)
    calls.find { |args| args[0] == "pr" && args[1] == "create" }
  end

  it "commits the refreshed pin, pushes the branch, and opens a PR" do
    runner.call

    expect(remote_branch_sha(BRANCH)).not_to be_nil

    blob = git(remote_path, "show", "refs/heads/#{BRANCH}:lib/agent_harness/providers/cursor.rb")
    expect(blob).to include(%(INSTALL_BUILD = "#{NEW_BUILD}"))
    expect(blob).to include(%(INSTALL_LINUX_X64_PACKAGE_SHA256 = "#{NEW_SHA256}"))

    create_call = pr_create_call(github_cli.calls)
    expect(create_call).to include("--base", "main", "--head", BRANCH)
    expect(create_call).to include("--title", "fix(cursor): refresh agent artifact pin to #{NEW_BUILD}")
    body = create_call[create_call.index("--body") + 1]
    expect(body).to include(NEW_BUILD)
    expect(body).to include(NEW_SHA256)
  end

  it "commits as the automation identity, not the runner's git config" do
    runner.call

    author = git(repo_root, "log", "-1", "--format=%an <%ae>", BRANCH).strip
    expect(author).to eq(
      "github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>"
    )
  end

  it "pushes nothing new and opens no second PR when re-run for the same build" do
    runner.call
    sha_before = remote_branch_sha(BRANCH)

    second_github_cli = FakeGithubCli.new(pr_numbers: ["42"])
    second_runner = described_class.new(
      repo_root: repo_root,
      github_cli: second_github_cli,
      git_cli: AgentHarness::CliPinRefresh::GitCli.new(repo_root: repo_root)
    )
    allow(second_runner).to receive(:refresh_cursor).and_return(changed_result)
    allow(second_runner).to receive(:check_claude_oracle).and_return(unchanged_result)
    allow(second_runner).to receive(:sweep_parity).and_return(unchanged_result)

    second_runner.call

    expect(remote_branch_sha(BRANCH)).to eq(sha_before)
    expect(pr_create_call(second_github_cli.calls)).to be_nil
    expect(second_github_cli.messages.join("\n")).to match(/PR #42 already open for #{BRANCH}/)
  end

  it "leaves git and gh untouched when the pin is unchanged" do
    allow(runner).to receive(:refresh_cursor).and_return(unchanged_result)

    runner.call

    expect(github_cli.calls).to be_empty
    expect(remote_branch_sha(BRANCH)).to be_nil
  end
end
