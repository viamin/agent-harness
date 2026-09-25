# frozen_string_literal: true

require "json"
require "ruby_llm"

module AgentHarness
  module Api
    # Translates the normalized public chat values to RubyLLM public objects.
    class RubyLlmChatAdapter
      PROVIDER_CONFIG = {
        anthropic: %i[anthropic_api_key anthropic_api_base],
        openai: %i[openai_api_key openai_api_base]
      }.freeze

      def call(candidate:, messages:, tools:, max_output_tokens:, temperature:, stream:, timeout:, cancellation:, &on_event)
        context = build_context(candidate, timeout)
        chat = context.chat(model: candidate[:model], provider: candidate[:provider], protocol: ruby_llm_protocol(candidate),
          assume_model_exists: true)
        configure_chat(chat, candidate, messages, tools, max_output_tokens, temperature)
        response = generate(chat, stream, cancellation, &on_event)
        emit_completed_tool_calls(response, &on_event) if stream
        normalize_response(response)
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
          config.public_send("#{config_keys[1]}=", candidate[:endpoint]) if candidate[:endpoint]
          config.max_retries = 0
          apply_timeout(config, timeout)
        end
      end

      def apply_timeout(config, timeout)
        seconds = timeout&.dig(:read_seconds)
        config.request_timeout = seconds if seconds
      end

      def configure_chat(chat, candidate, messages, tools, max_output_tokens, temperature)
        chat.messages = normalize_messages(messages)
        chat.with_tools(tools.map { |tool| normalized_tool(tool) }) unless tools.empty?
        chat.with_headers(candidate[:headers] || {})
        chat.with_max_output_tokens(max_output_tokens) if max_output_tokens
        chat.with_temperature(temperature) unless temperature.nil?
      end

      def generate(chat, stream, cancellation)
        return chat.generate unless stream

        started_tools = {}
        chat.generate do |chunk|
          chat.cancel if cancelled?(cancellation)
          stream_events(chunk, started_tools).each { |event| yield event }
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
          raise ArgumentError, "unsupported content type: #{part[:type]}" unless part[:type].to_sym == :text

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

      def stream_events(chunk, started_tools)
        events = []
        events << {type: :text_delta, content: chunk.content} unless chunk.content.nil? || chunk.content.empty?
        Array(chunk.tool_calls&.values).each do |call|
          unless started_tools[call.id]
            events << {type: :tool_call_started, provider_id: call.id, name: call.name}
            started_tools[call.id] = true
          end
          events << {type: :tool_call_delta, provider_id: call.id, name: call.name,
                     arguments_json: JSON.generate(call.arguments || {})}
        end
        events
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
          tool_calls: Array(response.tool_calls&.values).map { |call| normalize_tool_call(call) }
        }
      end

      def normalize_tool_call(call)
        {provider_id: call.id, name: call.name, arguments_json: JSON.generate(call.arguments || {})}
      end

      def normalize_usage(tokens)
        return unless tokens

        input = tokens.input
        output = tokens.output
        total = (input + output) if input && output
        {input_tokens: input, output_tokens: output, total_tokens: total}
      end
    end
  end
end
