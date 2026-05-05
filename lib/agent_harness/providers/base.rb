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
      include Extensions::DeepDupable

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
      # @param configuration [Configuration, nil] parent configuration for extension/sub-agent resolution
      def initialize(config: nil, executor: nil, logger: nil, configuration: nil)
        @config = config || ProviderConfig.new(self.class.provider_name)
        @configuration = configuration || AgentHarness.configuration
        @executor = executor || @configuration.command_executor
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
        skill_context = resolve_skills(options)
        prompt = apply_skills_to_prompt(prompt, skill_context)
        options = skill_context[:options]

        # Capture execution options (callbacks, observer) before extensions
        # processing deep-dups the options hash, which would replace identity-
        # sensitive references (observers, procs) with clones.
        exec_opts = command_execution_options(options)

        extension_context = apply_extensions_to_prompt(prompt, options)
        prompt = extension_context.prompt
        options = extension_context.options
        options = normalize_sub_agent(options)
        prompt = apply_sub_agent_to_prompt(prompt, options[:translated_sub_agent])

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
          **exec_opts
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

        response = apply_extensions_after_response(extension_context, response)

        # Track tokens
        track_tokens(response) if response.tokens

        log_debug("send_message_complete", duration: duration, tokens: response.tokens)

        response
      rescue ExtensionCompatibilityError, McpConfigurationError, McpUnsupportedError, McpTransportUnsupportedError
        raise
      rescue => e
        handle_error(e, prompt: prompt, options: options)
      end

      # Return the provider CLI execution plan without executing it.
      #
      # @param prompt [String] the prompt to send
      # @param options [Hash] additional options
      # @return [Hash] with :command, :env, and :preparation keys
      def plan_execution(prompt:, **options)
        log_debug("plan_execution_start", prompt_length: prompt.length, options: options.keys)

        if options[:mode] == :text && !supports_text_mode?
          log_debug("text_mode_cli_fallback", provider: self.class.provider_name)
          options = options.except(:mode).merge(tools: :none)
        end

        if options[:tools] && !supports_tool_control?
          log_debug("tools_option_unsupported",
            provider: self.class.provider_name,
            tools: options[:tools])
          @logger&.warn(
            "[AgentHarness::#{self.class.provider_name}] tools option is not supported " \
            "by this provider and will be ignored"
          )
        end

        options = normalize_provider_runtime(options)
        skill_context = resolve_skills(options)
        prompt = apply_skills_to_prompt(prompt, skill_context)
        options = skill_context[:options]

        extension_context = apply_extensions_to_prompt(prompt, options)
        prompt = extension_context.prompt
        options = extension_context.options
        options = normalize_sub_agent(options)
        prompt = apply_sub_agent_to_prompt(prompt, options[:translated_sub_agent])

        options = normalize_mcp_servers(options)
        validate_mcp_servers!(options[:mcp_servers]) if options[:mcp_servers]&.any?

        {
          command: build_command(prompt, options),
          env: build_env(options),
          preparation: build_execution_preparation(options)
        }
      rescue ExtensionCompatibilityError, McpConfigurationError, McpUnsupportedError, McpTransportUnsupportedError
        raise
      rescue => e
        handle_error(e, prompt: prompt, options: options)
      ensure
        # build_command may call build_mcp_flags which creates tempfiles (and
        # in Docker even invokes the executor) via write_mcp_config_file.
        # Clean up so that planning has no lasting side effects.
        cleanup_mcp_tempfiles! if respond_to?(:cleanup_mcp_tempfiles!, true)
      end

      # Send a multi-turn chat message via the provider's chat transport.
      #
      # Providers that support chat mode can accept either +conversation:+
      # or +messages:+ as the conversation history payload.
      #
      # Structured streaming events are delivered through three channels:
      # - +on_chat_chunk+ proc (keyword argument)
      # - +observer+ object responding to +on_chat_chunk+
      # - block (yield)
      #
      # When multiple receivers are provided, all receive every event.
      #
      # @param conversation [Array<Hash>, nil] message history
      # @param messages [Array<Hash>, nil] alias for +conversation+
      # @param tools [Array<Hash>, nil] tool/function definitions
      # @param stream [Boolean] whether to stream the response
      # @param on_chat_chunk [Proc, nil] callback for structured streaming events
      # @param observer [#on_chat_chunk, nil] observer receiving streaming events
      # @param options [Hash] additional options
      # @yield [Hash] streaming chunks when stream: true
      # @return [Response] the response
      # @raise [ProviderError] if the provider does not support chat mode
      def send_chat_message(conversation: nil, messages: nil, tools: nil, stream: false,
        on_chat_chunk: nil, observer: nil, **options, &on_chunk)
        unless supports_chat?
          raise ProviderError, "#{name} does not support chat mode"
        end

        options = normalize_provider_runtime(options)
        skill_context = resolve_skills(options)
        options = skill_context[:options]
        options = normalize_sub_agent(options)
        runtime = options[:provider_runtime]
        conversation ||= messages
        raise ArgumentError, "conversation or messages is required" unless conversation
        tools = runtime.chat_tools if tools.nil? && runtime&.chat_tools

        transport = resolve_chat_transport(options)
        messages = format_messages_for_transport(conversation, transport)
        messages = apply_skills_to_messages(messages, skill_context)
        tools = merge_skill_chat_tools(tools, skill_context[:tools])
        extension_context = apply_extensions_to_chat(messages, tools, options)
        messages = extension_context.messages
        tools = extension_context.tools
        options = extension_context.options
        messages = apply_sub_agent_to_messages(messages, options[:translated_sub_agent])
        validate_chat_mcp_servers!(options[:mcp_servers])
        transport_opts = chat_transport_options(runtime, options)
        transport_opts[:on_chat_chunk] = on_chat_chunk if on_chat_chunk
        transport_opts[:observer] = observer if observer

        response = transport.chat(
          messages: messages,
          tools: tools,
          stream: stream,
          **transport_opts,
          &on_chunk
        )

        response = apply_extensions_after_response(extension_context, response)

        track_tokens(response) if response.tokens
        log_debug("send_chat_message_complete", duration: response.duration, tokens: response.tokens)

        response
      rescue ExtensionCompatibilityError, ProviderError, AuthenticationError, RateLimitError, TimeoutError
        raise
      rescue => e
        last_msg = conversation&.last || messages&.last
        handle_error(e, prompt: (last_msg&.dig(:content) || last_msg&.dig("content")).to_s, options: options)
      end

      # Parse raw container output into a Response.
      #
      # This is the public interface for parsing CLI output captured from
      # external execution (e.g. Docker containers) without going through
      # send_message. It accepts the same data a CommandExecutor::Result
      # holds and returns an AgentHarness::Response.
      #
      # @param stdout [String] captured standard output
      # @param stderr [String] captured standard error
      # @param exit_code [Integer] process exit code
      # @param duration [Float] execution duration in seconds
      # @param options [Hash] additional provider-specific options
      # @return [Response] parsed response
      def parse_container_output(stdout:, stderr: "", exit_code: 0, duration: 0.0, **options)
        result = CommandExecutor::Result.new(
          stdout: stdout,
          stderr: stderr,
          exit_code: exit_code,
          duration: duration
        )
        parse_response(result, duration: duration)
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

      # Run a lightweight provider-owned preflight check before committing to a
      # full prompt execution.
      #
      # Providers can override this to validate request-scoped connectivity,
      # credentials, CLI version, or other fast-fail prerequisites.
      #
      # @param env [Hash] request-scoped environment overrides
      # @param timeout [Numeric] time budget in seconds
      # @return [Hash] with :healthy and optional :reason keys
      def preflight_check(env:, timeout: 10)
        {healthy: true}
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

      def resolve_skills(options)
        skill_refs = options[:skills]
        skills = Skills.resolve_all(skill_refs)
        return {skills: [], options: options, instructions: nil, tools: []} if skills.empty?

        runtime = skills.map { |skill| ProviderRuntime.wrap(skill.provider_override_for(self.class.provider_name)) }
          .compact
          .reduce(nil) { |merged, skill_runtime| merged ? merged.merge(skill_runtime) : skill_runtime }

        runtime = runtime&.merge(options[:provider_runtime]) || options[:provider_runtime]
        merged_options = options.merge(provider_runtime: runtime)
        merged_options = merge_skill_message_tools(merged_options, skills)
        merged_options = merge_skill_mcp_servers(merged_options, skills)

        {
          skills: skills,
          options: merged_options,
          instructions: skills.map(&:instructions).join("\n\n"),
          tools: resolve_skill_chat_tools(skills)
        }
      end

      def normalize_mcp_servers(options)
        if options.key?(:mcp_servers)
          servers = options[:mcp_servers]
        else
          # Configuration stores mcp_servers as a Hash keyed by name; extract values.
          config_servers = @configuration.mcp_servers
          servers = config_servers.is_a?(Hash) ? config_servers.values : config_servers
        end
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

      def normalize_sub_agent(options)
        sub_agent = options[:sub_agent]
        return options unless sub_agent

        resolved = @configuration.resolve_sub_agent(sub_agent)
        translated = SubAgentTranslator.for_provider(
          self.class.provider_name,
          resolved,
          tool_registry: @configuration.tool_registry,
          mcp_servers: @configuration.mcp_servers
        )

        options.merge(sub_agent: resolved, translated_sub_agent: translated)
      end

      def apply_sub_agent_to_prompt(prompt, translated_sub_agent)
        return prompt unless translated_sub_agent

        [translated_sub_agent[:runtime_instructions], "User task:\n#{prompt}"].join("\n\n")
      end

      def apply_skills_to_prompt(prompt, skill_context)
        instructions = skill_context[:instructions]
        return prompt if instructions.nil? || instructions.empty?

        [instructions, prompt].join("\n\n")
      end

      def apply_skills_to_messages(messages, skill_context)
        instructions = skill_context[:instructions]
        return messages if instructions.nil? || instructions.empty?

        [{role: "system", content: instructions}] + messages
      end

      def apply_sub_agent_to_messages(messages, translated_sub_agent)
        return messages unless translated_sub_agent

        [{role: "system", content: translated_sub_agent[:runtime_instructions]}] + messages
      end

      def resolve_extensions(options)
        Array(options[:extensions]).filter_map do |reference|
          @configuration.resolve_extension(reference)
        end
      end

      def apply_extensions_to_prompt(prompt, options)
        extensions = resolve_extensions(options)
        strict = options.fetch(:extensions_strict, true)
        Extensions::Composition.compose(extensions) if extensions.size > 1
        context = Extensions::MessageContext.new(
          provider: self,
          extensions: extensions,
          mode: :message,
          prompt: prompt,
          options: deep_dup(options),
          metadata: {}
        )

        validate_extensions!(extensions, strict: strict)
        reject_tool_extensions_in_message_mode!(extensions)
        reject_mcp_extensions_in_message_mode!(extensions)
        apply_extension_system_prompt!(context)
        extensions.each { |extension| extension.on_message_before(context) }
        context
      end

      def apply_extensions_to_chat(messages, tools, options)
        extensions = resolve_extensions(options)
        strict = options.fetch(:extensions_strict, true)
        Extensions::Composition.compose(extensions) if extensions.size > 1
        context = Extensions::MessageContext.new(
          provider: self,
          extensions: extensions,
          mode: :chat,
          messages: deep_dup(messages),
          tools: merge_extension_tools(tools, extensions),
          options: deep_dup(options),
          metadata: {}
        )

        validate_extensions!(extensions, strict: strict)
        merge_extension_mcp_servers!(context)
        apply_extension_system_messages!(context)
        extensions.each { |extension| extension.on_message_before(context) }
        extensions.each { |extension| extension.on_tools_available(context) } if context.tools&.any?
        context
      end

      def apply_extensions_after_response(context, response)
        return response unless context

        context.response = response
        context.extensions.each { |extension| extension.on_message_after(context) }
        context.response
      end

      def validate_extensions!(extensions, strict: true)
        extensions.each do |extension|
          report = Extensions::Compatibility.check!(provider: self, extension: extension, strict: strict)
          next if report.fully_supported?

          @logger&.warn(
            "[AgentHarness::#{self.class.provider_name}] Extension '#{extension.name}' has " \
            "unsupported features that will be unavailable: #{report.unsupported_features.inspect}"
          )
        end
      end

      def validate_chat_mcp_servers!(mcp_servers)
        return if mcp_servers.nil? || mcp_servers.empty?

        # Chat transports do not support request-scoped MCP servers.
        # Raise early so extensions with MCP requirements are not silently ignored.
        raise McpUnsupportedError.new(
          "Chat mode does not support request-scoped MCP servers. " \
          "Extensions or options requiring MCP servers cannot be used with send_chat_message.",
          provider: self.class.provider_name
        )
      end

      def reject_tool_extensions_in_message_mode!(extensions)
        tool_extensions = extensions.select { |ext| ext.tools.any? }
        return if tool_extensions.empty?

        names = tool_extensions.map(&:name).join(", ")
        raise ExtensionCompatibilityError.new(
          "Extensions with tools are not supported in message mode (CLI execution " \
          "cannot accept dynamic tool definitions): #{names}",
          provider: self.class.provider_name
        )
      end

      def reject_mcp_extensions_in_message_mode!(extensions)
        mcp_extensions = extensions.select { |ext| ext.mcp_servers.any? }
        return if mcp_extensions.empty?

        names = mcp_extensions.map(&:name).join(", ")
        raise ExtensionCompatibilityError.new(
          "Extensions with MCP servers are not supported in message mode: #{names}",
          provider: self.class.provider_name
        )
      end

      def merge_extension_mcp_servers!(context)
        extension_servers = context.extensions.flat_map(&:mcp_servers)
        return if extension_servers.empty?

        merged = Array(context.options[:mcp_servers]) + extension_servers
        context.options = context.options.merge(mcp_servers: merged)
      end

      def merge_extension_tools(tools, extensions)
        extension_tools = extensions.flat_map(&:tools)
        return tools unless extension_tools.any?

        normalized_extension_tools = extension_tools.map { |t| normalize_extension_tool_for_provider(t) }
        merged = Array(tools) + normalized_extension_tools
        names = merged.map { |t| extract_tool_name(t) }.compact
        duplicates = names.group_by { |n| n }.select { |_, v| v.size > 1 }.keys
        unless duplicates.empty?
          raise ConfigurationError,
            "Tool name conflict between user-provided and extension tools: #{duplicates.join(", ")}"
        end
        merged
      end

      def merge_skill_message_tools(options, skills)
        return options if skills.empty?
        return options if options[:tools] == :none

        skill_tools = skills.flat_map { |skill| skill.tools.map { |tool| resolve_skill_message_tool(tool) } }.compact
        return options if skill_tools.empty?

        current_tools = options[:tools]
        merged_tools = Array(current_tools) + skill_tools
        duplicates = merged_tools.group_by(&:itself).select { |_, entries| entries.size > 1 }.keys
        unless duplicates.empty?
          raise ConfigurationError, "Tool name conflict between explicit and skill tools: #{duplicates.join(", ")}"
        end

        options.merge(tools: merged_tools)
      end

      def merge_skill_mcp_servers(options, skills)
        skill_servers = skills.flat_map(&:mcp_servers)
        return options if skill_servers.empty?

        merged = Array(options[:mcp_servers]) + deep_dup(skill_servers)
        options.merge(mcp_servers: merged)
      end

      def resolve_skill_chat_tools(skills)
        skills.flat_map do |skill|
          skill.tools.map { |tool| normalize_skill_chat_tool_for_provider(resolve_skill_tool_mapping(tool)) }
        end
      end

      def merge_skill_chat_tools(tools, skill_tools)
        return tools if skill_tools.empty?

        merged = Array(tools) + skill_tools
        names = merged.map { |tool| extract_tool_name(tool) }.compact
        duplicates = names.group_by { |name| name }.select { |_, entries| entries.size > 1 }.keys
        unless duplicates.empty?
          raise ConfigurationError, "Tool name conflict between explicit and skill tools: #{duplicates.join(", ")}"
        end

        merged
      end

      def resolve_skill_message_tool(tool)
        resolved = resolve_skill_tool_mapping(tool)
        return resolved if resolved.is_a?(String)
        return extract_tool_name(resolved) if resolved.is_a?(Hash)

        raise ConfigurationError, "Unsupported skill tool mapping for message mode: #{resolved.inspect}"
      end

      def normalize_skill_chat_tool_for_provider(tool)
        return normalize_extension_tool_for_provider(tool) if tool.is_a?(Hash)

        {name: tool.to_s}
      end

      def resolve_skill_tool_mapping(tool)
        case tool
        when Symbol, String
          if @configuration.tool_registry.registered?(tool)
            mapping = @configuration.tool_registry.fetch(tool).mapping_for(self.class.provider_name)
            mapping.nil? ? tool.to_s : mapping
          else
            tool.to_s
          end
        when Hash
          deep_dup(tool)
        else
          raise ConfigurationError, "Unsupported tool reference #{tool.inspect} in skill definition"
        end
      end

      def extract_tool_name(tool)
        tool[:name] || tool["name"] ||
          tool.dig(:function, :name) || tool.dig(:function, "name") ||
          tool.dig("function", "name") || tool.dig("function", :name)
      end

      def normalize_extension_tool_for_provider(tool)
        case chat_transport_type
        when :openai_compatible
          # OpenAI-style: {type: "function", function: {name: ..., description: ...}}
          return tool if tool[:type] == "function" || tool["type"] == "function"

          func = {name: tool[:name] || tool["name"]}
          description = tool[:description] || tool["description"]
          func[:description] = description if description
          parameters = tool[:parameters] || tool["parameters"]
          func[:parameters] = parameters if parameters
          {type: "function", function: func}
        else
          # Anthropic-style: {name: ..., description: ..., input_schema: ...}
          # Convert `parameters` key to `input_schema` for Anthropic/TextTransport compatibility.
          normalized = tool.dup
          params = normalized.delete(:parameters) || normalized.delete("parameters")
          if params && !normalized.key?(:input_schema) && !normalized.key?("input_schema")
            normalized[:input_schema] = params
          end
          normalized
        end
      end

      def apply_extension_system_prompt!(context)
        additions = context.extensions.flat_map(&:system_prompt_additions).reject do |addition|
          addition.nil? || addition.empty?
        end
        return if additions.empty?

        context.prompt = [additions.join("\n\n"), context.prompt].join("\n\n")
      end

      def apply_extension_system_messages!(context)
        additions = context.extensions.flat_map(&:system_prompt_additions).reject do |addition|
          addition.nil? || addition.empty?
        end
        return if additions.empty?

        system_messages = additions.map { |addition| {role: "system", content: addition} }
        context.messages = system_messages + context.messages
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

      def resolve_chat_transport(options)
        runtime = options[:provider_runtime]

        # When the runtime specifies chat-specific overrides (base_url, api_key),
        # build a fresh transport instead of reusing the memoized default.
        if runtime && (runtime.chat_base_url || runtime.chat_api_key)
          transport = build_runtime_chat_transport(runtime)
          if transport
            return transport
          end
        end

        transport = chat_transport
        raise ProviderError, "#{name} chat_transport returned nil" unless transport

        transport
      end

      # Build a one-off chat transport from ProviderRuntime overrides.
      #
      # Subclasses that support chat must override this when the runtime
      # carries chat_base_url or chat_api_key so those overrides are
      # actually applied. The base implementation raises to surface the
      # misconfiguration early rather than silently ignoring the overrides.
      def build_runtime_chat_transport(_runtime)
        raise ProviderError,
          "#{name} does not support chat_base_url/chat_api_key overrides on ProviderRuntime"
      end

      def format_messages_for_transport(conversation, transport)
        normalized = conversation.map { |msg| normalize_transport_message(msg) }
        return normalized unless anthropic_transport?(transport)
        return normalized unless anthropic_conversion_required?(normalized)

        anthropic = anthropic_conversation(normalized)
        system_messages = anthropic[:system] ? [{role: "system", content: anthropic[:system]}] : []

        system_messages + anthropic[:messages]
      end

      def normalize_transport_message(message)
        message.each_with_object({}) do |(key, value), memo|
          memo[key.is_a?(String) ? key.to_sym : key] = value
        end.tap do |normalized|
          normalized[:role] = normalized[:role].to_s if normalized.key?(:role)
        end
      end

      def anthropic_transport?(transport)
        chat_transport_type == :anthropic || transport.is_a?(TextTransport)
      end

      def anthropic_conversion_required?(messages)
        messages.any? do |msg|
          msg[:role] == "tool" || msg.key?(:tool_calls)
        end
      end

      def anthropic_conversation(messages)
        conversation = Conversation.new

        messages.each do |msg|
          conversation.add_message(
            msg.fetch(:role).to_sym,
            msg[:content],
            tool_calls: msg[:tool_calls],
            tool_call_id: msg[:tool_call_id]
          )
        end

        conversation.to_anthropic_messages
      end

      def chat_transport_options(runtime, options)
        opts = {}
        max_tok = options[:chat_max_tokens] || options[:max_tokens] || runtime&.chat_max_tokens
        opts[:max_tokens] = max_tok if max_tok
        model = runtime&.chat_model || runtime&.model
        opts[:model] = model if model
        opts[:temperature] = options[:temperature] if options[:temperature]
        opts
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
