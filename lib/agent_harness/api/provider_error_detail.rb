# frozen_string_literal: true

module AgentHarness
  module Api
    # Extracts allowlisted, actionable text from provider errors without
    # retaining response bodies or caller-controlled message content.
    module ProviderErrorDetail
      LOCAL_DETAILS = [
        "RubyLLM does not support request-local connect timeouts",
        "provider state does not match the selected protocol",
        "provider state must carry at least one Responses output item",
        "unsupported content type"
      ].freeze
      TOOL_REASONING_DETAIL = "Function tools with reasoning_effort are not supported for gpt-5.6-luna " \
        "in /v1/chat/completions. To use function tools, use /v1/responses or set reasoning_effort to 'none'."

      module_function

      def call(error)
        message = normalized(error.message)
        return if message.empty? || structured_body?(message) || !safe_source?(error, message)

        message
      end

      def normalized(value)
        value.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�")
          .gsub(/[[:cntrl:]]+/, " ").gsub(/\s+/, " ").strip
      end
      private_class_method :normalized

      def safe_source?(error, message)
        safe_local_detail?(error, message) || safe_provider_detail?(error, message)
      end
      private_class_method :safe_source?

      def safe_local_detail?(error, message)
        error.is_a?(RubyLlmChatAdapter::UnsupportedOptionError) && LOCAL_DETAILS.include?(message)
      end
      private_class_method :safe_local_detail?

      # RubyLLM parses this provider diagnostic from a JSON error field before
      # constructing BadRequestError. Checking both the structured body and its
      # fixed, non-content-bearing shape avoids exposing raw bodies or arbitrary
      # provider prose that may echo request or conversation content.
      def safe_provider_detail?(error, message)
        error.is_a?(RubyLLM::BadRequestError) && message == TOOL_REASONING_DETAIL &&
          structured_messages(error.response).include?(message)
      end
      private_class_method :safe_provider_detail?

      def structured_messages(response)
        body = response&.body
        parsed = body.is_a?(String) ? JSON.parse(body) : body
        return [] unless parsed.is_a?(Hash)

        error = parsed["error"] || parsed[:error]
        [error, parsed].filter_map { |part| part["message"] || part[:message] if part.is_a?(Hash) }
      rescue JSON::ParserError
        []
      end
      private_class_method :structured_messages

      def structured_body?(message)
        message.start_with?("{", "[", "<")
      end
      private_class_method :structured_body?
    end
  end
end
