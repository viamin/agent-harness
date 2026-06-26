# frozen_string_literal: true

require "json"
require "fileutils"
require "net/http"
require "tempfile"
require "time"
require "uri"

module AgentHarness
  # Authentication management for CLI agent providers
  #
  # Provides methods for checking auth status, generating OAuth URLs,
  # and refreshing credentials for providers that support it.
  module Authentication
    class << self
      # Check if authentication is valid for a provider
      #
      # @param provider_name [Symbol] the provider name
      # @return [Boolean] true if auth is valid, false otherwise
      def auth_valid?(provider_name)
        status = auth_status(provider_name)
        !!status[:valid]
      end

      # Get detailed authentication status for a provider
      #
      # @param provider_name [Symbol] the provider name
      # @return [Hash] status with :valid, :expires_at, :error keys
      def auth_status(provider_name)
        provider_name = provider_name.to_sym
        case provider_name
        when :claude, :anthropic
          claude_auth_status
        else
          generic_auth_status(provider_name)
        end
      end

      # Get authentication flow capabilities for a provider.
      #
      # @param provider_name [Symbol] the provider name
      # @return [Hash] capabilities with :auth_type, :auth_url, :refresh keys
      # @raise [ProviderNotFoundError] if provider is unknown
      def auth_capabilities(provider_name)
        provider_name = provider_name.to_sym
        provider = resolve_provider(provider_name)
        canonical_name = Providers::Registry.instance.canonical_name(provider_name)
        flow_supported = claude_oauth_flow_provider?(provider_name, canonical_name)

        {
          auth_type: provider.auth_type,
          auth_url: flow_supported,
          exchange_code: flow_supported,
          refresh: flow_supported
        }
      end

      # Check whether OAuth URL generation is supported for a provider.
      #
      # @param provider_name [Symbol] the provider name
      # @return [Boolean] true if auth_url can be called for the provider
      # @raise [ProviderNotFoundError] if provider is unknown
      def auth_url_supported?(provider_name)
        auth_capabilities(provider_name)[:auth_url]
      end

      # Generate an OAuth URL for a provider
      #
      # Only supported for :oauth auth type providers.
      #
      # @param provider_name [Symbol] the provider name
      # @return [String] the OAuth authorization URL
      # @raise [UnsupportedAuthFlowError] if provider doesn't support OAuth
      def auth_url(provider_name)
        provider_name = provider_name.to_sym
        provider = resolve_provider(provider_name)

        unless provider.auth_type == :oauth
          raise UnsupportedAuthFlowError,
            "Provider #{provider_name} uses #{provider.auth_type} auth and does not support OAuth URL generation"
        end

        case provider_name
        when :claude, :anthropic
          claude_auth_url
        else
          raise UnsupportedAuthFlowError,
            "OAuth URL generation is not yet implemented for provider #{provider_name}"
        end
      end

      # Check whether PKCE code exchange is supported for a provider.
      #
      # @param provider_name [Symbol] the provider name
      # @return [Boolean] true if exchange_code can be called for the provider
      # @raise [ProviderNotFoundError] if provider is unknown
      def exchange_code_supported?(provider_name)
        auth_capabilities(provider_name)[:exchange_code]
      end

      # Exchange an OAuth authorization code for tokens using PKCE.
      #
      # Performs the code→token exchange with the provider's token endpoint
      # and stores the resulting credentials in native shape.
      #
      # @param provider_name [Symbol] the provider name
      # @param code [String] the authorization code from the OAuth redirect
      # @param code_verifier [String] the PKCE code verifier used when generating the auth URL
      # @return [Hash] result with :success and :credentials keys
      # @raise [UnsupportedAuthFlowError] if provider doesn't support code exchange
      # @raise [ArgumentError] if code or code_verifier are blank
      # @raise [AuthenticationError] if the token exchange request fails
      def exchange_code(provider_name, code:, code_verifier:)
        provider_name = provider_name.to_sym
        provider = resolve_provider(provider_name)

        unless provider.auth_type == :oauth
          raise UnsupportedAuthFlowError,
            "Provider #{provider_name} uses #{provider.auth_type} auth and does not support PKCE code exchange"
        end

        case provider_name
        when :claude, :anthropic
          exchange_claude_code(code: code, code_verifier: code_verifier)
        else
          raise UnsupportedAuthFlowError,
            "PKCE code exchange is not yet implemented for provider #{provider_name}"
        end
      end

      # Check whether credential refresh is supported for a provider.
      #
      # @param provider_name [Symbol] the provider name
      # @return [Boolean] true if refresh_auth can be called for the provider
      # @raise [ProviderNotFoundError] if provider is unknown
      def refresh_auth_supported?(provider_name)
        auth_capabilities(provider_name)[:refresh]
      end

      # Refresh authentication credentials for a provider
      #
      # For OAuth providers, stores a pre-exchanged token directly.
      # This method accepts a token (not an authorization code) because
      # the OAuth code-exchange flow is provider-specific and should be
      # handled by the caller or a CLI login command before calling this.
      # For API key providers, raises UnsupportedAuthFlowError.
      #
      # @param provider_name [Symbol] the provider name
      # @param token [String] OAuth token to store (must be non-blank)
      # @return [Hash] result with :success key
      # @raise [UnsupportedAuthFlowError] if provider doesn't support credential refresh
      def refresh_auth(provider_name, token: nil)
        provider_name = provider_name.to_sym
        provider = resolve_provider(provider_name)

        unless provider.auth_type == :oauth
          raise UnsupportedAuthFlowError,
            "Provider #{provider_name} uses #{provider.auth_type} auth and does not support credential refresh"
        end

        case provider_name
        when :claude, :anthropic
          refresh_claude_auth(token: token)
        else
          raise UnsupportedAuthFlowError,
            "Credential refresh is not yet implemented for provider #{provider_name}"
        end
      end

      private

      def claude_oauth_flow_provider?(requested_name, canonical_name)
        [:claude, :anthropic].include?(requested_name) || canonical_name == :claude
      end

      def resolve_provider(provider_name)
        klass = Providers::Registry.instance.get(provider_name)
        canonical_name = Providers::Registry.instance.canonical_name(provider_name)
        config = provider_config_for(provider_name, canonical_name: canonical_name)
        executor = AgentHarness.configuration.command_executor
        logger = AgentHarness.logger

        provider = if klass.respond_to?(:build_provider_instance, true)
          klass.send(:build_provider_instance, config: config, executor: executor, logger: logger)
        else
          klass.new(config: config, executor: executor, logger: logger)
        end

        # Ensure the executor is available even when the provider constructor
        # accepts only a subset of keywords (e.g. config: only).
        if provider.respond_to?(:executor=) && provider.executor.nil?
          provider.executor = executor
        elsif !provider.respond_to?(:executor)
          provider.define_singleton_method(:executor) { executor }
        end

        provider
      rescue ConfigurationError
        raise ProviderNotFoundError, "Unknown provider: #{provider_name}"
      end

      # Claude Code auth status check
      def claude_auth_status
        credentials = read_claude_credentials
        return {valid: false, expires_at: nil, error: "No credentials found"} unless credentials

        token, expires_at = extract_claude_token(credentials)
        if token
          if expires_at && expires_at < Time.now
            {valid: false, expires_at: expires_at, error: "Session expired"}
          else
            {valid: true, expires_at: expires_at, error: nil}
          end
        else
          {valid: false, expires_at: nil, error: "No authentication token found"}
        end
      rescue IOError, JSON::ParserError => e
        {valid: false, expires_at: nil, error: e.message}
      end

      # Generic auth status for non-Claude providers
      def generic_auth_status(provider_name)
        provider = resolve_provider(provider_name)

        # Prefer a provider-specific auth_status hook when available
        if provider.respond_to?(:auth_status)
          return provider.auth_status
        end

        if provider.auth_type == :api_key
          {valid: false, expires_at: nil, error: "Auth status check not implemented for api_key providers"}
        else
          {valid: false, expires_at: nil, error: "Auth status check not implemented for #{provider_name}"}
        end
      rescue ProviderNotFoundError => e
        {valid: false, expires_at: nil, error: e.message}
      end

      def claude_auth_url
        "https://claude.ai/oauth/authorize"
      end

      def claude_token_url
        "https://claude.ai/oauth/token"
      end

      def exchange_claude_code(code:, code_verifier:)
        raise ArgumentError, "code must be a non-empty string" unless code.is_a?(String) && !code.strip.empty?
        raise ArgumentError, "code_verifier must be a non-empty string" unless code_verifier.is_a?(String) && !code_verifier.strip.empty?

        uri = URI.parse(claude_token_url)
        request = Net::HTTP::Post.new(uri)
        request.content_type = "application/json"
        request.body = JSON.generate({
          grant_type: "authorization_code",
          code: code.strip,
          code_verifier: code_verifier.strip
        })

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
          http.open_timeout = 10
          http.read_timeout = 30
          http.request(request)
        end

        unless response.is_a?(Net::HTTPSuccess)
          error_body = begin
            JSON.parse(response.body)
          rescue JSON::ParserError
            {"error" => response.body}
          end
          raise AuthenticationError.new(
            "PKCE code exchange failed (HTTP #{response.code}): #{error_body["error"] || error_body["error_description"] || response.body}",
            provider: :claude
          )
        end

        token_data = JSON.parse(response.body)
        store_claude_token_response(token_data)
      end

      def store_claude_token_response(token_data)
        credentials_path = claude_credentials_path
        dir = File.dirname(credentials_path)
        FileUtils.mkdir_p(dir, mode: 0o700)

        lock_path = "#{credentials_path}.lock"
        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)

          credentials = read_claude_credentials
          credentials = {} unless credentials.is_a?(Hash)

          if credentials.key?("claudeAiOauth")
            # Preserve the native claudeAiOauth shape so extract_claude_token
            # picks up the newly exchanged token instead of a stale nested value.
            oauth = credentials["claudeAiOauth"]
            oauth = {} unless oauth.is_a?(Hash)
            oauth["accessToken"] = token_data["access_token"]
            oauth["refreshToken"] = token_data["refresh_token"] if token_data["refresh_token"]
            if token_data["expires_in"]
              oauth["expiresAt"] = (Time.now + token_data["expires_in"].to_i).iso8601
            else
              oauth.delete("expiresAt")
            end
            credentials["claudeAiOauth"] = oauth
          else
            credentials["oauth_token"] = token_data["access_token"]
            credentials["refreshToken"] = token_data["refresh_token"] if token_data["refresh_token"]
            if token_data["expires_in"]
              credentials["expiresAt"] = (Time.now + token_data["expires_in"].to_i).iso8601
            else
              credentials.delete("expiresAt")
              credentials.delete("expires_at")
            end
          end

          tmpfile = Tempfile.new(".credentials", dir)
          begin
            tmpfile.write(JSON.pretty_generate(credentials))
            tmpfile.close
            File.chmod(0o600, tmpfile.path)
            File.rename(tmpfile.path, credentials_path)
          rescue
            tmpfile.close!
            raise
          end
        end

        {success: true, credentials: token_data}
      end

      def provider_config_for(requested_name, canonical_name:)
        requested_key = requested_name.to_sym
        canonical_key = canonical_name.to_sym

        AgentHarness.configuration.providers[requested_key] ||
          AgentHarness.configuration.providers[canonical_key]
      end

      def refresh_claude_auth(token: nil)
        raise ArgumentError, "token must be a non-empty string" unless token.is_a?(String) && !token.strip.empty?

        credentials_path = claude_credentials_path
        dir = File.dirname(credentials_path)
        FileUtils.mkdir_p(dir, mode: 0o700)

        lock_path = "#{credentials_path}.lock"
        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)

          credentials = read_claude_credentials
          credentials = {} unless credentials.is_a?(Hash)

          if credentials.key?("claudeAiOauth")
            # Preserve the native claudeAiOauth shape
            oauth = credentials["claudeAiOauth"]
            oauth = {} unless oauth.is_a?(Hash)
            oauth["accessToken"] = token.strip
            oauth.delete("expiresAt")
            credentials["claudeAiOauth"] = oauth
          else
            credentials["oauth_token"] = token.strip
            # Clear any existing expiry metadata so refreshed tokens are not treated as expired
            credentials.delete("expiresAt")
            credentials.delete("expires_at")
          end

          # Write under a file lock using tempfile + rename to avoid corruption and lost updates on concurrent refreshes
          tmpfile = Tempfile.new(".credentials", dir)
          begin
            tmpfile.write(JSON.pretty_generate(credentials))
            tmpfile.close
            File.chmod(0o600, tmpfile.path)
            File.rename(tmpfile.path, credentials_path)
          rescue
            tmpfile.close!
            raise
          end
        end

        {success: true}
      end

      # Extract a usable token and expiry from Claude credentials,
      # supporting both the native claudeAiOauth shape and the legacy
      # top-level oauth_token/apiKey shape.
      #
      # @return [Array(String, Time)] token and parsed expiry, or nils
      def extract_claude_token(credentials)
        # Prefer the native claudeAiOauth nested shape written by the Claude CLI
        if credentials.key?("claudeAiOauth")
          oauth = credentials["claudeAiOauth"]
          if oauth.is_a?(Hash)
            access_token = oauth["accessToken"]
            if non_blank?(access_token)
              expires_at = parse_expiry(oauth["expiresAt"])
              return [access_token, expires_at]
            end
          end
        end

        # Fall back to the legacy top-level shape
        oauth_token = credentials["oauth_token"]
        api_key = credentials["apiKey"]
        token = [oauth_token, api_key].find { |t| non_blank?(t) }
        expires_at = parse_expiry(credentials["expiresAt"] || credentials["expires_at"]) if token
        [token, expires_at]
      end

      def non_blank?(value)
        value.is_a?(String) && !value.strip.empty?
      end

      def read_claude_credentials
        path = claude_credentials_path
        return nil unless File.exist?(path)

        JSON.parse(File.read(path))
      rescue Errno::ENOENT
        # File was removed between the existence check and the read; treat as missing
        nil
      rescue Errno::EACCES => e
        raise IOError, "Permission denied when reading Claude credentials at #{path}: #{e.message}"
      rescue JSON::ParserError => e
        raise JSON::ParserError, "Invalid JSON in Claude credentials at #{path}: #{e.message}"
      end

      def claude_credentials_path
        config_dir = ENV["CLAUDE_CONFIG_DIR"] || File.expand_path("~/.claude")
        File.join(config_dir, ".credentials.json")
      end

      def parse_expiry(value)
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
