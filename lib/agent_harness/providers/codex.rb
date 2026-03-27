# frozen_string_literal: true

require "json"

module AgentHarness
  module Providers
    # OpenAI Codex CLI provider
    #
    # Provides integration with the OpenAI Codex CLI tool.
    class Codex < Base
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
      end

      def name
        "codex"
      end

      def display_name
        "OpenAI Codex CLI"
      end

      def capabilities
        {
          streaming: false,
          file_upload: false,
          vision: false,
          tool_use: true,
          json_mode: false,
          mcp: false,
          dangerous_mode: false
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
          rate_limited: [
            /rate.?limit/i,
            /too.?many.?requests/i,
            /429/
          ],
          auth_expired: [
            /invalid.*api.*key/i,
            /unauthorized/i,
            /authentication/i,
            /401/,
            /incorrect.*api.*key/i
          ],
          quota_exceeded: [
            /quota.*exceeded/i,
            /insufficient.*quota/i,
            /billing/i
          ],
          transient: [
            /timeout/i,
            /connection.*reset/i,
            /service.*unavailable/i,
            /503/,
            /502/
          ]
        }
      end

      def auth_status
        api_key = ENV["OPENAI_API_KEY"]
        if api_key && !api_key.strip.empty?
          if api_key.strip.start_with?("sk-")
            return {valid: true, expires_at: nil, error: nil, auth_method: :api_key}
          else
            return {valid: false, expires_at: nil, error: "OPENAI_API_KEY is set but does not appear to be a valid OpenAI API key"}
          end
        end

        credentials = read_codex_credentials
        if credentials
          key = credentials["api_key"] || credentials["apiKey"] || credentials["OPENAI_API_KEY"]
          if key.is_a?(String) && !key.strip.empty?
            if key.strip.start_with?("sk-")
              return {valid: true, expires_at: nil, error: nil, auth_method: :config_file}
            else
              return {valid: false, expires_at: nil, error: "Config file API key is set but does not appear to be a valid OpenAI API key"}
            end
          end
        end

        {valid: false, expires_at: nil, error: "No OpenAI API key found. Set OPENAI_API_KEY or configure in #{codex_config_path}"}
      rescue IOError, JSON::ParserError => e
        {valid: false, expires_at: nil, error: e.message}
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

      def build_command(prompt, options)
        cmd = [self.class.binary_name, "exec"]

        flags = @config.default_flags
        if flags
          unless flags.is_a?(Array)
            raise ArgumentError, "Codex configuration error: default_flags must be an array of strings"
          end
          cmd += flags if flags.any?
        end

        if options[:session]
          cmd += session_flags(options[:session])
        end

        cmd << prompt

        cmd
      end

      def default_timeout
        300
      end

      private

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
