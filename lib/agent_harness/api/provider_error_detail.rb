# frozen_string_literal: true

module AgentHarness
  module Api
    # Extracts bounded, actionable text from provider errors without retaining
    # response bodies or common request and credential representations.
    module ProviderErrorDetail
      MAX_LENGTH = 1_000
      REDACTED = "[REDACTED]"
      SENSITIVE_SECTION = /(?:\b(?:request|response)\s+body\b|\b(?:headers?|messages?|conversation|prompt)\s*[:=]).*\z/i
      SENSITIVE_VALUE = /\b(?:authorization|x-api-key|api[_-]?key|access[_-]?token|secret)\b\s*[:=]\s*[^\s,;]+/i
      BEARER_TOKEN = /\b(?:bearer|basic)\s+[a-z0-9._~+\/-]+=*/i
      PROVIDER_TOKEN = /\b(?:sk|key)-[a-z0-9_-]{8,}\b/i
      URL = %r{https?://[^\s<>]+}i

      module_function

      def call(error)
        message = normalized(error.message)
        return if message.empty? || raw_response_body?(error, message) || structured_body?(message)

        sanitize(message)[0, MAX_LENGTH].strip
      end

      def normalized(value)
        value.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�")
          .gsub(/[[:cntrl:]]+/, " ").gsub(/\s+/, " ").strip
      end
      private_class_method :normalized

      def raw_response_body?(error, message)
        return false unless error.respond_to?(:response)

        body = error.response&.body
        body.is_a?(String) && normalized(body) == message
      end
      private_class_method :raw_response_body?

      def structured_body?(message)
        message.start_with?("{", "[", "<")
      end
      private_class_method :structured_body?

      def sanitize(message)
        message
          .sub(SENSITIVE_SECTION, REDACTED)
          .gsub(BEARER_TOKEN, REDACTED)
          .gsub(SENSITIVE_VALUE, REDACTED)
          .gsub(PROVIDER_TOKEN, REDACTED)
          .gsub(URL, "[REDACTED URL]")
      end
      private_class_method :sanitize
    end
  end
end
