# frozen_string_literal: true

module AgentHarness
  module Providers
    # Mistral Vibe CLI provider
    #
    # Provides integration with the Mistral Vibe CLI agent tool.
    class MistralVibe < Base
      class << self
        def provider_name
          :mistral_vibe
        end

        def binary_name
          "mistral-vibe"
        end

        def available?
          executor = AgentHarness.configuration.command_executor
          !!executor.which(binary_name)
        end

        def firewall_requirements
          {
            domains: [
              "api.mistral.ai"
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
        "mistral_vibe"
      end

      def display_name
        "Mistral Vibe CLI"
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
