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

    # @param api_key [String] Anthropic API key
    # @param logger [Logger, nil] optional logger
    def initialize(api_key:, logger: nil)
      @api_key = api_key
      @logger = logger
    end

    # Send a multi-turn chat completion request via the Anthropic Messages API.
    #
    # @param messages [Array<Hash>] conversation messages with :role and :content
    # @param tools [Array<Hash>, nil] tool definitions (Anthropic tool format)
    # @param stream [Boolean] whether to stream the response (not yet implemented)
    # @param max_tokens [Integer, nil] maximum tokens in the response
    # @param temperature [Float, nil] sampling temperature
    # @yield [Hash] streaming chunks when stream: true
    # @return [Response] the response
    def chat(messages:, tools: nil, stream: false, max_tokens: nil, temperature: nil, model: nil, &on_chunk)
      model ||= DEFAULT_MODEL
      timeout = DEFAULT_TIMEOUT
      max_tokens ||= DEFAULT_MAX_TOKENS

      uri = URI(ANTHROPIC_API_URL)

      system_messages = messages.select { |m| m[:role] == "system" || m["role"] == "system" }
      non_system = messages.reject { |m| m[:role] == "system" || m["role"] == "system" }

      body = {
        model: model,
        max_tokens: max_tokens,
        messages: non_system.map { |m| {role: m[:role] || m["role"], content: m[:content] || m["content"]} }
      }
      body[:system] = system_messages.map { |m| m[:content] || m["content"] }.join("\n") if system_messages.any?
      body[:tools] = tools if tools
      body[:temperature] = temperature if temperature

      start_time = Time.now
      http_response = make_request(uri, body, timeout: timeout)
      duration = Time.now - start_time

      parse_response(http_response, duration: duration, model: model)
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

      uri = URI(ANTHROPIC_API_URL)
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

    def make_request(uri, body, timeout:)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = [timeout, 30].min
      http.read_timeout = timeout

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["x-api-key"] = @api_key
      request["anthropic-version"] = ANTHROPIC_API_VERSION
      request.body = JSON.generate(body)

      @logger&.debug("[AgentHarness::TextTransport] POST #{uri} model=#{body[:model]}")

      http.request(request)
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise TimeoutError.new(e.message, original_error: e)
    rescue SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, IOError => e
      raise ProviderError.new("HTTP connection error: #{e.message}", original_error: e)
    end

    def parse_response(http_response, duration:, model:)
      status_code = http_response.code.to_i

      unless status_code == 200
        handle_error_response(http_response, status_code)
      end

      body = JSON.parse(http_response.body)
      output = extract_text_content(body)
      tokens = extract_tokens(body)

      Response.new(
        output: output,
        exit_code: 0,
        duration: duration,
        provider: :claude,
        model: body["model"] || model,
        tokens: tokens,
        metadata: {transport: :http}
      )
    rescue JSON::ParserError => e
      raise ProviderError.new(
        "Invalid JSON in API response: #{e.message}",
        original_error: e
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

    def extract_tokens(body)
      usage = body["usage"]
      return nil unless usage

      input = usage["input_tokens"] || 0
      output = usage["output_tokens"] || 0

      {input: input, output: output, total: input + output}
    end

    def handle_error_response(http_response, status_code)
      message = begin
        body = JSON.parse(http_response.body)
        body.dig("error", "message") || body.dig("error", "type") || http_response.body
      rescue JSON::ParserError
        http_response.body
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
  end
end
