# frozen_string_literal: true

RSpec.describe AgentHarness::McpConfigLoader do
  around do |example|
    Dir.mktmpdir do |dir|
      @tmp_dir = dir
      example.run
    end
  end

  describe ".load_file" do
    it "loads YAML MCP config and interpolates env vars" do
      path = File.join(@tmp_dir, "mcp_servers.yml")
      File.write(path, <<~YAML)
        servers:
          - name: github
            transport: stdio
            command: npx
            args: ["-y", "@modelcontextprotocol/server-github"]
            env:
              GITHUB_TOKEN: ${GITHUB_TOKEN}
          - name: remote-db
            transport: sse
            url: https://mcp.example.com/db
            headers:
              Authorization: Bearer ${DB_TOKEN}
      YAML

      allow(ENV).to receive(:fetch).with("GITHUB_TOKEN", "").and_return("gh-token")
      allow(ENV).to receive(:fetch).with("DB_TOKEN", "").and_return("db-token")

      servers = described_class.load_file(path)

      expect(servers.map(&:name)).to eq(%w[github remote-db])
      expect(servers.first.command).to eq("npx")
      expect(servers.first.env).to eq({"GITHUB_TOKEN" => "gh-token"})
      expect(servers.last.headers).to eq({"Authorization" => "Bearer db-token"})
    end

    it "loads JSON MCP config" do
      path = File.join(@tmp_dir, "mcp_servers.json")
      File.write(path, JSON.generate({
        servers: [
          {
            name: "filesystem",
            transport: "stdio",
            command: "npx",
            args: ["server"]
          }
        ]
      }))

      servers = described_class.load_file(path)
      expect(servers.first.command_argv).to eq(["npx", "server"])
    end

    it "rejects invalid top-level structures" do
      path = File.join(@tmp_dir, "mcp_servers.yml")
      File.write(path, "name: invalid\n")

      expect {
        described_class.load_file(path)
      }.to raise_error(AgentHarness::McpConfigurationError, /top-level servers array/)
    end
  end
end
