# frozen_string_literal: true

require "json"
require "yaml"

module AgentHarness
  class McpConfigLoader
    ENV_VAR_PATTERN = /\$\{([A-Z0-9_]+)\}/

    class << self
      def load_file(path)
        parsed = parse_file(path)
        servers = parsed.is_a?(Hash) ? (parsed["servers"] || parsed[:servers] || parsed) : parsed

        unless servers.is_a?(Array)
          raise McpConfigurationError,
            "MCP config file must contain a top-level servers array"
        end

        servers.map do |server|
          McpServer.from_hash(interpolate_env(server))
        end
      end

      private

      def parse_file(path)
        ext = File.extname(path).downcase
        content = File.read(path)

        case ext
        when ".json"
          JSON.parse(content)
        when ".yml", ".yaml"
          YAML.safe_load(content, aliases: false) || {}
        else
          raise McpConfigurationError,
            "Unsupported MCP config file format '#{ext}'. Use .json, .yml, or .yaml"
        end
      rescue Errno::ENOENT => e
        raise McpConfigurationError, "MCP config file not found: #{e.message}"
      rescue JSON::ParserError, Psych::SyntaxError => e
        raise McpConfigurationError, "Failed to parse MCP config file: #{e.message}"
      end

      def interpolate_env(value)
        case value
        when Array
          value.map { |entry| interpolate_env(entry) }
        when Hash
          value.each_with_object({}) do |(key, entry), memo|
            memo[key] = interpolate_env(entry)
          end
        when String
          value.gsub(ENV_VAR_PATTERN) { ENV.fetch(Regexp.last_match(1), "") }
        else
          value
        end
      end
    end
  end
end
