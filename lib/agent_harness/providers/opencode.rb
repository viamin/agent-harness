# frozen_string_literal: true

module AgentHarness
  module Providers
    # OpenCode CLI provider
    #
    # Provides integration with the OpenCode CLI tool.
    class Opencode < Base
      CLI_PACKAGE = "opencode-ai"
      SUPPORTED_CLI_VERSION = "1.3.2"
      SUPPORTED_CLI_REQUIREMENT = Gem::Requirement.new(">= #{SUPPORTED_CLI_VERSION}", "< 1.4.0").freeze

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

        def installation_contract(version: SUPPORTED_CLI_VERSION)
          normalized_version = normalize_install_version(version)

          default_package = "#{CLI_PACKAGE}@#{normalized_version}".freeze
          install_command_prefix = ["npm", "install", "-g", "--ignore-scripts"].freeze
          install_command = (install_command_prefix + [default_package]).freeze
          supported_versions = [SUPPORTED_CLI_VERSION].freeze
          version_requirement = SUPPORTED_CLI_REQUIREMENT.requirements
            .map { |op, ver| "#{op} #{ver}".freeze }
            .freeze

          contract = {
            source: :npm,
            package: default_package,
            package_name: CLI_PACKAGE,
            version: normalized_version,
            version_requirement: version_requirement,
            binary_name: binary_name,
            install_command_prefix: install_command_prefix,
            install_command: install_command,
            supported_versions: supported_versions
          }

          contract.each_value do |value|
            value.freeze if value.is_a?(String)
          end
          contract.freeze
        end

        def install_command(version: SUPPORTED_CLI_VERSION)
          installation_contract(version: version)[:install_command]
        end

        private

        def normalize_install_version(version)
          raise ArgumentError, unsupported_version_message(version) unless version.is_a?(String) && !version.strip.empty?

          normalized_version = version.strip
          parsed_version = Gem::Version.new(normalized_version)
          return normalized_version if SUPPORTED_CLI_REQUIREMENT.satisfied_by?(parsed_version)

          raise ArgumentError, unsupported_version_message(version)
        rescue ArgumentError
          raise ArgumentError, unsupported_version_message(version)
        end

        def unsupported_version_message(version)
          "Unsupported OpenCode CLI version #{version.inspect}; " \
            "supported versions must satisfy #{SUPPORTED_CLI_REQUIREMENT}"
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
        cmd = [self.class.installation_contract[:binary_name], "run"]

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

      def default_timeout
        300
      end
    end
  end
end
