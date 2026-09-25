# frozen_string_literal: true

require "json"
require "ruby_llm"

module AgentHarness
  module Api
    # Translates the normalized public chat values to RubyLLM public objects.
    class RubyLlmChatAdapter
      class UnsupportedOptionError < StandardError; end

      PROVIDER_CONFIG = {
        anthropic: %i[anthropic_api_key anthropic_api_base],
        openai: %i[openai_api_key openai_api_base]
      }.freeze

      def call(candidate:, messages:, tools:, max_output_tokens:, temperature:, stream:, timeout:, cancellation:,
        schema: nil, &on_event)
        context = build_context(candidate, timeout)
        chat = context.chat(model: candidate[:model], provider: candidate[:provider], protocol: ruby_llm_protocol(candidate),
          assume_model_exists: true)
        configure_chat(chat, candidate, messages, tools, max_output_tokens, temperature, schema)
        response = generate(chat, stream, cancellation, &on_event)
        emit_completed_tool_calls(response, &on_event) if stream
        normalize_response(response)
      end

      # RubyLLM keys streamed tool-call chunks by a stream index while
      # continuation chunks carry no call id, so correlation state must live
      # between chunks. Also remembers the latest cumulative token counts so
      # duplicate cumulative reports are not re-emitted.
      class StreamState
        attr_accessor :input_tokens, :output_tokens

        def initialize
          @provider_id_by_key = {}
          @started_ids = {}
          @latest_provider_id = nil
          @input_tokens = nil
          @output_tokens = nil
        end

        # Links a stream chunk key to its provider call id, returning true
        # only the first time +provider_id+ is seen.
        def start(stream_key, provider_id)
          @provider_id_by_key[stream_key] = provider_id unless stream_key.nil?
          @latest_provider_id = provider_id
          return false if @started_ids.key?(provider_id)

          @started_ids[provider_id] = true
        end

        def provider_id(stream_key)
          stream_key.nil? ? @latest_provider_id : @provider_id_by_key[stream_key]
        end

        def usage
          total = (input_tokens + output_tokens) if input_tokens && output_tokens
          {input_tokens: input_tokens, output_tokens: output_tokens, total_tokens: total}
        end
      end

      private

      def ruby_llm_protocol(candidate)
        return :anthropic if candidate[:provider].to_sym == :anthropic && candidate[:protocol].to_sym == :messages

        candidate[:protocol]
      end

      def build_context(candidate, timeout)
        provider = candidate[:provider].to_sym
        config_keys = PROVIDER_CONFIG[provider]
        raise RubyLLM::ConfigurationError, "Unsupported chat provider: #{provider}" unless config_keys

        RubyLLM.context do |config|
          config.public_send("#{config_keys[0]}=", candidate.dig(:credentials, :api_key))
          config.public_send("#{config_keys[1]}=", candidate[:endpoint])
          config.max_retries = 0
          apply_timeout(config, timeout)
        end
      end

      def apply_timeout(config, timeout)
        if timeout&.dig(:connect_seconds)
          raise UnsupportedOptionError, "RubyLLM does not support request-local connect timeouts"
        end

        seconds = timeout&.dig(:read_seconds)
        config.request_timeout = seconds if seconds
      end

      def configure_chat(chat, candidate, messages, tools, max_output_tokens, temperature, schema)
        chat.messages = normalize_messages(messages)
        chat.with_tools(tools.map { |tool| normalized_tool(tool) }) unless tools.empty?
        chat.with_headers(candidate[:headers] || {})
        chat.with_max_output_tokens(max_output_tokens) if max_output_tokens
        chat.with_temperature(temperature) unless temperature.nil?
        chat.with_schema(schema) if schema
      end

      def generate(chat, stream, cancellation)
        return chat.generate unless stream

        state = StreamState.new
        chat.generate do |chunk|
          chat.cancel if cancelled?(cancellation)
          stream_events(chunk, state).each { |event| yield event }
        end
      end

      def cancelled?(token)
        return false unless token

        token.respond_to?(:cancelled?) ? token.cancelled? : token.call
      end

      def normalize_messages(messages)
        stable_to_provider = tool_id_map(messages)
        messages.map do |message|
          role = message.fetch(:role).to_sym
          normalized = {role: role, content: text_content(message[:content])}
          normalized[:tool_calls] = normalize_input_tool_calls(message[:tool_calls]) if message[:tool_calls]
          normalized[:tool_call_id] = stable_to_provider.fetch(message[:tool_call_id], message[:tool_call_id]) if role == :tool
          normalized
        end
      end

      def tool_id_map(messages)
        messages.each_with_object({}) do |message, ids|
          Array(message[:tool_calls]).each do |call|
            ids[call[:id]] = call[:provider_id] || call[:id]
          end
        end
      end

      def normalize_input_tool_calls(tool_calls)
        Array(tool_calls).to_h do |call|
          provider_id = call[:provider_id] || call[:id]
          arguments = JSON.parse(call.fetch(:arguments_json, "{}"))
          [provider_id, {id: provider_id, name: call[:name], arguments: arguments}]
        end
      end

      def text_content(content)
        return content if content.is_a?(String) || content.nil?

        Array(content).map do |part|
          unless part[:type]&.to_sym == :text
            raise UnsupportedOptionError, "unsupported content type: #{part[:type]}"
          end

          part[:text].to_s
        end.join
      end

      def normalized_tool(tool)
        definition = tool.transform_keys(&:to_sym)
        name = definition.fetch(:name).to_s
        Class.new(RubyLLM::Tool).tap do |klass|
          klass.define_singleton_method(:tool_name) { name }
          klass.description(definition[:description].to_s)
          klass.parameters(definition[:input_schema] || definition[:parameters] || {type: "object", properties: {}})
          klass.define_method(:execute) { |**| raise "AgentHarness transports never execute tools" }
        end.new
      end

      def stream_events(chunk, state)
        [text_event(chunk), *tool_call_events(chunk, state), usage_event(chunk, state)].compact
      end

      def text_event(chunk)
        {type: :text_delta, content: chunk.content} unless chunk.content.nil? || chunk.content.empty?
      end

      def tool_call_events(chunk, state)
        return [] unless chunk.tool_calls

        chunk.tool_calls.flat_map { |stream_key, call| call_events(stream_key, call, state) }
      end

      # Continuation chunks have a nil id and carry the provider's raw JSON
      # fragment as arguments; they join the call that started their key.
      def call_events(stream_key, call, state)
        provider_id = call.id || state.provider_id(stream_key)
        return [] unless provider_id

        events = []
        if state.start(stream_key, provider_id)
          events << {type: :tool_call_started, provider_id: provider_id, name: call.name}
        end
        fragment = argument_fragment(call.arguments)
        events << {type: :tool_call_delta, provider_id: provider_id, arguments_json: fragment} if fragment
        events
      end

      # Deltas stay appendable JSON text; a start chunk may instead carry a
      # complete parsed Hash, which becomes JSON once.
      def argument_fragment(arguments)
        case arguments
        when String then arguments.empty? ? nil : arguments
        when Hash then arguments.empty? ? nil : JSON.generate(arguments)
        end
      end

      def usage_event(chunk, state)
        return unless cumulative_usage_changed?(chunk, state)

        {type: :usage_updated, **state.usage}
      end

      def cumulative_usage_changed?(chunk, state)
        tokens = chunk.tokens
        return false unless tokens

        changed = false
        if tokens.input && tokens.input != state.input_tokens
          state.input_tokens = tokens.input
          changed = true
        end
        if tokens.output && tokens.output != state.output_tokens
          state.output_tokens = tokens.output
          changed = true
        end
        changed
      end

      def emit_completed_tool_calls(response)
        Array(response.tool_calls&.values).each do |call|
          yield(type: :tool_call_completed, **normalize_tool_call(call))
        end
      end

      def normalize_response(response)
        {
          content: response.content || "",
          model: response.model,
          finish_reason: response.finish_reason,
          usage: normalize_usage(response.tokens),
          tool_calls: Array(response.tool_calls&.values).map { |call| normalize_tool_call(call) },
          refusal: refusal?(response)
        }
      end

      def refusal?(response)
        return true if response.finish_reason == :content_filter
        return false unless response.respond_to?(:raw)

        body = response.raw&.body
        return false unless body.is_a?(Hash)

        Array(body["output"] || body[:output]).any? do |item|
          next false unless item.is_a?(Hash)

          Array(item["content"] || item[:content]).any? do |part|
            part.is_a?(Hash) && (part["type"] || part[:type]) == "refusal"
          end
        end
      end

      def normalize_tool_call(call)
        {provider_id: call.id, name: call.name, arguments_json: JSON.generate(call.arguments || {})}
      end

      def normalize_usage(tokens)
        input = tokens&.input
        output = tokens&.output
        return unless input || output

        {input_tokens: input, output_tokens: output, total_tokens: (input && output) ? input + output : nil}
      end
    end
  end
end
