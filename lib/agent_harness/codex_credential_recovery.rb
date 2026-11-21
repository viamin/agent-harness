# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "net/http"
require "pathname"
require "tempfile"
require "time"
require "uri"

module AgentHarness
  # Performs one bounded refresh of an explicitly selected native Codex store.
  class CodexCredentialRecovery
    ENDPOINT = URI("https://auth.openai.com/oauth/token").freeze
    CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
    MAX_TIMEOUT = 45.0

    def initialize(credentials_path:, timeout: 30, http_factory: Net::HTTP, clock: Time)
      @path = validate_path(credentials_path)
      @timeout = validate_timeout(timeout)
      @http_factory = http_factory
      @clock = clock
    end

    def call
      with_lock do
        original_bytes, credentials = read_credentials
        tokens = validate_credentials(credentials)
        response = exchange(tokens.fetch("refresh_token"))
        updated = build_updated_credentials(credentials, tokens, response)
        recovery_result = result(updated)
        persist_if_unchanged(original_bytes, updated)
        recovery_result
      end
    rescue AuthenticationError, ArgumentError
      raise
    rescue JSON::ParserError, IOError, SystemCallError => e
      raise recovery_error("Codex credential store is unavailable or malformed", :invalid_credential_shape, e)
    end

    private

    def validate_path(path)
      unless path.is_a?(String) && !path.empty? && Pathname.new(path).absolute?
        raise ArgumentError, "credentials_path must be an explicit absolute path"
      end
      File.expand_path(path)
    end

    def validate_timeout(timeout)
      value = Float(timeout)
      raise ArgumentError unless value.positive? && value <= MAX_TIMEOUT
      value
    rescue TypeError, ArgumentError
      raise ArgumentError, "timeout must be greater than zero and at most #{MAX_TIMEOUT.to_i} seconds"
    end

    def with_lock
      File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
        unless lock.flock(File::LOCK_EX | File::LOCK_NB)
          raise recovery_error("Codex credential store is busy", :credential_store_busy)
        end
        yield
      end
    end

    def read_credentials
      bytes = File.binread(@path)
      parsed = JSON.parse(bytes)
      raise JSON::ParserError, "root is not an object" unless parsed.is_a?(Hash)
      [bytes, parsed]
    end

    def validate_credentials(credentials)
      validate_auth_mode(credentials)
      if credentials["OPENAI_API_KEY"].is_a?(String) && !credentials["OPENAI_API_KEY"].empty?
        raise recovery_error("Selected Codex store uses API-key authentication", :api_key_credential)
      end
      tokens = credentials["tokens"]
      raise recovery_error("Selected Codex store has no native OAuth token set", :invalid_credential_shape) unless tokens.is_a?(Hash)
      refresh_token = tokens["refresh_token"]
      unless refresh_token.is_a?(String) && !refresh_token.strip.empty?
        raise recovery_error("Selected Codex OAuth credential has no refresh material", :missing_refresh_material)
      end
      unless identity(tokens)
        raise recovery_error("Selected Codex OAuth credential has no account identity", :missing_account_identity)
      end
      tokens
    end

    def validate_auth_mode(credentials)
      mode = credentials["auth_mode"]
      return if mode.nil? && !alternate_auth_material?(credentials)
      return if mode == "chatgpt"

      raise recovery_error("Selected Codex store is not managed ChatGPT OAuth", :unsupported_auth_mode)
    end

    def alternate_auth_material?(credentials)
      %w[agent_identity personal_access_token bedrock_api_key].any? { |key| credentials[key] }
    end

    def exchange(refresh_token)
      http = @http_factory.new(ENDPOINT.host, ENDPOINT.port)
      http.use_ssl = true
      http.open_timeout = [@timeout, 10].min
      http.read_timeout = @timeout
      request = Net::HTTP::Post.new(ENDPOINT.path)
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(grant_type: "refresh_token", refresh_token: refresh_token, client_id: CLIENT_ID)
      parse_response(http.request(request))
    rescue AuthenticationError
      raise
    rescue Timeout::Error => e
      raise recovery_error("Codex OAuth refresh deadline exceeded", :deadline_exceeded, e)
    rescue IOError, SystemCallError => e
      raise recovery_error("Codex OAuth refresh transport failed", :transport_failure, e)
    end

    def parse_response(response)
      body = JSON.parse(response.body)
      return validate_response(body) if response.is_a?(Net::HTTPSuccess)
      code = body["error"]
      code = code["code"] if code.is_a?(Hash)
      raise recovery_error("Codex OAuth refresh was rejected", error_category(code, response.code))
    rescue JSON::ParserError
      raise recovery_error("Codex OAuth refresh returned a malformed response", :malformed_response)
    end

    def validate_response(body)
      unless body.is_a?(Hash) && non_blank?(body["access_token"])
        raise recovery_error("Codex OAuth refresh returned incomplete credentials", :malformed_response)
      end
      body
    end

    def error_category(code, status)
      return :refresh_token_expired if code.to_s.casecmp?("refresh_token_expired")
      return :refresh_token_reused if code.to_s.casecmp?("refresh_token_reused")
      return :refresh_token_revoked if code.to_s.casecmp?("refresh_token_invalidated")
      return :invalid_refresh_token if [400, 401].include?(status.to_i)
      :provider_failure
    end

    def build_updated_credentials(credentials, previous_tokens, response)
      updated = deep_copy(credentials)
      tokens = updated.fetch("tokens")
      tokens["access_token"] = response.fetch("access_token")
      tokens["refresh_token"] = response["refresh_token"] if non_blank?(response["refresh_token"])
      tokens["id_token"] = response["id_token"] if non_blank?(response["id_token"])
      preserve_identity!(previous_tokens, tokens)
      updated["last_refresh"] = @clock.now.utc.iso8601(6)
      updated
    end

    def preserve_identity!(previous, updated)
      previous_id = identity(previous)
      updated_id = token_identity(updated)
      if previous_id && !updated_id
        raise recovery_error("Codex OAuth refresh returned no verifiable account identity", :malformed_response)
      end
      if previous_id && updated_id && previous_id != updated_id
        raise recovery_error("Codex OAuth refresh changed account identity", :identity_mismatch)
      end
      updated["account_id"] = previous["account_id"] if previous.key?("account_id")
    end

    def identity(tokens)
      tokens["account_id"] || token_identity(tokens)
    end

    def token_identity(tokens)
      token_account_id(tokens["access_token"]) || token_account_id(tokens["id_token"])
    end

    def token_account_id(token)
      claims = jwt_claims(token)
      claims.dig("https://api.openai.com/auth", "chatgpt_account_id") || claims["chatgpt_account_id"]
    end

    def jwt_claims(token)
      return {} unless non_blank?(token) && token.count(".") >= 2
      part = token.split(".")[1]
      JSON.parse(Base64.urlsafe_decode64(part.ljust((part.length + 3) / 4 * 4, "=")))
    rescue ArgumentError, JSON::ParserError
      {}
    end

    def persist_if_unchanged(original_bytes, credentials)
      unless File.binread(@path) == original_bytes
        raise recovery_error("Codex credentials changed during refresh", :credential_generation_changed)
      end
      dir = File.dirname(@path)
      tempfile = Tempfile.new(".auth", dir)
      begin
        tempfile.write(JSON.pretty_generate(credentials))
        tempfile.flush
        tempfile.fsync
        tempfile.close
        File.chmod(0o600, tempfile.path)
        File.rename(tempfile.path, @path)
      ensure
        tempfile.close! if tempfile.path && File.exist?(tempfile.path)
      end
    end

    def result(credentials)
      tokens = credentials.fetch("tokens")
      expires_at = expiry(jwt_claims(tokens["access_token"]))
      raise recovery_error("Codex OAuth refresh returned no reliable expiry", :malformed_response) unless expires_at
      {
        credentials: deep_copy(credentials),
        expires_at: expires_at,
        account_id: identity(tokens),
        generation: Digest::SHA256.hexdigest(JSON.generate(credentials)),
        auth_mode: :subscription
      }
    end

    def expiry(claims)
      value = claims["exp"]
      Time.at(value).utc if value.is_a?(Numeric)
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end

    def non_blank?(value)
      value.is_a?(String) && !value.strip.empty?
    end

    def recovery_error(message, code, original = nil)
      AuthenticationError.new(message, provider: :codex, error_code: code, original_error: original)
    end
  end
end
