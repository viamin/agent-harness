# frozen_string_literal: true

require "json"
require_relative "attempt_report"

module AgentHarness
  module Api
    # Versioned JSON wire codec for ChatTransport events and terminal results.
    # It restores only fields owned by the public chat contract; parsed tool
    # values and provider continuation state remain opaque JSON values.
    module ChatWireCodec
      VERSION = 1
      DEFAULT_MAX_BYTES = 4 * 1024 * 1024
      DEFAULT_MAX_DEPTH = 64
      DEFAULT_MAX_NODES = 50_000

      EVENT_TYPES = %i[
        response_started text_delta tool_call_started tool_call_delta tool_call_completed
        usage_updated attempt_completed fallback_selected response_completed response_failed response_cancelled
      ].freeze
      RESULT_STATUSES = %i[succeeded partial failed cancelled].freeze
      TOOL_STATUSES = %i[completed incomplete].freeze
      PROVIDERS = %i[anthropic openai].freeze
      PROTOCOLS = %i[messages responses chat_completions].freeze
      AUTHENTICATION_MODES = %i[api_key].freeze
      FINISH_REASONS = %i[stop tool_calls max_tokens length content_filter refusal].freeze
      ERROR_CATEGORIES = %i[
        transient authentication authorization billing invalid_request unsupported invalid_response
        context_length configuration cancelled unknown
      ].freeze
      ERROR_CODES = %i[
        timeout connection_failed rate_limited server_error service_unavailable overloaded
        invalid_credential permission_denied billing_unavailable context_length_exceeded invalid_request
        unsupported_capability structured_output_not_supported invalid_tool_arguments invalid_json invalid_schema
        refusal truncated_output invalid_configuration cancelled unclassified_provider_error
      ].freeze
      USAGE_KEYS = AttemptReport::USAGE_KEYS
      COST_KEYS = AttemptReport::COST_KEYS + %i[currency source priced_at]
      RESULT_KEYS = %i[
        request_id provider model protocol authentication_mode status content parsed tool_calls provider_state
        finish_reason usage error attempts provider_request_id
      ].freeze
      EVENT_KEYS = %i[
        type request_id attempt_id sequence candidate content id provider_id name arguments_json
        input_tokens output_tokens cache_read_tokens cache_write_tokens thinking_tokens total_tokens
        attempt from to error result
      ].freeze

      class ProtocolError < StandardError; end

      module_function

      def dump_event(event, **limits) = JSON.generate(to_wire(event, kind: :event, **limits))
      def dump_result(result, **limits) = JSON.generate(to_wire(result, kind: :result, **limits))
      def load_event(json, **limits) = load(json, expected_kind: :event, **limits)
      def load_result(json, **limits) = load(json, expected_kind: :result, **limits)

      def to_wire(value, kind:, **limits)
        wire = JSON.parse(JSON.generate(version: VERSION, kind: kind.to_s, payload: value))
        from_wire(wire, expected_kind: kind, **limits)
        wire
      rescue ProtocolError
        raise
      rescue JSON::GeneratorError, TypeError
        invalid!("value is not JSON-compatible")
      end

      def from_wire(wire, expected_kind: nil, max_bytes: DEFAULT_MAX_BYTES,
        max_depth: DEFAULT_MAX_DEPTH, max_nodes: DEFAULT_MAX_NODES)
        bound_structure!(wire, max_bytes:, max_depth:, max_nodes:)
        envelope = object!(wire, "envelope")
        invalid!("unsupported version") unless fetch(envelope, :version) == VERSION
        kind = enum(fetch(envelope, :kind), %i[event result], "payload kind")
        invalid!("unexpected payload kind") if expected_kind && kind != expected_kind.to_sym

        payload = fetch(envelope, :payload)
        (kind == :event) ? decode_event(payload) : decode_result(payload)
      rescue ProtocolError
        raise
      rescue NoMethodError, TypeError, ArgumentError
        invalid!("invalid structure")
      end

      def load(json, expected_kind:, max_bytes: DEFAULT_MAX_BYTES, **limits)
        invalid!("input must be a JSON string") unless json.is_a?(String)
        invalid!("input exceeds byte limit") if json.bytesize > max_bytes

        from_wire(JSON.parse(json, max_nesting: limits.fetch(:max_depth, DEFAULT_MAX_DEPTH)),
          expected_kind:, max_bytes:, **limits)
      rescue JSON::ParserError
        invalid!("malformed JSON")
      end
      private_class_method :load

      def decode_event(payload)
        source = object!(payload, "event")
        event = copy_keys(source, EVENT_KEYS)
        event[:type] = enum(event[:type], EVENT_TYPES, "event type")
        required!(event, :request_id, "event")
        required!(event, :attempt_id, "event")
        positive_integer!(event[:sequence], "event sequence")
        event[:candidate] = decode_candidate(event[:candidate]) if event.key?(:candidate)
        event[:from] = decode_candidate(event[:from]) if event.key?(:from)
        event[:to] = decode_candidate(event[:to]) if event.key?(:to)
        event[:error] = decode_error(event[:error]) if event[:error]
        event[:attempt] = decode_attempt(event[:attempt]) if event.key?(:attempt)
        event[:result] = decode_result(event[:result]) if event.key?(:result)
        validate_event_payload!(event)
        event
      end
      private_class_method :decode_event

      def validate_event_payload!(event)
        required = case event[:type]
        when :response_started then %i[candidate]
        when :text_delta then %i[content]
        when :tool_call_started then %i[id name]
        when :tool_call_delta then %i[id arguments_json]
        when :tool_call_completed then %i[id name arguments_json]
        when :attempt_completed then %i[attempt]
        when :fallback_selected then %i[from to error]
        when :response_completed, :response_failed, :response_cancelled then %i[result]
        else []
        end
        required.each { |key| required!(event, key, "#{event[:type]} event") }
      end
      private_class_method :validate_event_payload!

      def decode_result(payload)
        source = object!(payload, "result")
        result = copy_keys(source, RESULT_KEYS)
        required!(result, :request_id, "result")
        result[:status] = enum(result[:status], RESULT_STATUSES, "result status")
        result[:provider] = nullable_enum(result[:provider], PROVIDERS, "result provider")
        result[:protocol] = nullable_enum(result[:protocol], PROTOCOLS, "result protocol")
        result[:authentication_mode] = nullable_enum(result[:authentication_mode], AUTHENTICATION_MODES,
          "result authentication mode")
        result[:finish_reason] = nullable_enum(result[:finish_reason], FINISH_REASONS, "result finish reason")
        result[:usage] = decode_usage(result[:usage]) if result[:usage]
        result[:error] = decode_error(result[:error]) if result[:error]
        result[:tool_calls] = array!(result[:tool_calls], "result tool_calls").map { |call| decode_tool_call(call) }
        result[:attempts] = array!(result[:attempts], "result attempts").map { |attempt| decode_attempt(attempt) }
        result
      end
      private_class_method :decode_result

      def decode_candidate(value)
        candidate = copy_keys(object!(value, "candidate"), %i[provider model protocol authentication_mode])
        candidate[:provider] = enum(candidate[:provider], PROVIDERS, "candidate provider")
        candidate[:protocol] = enum(candidate[:protocol], PROTOCOLS, "candidate protocol")
        candidate[:authentication_mode] = enum(candidate[:authentication_mode], AUTHENTICATION_MODES,
          "candidate authentication mode")
        candidate
      end
      private_class_method :decode_candidate

      def decode_tool_call(value)
        call = copy_keys(object!(value, "tool call"), %i[id provider_id name arguments_json status])
        %i[id name arguments_json].each { |key| required!(call, key, "tool call") }
        call[:status] = enum(call[:status], TOOL_STATUSES, "tool call status")
        call
      end
      private_class_method :decode_tool_call

      def decode_attempt(value)
        attempt = copy_keys(object!(value, "attempt"), %i[
          attempt_id request_id number provider model status started_at finished_at usage cost provider_reported error
        ])
        attempt[:provider] = enum(attempt[:provider], PROVIDERS, "attempt provider")
        attempt[:status] = enum(attempt[:status], AttemptReport::STATUSES, "attempt status")
        attempt[:usage] = decode_usage(attempt[:usage]) if attempt[:usage]
        attempt[:cost] = decode_cost(attempt[:cost]) if attempt[:cost]
        attempt[:error] = decode_error(attempt[:error]) if attempt[:error]
        AttemptReport.from_h(attempt).to_h.merge(error: attempt[:error])
      rescue ArgumentError
        invalid!("invalid attempt report")
      end
      private_class_method :decode_attempt

      def decode_usage(value) = copy_keys(object!(value, "usage"), USAGE_KEYS)

      def decode_cost(value)
        cost = copy_keys(object!(value, "cost"), COST_KEYS)
        cost[:source] = enum(cost[:source], %i[provider_reported estimated], "cost source")
        cost
      end
      private_class_method :decode_cost

      def decode_error(value)
        error = copy_keys(object!(value, "error"), %i[category code retryable message retry_after_seconds])
        error[:category] = enum(error[:category], ERROR_CATEGORIES, "error category")
        error[:code] = enum(error[:code], ERROR_CODES, "error code")
        error
      end
      private_class_method :decode_error

      def bound_structure!(root, max_bytes:, max_depth:, max_nodes:)
        invalid!("invalid limits") unless [max_bytes, max_depth, max_nodes].all? { |limit| limit.is_a?(Integer) && limit.positive? }
        nodes = 0
        bytes = 0
        pending = [[root, 1]]
        until pending.empty?
          value, depth = pending.pop
          invalid!("nesting exceeds limit") if depth > max_depth
          nodes += 1
          invalid!("node count exceeds limit") if nodes > max_nodes
          bytes += value.bytesize if value.is_a?(String)
          invalid!("content exceeds byte limit") if bytes > max_bytes
          children = if value.is_a?(Hash)
            value.values
          elsif value.is_a?(Array)
            value
          else
            []
          end
          children.each { |child| pending << [child, depth + 1] }
        end
      end
      private_class_method :bound_structure!

      def object!(value, name)
        invalid!("#{name} must be an object") unless value.is_a?(Hash)
        value
      end
      private_class_method :object!

      def array!(value, name)
        invalid!("#{name} must be an array") unless value.is_a?(Array)
        value
      end
      private_class_method :array!

      def copy_keys(source, keys)
        keys.each_with_object({}) do |key, result|
          result[key] = fetch(source, key) if source.key?(key) || source.key?(key.to_s)
        end
      end
      private_class_method :copy_keys

      def fetch(source, key) = source.key?(key) ? source[key] : source[key.to_s]
      private_class_method :fetch

      def enum(value, allowed, name)
        match = allowed.find { |entry| entry.to_s == value.to_s }
        invalid!("invalid #{name}") unless match
        match
      end
      private_class_method :enum

      def nullable_enum(value, allowed, name) = value.nil? ? nil : enum(value, allowed, name)
      private_class_method :nullable_enum

      def required!(hash, key, name)
        invalid!("missing #{name} #{key}") if !hash.key?(key) || hash[key].nil? || hash[key] == ""
      end
      private_class_method :required!

      def positive_integer!(value, name)
        invalid!("invalid #{name}") unless value.is_a?(Integer) && value.positive?
      end
      private_class_method :positive_integer!

      def invalid!(reason) = raise(ProtocolError, "invalid chat wire payload: #{reason}")
      private_class_method :invalid!
    end
  end
end
