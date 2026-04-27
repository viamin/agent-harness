# frozen_string_literal: true

RSpec.describe AgentHarness::McpConfigTranslator do
  let(:stdio_server) do
    AgentHarness::McpServer.new(
      name: "filesystem",
      transport: "stdio",
      command: "npx",
      args: ["-y", "@modelcontextprotocol/server-filesystem", "/workspace"],
      env: {"DEBUG" => "0"}
    )
  end

  let(:sse_server) do
    AgentHarness::McpServer.new(
      name: "remote-db",
      transport: "sse",
      url: "https://mcp.example.com/db",
      headers: {"Authorization" => "Bearer secret"}
    )
  end

  describe ".for_provider" do
    it "translates Claude-compatible config" do
      translated = described_class.for_provider(:anthropic, [stdio_server, sse_server])

      expect(translated).to eq(
        mcpServers: {
          "filesystem" => {
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-filesystem", "/workspace"],
            env: {"DEBUG" => "0"}
          },
          "remote-db" => {
            url: "https://mcp.example.com/db",
            headers: {"Authorization" => "Bearer secret"}
          }
        }
      )
    end

    it "translates Codex config" do
      translated = described_class.for_provider(:codex, [stdio_server, sse_server])

      expect(translated).to eq(
        mcp_servers: {
          "filesystem" => {
            command: "npx",
            transport: "stdio",
            args: ["-y", "@modelcontextprotocol/server-filesystem", "/workspace"],
            env: {"DEBUG" => "0"}
          },
          "remote-db" => {
            url: "https://mcp.example.com/db",
            transport: "sse",
            headers: {"Authorization" => "Bearer secret"}
          }
        }
      )
    end

    it "translates OpenAI Responses API tools" do
      translated = described_class.for_provider(:openai, [sse_server])

      expect(translated).to eq([
        {
          type: "mcp",
          server_label: "remote-db",
          server_url: "https://mcp.example.com/db",
          authorization: "Bearer secret",
          require_approval: "never"
        }
      ])
    end

    it "rejects stdio servers for OpenAI" do
      expect {
        described_class.for_provider(:openai, [stdio_server])
      }.to raise_error(AgentHarness::McpTransportUnsupportedError, /only supports remote MCP servers/)
    end

    it "rejects unsupported OpenAI headers" do
      server = AgentHarness::McpServer.new(
        name: "remote-db",
        transport: "sse",
        url: "https://mcp.example.com/db",
        headers: {"X-Test" => "1"}
      )

      expect {
        described_class.for_provider(:openai, [server])
      }.to raise_error(AgentHarness::McpConfigurationError, /only supports the Authorization header/)
    end
  end
end
