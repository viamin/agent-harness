# AgentHarness

A unified Ruby interface for CLI-based AI coding agents like Claude Code, Cursor, Gemini CLI, GitHub Copilot, and more.

## Features

- **Unified Interface**: Single API for multiple AI coding agents
- **11 Built-in Providers**: Claude Code, Cursor, Gemini CLI, GitHub Copilot, Codex, Pi, Oh My Pi, Aider, OpenCode, Kilocode, Mistral Vibe
- **Full Orchestration**: Provider switching, circuit breakers, rate limiting, and health monitoring
- **Flexible Configuration**: YAML, Ruby DSL, or environment variables
- **Token Tracking**: Monitor usage across providers for cost and limit management
- **Error Taxonomy**: Standardized error classification for consistent error handling
- **Dynamic Registration**: Add custom providers at runtime

## Installation

Add to your Gemfile:

```ruby
gem "agent-harness"
```

Or install directly:

```bash
gem install agent-harness
```

## Quick Start

```ruby
require "agent_harness"

# Send a message using the default provider
response = AgentHarness.send_message("Write a hello world function in Ruby")
puts response.output

# Use a specific provider
response = AgentHarness.send_message("Explain this code", provider: :cursor)
```

## Configuration

### Ruby DSL

```ruby
AgentHarness.configure do |config|
  # Logging
  config.logger = Logger.new(STDOUT)
  config.log_level = :info

  # Default provider
  config.default_provider = :claude
  config.fallback_providers = [:cursor, :gemini]

  # Timeouts
  config.default_timeout = 300

  # Orchestration
  config.orchestration do |orch|
    orch.enabled = true
    orch.auto_switch_on_error = true
    orch.auto_switch_on_rate_limit = true

    orch.circuit_breaker do |cb|
      cb.enabled = true
      cb.failure_threshold = 5
      cb.timeout = 300
    end

    orch.retry do |r|
      r.enabled = true
      r.max_attempts = 3
      r.base_delay = 1.0
    end
  end

  # Provider-specific configuration
  config.provider(:claude) do |p|
    p.enabled = true
    p.timeout = 600
    p.model = "claude-sonnet-4-20250514"
  end

  # Callbacks
  config.on_tokens_used do |event|
    puts "Used #{event.total_tokens} tokens on #{event.provider}"
  end

  config.on_provider_switch do |event|
    puts "Switched from #{event[:from]} to #{event[:to]}: #{event[:reason]}"
  end
end
```

## Providers

### Built-in Providers

| Provider | CLI Binary | Description |
| -------- | ---------- | ----------- |
| `:claude` | `claude` | Anthropic Claude Code CLI |
| `:cursor` | `cursor-agent` | Cursor AI editor CLI |
| `:gemini` | `gemini` | Google Gemini CLI |
| `:github_copilot` | `copilot` | GitHub Copilot CLI |
| `:codex` | `codex` | OpenAI Codex CLI |
| `:pi` | `pi` | Pi coding agent CLI |
| `:omp` | `omp` | Oh My Pi coding agent CLI (Bun-based fork of Pi) |
| `:aider` | `aider` | Aider coding assistant |
| `:opencode` | `opencode` | OpenCode CLI |
| `:kilocode` | `kilo` | Kilocode CLI |
| `:mistral_vibe` | `mistral-vibe` | Mistral Vibe CLI |

### Provider Install Contracts

Provider classes can expose install metadata for downstream apps that build
their own agent images.

```ruby
contract = AgentHarness.provider_install_contract(:gemini)

contract[:package_name]
# => "@google/gemini-cli"

contract[:default_version]
# => "0.35.3"

contract[:install_command]
# => ["npm", "install", "-g", "--ignore-scripts", "@google/gemini-cli@0.35.3"]
```

Cursor also exposes a first-class install contract for container/image builds.
The contract publishes checksums for both the installer script and the default
Linux x64 artifact so consumers can verify downloads independently:

```ruby
cursor_install = AgentHarness::Providers::Cursor.install_metadata

cursor_install
# => {
#      source: {
#        type: :shell_script,
#        url: "https://cursor.com/install",
#        resolved_version: "2026.03.30-a5d3e17",
#        default_artifact_url: "https://downloads.cursor.com/lab/2026.03.30-a5d3e17/linux/x64/agent-cli-package.tar.gz"
#      },
#      checksum: {
#        strategy: :sha256,
#        targets: {
#          script: { url: "https://cursor.com/install", value: "8371..." },
#          artifacts: { "linux/x64" => { url: "https://downloads.cursor.com/...", value: "e0d4..." } }
#        }
#      },
#      binary: {
#        name: "cursor-agent",
#        path: "$HOME/.local/bin/cursor-agent",
#        suggested_global_path: "/usr/local/bin/cursor-agent"
#      },
#      version: {
#        default: "latest",
#        supported: "latest",
#        command: ["cursor-agent", "--version"]
#      }
#    }
```

### Direct Provider Access

```ruby
# Get a provider instance
provider = AgentHarness.provider(:claude)
response = provider.send_message(prompt: "Hello!")

# Check provider availability
if AgentHarness::Providers::Registry.instance.get(:claude).available?
  puts "Claude CLI is installed"
end

# Ask the harness which Claude CLI install contract it supports
contract = AgentHarness.install_contract(:claude)
puts contract[:install][:command]
# => "tmp_script=$(mktemp) && ... && bash \"$tmp_script\" 2.1.92"
puts contract[:install][:post_install_binary_path]
# => "$HOME/.local/bin/claude"
puts contract[:supported_versions][:default]
# => "2.1.92"
puts contract[:supported_versions][:requirement]
# => ">= 2.1.92, < 2.2.0"

# List all registered providers
AgentHarness::Providers::Registry.instance.all
# => [:claude, :cursor, :gemini, :github_copilot, :pi, :omp, :codex, :opencode, :kilocode, :aider, :mistral_vibe]
```

For Claude, the install contract is the first-class source of truth for:

- the official install recipe the current harness release expects
- the expected binary name and normalized PATH entry that recipe leaves behind
- the supported Claude CLI version boundary the current harness release validates (`default` plus the compatible version range)

### Provider Installation Contracts

Downstream apps can ask `agent-harness` for provider-specific CLI install
metadata instead of hardcoding package names, binary names, or supported
versions out-of-band.

```ruby
contract = AgentHarness.provider_installation_contract(:kilocode, version: "7.4.16")

contract
# {
#   source: { type: :npm, package: "@kilocode/cli" },
#   install_command: ["npm", "install", "-g", "--ignore-scripts", "@kilocode/cli@7.4.16"],
#   binary_name: "kilo",
#   default_version: "7.4.16",
#   supported_version_requirement: "= 7.4.16"
# }
```

The Kilocode runtime adapter expects the `kilo` binary and executes prompts via
`kilo run ...`, so the install contract and runtime behavior stay aligned in
tests.

#### Kilocode permission defaults

In non-interactive container runs Kilo boots with an `external_directory`
permission default of `ask`, which silently auto-rejects any read/write/edit
tool call targeting paths outside the project directory (no human is present to
approve the prompt). To keep those runs alive, the Kilocode provider injects a
permissive default allowlist into the generated `kilo.json` before the CLI
boots:

```json
{
  "permission": {
    "external_directory": {
      "/tmp/**": "allow",
      "/home/agent/**": "allow"
    }
  }
}
```

This covers the agent's scratch output (`/tmp`) and its own config/cache/data
files (`/home/agent`). When a caller supplies its own `permission` block (for
example via the `provider_runtime` metadata `config` extras, or the
`permission:` option on `config_file_content`), the caller's entries are
**merged on top of** these defaults: the `external_directory` rules are unioned
together with the caller winning on overlapping patterns, and every other
caller-supplied permission category is carried through verbatim. That means a
downstream app can add a single extra path without re-declaring the provider
defaults:

```ruby
# Only the agent-harness gem path is added; /tmp/** and /home/agent/**
# are still allowed automatically.
runtime = AgentHarness::ProviderRuntime.new(
  metadata: {
    config: {
      permission: {
        external_directory: {
          "/usr/local/lib/ruby/gems/*/gems/agent-harness-*/**" => "allow"
        }
      }
    }
  }
)
```

A caller that intentionally wants to **own the full permission block** (for
example to deny the default `/tmp` or `/home/agent` paths) can opt out of the
merge with `permission_replace: true`, in which case the supplied `permission`
is honored verbatim and no defaults are injected:

```ruby
runtime = AgentHarness::ProviderRuntime.new(
  metadata: {
    config: {
      permission_replace: true,
      permission: {
        bash: "ask",
        external_directory: {"/workspace/**" => "allow"}
      }
    }
  }
)
```

The `permission_replace` control flag is consumed by the provider and stripped
before the config is written to disk, so it never reaches `kilo.json`.

Providers that expose installation contracts can also be queried through the
generic API:

```ruby
codex_install = AgentHarness.installation_contract(:codex)
aider_install = AgentHarness.installation_contract(:aider)
opencode_install = AgentHarness.installation_contract(:opencode)

opencode_install
# => {
#      source: :npm,
#      package_name: "opencode-ai",
#      version: "1.18.18",
#      version_requirement: [">= 1.18.18", "< 2.0.0"],
#      binary_name: "opencode",
#      install_command: ["npm", "install", "-g", "--ignore-scripts", "opencode-ai@1.18.18"]
#    }

aider_install
# => {
#      source: :uv_tool,
#      bootstrap_package: "uv==0.8.17",
#      package_name: "aider-chat",
#      version: "0.86.2",
#      binary_name: "aider",
#      binary_path: "/usr/local/bin/aider",
#      install_environment: {
#        "UV_TOOL_BIN_DIR" => "/usr/local/bin",
#        "UV_TOOL_DIR" => "/opt/uv/tools",
#        "UV_PYTHON_INSTALL_DIR" => "/opt/uv/python"
#      },
#      bootstrap_commands: [
#        ["python3", "-m", "pip", "install", "--no-cache-dir", "--break-system-packages", "uv==0.8.17"]
#      ],
#      install_command: ["uv", "tool", "install", "--force", "--python", "python3.12", "--with", "pip", "aider-chat==0.86.2"]
#    }
```

For supported providers like Codex and Aider, the install contract tracks
the CLI version supported by the current `agent-harness` release. The
contract includes bootstrap requirements, install command shape, and the
expected runtime binary, and the provider specs assert that runtime
expectations remain aligned with the published install metadata.

### Provider Metadata

Downstream apps can also query a consolidated provider metadata contract for
configuration UIs and policy decisions.

The following example shows how to retrieve metadata for the Anthropic provider:

```ruby
metadata = AgentHarness.provider_metadata(:anthropic)

metadata
# => {
#      provider: :claude,
#      canonical_provider: :claude,
#      aliases: [:anthropic],
#      auth: {
#        default_mode: :oauth,
#        supported_modes: [:oauth],
#        service: :anthropic,
#        api_family: :anthropic
#      },
#      runtime: {
#        interface: :cli,
#        requires_cli: true,
#        installable: false,
#        installation: nil,
#        supports_mcp: true,
#        supports_dangerous_mode: true
#      },
#      health_check: {
#        supports_registry_checks: true,
#        auth_check_supported: true,
#        lightweight: true
#      },
#      identity: {
#        bot_usernames: ["claude", "anthropic"]
#      }
#    }
```

To enumerate the full catalog:

```ruby
AgentHarness.provider_metadata_catalog
# => { claude: {...}, cursor: {...}, gemini: {...}, ... }
```

Provider metadata is cached so repeated catalog reads stay cheap.
Pass `refresh: true` to rebuild metadata and re-run live availability checks when needed:

```ruby
AgentHarness.provider_metadata(:anthropic, refresh: true)
AgentHarness.provider_metadata_catalog(refresh: true)
```

For providers with install contracts, the metadata tracks the CLI version
supported by the current `agent-harness` release, and the runtime adapter
tests assert that the expected binary remains aligned with that contract.
`runtime[:installation]` is normalized to a stable shape with
`source_type`, `package_name`, version fields, and install commands so
downstream apps do not need provider-specific branching.

### Runner Model Compatibility

Downstream orchestrators that map tiers or task requirements to concrete
models should consult the runner/model compatibility contract before
scheduling a run. The contract surfaces the runtime dimensions that
materially affect whether a model will run — runner identity, model id,
auth mode, and installed CLI version — and returns a structured result
instead of forcing callers to parse error strings:

```ruby
result = AgentHarness.model_compatibility(
  runner: :codex,
  model_id: "gpt-5.5",
  auth_mode: :subscription,
  cli_version: "0.115.0"
)

result.supported?            # => false
result.reason                # => :cli_version_too_old
result.minimum_cli_version   # => "0.116.0"
result.fallback_model_id     # => "gpt-5.2-codex"
result.source                # => :static_contract
```

Outcomes follow three explicit shapes:

- **Supported** — `result.supported?` is `true`. The runner contract
  confirms the model can be driven under the given constraints.
- **Unsupported** — `result.unsupported?` is `true` with a stable
  symbolic `reason` such as `:cli_version_too_old` or
  `:auth_mode_not_supported`, plus any version requirement and a
  contract-owned `fallback_model_id` to use instead.
- **Unknown** — `result.unknown?` is `true`. The runner cannot answer
  definitively — either the model is not in the runner's static
  contract (`reason: :unknown_model`), or the model is CLI-gated and the
  caller did not supply a comparable `cli_version`
  (`reason: :cli_version_unknown`, with `minimum_cli_version` attached).
  Callers must treat unknown as "ask the provider" — never as implicit
  approval — so a missing CLI version cannot silently schedule a run
  onto an older CLI that the model does not support.

Providers that have not opted in to a static contract return an unknown
result by default, so callers always get a normalized
`AgentHarness::ModelCompatibility::Result` without provider-specific
branching. The Codex runner ships static facts for CLI-gated models
(for example `gpt-5.5` requires Codex CLI `>= 0.116.0`) and a baseline
list of always-supported models.

### Custom Providers

```ruby
class MyProvider < AgentHarness::Providers::Base
  class << self
    def provider_name
      :my_provider
    end

    def binary_name
      "my-cli"
    end

    def install_contract(version: "1.2.3")
      {
        provider: provider_name,
        source_type: :npm,
        package_name: "@acme/my-cli",
        supported_version_requirement: Gem::Requirement.new("~> 1.2"),
        default_version: "1.2.3",
        resolved_version: version,
        binary_name: binary_name,
        install_command: ["npm", "install", "-g", "@acme/my-cli@#{version}"]
      }
    end

    def available?
      system("which my-cli > /dev/null 2>&1")
    end
  end

  protected

  def build_command(prompt, options)
    [self.class.binary_name, "--prompt", prompt]
  end

  def parse_response(result, duration:)
    AgentHarness::Response.new(
      output: result.stdout,
      exit_code: result.exit_code,
      provider: self.class.provider_name,
      duration: duration
    )
  end
end

# Register the custom provider
AgentHarness::Providers::Registry.instance.register(:my_provider, MyProvider)
```

## Orchestration

### Circuit Breaker

Prevents cascading failures by stopping requests to unhealthy providers:

```ruby
# After 5 consecutive failures, the circuit opens for 5 minutes
config.orchestration.circuit_breaker.failure_threshold = 5
config.orchestration.circuit_breaker.timeout = 300
```

### Rate Limiting

Track and respect provider rate limits:

```ruby
manager = AgentHarness.conductor.provider_manager

# Mark a provider as rate limited
manager.mark_rate_limited(:claude, reset_at: Time.now + 3600)

# Check rate limit status
manager.rate_limited?(:claude)
```

### Health Monitoring

Monitor provider health and automatically switch on failures:

```ruby
manager = AgentHarness.conductor.provider_manager

# Record success/failure
manager.record_success(:claude)
manager.record_failure(:claude)

# Check health
manager.healthy?(:claude)

# Get available providers
manager.available_providers
```

### Token Tracking

```ruby
# Track tokens across requests
AgentHarness.token_tracker.on_tokens_used do |event|
  puts "Provider: #{event.provider}"
  puts "Input tokens: #{event.input_tokens}"
  puts "Output tokens: #{event.output_tokens}"
  puts "Total: #{event.total_tokens}"
end

# Get usage summary
AgentHarness.token_tracker.summary
```

## Error Handling

```ruby
begin
  response = AgentHarness.send_message("Hello")
rescue AgentHarness::AuthenticationError => e
  puts "Auth failed for provider: #{e.provider}"
  # Optionally trigger re-auth flow (see Authentication Management below)
rescue AgentHarness::TimeoutError => e
  puts "Request timed out"
rescue AgentHarness::RateLimitError => e
  puts "Rate limited, retry after: #{e.reset_time}"
rescue AgentHarness::NoProvidersAvailableError => e
  puts "All providers unavailable: #{e.attempted_providers}"
rescue AgentHarness::Error => e
  puts "Provider error: #{e.message}"
end
```

### Error Taxonomy

Classify errors for consistent handling:

```ruby
category = AgentHarness::ErrorTaxonomy.classify_message("rate limit exceeded")
# => :rate_limited

AgentHarness::ErrorTaxonomy.retryable?(category)
# => false (rate limits should switch provider, not retry)

AgentHarness::ErrorTaxonomy.action_for(category)
# => :switch_provider
```

## Authentication Management

AgentHarness can detect authentication failures and manage credentials for CLI agents.

### Auth Type

Providers declare their authentication type:

```ruby
provider = AgentHarness.provider(:claude)
provider.auth_type
# => :oauth  (token-based auth that can expire)

provider = AgentHarness.provider(:aider)
provider.auth_type
# => :api_key  (static API key, no refresh needed)
```

### Auth Status Check

Pre-flight check auth before starting a run:

```ruby
AgentHarness.auth_valid?(:claude)
# => true/false

AgentHarness.auth_status(:claude)
# => { valid: false, expires_at: <Time>, error: "Session expired" }
```

For providers without a built-in auth check (including `:api_key` providers), `auth_valid?` returns `false` and `auth_status` returns an error indicating the check is not implemented. Custom providers can implement an `auth_status` instance method to provide their own check.

### Auth Flow Capabilities

Before rendering provider-specific auth controls, check whether the flow is supported:

```ruby
AgentHarness.auth_url_supported?(:claude)
# => true

AgentHarness.auth_url_supported?(:codex)
# => false

AgentHarness.refresh_auth_supported?(:claude)
# => true

AgentHarness.refresh_auth_supported?(:codex)
# => false

AgentHarness.auth_capabilities(:codex)
# => { auth_type: :api_key, auth_url: false, refresh: false }
```

Provider aliases are resolved the same way as other auth APIs, so `:anthropic` reports the same capabilities as `:claude`. Unknown providers raise `AgentHarness::ProviderNotFoundError`, matching `auth_url` and `refresh_auth` provider lookup behavior.

### Auth Error Detection

When a CLI agent fails due to expired or invalid authentication, `send_message` raises `AuthenticationError` with the provider name. Authentication errors are always surfaced directly to the caller (never auto-switched to another provider) so your application can trigger the appropriate re-auth flow:

```ruby
begin
  AgentHarness.send_message("Hello", provider: :claude)
rescue AgentHarness::AuthenticationError => e
  provider = e.provider

  if AgentHarness.auth_url_supported?(provider)
    redirect_to AgentHarness.auth_url(provider)
  elsif AgentHarness.refresh_auth_supported?(provider)
    render :reauth_token_form, locals: { provider: provider }
  else
    render :auth_expired_without_refresh, locals: { provider: provider, message: e.message }
  end
end
```

### OAuth URL Generation

For OAuth providers, get the URL the user should visit to start the login flow:

```ruby
AgentHarness.auth_url(:claude)
# => "https://claude.ai/oauth/authorize"
```

This raises `AgentHarness::UnsupportedAuthFlowError` for `:api_key` providers or providers whose OAuth URL flow is not implemented. The exception inherits from `AgentHarness::Error` and `StandardError`, so host applications can rescue it with their normal app-level error handling.

### Credential Refresh

Accept a pre-exchanged OAuth token and update the provider's stored credentials. The OAuth authorization code exchange is provider-specific and should be handled by your application or CLI login command before calling this method:

```ruby
AgentHarness.refresh_auth(:claude, token: "new-oauth-token")
# => { success: true }
```

Any existing expiry metadata in the credentials file is cleared on refresh so that `auth_valid?` returns `true` immediately after a successful refresh.

This raises `AgentHarness::UnsupportedAuthFlowError` for `:api_key` providers or providers whose credential refresh flow is not implemented. Credential file paths respect the `CLAUDE_CONFIG_DIR` environment variable.

If you currently rescue `NotImplementedError` for unsupported auth URL generation or credential refresh, update that code to rescue `AgentHarness::UnsupportedAuthFlowError` or the broader `AgentHarness::Error` instead.

## Provider Health Checks

Pre-flight check that configured providers are registered and authenticated. Reachability and configuration validation depend on provider-specific `health_status` and `validate_config` overrides; providers that don't implement these use safe defaults (healthy / valid).

> **Note:** These methods provide the library-level API. CLI flag (`--check-providers`) and HTTP endpoint (`GET /providers/status`) integration are not yet implemented and are tracked separately.

```ruby
# Check all enabled providers
results = AgentHarness.check_providers
results.each do |r|
  puts "#{r[:name]}: #{r[:status]} - #{r[:message]} (#{r[:latency_ms]}ms)"
end

# Check a single provider
result = AgentHarness.check_provider(:claude)
puts result[:status]  # => "ok", "degraded", or "error"

# Formatted CLI output
puts AgentHarness::ProviderHealthCheck.format_results(results)
```

Each result is a hash with keys:

- `:name` — provider name (Symbol)
- `:status` — `"ok"` (all checks passed), `"degraded"` (partial issues such as unimplemented auth status), or `"error"` (provider unavailable or authentication failed)
- `:message` — human-readable description
- `:latency_ms` — time taken for the check in milliseconds

Health checks run five steps per provider: registration, CLI availability, authentication, provider health status, and configuration validation. The default timeout per provider is configurable via `orchestration.health_check.timeout` (default: 5 seconds).

## Development

```bash
# Install dependencies
bin/setup

# Run tests
bundle exec rake spec

# Run linter
bundle exec standardrb

# Interactive console
bin/console
```

## License

MIT License. See [LICENSE.txt](LICENSE.txt).
