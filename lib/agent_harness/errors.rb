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

  class ProviderNotFoundError < ProviderError; end

  class ProviderUnavailableError < ProviderError; end

  # Execution errors
  class TimeoutError < Error; end

  class CommandExecutionError < Error; end

  # Rate limiting and circuit breaker errors
  class RateLimitError < Error
    attr_reader :reset_time, :provider

    def initialize(message = nil, reset_time: nil, provider: nil, **kwargs)
      @reset_time = reset_time
      @provider = provider
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
  class AuthenticationError < Error; end

  # Configuration errors
  class ConfigurationError < Error; end

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
