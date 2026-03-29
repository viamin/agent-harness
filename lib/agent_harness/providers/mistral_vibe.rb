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

      def error_patterns
        {
          rate_limited: [
            /rate.?limit/i,
            /too.?many.?requests/i,
            /429/
          ],
          auth_expired: [
            /invalid.*api.*key/i,
            /unauthorized/i,
            /authentication/i
          ],
          quota_exceeded: [
            /quota.*exceeded/i,
            /insufficient.*quota/i,
            /billing/i
          ],
          transient: [
            /timeout/i,
            /connection.*error/i,
            /service.*unavailable/i,
            /503/,
            /502/
          ]
        }
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
