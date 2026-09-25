# frozen_string_literal: true

require "ruby_llm"
require "securerandom"
require "time"

module AgentHarness
  # Provider-neutral embedding execution backed by RubyLLM.
  class Embeddings
    DEFAULT_TIMEOUT = 300
    DEFAULT_MAX_ATTEMPTS = 3
    RETRY_BASE_DELAY = 0.25
    RETRY_MAX_DELAY = 2.0
    CANCELLATION_POLL_INTERVAL = 0.05
    TRANSIENT_ERRORS = [RateLimitError, TimeoutError].freeze

    def initialize(model:, credentials:, endpoint: nil, headers: {}, timeout: DEFAULT_TIMEOUT,
      max_attempts: DEFAULT_MAX_ATTEMPTS, cancellation: nil, observer: nil, request_id: nil)
      @model = model
      @api_key = credential(credentials, :api_key)
      @endpoint = endpoint
      @headers = headers.to_h.transform_keys(&:to_s).freeze
      @timeout = timeout
      @max_attempts = max_attempts
      @cancellation = cancellation
      @observer = observer
      @request_id = request_id || SecureRandom.uuid
      validate!
    end

    def call(inputs:, dimensions: nil)
      inputs = Array(inputs)
      return EmbeddingResult.new(vectors: [], model: @model) if inputs.empty?

      execute(inputs, dimensions)
    end

    private

    def execute(inputs, dimensions)
      attempts = []

      1.upto(@max_attempts) do |number|
        check_cancellation!
        result = attempt(inputs, dimensions, number, attempts)
        check_cancellation!
        return result
      rescue RateLimitError, TimeoutError, ProviderError => e
        raise unless retryable?(e) && number < @max_attempts

        wait_before_retry(e, number)
      end
    end

    def attempt(inputs, dimensions, number, attempts)
      started_at = Time.now.utc
      embedding = request_embedding(inputs, dimensions)
      validate_result!(embedding.vectors, inputs.length)
      report = success_report(embedding, number, started_at)
    rescue CancelledError => e
      record_attempt(attempts, failure_report(e, number, started_at, :cancelled, :cancelled))
      raise
    rescue AuthenticationError, AuthorizationError, RateLimitError, TimeoutError, ProviderError => e
      record_attempt(attempts, failure_report(e, number, started_at, *error_classification(e)))
      raise
    rescue NoMethodError, TypeError => e
      error = MalformedEmbeddingError.new("Malformed embedding response", original_error: e)
      record_attempt(attempts, failure_report(error, number, started_at, *error_classification(error)))
      raise error
    else
      record_attempt(attempts, report)
      EmbeddingResult.new(
        vectors: embedding.vectors, model: embedding.model,
        input_tokens: embedding.tokens.input, attempts: attempts
      )
    end

    def request_embedding(inputs, dimensions)
      context.embed(
        inputs,
        model: @model,
        provider: :openai,
        assume_model_exists: true,
        dimensions: dimensions
      )
    rescue RubyLLM::UnauthorizedError => e
      raise AuthenticationError.new(e.message, provider: :openai, original_error: e)
    rescue RubyLLM::ForbiddenError => e
      raise AuthorizationError.new(e.message, provider: :openai, original_error: e)
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
    rescue RubyLLM::Error => e
      raise ProviderError.new(e.message, original_error: e)
    end

    def context
      RubyLLM.context do |config|
        config.openai_api_key = @api_key
        config.openai_api_base = @endpoint if @endpoint
        config.request_timeout = @timeout
        config.max_retries = 0
        config.retry_interval_randomness = 0
        config.faraday_adapter = EmbeddingAdapter.build(headers: @headers, cancellation: @cancellation)
      end
    end

    def success_report(embedding, number, started_at)
      attempt_report(number, started_at).merge(
        status: :succeeded,
        model: embedding.model,
        usage: usage(embedding.tokens.input),
        provider_reported: !embedding.tokens.input.nil?,
        error: nil
      ).freeze
    end

    def failure_report(error, number, started_at, category, code)
      attempt_report(number, started_at).merge(
        status: (category == :cancelled) ? :cancelled : :failed,
        usage: usage(nil),
        provider_reported: false,
        error: {category: category, code: code}.freeze
      ).freeze
    end

    def attempt_report(number, started_at)
      {
        attempt_id: "attempt_#{SecureRandom.uuid}", request_id: @request_id,
        number: number, provider: :openai, model: @model,
        started_at: started_at.iso8601(6), finished_at: Time.now.utc.iso8601(6),
        cost: nil, provider_request_id: nil
      }
    end

    def usage(input_tokens)
      {input_tokens: input_tokens, output_tokens: nil, total_tokens: input_tokens}.freeze
    end

    def record_attempt(attempts, report)
      attempts << report
      return unless @observer

      @observer.respond_to?(:on_attempt) ? @observer.on_attempt(report) : @observer.call(report)
    end

    def error_classification(error)
      return [error.error_category, error.error_code] if error.is_a?(AuthenticationError) || error.is_a?(AuthorizationError)
      return [:transient, :rate_limited] if error.is_a?(RateLimitError)
      return [:transient, :timeout] if error.is_a?(TimeoutError)
      return transient_provider_classification(error) if transient_provider_error?(error)
      return [:invalid_response, :malformed_response] if error.is_a?(MalformedEmbeddingError)

      [:unknown, :unclassified_provider_error]
    end

    def transient_provider_classification(error)
      original = error.original_error
      return [:transient, :connection_failed] if original.is_a?(Faraday::ConnectionFailed)
      return [:transient, :service_unavailable] if original.is_a?(RubyLLM::ServiceUnavailableError)
      return [:transient, :overloaded] if original.is_a?(RubyLLM::OverloadedError)

      [:transient, :server_error]
    end

    def retryable?(error)
      TRANSIENT_ERRORS.any? { |klass| error.is_a?(klass) } || transient_provider_error?(error)
    end

    def transient_provider_error?(error)
      original = error.original_error
      original.is_a?(Faraday::ConnectionFailed) || original.is_a?(RubyLLM::ServerError) ||
        original.is_a?(RubyLLM::ServiceUnavailableError) || original.is_a?(RubyLLM::OverloadedError)
    end

    def wait_before_retry(error, attempt_number)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + retry_delay(error, attempt_number)
      loop do
        check_cancellation!
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break unless remaining.positive?

        sleep([remaining, CANCELLATION_POLL_INTERVAL].min)
      end
    end

    def retry_delay(error, attempt_number)
      retry_after_delay = error.reset_time - Time.now if error.is_a?(RateLimitError) && error.reset_time
      return [retry_after_delay, RETRY_MAX_DELAY].min if retry_after_delay&.positive?

      [RETRY_BASE_DELAY * (2**(attempt_number - 1)), RETRY_MAX_DELAY].min
    end

    def check_cancellation!
      raise CancelledError, "Embedding request cancelled" if @cancellation&.call
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
      unless @request_id.is_a?(String) && !@request_id.empty?
        raise ArgumentError, "request_id must be a non-empty string"
      end
      unless @observer.nil? || @observer.respond_to?(:on_attempt) || @observer.respond_to?(:call)
        raise ArgumentError, "observer must respond to on_attempt or call"
      end
    end

    def retry_after(error)
      value = error.response&.response_headers&.[]("retry-after")
      return unless value

      seconds = Float(value, exception: false)
      seconds ? Time.now + seconds : Time.httpdate(value)
    rescue ArgumentError, TypeError
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
