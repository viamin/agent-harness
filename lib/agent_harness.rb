# frozen_string_literal: true

require_relative "agent_harness/version"

# AgentHarness provides a unified interface for CLI-based AI coding agents.
#
# It offers:
# - Unified interface for multiple AI coding agents (Claude Code, Cursor, Gemini CLI, etc.)
# - Full orchestration layer with provider switching, circuit breakers, and health monitoring
# - Flexible configuration via YAML, Ruby DSL, or environment variables
# - Dynamic provider registration for custom provider support
# - Token usage tracking for cost and limit calculations
#
# @example Basic usage
#   AgentHarness.send_message("Write a hello world function", provider: :claude)
#
# @example With configuration
#   AgentHarness.configure do |config|
#     config.logger = Logger.new(STDOUT)
#     config.default_provider = :cursor
#   end
#
# @example Direct provider access
#   provider = AgentHarness.provider(:claude)
#   provider.send_message(prompt: "Hello")
#
module AgentHarness
  class Error < StandardError; end

  class << self
    # Returns the global configuration instance
    # @return [Configuration] the configuration object
    def configuration
      @configuration ||= Configuration.new
    end

    # Configure AgentHarness with a block
    # @yield [Configuration] the configuration object
    # @return [void]
    def configure
      yield(configuration) if block_given?
    end

    # Reset configuration to defaults (useful for testing)
    # @return [void]
    def reset!
      @configuration = nil
      @conductor = nil
      @token_tracker = nil
    end

    # Returns the global logger
    # @return [Logger, nil] the configured logger
    def logger
      configuration.logger
    end

    # Returns the global token tracker
    # @return [TokenTracker] the token tracker instance
    def token_tracker
      @token_tracker ||= TokenTracker.new
    end

    # Returns the global conductor for orchestrated requests
    # @return [Orchestration::Conductor] the conductor instance
    def conductor
      @conductor ||= Orchestration::Conductor.new(config: configuration)
    end

    # Send a message using the orchestration layer
    # @param prompt [String] the prompt to send
    # @param provider [Symbol, nil] optional provider override
    # @param options [Hash] additional options
    # @return [Response] the response from the provider
    def send_message(prompt, provider: nil, **options)
      conductor.send_message(prompt, provider: provider, **options)
    end

    # Get a provider instance
    # @param name [Symbol] the provider name
    # @return [Providers::Base] the provider instance
    def provider(name)
      conductor.provider_manager.get_provider(name)
    end
  end
end

# Core components
require_relative "agent_harness/errors"
require_relative "agent_harness/configuration"
require_relative "agent_harness/command_executor"
require_relative "agent_harness/response"
require_relative "agent_harness/token_tracker"
require_relative "agent_harness/error_taxonomy"

# Provider layer
require_relative "agent_harness/providers/registry"
require_relative "agent_harness/providers/adapter"
require_relative "agent_harness/providers/base"
require_relative "agent_harness/providers/anthropic"
require_relative "agent_harness/providers/aider"
require_relative "agent_harness/providers/codex"
require_relative "agent_harness/providers/cursor"
require_relative "agent_harness/providers/gemini"
require_relative "agent_harness/providers/github_copilot"
require_relative "agent_harness/providers/kilocode"
require_relative "agent_harness/providers/opencode"

# Orchestration layer
require_relative "agent_harness/orchestration/circuit_breaker"
require_relative "agent_harness/orchestration/rate_limiter"
require_relative "agent_harness/orchestration/health_monitor"
require_relative "agent_harness/orchestration/metrics"
require_relative "agent_harness/orchestration/provider_manager"
require_relative "agent_harness/orchestration/conductor"
