# frozen_string_literal: true

require "json"

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

        runtime = options[:provider_runtime]
        if runtime
          cmd += runtime.flags unless runtime.flags.empty?
        end

        cmd << prompt
        cmd
      end

      def build_env(options)
        env = super
        runtime = options[:provider_runtime]
        return env unless runtime

        env["OPENAI_BASE_URL"] = runtime.base_url if runtime.base_url
        env
      end

      def build_execution_preparation(options)
        runtime = options[:provider_runtime]
        return nil unless runtime

        config_payload = opencode_config_payload(runtime)
        return nil unless config_payload

        ExecutionPreparation.new(
          file_writes: [
            {
              path: opencode_config_path(runtime),
              content: serialize_opencode_config(config_payload),
              mode: 0o600
            }
          ]
        )
      end

      def default_timeout
        300
      end

      private

      def opencode_config_payload(runtime)
        metadata = runtime.metadata
        metadata[:config] || metadata["config"]
      end

      def opencode_config_path(runtime)
        metadata = runtime.metadata
        metadata[:config_path] || metadata["config_path"] || "~/.config/opencode/opencode.json"
      end

      def serialize_opencode_config(payload)
        case payload
        when String
          payload
        when Hash
          JSON.pretty_generate(payload)
        else
          raise ArgumentError, "OpenCode runtime metadata config must be a String or Hash (got #{payload.class})"
        end
      end
    end
  end
end
