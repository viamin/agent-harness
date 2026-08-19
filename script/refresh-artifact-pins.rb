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

    # Encapsulates the script-level orchestration: read inputs, run each
    # step, and dispatch to `gh` when an action is required.
    class ScriptRunner
      CURSOR_BRANCH_PREFIX = "dependabot/cursor-pin-"
      CURSOR_PR_TITLE = "fix(cursor): refresh agent artifact pin to %<build>s"
      CURSOR_PR_LABELS = %w[dependencies cli-pins]
      CLAUDE_ISSUE_TITLE = "Claude install oracle drift: install.sh=%<installer_version>s vs npm=%<npm_version>s"
      CLAUDE_ISSUE_LABELS = %w[dependencies cli-pins oracle-drift]
      PARITY_ISSUE_TITLE = "Advisory SUPPORTED_CLI_VERSION drift vs vendor/pins/"
      PARITY_ISSUE_LABELS = %w[dependencies cli-pins parity-drift]
      DEFAULT_PINNED_CLAUDE_VERSION = AgentHarness::Providers::Anthropic::SUPPORTED_CLI_VERSION
      DEFAULT_CURSOR_REPOSITORY = "cursor/agent"
      DEFAULT_CLAUDE_INSTALL_URL = "https://claude.ai/install.sh"
      DEFAULT_NPM_PACKAGE = "@anthropic-ai/claude-code"

      attr_reader :repo_root, :github_cli

      def initialize(repo_root:, github_cli: GithubCli.new)
        @repo_root = repo_root
        @github_cli = github_cli
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
        # Idempotent: create the branch from main if it doesn't exist.
        @github_cli.call("api", "-X", "GET", "/repos/:owner/:repo/branches/#{branch}")
      rescue GithubCli::CommandError
        @github_cli.call("api", "-X", "POST", "/repos/:owner/:repo/git/refs",
          "--field", "ref=refs/heads/#{branch}",
          "--field", "sha=#{main_sha}")
      end

      def main_sha
        @github_cli.call("api", "/repos/:owner/:repo/git/ref/heads/main").then do |raw|
          JSON.parse(raw).fetch("object").fetch("sha")
        end
      end

      def commit_cursor_pin(rendered_content, build:)
        # Write the rendered cursor.rb to the working tree and let the
        # workflow handle the actual git commit via the existing tooling.
        # Writing in-script keeps the script self-contained.
        File.write(cursor_source_path, rendered_content)
        @github_cli.print("[cursor] wrote refreshed cursor.rb (build=#{build})")
      end

      def push_branch(branch)
        @github_cli.call("push", "origin", branch)
      end

      def open_pull_request(branch:, title:, body:, labels:)
        @github_cli.call(
          "pr", "create",
          "--base", "main",
          "--head", branch,
          "--title", title,
          "--body", body,
          "--label", labels.join(",")
        )
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
  require "json"

  repo_root = File.expand_path("..", __dir__)
  AgentHarness::CliPinRefresh::ScriptRunner.new(repo_root: repo_root).call
end
