# frozen_string_literal: true

module AgentHarness
  module Api
    # Extracts bounded, actionable text from provider errors without retaining
    # response bodies or common request and credential representations.
    module ProviderErrorDetail
      MAX_LENGTH = 1_000
      REDACTED = "[REDACTED]"
      REDACTED_URL = "[REDACTED URL]"
      SENSITIVE_SECTION = /(?:\b(?:request|response)\s+body\b|\b(?:headers?|messages?|conversation|prompt)\s*[:=]).*\z/i
      SENSITIVE_VALUE = /\b(?:authorization|x-api-key|api[_-]?key|access[_-]?token|secret)\b\s*[:=]\s*[^\s,;]+/i
      BEARER_TOKEN = /\b(?:bearer|basic)\s+[a-z0-9._~+\/-]+=*/i
      PROVIDER_TOKEN = /\b(?:sk|key)-[a-z0-9_-]{8,}\b/i
      URL = %r{https?://[^\s<>]+}i

      module_function

      def call(error)
        message = normalized(error.message)
        return if message.empty? || untrusted_source?(error) || structured_body?(message)

        truncate(sanitize(message))
      end

      def normalized(value)
        value.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�")
          .gsub(/[[:cntrl:]]+/, " ").gsub(/\s+/, " ").strip
      end
      private_class_method :normalized

      # Provider responses and parser diagnostics can quote request or conversation
      # content. Redaction cannot prove that arbitrary prose from either source is
      # safe, so only locally constructed error messages are eligible for detail.
      def untrusted_source?(error)
        error.is_a?(JSON::ParserError) || (error.respond_to?(:response) && !error.response.nil?)
      end
      private_class_method :untrusted_source?

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
          .gsub(URL, REDACTED_URL)
      end
      private_class_method :sanitize

      # Sanitizing the full message before truncating keeps partial secrets at
      # the boundary redacted; when the cut would split a redaction marker, the
      # slice grows so the marker is always emitted whole.
      def truncate(sanitized)
        return sanitized if sanitized.length <= MAX_LENGTH

        cut = sanitized[0, MAX_LENGTH]
        marker_start = cut.rindex("[")
        return cut.strip if marker_start.nil?

        marker = [REDACTED_URL, REDACTED].find { |candidate| sanitized[marker_start..].start_with?(candidate) }
        return cut.strip if marker.nil? || marker_start + marker.length <= MAX_LENGTH

        sanitized[0, marker_start + marker.length].strip
      end
      private_class_method :truncate
    end
  end
end
