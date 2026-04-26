# frozen_string_literal: true

require "yaml"

module AgentHarness
  # Loads canonical sub-agent definitions from YAML or Markdown files.
  class SubAgentFileLoader
    class << self
      def load(path)
        case File.extname(path).downcase
        when ".yml", ".yaml"
          load_yaml(path)
        when ".md", ".markdown"
          [load_markdown(path)]
        else
          raise ConfigurationError, "Unsupported sub-agent definition format: #{path}"
        end
      end

      private

      def load_yaml(path)
        parsed = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
        unless parsed.is_a?(Hash)
          raise ConfigurationError, "YAML sub-agent definition must be a Hash"
        end

        agents = parsed["agents"] || parsed[:agents] || [parsed]
        unless agents.is_a?(Array)
          raise ConfigurationError, "YAML sub-agent definitions must provide an agents Array"
        end

        agents.map { |entry| SubAgentConfig.from_hash(entry) }
      rescue Psych::SyntaxError => e
        raise ConfigurationError, "Invalid YAML in #{path}: #{e.message}"
      end

      def load_markdown(path)
        content = File.read(path)
        match = content.match(/\A---\s*\n(?<frontmatter>.*?)\n---\s*\n?(?<body>.*)\z/m)
        raise ConfigurationError, "Markdown sub-agent definitions require YAML frontmatter" unless match

        attrs = YAML.safe_load(match[:frontmatter], permitted_classes: [], aliases: false) || {}
        unless attrs.is_a?(Hash)
          raise ConfigurationError, "Markdown frontmatter must be a Hash"
        end

        attrs["instructions"] ||= match[:body].strip
        SubAgentConfig.from_hash(attrs)
      rescue Psych::SyntaxError => e
        raise ConfigurationError, "Invalid frontmatter in #{path}: #{e.message}"
      end
    end
  end
end
