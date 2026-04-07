# AgentHarness

A unified Ruby interface for CLI-based AI coding agents like Claude Code, Cursor, Gemini CLI, GitHub Copilot, and more.

## Features

- **Unified Interface**: Single API for multiple AI coding agents
- **8 Built-in Providers**: Claude Code, Cursor, Gemini CLI, GitHub Copilot, Codex, Aider, OpenCode, Kilocode
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
| `:aider` | `aider` | Aider coding assistant |
| `:opencode` | `opencode` | OpenCode CLI |
| `:kilocode` | `kilo` | Kilocode CLI |

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

### Direct Provider Access

```ruby
# Get a provider instance
provider = AgentHarness.provider(:claude)
response = provider.send_message(prompt: "Hello!")

# Check provider availability
if AgentHarness::Providers::Registry.instance.get(:claude).available?
  puts "Claude CLI is installed"
end

# List all registered providers
AgentHarness::Providers::Registry.instance.all
# => [:claude, :cursor, :gemini, :github_copilot, :codex, :opencode, :kilocode, :aider]
```

### Provider Installation Contracts

Downstream apps can ask `agent-harness` for provider-specific CLI install
metadata instead of hardcoding package names, binary names, or supported
versions out-of-band.

```ruby
contract = AgentHarness.provider_installation_contract(:kilocode, version: "7.1.3")

contract
# {
#   source: { type: :npm, package: "@kilocode/cli" },
#   install_command: ["npm", "install", "-g", "--ignore-scripts", "@kilocode/cli@7.1.3"],
#   binary_name: "kilo",
#   default_version: "7.1.3",
#   supported_version_requirement: "= 7.1.3"
# }
```

The Kilocode runtime adapter expects the `kilo` binary and executes prompts via
`kilo run ...`, so the install contract and runtime behavior stay aligned in
tests.

Providers that expose installation contracts can also be queried through the
generic API:

```ruby
opencode_install = AgentHarness.installation_contract(:opencode)

opencode_install
# => {
#      source: :npm,
#      package_name: "opencode-ai",
#      version: "1.3.2",
#      version_requirement: [">= 1.3.2", "< 1.4.0"],
#      binary_name: "opencode",
#      install_command: ["npm", "install", "-g", "--ignore-scripts", "opencode-ai@1.3.2"]
#    }
```

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

### Auth Error Detection

When a CLI agent fails due to expired or invalid authentication, `send_message` raises `AuthenticationError` with the provider name. Authentication errors are always surfaced directly to the caller (never auto-switched to another provider) so your application can trigger the appropriate re-auth flow:

```ruby
begin
  AgentHarness.send_message("Hello", provider: :claude)
rescue AgentHarness::AuthenticationError => e
  puts e.provider  # => :claude
  puts e.message   # => "oauth token expired"
  # Trigger re-authentication flow for the specific provider
end
```

### OAuth URL Generation

For OAuth providers, get the URL the user should visit to start the login flow:

```ruby
AgentHarness.auth_url(:claude)
# => "https://claude.ai/oauth/authorize"
```

This raises `NotImplementedError` for `:api_key` providers.

### Credential Refresh

Accept a pre-exchanged OAuth token and update the provider's stored credentials. The OAuth authorization code exchange is provider-specific and should be handled by your application or CLI login command before calling this method:

```ruby
AgentHarness.refresh_auth(:claude, token: "new-oauth-token")
# => { success: true }
```

Any existing expiry metadata in the credentials file is cleared on refresh so that `auth_valid?` returns `true` immediately after a successful refresh.

This raises `NotImplementedError` for `:api_key` providers. Credential file paths respect the `CLAUDE_CONFIG_DIR` environment variable.

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
