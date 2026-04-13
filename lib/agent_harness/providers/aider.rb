# frozen_string_literal: true

require "json"
require "securerandom"
require "shellwords"
require "tmpdir"

module AgentHarness
  module Providers
    # Aider AI coding assistant provider
    #
    # Provides integration with the Aider CLI tool.
    class Aider < Base
      UV_VERSION = "0.8.17"
      SUPPORTED_CLI_VERSION = "0.86.2"
      SUPPORTED_CLI_REQUIREMENT = Gem::Requirement.new(">= #{SUPPORTED_CLI_VERSION}", "< 0.87.0").freeze
      PYTHON_VERSION = "python3.12"
      BINARY_PATH = "/usr/local/bin/aider"
      UV_TOOL_ENV = {
        "UV_TOOL_BIN_DIR" => "/usr/local/bin",
        "UV_TOOL_DIR" => "/opt/uv/tools",
        "UV_PYTHON_INSTALL_DIR" => "/opt/uv/python"
      }.freeze

      class << self
        def provider_name
          :aider
        end

        def binary_name
          "aider"
        end

        def available?
          executor = AgentHarness.configuration.command_executor
          !!executor.which(binary_name)
        end

        def firewall_requirements
          {
            domains: [
              "api.openai.com",
              "api.anthropic.com"
            ],
            ip_ranges: []
          }
        end

        def instruction_file_paths
          [
            {
              path: ".aider.conf.yml",
              description: "Aider configuration file",
              symlink: false
            }
          ]
        end

        def discover_models
          return [] unless available?

          # Aider supports multiple model providers
          [
            {name: "gpt-4o", family: "gpt-4o", tier: "standard", provider: "aider"},
            {name: "claude-3-5-sonnet", family: "claude-3-5-sonnet", tier: "standard", provider: "aider"}
          ]
        end

        def installation_contract(version: SUPPORTED_CLI_VERSION)
          version = version.strip if version.respond_to?(:strip)

          unless version.is_a?(String) && !version.empty?
            raise ArgumentError,
              "Unsupported Aider CLI version #{version.inspect}; " \
              "supported versions must satisfy #{SUPPORTED_CLI_REQUIREMENT}"
          end

          parsed_version = begin
            Gem::Version.new(version)
          rescue ArgumentError
            raise ArgumentError,
              "Unsupported Aider CLI version #{version.inspect}; " \
              "supported versions must satisfy #{SUPPORTED_CLI_REQUIREMENT}"
          end

          unless SUPPORTED_CLI_REQUIREMENT.satisfied_by?(parsed_version)
            raise ArgumentError,
              "Unsupported Aider CLI version #{version.inspect}; " \
              "supported versions must satisfy #{SUPPORTED_CLI_REQUIREMENT}"
          end

          default_package = "aider-chat==#{version}".freeze
          bootstrap_command = [
            "python3", "-m", "pip", "install", "--no-cache-dir", "--break-system-packages", "uv==#{UV_VERSION}"
          ].freeze
          install_command_prefix = [
            "uv", "tool", "install", "--force", "--python", PYTHON_VERSION, "--with", "pip"
          ].freeze
          install_command = (install_command_prefix + [default_package]).freeze
          supported_versions = [version].freeze
          version_requirement = SUPPORTED_CLI_REQUIREMENT.requirements
            .map { |op, ver| "#{op} #{ver}".freeze }
            .freeze

          contract = {
            source: :uv_tool,
            bootstrap_source: :pip,
            bootstrap_package: "uv==#{UV_VERSION}",
            bootstrap_commands: [bootstrap_command].freeze,
            install_environment: UV_TOOL_ENV,
            package: default_package,
            package_name: "aider-chat",
            version: version,
            version_format: "%{package_name}==%{version}",
            version_requirement: version_requirement,
            binary_name: binary_name,
            binary_path: BINARY_PATH,
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
      end

      def name
        "aider"
      end

      def display_name
        "Aider"
      end

      def configuration_schema
        {
          fields: [
            {
              name: :model,
              type: :string,
              label: "Model",
              required: false,
              hint: "Model identifier (supports OpenAI, Anthropic, and other model names)",
              accepts_arbitrary: true
            }
          ],
          auth_modes: [:api_key],
          openai_compatible: false
        }
      end

      def capabilities
        {
          streaming: true,
          file_upload: true,
          vision: false,
          tool_use: true,
          json_mode: false,
          mcp: false,
          dangerous_mode: false
        }
      end

      def error_patterns
        COMMON_ERROR_PATTERNS.merge(
          auth_expired: COMMON_ERROR_PATTERNS[:auth_expired] + [/incorrect.*api.*key/i],
          transient: COMMON_ERROR_PATTERNS[:transient] + [/connection.*reset/i]
        )
      end

      def execution_semantics
        {
          prompt_delivery: :flag,
          output_format: :text,
          sandbox_aware: false,
          uses_subcommand: false,
          non_interactive_flag: "--yes",
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
        ["--restore-chat-history", session_id]
      end

      def supports_token_counting?
        true
      end

      def send_message(prompt:, **options)
        log_debug("send_message_start", prompt_length: prompt.length, options: options.keys)

        options = normalize_provider_runtime(options)
        runtime = options[:provider_runtime]

        options = normalize_mcp_servers(options)
        validate_mcp_servers!(options[:mcp_servers]) if options[:mcp_servers]&.any?

        timeout = options[:timeout] || @config.timeout || default_timeout
        raise TimeoutError, "Command timed out before execution started" if timeout <= 0

        start_time = Time.now
        llm_history_path = prepare_llm_history_file!
        command = build_command(prompt, options.merge(llm_history_path: llm_history_path))
        preparation = build_execution_preparation(options)
        remaining_timeout = timeout - (Time.now - start_time)
        raise TimeoutError, "Command timed out before execution started" if remaining_timeout <= 0

        result = execute_with_timeout(
          command,
          timeout: remaining_timeout,
          env: build_env(options),
          preparation: preparation,
          **command_execution_options(options)
        )
        duration = Time.now - start_time

        response = parse_response(result, duration: duration, llm_history_path: llm_history_path)
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

        log_debug("send_message_complete", duration: duration, tokens: response.tokens)

        response
      rescue McpConfigurationError, McpUnsupportedError, McpTransportUnsupportedError
        raise
      rescue => e
        handle_error(e, prompt: prompt, options: options)
      ensure
        cleanup_llm_history_file!(llm_history_path)
      end

      protected

      def build_command(prompt, options)
        cmd = [self.class.binary_name]
        runtime = options[:provider_runtime]

        cmd << "--yes"

        if options[:llm_history_path]
          cmd += ["--llm-history-file", options[:llm_history_path]]
        end

        model = runtime&.model || @config.model
        if model && !model.empty?
          cmd += ["--model", model]
        end

        if options[:session]
          cmd += session_flags(options[:session])
        end

        if runtime&.flags&.any?
          validate_runtime_flags!(runtime.flags)
          cmd += runtime.flags
        end

        cmd += ["--message", prompt]

        cmd
      end

      def parse_response(result, duration:, llm_history_path: nil)
        response = super(result, duration: duration)
        tokens = parse_token_usage(result, llm_history_path: llm_history_path)

        return response unless tokens

        Response.new(
          output: response.output,
          exit_code: response.exit_code,
          duration: response.duration,
          provider: response.provider,
          model: response.model,
          tokens: tokens,
          metadata: response.metadata,
          error: response.error
        )
      end

      def default_timeout
        600
      end

      private

      TOKEN_COUNT_PATTERN = /\d[\d,]*(?:\.\d+)?[kmb]?/i

      TOKEN_USAGE_PATTERN =
        /^\s*Tokens:\s*(?<input>#{TOKEN_COUNT_PATTERN})\s+sent(?:,\s*#{TOKEN_COUNT_PATTERN}\s+cache\s+\w+)*,\s*(?<output>#{TOKEN_COUNT_PATTERN})\s+received\.?(?:\s+Cost:\s+.+)?\s*$/i
      FOOTER_COST_PATTERN = /^\s*Cost:\s+.+\s*$/i
      RUN_SHELL_COMMAND_PATTERN = /^\s*Run shell command\?.*$/i
      OUTPUT_STATUS_PATTERN =
        /^\s*(?:Applied edit to|Commit\b|Committing\b|You can use \/undo\b|Added .+ to the chat\.|Removed .+ from the chat\.|Use \/help\b|Create new file\?|Allow edits to\b|Edit the files\?|Run shell command\?).*$/i
      OUTPUT_PATH_PATTERN = /\A(?:\.\.?\/|\/|~\/)[\w.\-\/]+\z/
      OUTPUT_DOTFILE_PATTERN = /\A\.[\w.-]+\z/
      OUTPUT_FILENAME_PATTERN = /\A[\w.-]+\.[A-Za-z][\w.-]*\z/
      COMMON_SHELL_COMMAND_PATTERN =
        /\A(?:git|bundle|ruby|python\d*(?:\.\d+)?|uv|npm|yarn|pnpm|node|bash|sh|zsh|make|rake|rspec|rails|go|pytest|bin\/[\w.-]+|sed|rg|grep|find|ls|cat|cp|mv|rm|mkdir|touch|chmod|chown|docker|kubectl)\z/
      EXECUTOR_LLM_HISTORY_TIMEOUT = 10
      HistoryFileHandle = Struct.new(:path)
      def generate_llm_history_path
        return "/tmp/aider_llm_history_#{SecureRandom.hex(8)}.json" if sandboxed_environment?

        File.join(Dir.tmpdir, "aider_llm_history_#{Process.pid}_#{SecureRandom.hex(8)}")
      end

      def parse_token_usage(result, llm_history_path:)
        # Aider 0.86.x writes --llm-history-file as conversation text, not JSONL.
        # Prefer the request-local history file when it includes a token report,
        # but fall back to captured command output because the usage summary is
        # printed there during normal runs.
        parse_token_usage_history_content(safe_read_llm_history(llm_history_path)) ||
          parse_token_usage_text(result.stdout, source: :output) ||
          parse_token_usage_text(result.stderr, source: :output)
      end

      def parse_token_usage_history_content(content)
        return nil if content.nil? || content.strip.empty?

        aggregate_token_counts(parse_history_entries(content)) ||
          parse_token_usage_text(content, source: :history)
      end

      def read_llm_history(path)
        return read_executor_llm_history(path) if sandboxed_environment?
        return nil unless path && File.exist?(path) && !File.zero?(path)

        content = File.read(path)
        return nil if content.strip.empty?

        content
      end

      def safe_read_llm_history(path)
        read_llm_history(path)
      rescue => e
        log_debug("llm_history_parse_error", error: e.message)
        nil
      end

      def parse_token_usage_text(content, source: :output)
        return nil if content.nil? || content.strip.empty?

        match = if source == :history
          extract_history_token_usage_match(content)
        else
          extract_output_token_usage_match(content)
        end
        return nil unless match

        input = parse_token_count(match[:input])
        output = parse_token_count(match[:output])

        {input: input, output: output, total: input + output}
      end

      def parse_history_entries(content)
        parsed = JSON.parse(content)
        case parsed
        when Array
          parsed
        when Hash
          [parsed]
        end
      rescue JSON::ParserError
        parsed_lines = []

        content.each_line do |line|
          next if line.strip.empty?

          parsed_lines << JSON.parse(line)
        rescue JSON::ParserError
          return nil
        end

        parsed_lines.empty? ? nil : parsed_lines
      end

      def aggregate_token_counts(entries)
        return nil unless entries&.any?

        total_input = 0
        total_output = 0
        found = false

        entries.each do |entry|
          usage = find_usage_in_entry(entry)
          next unless usage

          input = token_count_for(usage, "prompt_tokens", "input_tokens", "promptTokens", "inputTokens")
          output = token_count_for(usage, "completion_tokens", "output_tokens", "completionTokens", "outputTokens")
          next if input.nil? && output.nil?

          total_input += input || 0
          total_output += output || 0
          found = true
        end

        return nil unless found
        return nil if total_input.zero? && total_output.zero?

        {input: total_input, output: total_output, total: total_input + total_output}
      end

      def find_usage_in_entry(entry)
        return nil unless entry.is_a?(Hash)

        usage = entry["usage"]
        return usage if usage.is_a?(Hash)

        usage = entry.dig("response", "usage")
        return usage if usage.is_a?(Hash)

        nil
      end

      def extract_history_token_usage_match(content)
        lines = content.lines

        lines.each_index.reverse_each do |index|
          match = TOKEN_USAGE_PATTERN.match(lines[index])
          next unless match
          next unless history_token_usage_footer_line?(lines, index)

          return match
        end

        nil
      end

      def extract_output_token_usage_match(content)
        lines = content.lines

        lines.each_index.reverse_each do |index|
          match = TOKEN_USAGE_PATTERN.match(lines[index])
          next unless match
          next unless output_token_usage_footer_line?(lines, index)

          return match
        end

        nil
      end

      def history_token_usage_footer_line?(lines, index)
        footer_prefix?(lines, index) && footer_suffix?(lines, index)
      end

      def output_token_usage_footer_line?(lines, index)
        footer_prefix?(lines, index) && output_footer_suffix?(lines, index)
      end

      def footer_prefix?(lines, index)
        block_start = index
        while block_start.positive? && TOKEN_USAGE_PATTERN.match?(lines[block_start - 1])
          block_start -= 1
        end

        return false if block_start.zero?

        lines[block_start - 1].strip.empty?
      end

      def footer_suffix?(lines, index)
        lines[(index + 1)..].to_a.all? do |line|
          stripped = line.strip
          stripped.empty? || TOKEN_USAGE_PATTERN.match?(line) || FOOTER_COST_PATTERN.match?(line)
        end
      end

      def output_footer_suffix?(lines, index)
        suffix_lines = lines[(index + 1)..].to_a
        shell_prompt_index = suffix_lines.index { |line| RUN_SHELL_COMMAND_PATTERN.match?(line) }

        suffix_lines.each_with_index.all? do |line, line_index|
          stripped = line.strip
          stripped.empty? ||
            TOKEN_USAGE_PATTERN.match?(line) ||
            FOOTER_COST_PATTERN.match?(line) ||
            OUTPUT_STATUS_PATTERN.match?(line) ||
            output_path_footer_line?(stripped) ||
            output_command_footer_line?(line, line_index, shell_prompt_index)
        end
      end

      def output_path_footer_line?(line)
        OUTPUT_PATH_PATTERN.match?(line) ||
          OUTPUT_DOTFILE_PATTERN.match?(line) ||
          OUTPUT_FILENAME_PATTERN.match?(line) ||
          (line.include?("/") && line.match?(/\A[\w.\-\/]+\z/))
      end

      def output_command_footer_line?(line, line_index, shell_prompt_index)
        return false unless shell_prompt_index && line_index < shell_prompt_index

        stripped = line.strip
        return false if stripped.end_with?(".", "?", "!")
        return false if stripped.empty?

        tokens = shell_command_footer_tokens(stripped)
        return false if tokens.empty?
        command = tokens.first
        return false unless command_invocation_token?(command)
        return single_token_command_footer?(command) if tokens.length == 1
        return false unless command_line_token?(command, tokens[1..])

        tokens[1..].all? { |token| command_argument_token?(token) }
      end

      def shell_command_footer_tokens(line)
        Shellwords.shellsplit(line.sub(/\A[$>#]\s*/, ""))
      rescue ArgumentError
        []
      end

      def command_token?(token)
        token.match?(/\A[a-z0-9_][\w.\/~:-]*\z/) && token.match?(/[a-z]/)
      end

      def command_invocation_token?(token)
        command_token?(token) || executable_path_token?(token)
      end

      def executable_path_token?(token)
        token.match?(%r{\A(?:\.\.?/|/|~/)[\w.+%:@=-][\w./+%:@~=-]*\z})
      end

      def command_line_token?(token, arguments)
        command_invocation_token?(token) &&
          (COMMON_SHELL_COMMAND_PATTERN.match?(token) ||
            executable_path_token?(token) ||
            command_footer_shell_like_arguments?(arguments))
      end

      def single_token_command_footer?(token)
        COMMON_SHELL_COMMAND_PATTERN.match?(token) || executable_path_token?(token)
      end

      def command_footer_shell_like_arguments?(arguments)
        arguments.any? do |argument|
          argument.match?(%r{\A(?:&&|\|\|?|\||[<>]|>>|&>|2>)\z}) ||
            argument.start_with?("-", "./", "../", "/", "~/") ||
            argument.include?("/")
        end
      end

      def command_argument_token?(token)
        !token.empty? && !token.match?(/[[:cntrl:]]/)
      end

      def parse_token_count(value)
        normalized = value.delete(",").downcase
        multiplier = case normalized[-1]
        when "k" then 1_000
        when "m" then 1_000_000
        when "b" then 1_000_000_000
        else 1
        end
        normalized = normalized[0...-1] if multiplier > 1

        (normalized.to_f * multiplier).round
      end

      def normalize_token_count(value)
        case value
        when Integer
          value
        when String
          Integer(value, exception: false)
        end
      end

      def token_count_for(usage, *keys)
        keys.each do |key|
          value = normalize_token_count(usage[key])
          return value unless value.nil?
        end
        nil
      end

      def prepare_llm_history_file!
        if sandboxed_environment?
          @aider_history_path = generate_llm_history_path
        else
          path = reserve_local_llm_history_path
          @aider_history_tempfile = HistoryFileHandle.new(path)
          path
        end
      end

      def cleanup_llm_history_file!(path)
        return unless path

        return cleanup_executor_llm_history_file!(path) if sandboxed_environment?

        File.delete(path) if File.exist?(path)
      rescue => e
        log_debug("llm_history_cleanup_error", error: e.message)
        nil
      ensure
        clear_local_history_handle!(path)
        clear_executor_history_path!(path)
      end

      def validate_runtime_flags!(flags)
        invalid_flags = reserved_runtime_flags(flags)
        return if invalid_flags.empty?

        raise ArgumentError,
          "Aider provider_runtime.flags cannot override provider-managed flags: " \
          "#{invalid_flags.join(", ")}"
      end

      def reserved_runtime_flags(flags)
        flags.each_with_index.filter_map do |flag, index|
          next unless reserved_runtime_flag?(flag)

          if flag == "--llm-history-file" && flags[index + 1]
            "#{flag} #{flags[index + 1]}"
          else
            flag
          end
        end.uniq
      end

      def reserved_runtime_flag?(flag)
        flag == "--llm-history-file" || flag.start_with?("--llm-history-file=")
      end

      def read_executor_llm_history(path)
        return nil unless path

        result = @executor.execute(
          ["sh", "-lc", "if [ -s #{Shellwords.escape(path)} ]; then cat #{Shellwords.escape(path)}; fi"],
          timeout: EXECUTOR_LLM_HISTORY_TIMEOUT
        )
        return nil unless result.success?

        content = result.stdout
        return nil if content.to_s.strip.empty?

        content
      end

      def cleanup_executor_llm_history_file!(path)
        @executor.execute(
          ["sh", "-lc", "rm -f -- #{Shellwords.escape(path)}"],
          timeout: EXECUTOR_LLM_HISTORY_TIMEOUT
        )
      rescue => e
        log_debug("llm_history_cleanup_error", error: e.message)
        nil
      end

      def reserve_local_llm_history_path
        loop do
          path = generate_llm_history_path

          begin
            File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600, &:close)
            return path
          rescue Errno::EEXIST
            next
          end
        end
      end

      def clear_local_history_handle!(path)
        return unless defined?(@aider_history_tempfile)
        return unless @aider_history_tempfile&.path == path

        @aider_history_tempfile = nil
      end

      def clear_executor_history_path!(path)
        return unless defined?(@aider_history_path)
        return unless @aider_history_path == path

        @aider_history_path = nil
      end
    end
  end
end
