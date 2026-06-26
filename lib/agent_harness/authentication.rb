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
          refresh: flow_supported,
          exchange: flow_supported,
          code_exchange: flow_supported
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

      # Check whether refresh-token exchange is supported for a provider.
      #
      # @param provider_name [Symbol] the provider name
      # @return [Boolean] true if exchange_refresh_token can be called
      # @raise [ProviderNotFoundError] if provider is unknown
      def exchange_refresh_token_supported?(provider_name)
        auth_capabilities(provider_name)[:exchange]
      end

      # Exchange a stored refresh token for a fresh access token (and rotated refresh token).
      #
      # Reads the refresh token from the provider's credentials store, posts it to the
      # OAuth token endpoint, persists the rotated tokens, and returns the credential
      # in native claudeAiOauth shape.
      #
      # Serializes through a file lock so that concurrent callers do not race on a
      # single-use/rotating refresh token.  If the token server reports that the
      # refresh token has already been consumed (`refresh_token_reused`), raises
      # +AuthenticationError+ so the caller can trigger a full re-auth.
      #
      # @param provider_name [Symbol] the provider name
      # @return [Hash] credential in claudeAiOauth shape:
      #   +{ claudeAiOauth: { accessToken:, refreshToken:, expiresAt: } }+
      # @raise [UnsupportedAuthFlowError] if provider doesn't support token exchange
      # @raise [AuthenticationError] if the refresh token is missing, reused, or exchange fails
      def exchange_refresh_token(provider_name)
        provider_name = provider_name.to_sym
        provider = resolve_provider(provider_name)

        unless provider.auth_type == :oauth
          raise UnsupportedAuthFlowError,
            "Provider #{provider_name} uses #{provider.auth_type} auth and does not support token exchange"
        end

        case provider_name
        when :claude, :anthropic
          exchange_claude_refresh_token
        else
          raise UnsupportedAuthFlowError,
            "Token exchange is not yet implemented for provider #{provider_name}"
        end
      end

      # Check whether PKCE authorization-code exchange is supported for a provider.
      #
      # @param provider_name [Symbol] the provider name
      # @return [Boolean] true if exchange_code can be called
      # @raise [ProviderNotFoundError] if provider is unknown
      def exchange_code_supported?(provider_name)
        auth_capabilities(provider_name)[:code_exchange]
      end

      # Exchange a PKCE authorization code for tokens and persist them in native shape.
      #
      # Posts the authorization code and PKCE verifier to the provider's OAuth
      # token endpoint, then writes the resulting access/refresh tokens to the
      # credentials store using the provider's native shape (e.g. +claudeAiOauth+
      # for Claude).
      #
      # Serializes through a file lock so that concurrent callers do not race on
      # credential writes.
      #
      # @param provider_name [Symbol] the provider name
      # @param code [String] authorization code returned from the OAuth redirect (required)
      # @param code_verifier [String] PKCE code verifier matching the code_challenge sent on the auth URL (required)
      # @param redirect_uri [String] redirect URI registered with the authorization request (required)
      # @param client_id [String] OAuth client identifier (required)
      # @param state [String, nil] optional state parameter echoed from the authorization request
      # @return [Hash] credential in claudeAiOauth shape for Claude:
      #   +{ claudeAiOauth: { accessToken:, refreshToken:, expiresAt: } }+
      # @raise [UnsupportedAuthFlowError] if provider doesn't support PKCE code exchange
      # @raise [ArgumentError] if any required parameter is blank
      # @raise [AuthenticationError] if the exchange fails
      def exchange_code(provider_name, code:, code_verifier:, redirect_uri:, client_id:, state: nil)
        provider_name = provider_name.to_sym
        provider = resolve_provider(provider_name)

        unless provider.auth_type == :oauth
          raise UnsupportedAuthFlowError,
            "Provider #{provider_name} uses #{provider.auth_type} auth and does not support code exchange"
        end

        validate_code_exchange_params!(code: code, code_verifier: code_verifier,
          redirect_uri: redirect_uri, client_id: client_id)

        case provider_name
        when :claude, :anthropic
          exchange_claude_code(
            code: code.strip,
            code_verifier: code_verifier.strip,
            redirect_uri: redirect_uri.strip,
            client_id: client_id.strip,
            state: state
          )
        else
          raise UnsupportedAuthFlowError,
            "Code exchange is not yet implemented for provider #{provider_name}"
        end
      end

      private

      def validate_code_exchange_params!(code:, code_verifier:, redirect_uri:, client_id:)
        {code: code, code_verifier: code_verifier,
         redirect_uri: redirect_uri, client_id: client_id}.each do |name, value|
          unless non_blank?(value)
            raise ArgumentError, "#{name} must be a non-empty string"
          end
        end
      end

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

      # Token endpoint used for Claude OAuth refresh-token exchange.
      CLAUDE_TOKEN_ENDPOINT = URI("https://claude.ai/oauth/token").freeze

      def exchange_claude_refresh_token
        credentials_path = claude_credentials_path
        lock_path = "#{credentials_path}.lock"

        dir = File.dirname(credentials_path)
        FileUtils.mkdir_p(dir, mode: 0o700)

        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)

          credentials = read_claude_credentials
          refresh_token = credentials&.dig("claudeAiOauth", "refreshToken")
          refresh_token = nil if refresh_token.is_a?(String) && refresh_token.strip.empty?

          unless refresh_token
            raise AuthenticationError.new(
              "No refresh token found in Claude credentials",
              provider: :claude
            )
          end

          response_body = post_token_exchange(refresh_token)

          access_token = response_body["access_token"]
          new_refresh_token = response_body["refresh_token"]
          expires_in = response_body["expires_in"]

          expires_at = expires_in ? (Time.now + expires_in).iso8601 : nil

          oauth_block = {
            "accessToken" => access_token,
            "refreshToken" => new_refresh_token,
            "expiresAt" => expires_at
          }

          credentials["claudeAiOauth"] = oauth_block
          credentials["oauth_token"] = access_token
          credentials.delete("expiresAt")
          credentials.delete("expires_at")
          credentials["expiresAt"] = expires_at

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

          {claudeAiOauth: oauth_block.transform_keys(&:to_sym)}
        end
      end

      def exchange_claude_code(code:, code_verifier:, redirect_uri:, client_id:, state:)
        credentials_path = claude_credentials_path
        lock_path = "#{credentials_path}.lock"

        dir = File.dirname(credentials_path)
        FileUtils.mkdir_p(dir, mode: 0o700)

        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)

          response_body = post_code_exchange(
            code: code,
            code_verifier: code_verifier,
            redirect_uri: redirect_uri,
            client_id: client_id,
            state: state
          )

          access_token = response_body["access_token"]
          new_refresh_token = response_body["refresh_token"]
          expires_in = response_body["expires_in"]

          unless non_blank?(access_token)
            raise AuthenticationError.new(
              "Code exchange response did not include an access_token",
              provider: :claude
            )
          end

          expires_at = expires_in ? (Time.now + expires_in).iso8601 : nil

          oauth_block = {
            "accessToken" => access_token,
            "refreshToken" => new_refresh_token,
            "expiresAt" => expires_at
          }

          credentials = read_claude_credentials
          credentials = {} unless credentials.is_a?(Hash)
          credentials["claudeAiOauth"] = oauth_block
          credentials["oauth_token"] = access_token
          credentials.delete("expires_at")
          credentials["expiresAt"] = expires_at

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

          {claudeAiOauth: oauth_block.transform_keys(&:to_sym)}
        end
      end

      def post_code_exchange(code:, code_verifier:, redirect_uri:, client_id:, state:)
        payload = {
          grant_type: "authorization_code",
          code: code,
          code_verifier: code_verifier,
          redirect_uri: redirect_uri,
          client_id: client_id
        }
        payload[:state] = state if non_blank?(state)

        http = Net::HTTP.new(CLAUDE_TOKEN_ENDPOINT.host, CLAUDE_TOKEN_ENDPOINT.port)
        http.use_ssl = true
        http.open_timeout = 10
        http.read_timeout = 10

        request = Net::HTTP::Post.new(CLAUDE_TOKEN_ENDPOINT.path)
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(payload)

        response = http.request(request)

        body = begin
          JSON.parse(response.body)
        rescue JSON::ParserError
          {}
        end

        unless response.is_a?(Net::HTTPSuccess)
          error_description = body["error_description"] || body["error"] || body["message"] || response.body
          raise AuthenticationError.new(
            "Code exchange failed (HTTP #{response.code}): #{error_description}",
            provider: :claude
          )
        end

        body
      end

      def post_token_exchange(refresh_token)
        http = Net::HTTP.new(CLAUDE_TOKEN_ENDPOINT.host, CLAUDE_TOKEN_ENDPOINT.port)
        http.use_ssl = true
        http.open_timeout = 10
        http.read_timeout = 10

        request = Net::HTTP::Post.new(CLAUDE_TOKEN_ENDPOINT.path)
        request["Content-Type"] = "application/json"
        request.body = JSON.generate({
          grant_type: "refresh_token",
          refresh_token: refresh_token
        })

        response = http.request(request)

        body = begin
          JSON.parse(response.body)
        rescue JSON::ParserError
          {}
        end

        unless response.is_a?(Net::HTTPSuccess)
          error_code = body["error"] || body["code"]
          if error_code.to_s.match?(/refresh_token_reused/i)
            raise AuthenticationError.new(
              "Refresh token has already been used (refresh_token_reused). Re-authentication required.",
              provider: :claude
            )
          end

          error_description = body["error_description"] || body["message"] || response.body
          raise AuthenticationError.new(
            "Token exchange failed (HTTP #{response.code}): #{error_description}",
            provider: :claude
          )
        end

        body
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
