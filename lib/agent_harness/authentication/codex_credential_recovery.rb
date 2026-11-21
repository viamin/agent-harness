# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "net/http"
require "pathname"
require "tempfile"
require "timeout"
require "time"
require "uri"

module AgentHarness
  module Authentication
    # Bounded refresh of one explicitly selected Codex native auth.json file.
    class CodexCredentialRecovery
      DEFAULT_TIMEOUT = 45
      MAX_TIMEOUT = 60
      DEFAULT_ENDPOINT = URI("https://auth.openai.com/oauth/token").freeze
      DEFAULT_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
      CHATGPT_MODES = [nil, "chatgpt"].freeze
      PROVIDER_ERRORS = {
        "refresh_token_expired" => :refresh_token_expired,
        "refresh_token_reused" => :refresh_token_reused,
        "refresh_token_invalidated" => :refresh_token_revoked,
        "invalid_grant" => :invalid_refresh_token
      }.freeze

      def self.metadata(credential_path:)
        new(credential_path: credential_path).metadata
      end

      def initialize(credential_path:, expected_generation: nil, expected_account_id: nil,
        timeout: DEFAULT_TIMEOUT, clock: Time, http_factory: Net::HTTP)
        @path = validate_path(credential_path)
        @expected_generation = expected_generation
        @expected_account_id = expected_account_id
        @timeout = validate_timeout(timeout)
        @clock = clock
        @http_factory = http_factory
      end

      def metadata
        document, bytes = read_document
        native_metadata(document, bytes)
      rescue JSON::ParserError
        auth_error(:invalid_native_credentials, "Selected Codex credentials are not valid JSON")
      rescue IOError, SocketError, SystemCallError => error
        transport_error(error, "Selected Codex credentials could not be inspected")
      end

      def call
        validate_selection!
        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          original, original_bytes = read_document
          validate_original!(original, original_bytes)
          response = request_refresh(original.fetch("tokens"))
          updated = refreshed_document(original, response)
          persisted_bytes = compare_and_write!(original_bytes, updated)
          {credentials: updated, metadata: native_metadata(updated, persisted_bytes)}
        end
      rescue Timeout::Error
        auth_error(:deadline_exceeded, "Codex credential recovery exceeded its deadline")
      rescue JSON::ParserError
        auth_error(:invalid_native_credentials, "Selected Codex credentials are not valid JSON")
      rescue IOError, SocketError, SystemCallError => error
        transport_error(error, "Codex credential recovery could not complete")
      end

      private

      def validate_path(value)
        raise ArgumentError, "credential_path must be an absolute path" unless value.is_a?(String) && Pathname.new(value).absolute?

        value
      end

      def validate_timeout(value)
        unless value.is_a?(Numeric) && value.positive? && value <= MAX_TIMEOUT
          raise ArgumentError, "timeout must be greater than zero and at most #{MAX_TIMEOUT} seconds"
        end

        value
      end

      def validate_selection!
        unless @expected_generation.is_a?(String) && @expected_generation.match?(/\A[0-9a-f]{64}\z/)
          raise ArgumentError, "expected_generation must be a SHA-256 generation"
        end
        unless non_blank?(@expected_account_id)
          raise ArgumentError, "expected_account_id must be a non-empty string"
        end
      end

      def read_document
        bytes = File.binread(@path)
        document = JSON.parse(bytes)
        auth_error(:invalid_native_credentials, "Selected Codex credentials must be a JSON object") unless document.is_a?(Hash)
        [document, bytes]
      end

      def validate_original!(document, bytes)
        auth_error(:concurrent_update, "Selected Codex credentials changed before recovery") unless digest(bytes) == @expected_generation
        unless CHATGPT_MODES.include?(document["auth_mode"]) && document["OPENAI_API_KEY"].nil?
          auth_error(:unsupported_credential_type, "Selected Codex credentials are not managed ChatGPT OAuth material")
        end

        tokens = document["tokens"]
        auth_error(:invalid_native_credentials, "Selected Codex credentials have no native token object") unless tokens.is_a?(Hash)
        auth_error(:identity_mismatch, "Selected Codex credential identity does not match the authorized identity") unless tokens["account_id"] == @expected_account_id
        auth_error(:missing_refresh_material, "Selected Codex credentials have no reusable refresh material") unless non_blank?(tokens["refresh_token"])
        auth_error(:invalid_native_credentials, "Selected Codex credentials have no access token") unless non_blank?(tokens["access_token"])
      end

      def request_refresh(tokens)
        endpoint, client_id = authority(tokens)
        request = Net::HTTP::Post.new(endpoint)
        request.content_type = "application/json"
        request.body = JSON.generate(
          grant_type: "refresh_token",
          refresh_token: tokens.fetch("refresh_token"),
          client_id: client_id,
          refresh_reason: "unauthorized"
        )

        response = Timeout.timeout(@timeout) { http_for(endpoint).request(request) }
        parse_response(response)
      rescue Timeout::Error
        raise
      rescue IOError, SocketError, SystemCallError => error
        transport_error(error, "Codex OAuth authority was unavailable")
      end

      def authority(tokens)
        provenance = tokens["oauth_provenance"]
        return [DEFAULT_ENDPOINT, DEFAULT_CLIENT_ID] unless provenance.is_a?(Hash)

        issuer = URI(provenance["issuer"].to_s)
        client_id = provenance["client_id"]
        unless issuer.is_a?(URI::HTTPS) && issuer.host && non_blank?(client_id)
          auth_error(:invalid_native_credentials, "Selected Codex OAuth provenance is malformed")
        end
        [URI("#{issuer.to_s.delete_suffix("/")}/oauth/token"), client_id]
      rescue URI::InvalidURIError
        auth_error(:invalid_native_credentials, "Selected Codex OAuth provenance is malformed")
      end

      def http_for(endpoint)
        http = @http_factory.new(endpoint.host, endpoint.port)
        http.use_ssl = true
        http.open_timeout = [@timeout, 10].min
        http.read_timeout = @timeout
        http.write_timeout = @timeout if http.respond_to?(:write_timeout=)
        http
      end

      def parse_response(response)
        body = JSON.parse(response.body)
        unless response.is_a?(Net::HTTPSuccess)
          code = body.is_a?(Hash) && (body["error"] || body["code"])
          category = PROVIDER_ERRORS.fetch(code.to_s.downcase, :provider_rejected)
          auth_error(category, provider_error_message(category))
        end
        unless body.is_a?(Hash) && non_blank?(body["access_token"])
          auth_error(:malformed_response, "Codex OAuth authority returned an unusable response")
        end

        body
      rescue JSON::ParserError
        auth_error(:malformed_response, "Codex OAuth authority returned an unusable response")
      end

      def refreshed_document(original, response)
        updated = JSON.parse(JSON.generate(original))
        tokens = updated.fetch("tokens")
        assert_response_identity!(response.fetch("access_token"))
        assert_response_identity!(response["id_token"], require_expiry: false) if non_blank?(response["id_token"])
        tokens["access_token"] = response.fetch("access_token")
        tokens["id_token"] = response["id_token"] if non_blank?(response["id_token"])
        tokens["refresh_token"] = response["refresh_token"] if non_blank?(response["refresh_token"])
        updated["last_refresh"] = @clock.now.utc.iso8601
        updated
      end

      def assert_response_identity!(token, require_expiry: true)
        claims = jwt_claims(token)
        identity = claims.dig("https://api.openai.com/auth", "chatgpt_account_id")
        unless identity == @expected_account_id
          auth_error(:identity_mismatch, "Refreshed Codex credentials do not match the authorized identity")
        end
        if require_expiry && (!claims["exp"].is_a?(Numeric) || Time.at(claims["exp"]).utc <= @clock.now)
          auth_error(:malformed_response, "Codex OAuth authority returned an access token without a usable expiry")
        end
      rescue JSON::ParserError, ArgumentError
        auth_error(:malformed_response, "Codex OAuth authority returned an unusable access token")
      end

      def compare_and_write!(original_bytes, updated)
        current_bytes = File.binread(@path)
        auth_error(:concurrent_update, "Selected Codex credentials changed during recovery") unless current_bytes == original_bytes

        dir = File.dirname(@path)
        tempfile = Tempfile.new(".auth", dir)
        persisted_bytes = JSON.pretty_generate(updated)
        begin
          tempfile.write(persisted_bytes)
          tempfile.close
          File.chmod(0o600, tempfile.path)
          File.rename(tempfile.path, @path)
        ensure
          tempfile.close!
        end
        persisted_bytes
      end

      def native_metadata(document, bytes)
        tokens = document["tokens"]
        mode = CHATGPT_MODES.include?(document["auth_mode"]) && document["OPENAI_API_KEY"].nil?
        expiry = tokens.is_a?(Hash) ? jwt_expiry(tokens["access_token"]) : nil
        {
          provider: :codex,
          billing_mode: mode ? :chatgpt_subscription : :api_key,
          account_id: tokens.is_a?(Hash) ? tokens["account_id"] : nil,
          expires_at: expiry,
          expired: expiry ? expiry <= @clock.now : nil,
          refreshable: mode && tokens.is_a?(Hash) && non_blank?(tokens["refresh_token"]),
          generation: digest(bytes)
        }
      end

      def jwt_expiry(token)
        exp = jwt_claims(token)["exp"]
        Time.at(exp).utc if exp.is_a?(Numeric)
      rescue JSON::ParserError, ArgumentError, TypeError
        nil
      end

      def jwt_claims(token)
        parts = token.to_s.split(".")
        raise ArgumentError unless parts.length == 3 && parts.all? { |part| !part.empty? }

        JSON.parse(Base64.urlsafe_decode64(parts[1].ljust((parts[1].length + 3) / 4 * 4, "=")))
      end

      def provider_error_message(category)
        {
          refresh_token_expired: "Codex refresh material expired; sign in again",
          refresh_token_reused: "Codex refresh material was already used; select the newest generation or sign in again",
          refresh_token_revoked: "Codex refresh material was revoked; sign in again",
          invalid_refresh_token: "Codex refresh material was rejected; sign in again",
          provider_rejected: "Codex OAuth authority rejected credential recovery"
        }.fetch(category)
      end

      def auth_error(code, message, **context)
        raise AuthenticationError.new(message, provider: :codex, error_code: code, context: context)
      end

      def transport_error(error, message)
        auth_error(:transport_failure, message, cause_class: error.class.name)
      end

      def non_blank?(value) = value.is_a?(String) && !value.strip.empty?
      def digest(bytes) = Digest::SHA256.hexdigest(bytes)
      def lock_path = "#{@path}.lock"
    end
  end
end
