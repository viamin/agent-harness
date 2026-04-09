# PR Review Audit Disposition (Issue #91)

Audit of PRs merged before review completion in `viamin/agent-harness`.

## P1 PRs

### PR #55 — Per-request provider runtime overrides

| Finding | Disposition |
|---------|-------------|
| env stringifies only keys, not values | Fixed in PR #55 itself |
| Token tracking uses config model instead of runtime model | Fixed in PR #55 itself |
| nil env/metadata raises NoMethodError | Fixed in PR #55 itself |
| flags values not validated as Strings | Fixed in PR #55 itself |
| Adapter Hash-to-ProviderRuntime docs misleading | Fixed in PR #55 itself |
| `Array(flags)` freezes caller's array | Fixed in PR #55 itself |
| freezes caller-provided metadata Hash | Fixed in PR #55 itself |
| env type validation missing | Fixed in PR #55 itself |
| `.from_hash` no input type check | Fixed in PR #55 itself |
| flags accepts single String silently | Fixed in PR #55 itself |
| Cursor never normalizes/uses provider_runtime | Fixed in PR #55 itself |
| Cursor reimplements build_env instead of calling super | Fixed in PR #55 itself |
| runtime.model CLI vs telemetry mismatch | Fixed in PR #55 itself |
| Missing precedence spec | Fixed in PR #55 itself |
| `.wrap` kwargs bug on Ruby >= 3.2 | Fixed in PR #55 itself |
| runtime.model precedence unclear | Fixed in PR #55 itself |
| **base_url/model/api_provider not type-validated** | **Fixed forward in this PR** |
| **`.from_hash` treats `false` same as missing** | **Fixed forward in this PR** (hash_value helper) |
| Cursor not mentioned in PR description | Accepted (docs-only, no code impact) |

### PR #81 — Kilocode CLI installation contract

| Finding | Disposition |
|---------|-------------|
| `installation_contract` can raise NoMethodError for non-Adapter providers | Fixed in PR #81 itself |
| `provider_installation_contract` doesn't forward `version:` | Fixed in PR #81 itself |
| Default `installation_contract` doesn't accept `**options` | Fixed in PR #81 itself |
| Registry forwards `**options` unconditionally | Fixed in PR #81 itself |
| **`install_command` doesn't handle `version: nil`** | Accepted (produces clear error message via Gem::Version coercion) |
| **`validate_install_version!` gives generic error for bad input** | **Fixed forward in this PR** |

### PR #57 — Provider configuration capabilities

| Finding | Disposition |
|---------|-------------|
| All 19 findings (schema field removal, auth_modes derivation, model hints, accepts_arbitrary alignment) | All fixed in PR #57 itself across 5 review rounds |

### PR #42 — Gemini and Codex health/auth checks

| Finding | Disposition |
|---------|-------------|
| Temp dir from Dir.mktmpdir never cleaned up | Fixed in PR #42 itself |
| Config-file API key not validated for sk- prefix | Fixed in PR #42 itself |
| Error message hardcodes ~/.codex/config.json | Fixed in PR #42 itself |
| default_flags assumed to be Array, no guard | Fixed in PR #42 itself |
| Error message only mentions GEMINI_API_KEY | Fixed in PR #42 itself |
| validate_config doesn't check model/flags types | Fixed in PR #42 itself |
| JSON parse error leaks credential file contents | Fixed in PR #42 itself |
| Blank GEMINI_API_KEY doesn't fall back | Fixed in PR #42 itself |
| validate_config validates default_flags but build_command never uses them | Fixed in PR #42 itself |
| build_command raises if default_flags is non-Array | Fixed in PR #42 itself |
| auth_status assumes parsed JSON is Hash | Fixed in PR #42 itself |
| **auth_status returns inconsistent hash shape (missing auth_method)** | **Fixed forward in this PR** (both Codex and Gemini) |
| **Numeric status-code regexes can match unrelated numbers** | **Fixed forward in this PR** (added `\b` word boundaries) |

## P2 PRs

### PR #16 — DockerCommandExecutor

| Finding | Disposition |
|---------|-------------|
| Duplicated `normalize_command` method | Already resolved (inherits from protected parent) |
| `which` missing timeout | Already resolved (timeout: 5 added) |
| **container_id not validated for whitespace-only** | **Fixed forward in this PR** |
| Test stubs don't assert command arguments | Accepted (test quality, not a runtime defect) |

### PR #83 — OpenCode CLI installation contract

| Finding | Disposition |
|---------|-------------|
| No unresolved review comments | No action needed |

### PR #80 — Gemini CLI installation contract

| Finding | Disposition |
|---------|-------------|
| `install_contract` signature mismatch between base adapter and callers | Already resolved in current adapter.rb |
| No guard for providers without `install_contract` | Already resolved in registry.rb |
| **Malformed version strings not handled gracefully** | Already resolved (Gemini rescues ArgumentError from Gem::Version) |
| Missing test coverage for edge cases | Accepted (test quality, not a runtime defect) |

### PR #1 — Initial extraction

| Finding | Disposition |
|---------|-------------|
| `timecop` gem not declared in Gemfile | Already resolved (timecop removed from codebase) |
| Missing YamlLoader/EnvLoader files | Already resolved (references removed) |
| README binary name for Cursor incorrect | Already resolved (README says cursor-agent, matches code) |
| README binary name for GitHub Copilot incorrect | Already resolved (README updated) |
| bin/ excluded from gemspec | Accepted (intentional for gem packaging) |

## Summary of fixes in this PR

1. **ProviderRuntime**: Added type validation for `model`, `base_url`, `api_provider` (must be String or nil)
2. **ProviderRuntime**: Replaced `||`-based hash key lookup in `.from_hash` with `hash_value` helper that distinguishes nil from missing keys
3. **Codex auth_status**: Added consistent `auth_method` key to all return paths
4. **Gemini auth_status**: Added consistent `auth_method` key to all return paths
5. **Codex error_patterns**: Added `\b` word boundaries to `/401/` regex
6. **Gemini error_patterns**: Added `\b` word boundaries to `/429/` and `/503/` regexes
7. **Kilocode**: `validate_install_version!` now rescues malformed version strings with a provider-specific error message
8. **DockerCommandExecutor**: Validates whitespace-only `container_id` values
