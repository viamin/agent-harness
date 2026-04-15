# frozen_string_literal: true

module AgentHarness
  module Providers
    # Shared token-usage parsing helpers for providers that extract token
    # counts from JSON/JSONL CLI output.
    #
    # Include this module in any provider that needs to inspect usage
    # payloads (hashes with keys like "input_tokens", "prompt_tokens",
    # "output_tokens", "completion_tokens" and their camelCase variants).
    #
    # Provider-specific behaviour (e.g. where to locate the payload in the
    # CLI output) stays in the provider class; only the reusable parsing
    # and comparison logic lives here.
    module TokenUsageParsing
      private

      TOKEN_COUNT_KEYS = %w[
        input_tokens
        prompt_tokens
        output_tokens
        completion_tokens
        inputTokens
        promptTokens
        outputTokens
        completionTokens
      ].freeze

      def normalized_model_name(value)
        return nil unless value.is_a?(String)

        stripped = value.strip
        stripped.empty? ? nil : stripped
      end

      def effective_model_name(runtime = nil)
        normalized_model_name(runtime&.model) || normalized_model_name(@config.model)
      end

      def nested_hash_value(value, *keys)
        keys.reduce(value) do |current, key|
          break nil unless current.is_a?(Hash)

          current[key]
        end
      end

      def normalize_token_count(value)
        count = case value
        when Integer
          value
        when String
          Integer(value, exception: false)
        end

        count if count && count >= 0
      end

      def token_count_for(usage, *keys)
        keys.each do |key|
          value = normalize_token_count(usage[key])
          return value unless value.nil?
        end
        nil
      end

      def select_best_usage_payload(candidates)
        candidates
          .select { |usage| usage_with_token_counts?(usage) }
          .max_by { |usage| [usage_token_field_count(usage), usage_token_total(usage)] }
      end

      def usage_token_field_count(usage)
        return 0 unless usage.is_a?(Hash)

        [
          token_count_for(usage, "input_tokens", "prompt_tokens", "inputTokens", "promptTokens"),
          token_count_for(usage, "output_tokens", "completion_tokens", "outputTokens", "completionTokens")
        ].count { |value| !value.nil? }
      end

      def usage_token_total(usage)
        return 0 unless usage.is_a?(Hash)

        [
          token_count_for(usage, "input_tokens", "prompt_tokens", "inputTokens", "promptTokens"),
          token_count_for(usage, "output_tokens", "completion_tokens", "outputTokens", "completionTokens")
        ].compact.sum
      end

      def usage_with_token_counts?(usage)
        return false unless usage.is_a?(Hash)
        return false unless TOKEN_COUNT_KEYS.any? { |key| usage.key?(key) }
        return false if negative_token_count_present?(usage)

        token_count_for(usage, "input_tokens", "prompt_tokens", "inputTokens", "promptTokens") ||
          token_count_for(usage, "output_tokens", "completion_tokens", "outputTokens", "completionTokens")
      end

      def negative_token_count_present?(usage)
        TOKEN_COUNT_KEYS.any? do |key|
          count = case usage[key]
          when Integer
            usage[key]
          when String
            Integer(usage[key], exception: false)
          end

          count && count < 0
        end
      end

      def token_count_keys
        TOKEN_COUNT_KEYS
      end
    end
  end
end
