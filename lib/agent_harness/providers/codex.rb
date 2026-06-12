# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module AgentHarness
  module Providers
    # OpenAI Codex CLI provider
    #
    # Provides integration with the OpenAI Codex CLI tool.
    class Codex < Base
      include RateLimitResetParsing
      include McpConfigFileSupport

      StreamingEvent = Struct.new(
        :type, :turn, :tokens, :error_message, :tool_name, :raw_event,
        keyword_init: true
      )

      SUPPORTED_CLI_VERSION = "0.122.0"
      SUPPORTED_CLI_REQUIREMENT = Gem::Requirement.new(">= #{SUPPORTED_CLI_VERSION}", "< 0.123.0").freeze
      OAUTH_REFRESH_FAILURE_PATTERNS = [
        /refresh_token_reused/i,
        /failed to refresh token\b.*\b401\b/im,
        /failed to refresh token\b.*unauthorized/im,
        /failed to refresh token\b.*\binvalid_client\b/im,
        /failed to refresh token\b.*\binvalid_grant\b/im,
        /failed to refresh token\b.*invalid.*refresh.*token/im,
        /failed to refresh token\b.*refresh.*token.*invalid/im,
        /your access token could not be refreshed because\b.*\b401\b/im,
        /your access token could not be refreshed because\b.*unauthorized/im,
        /your access token could not be refreshed because\b.*\binvalid_client\b/im,
        /your access token could not be refreshed because\b.*\binvalid_grant\b/im,
        /your access token could not be refreshed because\b.*invalid.*refresh.*token/im,
        /your access token could not be refreshed because\b.*refresh.*token.*invalid/im,
        /your access token could not be refreshed because\s+your refresh token .*already (?:been )?used/im,
        /refresh token .*already (?:been )?used/im
      ].freeze
      OAUTH_REFRESH_TRANSIENT_PATTERNS = [
        /your access token could not be refreshed because\s+(?:the\s+)?auth(?:entication)? service(?:\s+(?:is|was))?\s+(?:temporarily\s+)?unavailable/im,
        /your access token could not be refreshed because .*connection.*error/im,
        /failed to refresh token\b.*connection.*error/im,
        /failed to refresh token\b.*service(?:\s+(?:is|was))?\s+(?:temporarily\s+)?unavailable/im
      ].freeze

      SHARED_OUTPUT_ERROR_PATTERNS = {
        quota_exceeded: [
          /free tier limit reached/i,
          /please upgrade to a paid plan/i,
          /quota.*exceeded/i,
          /insufficient.*quota/i,
          /billing/i
        ],
        rate_limited: [
          /rate.?limit/i,
          /too.?many.?requests/i,
          /\b429\b/
        ],
        auth_expired: [
          /authentication_error/i,
          /invalid_grant/i,
          /Token is expired or invalid/i,
          /unauthorized/i
        ],
        sandbox_failure: [
          /bwrap.*no permissions/i,
          /no permissions to create a new namespace/i,
          /unprivileged.*namespace/i
        ],
        transient_error: [
          /timeout/i,
          /connection.*error/i,
          /service.*unavailable/i,
          /\b503\b/,
          /\b502\b/,
          /connection.*reset/i
        ]
      }.tap { |h| h.each_value(&:freeze) }.freeze

      STDOUT_ERROR_PATTERNS = SHARED_OUTPUT_ERROR_PATTERNS.merge(
        auth_expired: [
          /authentication_error/i,
          /invalid_grant/i,
          /Token is expired or invalid/i,
          /unauthorized/i
        ]
      ).tap { |h| h.each_value(&:freeze) }.freeze

      STDERR_ERROR_PATTERNS = SHARED_OUTPUT_ERROR_PATTERNS.merge(
        auth_expired: OAUTH_REFRESH_FAILURE_PATTERNS + [
          /invalid.*api.*key/i,
          /unauthorized/i,
          /authentication_error/i,
          /invalid_grant/i,
          /Token is expired or invalid/i,
          /\b401\b/,
          /incorrect.*api.*key/i
        ],
        transient_error: OAUTH_REFRESH_TRANSIENT_PATTERNS + SHARED_OUTPUT_ERROR_PATTERNS[:transient_error]
      ).tap { |h| h.each_value(&:freeze) }.freeze

      class << self
        def provider_name
          :codex
        end

        def binary_name
          "codex"
        end

        # Classify a chunk of output text from the provider CLI in real-time
        #
        # Can be called during streaming to classify both stdout and stderr
        # chunks as they arrive. For stdout, attempts to parse JSONL events
        # and extract error information from structured output.
        #
        # Because CommandExecutor reads arbitrary 4096-byte chunks, a single
        # JSONL event may be split across consecutive calls. Pass a String
        # buffer via +stdout_buffer+ that persists across calls so incomplete
        # trailing lines are re-assembled before parsing.
        #
        # @param text [String] the output chunk to classify
        # @param stream [:stdout, :stderr] which stream the text came from
        # @param stdout_buffer [String, nil] mutable String accumulator for
        #   incomplete stdout lines across calls (ignored for stderr)
        # @return [nil, Hash] nil if no error detected, or a Hash with
        #   :reason (Symbol)
        def classify_output_chunk(text, stream:, stdout_buffer: nil)
          return nil if text.nil? || text.strip.empty?

          case normalize_output_stream(stream)
          when :stdout
            classify_stdout_chunk(text, stdout_buffer)
          when :stderr
            classify_stderr_chunk(text)
          end
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

        def parse_cli_jsonl_transcript(raw_output, max_events: nil)
          return parser_instance.send(:parse_jsonl_output, "") if max_events && max_events <= 0

          output = max_events ? tail_nonempty_lines(raw_output, limit: max_events).join("\n") : raw_output

          parser_instance.send(:parse_jsonl_output, output)
        end

        # Parse a single Codex JSONL event as it arrives on stdout and classify it
        # for real-time progress tracking. Returns nil for malformed JSON, scalar
        # JSON values, plain-text output, or unsupported event types.
        def parse_streaming_event(line)
          event = JSON.parse(line.to_s)
          return unless event.is_a?(Hash)

          parser_instance.send(:build_streaming_event, event)
        rescue JSON::ParserError, TypeError
          nil
        end

        private

        def classify_stdout_chunk(text, buffer)
          # Prepend any leftover data from a previous partial chunk.
          data = buffer ? (buffer.slice!(0..-1) + text) : text

          lines = data.split("\n", -1)

          # If the chunk does not end with a newline the last element is an
          # incomplete line — stash it in the buffer for the next call.
          if buffer && !data.end_with?("\n")
            buffer.replace(lines.pop.to_s)
          end

          lines.each do |line|
            stripped = line.strip
            next if stripped.empty?

            event = parse_stdout_jsonl_event(stripped)
            next unless event

            result = classify_jsonl_event(event)
            return result if result
          end

          nil
        end

        def classify_stderr_chunk(text)
          match_patterns(text, STDERR_ERROR_PATTERNS)
        end

        def normalize_output_stream(stream)
          normalized_stream = case stream
          when Symbol
            stream
          when String
            stream.strip.to_sym
          end

          return normalized_stream if %i[stdout stderr].include?(normalized_stream)

          raise ArgumentError, "Unknown stream: #{stream.inspect}"
        end

        def parse_stdout_jsonl_event(text)
          escaped_newline_trimmed = text.sub(/(?:\\r)?\\n\z/, "")
          candidates = if escaped_newline_trimmed == text
            [text]
          else
            [text, escaped_newline_trimmed]
          end

          candidates.each do |candidate|
            return JSON.parse(candidate)
          rescue JSON::ParserError
            next
          end

          # Non-JSON stdout line — skip, only classify explicit error events
          nil
        end

        def classify_jsonl_event(event)
          return nil unless event.is_a?(Hash)

          payload = unwrap_classification_event(event)
          event = payload if payload.is_a?(Hash)

          # Only classify events with explicit error payloads — not normal
          # assistant messages whose text happens to contain error-ish words.
          error_text = extract_jsonl_error_text(event)
          return nil unless error_text

          match_patterns(error_text, STDOUT_ERROR_PATTERNS)
        end

        def extract_jsonl_error_text(event)
          # Direct error field (top-level "error" key)
          error = event["error"]
          return error if error.is_a?(String) && !error.empty?

          if error.is_a?(Hash)
            msg = error["message"]
            return msg if msg.is_a?(String) && !msg.empty?
          end

          return nil unless explicit_jsonl_error_event?(event["type"])

          # "message" appears on both error events and normal assistant output.
          # Restricting message-based extraction to explicit error event types
          # avoids false positives from user-facing assistant content.
          message = event["message"]
          return message if message.is_a?(String) && !message.empty?

          nil
        end

        def match_patterns(text, pattern_groups)
          pattern_groups.each do |category, patterns|
            if patterns.any? { |p| text.match?(p) }
              return {reason: category}
            end
          end

          nil
        end

        def parser_instance
          @parser_instance ||= allocate.freeze
        end

        def unwrap_classification_event(event)
          case event["type"]
          when "event_msg", "response_item"
            event["payload"]
          else
            event
          end
        end

        def explicit_jsonl_error_event?(event_type)
          %w[error turn.failed].include?(event_type)
        end

        def tail_nonempty_lines(text, limit:)
          return [] if limit <= 0

          text.to_s.each_line.each_with_object([]) do |line, lines|
            stripped = line.strip
            next if stripped.empty?

            lines.shift if lines.size >= limit
            lines << stripped
          end
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
          mcp: true,
          dangerous_mode: true
        }
      end

      def api_key_env_var_names = ["OPENAI_API_KEY"]

      def api_key_unset_vars = ["OPENAI_BASE_URL", "OPENAI_HEADER_X_AGENT_RUN_ID", "OPENAI_HEADER_X_PROXY_TOKEN"]

      def subscription_unset_vars = ["OPENAI_API_KEY", "OPENAI_BASE_URL"] + api_key_unset_vars

      def cli_env_overrides = {"PAID_CODEX_SUBSCRIPTION_AUTH" => "1"}

      def send_message(prompt:, **options)
        super
      ensure
        cleanup_mcp_tempfiles!
      end

      def supports_mcp?
        true
      end

      def supported_mcp_transports
        %w[stdio http sse]
      end

      def build_mcp_flags(mcp_servers, working_dir: nil)
        return [] if mcp_servers.empty?

        config_path = write_mcp_config_file(mcp_servers, working_dir: working_dir)
        ["--mcp-config", config_path]
      end

      def test_command_overrides
        ["--skip-git-repo-check", "--output-last-message", "/tmp/codex-smoke-output.txt"]
      end

      def dangerous_mode_flags
        ["--full-auto"]
      end

      def token_usage_from_api_response(body)
        usage = body&.dig("usage")
        return {} unless usage

        {
          input_tokens: usage["prompt_tokens"].to_i,
          output_tokens: usage["completion_tokens"].to_i
        }
      end

      def execution_semantics
        {
          prompt_delivery: :arg,
          output_format: :json,
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
            /your access token could not be refreshed.*(?:timeout|timed.?out)/im,
            /failed to refresh token\b.*(?:timeout|timed.?out)/im
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

      def error_classification_patterns
        super.merge(
          auth_expired: [
            /refresh_token_reused/i,
            /refresh token has already been used/i,
            /Please log out and sign in again/i,
            /authentication_error/i,
            /invalid_grant/i,
            /Token is expired or invalid/i
          ],
          abort: [
            /free tier limit reached/i,
            /please upgrade to a paid plan/i,
            /bwrap.*no permissions/i,
            /no permissions to create a new namespace/i,
            /unprivileged.*namespace/i
          ]
        )
      end

      def translate_error(message)
        case message
        when /refresh_token_reused/i then "Codex authentication expired. Please re-authenticate."
        when /free tier limit/i then "Codex free tier limit reached."
        else message
        end
      end

      def auth_status
        auth_status_for_env({})
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

      def preflight_check(env:, timeout: 10)
        auth = auth_status_for_env(env)
        return {healthy: false, reason: auth[:error], error_category: :authentication} unless auth[:valid]

        version = codex_cli_version(env: env, timeout: timeout)
        unless version
          return {
            healthy: false,
            reason: "Codex CLI version check failed. Ensure 'codex' is installed and available in PATH.",
            error_category: :installation
          }
        end

        unless SUPPORTED_CLI_REQUIREMENT.satisfied_by?(version)
          return {
            healthy: false,
            reason: "Unsupported Codex CLI version #{version}. Expected #{SUPPORTED_CLI_REQUIREMENT}.",
            error_category: :installation
          }
        end

        check_base_url_reachability(env: env, timeout: timeout)
      rescue => e
        {healthy: false, reason: "Codex preflight failed: #{e.message}"}
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

      def config_file_content(options = {})
        <<~TOML
          [chatgpt]
          model_provider = "#{escape_toml_string(options[:model_provider])}"
          base_url = "#{escape_toml_string(options[:base_url])}"
          env_key = "#{escape_toml_string(options[:env_key])}"
          wire_api = "#{escape_toml_string(options[:wire_api])}"
        TOML
      end

      def notify_hook_content
        <<~TOML

          [notify]
          # Paid notification hook
        TOML
      end

      def auth_lock_config
        {path: "/tmp/codex-auth.lock", timeout: 30}
      end

      protected

      def parse_response(result, duration:)
        output = result.stdout
        error = nil
        tokens = nil
        legitimate = execution_semantics[:legitimate_exit_codes] || [0]

        unless legitimate.include?(result.exit_code)
          combined = [result.stderr, result.stdout]
            .map { |stream| stream.to_s.strip }
            .reject(&:empty?)
            .join("\n")
          error = combined unless combined.empty?
        end

        parsed = parse_jsonl_output(output)
        if parsed
          output = parsed[:text].nil? ? output : parsed[:text]
          tokens = parsed[:tokens]
        end

        response = Response.new(
          output: output,
          exit_code: result.exit_code,
          duration: duration,
          provider: self.class.provider_name,
          model: @config.model,
          tokens: tokens,
          metadata: {
            legitimate_exit_codes: legitimate
          },
          error: error
        )

        if response.success? && sandbox_failure_detected?(result.stderr)
          return Response.new(
            output: output,
            exit_code: 1,
            duration: duration,
            provider: self.class.provider_name,
            model: @config.model,
            tokens: tokens,
            metadata: {
              legitimate_exit_codes: legitimate
            },
            error: "Sandbox failure detected: #{result.stderr.strip}"
          )
        end

        response
      end

      def build_command(prompt, options)
        cmd = [self.class.binary_name, "exec", "--json"]
        externally_sandboxed = externally_sandboxed?(options)
        runtime = options[:provider_runtime]

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

        # Add MCP server flags (validated/normalized by Base#send_message)
        if options[:mcp_servers]&.any?
          cmd += build_mcp_flags(options[:mcp_servers])
        end

        if options[:session]
          cmd += session_flags(options[:session])
        end
        if runtime
          cmd += ["--model", runtime.model] if runtime.model
          runtime_flags = runtime.flags
          # Strip --full-auto from runtime flags when externally sandboxed.
          runtime_flags -= dangerous_mode_flags if externally_sandboxed
          cmd += runtime_flags unless runtime_flags.empty?
        end

        cmd += test_command_overrides if options[:smoke_test]

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

      def auth_status_for_env(env)
        api_key = env_fetch(env, "OPENAI_API_KEY")
        # Fall back to process ENV when the provided env hash does not override auth keys
        if api_key.nil? && !env.key?("OPENAI_API_KEY") && !env.key?(:OPENAI_API_KEY)
          api_key = ENV["OPENAI_API_KEY"]
        end

        if api_key.nil? || api_key.strip.empty?
          credentials = read_codex_credentials_for_env(env)
          if credentials
            key = credentials["api_key"] || credentials["apiKey"] || credentials["OPENAI_API_KEY"]
            if key.is_a?(String) && !key.strip.empty?
              if key.strip.start_with?("sk-")
                return {valid: true, expires_at: nil, error: nil, auth_method: :config_file}
              end

              return {
                valid: false,
                expires_at: nil,
                error: "Config file API key is set but does not appear to be a valid OpenAI API key",
                auth_method: nil
              }
            end
          end

          return {
            valid: false,
            expires_at: nil,
            error: "No OpenAI API key found. Set OPENAI_API_KEY or configure in #{codex_config_path_for_env(env)}",
            auth_method: nil
          }
        end

        if api_key.strip.start_with?("sk-")
          {valid: true, expires_at: nil, error: nil, auth_method: :api_key}
        else
          {
            valid: false,
            expires_at: nil,
            error: "OPENAI_API_KEY is set but does not appear to be a valid OpenAI API key",
            auth_method: nil
          }
        end
      rescue IOError, JSON::ParserError => e
        {valid: false, expires_at: nil, error: e.message, auth_method: nil}
      end

      def codex_cli_version(env:, timeout:)
        result = @executor.execute([self.class.binary_name, "--version"], timeout: timeout, env: env)
        version_string = [result.stdout, result.stderr].join("\n")[/(\d+\.\d+\.\d+)/, 1]
        return nil unless version_string

        Gem::Version.new(version_string)
      rescue # rubocop prefers bare rescue; in Ruby this catches StandardError, not Exception/SignalException
        nil
      end

      def check_base_url_reachability(env:, timeout:)
        uri = codex_base_url_uri(env)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = timeout
        http.read_timeout = timeout
        http.write_timeout = timeout if http.respond_to?(:write_timeout=)

        response = http.start do |client|
          head_response = client.request(Net::HTTP::Head.new(uri))

          if http_success_or_redirect?(head_response) || http_auth_rejection?(head_response)
            head_response
          else
            client.request(Net::HTTP::Get.new(uri))
          end
        end

        return {healthy: true} if http_success_or_redirect?(response)

        response_code = response.code.to_i
        # 401/403 confirm the endpoint exists and is reachable; auth is
        # validated separately by auth_status_for_env.
        return {healthy: true} if http_auth_rejection?(response)
        if invalid_base_url_response_code?(response_code)
          return {
            healthy: false,
            reason: "Codex API base URL #{uri} returned HTTP #{response.code}. Check OPENAI_BASE_URL; the configured URL appears to point at an invalid API path.",
            error_category: :configuration
          }
        end

        {
          healthy: false,
          reason: "Codex API base URL #{uri} returned HTTP #{response.code}. Check OPENAI_BASE_URL, proxy configuration, and network policy.",
          error_category: (response_code >= 500) ? :transient : :configuration
        }
      rescue URI::InvalidURIError => e
        {
          healthy: false,
          reason: e.message.start_with?("OPENAI_BASE_URL") ? e.message : "OPENAI_BASE_URL is invalid. Check the configured URL format.",
          error_category: :configuration
        }
      rescue SocketError, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError => e
        {
          healthy: false,
          reason: "Codex API base URL #{env_fetch(env, "OPENAI_BASE_URL") || "https://api.openai.com"} is unreachable: #{e.message}. Check DNS, proxy settings, and network policy.",
          error_category: :transient
        }
      end

      def codex_base_url_uri(env)
        raw_url = env_fetch(env, "OPENAI_BASE_URL")
        # Only fall back to the default URL; do not read process ENV here, as the
        # caller may have intentionally omitted OPENAI_BASE_URL to use the default.
        raw_url = "https://api.openai.com" if raw_url.nil? || raw_url.empty?

        uri = URI.parse(raw_url)

        unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty?
          raise URI::InvalidURIError,
            "OPENAI_BASE_URL must be an absolute HTTP or HTTPS URL (got #{raw_url.inspect})"
        end

        uri.path = "/" if uri.path.nil? || uri.path.empty?
        uri
      end

      def env_fetch(env, key)
        return env[key] if env.key?(key)
        return env[key.to_sym] if env.key?(key.to_sym)

        nil
      end

      def http_success_or_redirect?(response)
        response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPRedirection)
      end

      def http_auth_rejection?(response)
        [401, 403].include?(response.code.to_i)
      end

      def invalid_base_url_response_code?(response_code)
        [404, 410].include?(response_code)
      end

      def build_streaming_event(event)
        raw_event, payload, dispatch_type = unwrap_streaming_event(event)
        return unless payload.is_a?(Hash)

        case dispatch_type
        when "message.delta", "agent_message_delta"
          build_progress_streaming_event(raw_event, payload)
        when "turn.completed", "task_complete", "turn_complete"
          build_turn_complete_streaming_event(raw_event, payload)
        when "turn.failed"
          build_error_streaming_event(raw_event, payload)
        when "item.completed", "response_item", "agent_message"
          build_item_streaming_event(raw_event, payload)
        when "token_count"
          build_token_usage_streaming_event(raw_event, payload)
        end
      end

      def unwrap_streaming_event(event)
        event_type = event["type"]

        if event_type == "event_msg"
          payload = event["payload"]
          [event, payload, payload.is_a?(Hash) ? payload["type"] : nil]
        elsif event_type == "response_item"
          # Preserve the original "response_item" dispatch type so
          # build_streaming_event routes to build_item_streaming_event
          # even after unwrapping the inner payload.
          [event, event["payload"], "response_item"]
        else
          [event, event, event_type]
        end
      end

      def build_progress_streaming_event(raw_event, payload)
        return unless progress_payload?(payload)

        StreamingEvent.new(
          type: :progress,
          turn: extract_streaming_turn(payload),
          raw_event: raw_event
        )
      end

      def build_turn_complete_streaming_event(raw_event, payload)
        StreamingEvent.new(
          type: :turn_complete,
          turn: extract_streaming_turn(payload),
          tokens: compact_streaming_tokens(build_token_usage(payload["usage"])),
          raw_event: raw_event
        )
      end

      def build_error_streaming_event(raw_event, payload)
        StreamingEvent.new(
          type: :error,
          turn: extract_streaming_turn(payload),
          tokens: compact_streaming_tokens(build_token_usage(payload["usage"])),
          error_message: extract_error_message(payload),
          raw_event: raw_event
        )
      end

      def build_item_streaming_event(raw_event, payload)
        item = payload["item"].is_a?(Hash) ? payload["item"] : payload

        if tool_use_payload?(item)
          return StreamingEvent.new(
            type: :tool_use,
            turn: extract_streaming_turn(payload),
            tool_name: extract_tool_name(item),
            raw_event: raw_event
          )
        end

        return unless assistant_message_item?(item) || response_item_assistant_payload?(item) || wrapped_assistant_payload?(item)

        StreamingEvent.new(
          type: :progress,
          turn: extract_streaming_turn(payload),
          raw_event: raw_event
        )
      end

      def build_token_usage_streaming_event(raw_event, payload)
        wrapped_token_usage = extract_wrapped_tokens(payload["info"])
        usage = wrapped_token_usage&.fetch(:last, nil) || wrapped_token_usage&.fetch(:total, nil)
        return unless usage

        StreamingEvent.new(
          type: :token_usage,
          turn: extract_streaming_turn(payload),
          tokens: compact_streaming_tokens(usage),
          raw_event: raw_event
        )
      end

      def progress_payload?(payload)
        case payload["type"]
        when "message.delta"
          payload["delta"].is_a?(Hash)
        when "agent_message_delta"
          wrapped_assistant_payload?(payload)
        else
          false
        end
      end

      def tool_use_payload?(item)
        item.is_a?(Hash) && item["type"] == "tool_call"
      end

      def extract_tool_name(item)
        item["tool_name"] || item["name"] || item.dig("function", "name") || item.dig("call", "name")
      end

      def extract_streaming_turn(payload)
        value = payload["turn"] || payload["turn_id"] || payload["turn_index"] || payload.dig("context", "turn")
        return value if value.is_a?(Integer)

        value.to_i if value.is_a?(String) && /\A\d+\z/.match?(value.strip)
      end

      def compact_streaming_tokens(usage)
        return unless usage

        {
          input: usage[:input],
          output: usage[:output],
          total: usage[:total]
        }
      end

      def extract_error_message(payload)
        error = payload["error"]

        case error
        when String
          error
        when Hash
          error["message"] || error["error"] || error["detail"]
        else
          payload["message"]
        end
      end

      def escape_toml_string(val)
        val.to_s.gsub("\\") { "\\\\" }.gsub('"') { "\\\"" }.gsub("\n") { "\\n" }
      end

      def parse_jsonl_output(raw_output)
        return nil if raw_output.nil? || raw_output.strip.empty?

        latest_completed_parts = []
        current_turn_parts = []
        total_input = 0
        total_output = 0
        total_tokens = 0
        has_usage = false
        saw_assistant_output = false
        pending_turn_usage = nil
        pending_turn_usage_source = nil
        pending_wrapped_output_parts = nil
        pending_wrapped_same_turn_finalization = false
        turn_completed = false
        current_turn_finalized_output = false

        commit_pending_turn = lambda do
          next unless pending_turn_usage

          total_input += pending_turn_usage[:input]
          total_output += pending_turn_usage[:output]
          total_tokens += pending_turn_usage[:total]
          pending_turn_usage = nil
          pending_turn_usage_source = nil
          pending_wrapped_output_parts = nil
          pending_wrapped_same_turn_finalization = false
        end

        start_new_turn = lambda do
          next unless turn_completed

          commit_pending_turn.call
          turn_completed = false
          current_turn_finalized_output = false
        end

        start_new_finalized_turn = lambda do
          start_new_turn.call
        end

        start_new_streaming_turn = lambda do
          start_new_turn.call
          next unless pending_turn_usage_source == :wrapped && pending_turn_usage && current_turn_finalized_output

          latest_completed_parts = current_turn_parts.dup
          commit_pending_turn.call
          current_turn_parts = []
          current_turn_finalized_output = false
        end

        replace_current_turn_parts = lambda do |parts|
          next if parts.nil?

          current_turn_parts = parts
          saw_assistant_output = true
          current_turn_finalized_output = true
        end

        finalize_current_turn = lambda do
          latest_completed_parts = current_turn_parts.dup
          current_turn_parts = []
          turn_completed = true
          current_turn_finalized_output = false
        end

        finalize_pending_wrapped_turn = lambda do
          next unless pending_turn_usage_source == :wrapped && pending_turn_usage

          wrapped_output_parts = pending_wrapped_output_parts || current_turn_parts
          latest_completed_parts = wrapped_output_parts.dup
          current_turn_parts = [] if current_turn_parts.equal?(wrapped_output_parts)
          commit_pending_turn.call
          turn_completed = false
          current_turn_finalized_output = false
        end

        fail_current_turn = lambda do
          latest_completed_parts = []
          current_turn_parts = []
          turn_completed = true
          current_turn_finalized_output = false
        end

        process_event = lambda do |event|
          next unless event.is_a?(Hash)

          type = event["type"]

          case type
          when "message.delta"
            start_new_streaming_turn.call
            appended = append_delta_text(current_turn_parts, event["delta"])
            current_turn_finalized_output = false if appended
            saw_assistant_output ||= appended
          when "agent_message_delta"
            next unless wrapped_assistant_payload?(event)

            start_new_streaming_turn.call
            appended = append_wrapped_delta_text(current_turn_parts, event)
            current_turn_finalized_output = false if appended
            saw_assistant_output ||= appended
          when "agent_message"
            next unless wrapped_assistant_payload?(event)

            wrapped_same_turn_finalization =
              pending_turn_usage_source == :wrapped &&
              pending_turn_usage &&
              (
                !current_turn_finalized_output ||
                pending_wrapped_same_turn_finalization
              )
            start_new_turn.call
            replace_current_turn_parts.call(extract_message_content_parts(event))
            pending_wrapped_same_turn_finalization = wrapped_same_turn_finalization
          when "task_complete", "turn_complete"
            completion_parts = extract_task_complete_parts(event)
            next if completion_parts.nil?

            wrapped_same_turn_finalization =
              pending_turn_usage_source == :wrapped &&
              pending_turn_usage &&
              (
                !current_turn_finalized_output ||
                pending_wrapped_same_turn_finalization
              )
            start_new_turn.call
            replace_current_turn_parts.call(completion_parts)
            pending_wrapped_same_turn_finalization = wrapped_same_turn_finalization
          when "item.completed"
            item = event["item"]
            next unless item.is_a?(Hash)
            next unless assistant_message_item?(item)

            start_new_finalized_turn.call
            replace_current_turn_parts.call(extract_message_content_parts(item))
            pending_wrapped_same_turn_finalization =
              pending_turn_usage_source == :wrapped && pending_turn_usage
          when "turn.completed"
            turn_usage = build_token_usage(event["usage"])
            result = event["result"]
            result_parts = result.is_a?(String) ? [result] : extract_task_complete_parts(event)
            wrapped_completion_without_new_output =
              pending_turn_usage_source == :wrapped &&
              pending_turn_usage &&
              result_parts.nil? &&
              (turn_usage.nil? || current_turn_parts.empty? || current_turn_parts.equal?(pending_wrapped_output_parts))

            if wrapped_completion_without_new_output
              if pending_wrapped_output_parts && !current_turn_parts.empty? && !current_turn_parts.equal?(pending_wrapped_output_parts)
                commit_pending_turn.call
                finalize_current_turn.call
                if turn_usage
                  has_usage = true
                  pending_turn_usage = turn_usage
                  pending_turn_usage_source = :turn_completed
                  pending_wrapped_same_turn_finalization = false
                end
                next
              end

              wrapped_output_parts = pending_wrapped_output_parts || current_turn_parts
              latest_completed_parts = wrapped_output_parts.dup
              current_turn_parts = [] if current_turn_parts.equal?(wrapped_output_parts)
              commit_pending_turn.call
              if turn_usage
                has_usage = true
                total_input += turn_usage[:input]
                total_output += turn_usage[:output]
                total_tokens += turn_usage[:total]
              end
              turn_completed = true
              current_turn_finalized_output = false
              next
            end

            same_streaming_wrapped_turn =
              pending_turn_usage_source == :wrapped &&
              pending_wrapped_output_parts&.equal?(current_turn_parts) &&
              !current_turn_finalized_output
            same_wrapped_turn = pending_turn_usage_source == :wrapped &&
              same_turn_usage?(pending_turn_usage, turn_usage) &&
              (
                same_turn_output?(current_turn_parts, current_turn_finalized_output, result) ||
                same_streaming_wrapped_turn
              )

            finalize_pending_wrapped_turn.call unless same_wrapped_turn

            if turn_completed && !same_wrapped_turn
              commit_pending_turn.call
              turn_completed = false
            end

            if turn_usage
              has_usage = true
              turn_usage = merge_same_turn_usage(pending_turn_usage, turn_usage) if same_wrapped_turn
              pending_turn_usage = turn_usage
              pending_turn_usage_source = :turn_completed
              pending_wrapped_same_turn_finalization = false
            end

            if result_parts
              current_turn_parts = result_parts
              saw_assistant_output = true
              current_turn_finalized_output = true
            end

            finalize_current_turn.call
          when "turn.failed"
            turn_usage = build_token_usage(event["usage"])
            same_streaming_wrapped_turn =
              pending_turn_usage_source == :wrapped &&
              pending_wrapped_output_parts&.equal?(current_turn_parts) &&
              !current_turn_finalized_output
            same_finalized_wrapped_turn =
              pending_turn_usage_source == :wrapped &&
              pending_wrapped_same_turn_finalization &&
              current_turn_finalized_output
            same_wrapped_turn = pending_turn_usage_source == :wrapped &&
              same_turn_usage?(pending_turn_usage, turn_usage) &&
              (
                pending_wrapped_output_parts&.equal?(current_turn_parts) ||
                same_streaming_wrapped_turn ||
                same_finalized_wrapped_turn
              )

            finalize_pending_wrapped_turn.call unless same_wrapped_turn

            if turn_completed && !same_wrapped_turn
              commit_pending_turn.call
              turn_completed = false
            end

            if turn_usage
              has_usage = true
              turn_usage = merge_same_turn_usage(pending_turn_usage, turn_usage) if same_wrapped_turn
              pending_turn_usage = turn_usage
              pending_turn_usage_source = :turn_completed
              pending_wrapped_same_turn_finalization = false
            end

            fail_current_turn.call
          when "event_msg"
            payload = event["payload"]
            next unless payload.is_a?(Hash)

            case payload["type"]
            when "agent_message_delta"
              next unless wrapped_assistant_payload?(payload)

              start_new_streaming_turn.call
              appended = append_wrapped_delta_text(current_turn_parts, payload)
              current_turn_finalized_output = false if appended
              saw_assistant_output ||= appended
            when "agent_message"
              next unless wrapped_assistant_payload?(payload)

              wrapped_same_turn_finalization =
                pending_turn_usage_source == :wrapped &&
                pending_turn_usage &&
                (
                  !current_turn_finalized_output ||
                  pending_wrapped_same_turn_finalization
                )
              start_new_turn.call
              replace_current_turn_parts.call(extract_message_content_parts(payload))
              pending_wrapped_same_turn_finalization = wrapped_same_turn_finalization
            when "task_complete", "turn_complete"
              completion_parts = extract_task_complete_parts(payload)
              next if completion_parts.nil?

              wrapped_same_turn_finalization =
                pending_turn_usage_source == :wrapped &&
                pending_turn_usage &&
                (
                  !current_turn_finalized_output ||
                  pending_wrapped_same_turn_finalization
                )
              start_new_turn.call
              replace_current_turn_parts.call(completion_parts)
              pending_wrapped_same_turn_finalization = wrapped_same_turn_finalization
            when "token_count"
              wrapped_token_usage = extract_wrapped_tokens(payload["info"])
              if wrapped_token_usage
                has_usage = true
                if wrapped_token_usage_starts_new_turn?(pending_turn_usage, pending_turn_usage_source, turn_completed, wrapped_token_usage)
                  commit_pending_turn.call
                  turn_completed = false
                end
                pending_turn_usage, pending_turn_usage_source = merge_wrapped_turn_usage(
                  pending_turn_usage,
                  pending_turn_usage_source,
                  wrapped_token_usage
                )
                pending_wrapped_output_parts =
                  (pending_turn_usage_source == :wrapped) ? current_turn_parts : nil
              end
            end
          when "response_item"
            payload = event["payload"]
            next unless payload.is_a?(Hash) && response_item_assistant_payload?(payload)

            start_new_finalized_turn.call
            replace_current_turn_parts.call(extract_message_content_parts(payload))
            pending_wrapped_same_turn_finalization =
              pending_turn_usage_source == :wrapped && pending_turn_usage
          end
        end

        raw_output.each_line do |line|
          line = line.strip
          next if line.empty?

          begin
            event = JSON.parse(line)
          rescue JSON::ParserError
            next
          end

          process_event.call(event)
        end

        commit_pending_turn.call
        final_parts = current_turn_parts.empty? ? latest_completed_parts : current_turn_parts
        text = if final_parts.empty?
          (turn_completed && saw_assistant_output) ? "" : nil
        else
          final_parts.join
        end

        {
          text: text,
          tokens: has_usage ? {
            input: total_input,
            output: total_output,
            total: total_tokens
          } : nil
        }
      rescue JSON::ParserError => e
        AgentHarness.logger&.warn("[AgentHarness::Codex] JSONL parse error: #{e.message}")
        nil
      rescue => e
        AgentHarness.logger&.warn("[AgentHarness::Codex] Unexpected error parsing JSONL output: #{e.class}: #{e.message}")
        nil
      end

      def append_delta_text(parts, delta)
        return false unless delta.is_a?(Hash)

        delta_parts = extract_delta_content_parts(delta)
        return false if delta_parts.nil?

        appended = false
        delta_parts.each do |part|
          next if part.empty?

          parts << part
          appended = true
        end

        appended
      end

      def append_wrapped_delta_text(parts, payload)
        delta_parts = extract_wrapped_delta_parts(payload)
        return false if delta_parts.nil?

        appended = false
        delta_parts.each do |part|
          next if part.empty?

          parts << part
          appended = true
        end

        appended
      end

      def assistant_message_item?(item)
        item_role = item["role"]
        item_type = item["type"]
        item_item_type = item["item_type"]
        message_shaped_item =
          (
            message_item_type?(item_type) ||
            item_type == "agent_message"
          ) && assistant_message_item_type?(item_item_type)

        (
          item_role == "assistant" && message_shaped_item
        ) || (
          item_role.nil? && message_shaped_item && (
            item_type == "agent_message" ||
            item_item_type == "assistant_message"
          )
        )
      end

      def wrapped_assistant_payload?(payload)
        role = payload["role"]
        item_type = payload["item_type"]

        assistant_message_item_type?(item_type) &&
          (role == "assistant" || role.nil?)
      end

      def response_item_assistant_payload?(payload)
        payload_type = payload["type"]
        payload_role = payload["role"]
        payload_item_type = payload["item_type"]
        assistant_message_type = payload_type == "assistant_message"

        return false unless assistant_message_item_type?(payload_item_type)

        ((message_item_type?(payload_type) || payload_type == "agent_message" || assistant_message_type) && payload_role == "assistant") ||
          (payload_type == "agent_message" && (
            payload_role == "assistant" ||
            (payload_role.nil? && assistant_message_item_type?(payload_item_type))
          )) ||
          (
            assistant_message_type && (
              payload_role == "assistant" ||
              (payload_role.nil? && assistant_message_item_type?(payload_item_type))
            )
          ) ||
          (
            payload_role.nil? &&
            message_item_type?(payload_type) &&
            payload_item_type == "assistant_message"
          )
      end

      def assistant_message_item_type?(item_type)
        item_type.nil? || item_type == "assistant_message"
      end

      def message_item_type?(item_type)
        item_type.nil? || item_type == "message"
      end

      def extract_message_content_parts(item)
        item_text = item["text"]
        return [item_text] if item_text.is_a?(String) && !item_text.empty?

        item_message = item["message"]
        return [item_message] if item_message.is_a?(String) && !item_message.empty?

        if item_text.is_a?(String)
          return extract_fallback_content_parts(item, item_text)
        end

        if item_message.is_a?(String)
          return extract_fallback_content_parts(item, item_message)
        end

        item_content = item["content"]
        return nil unless item_content.is_a?(Array)

        extract_content_parts(item_content)
      end

      def extract_fallback_content_parts(item, empty_value)
        item_content = item["content"]
        return [empty_value] unless item_content.is_a?(Array)

        content_parts = extract_content_parts(item_content)
        content_parts.nil? ? [empty_value] : content_parts
      end

      def extract_wrapped_delta_parts(payload)
        delta = payload["delta"]
        if delta.is_a?(Hash)
          delta_parts = extract_delta_content_parts(delta)
          return delta_parts unless delta_parts.nil?
        end

        extract_delta_content_parts(payload)
      end

      def extract_task_complete_parts(payload)
        last_agent_message = payload["last_agent_message"]
        return [last_agent_message] if last_agent_message.is_a?(String)
        return nil unless last_agent_message.is_a?(Hash)
        return nil unless completed_assistant_message_payload?(last_agent_message)

        extract_message_content_parts(last_agent_message)
      end

      def completed_assistant_message_payload?(payload)
        payload_role = payload["role"]
        payload_type = payload["type"]
        payload_item_type = payload["item_type"]
        message_shaped_payload =
          (
            message_item_type?(payload_type) ||
            payload_type == "agent_message" ||
            payload_type == "assistant_message"
          ) && assistant_message_item_type?(payload_item_type)

        (
          payload_role == "assistant" && message_shaped_payload
        ) || (
          payload_role.nil? && message_shaped_payload && (
            payload_type.nil? ||
            payload_type == "agent_message" ||
            payload_type == "assistant_message" ||
            payload_item_type == "assistant_message"
          )
        )
      end

      def extract_delta_content_parts(item)
        direct_parts = extract_message_content_parts(item)
        return direct_parts unless direct_parts == [""]

        item_content = item["content"]
        return direct_parts unless item_content.is_a?(Array)

        content_parts = extract_content_parts(item_content)
        content_parts.nil? ? direct_parts : content_parts
      end

      def output_text_block?(block)
        block_type = block["type"]

        block_type.nil? || block_type == "output_text" || block_type == "output_text_delta"
      end

      def extract_content_parts(item_content)
        completed_parts = []
        extracted_content = false

        item_content.each do |block|
          next unless block.is_a?(Hash)
          next unless output_text_block?(block)

          block_text = block["text"]
          next unless block_text.is_a?(String)

          extracted_content = true
          completed_parts << block_text
        end

        extracted_content ? completed_parts : nil
      end

      def extract_wrapped_tokens(info)
        return unless info.is_a?(Hash)

        last_usage = build_token_usage(info["last_token_usage"])
        total_usage = build_token_usage(info["total_token_usage"])

        return unless last_usage || total_usage

        {last: last_usage, total: total_usage}
      end

      def token_usage_fields_present?(usage)
        usage.is_a?(Hash) && (
          !parse_token_count(usage["input_tokens"]).nil? ||
          !parse_token_count(usage["cached_input_tokens"]).nil? ||
          !parse_token_count(usage["output_tokens"]).nil? ||
          !parse_token_count(usage["total_tokens"]).nil?
        )
      end

      def build_token_usage(usage)
        return unless token_usage_fields_present?(usage)

        input_value = parse_token_count(usage["input_tokens"])
        cached_input_value = parse_token_count(usage["cached_input_tokens"])
        output_value = parse_token_count(usage["output_tokens"])
        total_value = parse_token_count(usage["total_tokens"])

        input = (input_value || 0) + (cached_input_value || 0)
        output = output_value || 0
        total = total_value || (input + output)

        {
          input: input,
          output: output,
          total: total,
          input_reported: !input_value.nil? || !cached_input_value.nil?,
          output_reported: !output_value.nil?,
          total_reported: !total_value.nil?
        }
      end

      def merge_wrapped_turn_usage(existing_usage, existing_source, wrapped_token_usage)
        total_usage = wrapped_token_usage[:total]
        last_usage = wrapped_token_usage[:last]

        if existing_source == :turn_completed
          replacement_usage = merged_wrapped_usage(existing_usage, existing_source, last_usage, total_usage)
          return [existing_usage, existing_source] unless replacement_usage

          return [merge_same_turn_usage(existing_usage, replacement_usage), :turn_completed]
        end

        merged_usage = merged_wrapped_usage(existing_usage, existing_source, last_usage, total_usage)
        [merged_usage, :wrapped]
      end

      def merged_wrapped_usage(existing_usage, existing_source, last_usage, total_usage)
        if last_usage
          replacement_usage = last_usage
          if total_usage && same_turn_usage?(replacement_usage, total_usage)
            replacement_usage = merge_same_turn_usage(replacement_usage, total_usage)
          end

          return replacement_usage unless existing_source == :wrapped && existing_usage

          merged_usage = add_token_usage(existing_usage, last_usage)
          if total_usage && same_turn_usage?(merged_usage, total_usage)
            return merge_same_turn_usage(merged_usage, total_usage)
          end

          return replacement_usage if total_usage && same_turn_usage?(last_usage, total_usage)

          return merged_usage
        end

        total_usage
      end

      def wrapped_token_usage_starts_new_turn?(existing_usage, existing_source, turn_completed, wrapped_token_usage)
        return false unless turn_completed && existing_source == :turn_completed && existing_usage

        candidate_usage = wrapped_token_usage[:total] || wrapped_token_usage[:last]
        return false unless candidate_usage

        return false if same_turn_usage?(existing_usage, candidate_usage)

        existing_detailed = existing_usage[:input_reported] && existing_usage[:output_reported]
        candidate_detailed = candidate_usage[:input_reported] && candidate_usage[:output_reported]
        existing_total_only = existing_usage[:total_reported] && !existing_detailed
        candidate_total_only = candidate_usage[:total_reported] && !candidate_detailed

        return true if existing_detailed && candidate_detailed
        return true if existing_total_only && candidate_detailed

        existing_total_only && candidate_total_only
      end

      def add_token_usage(left, right)
        {
          input: left[:input] + right[:input],
          output: left[:output] + right[:output],
          total: left[:total] + right[:total],
          input_reported: left[:input_reported] || right[:input_reported],
          output_reported: left[:output_reported] || right[:output_reported],
          total_reported: left[:total_reported] || right[:total_reported]
        }
      end

      def merge_same_turn_usage(left, right)
        return right unless left
        return left unless right

        merged_input_reported = left[:input_reported] || right[:input_reported]
        merged_output_reported = left[:output_reported] || right[:output_reported]
        merged_total_reported = left[:total_reported] || right[:total_reported]

        input = if right[:input_reported]
          right[:input]
        elsif left[:input_reported]
          left[:input]
        else
          0
        end

        output = if right[:output_reported]
          right[:output]
        elsif left[:output_reported]
          left[:output]
        else
          0
        end

        total = if right[:total_reported]
          right[:total]
        elsif left[:total_reported]
          left[:total]
        else
          input + output
        end

        {
          input: input,
          output: output,
          total: total,
          input_reported: merged_input_reported,
          output_reported: merged_output_reported,
          total_reported: merged_total_reported
        }
      end

      def same_turn_usage?(left, right)
        return false unless left && right

        detailed_usage_matches = left[:input_reported] &&
          right[:input_reported] &&
          left[:output_reported] &&
          right[:output_reported]
        return left[:input] == right[:input] && left[:output] == right[:output] if detailed_usage_matches

        mixed_total_match = (
          left[:input_reported] &&
          left[:output_reported] &&
          right[:total_reported]
        ) || (
          right[:input_reported] &&
          right[:output_reported] &&
          left[:total_reported]
        )
        return left[:total] == right[:total] if mixed_total_match

        left[:total_reported] && right[:total_reported] && left[:total] == right[:total]
      end

      def same_turn_output?(current_turn_parts, current_turn_finalized_output, result)
        return true if current_turn_parts.empty?
        return false unless current_turn_finalized_output
        return true unless result.is_a?(String)

        current_turn_parts.join == result
      end

      def parse_token_count(value)
        case value
        when Integer
          value if value >= 0
        when String
          stripped = value.strip
          return nil unless /\A\d+\z/.match?(stripped)

          stripped.to_i
        end
      end

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
        read_codex_credentials_for_env({})
      end

      def read_codex_credentials_for_env(env)
        path = codex_config_path_for_env(env)
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
        codex_config_path_for_env({})
      end

      def codex_config_path_for_env(env)
        config_dir = env_fetch(env, "CODEX_CONFIG_DIR")
        config_dir = ENV["CODEX_CONFIG_DIR"] if config_dir.nil? || config_dir.empty?
        config_dir = File.expand_path("~/.codex") if config_dir.nil? || config_dir.empty?
        File.join(config_dir, "config.json")
      end

      def mcp_provider_key
        :codex
      end
    end
  end
end
