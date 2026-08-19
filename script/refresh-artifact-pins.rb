#!/usr/bin/env ruby
# frozen_string_literal: true

# Weekly scheduled job that refreshes CLI artifact pins Dependabot cannot
# see. See issue #338. Run by .github/workflows/refresh-cli-pins.yml on a
# weekly cron + workflow_dispatch.
#
# Steps:
#
#   1. Cursor pin refresh: query the Cursor agent GitHub releases API for
#      the latest `linux/x64` build + artifact SHA256. If upstream differs
#      from `lib/agent_harness/providers/cursor.rb`, open a PR.
#   2. Claude oracle parity: compare the version `claude.ai/install.sh`
#      resolves to against the npm `@anthropic-ai/claude-code` oracle.
#      Divergence -> open an issue (never guess which side is right).
#   3. Parity sweep (advisory): re-check every provider's
#      `SUPPORTED_CLI_VERSION` against its `vendor/pins/` manifest.
#
# None of the steps auto-merge. The rspec contract specs + human review
# remain the gate, same as today's manual bumps.

require "bundler/setup"
require "open3"

require "agent_harness"
# omp and pi are lazy-loaded via the provider registry, but the parity
# sweep resolves their constants directly - require them explicitly the
# same way spec/vendor_pins_parity_spec.rb does.
require "agent_harness/providers/omp"
require "agent_harness/providers/pi"

module AgentHarness
  module CliPinRefresh
    # Thin wrapper around the `gh` CLI. The script shells out because `gh`
    # already knows how to authenticate inside a GitHub Actions runner and
    # we don't want to reimplement OAuth/PAT handling in Ruby.
    class GithubCli
      class CommandError < StandardError; end

      def initialize(io: $stdout)
        @io = io
      end

      # @param args [Array<String>] arguments to pass to `gh`
      # @return [String] combined stdout
      # @raise [CommandError] when `gh` exits non-zero
      def call(*args)
        output, status = Open3.capture2("gh", *args)
        unless status.success?
          raise CommandError, "gh #{args.join(" ")} failed (exit #{status.exitstatus}): #{output}"
        end

        output
      end

      def print(message)
        @io.puts(message)
      end
    end

    # Thin wrapper around the `git` CLI. Branch/commit/push operations go
    # through plain git (the workflow checks the repo out with full
    # history and authenticated push access) because `gh` has no
    # equivalent subcommands and the Git data API would need blob SHAs
    # and base64 round-trips to do what `git commit` no-ops on identical
    # content for free.
    class GitCli
      class CommandError < StandardError; end

      def initialize(repo_root:)
        @repo_root = repo_root
      end

      # @param args [Array<String>] arguments to pass to `git -C <repo_root>`
      # @return [String] combined stdout
      # @raise [CommandError] when `git` exits non-zero
      def call(*args)
        output, status = Open3.capture2("git", "-C", @repo_root, *args)
        unless status.success?
          raise CommandError, "git #{args.join(" ")} failed (exit #{status.exitstatus}): #{output}"
        end

        output
      end

      # `git diff --cached --quiet` exits non-zero exactly when there are
      # staged changes, so success means "nothing staged".
      #
      # @return [Boolean]
      def staged_changes?
        _, status = Open3.capture2("git", "-C", @repo_root, "diff", "--cached", "--quiet")
        !status.success?
      end

      # `git ls-remote --exit-code` exits 0 when the ref exists, 2 when
      # it does not, and anything else on a real transport failure -
      # only exit 2 may be treated as "branch missing".
      #
      # @return [Boolean]
      # @raise [CommandError] on transport failure
      def remote_branch_exists?(branch)
        _, status = Open3.capture2("git", "-C", @repo_root, "ls-remote", "--exit-code", "origin",
          "refs/heads/#{branch}")
        return true if status.success?
        return false if status.exitstatus == 2

        raise CommandError, "git ls-remote origin refs/heads/#{branch} failed (exit #{status.exitstatus})"
      end

      # Commits staged changes as the automation identity. The
      # GIT_AUTHOR_*/GIT_COMMITTER_* env vars win over `-c` config, so
      # the identity is pinned through the environment to stay
      # deterministic even when the script inherits one.
      #
      # @raise [CommandError] when `git commit` exits non-zero
      def commit_as(name:, email:, message:)
        env = {
          "GIT_AUTHOR_NAME" => name,
          "GIT_AUTHOR_EMAIL" => email,
          "GIT_COMMITTER_NAME" => name,
          "GIT_COMMITTER_EMAIL" => email
        }
        output, status = Open3.capture2(env, "git", "-C", @repo_root, "commit", "-m", message)
        unless status.success?
          raise CommandError, "git commit failed (exit #{status.exitstatus}): #{output}"
        end

        output
      end
    end

    # Encapsulates the script-level orchestration: read inputs, run each
    # step, and dispatch to `gh` when an action is required.
    class ScriptRunner
      CURSOR_BRANCH_PREFIX = "dependabot/cursor-pin-"
      CURSOR_PR_TITLE = "fix(cursor): refresh agent artifact pin to %<build>s"
      CURSOR_COMMIT_SUBJECT = "fix(cursor): refresh agent artifact pin to %<build>s"
      CURSOR_PR_LABELS = %w[dependencies cli-pins]
      CLAUDE_ISSUE_TITLE = "Claude install oracle drift: install.sh=%<installer_version>s vs npm=%<npm_version>s"
      CLAUDE_ISSUE_LABELS = %w[dependencies cli-pins oracle-drift]
      PARITY_ISSUE_TITLE = "Advisory SUPPORTED_CLI_VERSION drift vs vendor/pins/"
      PARITY_ISSUE_LABELS = %w[dependencies cli-pins parity-drift]
      DEFAULT_PINNED_CLAUDE_VERSION = AgentHarness::Providers::Anthropic::SUPPORTED_CLI_VERSION
      DEFAULT_CURSOR_REPOSITORY = "cursor/agent"
      DEFAULT_CLAUDE_INSTALL_URL = "https://claude.ai/install.sh"
      DEFAULT_NPM_PACKAGE = "@anthropic-ai/claude-code"
      # The same committer identity actions/checkout-derived automation
      # uses; the runner has no global git identity configured.
      COMMIT_AUTHOR_NAME = "github-actions[bot]"
      COMMIT_AUTHOR_EMAIL = "41898282+github-actions[bot]@users.noreply.github.com"

      attr_reader :repo_root, :github_cli, :git_cli

      def initialize(repo_root:, github_cli: GithubCli.new, git_cli: GitCli.new(repo_root: repo_root))
        @repo_root = repo_root
        @github_cli = github_cli
        @git_cli = git_cli
      end

      def call
        cursor_result = refresh_cursor
        claude_result = check_claude_oracle
        parity_result = sweep_parity

        apply_cursor(cursor_result)
        apply_claude(claude_result)
        apply_parity(parity_result)

        {cursor: cursor_result, claude: claude_result, parity: parity_result}
      end

      private

      def refresh_cursor
        CursorRefresh.new(
          releases: build_releases,
          downloader: ArtifactDownloader.new(http_client: HttpClient.new),
          source: CursorSource.new(file_path: cursor_source_path)
        ).call
      end

      def check_claude_oracle
        http_client = HttpClient.new
        ClaudeOracleCheck.new(
          installer_probe: ClaudeInstallerProbe.new(
            http_client: http_client,
            install_script_url: ENV.fetch("CLAUDE_INSTALL_URL", DEFAULT_CLAUDE_INSTALL_URL)
          ),
          npm_registry: NpmRegistry.new(http_client: http_client),
          pinned_version: DEFAULT_PINNED_CLAUDE_VERSION,
          package_name: ENV.fetch("CLAUDE_NPM_PACKAGE", DEFAULT_NPM_PACKAGE)
        ).call
      end

      # Advisory sweep: the parity spec at
      # `spec/vendor_pins_parity_spec.rb` is the real gate. We re-run the
      # same comparison here so any drift becomes visible inside one cron
      # window instead of waiting for the next Dependabot bump.
      def sweep_parity
        ParitySweep.new(
          pins_dir: File.join(repo_root, "vendor", "pins"),
          repo_root: repo_root
        ).call
      end

      def build_releases
        GithubCursorReleases.new(
          http_client: HttpClient.new,
          repository: ENV.fetch("CURSOR_RELEASE_REPOSITORY", DEFAULT_CURSOR_REPOSITORY)
        )
      end

      def cursor_source_path
        File.join(repo_root, "lib", "agent_harness", "providers", "cursor.rb")
      end

      def apply_cursor(result)
        @github_cli.print("[cursor] #{result.status}: #{result.details.inspect}")
        return unless result.changed?

        details = result.details
        build = details.fetch(:build)
        sha256 = details.fetch(:sha256)
        release_url = details[:release_url]

        source = CursorSource.new(file_path: cursor_source_path)
        rendered = source.render(build: build, sha256: sha256)
        branch = "#{CURSOR_BRANCH_PREFIX}#{build}"

        create_or_update_branch(branch)
        commit_cursor_pin(rendered, build: build)
        push_branch(branch)
        open_pull_request(
          branch: branch,
          title: format(CURSOR_PR_TITLE, build: build),
          body: cursor_pr_body(details, release_url),
          labels: CURSOR_PR_LABELS
        )
      end

      def cursor_pr_body(details, release_url)
        [
          "Refreshes the Cursor artifact pin to match the upstream release.",
          "",
          "- New build: `#{details[:build]}`",
          "- New SHA256: `#{details[:sha256]}`",
          "- Artifact URL: #{details[:artifact_url]}",
          release_url ? "- Release notes: #{release_url}" : nil,
          "",
          "Previous pin:",
          "",
          "- Build: `#{details[:previous_build]}`",
          "- SHA256: `#{details[:previous_sha256]}`",
          "",
          "release-please will mint the version PR as usual; the rspec parity",
          "specs and human review remain the gate."
        ].compact.join("\n")
      end

      def apply_claude(result)
        @github_cli.print("[claude] #{result.status}: #{result.details.inspect}")
        return unless result.divergent?

        details = result.details
        open_issue(
          title: format(
            CLAUDE_ISSUE_TITLE,
            installer_version: details[:installer_version],
            npm_version: details[:npm_version]
          ),
          body: claude_issue_body(details),
          labels: CLAUDE_ISSUE_LABELS,
          search_labels: CLAUDE_ISSUE_LABELS
        )
      end

      def claude_issue_body(details)
        [
          "The Claude install oracle (npm `@anthropic-ai/claude-code`) and",
          "`claude.ai/install.sh` resolved to different versions during the",
          "scheduled parity check (issue #338). Manual investigation is",
          "needed to determine which source is right before either is",
          "bumped.",
          "",
          "- Pinned version in `Providers::Anthropic::SUPPORTED_CLI_VERSION`: `#{details[:pinned_version]}`",
          "- `claude.ai/install.sh` resolves to: `#{details[:installer_version]}`",
          "- npm `@anthropic-ai/claude-code` latest: `#{details[:npm_version]}`",
          "",
          "Do **not** auto-merge either side until the discrepancy is",
          "understood. See vendor/pins/README.md for the oracle contract."
        ].join("\n")
      end

      def apply_parity(result)
        @github_cli.print("[parity] #{result.status}: #{result.details.inspect}")
        return unless result.divergent?

        open_issue(
          title: PARITY_ISSUE_TITLE,
          body: parity_issue_body(result.details),
          labels: PARITY_ISSUE_LABELS,
          search_labels: PARITY_ISSUE_LABELS
        )
      end

      def parity_issue_body(details)
        offenders = details.fetch(:offenders)
        lines = [
          "The scheduled parity sweep detected `SUPPORTED_CLI_VERSION`",
          "constants that no longer match their `vendor/pins/` manifest.",
          "The CI parity spec at `spec/vendor_pins_parity_spec.rb` is the",
          "real gate - this issue is advisory so drift is visible inside one",
          "cron window.",
          "",
          "Offenders:"
        ]
        offenders.each do |offender|
          lines << "- `#{offender[:ecosystem]}:#{offender[:provider]}:#{offender[:package]}` " \
            "manifest=`#{offender[:manifest_value].inspect}` constant=`#{offender[:constant_value].inspect}`"
        end
        lines.join("\n")
      end

      def create_or_update_branch(branch)
        # Refresh remote-tracking refs, then point the local branch at
        # its remote counterpart when one already exists (so a re-run
        # for the same build re-derives an unchanged tree and commits
        # nothing), or at main's tip when creating it fresh.
        @git_cli.call("fetch", "origin")
        base = @git_cli.remote_branch_exists?(branch) ? "origin/#{branch}" : "origin/main"
        @git_cli.call("checkout", "-B", branch, base)
      end

      def commit_cursor_pin(rendered_content, build:)
        # Write the rendered cursor.rb, stage it, and commit when the
        # content actually changed. Re-running for the same build ends
        # with nothing to commit, which keeps the whole flow idempotent.
        File.write(cursor_source_path, rendered_content)
        @git_cli.call("add", cursor_source_path)
        return unless @git_cli.staged_changes?

        @git_cli.commit_as(
          name: COMMIT_AUTHOR_NAME,
          email: COMMIT_AUTHOR_EMAIL,
          message: format(CURSOR_COMMIT_SUBJECT, build: build)
        )
        @github_cli.print("[cursor] committed pin refresh (build=#{build})")
      end

      def push_branch(branch)
        # The automation branch always carries a single generated commit
        # on top of current main; force-with-lease keeps it there even
        # when main has moved since the branch was first pushed (the
        # same update model Dependabot uses for its branches).
        @git_cli.call("push", "--force-with-lease", "origin", branch)
      end

      def open_pull_request(branch:, title:, body:, labels:)
        existing = find_open_pull_request(branch)
        if existing
          @github_cli.print("[cursor] PR ##{existing} already open for #{branch}")
          return
        end

        @github_cli.call(
          "pr", "create",
          "--base", "main",
          "--head", branch,
          "--title", title,
          "--body", body,
          "--label", labels.join(",")
        )
      end

      def find_open_pull_request(branch)
        raw = @github_cli.call("pr", "list", "--head", branch, "--state", "open",
          "--json", "number", "--jq", ".[0].number")
        number = raw.strip
        return nil if number.empty?

        number
      rescue GithubCli::CommandError
        nil
      end

      def open_issue(title:, body:, labels:, search_labels:)
        # Reuse an existing issue with the same search labels if one is
        # already open, so we don't flood the issue list each run.
        existing = find_open_issue(search_labels)
        if existing
          comment_on_issue(existing, body)
        else
          create_issue(title: title, body: body, labels: labels)
        end
      end

      def find_open_issue(labels)
        label_arg = labels.join(",")
        raw = @github_cli.call("issue", "list", "--label", label_arg, "--state", "open",
          "--json", "number", "--jq", ".[0].number")
        number = raw.strip
        return nil if number.empty?

        number
      rescue GithubCli::CommandError
        nil
      end

      def comment_on_issue(number, body)
        @github_cli.call("issue", "comment", number.to_s, "--body", body)
      end

      def create_issue(title:, body:, labels:)
        @github_cli.call(
          "issue", "create",
          "--title", title,
          "--body", body,
          "--label", labels.join(",")
        )
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  repo_root = File.expand_path("..", __dir__)
  AgentHarness::CliPinRefresh::ScriptRunner.new(repo_root: repo_root).call
end
