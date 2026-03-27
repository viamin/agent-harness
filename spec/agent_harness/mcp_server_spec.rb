# frozen_string_literal: true

RSpec.describe AgentHarness::McpServer do
  describe "initialization" do
    context "with valid stdio config" do
      subject(:server) do
        described_class.new(
          name: "filesystem",
          transport: "stdio",
          command: ["npx", "-y", "@modelcontextprotocol/server-filesystem", "/workspace"],
          env: {"DEBUG" => "0"}
        )
      end

      it "sets all attributes" do
        expect(server.name).to eq("filesystem")
        expect(server.transport).to eq("stdio")
        expect(server.command).to eq(["npx", "-y", "@modelcontextprotocol/server-filesystem", "/workspace"])
        expect(server.env).to eq({"DEBUG" => "0"})
      end

      it "is stdio" do
        expect(server.stdio?).to be true
        expect(server.http?).to be false
      end

      it "defaults args to empty array" do
        expect(server.args).to eq([])
      end
    end

    context "with valid http config" do
      subject(:server) do
        described_class.new(
          name: "playwright",
          transport: "http",
          url: "http://mcp-playwright:3000/mcp"
        )
      end

      it "sets all attributes" do
        expect(server.name).to eq("playwright")
        expect(server.transport).to eq("http")
        expect(server.url).to eq("http://mcp-playwright:3000/mcp")
      end

      it "is http" do
        expect(server.http?).to be true
        expect(server.stdio?).to be false
      end
    end

    context "with valid sse config" do
      subject(:server) do
        described_class.new(
          name: "sse-server",
          transport: "sse",
          url: "http://localhost:8080/sse"
        )
      end

      it "treats sse as http" do
        expect(server.http?).to be true
        expect(server.stdio?).to be false
      end
    end

    context "with args" do
      subject(:server) do
        described_class.new(
          name: "test",
          transport: "stdio",
          command: ["node"],
          args: ["--inspect", "server.js"]
        )
      end

      it "stores args" do
        expect(server.args).to eq(["--inspect", "server.js"])
      end
    end
  end

  describe "validation" do
    it "raises on missing name" do
      expect {
        described_class.new(name: "", transport: "stdio", command: ["test"])
      }.to raise_error(AgentHarness::McpConfigurationError, /name is required/)
    end

    it "raises on nil name" do
      expect {
        described_class.new(name: nil, transport: "stdio", command: ["test"])
      }.to raise_error(AgentHarness::McpConfigurationError, /name is required/)
    end

    it "raises on invalid transport" do
      expect {
        described_class.new(name: "test", transport: "websocket", command: ["test"])
      }.to raise_error(AgentHarness::McpConfigurationError, /Invalid MCP transport 'websocket'/)
    end

    it "raises on stdio without command" do
      expect {
        described_class.new(name: "test", transport: "stdio")
      }.to raise_error(AgentHarness::McpConfigurationError, /requires a non-empty command array/)
    end

    it "raises on stdio with empty command" do
      expect {
        described_class.new(name: "test", transport: "stdio", command: [])
      }.to raise_error(AgentHarness::McpConfigurationError, /requires a non-empty command array/)
    end

    it "raises on stdio with non-string command elements" do
      expect {
        described_class.new(name: "test", transport: "stdio", command: [123])
      }.to raise_error(AgentHarness::McpConfigurationError, /command must contain only strings/)
    end

    it "raises on stdio with url" do
      expect {
        described_class.new(name: "test", transport: "stdio", command: ["test"], url: "http://x")
      }.to raise_error(AgentHarness::McpConfigurationError, /should not have a url/)
    end

    it "raises on http without url" do
      expect {
        described_class.new(name: "test", transport: "http")
      }.to raise_error(AgentHarness::McpConfigurationError, /requires a url/)
    end

    it "raises on http with command" do
      expect {
        described_class.new(name: "test", transport: "http", url: "http://x", command: ["test"])
      }.to raise_error(AgentHarness::McpConfigurationError, /should not have a command/)
    end

    it "raises when args are provided for http transport" do
      expect {
        described_class.new(name: "test", transport: "http", url: "http://x", args: ["--flag"])
      }.to raise_error(AgentHarness::McpConfigurationError, /should not have args/)
    end

    it "raises when args are provided for sse transport" do
      expect {
        described_class.new(name: "test", transport: "sse", url: "http://x", args: ["--flag"])
      }.to raise_error(AgentHarness::McpConfigurationError, /should not have args/)
    end

    it "raises when args is not an Array" do
      expect {
        described_class.new(name: "test", transport: "stdio", command: ["test"], args: "--flag")
      }.to raise_error(AgentHarness::McpConfigurationError, /args must be an Array of Strings/)
    end

    it "raises when args contains non-strings" do
      expect {
        described_class.new(name: "test", transport: "stdio", command: ["test"], args: [123])
      }.to raise_error(AgentHarness::McpConfigurationError, /args must be an Array of Strings/)
    end

    it "raises when env is not a Hash" do
      expect {
        described_class.new(name: "test", transport: "stdio", command: ["test"], env: "DEBUG=1")
      }.to raise_error(AgentHarness::McpConfigurationError, /env must be a Hash/)
    end

    it "raises when env has non-string values" do
      expect {
        described_class.new(name: "test", transport: "stdio", command: ["test"], env: {"DEBUG" => 1})
      }.to raise_error(AgentHarness::McpConfigurationError, /env must be a Hash with String keys and values/)
    end
  end

  describe ".from_hash" do
    it "builds from a string-keyed hash" do
      server = described_class.from_hash(
        "name" => "fs",
        "transport" => "stdio",
        "command" => ["npx", "server"],
        "env" => {"A" => "1"}
      )
      expect(server.name).to eq("fs")
      expect(server.transport).to eq("stdio")
      expect(server.command).to eq(["npx", "server"])
      expect(server.env).to eq({"A" => "1"})
    end

    it "builds from a symbol-keyed hash" do
      server = described_class.from_hash(
        name: "web",
        transport: "http",
        url: "http://localhost:3000"
      )
      expect(server.name).to eq("web")
      expect(server.url).to eq("http://localhost:3000")
    end

    it "raises McpConfigurationError for non-hash input" do
      expect {
        described_class.from_hash("not a hash")
      }.to raise_error(AgentHarness::McpConfigurationError, /must be a Hash/)
    end

    it "raises McpConfigurationError when keys cannot be symbolized" do
      expect {
        described_class.from_hash(123 => "value")
      }.to raise_error(AgentHarness::McpConfigurationError, /invalid keys/)
    end
  end

  describe "#to_h" do
    it "serializes stdio server" do
      server = described_class.new(
        name: "fs",
        transport: "stdio",
        command: ["npx", "server"],
        env: {"DEBUG" => "1"}
      )
      h = server.to_h
      expect(h[:name]).to eq("fs")
      expect(h[:transport]).to eq("stdio")
      expect(h[:command]).to eq(["npx", "server"])
      expect(h[:env]).to eq({"DEBUG" => "1"})
      expect(h).not_to have_key(:url)
    end

    it "serializes http server" do
      server = described_class.new(
        name: "web",
        transport: "http",
        url: "http://localhost:3000"
      )
      h = server.to_h
      expect(h[:name]).to eq("web")
      expect(h[:transport]).to eq("http")
      expect(h[:url]).to eq("http://localhost:3000")
      expect(h).not_to have_key(:command)
    end

    it "omits empty env and args" do
      server = described_class.new(
        name: "fs",
        transport: "stdio",
        command: ["npx", "server"]
      )
      h = server.to_h
      expect(h).not_to have_key(:env)
      expect(h).not_to have_key(:args)
    end
  end
end
