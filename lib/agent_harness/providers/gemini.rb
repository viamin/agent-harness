# frozen_string_literal: true

require "json"
require "time"

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

      def auth_type
        :oauth
      end

      def execution_semantics
        {
          prompt_delivery: :flag,
          output_format: :text,
          sandbox_aware: false,
          uses_subcommand: false,
          non_interactive_flag: nil,
          legitimate_exit_codes: [0],
          stderr_is_diagnostic: true,
          parses_rate_limit_reset: false
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
            /invalid.?credentials/i,
            /login.*required/i,
            /not.*logged.*in/i,
            /credentials.*expired/i,
            /account.*not.*verified/i
          ],
          transient: [
            /timeout/i,
            /temporary/i,
            /503/
          ]
        }
      end

      def auth_status
        api_key = [ENV["GEMINI_API_KEY"], ENV["GOOGLE_API_KEY"]].find { |key| key && !key.strip.empty? }
        if api_key
          return {valid: true, expires_at: nil, error: nil, auth_method: :api_key}
        end

        credentials = read_gemini_credentials
        return {valid: false, expires_at: nil, error: "No Gemini credentials found. Run 'gemini auth login' or set GEMINI_API_KEY or GOOGLE_API_KEY"} unless credentials

        token = credentials["access_token"] || credentials["oauth_token"]
        unless token.is_a?(String) && !token.strip.empty?
          return {valid: false, expires_at: nil, error: "No authentication token in Gemini credentials"}
        end

        expires_at = parse_gemini_expiry(credentials)
        if expires_at && expires_at < Time.now
          {valid: false, expires_at: expires_at, error: "Gemini session expired. Run 'gemini auth login' to re-authenticate"}
        else
          {valid: true, expires_at: expires_at, error: nil, auth_method: :oauth}
        end
      rescue IOError, JSON::ParserError => e
        {valid: false, expires_at: nil, error: e.message}
      end

      def health_status
        unless self.class.available?
          return {healthy: false, message: "Gemini CLI not found in PATH. Install from https://github.com/google-gemini/gemini-cli"}
        end

        auth = auth_status
        unless auth[:valid]
          return {healthy: false, message: auth[:error]}
        end

        {healthy: true, message: "Gemini CLI available and authenticated"}
      end

      def validate_config
        errors = []

        model = @config.model
        if !model.nil? && !model.is_a?(String)
          errors << "model must be a string"
        elsif model.is_a?(String) && !model.empty?
          unless self.class.supports_model_family?(model)
            errors << "Unrecognized model '#{model}'. Expected a Gemini model (e.g., gemini-2.0-flash, gemini-2.5-pro)"
          end
        end

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
        cmd = [self.class.binary_name]

        if @config.model && !@config.model.empty?
          cmd += ["--model", @config.model]
        end

        flags = @config.default_flags
        if flags
          unless flags.is_a?(Array)
            raise ArgumentError, "Gemini configuration error: default_flags must be an array of strings"
          end
          cmd += flags if flags.any?
        end

        cmd += ["--prompt", prompt]

        cmd
      end

      def default_timeout
        300
      end

      private

      def read_gemini_credentials
        path = gemini_credentials_path
        return nil unless File.exist?(path)

        parsed = JSON.parse(File.read(path))
        return nil unless parsed.is_a?(Hash)

        parsed
      rescue Errno::ENOENT
        nil
      rescue Errno::EACCES => e
        raise IOError, "Permission denied reading Gemini credentials at #{path}: #{e.message}"
      rescue JSON::ParserError
        raise JSON::ParserError, "Invalid JSON in Gemini credentials at #{path}"
      end

      def gemini_credentials_path
        config_dir = ENV["GEMINI_CONFIG_DIR"] || File.expand_path("~/.gemini")
        File.join(config_dir, "credentials.json")
      end

      def parse_gemini_expiry(credentials)
        value = credentials["expires_at"] || credentials["expiresAt"] || credentials["expiry"]
        return nil unless value

        case value
        when Time
          value
        when Integer, Float
          Time.at(value)
        when String
          Time.parse(value)
        end
      rescue ArgumentError
        nil
      end
    end
  end
end
