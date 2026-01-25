# frozen_string_literal: true

module AgentHarness
  module Providers
    # Google Gemini CLI provider
    #
    # Provides integration with the Google Gemini CLI tool.
    class Gemini < Base
      # Model name pattern for Gemini models
      MODEL_PATTERN = /^gemini-[\d.]+-(?:pro|flash|ultra)(?:-\d+)?$/i

      class << self
        def provider_name
          :gemini
        end

        def binary_name
          "gemini"
        end

        def available?
          executor = AgentHarness.configuration.command_executor
          !!executor.which(binary_name)
        end

        def firewall_requirements
          {
            domains: [
              "generativelanguage.googleapis.com",
              "oauth2.googleapis.com",
              "accounts.google.com",
              "www.googleapis.com"
            ],
            ip_ranges: []
          }
        end

        def instruction_file_paths
          [
            {
              path: "GEMINI.md",
              description: "Google Gemini agent instructions",
              symlink: true
            }
          ]
        end

        def discover_models
          return [] unless available?

          # Gemini CLI doesn't have a standard model listing command
          # Return common models
          [
            {name: "gemini-2.0-flash", family: "gemini-2-0-flash", tier: "standard", provider: "gemini"},
            {name: "gemini-2.5-pro", family: "gemini-2-5-pro", tier: "advanced", provider: "gemini"},
            {name: "gemini-1.5-pro", family: "gemini-1-5-pro", tier: "standard", provider: "gemini"},
            {name: "gemini-1.5-flash", family: "gemini-1-5-flash", tier: "mini", provider: "gemini"}
          ]
        end

        def model_family(provider_model_name)
          # Strip version suffix: "gemini-1.5-pro-001" -> "gemini-1.5-pro"
          provider_model_name.sub(/-\d+$/, "")
        end

        def provider_model_name(family_name)
          family_name
        end

        def supports_model_family?(family_name)
          MODEL_PATTERN.match?(family_name) || family_name.start_with?("gemini-")
        end
      end

      def name
        "gemini"
      end

      def display_name
        "Google Gemini"
      end

      def capabilities
        {
          streaming: true,
          file_upload: true,
          vision: true,
          tool_use: true,
          json_mode: true,
          mcp: false,
          dangerous_mode: false
        }
      end

      def error_patterns
        {
          rate_limited: [
            /rate.?limit/i,
            /quota.?exceeded/i,
            /429/
          ],
          auth_expired: [
            /authentication/i,
            /unauthorized/i,
            /invalid.?credentials/i
          ],
          transient: [
            /timeout/i,
            /temporary/i,
            /503/
          ]
        }
      end

      protected

      def build_command(prompt, options)
        cmd = [self.class.binary_name]

        if @config.model && !@config.model.empty?
          cmd += ["--model", @config.model]
        end

        cmd += @config.default_flags if @config.default_flags&.any?

        cmd += ["--prompt", prompt]

        cmd
      end

      def default_timeout
        300
      end
    end
  end
end
