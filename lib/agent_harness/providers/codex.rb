# frozen_string_literal: true

require "json"

module AgentHarness
  module Providers
    # OpenAI Codex CLI provider
    #
    # Provides integration with the OpenAI Codex CLI tool.
    class Codex < Base
      SUPPORTED_CLI_VERSION = "0.116.0"
      SUPPORTED_CLI_REQUIREMENT = Gem::Requirement.new(">= #{SUPPORTED_CLI_VERSION}", "< 0.117.0").freeze
      OAUTH_REFRESH_FAILURE_PATTERNS = [
        /refresh_token_reused/i,
        /failed to refresh token:.*\b401\b/i,
        /failed to refresh token:.*unauthorized/i,
        /failed to refresh token:.*invalid_client/i,
        /failed to refresh token:.*invalid_grant/i,
        /failed to refresh token:.*invalid.*refresh.*token/i,
        /your access token could not be refreshed because your refresh token .*already (?:been )?used/i,
        /refresh token .*already been used/i
      ].freeze
      OAUTH_REFRESH_TRANSIENT_PATTERNS = [
        /your access token could not be refreshed because the auth(?:entication)? service was unavailable/i,
        /your access token could not be refreshed because .*connection.*error/i,
        /failed to refresh token:.*connection.*error/i,
        /failed to refresh token:.*service.*unavailable/i
      ].freeze

      class << self
        def provider_name
          :codex
        end

        def binary_name
          "codex"
        end

        def available?
          executor = AgentHarness.configuration.command_executor
          !!executor.which(binary_name)
        end

        def provider_metadata_overrides
          {
            auth: {
              service: :openai,
              api_family: :openai
            }
          }
        end

        def firewall_requirements
          {
            domains: [
              "api.openai.com",
              "openai.com"
            ],
            ip_ranges: []
          }
        end

        def instruction_file_paths
          [
            {
              path: "AGENTS.md",
              description: "OpenAI Codex agent instructions",
              symlink: false
            }
          ]
        end

        def discover_models
          return [] unless available?

          [
            {name: "codex", family: "codex", tier: "standard", provider: "codex"}
          ]
        end

        def installation_contract(version: SUPPORTED_CLI_VERSION)
          version = version.strip if version.respond_to?(:strip)

          unless version.is_a?(String) && !version.empty?
            raise ArgumentError,
              "Unsupported Codex CLI version #{version.inspect}; " \
              "supported versions must satisfy #{SUPPORTED_CLI_REQUIREMENT}"
          end

          parsed_version = begin
            Gem::Version.new(version)
          rescue ArgumentError
            raise ArgumentError,
              "Unsupported Codex CLI version #{version.inspect}; " \
              "supported versions must satisfy #{SUPPORTED_CLI_REQUIREMENT}"
          end

          unless SUPPORTED_CLI_REQUIREMENT.satisfied_by?(parsed_version)
            raise ArgumentError,
              "Unsupported Codex CLI version #{version.inspect}; " \
              "supported versions must satisfy #{SUPPORTED_CLI_REQUIREMENT}"
          end

          default_package = "@openai/codex@#{version}".freeze
          install_command_prefix = ["npm", "install", "-g", "--ignore-scripts"].freeze
          install_command = (install_command_prefix + [default_package]).freeze
          supported_versions = [version].freeze
          version_requirement = SUPPORTED_CLI_REQUIREMENT.requirements
            .map { |op, ver| "#{op} #{ver}".freeze }
            .freeze

          contract = {
            source: :npm,
            package: default_package,
            package_name: "@openai/codex",
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
        "codex"
      end

      def display_name
        "OpenAI Codex CLI"
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
          tool_use: true,
          json_mode: false,
          mcp: false,
          dangerous_mode: true
        }
      end

      def dangerous_mode_flags
        ["--full-auto"]
      end

      def execution_semantics
        {
          prompt_delivery: :arg,
          output_format: :text,
          sandbox_aware: true,
          uses_subcommand: true,
          non_interactive_flag: nil,
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
        ["--session", session_id]
      end

      def error_patterns
        {
          rate_limited: COMMON_ERROR_PATTERNS[:rate_limited],
          timeout: [
            /your access token could not be refreshed.*(?:timeout|timed out)/i,
            /failed to refresh token:.*(?:timeout|timed out)/i
          ],
          transient: COMMON_ERROR_PATTERNS[:transient] + [
            /connection.*reset/i
          ] + OAUTH_REFRESH_TRANSIENT_PATTERNS,
          auth_expired: COMMON_ERROR_PATTERNS[:auth_expired] + [
            /\b401\b/,
            /incorrect.*api.*key/i
          ] + OAUTH_REFRESH_FAILURE_PATTERNS,
          quota_exceeded: COMMON_ERROR_PATTERNS[:quota_exceeded],
          sandbox_failure: [
            /bwrap.*no permissions/i,
            /no permissions to create a new namespace/i,
            /unprivileged.*namespace/i
          ]
        }
      end

      def auth_status
        api_key = ENV["OPENAI_API_KEY"]
        if api_key && !api_key.strip.empty?
          if api_key.strip.start_with?("sk-")
            return {valid: true, expires_at: nil, error: nil, auth_method: :api_key}
          else
            return {valid: false, expires_at: nil, error: "OPENAI_API_KEY is set but does not appear to be a valid OpenAI API key", auth_method: nil}
          end
        end

        credentials = read_codex_credentials
        if credentials
          key = credentials["api_key"] || credentials["apiKey"] || credentials["OPENAI_API_KEY"]
          if key.is_a?(String) && !key.strip.empty?
            if key.strip.start_with?("sk-")
              return {valid: true, expires_at: nil, error: nil, auth_method: :config_file}
            else
              return {valid: false, expires_at: nil, error: "Config file API key is set but does not appear to be a valid OpenAI API key", auth_method: nil}
            end
          end
        end

        {valid: false, expires_at: nil, error: "No OpenAI API key found. Set OPENAI_API_KEY or configure in #{codex_config_path}", auth_method: nil}
      rescue IOError, JSON::ParserError => e
        {valid: false, expires_at: nil, error: e.message, auth_method: nil}
      end

      def health_status
        unless self.class.available?
          return {healthy: false, message: "Codex CLI not found in PATH. Install from https://github.com/openai/codex"}
        end

        auth = auth_status
        unless auth[:valid]
          return {healthy: false, message: auth[:error]}
        end

        {healthy: true, message: "Codex CLI available and authenticated"}
      end

      def validate_config
        errors = []

        flags = @config.default_flags
        unless flags.nil?
          if flags.is_a?(Array)
            invalid = flags.reject { |f| f.is_a?(String) }
            errors << "default_flags contains non-string values" if invalid.any?
          else
            errors << "default_flags must be an array of strings"
          end
        end

        {valid: errors.empty?, errors: errors}
      end

      protected

      def parse_response(result, duration:)
        response = super

        if response.success? && sandbox_failure_detected?(result.stderr)
          return Response.new(
            output: result.stdout,
            exit_code: 1,
            duration: duration,
            provider: self.class.provider_name,
            model: @config.model,
            error: "Sandbox failure detected: #{result.stderr.strip}"
          )
        end

        response
      end

      def build_command(prompt, options)
        cmd = [self.class.binary_name, "exec"]
        externally_sandboxed = externally_sandboxed?(options)

        # When externally_sandboxed is set, use --dangerously-bypass-approvals-and-sandbox
        # instead of --full-auto. In the Codex CLI, full_auto is checked first and
        # selects workspace-write sandbox mode, which overrides the bypass flag.
        # Passing both would leave the run in the wrong sandbox mode.
        #
        # When NOT externally sandboxed: use --full-auto for Docker containers
        # (to skip nested sandboxing) or when dangerous_mode is explicitly requested.
        if !externally_sandboxed && (sandboxed_environment? || options[:dangerous_mode])
          cmd += dangerous_mode_flags
        end

        flags = @config.default_flags
        if flags
          unless flags.is_a?(Array)
            raise ArgumentError, "Codex configuration error: default_flags must be an array of strings"
          end
          # Strip --full-auto from defaults when externally sandboxed to avoid
          # conflicting with --dangerously-bypass-approvals-and-sandbox.
          flags -= dangerous_mode_flags if externally_sandboxed
          cmd += flags if flags.any?
        end

        if externally_sandboxed
          cmd += sandbox_bypass_flags
        end

        if options[:session]
          cmd += session_flags(options[:session])
        end

        runtime = options[:provider_runtime]
        if runtime
          cmd += ["--model", runtime.model] if runtime.model
          runtime_flags = runtime.flags
          # Strip --full-auto from runtime flags when externally sandboxed.
          runtime_flags -= dangerous_mode_flags if externally_sandboxed
          cmd += runtime_flags unless runtime_flags.empty?
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

      private

      def externally_sandboxed?(options)
        if options.key?(:externally_sandboxed)
          !!options[:externally_sandboxed]
        else
          !!@config.externally_sandboxed
        end
      end

      def sandbox_failure_detected?(stderr)
        return false if stderr.nil? || stderr.empty?

        error_patterns[:sandbox_failure].any? { |pattern| stderr.match?(pattern) }
      end

      def sandbox_bypass_flags
        ["--dangerously-bypass-approvals-and-sandbox"]
      end

      def read_codex_credentials
        path = codex_config_path
        return nil unless File.exist?(path)

        parsed = JSON.parse(File.read(path))
        return nil unless parsed.is_a?(Hash)

        parsed
      rescue Errno::ENOENT
        nil
      rescue Errno::EACCES => e
        raise IOError, "Permission denied reading Codex config at #{path}: #{e.message}"
      rescue JSON::ParserError
        raise JSON::ParserError, "Invalid JSON in Codex config at #{path}"
      end

      def codex_config_path
        config_dir = ENV["CODEX_CONFIG_DIR"] || File.expand_path("~/.codex")
        File.join(config_dir, "config.json")
      end
    end
  end
end
