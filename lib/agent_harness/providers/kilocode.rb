# frozen_string_literal: true

module AgentHarness
  module Providers
    # Kilocode CLI provider
    #
    # Provides integration with the Kilocode CLI tool.
    class Kilocode < Base
      class << self
        def provider_name
          :kilocode
        end

        def binary_name
          "kilocode"
        end

        def available?
          executor = AgentHarness.configuration.command_executor
          !!executor.which(binary_name)
        end

        def firewall_requirements
          {
            domains: [],
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
        "kilocode"
      end

      def display_name
        "Kilocode CLI"
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

      protected

      def build_command(prompt, options)
        cmd = [self.class.binary_name]
        cmd += ["--prompt", prompt]
        cmd
      end

      def default_timeout
        300
      end
    end
  end
end
