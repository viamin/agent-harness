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
      if role == :system && !@messages.empty?
        raise ArgumentError, "System messages are only allowed as the first message"
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
      system_message = initial_system_message
      system_messages = (keep_system_prompt && system_message) ? [system_message] : []
      non_system = system_message ? @messages.drop(1) : @messages

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
      system_prompt = initial_system_message&.dig(:content)
      result_messages = []

      start_index = system_prompt ? 1 : 0
      @messages.drop(start_index).each do |msg|
        case msg[:role]
        when :user
          result_messages << {
            role: "user",
            content: [{type: "text", text: msg[:content]}]
          }
        when :assistant
          content_blocks = []
          content_blocks << {type: "text", text: msg[:content]} if msg[:content]

          msg[:tool_calls]&.each do |tc|
            arguments = tool_call_arguments(tc)
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
              id: tool_call_value(tc, :id),
              name: tool_call_name(tc),
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

      {system: system_prompt, messages: result_messages}
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
      system_message = initial_system_message
      @messages = system_message ? [system_message] : []
    end

    private

    def initial_system_message
      @messages.first if @messages.first&.dig(:role) == :system
    end

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
              id: tool_call_value(tc, :id),
              type: "function",
              function: {
                name: tool_call_name(tc),
                arguments: serialize_tool_call_arguments(tc)
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

    def serialize_tool_call_arguments(tool_call)
      arguments = tool_call_arguments(tool_call)
      arguments.is_a?(Hash) ? JSON.generate(arguments) : arguments
    end

    def tool_call_name(tool_call)
      tool_call_value(tool_call, :name) || nested_tool_call_value(tool_call, :function, :name)
    end

    def tool_call_arguments(tool_call)
      tool_call_value(tool_call, :arguments) || nested_tool_call_value(tool_call, :function, :arguments)
    end

    def nested_tool_call_value(tool_call, *keys)
      value = tool_call
      keys.each do |key|
        value = hash_value(value, key)
        return nil if value.nil?
      end
      value
    end

    def tool_call_value(tool_call, key)
      hash_value(tool_call, key)
    end

    def hash_value(hash, key)
      return nil unless hash.is_a?(Hash)

      hash[key] || hash[key.to_s]
    end
  end
end
