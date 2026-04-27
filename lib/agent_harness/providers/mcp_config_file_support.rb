# frozen_string_literal: true

module AgentHarness
  module Providers
    # Shared concern for writing and cleaning up MCP configuration tempfiles.
    #
    # Include this module in any provider that needs to write MCP config files
    # for CLI processes. The including class must define an +mcp_provider_key+
    # method that returns the symbol passed to +McpConfigTranslator.for_provider+.
    module McpConfigFileSupport
      def write_mcp_config_file(mcp_servers, working_dir: nil)
        require "tempfile"
        require "tmpdir"
        require "securerandom"

        config = McpConfigTranslator.for_provider(mcp_provider_key, mcp_servers)
        config_json = JSON.generate(config)

        if @executor.is_a?(DockerCommandExecutor)
          # When running inside a Docker container, write the config file
          # inside the container so the CLI process can read it.
          # Track the path so cleanup_mcp_tempfiles! can remove it after execution.
          container_path = "/tmp/agent_harness_mcp_#{SecureRandom.hex(8)}.json"
          result = @executor.execute(
            ["sh", "-c", "cat > #{container_path}"],
            stdin_data: config_json,
            timeout: 5
          )
          unless result.success?
            raise McpConfigurationError,
              "Failed to write MCP config inside container: #{result.stderr}"
          end

          @mcp_docker_config_paths ||= []
          @mcp_docker_config_paths << container_path

          container_path
        else
          dir = working_dir || Dir.tmpdir
          file = Tempfile.new(["agent_harness_mcp_", ".json"], dir)
          file.write(config_json)
          file.close

          # Hold a reference so the Tempfile is not garbage-collected (and
          # therefore deleted) before the CLI process reads it.
          # Cleaned up by cleanup_mcp_tempfiles! after execution.
          @mcp_config_tempfiles ||= []
          @mcp_config_tempfiles << file

          file.path
        end
      end

      def cleanup_mcp_tempfiles!
        if @mcp_config_tempfiles
          @mcp_config_tempfiles.each do |file|
            file.close unless file.closed?
            file.unlink
          rescue
            nil
          end
          @mcp_config_tempfiles = nil
        end

        if @mcp_docker_config_paths
          @mcp_docker_config_paths.each do |path|
            @executor.execute(["rm", "-f", path], timeout: 5)
          rescue
            nil
          end
          @mcp_docker_config_paths = nil
        end
      end
    end
  end
end
