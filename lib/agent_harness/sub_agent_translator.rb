# frozen_string_literal: true

require "yaml"

module AgentHarness
  # Translates canonical sub-agent definitions into provider-specific formats.
  module SubAgentTranslator
    class << self
      def for_provider(provider, sub_agent_config, tool_registry: AgentHarness.configuration.tool_registry,
        mcp_servers: AgentHarness.configuration.mcp_servers)
        config = normalize_sub_agent_config(sub_agent_config)
        normalized_provider = normalize_provider(provider)
        tools = resolve_tools(config.tools, provider: normalized_provider, tool_registry: tool_registry)
        servers = resolve_mcp_servers(config.mcp_servers, mcp_servers: mcp_servers)

        case normalized_provider
        when :anthropic
          translate_for_anthropic(config, tools: tools, mcp_servers: servers)
        when :openai
          translate_for_openai(config, tools: tools, mcp_servers: servers)
        when :google
          translate_for_google(config, tools: tools, mcp_servers: servers)
        when :claude_code
          translate_for_claude_code(config, tools: tools, mcp_servers: servers)
        when :codex
          translate_for_codex(config, tools: tools, mcp_servers: servers)
        when :pi
          translate_for_pi(config, tools: tools, mcp_servers: servers)
        else
          translate_generic(normalized_provider, config, tools: tools, mcp_servers: servers)
        end
      end

      private

      def normalize_sub_agent_config(sub_agent_config)
        case sub_agent_config
        when SubAgentConfig
          sub_agent_config
        when Hash
          SubAgentConfig.from_hash(sub_agent_config)
        else
          raise ConfigurationError, "Sub-agent config must be a SubAgentConfig or Hash"
        end
      end

      def normalize_provider(provider)
        case provider.to_sym
        when :claude then :anthropic
        when :gemini then :google
        else provider.to_sym
        end
      end

      def resolve_tools(tool_refs, provider:, tool_registry:)
        tool_refs.map do |tool|
          case tool
          when Symbol, String
            mapping = tool_registry.fetch(tool).mapping_for(provider)
            mapping.nil? ? tool.to_s : mapping
          when Hash
            deep_dup(tool)
          else
            raise ConfigurationError, "Unsupported tool reference #{tool.inspect} in sub-agent definition"
          end
        end
      end

      def resolve_mcp_servers(server_refs, mcp_servers:)
        server_refs.map do |server|
          resolved = case server
          when McpServer
            server
          when Symbol, String
            mcp_servers.fetch(server.to_sym) do
              raise ConfigurationError, "Unknown MCP server: #{server}"
            end
          when Hash
            McpServer.from_hash(server)
          else
            raise ConfigurationError, "Unsupported MCP server reference #{server.inspect} in sub-agent definition"
          end

          resolved.to_h
        end
      end

      def translate_for_anthropic(config, tools:, mcp_servers:)
        {
          provider: :anthropic,
          format: :agent_sdk,
          agent: {
            name: config.name.to_s,
            description: config.description,
            instructions: config.instructions,
            model: config.model,
            tools: tools,
            mcp_servers: mcp_servers,
            constraints: deep_dup(config.constraints)
          },
          runtime_instructions: runtime_instructions(config)
        }
      end

      def translate_for_openai(config, tools:, mcp_servers:)
        {
          provider: :openai,
          format: :responses,
          assistant: {
            name: config.name.to_s,
            description: config.description,
            instructions: config.instructions,
            model: config.model,
            tools: tools,
            metadata: {
              mcp_servers: mcp_servers,
              constraints: deep_dup(config.constraints)
            }
          },
          runtime_instructions: runtime_instructions(config)
        }
      end

      def translate_for_google(config, tools:, mcp_servers:)
        {
          provider: :google,
          format: :adk,
          agent: {
            name: config.name.to_s,
            description: config.description,
            instruction: config.instructions,
            model: config.model,
            tools: tools,
            mcp_servers: mcp_servers,
            constraints: deep_dup(config.constraints)
          },
          runtime_instructions: runtime_instructions(config)
        }
      end

      def translate_for_claude_code(config, tools:, mcp_servers:)
        frontmatter = {
          "name" => config.name.to_s,
          "description" => config.description,
          "model" => config.model,
          "tools" => tools,
          "mcp_servers" => mcp_servers,
          "constraints" => deep_dup(config.constraints)
        }.delete_if { |_key, value| value.respond_to?(:empty?) ? value.empty? : value.nil? }

        {
          provider: :claude_code,
          format: :markdown,
          content: build_markdown_definition(frontmatter, config.instructions),
          runtime_instructions: runtime_instructions(config)
        }
      end

      def translate_for_codex(config, tools:, mcp_servers:)
        {
          provider: :codex,
          format: :delegated_prompt,
          definition: {
            name: config.name.to_s,
            description: config.description,
            instructions: config.instructions,
            model: config.model,
            tools: tools,
            mcp_servers: mcp_servers,
            constraints: deep_dup(config.constraints)
          },
          runtime_instructions: runtime_instructions(config)
        }
      end

      def translate_for_pi(config, tools:, mcp_servers:)
        frontmatter = {
          "name" => config.name.to_s,
          "description" => config.description,
          "model" => config.model,
          "tools" => tools,
          "mcp_servers" => mcp_servers
        }.delete_if { |_key, value| value.respond_to?(:empty?) ? value.empty? : value.nil? }

        {
          provider: :pi,
          format: :skill_markdown,
          content: build_markdown_definition(frontmatter, config.instructions),
          runtime_instructions: runtime_instructions(config)
        }
      end

      def translate_generic(provider, config, tools:, mcp_servers:)
        {
          provider: provider,
          format: :generic,
          definition: {
            name: config.name.to_s,
            description: config.description,
            instructions: config.instructions,
            model: config.model,
            tools: tools,
            mcp_servers: mcp_servers,
            constraints: deep_dup(config.constraints)
          },
          runtime_instructions: runtime_instructions(config)
        }
      end

      def runtime_instructions(config)
        <<~TEXT.strip
          Sub-agent role: #{config.name}
          Description: #{config.description}

          Follow these sub-agent instructions exactly:
          #{config.instructions}
        TEXT
      end

      def build_markdown_definition(frontmatter, instructions)
        <<~MARKDOWN
          ---
          #{YAML.dump(frontmatter).sub(/\A---\s*\n/, "").strip}
          ---
          #{instructions}
        MARKDOWN
      end

      def deep_dup(value)
        case value
        when Array
          value.map { |entry| deep_dup(entry) }
        when Hash
          value.each_with_object({}) { |(key, entry), copy| copy[key] = deep_dup(entry) }
        else
          value.dup
        end
      rescue TypeError
        value
      end
    end
  end
end
