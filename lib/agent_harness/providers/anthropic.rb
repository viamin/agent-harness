# frozen_string_literal: true

require "json"
require "shellwords"

module AgentHarness
  module Providers
    # Anthropic Claude Code CLI provider
    #
    # Provides integration with the Claude Code CLI tool for AI-powered
    # coding assistance.
    #
    # @example Basic usage
    #   provider = AgentHarness::Providers::Anthropic.new
    #   response = provider.send_message(prompt: "Hello!")
    class Anthropic < Base
      include RateLimitResetParsing
      include McpConfigFileSupport

      # Anthropic rate-limit response headers exposing quota/rate information.
      # These are surfaced on normal /v1/messages responses and parsed by
      # {#update_quota_from_headers} to opportunistically refresh cached quota
      # without making a dedicated API call.
      RATE_LIMIT_HEADER_LIMIT = "anthropic-ratelimit-tokens-limit"
      RATE_LIMIT_HEADER_REMAINING = "anthropic-ratelimit-tokens-remaining"
      RATE_LIMIT_HEADER_RESET = "anthropic-ratelimit-tokens-reset"

      # Model name pattern for Anthropic Claude models
      MODEL_PATTERN = /^claude-[\d.-]+-(?:opus|sonnet|haiku)(?:-\d{8})?$/i
      SUPPORTED_CLI_VERSION = "2.1.238"
      SUPPORTED_CLI_REQUIREMENT = Gem::Requirement.new(">= #{SUPPORTED_CLI_VERSION}", "< 2.2.0").freeze

      # Matches semver (e.g. "2.1.92"), optional pre-release (e.g. "2.1.92-beta.1"),
      # or channel tokens (e.g. "latest", "stable").
      VALID_VERSION_PATTERN = /\A(?:\d+\.\d+\.\d+(?:-[a-zA-Z0-9.]+)?|latest|stable)\z/

      class << self
        def provider_name
          :claude
        end

        def binary_name
          "claude"
        end

        def install_contract(version: nil)
          target_version = version.nil? ? SUPPORTED_CLI_VERSION : version
          target_version = target_version.strip if target_version.respond_to?(:strip)
          validate_version!(target_version)
          version_requirement = SUPPORTED_CLI_REQUIREMENT.requirements
            .map { |op, ver| "#{op} #{ver}" }
            .join(", ")
          channel_token = %w[latest stable].include?(target_version.to_s)

          warning = "Review the downloaded installer before execution and verify any published checksum or signature metadata when available."
          if channel_token
            warning += " Channel '#{target_version}' is not pinned; the resolved version may fall " \
              "outside the supported range (#{version_requirement}). Verify the installed version " \
              "after installation."
          end

          {
            provider: provider_name,
            binary_name: binary_name,
            binary_paths: [
              "$HOME/.local/bin/claude",
              binary_name
            ],
            install: {
              strategy: :shell,
              source: "official",
              command: "tmp_script=$(mktemp) && trap 'rm -f \"$tmp_script\"' EXIT && curl -fsSL https://claude.ai/install.sh -o \"$tmp_script\" && bash \"$tmp_script\" #{Shellwords.shellescape(target_version)}",
              warning: warning,
              post_install_binary_path: "$HOME/.local/bin/claude",
              # When a channel token is used, include the requirement so
              # consumers can validate the installed version post-install.
              version_not_pinned: channel_token
            },
            supported_versions: {
              default: SUPPORTED_CLI_VERSION,
              requirement: version_requirement,
              channel: "stable"
            },
            runtime_contract: {
              available_via: binary_name,
              build_command: [
                binary_name,
                "--print",
                "--output-format=json"
              ],
              required_features: [
                "print_mode",
                "json_output",
                "mcp_config",
                "mcp_list",
                "dangerously_skip_permissions",
                "models_list"
              ]
            }
          }
        end

        def available?
          executor = AgentHarness.configuration.command_executor
          !!executor.which(binary_name)
        end

        def provider_metadata_overrides
          {
            auth: {
              service: :anthropic,
              api_family: :anthropic
            },
            identity: {
              bot_usernames: %w[claude anthropic]
            }
          }
        end

        def firewall_requirements
          {
            domains: [
              "api.anthropic.com",
              "claude.ai",
              "console.anthropic.com"
            ],
            ip_ranges: []
          }
        end

        def instruction_file_paths
          [
            {
              path: "CLAUDE.md",
              description: "Claude Code CLI agent instructions",
              symlink: true
            }
          ]
        end

        def discover_models
          return [] unless available?

          begin
            require "open3"
            output, _, status = Open3.capture3("claude", "models", "list", {timeout: 10})
            return [] unless status.success?

            parse_models_list(output)
          rescue => e
            AgentHarness.logger&.debug("[AgentHarness::Anthropic] Model discovery failed: #{e.message}")
            []
          end
        end

        # Normalize a provider-specific model name to its model family
        def model_family(provider_model_name)
          provider_model_name.sub(/-\d{8}$/, "")
        end

        # Convert a model family name to the provider's preferred model name
        def provider_model_name(family_name)
          family_name
        end

        # Check if this provider supports a given model family
        def supports_model_family?(family_name)
          MODEL_PATTERN.match?(family_name)
        end

        def supports_chat?
          true
        end

        def smoke_test_contract
          Base::DEFAULT_SMOKE_TEST_CONTRACT
        end

        # Parse a raw Claude CLI --output-format=json envelope into its components.
        #
        # Downstream callers that capture Claude CLI stdout directly (e.g. container
        # execution plans) can use this to extract the assistant text, error state,
        # token usage, and structured metadata without re-implementing the parsing.
        #
        # @param json_string [String] raw JSON envelope from Claude CLI stdout
        # @return [Hash, nil] parsed components or nil if not a valid envelope
        #   - :output [String] the assistant's final text (the "result" field)
        #   - :error [String, nil] error message if is_error was true
        #   - :tokens [Hash, nil] {input:, output:, total:} token counts
        #   - :metadata [Hash] structured metadata (cost_usd, session_id, etc.)
        def parse_cli_json_envelope(json_string)
          return nil if json_string.nil? || json_string.empty?

          cleaned = json_string.lines.reject { |line|
            line.include?('"type":"session.') || line.include?('"type": "session.')
          }.join.strip
          return nil if cleaned.empty?

          parsed = JSON.parse(cleaned)
          return nil unless parsed.is_a?(Hash) && parsed.key?("result")

          output = parsed["result"]
          error = nil

          if parsed["is_error"]
            error = classify_error_message(output || "Unknown Claude CLI error")
          end

          tokens = extract_tokens(parsed)
          metadata = extract_envelope_metadata(parsed)

          {output: output, error: error, tokens: tokens, metadata: metadata}
        rescue JSON::ParserError
          nil
        end

        private

        # Message fragments the Claude CLI emits when the local session is
        # missing or expired. Detected in the envelope's +result+ field even
        # when +subtype+ is "success", since Claude reports the failure
        # inside the payload rather than through the transport layer.
        #
        # Scoped to explicit expired / login-required phrases. A bare
        # "authentication" match would also fire on transient service
        # outages like "authentication service was unavailable", which
        # belong on the retry / provider-fallback path, not the re-auth
        # path.
        AUTH_FAILURE_FRAGMENTS = [
          "oauth token",
          "not logged in",
          "please run /login",
          "login required",
          "credentials expired",
          "session expired"
        ].freeze

        def classify_error_message(message)
          msg_lower = message.downcase

          if msg_lower.include?("rate limit") || msg_lower.include?("session limit")
            "Rate limit exceeded"
          elsif msg_lower.include?("deprecat") || msg_lower.include?("end-of-life")
            "Model deprecated"
          elsif authentication_failure_message?(msg_lower)
            "Authentication error"
          else
            message
          end
        end

        def authentication_failure_message?(message)
          return false if message.nil? || message.empty?

          msg_lower = message.downcase
          AUTH_FAILURE_FRAGMENTS.any? { |fragment| msg_lower.include?(fragment) }
        end

        def extract_tokens(parsed)
          usage = parsed["usage"]
          return nil unless usage

          input = usage["input_tokens"]
          output = usage["output_tokens"]
          return nil unless input || output

          input ||= 0
          output ||= 0

          {input: input, output: output, total: input + output}
        end

        def extract_envelope_metadata(parsed)
          meta = {}
          meta[:cost_usd] = parsed["total_cost_usd"] if parsed.key?("total_cost_usd")
          meta[:session_id] = parsed["session_id"] if parsed.key?("session_id")
          meta[:stop_reason] = parsed["stop_reason"] if parsed.key?("stop_reason")
          meta[:terminal_reason] = parsed["terminal_reason"] if parsed.key?("terminal_reason")
          meta[:num_turns] = parsed["num_turns"] if parsed.key?("num_turns")
          meta[:duration_ms] = parsed["duration_ms"] if parsed.key?("duration_ms")
          meta[:duration_api_ms] = parsed["duration_api_ms"] if parsed.key?("duration_api_ms")
          meta
        end

        def validate_version!(version)
          unless version.is_a?(String) && !version.strip.empty?
            raise ArgumentError, "Invalid version: #{version.inspect}. " \
              "Must be a semver string (e.g. '2.1.92'), optional pre-release suffix, or a channel token ('latest', 'stable')."
          end

          version_str = version.strip

          unless VALID_VERSION_PATTERN.match?(version_str)
            raise ArgumentError, "Invalid version: #{version.inspect}. " \
              "Must be a semver string (e.g. '2.1.92'), optional pre-release suffix, or a channel token ('latest', 'stable')."
          end

          return if %w[latest stable].include?(version_str)

          gem_version = begin
            Gem::Version.new(version_str)
          rescue ArgumentError
            raise ArgumentError, "Invalid version: #{version.inspect}. " \
              "Must be a semver string (e.g. '2.1.92'), optional pre-release suffix, or a channel token ('latest', 'stable')."
          end
          return if SUPPORTED_CLI_REQUIREMENT.satisfied_by?(gem_version)

          raise ArgumentError, "Version #{version.inspect} is outside the supported range " \
            "(#{SUPPORTED_CLI_REQUIREMENT}). Update SUPPORTED_CLI_REQUIREMENT before targeting this version."
        end

        def parse_models_list(output)
          return [] if output.nil? || output.empty?

          models = []
          lines = output.lines.map(&:strip)

          # Skip header and separator lines
          lines.reject! { |line| line.empty? || line.match?(/^[-=]+$/) || line.match?(/^(Model|Name)/i) }

          lines.each do |line|
            model_info = parse_model_line(line)
            models << model_info if model_info
          end

          models
        end

        def parse_model_line(line)
          # Format 1: Simple list of model names
          if line.match?(/^claude-\d/)
            model_name = line.split.first
            return build_model_info(model_name)
          end

          # Format 2: Table format with columns
          parts = line.split(/\s{2,}/)
          if parts.size >= 1 && parts[0].match?(/^claude/)
            model_name = parts[0]
            model_name = "#{model_name}-#{parts[1]}" if parts.size > 1 && parts[1].match?(/^\d{8}$/)
            return build_model_info(model_name)
          end

          nil
        end

        def build_model_info(model_name)
          family = model_family(model_name)
          tier = classify_tier(model_name)

          {
            name: model_name,
            family: family,
            tier: tier,
            capabilities: extract_capabilities(model_name),
            context_window: infer_context_window(family),
            provider: "anthropic"
          }
        end

        def classify_tier(model_name)
          name_lower = model_name.downcase
          return "advanced" if name_lower.include?("opus")
          return "mini" if name_lower.include?("haiku")
          return "standard" if name_lower.include?("sonnet")
          "standard"
        end

        def extract_capabilities(model_name)
          capabilities = ["chat", "code"]
          name_lower = model_name.downcase
          capabilities << "vision" unless name_lower.include?("haiku")
          capabilities
        end

        def infer_context_window(family)
          family.match?(/claude-3/) ? 200_000 : nil
        end
      end

      def name
        "anthropic"
      end

      def display_name
        "Anthropic Claude CLI"
      end

      def configuration_schema
        {
          fields: [
            {
              name: :model,
              type: :string,
              label: "Model",
              required: false,
              hint: "Claude model to use (e.g. claude-3-5-sonnet-20241022)",
              accepts_arbitrary: false
            }
          ],
          auth_modes: [:oauth],
          openai_compatible: false
        }
      end

      def capabilities
        {
          streaming: true,
          file_upload: true,
          vision: true,
          tool_use: true,
          json_mode: true,
          mcp: true,
          dangerous_mode: true
        }
      end

      def send_message(prompt:, **options)
        if options[:mode] == :text
          options = normalize_provider_runtime(options)
          skill_context = resolve_skills(options)
          prompt = apply_skills_to_prompt(prompt, skill_context)
          return send_text_message(prompt, **skill_context[:options].except(:mode, :skills))
        end

        super
      ensure
        cleanup_mcp_tempfiles!
      end

      def plan_execution(prompt:, **options)
        if options[:mode] == :text
          raise ProviderError,
            "Anthropic text mode uses the HTTP transport and does not produce a CLI execution plan"
        end

        super
      ensure
        cleanup_mcp_tempfiles!
      end

      def api_key_env_var_names = ["ANTHROPIC_API_KEY"]

      def api_key_unset_vars = ["ANTHROPIC_BASE_URL", "ANTHROPIC_HEADER_X_AGENT_RUN_ID", "ANTHROPIC_HEADER_X_PROXY_TOKEN"]

      def subscription_unset_vars = ["ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL"] + api_key_unset_vars

      # Opportunistically refresh quota info from Anthropic rate-limit headers
      # observed on a normal /v1/messages response.
      #
      # @param headers [Hash{String=>String}, Net::HTTPHeader] response headers
      # @return [AgentHarness::QuotaStatus, nil]
      def update_quota_from_headers(headers)
        limit_value = header_value(headers, RATE_LIMIT_HEADER_LIMIT)
        remaining_value = header_value(headers, RATE_LIMIT_HEADER_REMAINING)
        return nil unless limit_value || remaining_value

        QuotaStatus.new(
          available: true,
          remaining: remaining_value&.to_i,
          limit: limit_value&.to_i,
          reset_at: parse_rate_limit_header_reset(headers),
          unit: :tokens
        )
      end

      def supports_mcp?
        true
      end

      def supported_mcp_transports
        %w[stdio http sse]
      end

      def build_mcp_flags(mcp_servers, working_dir: nil)
        config_path = write_mcp_config_file(mcp_servers, working_dir: working_dir)
        ["--mcp-config=#{config_path}"]
      end

      def supports_tool_control?
        true
      end

      def supports_text_mode?
        true
      end

      CHAT_MODELS = %w[claude-sonnet-4-20250514 claude-haiku-4-20250414 claude-opus-4-20250514].freeze

      def supports_chat?
        true
      end

      def chat_models
        CHAT_MODELS
      end

      def chat_transport
        @chat_transport ||= TextTransport.new(api_key: resolve_text_mode_api_key, logger: @logger)
      end

      def build_runtime_chat_transport(runtime)
        TextTransport.new(
          base_url: runtime.chat_base_url || TextTransport::ANTHROPIC_API_URL,
          api_key: runtime.chat_api_key || resolve_text_mode_api_key,
          logger: @logger
        )
      end

      def chat_transport_type
        :anthropic
      end

      def dangerous_mode_flags
        ["--dangerously-skip-permissions"]
      end

      def auth_type
        :oauth
      end

      def supports_token_counting?
        true
      end

      def token_usage_from_api_response(body)
        usage = body&.dig("usage")
        return {} unless usage

        {
          input_tokens: usage["input_tokens"].to_i,
          output_tokens: usage["output_tokens"].to_i
        }
      end

      def execution_semantics
        {
          prompt_delivery: :arg,
          output_format: :json,
          sandbox_aware: true,
          uses_subcommand: false,
          non_interactive_flag: "--print",
          legitimate_exit_codes: [0],
          stderr_is_diagnostic: true,
          parses_rate_limit_reset: false
        }
      end

      def error_patterns
        {
          rate_limited: [
            /rate.?limit/i,
            /too.?many.?requests/i,
            /\b429\b/,
            /overloaded/i,
            /session.?limit/i
          ],
          auth_expired: [
            /oauth.*token.*expired/i,
            /authentication.*error/i,
            /invalid.*api.*key/i,
            /unauthorized/i,
            /\b401\b/,
            /session.*expired/i,
            /not.*logged.*in/i,
            /login.*required/i,
            /credentials.*expired/i
          ],
          quota_exceeded: [
            /quota.*exceeded/i,
            /usage.*limit/i,
            /credit.*exhausted/i
          ],
          transient: [
            /timeout/i,
            /connection.*reset/i,
            /temporary.*error/i,
            /service.*unavailable/i,
            /\b503\b/,
            /\b502\b/,
            /\b504\b/
          ],
          permanent: [
            /invalid.*model/i,
            /unsupported.*operation/i,
            /not.*found/i,
            /\b404\b/,
            /bad.*request/i,
            /\b400\b/,
            /model.*deprecated/i,
            /end-of-life/i
          ]
        }
      end

      def error_classification_patterns
        super.merge(
          abort: [
            /free tier limit reached/i,
            /please upgrade to a paid plan/i
          ]
        )
      end

      def fetch_mcp_servers
        return [] unless self.class.available?

        begin
          result = @executor.execute(["claude", "mcp", "list"], timeout: 5)
          return [] unless result.success?

          parse_claude_mcp_output(result.stdout)
        rescue => e
          log_debug("fetch_mcp_servers_failed", error: e.message)
          []
        end
      end

      protected

      # All tools the Claude CLI exposes by default.
      # Used to build the --disallowedTools list when tools: :none is requested.
      ALL_CLI_TOOLS = %w[
        Agent
        Bash
        Read
        Edit
        Write
        Grep
        Glob
        WebFetch
        WebSearch
        TodoWrite
        NotebookEdit
      ].freeze

      def build_command(prompt, options)
        cmd = [self.class.binary_name]

        cmd += ["--print", "--output-format=json"]

        # Add model if specified — prefer config, fall back to runtime override
        runtime = options[:provider_runtime]
        runtime = ProviderRuntime.wrap(runtime) if runtime.is_a?(Hash)
        model = if @config.model && !@config.model.empty?
          @config.model
        else
          runtime&.model
        end
        if model && !model.empty?
          cmd += ["--model", model]
        end

        # Add permission mode for tool-disabled requests (belt-and-suspenders)
        if options[:tools]
          # Skip --permission-mode plan when dangerous_mode is active, since
          # --dangerously-skip-permissions would override it anyway.
          # The --disallowedTools flags still provide the primary protection.
          cmd += build_tool_control_flags(options[:tools], skip_permission_mode: options[:dangerous_mode])
        end

        # Add dangerous mode if requested
        if options[:dangerous_mode] && supports_dangerous_mode?
          cmd += dangerous_mode_flags
        end

        # Add MCP server flags (validated/normalized by Base#send_message).
        # Always pass --mcp-config, even with an empty server list, to suppress
        # the Claude CLI's auto-discovery of .mcp.json in the working directory.
        cmd += build_mcp_flags(options[:mcp_servers] || [])

        # Add custom flags from config
        cmd += @config.default_flags if @config.default_flags&.any?

        cmd << prompt

        cmd
      end

      def parse_response(result, duration:)
        output = result.stdout
        error = nil
        auth_source = nil
        tokens = nil
        metadata = {}

        parsed = parse_json_output(output)

        # Claude CLI can return `subtype: "success"` with `is_error: true`
        # (e.g. "Not logged in · Please run /login"); trust `is_error` and the
        # process exit code rather than the envelope subtype.
        envelope_error = parsed && parsed["is_error"]
        envelope_message = parsed && parsed["result"]

        if result.failed?
          combined = [result.stdout, result.stderr].compact.join("\n")
          error = classify_error_message(combined)
          # With an envelope present, restrict auth detection to stderr so
          # assistant `result` text mentioning "authentication" can't trip
          # a false positive. Without an envelope, the combined output is
          # our only window into CLI-reported auth failures.
          auth_source ||= parsed ? result.stderr : combined
        end

        if envelope_error
          error ||= classify_error_message(envelope_message || "Unknown Claude CLI error")
          # Prefer the envelope's own message for auth detection to avoid
          # false positives from assistant text that mentions "authentication".
          auth_source = envelope_message
        end

        raise_if_authentication_failure(auth_source)

        if parsed
          output = parsed["result"] || output
          tokens = extract_tokens(parsed)
          metadata = extract_envelope_metadata(parsed)
        end

        Response.new(
          output: output,
          exit_code: result.exit_code,
          duration: duration,
          provider: self.class.provider_name,
          model: @config.model,
          tokens: tokens,
          metadata: metadata,
          error: error
        )
      end

      def default_timeout
        300
      end

      private

      def send_text_message(prompt, **options)
        api_key = resolve_text_mode_api_key
        model = options[:model] || @config.model
        timeout = options[:timeout] || @config.timeout || default_timeout
        max_tokens = options[:max_tokens]

        transport = TextTransport.new(api_key: api_key, logger: @logger)

        kwargs = {model: model, timeout: timeout}
        kwargs[:max_tokens] = max_tokens if max_tokens

        response = transport.send_message(prompt, **kwargs)
        response = attach_quota_status_from_headers(response)

        # Apply runtime model override if present
        runtime = options[:provider_runtime]
        runtime = ProviderRuntime.wrap(runtime) if runtime.is_a?(Hash)
        if runtime&.model
          response = Response.new(
            output: response.output,
            exit_code: response.exit_code,
            duration: response.duration,
            provider: response.provider,
            model: runtime.model,
            tokens: response.tokens,
            metadata: response.metadata,
            error: response.error
          )
        end

        track_tokens(response) if response.tokens

        log_debug("send_text_message_complete",
          duration: response.duration,
          tokens: response.tokens,
          transport: :http)

        response
      end

      # Resolve the API key for text mode, validating that the caller's
      # credentials support direct API access without silently shifting
      # billing from subscription to API-metered usage.
      #
      # @return [String] the API key
      # @raise [AuthMismatchError] if no API key is available
      def resolve_text_mode_api_key
        api_key = ENV["ANTHROPIC_API_KEY"]

        if api_key.nil? || api_key.strip.empty?
          raise AuthMismatchError.new(
            "Text mode requires an ANTHROPIC_API_KEY for direct API access. " \
            "OAuth/subscription credentials cannot be used for HTTP transport " \
            "because it would silently shift billing to API-metered usage. " \
            "Set ANTHROPIC_API_KEY or use the default CLI mode instead.",
            provider: :claude
          )
        end

        api_key.strip
      end

      def parse_json_output(output)
        return nil if output.nil? || output.empty?

        cleaned = strip_claude_streaming_events(output)
        return nil if cleaned.empty?

        JSON.parse(cleaned)
      rescue JSON::ParserError
        nil
      end

      def strip_claude_streaming_events(output)
        output.lines.reject { |line|
          line.include?('"type":"session.') || line.include?('"type": "session.')
        }.join.strip
      end

      # Delegate to class-level implementations so both instance and class
      # methods share a single definition.
      def extract_envelope_metadata(parsed)
        self.class.send(:extract_envelope_metadata, parsed)
      end

      def extract_tokens(parsed)
        self.class.send(:extract_tokens, parsed)
      end

      def classify_error_message(message)
        self.class.send(:classify_error_message, message)
      end

      def authentication_failure_message?(message)
        self.class.send(:authentication_failure_message?, message)
      end

      # Raise AuthenticationError so callers (e.g. Conductor) can route to
      # re-auth handling instead of retrying through generic provider-error
      # paths. Fires when the source message (envelope's +result+ field, or
      # the raw combined process output when there is no envelope) matches
      # a Claude "not logged in" / session-expired signal.
      def raise_if_authentication_failure(source_message)
        return unless authentication_failure_message?(source_message)

        message = source_message.to_s.strip
        message = "Claude CLI reported an authentication failure" if message.empty?

        raise AuthenticationError.new(message, provider: self.class.provider_name)
      end

      def parse_claude_mcp_output(output)
        servers = []
        return servers unless output

        lines = output.lines
        lines.reject! { |line| /checking mcp server health/i.match?(line) }

        lines.each do |line|
          line = line.strip
          next if line.empty?

          # Parse format: "name: command - ✓ Connected"
          if line =~ /^([^:]+):\s*(.+?)\s*-\s*(✓|✗)\s*(.+)$/
            name = Regexp.last_match(1).strip
            command = Regexp.last_match(2).strip
            status_symbol = Regexp.last_match(3)
            status_text = Regexp.last_match(4).strip

            servers << {
              name: name,
              status: (status_symbol == "✓") ? "connected" : "error",
              description: command,
              enabled: status_symbol == "✓",
              error: (status_symbol == "✗") ? status_text : nil,
              source: "claude_cli"
            }
          end
        end

        servers
      end

      def mcp_provider_key
        :anthropic
      end

      def build_tool_control_flags(tools_option, skip_permission_mode: false)
        tool_names = case tools_option
        when :none
          ALL_CLI_TOOLS
        when Array
          tools_option
        else
          return []
        end

        return [] if tool_names.empty?

        flags = ["--disallowedTools=#{tool_names.join(",")}"]
        flags = ["--permission-mode", "plan"] + flags unless skip_permission_mode
        flags
      end

      def log_debug(action, **context)
        @logger&.debug("[AgentHarness::Anthropic] #{action}: #{context.inspect}")
      end

      # Read a header value from either a Net::HTTPHeader or a plain Hash.
      def header_value(headers, name)
        return headers[name] || headers[name.to_sym] if headers.respond_to?(:[])

        nil
      rescue NoMethodError
        nil
      end

      # Anthropic's ratelimit reset header is an RFC 3339 timestamp
      # (e.g. "2026-07-21T05:00:00Z"), per the API docs.
      def parse_rate_limit_header_reset(headers)
        raw = header_value(headers, RATE_LIMIT_HEADER_RESET)
        return nil unless raw

        Time.iso8601(raw.to_s).utc
      rescue ArgumentError
        nil
      end
    end
  end
end
