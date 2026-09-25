# frozen_string_literal: true

require "json"
require "json_schemer"

module AgentHarness
  module Api
    # Parses and validates one schema-constrained provider response.
    class SchemaResponse
      def initialize(schema)
        @validator = JSONSchemer.schema(schema)
      end

      def call(response)
        content = response[:content].to_s
        return failure(content, :refusal) if response[:refusal]
        return failure(content, :truncated_output) if response[:finish_reason]&.to_sym == :max_tokens

        parsed = JSON.parse(content)
        return failure(content, :invalid_schema) unless @validator.valid?(parsed)

        {content: content, parsed: parsed, error: nil}
      rescue JSON::ParserError
        failure(content, :invalid_json)
      end

      private

      def failure(content, code)
        {
          content: content,
          parsed: nil,
          error: {
            category: :invalid_response,
            code: code,
            retryable: false,
            message: "Schema response failed (invalid_response/#{code})"
          }
        }
      end
    end
  end
end
