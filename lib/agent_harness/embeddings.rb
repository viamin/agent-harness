# frozen_string_literal: true

require "ruby_llm"

module AgentHarness
  # Provider-neutral embedding execution backed by RubyLLM.
  class Embeddings
    DEFAULT_TIMEOUT = 300
    DEFAULT_MAX_ATTEMPTS = 3

    def initialize(model:, credentials:, endpoint: nil, headers: {}, timeout: DEFAULT_TIMEOUT,
      max_attempts: DEFAULT_MAX_ATTEMPTS, cancellation: nil)
      @model = model
      @api_key = credential(credentials, :api_key)
      @endpoint = endpoint
      @headers = headers.to_h.transform_keys(&:to_s).freeze
      @timeout = timeout
      @max_attempts = max_attempts
      @cancellation = cancellation
      validate!
    end

    def call(inputs:, dimensions: nil)
      inputs = Array(inputs)
      return EmbeddingResult.new(vectors: [], model: @model) if inputs.empty?

      embedding = context.embed(
        inputs,
        model: @model,
        provider: :openai,
        assume_model_exists: true,
        dimensions: dimensions
      )
      validate_result!(embedding.vectors, inputs.length)
      EmbeddingResult.new(vectors: embedding.vectors, model: embedding.model, input_tokens: embedding.tokens.input)
    rescue RubyLLM::UnauthorizedError, RubyLLM::ForbiddenError => e
      raise AuthenticationError.new(e.message, provider: :openai, original_error: e)
    rescue RubyLLM::RateLimitError => e
      raise RateLimitError.new(e.message, provider: :openai, reset_time: retry_after(e), original_error: e)
    rescue Faraday::TimeoutError, Timeout::Error => e
      raise TimeoutError.new(e.message, original_error: e)
    rescue Faraday::ConnectionFailed => e
      raise connection_error(e)
    rescue RubyLLM::ServerError, RubyLLM::ServiceUnavailableError, RubyLLM::OverloadedError => e
      raise ProviderError.new(e.message, original_error: e)
    rescue Faraday::ParsingError, NoMethodError, TypeError => e
      raise MalformedEmbeddingError.new("Malformed embedding response", original_error: e)
    end

    private

    def context
      RubyLLM.context do |config|
        config.openai_api_key = @api_key
        config.openai_api_base = @endpoint if @endpoint
        config.request_timeout = @timeout
        config.max_retries = @max_attempts - 1
        config.retry_interval_randomness = 0
        config.faraday_adapter = EmbeddingAdapter.build(headers: @headers, cancellation: @cancellation)
      end
    end

    def validate_result!(vectors, expected_count)
      valid = vectors.is_a?(Array) && vectors.length == expected_count
      valid &&= vectors.all? { |vector| valid_vector?(vector) }
      raise MalformedEmbeddingError, "Provider returned an invalid embedding batch" unless valid
    end

    def valid_vector?(vector)
      vector.is_a?(Array) && !vector.empty? && vector.all? { |value| value.is_a?(Numeric) && value.finite? }
    end

    def credential(credentials, key)
      return credentials if credentials.is_a?(String)

      credentials&.[](key) || credentials&.[](key.to_s)
    end

    def validate!
      raise ArgumentError, "model must be a non-empty string" unless @model.is_a?(String) && !@model.empty?
      raise ArgumentError, "credentials must include api_key" unless @api_key.is_a?(String) && !@api_key.empty?
      if @headers.keys.any? { |header| header.casecmp?("authorization") }
        raise ArgumentError, "headers cannot override Authorization; use credentials"
      end
      raise ArgumentError, "timeout must be positive" unless @timeout.is_a?(Numeric) && @timeout.positive?
      unless @max_attempts.is_a?(Integer) && @max_attempts.positive?
        raise ArgumentError, "max_attempts must be a positive integer"
      end
    end

    def retry_after(error)
      value = error.response&.response_headers&.[]("retry-after")
      value && Float(value)
    rescue ArgumentError
      nil
    end

    def connection_error(error)
      wrapped = error.wrapped_exception
      if wrapped.is_a?(Timeout::Error)
        TimeoutError.new(error.message, original_error: error)
      else
        ProviderError.new(error.message, original_error: error)
      end
    end
  end
end
