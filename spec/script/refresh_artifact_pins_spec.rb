# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "open3"

require_relative "../../script/refresh-artifact-pins"

# End-to-end coverage for the script's Cursor PR flow: branch, commit,
# push, and PR creation all go through real `git` against a bare origin,
# with `gh` replaced by a recording fake. Regression-guards the flow
# review threads from #353: the script must actually commit and push via
# git (`gh` has no push), handle slash-containing branch names, be
# idempotent on re-runs for the same build, ensure its labels exist
# before `--label` uses them, isolate a failing step from the others,
# and refresh the install-script checksum alongside the artifact pin.

CURSOR_FIXTURE = <<~RUBY
  # frozen_string_literal: true

  module AgentHarness
    module Providers
      class Cursor < Base
        INSTALL_SCRIPT_URL = "https://cursor.com/install"
        INSTALL_BUILD = "2026.03.30-a5d3e17"
        INSTALL_SCRIPT_SHA256 = "8371988b483abec13c07c10e95cccc839da81ebf9596e430d3c90835a227cbad"
        INSTALL_LINUX_X64_PACKAGE_SHA256 = "e0d4b611db111d2dbe76474386271bff3e1dbb2cc6ddf527f9d5d5801b2ce2a0"
      end
    end
  end
RUBY

NEW_BUILD = "2027.01.01-abcdef0"
NEW_SHA256 = "f" * 64
NEW_SCRIPT_SHA256 = "e" * 64
BRANCH = "dependabot/cursor-pin-#{NEW_BUILD}"

# Records every `gh` invocation; `pr list` answers from a canned queue
# so tests can simulate a PR already being open, and `fail_on` makes
# matching invocations raise CommandError to simulate GitHub API
# failures.
class FakeGithubCli
  attr_reader :calls, :messages

  def initialize(pr_numbers: [], fail_on: nil)
    @pr_numbers = pr_numbers.dup
    @fail_on = fail_on
    @calls = []
    @messages = []
  end

  def call(*args)
    @calls << args
    if @fail_on && args[0, @fail_on.length] == @fail_on
      raise AgentHarness::CliPinRefresh::GithubCli::CommandError,
        "gh #{args.join(" ")} failed (exit 1): boom"
    end
    return @pr_numbers.shift.to_s if args[0] == "pr" && args[1] == "list"
    return @pr_numbers.shift.to_s if args[0] == "issue" && args[1] == "list"

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
        script_sha256: NEW_SCRIPT_SHA256,
        artifact_url: "https://downloads.cursor.com/lab/#{NEW_BUILD}/linux/x64/agent-cli-package.tar.gz",
        install_script_url: "https://cursor.com/install",
        previous_build: "2026.03.30-a5d3e17",
        previous_sha256: "e0d4b611db111d2dbe76474386271bff3e1dbb2cc6ddf527f9d5d5801b2ce2a0",
        previous_script_sha256: "8371988b483abec13c07c10e95cccc839da81ebf9596e430d3c90835a227cbad"
      }
    )
  end

  let(:unchanged_result) { AgentHarness::CliPinRefresh::Result.new(status: :unchanged, details: {}) }

  let(:divergent_claude_result) do
    AgentHarness::CliPinRefresh::Result.new(
      status: :divergent,
      details: {
        pinned_version: "2.1.92",
        installer_version: "2.1.93",
        npm_version: "2.1.92"
      }
    )
  end

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

  def issue_create_call(calls)
    calls.find { |args| args[0] == "issue" && args[1] == "create" }
  end

  def label_create_calls(calls)
    calls.select { |args| args[0] == "label" && args[1] == "create" }
  end

  it "commits the refreshed pin, pushes the branch, and opens a PR" do
    runner.call

    expect(remote_branch_sha(BRANCH)).not_to be_nil

    blob = git(remote_path, "show", "refs/heads/#{BRANCH}:lib/agent_harness/providers/cursor.rb")
    expect(blob).to include(%(INSTALL_BUILD = "#{NEW_BUILD}"))
    expect(blob).to include(%(INSTALL_LINUX_X64_PACKAGE_SHA256 = "#{NEW_SHA256}"))
    expect(blob).to include(%(INSTALL_SCRIPT_SHA256 = "#{NEW_SCRIPT_SHA256}"))

    create_call = pr_create_call(github_cli.calls)
    expect(create_call).to include("--base", "main", "--head", BRANCH)
    expect(create_call).to include("--title", "fix(cursor): refresh agent artifact pin to #{NEW_BUILD}")
    body = create_call[create_call.index("--body") + 1]
    expect(body).to include(NEW_BUILD)
    expect(body).to include(NEW_SHA256)
    expect(body).to include(NEW_SCRIPT_SHA256)
    expect(body).to include("Upstream source: https://cursor.com/install")
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
    expect(second_github_cli.messages.join("\n")).to match(/PR #42 already open for #{BRANCH}/o)
  end

  it "leaves git and gh untouched when the pin is unchanged" do
    allow(runner).to receive(:refresh_cursor).and_return(unchanged_result)

    runner.call

    expect(github_cli.calls).to be_empty
    expect(remote_branch_sha(BRANCH)).to be_nil
  end

  it "creates the labels before first using them on an issue" do
    allow(runner).to receive(:check_claude_oracle).and_return(divergent_claude_result)

    runner.call

    calls = github_cli.calls
    issue_create = issue_create_call(calls)
    expect(issue_create).to include("--label", "dependencies,cli-pins,oracle-drift")
    oracle_label = label_create_calls(calls).find { |args| args[2] == "oracle-drift" }
    expect(oracle_label).to include("--color", "#d4c5f9")
    expect(calls.index(oracle_label)).to be < calls.index(issue_create)
  end

  it "creates the labels before first using them on a PR" do
    runner.call

    calls = github_cli.calls
    pr_create = pr_create_call(calls)
    expect(pr_create).to include("--label", "dependencies,cli-pins")
    expect(label_create_calls(calls).map { |args| args[2] }).to include("dependencies", "cli-pins")
  end

  it "still opens the issue when a label already exists" do
    # `label create` failing with "already exists" must not abort the run.
    failing_cli = FakeGithubCli.new(fail_on: ["label", "create"])
    failing_runner = described_class.new(
      repo_root: repo_root,
      github_cli: failing_cli,
      git_cli: AgentHarness::CliPinRefresh::GitCli.new(repo_root: repo_root)
    )
    allow(failing_runner).to receive(:refresh_cursor).and_return(unchanged_result)
    allow(failing_runner).to receive(:check_claude_oracle).and_return(divergent_claude_result)
    allow(failing_runner).to receive(:sweep_parity).and_return(unchanged_result)

    results = failing_runner.call

    expect(issue_create_call(failing_cli.calls)).not_to be_nil
    expect(results[:claude].divergent?).to be true
  end

  it "isolates a failing step so the remaining steps still run" do
    allow(runner).to receive(:check_claude_oracle).and_return(divergent_claude_result)
    allow(github_cli).to receive(:call).and_wrap_original do |method, *args|
      # Simulate a GitHub API failure only for the claude dispatch; the
      # cursor PR flow must still complete.
      if args[0] == "issue" && args[1] == "create"
        raise AgentHarness::CliPinRefresh::GithubCli::CommandError, "gh issue create failed (exit 1): 403"
      end
      method.call(*args)
    end

    results = runner.call

    expect(results[:claude].failed?).to be true
    expect(results[:claude].details[:reason]).to include("403")
    expect(results[:cursor].changed?).to be true
    expect(pr_create_call(github_cli.calls)).not_to be_nil
    expect(remote_branch_sha(BRANCH)).not_to be_nil
  end

  it "marks a crashing check as failed without aborting the other steps" do
    allow(runner).to receive(:refresh_cursor)
      .and_raise(AgentHarness::CliPinRefresh::CursorSource::ParseError, "Could not parse Cursor pin constants")

    results = runner.call

    expect(results[:cursor].failed?).to be true
    expect(results[:claude].unchanged?).to be true
    expect(github_cli.messages.join("\n")).to match(/\[cursor\] step failed: .*ParseError/o)
    expect(remote_branch_sha(BRANCH)).to be_nil
  end

  it "returns every step's result so the entry point can exit non-zero" do
    allow(runner).to receive(:check_claude_oracle).and_return(
      AgentHarness::CliPinRefresh::Result.new(status: :failed, details: {reason: "npm registry unreachable"})
    )

    results = runner.call

    expect(results.keys).to contain_exactly(:cursor, :claude, :parity)
    expect(results[:cursor].changed?).to be true
    expect(results[:claude].failed?).to be true
    expect(results[:parity].unchanged?).to be true
  end
end
