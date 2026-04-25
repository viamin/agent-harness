# frozen_string_literal: true

module AgentHarness
  # Canonical representation of an MCP server for request-time execution.
  #
  # Provider-agnostic value object that can be translated by each provider
  # adapter into its CLI-specific configuration.
  #
  # @example stdio server
  #   McpServer.new(
  #     name: "filesystem",
  #     transport: "stdio",
  #     command: ["npx", "-y", "@modelcontextprotocol/server-filesystem", "/workspace"],
  #     env: { "DEBUG" => "0" }
  #   )
  #
  # @example HTTP/URL server
  #   McpServer.new(
  #     name: "playwright",
  #     transport: "http",
  #     url: "http://mcp-playwright:3000/mcp"
  #   )
  class McpServer
    VALID_TRANSPORTS = %w[stdio http sse].freeze

    attr_reader :name, :transport, :command, :args, :env, :url

    # @param name [String] unique name for this MCP server
    # @param transport [String] one of "stdio", "http", "sse"
    # @param command [Array<String>, nil] command to launch (stdio only)
    # @param args [Array<String>, nil] additional args for the command
    # @param env [Hash<String,String>, nil] environment variables for the server process
    # @param url [String, nil] URL for HTTP/SSE transport
    def initialize(name:, transport:, command: nil, args: nil, env: nil, url: nil)
      @name = name
      @transport = transport.to_s
      @command = command
      @args = args || []
      @env = env || {}
      @url = url

      validate!
    end

    # Build from a plain Hash (e.g. from user input or serialized config)
    #
    # @param hash [Hash] server definition
    # @return [McpServer]
    def self.from_hash(hash)
      unless hash.is_a?(Hash)
        raise McpConfigurationError, "MCP server definition must be a Hash, got #{hash.class}"
      end

      begin
        hash = hash.transform_keys(&:to_sym)
      rescue NoMethodError, TypeError => e
        raise McpConfigurationError, "MCP server hash contains invalid keys: #{e.message}"
      end

      new(
        name: hash[:name],
        transport: hash[:transport],
        command: hash[:command],
        args: hash[:args],
        env: hash[:env],
        url: hash[:url]
      )
    end

    def stdio?
      @transport == "stdio"
    end

    def http?
      %w[http sse].include?(@transport)
    end

    # Check if the MCP server is reachable based on its transport type.
    #
    # For stdio servers, checks that a command is present.
    # For HTTP/SSE servers, checks that a URL is present and the server
    # responds to an HTTP HEAD request.
    #
    # @param timeout [Integer] HTTP request timeout in seconds (default: 5)
    # @return [Boolean]
    def reachable?(timeout: 5)
      case transport
      when "stdio"
        !command.nil? && !command.empty?
      when "http", "sse"
        !url.nil? && !url.to_s.strip.empty? && http_ping_ok?(timeout: timeout)
      else
        false
      end
    end

    def to_h
      h = {name: @name, transport: @transport}
      if stdio?
        h[:command] = @command
        h[:args] = @args unless @args.empty?
      else
        h[:url] = @url
      end
      h[:env] = @env unless @env.empty?
      h
    end

    private

    def validate!
      raise McpConfigurationError, "MCP server name is required" if @name.nil? || @name.to_s.strip.empty?

      unless VALID_TRANSPORTS.include?(@transport)
        raise McpConfigurationError,
          "Invalid MCP transport '#{@transport}' for server '#{@name}'. Valid transports: #{VALID_TRANSPORTS.join(", ")}"
      end

      validate_args!
      validate_env!
      validate_stdio! if stdio?
      validate_http! if http?
      validate_no_stdio_only_fields_on_http! if http?
    end

    def validate_args!
      return if @args.is_a?(Array) && @args.all? { |a| a.is_a?(String) }

      raise McpConfigurationError,
        "MCP server '#{@name}' args must be an Array of Strings"
    end

    def validate_env!
      return if @env.is_a?(Hash) && @env.keys.all? { |k| k.is_a?(String) } && @env.values.all? { |v| v.is_a?(String) }

      raise McpConfigurationError,
        "MCP server '#{@name}' env must be a Hash with String keys and values"
    end

    def validate_stdio!
      if @command.nil? || !@command.is_a?(Array) || @command.empty?
        raise McpConfigurationError,
          "MCP server '#{@name}' with stdio transport requires a non-empty command array"
      end

      unless @command.all? { |c| c.is_a?(String) }
        raise McpConfigurationError,
          "MCP server '#{@name}' command must contain only strings"
      end

      return if @url.nil?

      raise McpConfigurationError,
        "MCP server '#{@name}' with stdio transport should not have a url"
    end

    def validate_http!
      if @url.nil? || @url.to_s.strip.empty?
        raise McpConfigurationError,
          "MCP server '#{@name}' with #{@transport} transport requires a url"
      end

      return if @command.nil?

      raise McpConfigurationError,
        "MCP server '#{@name}' with #{@transport} transport should not have a command"
    end

    def validate_no_stdio_only_fields_on_http!
      return if @args.empty?

      raise McpConfigurationError,
        "MCP server '#{@name}' with #{@transport} transport should not have args (args are only valid for stdio)"
    end

    def http_ping_ok?(timeout: 5)
      require "net/http"
      uri = URI.parse(@url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = timeout
      http.read_timeout = timeout
      response = http.head(uri.request_uri)
      response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPRedirection)
    rescue
      false
    end
  end
end
