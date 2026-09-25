# frozen_string_literal: true

require "securerandom"
require "ruby_llm"
require_relative "ruby_llm_chat_adapter"

module AgentHarness
  module Api
    # Executes one normalized chat response without running application tools.
    class ChatTransport
      RESERVED_HEADERS = {
        anthropic: %w[x-api-key anthropic-version],
        openai: %w[authorization]
      }.freeze
      PROTOCOLS = {
        anthropic: %i[messages],
        openai: %i[responses chat_completions]
      }.freeze
      DEFAULT_RETRY = {max_attempts: 1, base_delay_seconds: 0, max_delay_seconds: 0}.freeze

      # Raised when the caller's observer fails. Observer bugs stay outside
      # provider error classification, abort the in-flight request, and are
      # never re-invoked with a synthetic terminal event.
      class ObserverError < StandardError
      end

      def initialize(adapter: RubyLlmChatAdapter.new, id_generator: -> { SecureRandom.uuid }, sleeper: Kernel.method(:sleep))
        @adapter = adapter
        @id_generator = id_generator
        @sleeper = sleeper
      end

      def call(request, observer: nil, &on_event)
        execution = Execution.new(request, adapter: @adapter, id_generator: @id_generator,
          sleeper: @sleeper, observer: observer || on_event)
        execution.call
      end

      # Holds mutable state for exactly one request, keeping the transport reusable.
      class Execution
        def initialize(request, adapter:, id_generator:, sleeper:, observer:)
          @request = symbolize(request)
          @adapter = adapter
          @id_generator = id_generator
          @sleeper = sleeper
          @observer = observer
          @attempts = []
          @sequence = 0
          @partial_content = +""
          @stream_tool_calls = {}
          @tool_ids = {}
          validate!
        end

        def call
          return cancelled_result unless active?

          candidates.each_with_index do |candidate, candidate_index|
            result = attempt_candidate(candidate, candidate_index)
            return result if terminal?(result)
          end
          failed_result(@last_error, @last_candidate)
        end

        private

        attr_reader :request, :attempts

        def attempt_candidate(candidate, candidate_index)
          loop do
            return cancelled_result(candidate) unless active?
            return failed_result(@last_error, candidate) if attempts.length >= retry_config[:max_attempts]

            result = perform_attempt(candidate)
            return result if result[:status] == :succeeded || result[:status] == :partial
            return cancelled_result(candidate) unless active?

            @last_error = result[:error]
            @last_candidate = candidate
            return result if fallback_allowed?(result, candidate_index)
            return result unless retryable?(result)

            backoff
          end
        end

        def perform_attempt(candidate)
          attempt_id = @id_generator.call
          started_at = Time.now.utc
          emitted = false
          emit(:response_started, attempt_id:, candidate: candidate_identity(candidate))

          adapter_result = @adapter.call(
            candidate: candidate,
            messages: request[:messages],
            tools: request[:tools] || [],
            max_output_tokens: request[:max_output_tokens],
            temperature: request[:temperature],
            stream: request[:stream] == true,
            timeout: request[:timeout],
            cancellation: request[:cancellation]
          ) do |event|
            event = normalize_stream_event(event)
            emitted = true if output_event?(event)
            accumulate(event)
            emit(event.fetch(:type), attempt_id:, **event.except(:type))
          end
          raise RubyLLM::CancelledError unless active?

          success(candidate, attempt_id, started_at, adapter_result)
        rescue ObserverError
          raise
        rescue => error
          failure(candidate, attempt_id, started_at, classify(error), partial: emitted)
        end

        def success(candidate, attempt_id, started_at, adapter_result)
          attempts << attempt_report(candidate, attempt_id, started_at, :succeeded)
          result = base_result(candidate).merge(
            status: :succeeded,
            content: adapter_result[:content] || "",
            tool_calls: normalize_tool_calls(adapter_result[:tool_calls]),
            finish_reason: adapter_result[:finish_reason],
            usage: adapter_result[:usage],
            error: nil
          )
          emit(:response_completed, attempt_id:, result: result)
          result
        end

        def failure(candidate, attempt_id, started_at, error, partial:)
          status = failure_status(error, partial)
          attempts << attempt_report(candidate, attempt_id, started_at, status, error: error)
          result = base_result(candidate).merge(
            status: status,
            content: partial ? @partial_content.dup : "",
            tool_calls: partial_tool_calls,
            finish_reason: nil,
            usage: nil,
            error: error
          )
          emit((status == :cancelled) ? :response_cancelled : :response_failed, attempt_id:, result: result)
          result
        end

        def fallback_allowed?(result, candidate_index)
          return false if result[:status] == :partial
          return false unless fallback_categories.include?(result.dig(:error, :category))
          return false unless candidates[candidate_index + 1]

          true
        end

        def retryable?(result)
          result.dig(:error, :retryable) && attempts.length < retry_config[:max_attempts]
        end

        def terminal?(result)
          return true if %i[succeeded partial cancelled].include?(result[:status])
          return true unless fallback_categories.include?(result.dig(:error, :category))

          attempts.length >= retry_config[:max_attempts]
        end

        def backoff
          exponent = [attempts.length - 1, 0].max
          delay = retry_config[:base_delay_seconds] * (2**exponent)
          remaining = [delay, retry_config[:max_delay_seconds]].min
          while remaining.positive? && active?
            interval = [remaining, 0.05].min
            @sleeper.call(interval)
            remaining -= interval
          end
        end

        def emit(type, attempt_id:, **payload)
          @sequence += 1
          event = payload.merge(type: type, request_id: request[:request_id], attempt_id: attempt_id, sequence: @sequence)
          deliver(event) if @observer
        end

        # Observer exceptions are caller bugs, not provider failures: they
        # abort the in-flight request and surface directly instead of being
        # classified or retried as provider errors.
        def deliver(event)
          @observer.respond_to?(:on_chat_event) ? @observer.on_chat_event(event) : @observer.call(event)
        rescue => error
          raise ObserverError, "chat observer failed: #{error.class} #{error.message}", error.backtrace
        end

        def accumulate(event)
          @partial_content << event[:content].to_s if event[:type] == :text_delta
          return unless event[:id]

          call = (@stream_tool_calls[event[:id]] ||= {
            id: event[:id], provider_id: event[:provider_id], name: event[:name],
            arguments_json: +"", status: :incomplete
          })
          call[:arguments_json] << event[:arguments_json].to_s if event[:type] == :tool_call_delta
          if event[:type] == :tool_call_completed
            call[:arguments_json] = event[:arguments_json]
            call[:status] = :completed
          end
        end

        def output_event?(event)
          %i[text_delta tool_call_started tool_call_delta tool_call_completed].include?(event[:type])
        end

        def partial_tool_calls
          @stream_tool_calls.values.map(&:dup)
        end

        def normalize_tool_calls(tool_calls)
          Array(tool_calls).map do |call|
            call.merge(id: tool_id(call[:provider_id]), status: :completed)
          end
        end

        def normalize_stream_event(event)
          return event unless event[:provider_id]

          event.merge(id: tool_id(event[:provider_id]))
        end

        def tool_id(provider_id)
          @tool_ids[provider_id] ||= @id_generator.call
        end

        def base_result(candidate)
          {
            request_id: request[:request_id],
            provider: candidate&.dig(:provider),
            model: candidate&.dig(:model),
            protocol: candidate&.dig(:protocol),
            authentication_mode: candidate&.dig(:authentication_mode),
            parsed: nil,
            attempts: attempts.dup,
            provider_request_id: nil
          }
        end

        def failed_result(error, candidate)
          base_result(candidate).merge(status: :failed, content: "", tool_calls: [], finish_reason: nil,
            usage: nil, error: error)
        end

        def cancelled_result(candidate = candidates.first)
          error = {category: :cancelled, code: :cancelled, retryable: false, message: "Request cancelled"}
          base_result(candidate).merge(status: :cancelled, content: "", tool_calls: [], finish_reason: nil,
            usage: nil, error: error)
        end

        def attempt_report(candidate, attempt_id, started_at, status, error: nil)
          {
            attempt_id: attempt_id,
            request_id: request[:request_id],
            number: attempts.length + 1,
            provider: candidate[:provider],
            model: candidate[:model],
            status: status,
            started_at: started_at.iso8601(6),
            finished_at: Time.now.utc.iso8601(6),
            error: error
          }
        end

        def classify(error)
          ErrorClassifier.call(error)
        end

        def failure_status(error, partial)
          return :cancelled if error[:category] == :cancelled
          return :partial if partial

          :failed
        end

        def candidates = request[:candidates]
        def retry_config = @retry_config ||= DEFAULT_RETRY.merge(request[:retry] || {})
        def fallback_categories = Array(request.dig(:fallback, :on_error_categories)).map(&:to_sym)

        def active?
          token = request[:cancellation]
          return true unless token

          cancelled = token.respond_to?(:cancelled?) ? token.cancelled? : token.call
          !cancelled
        end

        def validate!
          raise ArgumentError, "operation must be :chat" unless request[:operation]&.to_sym == :chat
          raise ArgumentError, "request_id is required" if request[:request_id].to_s.empty?
          raise ArgumentError, "candidates must not be empty" if !request[:candidates].is_a?(Array) || request[:candidates].empty?
          raise ArgumentError, "messages must be an array" unless request[:messages].is_a?(Array)
          validate_attempt_limit!
          candidates.each { |candidate| validate_candidate!(candidate) }
        end

        def validate_attempt_limit!
          limit = retry_config[:max_attempts]
          raise ArgumentError, "retry.max_attempts must be a positive integer" unless limit.is_a?(Integer) && limit.positive?
        end

        def validate_candidate!(candidate)
          candidate.replace(symbolize(candidate))
          %i[provider model protocol authentication_mode credentials].each do |key|
            raise ArgumentError, "candidate.#{key} is required" if candidate[key].nil?
          end
          raise ArgumentError, "only api_key authentication is supported" unless candidate[:authentication_mode].to_sym == :api_key
          supported_protocols = PROTOCOLS[candidate[:provider].to_sym]
          unless supported_protocols&.include?(candidate[:protocol].to_sym)
            raise ArgumentError, "unsupported provider/protocol combination"
          end

          headers = candidate[:headers] || {}
          reserved_names = RESERVED_HEADERS.fetch(candidate[:provider].to_sym, RESERVED_HEADERS.values.flatten)
          reserved = headers.keys.map { |key| key.to_s.downcase } & reserved_names
          raise ArgumentError, "reserved header override: #{reserved.first}" if reserved.any?
        end

        def candidate_identity(candidate)
          candidate.slice(:provider, :model, :protocol, :authentication_mode)
        end

        def symbolize(value)
          if value.is_a?(Hash)
            return value.each_with_object({}) do |(key, child), normalized|
              symbol = key.to_sym
              normalized[symbol] = (symbol == :headers) ? child.dup : symbolize(child)
            end
          end
          return value.map { |child| symbolize(child) } if value.is_a?(Array)

          value
        end
      end
    end

    module ErrorClassifier
      TRANSIENT = {
        Faraday::TimeoutError => :timeout,
        Faraday::ConnectionFailed => :connection_failed,
        Faraday::SSLError => :connection_failed,
        RubyLLM::RateLimitError => :rate_limited,
        RubyLLM::ServerError => :server_error,
        RubyLLM::ServiceUnavailableError => :service_unavailable,
        RubyLLM::OverloadedError => :overloaded
      }.freeze

      NON_RETRYABLE = {
        RubyLLM::UnauthorizedError => [:authentication, :invalid_credential],
        RubyLLM::ForbiddenError => [:authorization, :permission_denied],
        RubyLLM::PaymentRequiredError => [:billing, :billing_unavailable],
        RubyLLM::ContextLengthExceededError => [:context_length, :context_length_exceeded],
        RubyLLM::BadRequestError => [:invalid_request, :invalid_request],
        RubyLLM::UnsupportedServerToolError => [:unsupported, :unsupported_capability],
        RubyLLM::ToolCallParseError => [:invalid_response, :invalid_tool_arguments],
        RubyLLM::ModelNotFoundError => [:configuration, :invalid_configuration],
        RubyLLM::ConfigurationError => [:configuration, :invalid_configuration],
        RubyLLM::CancelledError => [:cancelled, :cancelled]
      }.freeze

      def self.call(error)
        transient = TRANSIENT.find { |klass, _| error.is_a?(klass) }
        return payload(error, :transient, transient.last, true) if transient

        permanent = NON_RETRYABLE.find { |klass, _| error.is_a?(klass) }
        return payload(error, *permanent.last, false) if permanent

        payload(error, :unknown, :unclassified_provider_error, false)
      end

      def self.payload(error, category, code, retryable)
        {category: category, code: code, retryable: retryable, message: safe_message(category, code)}
      end
      private_class_method :payload

      def self.safe_message(category, code)
        "Chat request failed (#{category}/#{code})"
      end
      private_class_method :safe_message
    end
  end
end
