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
    # @param executor [CommandExecutor, nil] per-request executor override
    # @param options [Hash] additional options
    # @return [Response] the response from the provider
    def send_message(prompt, provider: nil, executor: nil, **options)
      conductor.send_message(prompt, provider: provider, executor: executor, **options)
    end

    # Get a provider instance
    # @param name [Symbol] the provider name
    # @return [Providers::Base] the provider instance
    def provider(name)
      conductor.provider_manager.get_provider(name)
    end

    # Get install contract metadata for a provider
    # @param name [Symbol, String] the provider name
    # @return [Hash] install contract metadata
    # @raise [ConfigurationError] if the provider does not expose an install contract
    def install_contract(name)
      Providers::Registry.instance.install_contract(name)
    end

    # Returns install metadata for a provider CLI when the provider exposes it.
    #
    # @param provider_name [Symbol, String] the provider name
    # @param version [String, nil] optional explicit CLI version override
    # @return [Hash, nil] installation metadata
    def provider_install_contract(provider_name, version: nil)
      provider_installation_contract(provider_name, **(version ? {version: version} : {}))
    end

    # Get the installation contract for a provider CLI.
    #
    # @param name [Symbol, String] the provider name
    # @param options [Hash] optional target selection (for example, `version:`)
    # @return [Hash, nil] provider installation contract for the requested target
    # @raise [ConfigurationError] if provider not found
    def provider_installation_contract(name, **options)
      Providers::Registry.instance.installation_contract(name, **options)
    end

    # Get installation metadata for a provider CLI.
    # @param provider_name [Symbol, String] the provider name
    # @param options [Hash] optional target selection (for example, `version:`)
    # @return [Hash, nil] installation contract
    # @raise [ConfigurationError] if the provider name is not registered
    def installation_contract(provider_name, **options)
      Providers::Registry.instance.installation_contract(provider_name, **options)
    end

    # Get all provider installation contracts exposed by agent-harness.
    # @return [Hash<Symbol, Hash>] installation contracts keyed by provider
    def installation_contracts
      Providers::Registry.instance.installation_contracts
    end

    # Get consolidated metadata for a provider.
    #
    # @param provider_name [Symbol, String] the provider name or alias
    # @param refresh [Boolean] when true, refresh live runtime metadata such as
    #   CLI availability instead of reusing cached values
    # @return [Hash] provider metadata
    # @raise [ConfigurationError] if the provider name is not registered
    def provider_metadata(provider_name, refresh: false)
      Providers::Registry.instance.provider_metadata(provider_name, refresh: refresh)
    end

    # Get consolidated metadata for all registered providers.
    #
    # @param refresh [Boolean] when true, refresh live runtime metadata such as
    #   CLI availability instead of reusing cached values
    # @return [Hash<Symbol, Hash>] provider metadata keyed by canonical provider
    def provider_metadata_catalog(refresh: false)
      Providers::Registry.instance.provider_metadata_catalog(refresh: refresh)
    end

    # Get smoke-test metadata for a provider CLI when the provider exposes it.
    #
    # @param provider_name [Symbol, String] the provider name
    # @return [Hash, nil] smoke-test contract
    def provider_smoke_test_contract(provider_name)
      smoke_test_contract(provider_name)
    end

    # Get smoke-test metadata for a provider CLI.
    # @param provider_name [Symbol, String] the provider name
    # @return [Hash, nil] smoke-test contract
    # @raise [ConfigurationError] if the provider name is not registered
    def smoke_test_contract(provider_name)
      # Explicitly raise if provider is not registered to match documentation
      raise ConfigurationError, "Unknown provider: #{provider_name}" unless Providers::Registry.instance.registered?(provider_name)
      Providers::Registry.instance.smoke_test_contract(provider_name)
    end

    # Get all provider smoke-test contracts exposed by agent-harness.
    # @return [Hash<Symbol, Hash>] smoke-test contracts keyed by provider
    def smoke_test_contracts
      Providers::Registry.instance.smoke_test_contracts
    end

    # Check if authentication is valid for a provider
    # @param provider_name [Symbol] the provider name
    # @return [Boolean] true if auth is valid
    def auth_valid?(provider_name)
      Authentication.auth_valid?(provider_name)
    end

    # Get detailed authentication status for a provider
    # @param provider_name [Symbol] the provider name
    # @return [Hash] status with :valid, :expires_at, :error keys
    def auth_status(provider_name)
      Authentication.auth_status(provider_name)
    end

    # Generate an OAuth URL for a provider
    # @param provider_name [Symbol] the provider name
    # @return [String] the OAuth authorization URL
    # @raise [NotImplementedError] if provider doesn't support OAuth
    def auth_url(provider_name)
      Authentication.auth_url(provider_name)
    end

    # Refresh authentication credentials for a provider
    # @param provider_name [Symbol] the provider name
    # @param token [String, nil] OAuth token to store
    # @return [Hash] result with :success key
    # @raise [NotImplementedError] if provider doesn't support credential refresh
    def refresh_auth(provider_name, token: nil)
      Authentication.refresh_auth(provider_name, token: token)
    end

    # Check health of all configured providers.
    #
    # Validates each enabled provider through registration, CLI availability,
    # authentication, provider health status, and config validation checks.
    #
    # @param timeout [Integer] timeout in seconds for each check (defaults to configured value)
    # @raise [ArgumentError] if provider_runtime is supplied; runtime overrides are
    #   only supported by `check_provider` to avoid leaking one provider's execution
    #   context into every other health check
    # @return [Array<Hash>] health status for each provider
    def check_providers(timeout: nil, executor: nil, provider_runtime: nil)
      raise ArgumentError, "provider_runtime is only supported for single-provider health checks" unless provider_runtime.nil?

      options = {}
      options[:timeout] = timeout unless timeout.nil?
      options[:executor] = executor unless executor.nil?
      ProviderHealthCheck.check_all(**options)
    end

    # Check health of a single provider
    # @param provider_name [Symbol] the provider name
    # @param timeout [Integer, nil] timeout in seconds (nil lets ProviderHealthCheck apply its validated default)
    # @return [Hash] health status with :name, :status, :message, :latency_ms
    def check_provider(provider_name, timeout: nil, executor: nil, provider_runtime: nil)
      options = {}
      options[:timeout] = timeout unless timeout.nil?
      options[:executor] = executor unless executor.nil?
      options[:provider_runtime] = provider_runtime unless provider_runtime.nil?
      ProviderHealthCheck.check(provider_name, **options)
    end
  end
end

# Core components
require_relative "agent_harness/errors"
require_relative "agent_harness/mcp_server"
require_relative "agent_harness/provider_runtime"
require_relative "agent_harness/execution_preparation"
require_relative "agent_harness/configuration"
require_relative "agent_harness/command_executor"
require_relative "agent_harness/docker_command_executor"
require_relative "agent_harness/response"
require_relative "agent_harness/token_tracker"
require_relative "agent_harness/error_taxonomy"
require_relative "agent_harness/authentication"
require_relative "agent_harness/provider_health_check"

# Provider layer
require_relative "agent_harness/providers/registry"
require_relative "agent_harness/providers/adapter"
require_relative "agent_harness/providers/base"
require_relative "agent_harness/providers/token_usage_parsing"
require_relative "agent_harness/providers/anthropic"
require_relative "agent_harness/providers/aider"
require_relative "agent_harness/providers/codex"
require_relative "agent_harness/providers/cursor"
require_relative "agent_harness/providers/gemini"
require_relative "agent_harness/providers/github_copilot"
require_relative "agent_harness/providers/kilocode"
require_relative "agent_harness/providers/mistral_vibe"
require_relative "agent_harness/providers/opencode"

# Orchestration layer
require_relative "agent_harness/orchestration/circuit_breaker"
require_relative "agent_harness/orchestration/rate_limiter"
require_relative "agent_harness/orchestration/health_monitor"
require_relative "agent_harness/orchestration/metrics"
require_relative "agent_harness/orchestration/provider_manager"
require_relative "agent_harness/orchestration/conductor"
