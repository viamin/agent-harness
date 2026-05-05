# frozen_string_literal: true

require "rubygems/requirement"

module AgentHarness
  module Providers
    # Pi coding agent CLI provider
    #
    # Provides integration with the Pi terminal coding agent.
    class Pi < Base
      CLI_PACKAGE = "@mariozechner/pi-coding-agent"
      SUPPORTED_CLI_VERSION = "0.73.0"
      SUPPORTED_CLI_REQUIREMENT = Gem::Requirement.new("= #{SUPPORTED_CLI_VERSION}").freeze

      class << self
        def provider_name
          :pi
        end

        def binary_name
          "pi"
        end

        def available?
          executor = AgentHarness.configuration.command_executor
          !!executor.which(binary_name)
        end

        def provider_metadata_overrides
          {
            auth: {
              service: :pi,
              api_family: :multi_provider
            }
          }
        end

        def firewall_requirements
          {
            domains: [
              "pi.dev"
            ],
            ip_ranges: []
          }
        end

        def instruction_file_paths
          [
            {
              path: "AGENTS.md",
              description: "Pi agent instructions",
              symlink: false
            },
            {
              path: "SYSTEM.md",
              description: "Pi system prompt override",
              symlink: false
            }
          ]
        end

        def discover_models
          return [] unless available?
          []
        end

        def installation_contract(version: SUPPORTED_CLI_VERSION)
          version = version.strip if version.respond_to?(:strip)

          unless version.is_a?(String) && !version.empty?
            raise ArgumentError,
              "Unsupported Pi CLI version #{version.inspect}; " \
              "supported versions must satisfy #{SUPPORTED_CLI_REQUIREMENT}"
          end

          parsed_version = begin
            Gem::Version.new(version)
          rescue ArgumentError
            raise ArgumentError,
              "Unsupported Pi CLI version #{version.inspect}; " \
              "supported versions must satisfy #{SUPPORTED_CLI_REQUIREMENT}"
          end

          unless SUPPORTED_CLI_REQUIREMENT.satisfied_by?(parsed_version)
            raise ArgumentError,
              "Unsupported Pi CLI version #{version.inspect}; " \
              "supported versions must satisfy #{SUPPORTED_CLI_REQUIREMENT}"
          end

          package = "#{CLI_PACKAGE}@#{version}".freeze
          install_command_prefix = ["npm", "install", "-g", "--ignore-scripts"].freeze
          install_command = (install_command_prefix + [package]).freeze
          supported_versions = [version].freeze
          version_requirement = SUPPORTED_CLI_REQUIREMENT.requirements
            .map { |op, ver| "#{op} #{ver}".freeze }
            .freeze

          contract = {
            source: :npm,
            package: package,
            package_name: CLI_PACKAGE,
            version: version,
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

        def smoke_test_contract
          Base::DEFAULT_SMOKE_TEST_CONTRACT
        end
      end

      def name
        "pi"
      end

      def display_name
        "Pi Coding Agent"
      end

      def configuration_schema
        {
          fields: [
            {
              name: :model,
              type: :string,
              label: "Model",
              required: false,
              hint: "Pi model pattern or ID passed to --model"
            },
            {
              name: :provider,
              type: :string,
              label: "Provider",
              required: false,
              hint: "Pi provider name passed to --provider"
            }
          ],
          auth_modes: %i[api_key oauth],
          openai_compatible: false
        }
      end

      def capabilities
        {
          streaming: false,
          file_upload: true,
          vision: true,
          tool_use: true,
          json_mode: false,
          mcp: false,
          dangerous_mode: false
        }
      end

      def error_patterns
        COMMON_ERROR_PATTERNS
      end

      def supports_tool_control?
        true
      end

      def auth_type
        :oauth
      end

      def execution_semantics
        {
          prompt_delivery: :flag,
          output_format: :text,
          sandbox_aware: false,
          uses_subcommand: false,
          non_interactive_flag: "-p",
          legitimate_exit_codes: [0],
          stderr_is_diagnostic: true,
          parses_rate_limit_reset: false
        }
      end

      protected

      def build_command(prompt, options)
        runtime = options[:provider_runtime]
        provider = normalized_runtime_value(runtime&.api_provider) || @config.provider
        model = normalized_runtime_value(runtime&.model) || @config.model

        cmd = [self.class.binary_name, "--no-session"]
        cmd += @config.default_flags if @config.default_flags&.any?
        cmd += runtime.flags if runtime
        cmd += ["--provider", provider] if provider
        cmd += ["--model", model] if model
        cmd << "--no-tools" if options[:tools] == :none
        cmd += ["-p", prompt]

        cmd
      end

      def default_timeout
        300
      end

      def normalized_runtime_value(value)
        return value unless value.respond_to?(:strip)

        normalized = value.strip
        normalized.empty? ? nil : normalized
      end
    end
  end
end
