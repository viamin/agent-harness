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
        config_content = nil
        allow(mock_executor).to receive(:execute) do |cmd, **_opts|
          idx = cmd.index("--mcp-config")
          if idx
            config_content = JSON.parse(File.read(cmd[idx + 1]))
          end
          success_result
        end

        provider.send_message(prompt: "Hello", mcp_servers: mcp_servers)

        expect(config_content).not_to be_nil
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
        config_content = nil
        allow(mock_executor).to receive(:execute) do |cmd, **_opts|
          idx = cmd.index("--mcp-config")
          if idx
            config_content = JSON.parse(File.read(cmd[idx + 1]))
          end
          success_result
        end

        provider.send_message(prompt: "Hello", mcp_servers: mcp_servers)

        expect(config_content).not_to be_nil
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
        config_content = nil
        allow(mock_executor).to receive(:execute) do |cmd, **_opts|
          idx = cmd.index("--mcp-config")
          if idx
            config_content = JSON.parse(File.read(cmd[idx + 1]))
          end
          success_result
        end

        provider.send_message(prompt: "Hello", mcp_servers: mcp_servers)

        expect(config_content).not_to be_nil
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

    context "tempfile cleanup" do
      let(:mcp_servers) do
        [
          {
            name: "filesystem",
            transport: "stdio",
            command: ["npx", "server"]
          }
        ]
      end

      it "cleans up MCP config tempfiles after execution" do
        config_path = nil
        allow(mock_executor).to receive(:execute) do |cmd, **_opts|
          idx = cmd.index("--mcp-config")
          config_path = cmd[idx + 1] if idx
          success_result
        end

        provider.send_message(prompt: "Hello", mcp_servers: mcp_servers)

        expect(config_path).not_to be_nil
        expect(File.exist?(config_path)).to be false
      end

      it "cleans up tempfiles even when execution raises" do
        config_path = nil
        allow(mock_executor).to receive(:execute) do |cmd, **_opts|
          idx = cmd.index("--mcp-config")
          config_path = cmd[idx + 1] if idx
          raise StandardError, "execution failed"
        end

        expect {
          provider.send_message(prompt: "Hello", mcp_servers: mcp_servers)
        }.to raise_error(AgentHarness::ProviderError)

        expect(config_path).not_to be_nil
        expect(File.exist?(config_path)).to be false
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

    it "raises McpConfigurationError when mcp_servers is not an Array" do
      expect {
        provider.send_message(prompt: "Hello", mcp_servers: {name: "fs", transport: "stdio"})
      }.to raise_error(AgentHarness::McpConfigurationError, /mcp_servers must be an Array/)
    end

    it "raises McpConfigurationError for duplicate server names" do
      servers = [
        {name: "filesystem", transport: "stdio", command: ["npx", "server"]},
        {name: "filesystem", transport: "http", url: "http://localhost:3000/mcp"}
      ]
      expect {
        provider.send_message(prompt: "Hello", mcp_servers: servers)
      }.to raise_error(AgentHarness::McpConfigurationError, /Duplicate MCP server names.*filesystem/)
    end
  end

  describe "Cursor provider MCP validation" do
    let(:config) { AgentHarness::ProviderConfig.new(:cursor) }
    let(:mock_executor) { instance_double(AgentHarness::CommandExecutor) }
    let(:provider) { AgentHarness::Providers::Cursor.new(config: config, executor: mock_executor) }

    it "raises McpConfigurationError for non-array mcp_servers" do
      expect {
        provider.send_message(prompt: "Hello", mcp_servers: {name: "fs", transport: "stdio"})
      }.to raise_error(AgentHarness::McpConfigurationError, /mcp_servers must be an Array/)
    end

    it "raises McpConfigurationError for non-hash/non-McpServer elements" do
      expect {
        provider.send_message(prompt: "Hello", mcp_servers: ["invalid"])
      }.to raise_error(AgentHarness::McpConfigurationError, /must be a Hash or McpServer/)
    end

    it "raises McpUnsupportedError for request-time MCP servers (empty transports)" do
      mcp_servers = [
        {name: "fs", transport: "stdio", command: ["npx", "server"]}
      ]
      expect {
        provider.send_message(prompt: "Hello", mcp_servers: mcp_servers)
      }.to raise_error(AgentHarness::McpUnsupportedError, /does not support request-time MCP/)
    end
  end

  describe "Docker executor MCP config file" do
    let(:config) do
      AgentHarness::ProviderConfig.new(:claude).tap do |c|
        c.model = "claude-3-5-sonnet"
      end
    end

    let(:docker_executor) do
      instance_double(AgentHarness::DockerCommandExecutor)
    end

    let(:provider) { AgentHarness::Providers::Anthropic.new(config: config, executor: docker_executor) }

    let(:success_result) do
      AgentHarness::CommandExecutor::Result.new(
        stdout: '{"result":"response","usage":{"input_tokens":10,"output_tokens":5}}',
        stderr: "",
        exit_code: 0,
        duration: 1.0
      )
    end

    let(:write_result) do
      AgentHarness::CommandExecutor::Result.new(
        stdout: "",
        stderr: "",
        exit_code: 0,
        duration: 0.1
      )
    end

    let(:mcp_servers) do
      [
        {
          name: "filesystem",
          transport: "stdio",
          command: ["npx", "server"]
        }
      ]
    end

    it "writes config file inside the container" do
      allow(docker_executor).to receive(:is_a?).with(AgentHarness::DockerCommandExecutor).and_return(true)
      allow(docker_executor).to receive(:execute).and_return(success_result)

      expect(docker_executor).to receive(:execute).with(
        array_including("sh", "-c"),
        hash_including(stdin_data: a_string_including("mcpServers"), timeout: 5)
      ).and_return(write_result)

      provider.send_message(prompt: "Hello", mcp_servers: mcp_servers)
    end

    it "uses a container path for --mcp-config" do
      allow(docker_executor).to receive(:is_a?).with(AgentHarness::DockerCommandExecutor).and_return(true)

      config_path = nil
      call_count = 0
      allow(docker_executor).to receive(:execute) do |cmd, **_opts|
        call_count += 1
        if call_count == 1
          # First call is writing the config file
          write_result
        else
          # Second call is the actual command
          idx = cmd.index("--mcp-config")
          config_path = cmd[idx + 1] if idx
          success_result
        end
      end

      provider.send_message(prompt: "Hello", mcp_servers: mcp_servers)

      expect(config_path).to start_with("/tmp/agent_harness_mcp_")
      expect(config_path).to end_with(".json")
    end

    it "cleans up container config files after execution" do
      allow(docker_executor).to receive(:is_a?).with(AgentHarness::DockerCommandExecutor).and_return(true)

      container_path = nil
      call_count = 0
      allow(docker_executor).to receive(:execute) do |cmd, **_opts|
        call_count += 1
        if call_count == 1
          # First call: writing config file
          write_result
        elsif cmd.first == "rm"
          # Third call: cleanup
          container_path = cmd[2]
          write_result
        else
          # Second call: actual command
          success_result
        end
      end

      provider.send_message(prompt: "Hello", mcp_servers: mcp_servers)

      expect(container_path).to start_with("/tmp/agent_harness_mcp_")
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
