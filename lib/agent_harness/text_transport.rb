# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module AgentHarness
  # Direct HTTP transport for text-only provider interactions.
  #
  # Bypasses the CLI entirely by calling the provider's REST API directly.
  # Currently supports Anthropic's Messages API. This transport is used when
  # callers declare a task as text-only via +mode: :text+ on +send_message+.
  #
  # The transport preserves the same Response structure, token tracking,
  # and error classification semantics as the CLI path so that callers
  # do not need to distinguish between transport modes after the call.
  #
  # @example
  #   transport = AgentHarness::TextTransport.new(api_key: "sk-ant-...")
  #   response = transport.send_message("Summarize this PR", model: "claude-sonnet-4-20250514")
  class TextTransport
    ANTHROPIC_API_URL = "https://api.anthropic.com/v1/messages"
    ANTHROPIC_API_VERSION = "2023-06-01"
    DEFAULT_MODEL = "claude-sonnet-4-20250514"
    DEFAULT_MAX_TOKENS = 4096
    DEFAULT_TIMEOUT = 300

    # @param base_url [String] Anthropic Messages API URL
    # @param api_key [String] Anthropic API key
    # @param logger [Logger, nil] optional logger
    def initialize(api_key:, base_url: ANTHROPIC_API_URL, logger: nil)
      @base_url = base_url
      @api_key = api_key
      @logger = logger
    end

    # Send a multi-turn chat completion request via the Anthropic Messages API.
    #
    # @param messages [Array<Hash>] conversation messages with :role and :content
    # @param tools [Array<Hash>, nil] tool definitions (Anthropic tool format)
    # @param stream [Boolean] whether to stream the response
    # @param max_tokens [Integer, nil] maximum tokens in the response
    # @param temperature [Float, nil] sampling temperature
    # @yield [Hash] streaming chunks when stream: true
    # @return [Response] the response
    def chat(messages:, tools: nil, stream: false, max_tokens: nil, temperature: nil,
      model: nil, on_chat_chunk: nil, observer: nil, &on_chunk)
      model ||= DEFAULT_MODEL
      timeout = DEFAULT_TIMEOUT
      max_tokens ||= DEFAULT_MAX_TOKENS

      uri = URI(@base_url)

      system_messages = messages.select { |m| m[:role] == "system" || m["role"] == "system" }
      non_system = messages.reject { |m| m[:role] == "system" || m["role"] == "system" }
      has_stream_receiver = on_chunk || on_chat_chunk || observer_responds_to?(observer, :on_chat_chunk)
      request_stream = stream && has_stream_receiver

      body = build_chat_request_body(
        model: model,
        max_tokens: max_tokens,
        messages: non_system,
        system_messages: system_messages,
        tools: tools,
        temperature: temperature,
        stream: request_stream
      )

      start_time = Time.now

      if request_stream
        combined = build_chat_chunk_callback(on_chunk, on_chat_chunk, observer)
        result = make_streaming_request(uri, body, timeout: timeout, &combined)
        duration = Time.now - start_time
        build_streaming_response(result, duration: duration, model: model)
      else
        http_response = make_request(uri, body, timeout: timeout)
        duration = Time.now - start_time
        parse_response(http_response, duration: duration, model: model)
      end
    end

    # Send a text-only message via the Anthropic Messages API.
    #
    # @param prompt [String] the user prompt
    # @param model [String, nil] model to use (defaults to DEFAULT_MODEL)
    # @param timeout [Integer, nil] request timeout in seconds
    # @param max_tokens [Integer, nil] maximum tokens in the response
    # @return [Response] the response
    # @raise [AuthenticationError] on 401 responses
    # @raise [RateLimitError] on 429 responses
    # @raise [TimeoutError] on network timeouts
    # @raise [ProviderError] on other HTTP errors
    def send_message(prompt, model: nil, timeout: nil, max_tokens: nil)
      model ||= DEFAULT_MODEL
      timeout ||= DEFAULT_TIMEOUT
      max_tokens ||= DEFAULT_MAX_TOKENS

      uri = URI(@base_url)
      body = {
        model: model,
        max_tokens: max_tokens,
        messages: [{role: "user", content: prompt}]
      }

      start_time = Time.now
      http_response = make_request(uri, body, timeout: timeout)
      duration = Time.now - start_time

      parse_response(http_response, duration: duration, model: model)
    end

    private

    def build_chat_request_body(model:, max_tokens:, messages:, system_messages:, tools:, temperature:, stream:)
      body = {
        model: model,
        max_tokens: max_tokens,
        messages: messages.map { |m| {role: m[:role] || m["role"], content: m[:content] || m["content"]} }
      }
      body[:system] = system_messages.map { |m| m[:content] || m["content"] }.join("\n") if system_messages.any?
      body[:tools] = tools if tools
      body[:temperature] = temperature if temperature
      body[:stream] = true if stream
      body
    end

    def make_request(uri, body, timeout:)
      http = build_http(uri, timeout: timeout)
      request = build_post_request(uri, body)

      @logger&.debug("[AgentHarness::TextTransport] POST #{uri} model=#{body[:model]}")

      http.request(request)
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise TimeoutError.new(e.message, original_error: e)
    rescue SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, IOError => e
      raise ProviderError.new("HTTP connection error: #{e.message}", original_error: e)
    end

    def make_streaming_request(uri, body, timeout:, &on_chunk)
      http = build_http(uri, timeout: timeout)
      request = build_post_request(uri, body)

      @logger&.debug("[AgentHarness::TextTransport] POST #{uri} model=#{body[:model]} stream=true")

      accumulated = {content: +"", model: nil, usage: nil, tool_calls: [], headers: {}}

      http.request(request) do |http_response|
        status_code = http_response.code.to_i
        unless status_code == 200
          response_body = http_response.read_body
          handle_error_response_raw(response_body, status_code)
        end

        accumulated[:headers] = extract_headers(http_response)
        parse_sse_stream(http_response, accumulated, &on_chunk)
      end

      accumulated
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise TimeoutError.new(e.message, original_error: e)
    rescue SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, IOError => e
      raise ProviderError.new("HTTP connection error: #{e.message}", original_error: e)
    end

    def build_http(uri, timeout:)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = [timeout, 30].min
      http.read_timeout = timeout
      http
    end

    def build_post_request(uri, body)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["x-api-key"] = @api_key
      request["anthropic-version"] = ANTHROPIC_API_VERSION
      request.body = JSON.generate(body)
      request
    end

    def parse_sse_stream(http_response, accumulated, &on_chunk)
      buffer = +""
      event_name = nil
      data_lines = []

      http_response.read_body do |chunk|
        buffer << chunk.delete("\r")

        while (line_end = buffer.index("\n"))
          line = buffer.slice!(0, line_end + 1).chomp("\n")

          if line.empty?
            process_sse_event(event_name, data_lines.join("\n"), accumulated, &on_chunk)
            event_name = nil
            data_lines = []
            next
          end

          if line.start_with?("event:")
            event_name = line[6..].strip
          elsif line.start_with?("data:")
            data_lines << line[5..].lstrip
          end
        end
      end

      process_sse_event(event_name, data_lines.join("\n"), accumulated, &on_chunk) unless data_lines.empty?
    end

    def process_sse_event(event_name, raw_data, accumulated, &on_chunk)
      return if raw_data.nil? || raw_data.empty?
      return if event_name == "ping"

      payload = JSON.parse(raw_data)
      type = payload["type"] || event_name

      case type
      when "message_start"
        message = payload["message"] || {}
        accumulated[:model] ||= message["model"]
        merge_usage!(accumulated, message["usage"])
      when "content_block_start"
        process_content_block_start(payload, accumulated, &on_chunk)
      when "content_block_delta"
        process_content_block_delta(payload, accumulated, &on_chunk)
      when "content_block_stop"
        process_content_block_stop(payload, accumulated, &on_chunk)
      when "message_delta"
        merge_usage!(accumulated, payload["usage"])
      when "message_stop"
        emit_usage_and_done(accumulated, &on_chunk)
      when "error"
        message = payload.dig("error", "message") || payload.dig("error", "type") || raw_data
        raise ProviderError, message
      end
    rescue JSON::ParserError => e
      @logger&.warn("[AgentHarness::TextTransport] Skipping malformed SSE event: #{e.message}")
    end

    def emit_text_delta(text, accumulated, &on_chunk)
      return if text.nil? || text.empty?

      accumulated[:content] << text
      on_chunk.call({type: :text, content: text})
    end

    def merge_usage!(accumulated, usage)
      return unless usage

      current = accumulated[:usage] || {input: 0, output: 0, total: 0}
      current[:input] = usage["input_tokens"] unless usage["input_tokens"].nil?
      current[:output] = usage["output_tokens"] unless usage["output_tokens"].nil?
      current[:total] = current[:input].to_i + current[:output].to_i
      accumulated[:usage] = current
    end

    def emit_usage_and_done(accumulated, &on_chunk)
      usage = accumulated[:usage]
      if usage
        on_chunk.call({
          type: :usage,
          input_tokens: usage[:input],
          output_tokens: usage[:output]
        })
      end
      on_chunk.call({type: :done})
    end

    def parse_response(http_response, duration:, model:)
      status_code = http_response.code.to_i

      unless status_code == 200
        handle_error_response(http_response, status_code)
      end

      body = JSON.parse(http_response.body)
      output = extract_text_content(body)
      tokens = extract_tokens(body)
      tool_calls = extract_tool_calls(body)

      metadata = {transport: :http, headers: extract_headers(http_response)}
      metadata[:tool_calls] = tool_calls if tool_calls

      Response.new(
        output: output,
        exit_code: 0,
        duration: duration,
        provider: :claude,
        model: body["model"] || model,
        tokens: tokens,
        metadata: metadata
      )
    rescue JSON::ParserError => e
      raise ProviderError.new(
        "Invalid JSON in API response: #{e.message}",
        original_error: e
      )
    end

    def build_streaming_response(accumulated, duration:, model:)
      tool_calls = accumulated[:tool_calls].compact
      metadata = {transport: :http, stream: true, headers: accumulated[:headers] || {}}
      metadata[:tool_calls] = tool_calls unless tool_calls.empty?

      Response.new(
        output: accumulated[:content],
        exit_code: 0,
        duration: duration,
        provider: :claude,
        model: accumulated[:model] || model,
        tokens: accumulated[:usage],
        metadata: metadata
      )
    end

    def extract_text_content(body)
      content = body["content"]
      return "" unless content.is_a?(Array)

      content
        .select { |block| block["type"] == "text" }
        .map { |block| block["text"] }
        .join
    end

    def extract_tool_calls(body)
      content = body["content"]
      return nil unless content.is_a?(Array)

      tool_calls = content.filter_map do |block|
        next unless block["type"] == "tool_use"

        {
          id: block["id"],
          name: block["name"],
          arguments: JSON.generate(block["input"] || {})
        }
      end

      tool_calls.empty? ? nil : tool_calls
    end

    def extract_tokens(body)
      usage = body["usage"]
      return nil unless usage

      input = usage["input_tokens"] || 0
      output = usage["output_tokens"] || 0

      {input: input, output: output, total: input + output}
    end

    def handle_error_response(http_response, status_code)
      handle_error_response_raw(http_response.body, status_code)
    end

    def handle_error_response_raw(body_string, status_code)
      message = begin
        body = JSON.parse(body_string)
        body.dig("error", "message") || body.dig("error", "type") || body_string
      rescue JSON::ParserError
        body_string
      end

      case status_code
      when 401
        raise AuthenticationError.new(
          "API authentication failed: #{message}",
          provider: :claude
        )
      when 403
        raise AuthenticationError.new(
          "API access forbidden: #{message}",
          provider: :claude
        )
      when 429
        raise RateLimitError.new(
          "API rate limit exceeded: #{message}",
          provider: :claude
        )
      when 400
        raise ProviderError.new("Bad request: #{message}")
      when 500, 502, 503, 529
        raise ProviderError.new("Server error (#{status_code}): #{message}")
      else
        raise ProviderError.new("HTTP #{status_code}: #{message}")
      end
    end

    def extract_headers(http_response)
      return {} unless http_response.respond_to?(:each_header)

      {}.tap do |headers|
        http_response.each_header do |name, value|
          headers[name] = value
        end
      end
    end

    def build_chat_chunk_callback(on_chunk, on_chat_chunk, observer)
      proc do |chunk|
        on_chunk&.call(chunk)
        on_chat_chunk&.call(chunk)
        observer.on_chat_chunk(chunk) if observer_responds_to?(observer, :on_chat_chunk)
      end
    end

    def process_content_block_start(payload, accumulated, &on_chunk)
      content_block = payload["content_block"] || {}

      case content_block["type"]
      when "text"
        emit_text_delta(content_block["text"], accumulated, &on_chunk)
      when "tool_use"
        index = payload["index"] || 0
        accumulated[:tool_calls][index] = {
          id: content_block["id"],
          name: content_block["name"],
          arguments: +"",
          structured_input: content_block["input"],
          saw_delta: false
        }
        on_chunk.call({
          type: :tool_call_start,
          id: content_block["id"],
          name: content_block["name"]
        })
      end
    end

    def process_content_block_delta(payload, accumulated, &on_chunk)
      delta = payload["delta"] || {}

      case delta["type"]
      when "text_delta"
        emit_text_delta(delta["text"], accumulated, &on_chunk)
      when "input_json_delta"
        index = payload["index"] || 0
        tool_call = accumulated[:tool_calls][index]
        return unless tool_call

        partial_json = delta["partial_json"]
        return if partial_json.nil? || partial_json.empty?

        tool_call[:saw_delta] = true
        tool_call[:arguments] << partial_json
        on_chunk.call({
          type: :tool_call_delta,
          id: tool_call[:id],
          arguments: partial_json
        })
      end
    end

    def process_content_block_stop(payload, accumulated, &on_chunk)
      index = payload["index"] || 0
      tool_call = accumulated[:tool_calls][index]
      return unless tool_call

      arguments = finalized_tool_call_arguments(tool_call)
      tool_call[:arguments] = arguments
      tool_call.delete(:structured_input)
      tool_call.delete(:saw_delta)

      on_chunk.call({
        type: :tool_call_complete,
        id: tool_call[:id],
        name: tool_call[:name],
        arguments: arguments
      })
    end

    def finalized_tool_call_arguments(tool_call)
      return tool_call[:arguments] if tool_call[:saw_delta]

      JSON.generate(tool_call[:structured_input] || {})
    end

    def observer_responds_to?(observer, method_name)
      observer&.respond_to?(method_name)
    end
  end
end
