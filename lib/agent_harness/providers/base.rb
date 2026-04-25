# frozen_string_literal: true

module AgentHarness
  module Providers
    # Base class for all providers
    #
    # Provides common functionality for provider implementations including
    # command execution, error handling, and response parsing.
    #
    # @example Implementing a provider
    #   class MyProvider < AgentHarness::Providers::Base
    #     class << self
    #       def provider_name
    #         :my_provider
    #       end
    #
    #       def binary_name
    #         "my-cli"
    #       end
    #
    #       def available?
    #         system("which my-cli > /dev/null 2>&1")
    #       end
    #     end
    #   end
    class Base
      include Adapter

      DEFAULT_SMOKE_TEST_CONTRACT = {
        prompt: "Reply with exactly OK.",
        expected_output: "OK",
        timeout: 30,
        require_output: true,
        success_message: "Smoke test passed"
      }.freeze

      # Common error patterns shared across providers that use standard
      # HTTP-style error responses. Providers with unique patterns (e.g.
      # Anthropic, GitHub Copilot) override error_patterns entirely.
      COMMON_ERROR_PATTERNS = {
        rate_limited: [
          /rate.?limit/i,
          /too.?many.?requests/i,
          /\b429\b/
        ],
        auth_expired: [
          /invalid.*api.*key/i,
          /unauthorized/i,
          /authentication/i
        ],
        quota_exceeded: [
          /quota.*exceeded/i,
          /insufficient.*quota/i,
          /billing/i
        ],
        transient: [
          /timeout/i,
          /connection.*error/i,
          /service.*unavailable/i,
          /\b503\b/,
          /\b502\b/
        ]
      }.tap { |patterns| patterns.each_value(&:freeze) }.freeze

      attr_reader :config, :logger
      attr_accessor :executor

      class << self
        def smoke_test_contract
          nil
        end
      end

      # Initialize the provider
      #
      # @param config [ProviderConfig, nil] provider configuration
      # @param executor [CommandExecutor, nil] command executor
      # @param logger [Logger, nil] logger instance
      def initialize(config: nil, executor: nil, logger: nil)
        @config = config || ProviderConfig.new(self.class.provider_name)
        @executor = executor || AgentHarness.configuration.command_executor
        @logger = logger || AgentHarness.logger
      end

      # Configure the provider instance
      #
      # @param options [Hash] configuration options
      # @return [self]
      def configure(options = {})
        @config.merge!(options)
        self
      end

      # Main send_message implementation
      #
      # @param prompt [String] the prompt to send
      # @param options [Hash] additional options
      # @option options [ProviderRuntime, Hash, nil] :provider_runtime per-request
      #   runtime overrides (model, base_url, api_provider, env, flags, metadata).
      #   A plain Hash is automatically coerced into a ProviderRuntime.
      #   Providers can derive request-scoped execution preparation from this
      #   runtime to materialize config files or other bootstrap state.
      # @return [Response] the response
      def send_message(prompt:, **options)
        log_debug("send_message_start", prompt_length: prompt.length, options: options.keys)

        # Text mode: fall back to CLI with tools disabled when the provider
        # does not have an HTTP text transport.  Providers that support text
        # mode (e.g. Anthropic) override send_message to intercept this
        # before reaching Base.
        if options[:mode] == :text && !supports_text_mode?
          log_debug("text_mode_cli_fallback", provider: self.class.provider_name)
          options = options.except(:mode).merge(tools: :none)
        end

        # Warn when tools option is passed to a provider that doesn't support it
        if options[:tools] && !supports_tool_control?
          log_debug("tools_option_unsupported",
            provider: self.class.provider_name,
            tools: options[:tools])
          @logger&.warn(
            "[AgentHarness::#{self.class.provider_name}] tools option is not supported " \
            "by this provider and will be ignored"
          )
        end

        # Coerce provider_runtime from Hash if needed
        options = normalize_provider_runtime(options)

        # Normalize and validate MCP servers
        options = normalize_mcp_servers(options)
        validate_mcp_servers!(options[:mcp_servers]) if options[:mcp_servers]&.any?

        # Build command
        command = build_command(prompt, options)
        preparation = build_execution_preparation(options)

        # Calculate timeout
        timeout = options[:timeout] || @config.timeout || default_timeout

        # Execute command
        start_time = Time.now
        result = execute_with_timeout(
          command,
          timeout: timeout,
          env: build_env(options),
          preparation: preparation,
          **command_execution_options(options)
        )
        duration = Time.now - start_time

        # Parse response
        response = parse_response(result, duration: duration)
        runtime = options[:provider_runtime]
        # Runtime model is a per-request override and always takes precedence
        # over both the config-level model and whatever parse_response returned.
        # This is intentional: callers use runtime overrides to route a single
        # provider instance through different backends on each request.
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

        # Track tokens
        track_tokens(response) if response.tokens

        log_debug("send_message_complete", duration: duration, tokens: response.tokens)

        response
      rescue McpConfigurationError, McpUnsupportedError, McpTransportUnsupportedError
        raise
      rescue => e
        handle_error(e, prompt: prompt, options: options)
      end

      # Send a multi-turn chat message via an HTTP transport.
      #
      # Providers that support OpenAI-compatible chat should override this
      # to wire up their transport. The default raises NotImplementedError.
      #
      # Structured streaming events are delivered through three channels:
      # - +on_chat_chunk+ proc (keyword argument)
      # - +observer+ object responding to +on_chat_chunk+
      # - block (yield)
      #
      # When multiple receivers are provided, all receive every event.
      #
      # @param messages [Array<Hash>] conversation messages
      # @param stream [Boolean] whether to stream the response
      # @param on_chat_chunk [Proc, nil] callback for structured streaming events
      # @param observer [#on_chat_chunk, nil] observer receiving streaming events
      # @param options [Hash] additional options forwarded to the transport
      # @return [Response] the response
      def send_chat_message(messages:, stream: false, on_chat_chunk: nil, observer: nil, **options, &on_chunk)
        raise NotImplementedError,
          "#{self.class.provider_name} does not support chat messages. " \
          "Override send_chat_message or configure an OpenAI-compatible transport."
      end

      # Provider name for display
      #
      # @return [String] display name
      def name
        self.class.provider_name.to_s
      end

      # Human-friendly display name
      #
      # @return [String] display name
      def display_name
        name.capitalize
      end

      # Whether the provider is running inside a sandboxed (Docker) environment
      #
      # Providers can use this to adjust execution flags, e.g. skipping
      # nested sandboxing when already inside a container.
      #
      # @return [Boolean] true when the executor is a DockerCommandExecutor
      def sandboxed_environment?
        @executor.is_a?(DockerCommandExecutor)
      end

      # Environment variable names that the provider's CLI reads for API key authentication.
      #
      # @return [Array<String>] env var names (empty by default)
      def api_key_env_var_names = []

      # Environment variable names to unset when the caller supplies its own API key,
      # preventing the CLI from reading stale or conflicting proxy/header variables.
      #
      # @return [Array<String>] env var names (empty by default)
      def api_key_unset_vars = []

      # Environment variable names to unset when the caller uses subscription-based auth,
      # ensuring the CLI does not pick up API-key or proxy variables that would conflict.
      #
      # @return [Array<String>] env var names (empty by default)
      def subscription_unset_vars = []

      # Provider-specific environment variable overrides that the caller should set
      # when invoking the CLI (e.g. feature flags or sandbox controls).
      #
      # @return [Hash{String => String}] env var name => value (empty by default)
      def cli_env_overrides = {}

      # Additional CLI flags for health-check/test invocations
      #
      # Providers override this to supply flags that should be appended
      # when the CLI is invoked in a test or smoke-test context.
      #
      # @return [Array<String>] extra CLI flags (empty by default)
      def test_command_overrides
        []
      end

      # Parse provider-specific error information from test output
      #
      # Providers override this to extract structured error details from
      # CLI output or sidecar files produced during a test invocation.
      #
      # @param output [String] the CLI stdout/stderr output
      # @param files [Hash] mapping of logical names to file paths
      # @return [Hash, nil] structured error hash or nil if no error detected
      def parse_test_error(output:, files: {})
        nil
      end

      # Parse rate-limit reset time from provider error output.
      #
      # Providers that emit rate-limit reset times should override this
      # method (or include RateLimitResetParsing for the common format).
      #
      # @param text [String, nil] error output text
      # @return [Time, nil] UTC reset time, or nil if not parseable
      def parse_rate_limit_reset(text)
        nil
      end

      protected

      # Build CLI command - override in subclasses
      #
      # @param prompt [String] the prompt
      # @param options [Hash] options
      # @return [Array<String>] command array
      def build_command(prompt, options)
        raise NotImplementedError, "#{self.class} must implement #build_command"
      end

      # Build environment variables - override in subclasses
      #
      # Provider subclasses should call +super+ and merge their own env vars
      # so that ProviderRuntime env overrides are always included.
      #
      # @param options [Hash] options
      # @return [Hash] environment variables
      def build_env(options)
        runtime = options[:provider_runtime]
        return {} unless runtime

        # Return overrides only. Ruby subprocess spawning treats nil values as
        # explicit unsets in the child process, while omitted keys are inherited.
        env = runtime.env.dup
        runtime.unset_env.each { |key| env[key] = nil }
        env
      end

      # Build structured runtime preparation for the executor.
      #
      # Provider subclasses can override to request request-scoped file writes
      # or other bootstrap work without shell-wrapping the main command.
      #
      # @param options [Hash] options
      # @return [ExecutionPreparation, nil] preparation contract or nil
      def build_execution_preparation(options)
        nil
      end

      # Parse CLI output into Response - override in subclasses
      #
      # Combines stdout and stderr for error classification so that
      # provider-specific error messages are captured regardless of
      # which stream they appear on.
      #
      # @param result [CommandExecutor::Result] execution result
      # @param duration [Float] execution duration
      # @return [Response] parsed response
      def parse_response(result, duration:)
        error = nil
        # Use execution_semantics[:legitimate_exit_codes] so providers can
        # declare additional non-error exit codes beyond zero.
        legitimate = execution_semantics[:legitimate_exit_codes] || [0]
        unless legitimate.include?(result.exit_code)
          # Concatenate non-empty streams so error patterns can match
          # regardless of which stream the provider writes to.
          combined = [result.stderr, result.stdout]
            .map { |s| s.to_s.strip }
            .reject(&:empty?)
            .join("\n")

          error = combined unless combined.empty?
        end

        Response.new(
          output: result.stdout,
          exit_code: result.exit_code,
          duration: duration,
          provider: self.class.provider_name,
          model: @config.model,
          error: error,
          metadata: {
            legitimate_exit_codes: legitimate
          }
        )
      end

      # Default timeout
      #
      # @return [Integer] timeout in seconds
      def default_timeout
        300
      end

      private

      def normalize_provider_runtime(options)
        raw = options[:provider_runtime]
        return options if raw.nil? || raw.is_a?(ProviderRuntime)

        options.merge(provider_runtime: ProviderRuntime.wrap(raw))
      end

      def normalize_mcp_servers(options)
        servers = options[:mcp_servers]
        return options if servers.nil?

        unless servers.is_a?(Array)
          raise McpConfigurationError,
            "mcp_servers must be an Array of Hash or McpServer, got #{servers.class}"
        end

        return options if servers.empty?

        normalized = servers.map do |server|
          if server.is_a?(McpServer)
            server
          elsif server.is_a?(Hash)
            McpServer.from_hash(server)
          else
            raise McpConfigurationError, "MCP server must be a Hash or McpServer, got #{server.class}"
          end
        end

        # Ensure MCP server names are unique to avoid silent overwrites downstream
        names = normalized.map(&:name)
        duplicate_names = names.group_by { |n| n }.select { |_, v| v.size > 1 }.keys
        unless duplicate_names.empty?
          raise McpConfigurationError,
            "Duplicate MCP server names detected: #{duplicate_names.join(", ")}"
        end

        options.merge(mcp_servers: normalized)
      end

      def command_execution_options(options)
        execution_options = {
          idle_timeout: options[:idle_timeout],
          on_stdout_chunk: options[:on_stdout_chunk],
          on_stderr_chunk: options[:on_stderr_chunk],
          on_heartbeat: options[:on_heartbeat],
          observer: options[:execution_observer] || options[:observer]
        }.reject { |_, value| value.nil? }

        execution_options[:heartbeat_interval] = options[:heartbeat_interval] if options.key?(:heartbeat_interval)
        execution_options
      end

      def execute_with_timeout(command, timeout:, env:, preparation: nil, stdin_data: nil, **execution_options)
        kwargs = {timeout: timeout, env: env}
        kwargs[:stdin_data] = stdin_data unless stdin_data.nil?
        kwargs[:preparation] = preparation unless preparation.nil?
        kwargs.merge!(execution_options)

        @executor.execute(command, **kwargs)
      rescue ArgumentError => e
        unknown_keyword_message = e.message
        raise unless unknown_keyword_message.start_with?("unknown keyword", "unknown keywords")
        raise unless unknown_keyword_message.include?(":preparation")

        raise ProviderError.new(
          "Injected executor #{@executor.class}#execute must accept the preparation: keyword argument",
          original_error: e
        )
      end

      def track_tokens(response)
        return unless response.tokens

        AgentHarness.token_tracker.record(
          provider: self.class.provider_name,
          model: response.model || @config.model,
          input_tokens: response.tokens[:input] || 0,
          output_tokens: response.tokens[:output] || 0,
          total_tokens: response.tokens[:total]
        )
      end

      def handle_error(error, prompt:, options:)
        # Classify error
        classification = ErrorTaxonomy.classify(error, error_patterns)

        log_error("send_message_error",
          error: error.class.name,
          message: error.message,
          classification: classification)

        # Wrap in appropriate error class
        raise map_to_error_class(classification, error)
      end

      def map_to_error_class(classification, original_error)
        case classification
        when :rate_limited
          RateLimitError.new(original_error.message, original_error: original_error)
        when :auth_expired
          AuthenticationError.new(
            original_error.message,
            provider: self.class.provider_name,
            original_error: original_error
          )
        when :timeout
          return original_error if original_error.is_a?(TimeoutError)

          TimeoutError.new(original_error.message, original_error: original_error)
        when :idle_timeout
          return original_error if original_error.is_a?(IdleTimeoutError)

          IdleTimeoutError.new(original_error.message, original_error: original_error)
        else
          ProviderError.new(original_error.message, original_error: original_error)
        end
      end

      def log_debug(action, **context)
        @logger&.debug("[AgentHarness::#{self.class.provider_name}] #{action}: #{context.inspect}")
      end

      def log_error(action, **context)
        @logger&.error("[AgentHarness::#{self.class.provider_name}] #{action}: #{context.inspect}")
      end
    end
  end
end
