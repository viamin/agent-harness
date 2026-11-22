# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "net/http"
require "openssl"
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
      LOCK_POLL_INTERVAL = 0.01
      MIN_JWT_TIMESTAMP = -62_135_596_800
      MAX_JWT_TIMESTAMP = 253_402_300_799
      DEFAULT_ENDPOINT = URI("https://auth.openai.com/oauth/token").freeze
      APPROVED_ISSUER = URI("https://auth.openai.com").freeze
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
        deadline = monotonic_time + @timeout
        committed_result = nil
        Timeout.timeout(remaining_time(deadline), Timeout::Error) do
          recover(deadline) { |result| committed_result = result }
        end
      rescue Timeout::Error
        return committed_result if committed_result

        auth_error(:deadline_exceeded, "Codex credential recovery exceeded its deadline")
      rescue JSON::ParserError
        auth_error(:invalid_native_credentials, "Selected Codex credentials are not valid JSON")
      rescue IOError, SocketError, SystemCallError => error
        return committed_result if committed_result

        transport_error(error, "Codex credential recovery could not complete")
      end

      private

      # The deadline interrupt may only fire inside the +:immediate+ region so
      # the lock file's close in File.open's ensure cannot be interrupted by a
      # late or second Timeout::Error, nor by the Timeout::ExitException a
      # bare caller Timeout.timeout interrupts the thread with, guaranteeing
      # the lock is released. Deferred interrupts are redelivered when the
      # mask region exits, still inside any caller Timeout.timeout frame, so
      # the caller's frame keeps converting ExitException to Timeout::Error.
      def recover(deadline, &record_commit)
        Thread.handle_interrupt(Timeout::Error => :never, Timeout::ExitException => :never) do
          File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
            Thread.handle_interrupt(Timeout::Error => :immediate, Timeout::ExitException => :immediate) do
              acquire_lock(lock, deadline)
              rotate_under_lock(deadline, &record_commit)
            end
          end
        end
      end

      def rotate_under_lock(deadline, &record_commit)
        original, original_bytes = read_document
        validate_original!(original, original_bytes)
        response = request_refresh(original.fetch("tokens"), deadline)
        updated = refreshed_document(original, response)
        remaining_time(deadline)
        compare_and_write!(original_bytes, updated, &record_commit)
      end

      def validate_path(value)
        raise ArgumentError, "credential_path must be an absolute path" unless value.is_a?(String) && Pathname.new(value).absolute?

        value
      end

      def validate_timeout(value)
        unless finite_number?(value) && value.positive? && value <= MAX_TIMEOUT
          raise ArgumentError, "timeout must be greater than zero and at most #{MAX_TIMEOUT} seconds"
        end

        value
      end

      def acquire_lock(lock, deadline)
        loop do
          remaining = remaining_time(deadline)
          return if lock.flock(File::LOCK_EX | File::LOCK_NB)

          IO.select(nil, nil, nil, [remaining, LOCK_POLL_INTERVAL].min)
        end
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
        bytes = read_regular_file
        document = JSON.parse(bytes)
        auth_error(:invalid_native_credentials, "Selected Codex credentials must be a JSON object") unless document.is_a?(Hash)
        [document, bytes]
      end

      def read_regular_file
        File.open(@path, File::RDONLY | File::NONBLOCK) do |file|
          auth_error(:invalid_native_credentials, "Selected Codex credential path must be a regular file") unless file.stat.file?

          file.read
        end
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

      def request_refresh(tokens, deadline)
        endpoint, client_id = authority(tokens)
        request = Net::HTTP::Post.new(endpoint)
        request.content_type = "application/json"
        request.body = JSON.generate(
          grant_type: "refresh_token",
          refresh_token: tokens.fetch("refresh_token"),
          client_id: client_id,
          refresh_reason: "unauthorized"
        )

        remaining = remaining_time(deadline)
        response = Timeout.timeout(remaining, Timeout::Error) { http_for(endpoint, remaining).request(request) }
        parse_response(response).tap { remaining_time(deadline) }
      rescue Net::OpenTimeout, Net::ReadTimeout, IOError, OpenSSL::SSL::SSLError,
        SocketError, SystemCallError => error
        transport_error(error, "Codex OAuth authority was unavailable")
      end

      def authority(tokens)
        provenance = tokens["oauth_provenance"]
        return [DEFAULT_ENDPOINT, DEFAULT_CLIENT_ID] unless provenance.is_a?(Hash)

        issuer = URI(provenance["issuer"].to_s)
        client_id = provenance["client_id"]
        unless issuer == APPROVED_ISSUER && non_blank?(client_id)
          auth_error(:invalid_native_credentials, "Selected Codex OAuth provenance is malformed")
        end
        [URI("#{issuer.to_s.delete_suffix("/")}/oauth/token"), client_id]
      rescue URI::InvalidURIError
        auth_error(:invalid_native_credentials, "Selected Codex OAuth provenance is malformed")
      end

      def http_for(endpoint, timeout)
        http = @http_factory.new(endpoint.host, endpoint.port)
        http.use_ssl = true
        http.open_timeout = [timeout, 10].min
        http.read_timeout = timeout
        http.write_timeout = timeout if http.respond_to?(:write_timeout=)
        http
      end

      def parse_response(response)
        unless response.is_a?(Net::HTTPSuccess)
          code = provider_error_code(response.body)
          category = PROVIDER_ERRORS.fetch(code.to_s.downcase, :provider_rejected)
          auth_error(category, provider_error_message(category))
        end
        body = JSON.parse(response.body)
        unless body.is_a?(Hash) && non_blank?(body["access_token"])
          auth_error(:malformed_response, "Codex OAuth authority returned an unusable response")
        end

        body
      rescue JSON::ParserError, TypeError
        auth_error(:malformed_response, "Codex OAuth authority returned an unusable response")
      end

      def provider_error_code(body)
        parsed = JSON.parse(body)
        return unless parsed.is_a?(Hash)

        error = parsed["error"]
        error = error["code"] if error.is_a?(Hash)
        error || parsed["code"]
      rescue JSON::ParserError, TypeError
        nil
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
        auth_claim = claims["https://api.openai.com/auth"]
        if !auth_claim.nil? && !auth_claim.is_a?(Hash)
          auth_error(:malformed_response, "Codex OAuth authority returned an unusable access token")
        end
        identity = auth_claim&.fetch("chatgpt_account_id", nil)
        unless identity == @expected_account_id
          auth_error(:identity_mismatch, "Refreshed Codex credentials do not match the authorized identity")
        end
        if require_expiry && ((expiry = timestamp(claims["exp"])).nil? || expiry <= @clock.now)
          auth_error(:malformed_response, "Codex OAuth authority returned an access token without a usable expiry")
        end
      rescue JSON::ParserError, ArgumentError, TypeError
        auth_error(:malformed_response, "Codex OAuth authority returned an unusable access token")
      end

      def compare_and_write!(original_bytes, updated)
        dir = File.dirname(@path)
        tempfile = Tempfile.new(".auth", dir)
        snapshot = Tempfile.new(".auth-snapshot", dir)
        snapshot_path = snapshot.path
        persisted_bytes = JSON.pretty_generate(updated)
        begin
          tempfile.write(persisted_bytes)
          tempfile.close
          File.chmod(0o600, tempfile.path)
          snapshot.close!
          File.link(@path, snapshot_path)
          verify_generation!(snapshot_path, original_bytes)
          # Both interrupt forms are deferred so the committed rename, the
          # concurrent-write restore, and the commit record stay atomic
          # against bare caller watchdogs as well.
          Thread.handle_interrupt(Timeout::Error => :never, Timeout::ExitException => :never) do
            File.rename(tempfile.path, @path)
            restore_concurrent_in_place_write!(snapshot_path, original_bytes)
            yield(credentials: updated, metadata: native_metadata(updated, persisted_bytes))
          end
        ensure
          tempfile.close!
          File.unlink(snapshot_path) if File.exist?(snapshot_path)
        end
      end

      def verify_generation!(path, original_bytes)
        return if File.binread(path) == original_bytes

        auth_error(:concurrent_update, "Selected Codex credentials changed during recovery")
      end

      def restore_concurrent_in_place_write!(snapshot_path, original_bytes)
        return if File.binread(snapshot_path) == original_bytes

        File.rename(snapshot_path, @path)
        auth_error(:concurrent_update, "Selected Codex credentials changed during recovery")
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
        timestamp(jwt_claims(token)["exp"])
      rescue JSON::ParserError, ArgumentError, TypeError
        nil
      end

      def jwt_claims(token)
        parts = token.to_s.split(".")
        raise ArgumentError unless parts.length == 3 && parts.all? { |part| !part.empty? }

        claims = JSON.parse(Base64.urlsafe_decode64(parts[1].ljust((parts[1].length + 3) / 4 * 4, "=")))
        raise TypeError unless claims.is_a?(Hash)

        claims
      end

      def timestamp(value)
        return unless finite_number?(value) && value.between?(MIN_JWT_TIMESTAMP, MAX_JWT_TIMESTAMP)

        Time.at(value).utc
      rescue RangeError
        nil
      end

      def finite_number?(value)
        value.is_a?(Numeric) && !value.is_a?(Complex) && (!value.respond_to?(:finite?) || value.finite?)
      end

      def remaining_time(deadline)
        remaining = deadline - monotonic_time
        raise Timeout::Error unless remaining.positive?

        remaining
      end

      def monotonic_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

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
