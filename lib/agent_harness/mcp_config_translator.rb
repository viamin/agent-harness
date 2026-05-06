# frozen_string_literal: true

module AgentHarness
  module McpConfigTranslator
    module_function

    def for_provider(provider, mcp_servers)
      servers = normalize_servers(mcp_servers)

      case provider.to_sym
      when :anthropic, :claude, :claude_code
        translate_for_claude(servers)
      when :github_copilot, :copilot
        translate_for_copilot(servers)
      when :codex
        translate_for_codex(servers)
      when :openai
        translate_for_openai(servers)
      else
        servers.map(&:to_h)
      end
    end

    def normalize_servers(mcp_servers)
      Array(mcp_servers).map do |server|
        case server
        when McpServer
          server
        when Hash
          McpServer.from_hash(server)
        else
          raise McpConfigurationError, "MCP server must be a Hash or McpServer, got #{server.class}"
        end
      end
    end

    def translate_for_claude(mcp_servers)
      {
        mcpServers: mcp_servers.each_with_object({}) do |server, memo|
          entry = server.stdio? ? {command: server.command} : {url: server.url}
          entry[:args] = server.args if server.stdio? && !server.args.empty?
          entry[:env] = server.env unless server.env.empty?
          entry[:headers] = server.headers if server.http? && !server.headers.empty?
          memo[server.name] = entry
        end
      }
    end

    def translate_for_codex(mcp_servers)
      {
        mcp_servers: mcp_servers.each_with_object({}) do |server, memo|
          entry = server.stdio? ? {command: server.command, transport: server.transport} : {url: server.url, transport: server.transport}
          entry[:args] = server.args if server.stdio? && !server.args.empty?
          entry[:env] = server.env unless server.env.empty?
          entry[:headers] = server.headers if server.http? && !server.headers.empty?
          memo[server.name] = entry
        end
      }
    end

    def translate_for_copilot(mcp_servers)
      {
        mcpServers: mcp_servers.each_with_object({}) do |server, memo|
          entry = if server.stdio?
            {
              type: "local",
              command: server.command,
              args: server.args,
              tools: ["*"]
            }
          else
            {
              type: server.transport,
              url: server.url,
              tools: ["*"]
            }
          end

          entry[:env] = server.env unless server.env.empty?
          entry[:headers] = server.headers if server.http? && !server.headers.empty?
          memo[server.name] = entry
        end
      }
    end

    def translate_for_openai(mcp_servers)
      mcp_servers.map do |server|
        unless server.http?
          raise McpTransportUnsupportedError.new(
            "Provider 'openai' only supports remote MCP servers over HTTP/SSE (server: '#{server.name}')",
            provider: :openai
          )
        end

        unsupported_headers = server.headers.keys - ["Authorization"]
        unless unsupported_headers.empty?
          raise McpConfigurationError,
            "OpenAI MCP translation only supports the Authorization header (server: '#{server.name}')"
        end

        tool = {
          type: "mcp",
          server_label: server.name,
          server_url: server.url,
          require_approval: "never"
        }
        tool[:authorization] = server.headers["Authorization"] if server.headers.key?("Authorization")
        tool
      end
    end
  end
end
