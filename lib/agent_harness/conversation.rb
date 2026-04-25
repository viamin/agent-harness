# frozen_string_literal: true

require "json"

module AgentHarness
  # Manages multi-turn conversation history with token tracking and
  # transport-specific message formatting.
  #
  # Encapsulates message storage, token budget awareness, context window
  # truncation, and serialisation to OpenAI and Anthropic API formats.
  #
  # @example Basic usage
  #   convo = AgentHarness::Conversation.new(system_prompt: "You are helpful.")
  #   convo.add_message(:user, "Hello")
  #   convo.add_message(:assistant, "Hi there!", tokens: { input: 10, output: 5 })
  #   convo.to_openai_messages
  #
  # @example Token-aware truncation
  #   convo = AgentHarness::Conversation.new(system_prompt: "...", token_limit: 8000)
  #   # ... add many messages ...
  #   convo.truncate(keep_recent: 4) if convo.approaching_limit?
  class Conversation
    VALID_ROLES = %i[system user assistant tool].freeze

    # @return [Integer, nil] the token budget for this conversation
    attr_reader :token_limit

    # @param system_prompt [String, nil] optional system prompt prepended to messages
    # @param token_limit [Integer, nil] optional context-window token budget
    def initialize(system_prompt: nil, token_limit: nil)
      @messages = []
      @token_limit = token_limit

      if system_prompt
        add_message(:system, system_prompt)
      end
    end

    # Append a message to the conversation.
    #
    # @param role [Symbol] one of :system, :user, :assistant, :tool
    # @param content [String, nil] message text
    # @param metadata [Hash] optional fields — :tool_calls, :tool_call_id,
    #   :tool_name, :tool_arguments, :tool_result, :model, :tokens
    # @return [Hash] the message that was added
    # @raise [ArgumentError] if role is invalid
    def add_message(role, content = nil, **metadata)
      role = role.to_sym
      unless VALID_ROLES.include?(role)
        raise ArgumentError, "Invalid role: #{role}. Must be one of #{VALID_ROLES.join(", ")}"
      end

      message = {
        role: role,
        content: content,
        created_at: Time.now
      }

      message[:tool_calls] = metadata[:tool_calls] if metadata[:tool_calls]
      message[:tool_call_id] = metadata[:tool_call_id] if metadata[:tool_call_id]
      message[:tool_name] = metadata[:tool_name] if metadata[:tool_name]
      message[:tool_arguments] = metadata[:tool_arguments] if metadata[:tool_arguments]
      message[:tool_result] = metadata[:tool_result] if metadata[:tool_result]
      message[:model] = metadata[:model] if metadata[:model]
      message[:tokens] = metadata[:tokens] if metadata[:tokens]

      @messages << message
      deep_copy(message)
    end

    # Returns the full message history.
    #
    # @return [Array<Hash>] all messages in chronological order
    def messages
      deep_copy(@messages)
    end

    # @return [Integer] the number of messages in the conversation
    def message_count
      @messages.size
    end

    # Sum of all tracked tokens (input + output) across messages.
    #
    # @return [Integer] total tokens consumed
    def token_count
      @messages.sum do |msg|
        tokens = msg[:tokens]
        next 0 unless tokens

        (tokens[:input] || 0) + (tokens[:output] || 0)
      end
    end

    # Tokens remaining before hitting the limit.
    #
    # @return [Integer, nil] remaining tokens, or nil when no limit is set
    def token_remaining
      return nil unless @token_limit

      @token_limit - token_count
    end

    # Whether token usage has reached or exceeded the given threshold of the limit.
    #
    # @param threshold [Float] fraction of token_limit (0.0–1.0) at which to warn
    # @return [Boolean] true when usage >= threshold * limit; false when no limit set
    def approaching_limit?(threshold: 0.8)
      return false unless @token_limit

      token_count >= (threshold * @token_limit)
    end

    # Remove oldest non-system messages to free context window.
    #
    # keep_recent counts conversational turns, not individual messages. A turn is
    # anchored by a user message and includes any following assistant/tool
    # messages up to the next user message.
    #
    # @param keep_recent [Integer, nil] minimum number of recent turns to preserve
    # @param keep_system_prompt [Boolean] whether to preserve the system prompt
    # @return [Integer] number of messages removed
    def truncate(keep_recent: nil, keep_system_prompt: true)
      original_size = @messages.size
      system_messages = keep_system_prompt ? @messages.select { |m| m[:role] == :system } : []
      non_system = @messages.reject { |m| m[:role] == :system }

      kept = if keep_recent
        recent_turns(non_system, keep_recent).flatten
      else
        non_system
      end

      @messages = system_messages + kept
      original_size - @messages.size
    end

    # Format messages for OpenAI-compatible chat completions APIs.
    #
    # @return [Array<Hash>] messages with string roles and content
    def to_openai_messages
      @messages.map { |msg| openai_format(msg) }
    end

    # Format messages for the Anthropic Messages API.
    #
    # The system prompt is returned separately; tool results are wrapped as
    # content blocks inside user messages per Anthropic's schema.
    #
    # @return [Hash] :system [String, nil] and :messages [Array<Hash>]
    def to_anthropic_messages
      system_messages = []
      result_messages = []

      @messages.each do |msg|
        case msg[:role]
        when :system
          system_messages << msg[:content]
        when :user
          result_messages << {
            role: "user",
            content: [{type: "text", text: msg[:content]}]
          }
        when :assistant
          content_blocks = []
          content_blocks << {type: "text", text: msg[:content]} if msg[:content]

          msg[:tool_calls]&.each do |tc|
            arguments = tc[:arguments]
            parsed_arguments = if arguments.is_a?(String)
              begin
                JSON.parse(arguments)
              rescue JSON::ParserError
                arguments
              end
            else
              arguments
            end

            content_blocks << {
              type: "tool_use",
              id: tc[:id],
              name: tc[:name],
              input: parsed_arguments
            }
          end

          result_messages << {role: "assistant", content: content_blocks}
        when :tool
          tool_result_block = {
            type: "tool_result",
            tool_use_id: msg[:tool_call_id],
            content: msg[:content]
          }
          prev = result_messages.last
          if prev && prev[:role] == "user" && prev[:content]&.first&.dig(:type) == "tool_result"
            prev[:content] << tool_result_block
          else
            result_messages << {
              role: "user",
              content: [tool_result_block]
            }
          end
        end
      end

      {system: system_messages.empty? ? nil : system_messages.join("\n\n"), messages: result_messages}
    end

    # Returns the most recent assistant message, or nil.
    #
    # @return [Hash, nil]
    def last_assistant_message
      @messages.reverse_each do |msg|
        return deep_copy(msg) if msg[:role] == :assistant
      end
      nil
    end

    # Remove all messages except the system prompt.
    #
    # @return [void]
    def clear!
      @messages.select! { |m| m[:role] == :system }
    end

    private

    def recent_turns(non_system_messages, keep_recent)
      turns = non_system_messages.each_with_object([]) do |msg, grouped_turns|
        if msg[:role] == :user || grouped_turns.empty?
          grouped_turns << [msg]
        else
          grouped_turns.last << msg
        end
      end

      (keep_recent < turns.size) ? turns.last(keep_recent) : turns
    end

    def openai_format(msg)
      case msg[:role]
      when :tool
        {
          role: "tool",
          content: msg[:content],
          tool_call_id: msg[:tool_call_id]
        }
      when :assistant
        formatted = {role: "assistant", content: msg[:content]}
        if msg[:tool_calls]
          formatted[:tool_calls] = msg[:tool_calls].map do |tc|
            {
              id: tc[:id],
              type: "function",
              function: {
                name: tc[:name],
                arguments: tc[:arguments].is_a?(Hash) ? JSON.generate(tc[:arguments]) : tc[:arguments]
              }
            }
          end
        end
        formatted
      else
        {role: msg[:role].to_s, content: msg[:content]}
      end
    end

    def deep_copy(value)
      case value
      when Array
        value.map { |item| deep_copy(item) }
      when Hash
        value.each_with_object({}) do |(key, nested_value), copy|
          copy[key] = deep_copy(nested_value)
        end
      else
        begin
          value.dup
        rescue TypeError
          value
        end
      end
    end
  end
end
