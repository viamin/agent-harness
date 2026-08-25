# frozen_string_literal: true

module AgentHarness
  # Base error class for all AgentHarness errors
  class Error < StandardError
    attr_reader :original_error, :context

    def initialize(message = nil, original_error: nil, context: {})
      @original_error = original_error
      @context = context
      super(message)
    end
  end

  # Provider-related errors
  class ProviderError < Error; end

  class ProviderInstallationError < ProviderError
    attr_reader :provider, :error_category

    def initialize(message = nil, provider: nil, error_category: :installation, **kwargs)
      @provider = provider
      @error_category = error_category
      super(message, **kwargs)
    end
  end

  class ProviderNotFoundError < ProviderError; end

  class ProviderUnavailableError < ProviderError; end

  # Execution errors
  class TimeoutError < Error; end

  # Raised when a duration argument is invalid (non-positive)
  class InvalidDurationError < ArgumentError; end

  class IdleTimeoutError < TimeoutError; end

  class CommandExecutionError < Error; end

  # Rate limiting and circuit breaker errors
  class RateLimitError < Error
    attr_reader :reset_time, :provider, :error_category

    def initialize(message = nil, reset_time: nil, provider: nil, error_category: :rate_limited, **kwargs)
      @reset_time = reset_time
      @provider = provider
      @error_category = error_category
      super(message, **kwargs)
    end
  end

  class CircuitOpenError < Error
    attr_reader :provider

    def initialize(message = nil, provider: nil, **kwargs)
      @provider = provider
      super(message, **kwargs)
    end
  end

  # Authentication errors
  class AuthenticationError < Error
    attr_reader :provider

    def initialize(message = nil, provider: nil, **kwargs)
      @provider = provider
      super(message, **kwargs)
    end
  end

  # Auth mismatch errors — raised when the requested transport mode
  # requires credentials that differ from the caller's current auth mode.
  # For example, requesting HTTP text mode with only OAuth/subscription
  # credentials (no API key) would silently shift billing from
  # subscription to API-metered usage.
  class AuthMismatchError < AuthenticationError; end

  # Raised when a provider does not support the requested authentication flow.
  class UnsupportedAuthFlowError < Error; end

  # Configuration errors
  class ConfigurationError < Error; end

  class ExtensionCompatibilityError < ConfigurationError
    attr_reader :provider, :extension, :report

    def initialize(message = nil, provider: nil, extension: nil, report: nil, **kwargs)
      @provider = provider
      @extension = extension
      @report = report
      super(message, **kwargs)
    end
  end

  # MCP-specific errors
  class McpConfigurationError < ConfigurationError; end

  class McpUnsupportedError < ProviderError
    attr_reader :provider

    def initialize(message = nil, provider: nil, **kwargs)
      @provider = provider
      super(message, **kwargs)
    end
  end

  class McpTransportUnsupportedError < McpUnsupportedError; end

  # Orchestration errors
  class NoProvidersAvailableError < Error
    attr_reader :attempted_providers, :errors

    def initialize(message = nil, attempted_providers: [], errors: {}, **kwargs)
      @attempted_providers = attempted_providers
      @errors = errors
      super(message, **kwargs)
    end
  end
end
