# frozen_string_literal: true

RSpec.describe AgentHarness::Providers::Cursor do
  describe ".provider_name" do
    it "returns :cursor" do
      expect(described_class.provider_name).to eq(:cursor)
    end
  end

  describe ".binary_name" do
    it "returns cursor-agent" do
      expect(described_class.binary_name).to eq("cursor-agent")
    end
  end

  describe ".firewall_requirements" do
    it "returns required domains" do
      requirements = described_class.firewall_requirements

      expect(requirements[:domains]).to include("cursor.com")
      expect(requirements[:domains]).to include("api.cursor.sh")
      expect(requirements[:domains]).to include("auth0.com")
      expect(requirements[:ip_ranges]).to eq([])
    end
  end

  describe ".instruction_file_paths" do
    it "returns .cursorrules" do
      paths = described_class.instruction_file_paths

      expect(paths.first[:path]).to eq(".cursorrules")
      expect(paths.first[:symlink]).to be true
    end
  end

  describe ".model_family" do
    it "converts dots to hyphens in version numbers" do
      expect(described_class.model_family("claude-3.5-sonnet")).to eq("claude-3-5-sonnet")
    end

    it "handles names without dots" do
      expect(described_class.model_family("gpt-4o")).to eq("gpt-4o")
    end
  end

  describe ".provider_model_name" do
    it "converts hyphens to dots in version numbers" do
      expect(described_class.provider_model_name("claude-3-5-sonnet")).to eq("claude-3.5-sonnet")
    end
  end

  describe ".supports_model_family?" do
    it "returns true for supported model families" do
      expect(described_class.supports_model_family?("claude-3-5-sonnet")).to be true
      expect(described_class.supports_model_family?("gpt-4o")).to be true
      expect(described_class.supports_model_family?("cursor-small")).to be true
    end

    it "returns false for unsupported model families" do
      expect(described_class.supports_model_family?("gemini-pro")).to be false
      expect(described_class.supports_model_family?("llama-3")).to be false
    end
  end

  describe ".available?" do
    let(:mock_executor) do
      instance_double(AgentHarness::CommandExecutor)
    end

    before do
      allow(AgentHarness.configuration).to receive(:command_executor).and_return(mock_executor)
    end

    it "returns true when cursor-agent binary exists" do
      allow(mock_executor).to receive(:which).with("cursor-agent").and_return("/usr/local/bin/cursor-agent")
      expect(described_class.available?).to be true
    end

    it "returns false when cursor-agent binary is missing" do
      allow(mock_executor).to receive(:which).with("cursor-agent").and_return(nil)
      expect(described_class.available?).to be false
    end
  end

  describe ".discover_models" do
    let(:mock_executor) do
      instance_double(AgentHarness::CommandExecutor)
    end

    before do
      allow(AgentHarness.configuration).to receive(:command_executor).and_return(mock_executor)
    end

    context "when cursor-agent is available" do
      before do
        allow(mock_executor).to receive(:which).with("cursor-agent").and_return("/usr/local/bin/cursor-agent")
      end

      it "returns predefined models" do
        models = described_class.discover_models
        expect(models.size).to eq(4)

        sonnet = models.find { |m| m[:name] == "claude-3.5-sonnet" }
        expect(sonnet[:family]).to eq("claude-3-5-sonnet")
        expect(sonnet[:tier]).to eq("standard")

        small = models.find { |m| m[:name] == "cursor-small" }
        expect(small[:tier]).to eq("mini")
      end
    end

    context "when cursor-agent is not available" do
      before do
        allow(mock_executor).to receive(:which).with("cursor-agent").and_return(nil)
      end

      it "returns empty array" do
        expect(described_class.discover_models).to eq([])
      end
    end
  end

  describe "instance" do
    let(:mock_executor) do
      instance_double(AgentHarness::CommandExecutor)
    end

    let(:config) do
      AgentHarness::ProviderConfig.new(:cursor).tap do |c|
        c.timeout = 120
      end
    end

    subject(:provider) { described_class.new(config: config, executor: mock_executor) }

    describe "#name" do
      it "returns cursor" do
        expect(provider.name).to eq("cursor")
      end
    end

    describe "#display_name" do
      it "returns Cursor AI" do
        expect(provider.display_name).to eq("Cursor AI")
      end
    end

    describe "#capabilities" do
      it "includes expected capabilities" do
        caps = provider.capabilities

        expect(caps[:mcp]).to be true
        expect(caps[:file_upload]).to be true
        expect(caps[:tool_use]).to be true
        expect(caps[:streaming]).to be false
        expect(caps[:vision]).to be false
        expect(caps[:json_mode]).to be false
        expect(caps[:dangerous_mode]).to be false
      end
    end

    describe "#supports_mcp?" do
      it "returns true" do
        expect(provider.supports_mcp?).to be true
      end
    end

    describe "#error_patterns" do
      it "includes rate limit patterns" do
        patterns = provider.error_patterns
        expect(patterns[:rate_limited]).not_to be_empty
      end

      it "includes auth patterns" do
        patterns = provider.error_patterns
        expect(patterns[:auth_expired]).not_to be_empty
      end

      it "includes transient patterns" do
        patterns = provider.error_patterns
        expect(patterns[:transient]).not_to be_empty
      end
    end

    describe "#send_message" do
      it "sends prompt via stdin" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        expect(mock_executor).to receive(:execute).with(
          ["cursor-agent", "-p"],
          hash_including(stdin_data: "Hello")
        )

        provider.send_message(prompt: "Hello")
      end

      it "returns a Response object" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response output",
            stderr: "",
            exit_code: 0,
            duration: 1.5
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response).to be_a(AgentHarness::Response)
        expect(response.output).to eq("response output")
        expect(response.provider).to eq(:cursor)
      end

      it "uses config timeout" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "ok",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        expect(mock_executor).to receive(:execute).with(
          anything,
          hash_including(timeout: 120)
        )

        provider.send_message(prompt: "Hello")
      end

      it "uses option timeout when provided" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "ok",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        expect(mock_executor).to receive(:execute).with(
          anything,
          hash_including(timeout: 60)
        )

        provider.send_message(prompt: "Hello", timeout: 60)
      end

      context "error handling" do
        it "raises RateLimitError for rate limit errors" do
          allow(mock_executor).to receive(:execute).and_raise(StandardError.new("rate limit exceeded"))
          expect { provider.send_message(prompt: "Hello") }.to raise_error(AgentHarness::RateLimitError)
        end

        it "raises AuthenticationError for auth errors" do
          allow(mock_executor).to receive(:execute).and_raise(StandardError.new("unauthorized"))
          expect { provider.send_message(prompt: "Hello") }.to raise_error(AgentHarness::AuthenticationError)
        end

        it "raises ProviderError for generic errors" do
          allow(mock_executor).to receive(:execute).and_raise(StandardError.new("something went wrong"))
          expect { provider.send_message(prompt: "Hello") }.to raise_error(AgentHarness::ProviderError)
        end
      end
    end

    describe "#fetch_mcp_servers" do
      before do
        allow(AgentHarness.configuration).to receive(:command_executor).and_return(mock_executor)
      end

      context "when CLI succeeds" do
        before do
          allow(mock_executor).to receive(:which).with("cursor-agent").and_return("/usr/local/bin/cursor-agent")
          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: "filesystem: ready\nmemory: disconnected",
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )
        end

        it "parses servers correctly" do
          servers = provider.fetch_mcp_servers
          expect(servers.size).to eq(2)

          fs_server = servers.find { |s| s[:name] == "filesystem" }
          expect(fs_server[:status]).to eq("ready")
          expect(fs_server[:enabled]).to be true

          mem_server = servers.find { |s| s[:name] == "memory" }
          expect(mem_server[:status]).to eq("disconnected")
          expect(mem_server[:enabled]).to be false
        end
      end

      context "when CLI fails and config file exists" do
        let(:mcp_config) do
          {
            "mcpServers" => {
              "filesystem" => {
                "command" => "npx",
                "args" => ["@modelcontextprotocol/server-filesystem"]
              }
            }
          }
        end

        before do
          allow(mock_executor).to receive(:which).with("cursor-agent").and_return(nil)
          allow(File).to receive(:exist?).and_call_original
          allow(File).to receive(:exist?).with(File.expand_path("~/.cursor/mcp.json")).and_return(true)
          allow(File).to receive(:read).with(File.expand_path("~/.cursor/mcp.json")).and_return(mcp_config.to_json)
        end

        it "falls back to config file" do
          servers = provider.fetch_mcp_servers
          expect(servers.size).to eq(1)
          expect(servers.first[:name]).to eq("filesystem")
          expect(servers.first[:source]).to eq("cursor_config")
        end
      end

      context "when both CLI and config fail" do
        before do
          allow(mock_executor).to receive(:which).with("cursor-agent").and_return(nil)
          allow(File).to receive(:exist?).and_call_original
          allow(File).to receive(:exist?).with(File.expand_path("~/.cursor/mcp.json")).and_return(false)
        end

        it "returns empty array" do
          expect(provider.fetch_mcp_servers).to eq([])
        end
      end

      context "when config file has invalid JSON" do
        before do
          allow(mock_executor).to receive(:which).with("cursor-agent").and_return(nil)
          allow(File).to receive(:exist?).and_call_original
          allow(File).to receive(:exist?).with(File.expand_path("~/.cursor/mcp.json")).and_return(true)
          allow(File).to receive(:read).with(File.expand_path("~/.cursor/mcp.json")).and_return("invalid json")
        end

        it "returns empty array" do
          expect(provider.fetch_mcp_servers).to eq([])
        end
      end
    end
  end
end
