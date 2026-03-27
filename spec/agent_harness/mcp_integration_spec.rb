# frozen_string_literal: true

RSpec.describe "MCP Server Integration" do
  describe "Anthropic provider with MCP servers" do
    let(:config) do
      AgentHarness::ProviderConfig.new(:claude).tap do |c|
        c.model = "claude-3-5-sonnet"
      end
    end

    let(:mock_executor) do
      instance_double(AgentHarness::CommandExecutor)
    end

    let(:provider) { AgentHarness::Providers::Anthropic.new(config: config, executor: mock_executor) }

    let(:success_result) do
      AgentHarness::CommandExecutor::Result.new(
        stdout: '{"result":"response","usage":{"input_tokens":10,"output_tokens":5}}',
        stderr: "",
        exit_code: 0,
        duration: 1.0
      )
    end

    context "with stdio MCP servers" do
      let(:mcp_servers) do
        [
          {
            name: "filesystem",
            transport: "stdio",
            command: ["npx", "-y", "@modelcontextprotocol/server-filesystem", "/workspace"],
            env: {"DEBUG" => "0"}
          }
        ]
      end

      it "includes --mcp-config flag in the command" do
        allow(mock_executor).to receive(:execute).and_return(success_result)

        expect(mock_executor).to receive(:execute).with(
          array_including("--mcp-config"),
          anything
        )

        provider.send_message(prompt: "Hello", mcp_servers: mcp_servers)
      end

      it "generates a valid MCP config file" do
        config_path = nil
        allow(mock_executor).to receive(:execute) do |cmd, **_opts|
          idx = cmd.index("--mcp-config")
          config_path = cmd[idx + 1] if idx
          success_result
        end

        provider.send_message(prompt: "Hello", mcp_servers: mcp_servers)

        expect(config_path).not_to be_nil
        config_content = JSON.parse(File.read(config_path))
        expect(config_content).to have_key("mcpServers")
        expect(config_content["mcpServers"]).to have_key("filesystem")

        fs_config = config_content["mcpServers"]["filesystem"]
        expect(fs_config["command"]).to eq("npx")
        expect(fs_config["args"]).to eq(["-y", "@modelcontextprotocol/server-filesystem", "/workspace"])
        expect(fs_config["env"]).to eq({"DEBUG" => "0"})
      end

      it "returns a successful response" do
        allow(mock_executor).to receive(:execute).and_return(success_result)

        response = provider.send_message(prompt: "Hello", mcp_servers: mcp_servers)
        expect(response).to be_a(AgentHarness::Response)
        expect(response.success?).to be true
      end
    end

    context "with HTTP MCP servers" do
      let(:mcp_servers) do
        [
          {
            name: "playwright",
            transport: "http",
            url: "http://mcp-playwright:3000/mcp"
          }
        ]
      end

      it "generates config with url for HTTP servers" do
        config_path = nil
        allow(mock_executor).to receive(:execute) do |cmd, **_opts|
          idx = cmd.index("--mcp-config")
          config_path = cmd[idx + 1] if idx
          success_result
        end

        provider.send_message(prompt: "Hello", mcp_servers: mcp_servers)

        expect(config_path).not_to be_nil
        config_content = JSON.parse(File.read(config_path))
        pw_config = config_content["mcpServers"]["playwright"]
        expect(pw_config["url"]).to eq("http://mcp-playwright:3000/mcp")
        expect(pw_config).not_to have_key("command")
      end
    end

    context "with mixed stdio and HTTP servers" do
      let(:mcp_servers) do
        [
          {
            name: "filesystem",
            transport: "stdio",
            command: ["npx", "-y", "@modelcontextprotocol/server-filesystem", "/workspace"]
          },
          {
            name: "playwright",
            transport: "http",
            url: "http://mcp-playwright:3000/mcp"
          }
        ]
      end

      it "includes both servers in config" do
        config_path = nil
        allow(mock_executor).to receive(:execute) do |cmd, **_opts|
          idx = cmd.index("--mcp-config")
          config_path = cmd[idx + 1] if idx
          success_result
        end

        provider.send_message(prompt: "Hello", mcp_servers: mcp_servers)

        config_content = JSON.parse(File.read(config_path))
        expect(config_content["mcpServers"].keys).to contain_exactly("filesystem", "playwright")
      end
    end

    context "with McpServer objects" do
      it "accepts McpServer instances directly" do
        servers = [
          AgentHarness::McpServer.new(
            name: "fs",
            transport: "stdio",
            command: ["npx", "server"]
          )
        ]

        allow(mock_executor).to receive(:execute).and_return(success_result)

        response = provider.send_message(prompt: "Hello", mcp_servers: servers)
        expect(response.success?).to be true
      end
    end

    context "without MCP servers" do
      it "does not include --mcp-config flag" do
        allow(mock_executor).to receive(:execute).and_return(success_result)

        expect(mock_executor).to receive(:execute).with(
          satisfy { |cmd| !cmd.include?("--mcp-config") },
          anything
        )

        provider.send_message(prompt: "Hello")
      end
    end
  end

  describe "unsupported provider with MCP servers" do
    let(:config) { AgentHarness::ProviderConfig.new(:codex) }
    let(:mock_executor) { instance_double(AgentHarness::CommandExecutor) }
    let(:provider) { AgentHarness::Providers::Codex.new(config: config, executor: mock_executor) }

    let(:mcp_servers) do
      [
        {
          name: "filesystem",
          transport: "stdio",
          command: ["npx", "server"]
        }
      ]
    end

    it "raises McpUnsupportedError" do
      expect {
        provider.send_message(prompt: "Hello", mcp_servers: mcp_servers)
      }.to raise_error(AgentHarness::McpUnsupportedError, /does not support MCP/)
    end

    it "includes provider name in error" do
      expect {
        provider.send_message(prompt: "Hello", mcp_servers: mcp_servers)
      }.to raise_error(AgentHarness::McpUnsupportedError) do |error|
        expect(error.provider).to eq(:codex)
      end
    end
  end

  describe "MCP validation in adapter" do
    let(:config) { AgentHarness::ProviderConfig.new(:claude) }
    let(:mock_executor) { instance_double(AgentHarness::CommandExecutor) }
    let(:provider) { AgentHarness::Providers::Anthropic.new(config: config, executor: mock_executor) }

    it "raises McpConfigurationError for invalid server hash" do
      expect {
        provider.send_message(prompt: "Hello", mcp_servers: [{name: "", transport: "stdio"}])
      }.to raise_error(AgentHarness::McpConfigurationError)
    end

    it "raises McpConfigurationError for non-hash/non-McpServer" do
      expect {
        provider.send_message(prompt: "Hello", mcp_servers: ["invalid"])
      }.to raise_error(AgentHarness::McpConfigurationError, /must be a Hash or McpServer/)
    end
  end

  describe "container execution compatibility" do
    let(:mcp_servers) do
      [
        AgentHarness::McpServer.new(
          name: "filesystem",
          transport: "stdio",
          command: ["npx", "-y", "@modelcontextprotocol/server-filesystem", "/workspace"]
        )
      ]
    end

    it "MCP servers serialize and deserialize through to_h / from_hash" do
      hashes = mcp_servers.map(&:to_h)
      restored = hashes.map { |h| AgentHarness::McpServer.from_hash(h) }

      expect(restored.first.name).to eq("filesystem")
      expect(restored.first.transport).to eq("stdio")
      expect(restored.first.command).to eq(["npx", "-y", "@modelcontextprotocol/server-filesystem", "/workspace"])
    end
  end
end
