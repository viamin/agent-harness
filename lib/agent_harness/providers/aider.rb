# frozen_string_literal: true

module AgentHarness
  module Providers
    # Aider AI coding assistant provider
    #
    # Provides integration with the Aider CLI tool.
    class Aider < Base
      UV_VERSION = "0.8.17"
      SUPPORTED_CLI_VERSION = "0.86.2"
      SUPPORTED_CLI_REQUIREMENT = Gem::Requirement.new(">= #{SUPPORTED_CLI_VERSION}", "< 0.87.0").freeze
      PYTHON_VERSION = "python3.12"
      BINARY_PATH = "/usr/local/bin/aider"
      UV_TOOL_ENV = {
        "UV_TOOL_BIN_DIR" => "/usr/local/bin",
        "UV_TOOL_DIR" => "/opt/uv/tools",
        "UV_PYTHON_INSTALL_DIR" => "/opt/uv/python"
      }.freeze

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

        def installation_contract(version: SUPPORTED_CLI_VERSION)
          parsed_version = begin
            Gem::Version.new(version)
          rescue ArgumentError
            raise ArgumentError,
              "Unsupported Aider CLI version #{version.inspect}; " \
              "supported versions must satisfy #{SUPPORTED_CLI_REQUIREMENT}"
          end

          unless SUPPORTED_CLI_REQUIREMENT.satisfied_by?(parsed_version)
            raise ArgumentError,
              "Unsupported Aider CLI version #{version.inspect}; " \
              "supported versions must satisfy #{SUPPORTED_CLI_REQUIREMENT}"
          end

          default_package = "aider-chat==#{version}".freeze
          bootstrap_command = [
            "python3", "-m", "pip", "install", "--no-cache-dir", "--break-system-packages", "uv==#{UV_VERSION}"
          ].freeze
          install_command_prefix = [
            "uv", "tool", "install", "--force", "--python", PYTHON_VERSION, "--with", "pip"
          ].freeze
          install_command = (install_command_prefix + [default_package]).freeze
          supported_versions = [version].freeze
          version_requirement = SUPPORTED_CLI_REQUIREMENT.requirements
            .map { |op, ver| "#{op} #{ver}".freeze }
            .freeze

          contract = {
            source: :uv_tool,
            bootstrap_source: :pip,
            bootstrap_package: "uv==#{UV_VERSION}",
            bootstrap_commands: [bootstrap_command].freeze,
            install_environment: UV_TOOL_ENV,
            package: default_package,
            package_name: "aider-chat",
            version: version,
            version_format: "%{package_name}==%{version}",
            version_requirement: version_requirement,
            binary_name: binary_name,
            binary_path: BINARY_PATH,
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
        "aider"
      end

      def display_name
        "Aider"
      end

      def configuration_schema
        {
          fields: [
            {
              name: :model,
              type: :string,
              label: "Model",
              required: false,
              hint: "Model identifier (supports OpenAI, Anthropic, and other model names)",
              accepts_arbitrary: true
            }
          ],
          auth_modes: [:api_key],
          openai_compatible: false
        }
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

      def error_patterns
        COMMON_ERROR_PATTERNS.merge(
          auth_expired: COMMON_ERROR_PATTERNS[:auth_expired] + [/incorrect.*api.*key/i],
          transient: COMMON_ERROR_PATTERNS[:transient] + [/connection.*reset/i]
        )
      end

      def execution_semantics
        {
          prompt_delivery: :flag,
          output_format: :text,
          sandbox_aware: false,
          uses_subcommand: false,
          non_interactive_flag: "--yes",
          legitimate_exit_codes: [0],
          stderr_is_diagnostic: true,
          parses_rate_limit_reset: false
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
