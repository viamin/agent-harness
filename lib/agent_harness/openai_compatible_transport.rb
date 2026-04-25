# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module AgentHarness
  # OpenAI-compatible HTTP transport for multi-turn chat completions.
  #
  # Supports any endpoint that implements the OpenAI chat completions API,
  # including OpenAI, GitHub Models, OpenRouter, and other compatible services.
  #
  # @example Non-streaming
  #   transport = AgentHarness::OpenAICompatibleTransport.new(
  #     base_url: "https://api.openai.com/v1",
  #     api_key: "sk-...",
  #     model: "gpt-4o"
  #   )
  #   response = transport.chat(messages: [{ role: "user", content: "Hello" }])
  #
  # @example Streaming
  #   transport.chat(messages: msgs, stream: true) do |chunk|
  #     case chunk[:type]
  #     when :text    then print chunk[:content]
  #     when :done    then puts "\nTokens: #{chunk[:usage]}"
  #     end
  #   end
  class OpenAICompatibleTransport
    DEFAULT_TIMEOUT = 300
    DEFAULT_MAX_TOKENS = 4096
    USER_AGENT = "AgentHarness/1.0"

    # @param base_url [String] API base URL (e.g. "https://api.openai.com/v1")
    # @param api_key [String] bearer token for authentication
    # @param model [String] default model identifier
    # @param logger [Logger, nil] optional logger
    def initialize(base_url:, api_key:, model:, logger: nil)
      @base_url = base_url.chomp("/")
      @api_key = api_key
      @model = model
      @logger = logger
    end

    # Send a chat completion request.
    #
    # @param messages [Array<Hash>] conversation messages
    # @param tools [Array<Hash>, nil] tool/function definitions
    # @param stream [Boolean] whether to stream the response
    # @param max_tokens [Integer, nil] maximum tokens in the response
    # @param temperature [Float, nil] sampling temperature
    # @yield [Hash] streaming chunks when stream: true
    # @return [Response] the response
    # @raise [AuthenticationError] on 401/403 responses
    # @raise [RateLimitError] on 429 responses
    # @raise [TimeoutError] on network timeouts
    # @raise [ProviderError] on other HTTP errors
    # Send a chat completion request.
    #
    # Streaming chunks can be received via block, +on_chat_chunk+ proc,
    # or an observer that responds to +on_chat_chunk+. When multiple
    # receivers are provided, all receive every event.
    #
    # @param messages [Array<Hash>] conversation messages
    # @param tools [Array<Hash>, nil] tool/function definitions
    # @param stream [Boolean] whether to stream the response
    # @param max_tokens [Integer, nil] maximum tokens in the response
    # @param temperature [Float, nil] sampling temperature
    # @param on_chat_chunk [Proc, nil] callback for structured streaming events
    # @param observer [#on_chat_chunk, nil] observer receiving streaming events
    # @yield [Hash] streaming chunks when stream: true
    # @return [Response] the response
    # @raise [AuthenticationError] on 401/403 responses
    # @raise [RateLimitError] on 429 responses
    # @raise [TimeoutError] on network timeouts
    # @raise [ProviderError] on other HTTP errors
    def chat(messages:, tools: nil, stream: false, max_tokens: nil, temperature: nil,
      on_chat_chunk: nil, observer: nil, &on_chunk)
      max_tokens ||= DEFAULT_MAX_TOKENS
      uri = URI("#{@base_url}/chat/completions")

      body = build_request_body(
        messages: messages, tools: tools, stream: stream,
        max_tokens: max_tokens, temperature: temperature
      )

      start_time = Time.now

      has_stream_receiver = on_chunk || on_chat_chunk || observer_responds_to?(observer, :on_chat_chunk)

      if stream && has_stream_receiver
        combined = build_chat_chunk_callback(on_chunk, on_chat_chunk, observer)
        result = make_streaming_request(uri, body, &combined)
        duration = Time.now - start_time
        build_streaming_response(result, duration: duration)
      else
        http_response = make_request(uri, body)
        duration = Time.now - start_time
        parse_response(http_response, duration: duration)
      end
    end

    private

    def build_request_body(messages:, tools:, stream:, max_tokens:, temperature:)
      body = {
        model: @model,
        max_tokens: max_tokens,
        messages: messages
      }
      body[:temperature] = temperature if temperature
      body[:tools] = tools if tools
      body[:stream] = true if stream
      body[:stream_options] = {include_usage: true} if stream
      body
    end

    def make_request(uri, body)
      http = build_http(uri)
      request = build_post_request(uri, body)

      @logger&.debug("[AgentHarness::OpenAICompatibleTransport] POST #{uri} model=#{body[:model]}")

      http.request(request)
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise TimeoutError.new(e.message, original_error: e)
    rescue SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, IOError => e
      raise ProviderError.new("HTTP connection error: #{e.message}", original_error: e)
    end

    def make_streaming_request(uri, body, &on_chunk)
      http = build_http(uri)
      request = build_post_request(uri, body)

      @logger&.debug("[AgentHarness::OpenAICompatibleTransport] POST #{uri} model=#{body[:model]} stream=true")

      accumulated = {content: +"", tool_calls: [], model: nil, usage: nil}

      http.request(request) do |http_response|
        status_code = http_response.code.to_i
        unless status_code == 200
          response_body = http_response.read_body
          handle_error_response_raw(response_body, status_code)
        end

        parse_sse_stream(http_response, accumulated, &on_chunk)
      end

      accumulated
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise TimeoutError.new(e.message, original_error: e)
    rescue SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, IOError => e
      raise ProviderError.new("HTTP connection error: #{e.message}", original_error: e)
    end

    def parse_sse_stream(http_response, accumulated, &on_chunk)
      buffer = +""

      http_response.read_body do |chunk|
        buffer << chunk
        while (line_end = buffer.index("\n"))
          line = buffer.slice!(0, line_end + 1).strip
          next if line.empty?
          next unless line.start_with?("data: ")

          data = line[6..]
          next if data == "[DONE]"

          begin
            event = JSON.parse(data)
          rescue JSON::ParserError => e
            @logger&.warn("[AgentHarness::OpenAICompatibleTransport] Skipping malformed SSE event: #{e.message}")
            next
          end
          process_stream_event(event, accumulated, &on_chunk)
        end
      end
    end

    def process_stream_event(event, accumulated, &on_chunk)
      accumulated[:model] ||= event["model"]

      if event["usage"]
        usage = extract_usage(event)
        accumulated[:usage] = usage
        on_chunk.call({type: :usage, input_tokens: usage[:input], output_tokens: usage[:output]})
        on_chunk.call({type: :done})
        return
      end

      choice = event.dig("choices", 0)
      return unless choice

      delta = choice["delta"] || {}

      if delta["content"]
        accumulated[:content] << delta["content"]
        on_chunk.call({type: :text, content: delta["content"]})
      end

      process_tool_call_delta(delta, accumulated, &on_chunk)

      emit_tool_call_completions(choice, accumulated, &on_chunk)
    end

    def process_tool_call_delta(delta, accumulated, &on_chunk)
      return unless delta["tool_calls"]

      delta["tool_calls"].each do |tc_delta|
        index = tc_delta["index"] || 0

        if tc_delta["id"]
          accumulated[:tool_calls][index] = {
            id: tc_delta["id"],
            name: tc_delta.dig("function", "name") || "",
            arguments: +""
          }
        end

        tc = accumulated[:tool_calls][index]
        next unless tc

        if tc_delta.dig("function", "arguments")
          tc[:arguments] << tc_delta.dig("function", "arguments")
        end

        if tc_delta["id"]
          on_chunk.call({
            type: :tool_call_start,
            id: tc_delta["id"],
            name: tc_delta.dig("function", "name") || ""
          })
        elsif tc_delta.dig("function", "arguments")
          on_chunk.call({
            type: :tool_call_delta,
            id: tc[:id],
            arguments: tc_delta.dig("function", "arguments")
          })
        end
      end
    end

    def emit_tool_call_completions(choice, accumulated, &on_chunk)
      return unless choice["finish_reason"] == "tool_calls"

      accumulated[:tool_calls].each do |tc|
        next unless tc

        on_chunk.call({
          type: :tool_call_complete,
          id: tc[:id],
          name: tc[:name],
          arguments: tc[:arguments]
        })
      end
    end

    def build_http(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = [DEFAULT_TIMEOUT, 30].min
      http.read_timeout = DEFAULT_TIMEOUT
      http
    end

    def build_post_request(uri, body)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{@api_key}"
      request["User-Agent"] = USER_AGENT
      request.body = JSON.generate(body)
      request
    end

    def parse_response(http_response, duration:)
      status_code = http_response.code.to_i

      unless status_code == 200
        handle_error_response(http_response, status_code)
      end

      body = JSON.parse(http_response.body)
      output = extract_content(body)
      tokens = extract_usage(body)
      tool_calls = extract_tool_calls(body)

      metadata = {transport: :http, stream: false}
      metadata[:tool_calls] = tool_calls if tool_calls

      Response.new(
        output: output,
        exit_code: 0,
        duration: duration,
        provider: :openai_compatible,
        model: body["model"] || @model,
        tokens: tokens,
        metadata: metadata
      )
    rescue JSON::ParserError => e
      raise ProviderError.new(
        "Invalid JSON in API response: #{e.message}",
        original_error: e
      )
    end

    def build_streaming_response(accumulated, duration:)
      tool_calls = accumulated[:tool_calls].compact
      metadata = {transport: :http, stream: true}
      metadata[:tool_calls] = tool_calls unless tool_calls.empty?

      Response.new(
        output: accumulated[:content],
        exit_code: 0,
        duration: duration,
        provider: :openai_compatible,
        model: accumulated[:model] || @model,
        tokens: accumulated[:usage],
        metadata: metadata
      )
    end

    def extract_content(body)
      choice = body.dig("choices", 0)
      return "" unless choice

      choice.dig("message", "content") || ""
    end

    def extract_usage(body)
      usage = body["usage"]
      return nil unless usage

      input = usage["prompt_tokens"] || 0
      output = usage["completion_tokens"] || 0

      {input: input, output: output, total: input + output}
    end

    def extract_tool_calls(body)
      tool_calls = body.dig("choices", 0, "message", "tool_calls")
      return nil unless tool_calls&.any?

      tool_calls.map do |tc|
        {
          id: tc["id"],
          name: tc.dig("function", "name"),
          arguments: tc.dig("function", "arguments")
        }
      end
    end

    def build_chat_chunk_callback(on_chunk, on_chat_chunk, observer)
      proc do |chunk|
        on_chunk&.call(chunk)
        on_chat_chunk&.call(chunk)
        observer.on_chat_chunk(chunk) if observer_responds_to?(observer, :on_chat_chunk)
      end
    end

    def observer_responds_to?(observer, method_name)
      observer&.respond_to?(method_name)
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
          provider: :openai_compatible
        )
      when 403
        raise AuthenticationError.new(
          "API access forbidden: #{message}",
          provider: :openai_compatible
        )
      when 429
        raise RateLimitError.new(
          "API rate limit exceeded: #{message}",
          provider: :openai_compatible
        )
      when 400
        raise ProviderError.new("Bad request: #{message}")
      when 500, 502, 503
        raise ProviderError.new("Server error (#{status_code}): #{message}")
      else
        raise ProviderError.new("HTTP #{status_code}: #{message}")
      end
    end
  end
end
