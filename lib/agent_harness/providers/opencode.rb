# frozen_string_literal: true

module AgentHarness
  module Providers
    # OpenCode CLI provider
    #
    # Provides integration with the OpenCode CLI tool.
    class Opencode < Base
      class << self
        def provider_name
          :opencode
        end

        def binary_name
          "opencode"
        end

        def available?
          executor = AgentHarness.configuration.command_executor
          !!executor.which(binary_name)
        end

        def firewall_requirements
          {
            domains: [
              "api.openai.com"
            ],
            ip_ranges: []
          }
        end

        def instruction_file_paths
          []
        end

        def discover_models
          return [] unless available?
          []
        end
      end

      def name
        "opencode"
      end

      def display_name
        "OpenCode CLI"
      end

      def configuration_schema
        {
          fields: [],
          auth_modes: [:api_key],
          openai_compatible: true
        }
      end

      def capabilities
        {
          streaming: false,
          file_upload: false,
          vision: false,
          tool_use: false,
          json_mode: false,
          mcp: false,
          dangerous_mode: false
        }
      end

      def error_patterns
        COMMON_ERROR_PATTERNS
      end

      def execution_semantics
        {
          prompt_delivery: :arg,
          output_format: :text,
          sandbox_aware: false,
          uses_subcommand: true,
          non_interactive_flag: nil,
          legitimate_exit_codes: [0],
          stderr_is_diagnostic: true,
          parses_rate_limit_reset: false
        }
      end

      protected

      def build_command(prompt, options)
        cmd = [self.class.binary_name, "run"]
        cmd << prompt
        cmd
      end

      def default_timeout
        300
      end
    end
  end
end
