# vendor/pins — CLI version oracles

These manifests are **pure version oracles** for the CLI tools each provider
in `lib/agent_harness/providers/` wraps. They exist so Dependabot can notice
when upstream ships a new release. They are:

- **Never installed.** No `node_modules`, no runtime code imports them, and
  no CI job runs `npm install` or `pip install` against them.
- **Not shipped in the gem.** `agent-harness.gemspec` rejects `vendor/` from
  `spec.files`, so these files stay out of published releases.
- **One directory per provider.** Each tool gets its own Dependabot PR — one
  conventional commit per bump — matching how manual bumps are done today
  (recent examples: #316 opencode, #315 kilocode, #299 Claude).

## How the loop works

1. Dependabot notices a new upstream release and opens a PR editing only
   the manifest here (e.g. `vendor/pins/opencode/package.json`).
2. CI runs the parity spec at
   `spec/vendor_pins_parity_spec.rb`. It fails because the
   manifest and the provider's `SUPPORTED_CLI_VERSION` constant disagree.
3. The step-2 sync workflow (see issue #336's follow-ups) rewrites the
   corresponding Ruby constant. CI re-runs and goes green.
4. The PR is merged as a single conventional commit — same shape as the
   hand-edited bumps we do today.

Bumping the Ruby constant without touching the manifest — or vice versa —
also fails the parity spec, so drift can't slip through.

## Provider inventory

| Provider | Manifest                               | Oracle package                         | Ruby constant                                                       |
|----------|----------------------------------------|----------------------------------------|---------------------------------------------------------------------|
| claude   | `claude/package.json`                  | npm `@anthropic-ai/claude-code`        | `Providers::Anthropic::SUPPORTED_CLI_VERSION`                       |
| codex    | `codex/package.json`                   | npm `@openai/codex`                    | `Providers::Codex::SUPPORTED_CLI_VERSION`                           |
| opencode | `opencode/package.json`                | npm `opencode-ai`                      | `Providers::Opencode::SUPPORTED_CLI_VERSION`                        |
| gemini   | `gemini/package.json`                  | npm `@google/gemini-cli`               | `Providers::Gemini::SUPPORTED_CLI_VERSION`                          |
| pi       | `pi/package.json`                      | npm `@mariozechner/pi-coding-agent`    | `Providers::Pi::SUPPORTED_CLI_VERSION`                              |
| omp      | `omp/package.json` (CLI + Bun runtime) | npm `@oh-my-pi/pi-coding-agent`, `bun` | `Providers::OhMyPi::SUPPORTED_CLI_VERSION`, `SUPPORTED_BUN_VERSION` |
| kilocode | `kilocode/package.json`                | npm `@kilocode/cli`                    | `Providers::Kilocode::DEFAULT_VERSION`                              |
| aider    | `aider/requirements.txt`               | PyPI `aider-chat`                      | `Providers::Aider::SUPPORTED_CLI_VERSION`                           |

Providers deliberately without a manifest:

- **cursor** — installed from an artifact URL + SHA256, not a package
  ecosystem. Tracked by the step-3 scheduled gap-filler instead.
- **github_copilot** — the provider does not pin a `SUPPORTED_CLI_VERSION`
  (defaults to the npm `latest` tag at install time), so there is nothing to
  keep in parity.

## Caveats

- **claude oracle is version-tracking only.** Installation goes through
  `claude.ai/install.sh`, not npm. Versions on the npm mirror have
  historically matched the installer, and the step-3 cron job verifies that
  parity — but a claude-code npm bump that lags the installer will still be
  visible in the PR.
- **codex upper bound is load-bearing.** `SUPPORTED_CLI_REQUIREMENT` is
  `>= 0.122.0, < 0.123.0` because of the auth-mode gating in #329. If
  Dependabot ever opens a codex PR crossing `0.123.0`, the requirement and
  supporting code have to move first.
- **gemini is effectively frozen.** `SUPPORTED_CLI_REQUIREMENT` is
  `= 0.35.3`, so any Dependabot bump would fail the parity check anyway.
  The `.github/dependabot.yml` entry for gemini uses `ignore` to suppress
  automated PRs until the requirement is widened.
- **omp carries a Bun runtime pin.** Both `@oh-my-pi/pi-coding-agent` and
  `bun` live in the same `omp/package.json` so a runtime bump also goes
  through the same one-PR-per-provider flow. The parity spec checks both.

## `versioning-strategy`: `increase`

Every entry in `.github/dependabot.yml` for these directories uses
`versioning-strategy: "increase"` with exact-version pins. The manifests
have no siblings to reconcile — the version *is* the fact we care about —
so a strategy that also edits ranges (`widen`, `increase-if-necessary`) has
nothing to do. `lockfile-only` would silently update transitive deps
without moving the pinned version, which defeats the whole purpose of the
oracle.
