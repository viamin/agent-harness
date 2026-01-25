# frozen_string_literal: true

module AgentHarness
  module Providers
    # Aider AI coding assistant provider
    #
    # Provides integration with the Aider CLI tool.
    class Aider < Base
      class << self
        def provider_name
          :aider
        end

        def binary_name
          "aider"
        end

        def available?
          executor = AgentHarness.configuration.command_executor
          !!executor.which(binary_name)
        end

        def firewall_requirements
          {
            domains: [
              "api.openai.com",
              "api.anthropic.com"
            ],
            ip_ranges: []
          }
        end

        def instruction_file_paths
          [
            {
              path: ".aider.conf.yml",
              description: "Aider configuration file",
              symlink: false
            }
          ]
        end

        def discover_models
          return [] unless available?

          # Aider supports multiple model providers
          [
            {name: "gpt-4o", family: "gpt-4o", tier: "standard", provider: "aider"},
            {name: "claude-3-5-sonnet", family: "claude-3-5-sonnet", tier: "standard", provider: "aider"}
          ]
        end
      end

      def name
        "aider"
      end

      def display_name
        "Aider"
      end

      def capabilities
        {
          streaming: true,
          file_upload: true,
          vision: false,
          tool_use: true,
          json_mode: false,
          mcp: false,
          dangerous_mode: false
        }
      end

      def supports_sessions?
        true
      end

      def session_flags(session_id)
        return [] unless session_id && !session_id.empty?
        ["--restore-chat-history", session_id]
      end

      protected

      def build_command(prompt, options)
        cmd = [self.class.binary_name]

        # Run in non-interactive mode
        cmd << "--yes"

        if @config.model && !@config.model.empty?
          cmd += ["--model", @config.model]
        end

        if options[:session]
          cmd += session_flags(options[:session])
        end

        cmd += ["--message", prompt]

        cmd
      end

      def default_timeout
        600 # Aider can take longer
      end
    end
  end
end
