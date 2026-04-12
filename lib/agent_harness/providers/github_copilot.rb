# frozen_string_literal: true

require "json"

module AgentHarness
  module Providers
    # GitHub Copilot CLI provider
    #
    # Provides integration with the GitHub Copilot CLI tool.
    class GithubCopilot < Base
      MIN_JSON_OUTPUT_VERSION = Gem::Version.new("0.0.422").freeze

      # Model name pattern for GitHub Copilot (uses OpenAI models)
      MODEL_PATTERN = /^gpt-[\d.o-]+(?:-turbo)?(?:-mini)?$/i

      # Copilot-specific smoke test contract.  The `what-the-shell` subcommand
      # translates natural language into shell commands, so the generic
      # "Reply with exactly OK." prompt would produce something like
      # `echo "OK"` rather than the literal text "OK".  We use a prompt that
      # is meaningful for the shell-translation path and only require
      # non-empty output (no exact match).
      SMOKE_TEST_CONTRACT = {
        prompt: "list files in the current directory",
        expected_output: nil,
        timeout: 30,
        require_output: true,
        success_message: "Smoke test passed"
      }.freeze

      class << self
        def provider_name
          :github_copilot
        end

        def binary_name
          "github-copilot-cli"
        end

        def available?
          executor = AgentHarness.configuration.command_executor
          !!executor.which(binary_name)
        end

        def provider_metadata_overrides
          {
            auth: {
              service: :github,
              api_family: :github_copilot
            },
            identity: {
              bot_usernames: ["github-copilot[bot]"]
            }
          }
        end

        def firewall_requirements
          {
            domains: [
              "copilot-proxy.githubusercontent.com",
              "api.githubcopilot.com",
              "copilot-telemetry.githubusercontent.com",
              "default.exp-tas.com",
              "copilot-completions.githubusercontent.com"
            ],
            ip_ranges: []
          }
        end

        def instruction_file_paths
          [
            {
              path: ".github/copilot-instructions.md",
              description: "GitHub Copilot agent instructions",
              symlink: true
            }
          ]
        end

        def discover_models
          return [] unless available?

          [
            {name: "gpt-4o", family: "gpt-4o", tier: "standard", provider: "github_copilot"},
            {name: "gpt-4o-mini", family: "gpt-4o-mini", tier: "mini", provider: "github_copilot"},
            {name: "gpt-4-turbo", family: "gpt-4-turbo", tier: "advanced", provider: "github_copilot"}
          ]
        end

        def smoke_test_contract
          SMOKE_TEST_CONTRACT
        end

        def model_family(provider_model_name)
          provider_model_name
        end

        def provider_model_name(family_name)
          family_name
        end

        def supports_model_family?(family_name)
          MODEL_PATTERN.match?(family_name)
        end
      end

      def name
        "github_copilot"
      end

      def display_name
        "GitHub Copilot CLI"
      end

      def configuration_schema
        {
          fields: [],
          auth_modes: [:oauth],
          openai_compatible: false
        }
      end

      def capabilities
        {
          streaming: false,
          file_upload: false,
          vision: false,
          tool_use: true,
          json_mode: false,
          mcp: false,
          dangerous_mode: true
        }
      end

      def dangerous_mode_flags
        ["--allow-all-tools"]
      end

      def supports_sessions?
        true
      end

      def session_flags(session_id)
        return [] unless session_id && !session_id.empty?
        ["--resume", session_id]
      end

      def auth_type
        :oauth
      end

      def execution_semantics
        {
          prompt_delivery: :arg,
          output_format: copilot_cli_supports_json_output? ? :json : :text,
          sandbox_aware: false,
          uses_subcommand: true,
          non_interactive_flag: nil,
          legitimate_exit_codes: [0],
          stderr_is_diagnostic: true,
          parses_rate_limit_reset: false
        }
      end

      def error_patterns
        {
          auth_expired: [
            /not.?authorized/i,
            /access.?denied/i,
            /permission.?denied/i,
            /not.?enabled/i,
            /subscription.?required/i
          ],
          rate_limited: [
            /usage.?limit/i,
            /rate.?limit/i
          ],
          transient: [
            /connection.?error/i,
            /timeout/i,
            /try.?again/i
          ],
          permanent: [
            /invalid.?command/i,
            /unknown.?flag/i
          ]
        }
      end

      protected

      def build_command(prompt, options)
        cmd = [self.class.binary_name, "what-the-shell", prompt]
        cmd += ["--output-format", "json"] if copilot_cli_supports_json_output?

        # Opt in to unrestricted tool access explicitly to preserve a safe default.
        if supports_dangerous_mode? && options[:dangerous_mode]
          cmd += dangerous_mode_flags
        end

        # Add session support if provided
        if options[:session] && !options[:session].empty?
          cmd += session_flags(options[:session])
        end

        cmd
      end

      def default_timeout
        300
      end

      def parse_response(result, duration:)
        return super unless copilot_cli_supports_json_output?

        output = result.stdout.to_s
        error = nil

        legitimate = execution_semantics[:legitimate_exit_codes] || [0]
        unless legitimate.include?(result.exit_code)
          combined = [result.stderr.to_s, output].map(&:strip).reject(&:empty?).join("\n")
          error = combined unless combined.empty?
        end

        structured_json_seen = false
        shutdown_tokens = empty_token_totals
        usage_tokens = empty_token_totals
        fallback_tokens = empty_token_totals
        output_segments = []
        output.lines.each do |line|
          stripped_line = line.strip
          if stripped_line.empty?
            output_segments << {kind: :raw, content: line, terminated: line.end_with?("\n")}
            next
          end
          begin
            obj = JSON.parse(stripped_line)
          rescue JSON::ParserError
            output_segments << {kind: :raw, content: line, terminated: line.end_with?("\n")}
            next
          end

          structured_json_seen ||= obj.is_a?(Hash)

          text, text_kind = extract_event_text(obj)
          if text
            if text_kind == :assistant_delta
              append_delta_segment!(output_segments, text, terminated: line.end_with?("\n"))
            else
              drop_provisional_segments!(output_segments)
              output_segments << {kind: :assistant, content: text, terminated: line.end_with?("\n")}
            end
          elsif preserve_raw_json_line?(obj) || !obj.is_a?(Hash)
            output_segments << {kind: :raw, content: line, terminated: line.end_with?("\n")}
          end

          token_usage = extract_token_usage(obj)
          next unless token_usage

          if token_usage[:source] == :shutdown
            accumulate_token_totals!(shutdown_tokens, token_usage)
          elsif token_usage[:source] == :usage
            accumulate_token_totals!(usage_tokens, token_usage)
          else
            accumulate_token_totals!(fallback_tokens, token_usage)
          end
        end
        tokens = build_tokens(shutdown_tokens: shutdown_tokens, usage_tokens: usage_tokens, fallback_tokens: fallback_tokens)
        final_output = structured_json_seen ? render_output_segments(output_segments) : output

        Response.new(
          output: final_output,
          exit_code: result.exit_code,
          duration: duration,
          provider: self.class.provider_name,
          model: @config.model,
          tokens: tokens,
          error: error,
          metadata: {
            legitimate_exit_codes: legitimate
          }
        )
      end

      ASSISTANT_OUTPUT_EVENT_TYPES = %w[assistant assistant.message assistant.message_delta].freeze
      ASSISTANT_TOKEN_FALLBACK_EVENT_TYPES = %w[assistant assistant.message].freeze
      SESSION_SHUTDOWN_EVENT_TYPES = ["session.shutdown"].freeze
      USAGE_EVENT_TYPES = %w[usage assistant.usage].freeze
      COPILOT_EVENT_TYPE_PREFIXES = %w[assistant. user. system. session.].freeze

      def extract_event_text(obj)
        return [nil, nil] unless obj.is_a?(Hash)

        if obj.key?("type")
          return [nil, nil] unless obj["data"].is_a?(Hash)
          return [nil, nil] unless ASSISTANT_OUTPUT_EVENT_TYPES.include?(obj["type"])

          data = obj["data"]
          if obj["type"] == "assistant.message_delta"
            delta_content = string_content(data["deltaContent"])
            return [delta_content, :assistant_delta] if delta_content
          end

          return [string_content(data["content"]), :assistant] if data.key?("content")

          return [nil, nil]
        end

        return [nil, nil] if obj.key?("role") && !assistant_role?(obj["role"])

        output = string_content(obj["output"])
        return [output, :assistant] if output

        content = string_content(obj["content"])
        return [content, :assistant] if content

        if obj["message"].is_a?(Hash)
          return [nil, nil] if obj["message"].key?("role") && !assistant_role?(obj["message"]["role"])

          return [string_content(obj["message"]["content"]), :assistant] if obj["message"].key?("content")
        end

        [nil, nil]
      end

      def string_content(value)
        return value if value.is_a?(String)

        nil
      end

      def preserve_raw_json_line?(obj)
        return false unless obj.is_a?(Hash)
        return false if obj.key?("type") && copilot_event_type?(obj["type"])
        return false if obj.key?("role") && !assistant_role?(obj["role"])
        return false if obj["message"].is_a?(Hash) && obj["message"].key?("role") &&
          !assistant_role?(obj["message"]["role"])
        return false if extract_token_usage(obj)
        return false if string_content(obj["output"])
        return false if string_content(obj["content"])
        return false if obj["message"].is_a?(Hash) && string_content(obj["message"]["content"])

        true
      end

      def assistant_role?(role)
        role == "assistant"
      end

      def copilot_event_type?(event_type)
        return true if ASSISTANT_OUTPUT_EVENT_TYPES.include?(event_type)
        return true if ASSISTANT_TOKEN_FALLBACK_EVENT_TYPES.include?(event_type)
        return true if SESSION_SHUTDOWN_EVENT_TYPES.include?(event_type)
        return true if USAGE_EVENT_TYPES.include?(event_type)
        return false unless event_type.is_a?(String)

        COPILOT_EVENT_TYPE_PREFIXES.any? { |prefix| event_type.start_with?(prefix) }
      end

      def extract_token_usage(obj)
        return nil unless obj.is_a?(Hash)

        if obj.key?("type")
          return nil unless obj["data"].is_a?(Hash)

          data = obj["data"]

          if SESSION_SHUTDOWN_EVENT_TYPES.include?(obj["type"])
            return extract_shutdown_token_usage(data)
          end

          if USAGE_EVENT_TYPES.include?(obj["type"])
            return extract_payload_token_usage(
              data,
              source: :usage,
              input_keys: ["inputTokens", "input_tokens"],
              output_keys: ["outputTokens", "output_tokens"]
            )
          end

          if ASSISTANT_TOKEN_FALLBACK_EVENT_TYPES.include?(obj["type"])
            return extract_payload_token_usage(
              data,
              source: :assistant,
              input_keys: ["inputTokens", "input_tokens"],
              output_keys: ["outputTokens", "output_tokens"]
            )
          end

          return nil
        end

        extract_top_level_token_usage(obj)
      end

      def extract_shutdown_token_usage(data)
        model_metrics = data["modelMetrics"]
        return nil unless model_metrics.is_a?(Hash)

        totals = empty_token_totals

        model_metrics.each_value do |metric|
          next unless metric.is_a?(Hash)

          usage = metric["usage"]
          next unless usage.is_a?(Hash)

          metric_usage = extract_payload_token_usage(
            usage,
            source: :shutdown,
            input_keys: ["inputTokens", "input_tokens", "input"],
            output_keys: ["outputTokens", "output_tokens", "output"]
          )
          next unless metric_usage

          accumulate_token_totals!(totals, metric_usage)
        end

        return nil unless totals[:input_present] || totals[:output_present]

        {
          source: :shutdown,
          input: totals[:input],
          output: totals[:output],
          input_present: totals[:input_present],
          output_present: totals[:output_present]
        }
      end

      def extract_payload_token_usage(payload, source:, input_keys:, output_keys:)
        return nil unless payload.is_a?(Hash)

        input, input_present = token_value(payload, *input_keys)
        output, output_present = token_value(payload, *output_keys)
        return nil unless input_present || output_present

        {
          source: source,
          input: input,
          output: output,
          input_present: input_present,
          output_present: output_present
        }
      end

      def extract_top_level_token_usage(obj)
        return nil if obj.key?("role") && !assistant_role?(obj["role"])
        return nil if obj["message"].is_a?(Hash) && obj["message"].key?("role") &&
          !assistant_role?(obj["message"]["role"])

        usage = extract_payload_token_usage(
          obj["usage"],
          source: :usage,
          input_keys: ["input_tokens", "inputTokens", "input"],
          output_keys: ["output_tokens", "outputTokens", "output"]
        )
        tokens = extract_payload_token_usage(
          obj["tokens"],
          source: :usage,
          input_keys: ["input_tokens", "inputTokens", "input"],
          output_keys: ["output_tokens", "outputTokens", "output"]
        )
        return nil unless usage || tokens

        input, input_present = merged_token_metric(usage, tokens, :input)
        output, output_present = merged_token_metric(usage, tokens, :output)
        return nil unless input_present || output_present

        {
          source: :usage,
          input: input,
          output: output,
          input_present: input_present,
          output_present: output_present
        }
      end

      def merged_token_metric(primary, fallback, metric)
        present_key = :"#{metric}_present"
        return [primary[metric], true] if primary&.[](present_key)
        return [fallback[metric], true] if fallback&.[](present_key)

        [0, false]
      end

      def empty_token_totals
        {
          input: 0,
          output: 0,
          input_present: false,
          output_present: false
        }
      end

      def accumulate_token_totals!(totals, token_usage)
        if token_usage[:input_present]
          totals[:input_present] = true
          totals[:input] += token_usage[:input]
        end

        return unless token_usage[:output_present]

        totals[:output_present] = true
        totals[:output] += token_usage[:output]
      end

      def token_value(obj, *keys)
        keys.each do |candidate|
          next unless obj.key?(candidate)

          value, valid = coerce_token_value(obj[candidate])
          return [value, true] if valid
        end

        [0, false]
      end

      def build_tokens(shutdown_tokens:, usage_tokens:, fallback_tokens:)
        input, input_present = first_present_token_metric(shutdown_tokens, usage_tokens, fallback_tokens, :input)
        output, output_present = first_present_token_metric(shutdown_tokens, usage_tokens, fallback_tokens, :output)
        return nil unless input_present || output_present

        {input: input, output: output, total: input + output}
      end

      def first_present_token_metric(*sources, metric)
        present_key = :"#{metric}_present"

        sources.each do |source|
          next unless source[present_key]

          return [source[metric], true]
        end

        [0, false]
      end

      def render_output_segments(segments)
        rendered = +""
        previous_kind = nil
        previous_terminated = false

        segments.each do |segment|
          if previous_terminated && previous_kind == :assistant &&
              segment[:kind] != :assistant &&
              !rendered.empty? &&
              !rendered.end_with?("\n")
            rendered << "\n"
          end

          rendered << segment[:content]
          previous_kind = segment[:kind]
          previous_terminated = segment[:terminated]
        end

        rendered
      end

      def append_delta_segment!(segments, text, terminated:)
        previous_segment = segments.last
        if previous_segment&.[](:provisional) && previous_segment[:kind] == :assistant
          previous_segment[:content] << text
          previous_segment[:terminated] = terminated
          return
        end

        segments << {
          kind: :assistant,
          content: +text,
          terminated: terminated,
          provisional: true
        }
      end

      def drop_provisional_segments!(segments)
        segments.reject! { |segment| segment[:provisional] }
      end

      def copilot_cli_supports_json_output?
        return @copilot_cli_supports_json_output unless @copilot_cli_supports_json_output.nil?

        version = copilot_cli_version
        @copilot_cli_supports_json_output = !version.nil? && version >= MIN_JSON_OUTPUT_VERSION
      rescue
        @copilot_cli_supports_json_output = false
      end

      def copilot_cli_version
        return @copilot_cli_version if defined?(@copilot_cli_version)

        result = @executor.execute([self.class.binary_name, "--version"], timeout: 5)
        @copilot_cli_version = parse_copilot_cli_version(result.stdout) || parse_copilot_cli_version(result.stderr)
      rescue
        @copilot_cli_version = nil
      end

      def parse_copilot_cli_version(output)
        match = output.to_s.match(/(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)/)
        return nil unless match

        Gem::Version.new(match[1])
      rescue ArgumentError
        nil
      end

      def coerce_token_value(value)
        case value
        when Integer
          return [value, true] if value >= 0
        when Float
          return [value.to_i, true] if value.finite? && value >= 0 && value == value.to_i
        when String
          return [value.to_i, true] if /\A\+?\d+\z/.match?(value)
        end

        [0, false]
      end
    end
  end
end
