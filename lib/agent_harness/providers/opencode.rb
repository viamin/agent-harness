# frozen_string_literal: true

require "json"
require "shellwords"

module AgentHarness
  module Providers
    # OpenCode CLI provider
    #
    # Provides integration with the OpenCode CLI tool.
    class Opencode < Base
      CLI_PACKAGE = "opencode-ai"
      SUPPORTED_CLI_VERSION = "1.3.2"
      SUPPORTED_CLI_REQUIREMENT = Gem::Requirement.new(">= #{SUPPORTED_CLI_VERSION}", "< 1.4.0").freeze
      INSTALL_COMMAND_PREFIX = ["npm", "install", "-g", "--ignore-scripts"].freeze
      SUPPORTED_CLI_VERSIONS = [SUPPORTED_CLI_VERSION].freeze
      VERSION_REQUIREMENT_STRINGS = SUPPORTED_CLI_REQUIREMENT.requirements
        .map { |op, ver| "#{op} #{ver}".freeze }
        .freeze

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

        def provider_metadata_overrides
          {
            auth: {
              service: :openai,
              api_family: :openai_compatible
            }
          }
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
          return DEFAULT_INSTALLATION_CONTRACT if normalized_version == SUPPORTED_CLI_VERSION

          build_installation_contract(normalized_version)
        end

        def install_command(version: SUPPORTED_CLI_VERSION)
          installation_contract(version: version)[:install_command]
        end

        def smoke_test_contract
          Base::DEFAULT_SMOKE_TEST_CONTRACT
        end

        private

        def build_installation_contract(version)
          package = "#{CLI_PACKAGE}@#{version}".freeze
          install_command = (INSTALL_COMMAND_PREFIX + [package]).freeze

          contract = {
            source: :npm,
            package: package,
            package_name: CLI_PACKAGE,
            version: version,
            version_requirement: VERSION_REQUIREMENT_STRINGS,
            binary_name: binary_name,
            install_command_prefix: INSTALL_COMMAND_PREFIX,
            install_command: install_command,
            supported_versions: SUPPORTED_CLI_VERSIONS
          }

          contract.each_value do |value|
            value.freeze if value.is_a?(String)
          end
          contract.freeze
        end

        def normalize_install_version(version)
          raise ArgumentError, unsupported_version_message(version) unless version.is_a?(String) && !version.strip.empty?

          normalized_version = version.strip
          parsed_version = begin
            Gem::Version.new(normalized_version)
          rescue ArgumentError
            raise ArgumentError, unsupported_version_message(version)
          end
          return normalized_version if SUPPORTED_CLI_REQUIREMENT.satisfied_by?(parsed_version)

          raise ArgumentError, unsupported_version_message(version)
        end

        def unsupported_version_message(version)
          "Unsupported OpenCode CLI version #{version.inspect}; " \
            "supported versions must satisfy #{SUPPORTED_CLI_REQUIREMENT}"
        end
      end

      DEFAULT_INSTALLATION_CONTRACT = build_installation_contract(SUPPORTED_CLI_VERSION)

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

      def supports_activity_heartbeat?
        true
      end

      def heartbeat_integration(heartbeat_file_path:)
        unless heartbeat_file_path.is_a?(String) && !heartbeat_file_path.strip.empty?
          raise ArgumentError, "heartbeat_file_path must be a non-empty String"
        end
        unless heartbeat_file_path.start_with?("/")
          raise ArgumentError, "heartbeat_file_path must be an absolute path (got #{heartbeat_file_path.inspect})"
        end

        hook_script = heartbeat_hook_script(heartbeat_file_path)
        config_payload = merge_heartbeat_hooks(hook_script)

        preparation = ExecutionPreparation.new(
          file_writes: [
            {
              path: heartbeat_hook_config_path,
              content: serialize_opencode_config(config_payload),
              mode: 0o600
            }
          ]
        )

        {
          supported: true,
          env: {"OPENCODE_HEARTBEAT_FILE" => heartbeat_file_path},
          preparation: preparation,
          granularity: :tool_call
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
          parses_rate_limit_reset: true
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
        config_extras = metadata[:config] || metadata["config"] || {}
        unless config_extras.is_a?(Hash)
          raise ArgumentError, "OpenCode runtime metadata config must be a Hash of provider-specific extras (got #{config_extras.class})"
        end

        payload = stringify_keys(config_extras)
        payload["model"] = runtime.model if runtime.model
        payload["provider"] = runtime.api_provider if runtime.api_provider
        payload["baseURL"] = runtime.base_url if runtime.base_url
        payload.empty? ? nil : payload
      end

      def opencode_config_path(_runtime)
        "~/.config/opencode/opencode.json"
      end

      def serialize_opencode_config(payload)
        JSON.pretty_generate(payload)
      end

      def heartbeat_hook_script(heartbeat_file_path)
        "touch #{Shellwords.escape(heartbeat_file_path)}"
      end

      def heartbeat_hook_config_path
        "~/.config/opencode/hooks.json"
      end

      def merge_heartbeat_hooks(hook_script)
        existing = load_existing_hooks_config(heartbeat_hook_config_path)
        hooks = existing.fetch("hooks", {})
        on_activity = hooks.fetch("on_activity", [])
        on_activity = on_activity.dup
        on_activity << {"command" => hook_script}
        existing.merge("hooks" => hooks.merge("on_activity" => on_activity))
      end

      def load_existing_hooks_config(path)
        expanded = File.expand_path(path)
        return {} unless File.exist?(expanded)

        JSON.parse(File.read(expanded))
      rescue JSON::ParserError
        {}
      end

      def stringify_keys(hash)
        hash.each_with_object({}) do |(key, value), result|
          result[key.to_s] = value
        end
      end
    end
  end
end
