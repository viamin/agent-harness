# frozen_string_literal: true

require "json"

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
      # @return [Boolean] true if auth is valid
      def auth_valid?(provider_name)
        status = auth_status(provider_name)
        status[:valid]
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

      # Generate an OAuth URL for a provider
      #
      # Only supported for :oauth auth type providers.
      #
      # @param provider_name [Symbol] the provider name
      # @return [String] the OAuth authorization URL
      # @raise [NotImplementedError] if provider doesn't support OAuth
      def auth_url(provider_name)
        provider_name = provider_name.to_sym
        provider = resolve_provider(provider_name)

        unless provider.auth_type == :oauth
          raise NotImplementedError,
            "Provider #{provider_name} uses #{provider.auth_type} auth and does not support OAuth URL generation"
        end

        case provider_name
        when :claude, :anthropic
          claude_auth_url
        else
          raise NotImplementedError,
            "OAuth URL generation is not yet implemented for provider #{provider_name}"
        end
      end

      # Refresh authentication credentials for a provider
      #
      # For OAuth providers, accepts an auth code from the OAuth flow.
      # For API key providers, raises NotImplementedError.
      #
      # @param provider_name [Symbol] the provider name
      # @param code [String, nil] OAuth authorization code
      # @param token [String, nil] direct token to store
      # @return [Hash] result with :success key
      # @raise [NotImplementedError] if provider doesn't support credential refresh
      def refresh_auth(provider_name, code: nil, token: nil)
        provider_name = provider_name.to_sym
        provider = resolve_provider(provider_name)

        unless provider.auth_type == :oauth
          raise NotImplementedError,
            "Provider #{provider_name} uses #{provider.auth_type} auth and does not support credential refresh"
        end

        case provider_name
        when :claude, :anthropic
          refresh_claude_auth(code: code, token: token)
        else
          raise NotImplementedError,
            "Credential refresh is not yet implemented for provider #{provider_name}"
        end
      end

      private

      def resolve_provider(provider_name)
        klass = Providers::Registry.instance.get(provider_name)
        klass.new
      rescue ConfigurationError
        raise ProviderNotFoundError, "Unknown provider: #{provider_name}"
      end

      # Claude Code auth status check
      def claude_auth_status
        credentials = read_claude_credentials
        return {valid: false, expires_at: nil, error: "No credentials found"} unless credentials

        # Check if the credentials file has a token
        if credentials["oauth_token"] || credentials["apiKey"]
          expires_at = parse_expiry(credentials["expiresAt"] || credentials["expires_at"])
          if expires_at && expires_at < Time.now
            {valid: false, expires_at: expires_at, error: "Session expired"}
          else
            {valid: true, expires_at: expires_at, error: nil}
          end
        else
          {valid: false, expires_at: nil, error: "No authentication token found"}
        end
      end

      # Generic auth status for non-Claude providers
      def generic_auth_status(provider_name)
        provider = resolve_provider(provider_name)
        if provider.auth_type == :api_key
          {valid: true, expires_at: nil, error: nil}
        else
          {valid: false, expires_at: nil, error: "Auth status check not implemented for #{provider_name}"}
        end
      rescue ProviderNotFoundError => e
        {valid: false, expires_at: nil, error: e.message}
      end

      def claude_auth_url
        "https://claude.ai/oauth/authorize"
      end

      def refresh_claude_auth(code: nil, token: nil)
        unless code || token
          raise ArgumentError, "Either code or token must be provided"
        end

        credentials_path = claude_credentials_path
        FileUtils.mkdir_p(File.dirname(credentials_path))

        credentials = read_claude_credentials || {}

        if token
          credentials["oauth_token"] = token
        elsif code
          credentials["oauth_code"] = code
        end

        File.write(credentials_path, JSON.pretty_generate(credentials))

        {success: true}
      end

      def read_claude_credentials
        path = claude_credentials_path
        return nil unless File.exist?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError
        nil
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
