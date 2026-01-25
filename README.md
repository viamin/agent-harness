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
| `:cursor` | `cursor` | Cursor AI editor CLI |
| `:gemini` | `gemini` | Google Gemini CLI |
| `:github_copilot` | `gh copilot` | GitHub Copilot CLI |
| `:codex` | `codex` | OpenAI Codex CLI |
| `:aider` | `aider` | Aider coding assistant |
| `:opencode` | `opencode` | OpenCode CLI |
| `:kilocode` | `kilocode` | Kilocode CLI |

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
