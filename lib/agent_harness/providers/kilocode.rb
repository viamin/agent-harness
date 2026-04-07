# frozen_string_literal: true

module AgentHarness
  module Providers
    # Kilocode CLI provider
    #
    # Provides integration with the Kilocode CLI tool.
    class Kilocode < Base
      PACKAGE_NAME = "@kilocode/cli"
      DEFAULT_VERSION = "7.1.3"
      SUPPORTED_VERSION_REQUIREMENT = "= #{DEFAULT_VERSION}"

      class << self
        def provider_name
          :kilocode
        end

        def binary_name
          "kilo"
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

        def installation_contract(version: DEFAULT_VERSION)
          validate_install_version!(version)
          package_spec = "#{PACKAGE_NAME}@#{version}"

          {
            source: {
              type: :npm,
              package: PACKAGE_NAME
            },
            install_command: ["npm", "install", "-g", "--ignore-scripts", package_spec],
            binary_name: binary_name,
            default_version: DEFAULT_VERSION,
            supported_version_requirement: SUPPORTED_VERSION_REQUIREMENT
          }
        end

        def install_command(version: DEFAULT_VERSION)
          installation_contract(version: version)[:install_command]
        end

        def smoke_test_contract
          Base::DEFAULT_SMOKE_TEST_CONTRACT
        end

        private

        def validate_install_version!(version)
          requirement = Gem::Requirement.new(SUPPORTED_VERSION_REQUIREMENT)
          return if requirement.satisfied_by?(Gem::Version.new(version))

          raise ArgumentError,
            "Unsupported Kilocode CLI version #{version.inspect}; " \
            "supported versions must satisfy #{SUPPORTED_VERSION_REQUIREMENT}"
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
