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
      hash = hash.transform_keys(&:to_sym)
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

      validate_stdio! if stdio?
      validate_http! if http?
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
  end
end
