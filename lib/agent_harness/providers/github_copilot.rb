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
        output = result.stdout.to_s
        error = nil

        legitimate = execution_semantics[:legitimate_exit_codes] || [0]
        unless legitimate.include?(result.exit_code)
          combined = [result.stderr.to_s, output].map(&:strip).reject(&:empty?).join("\n")
          error = combined unless combined.empty?
        end

        usage_input = 0
        usage_output = 0
        usage_tokens_present = false
        fallback_input = 0
        fallback_output = 0
        fallback_tokens_present = false
        aggregated_output = +""
        output.lines.each do |line|
          line = line.strip
          next if line.empty?
          begin
            obj = JSON.parse(line)
          rescue JSON::ParserError
            next
          end

          text = extract_event_text(obj)
          aggregated_output << text if text

          token_usage = extract_token_usage(obj)
          next unless token_usage

          if token_usage[:source] == :usage
            usage_tokens_present = true
            usage_input += token_usage[:input]
            usage_output += token_usage[:output]
          else
            fallback_tokens_present = true
            fallback_input = token_usage[:input]
            fallback_output = token_usage[:output]
          end
        end

        tokens = build_tokens(
          usage_tokens_present: usage_tokens_present,
          usage_input: usage_input,
          usage_output: usage_output,
          fallback_tokens_present: fallback_tokens_present,
          fallback_input: fallback_input,
          fallback_output: fallback_output
        )
        final_output = aggregated_output.empty? ? output : aggregated_output

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

      ASSISTANT_OUTPUT_EVENT_TYPES = %w[assistant assistant.message].freeze
      USAGE_EVENT_TYPES = %w[usage assistant.usage].freeze

      def extract_event_text(obj)
        return nil unless obj.is_a?(Hash)

        if obj["type"] && obj["data"].is_a?(Hash)
          return nil unless ASSISTANT_OUTPUT_EVENT_TYPES.include?(obj["type"])

          data = obj["data"]
          return string_content(data["content"])
        end

        output = string_content(obj["output"])
        return output if output

        content = string_content(obj["content"])
        return content if content

        if obj["message"].is_a?(Hash)
          return string_content(obj["message"]["content"])
        end

        nil
      end

      def string_content(value)
        return value if value.is_a?(String)

        nil
      end

      def extract_token_usage(obj)
        return nil unless obj.is_a?(Hash)

        if obj["type"] && obj["data"].is_a?(Hash)
          data = obj["data"]

          if USAGE_EVENT_TYPES.include?(obj["type"])
            return nil unless token_fields_present?(data, "inputTokens", "input_tokens", "outputTokens", "output_tokens")

            return {
              source: :usage,
              input: token_value(data, "inputTokens", "input_tokens"),
              output: token_value(data, "outputTokens", "output_tokens")
            }
          end

          if ASSISTANT_OUTPUT_EVENT_TYPES.include?(obj["type"])
            return nil unless token_fields_present?(data, "inputTokens", "input_tokens", "outputTokens", "output_tokens")

            return {
              source: :assistant,
              input: token_value(data, "inputTokens", "input_tokens"),
              output: token_value(data, "outputTokens", "output_tokens")
            }
          end

          return nil
        end

        usage = extract_top_level_usage(obj)
        return nil unless usage
        return nil unless token_fields_present?(usage, "input_tokens", "inputTokens", "input", "output_tokens", "outputTokens", "output")

        {
          source: :usage,
          input: token_value(usage, "input_tokens", "inputTokens", "input"),
          output: token_value(usage, "output_tokens", "outputTokens", "output")
        }
      end

      def extract_top_level_usage(obj)
        return obj["usage"] if obj["usage"].is_a?(Hash) && !obj["usage"].empty?
        return obj["tokens"] if obj["tokens"].is_a?(Hash)

        nil
      end

      def token_value(obj, *keys)
        key = keys.find { |candidate| obj.key?(candidate) }
        return 0 unless key

        obj[key].to_i
      end

      def token_fields_present?(obj, *keys)
        keys.any? { |candidate| obj.key?(candidate) }
      end

      def build_tokens(usage_tokens_present:, usage_input:, usage_output:, fallback_tokens_present:, fallback_input:,
        fallback_output:)
        if usage_tokens_present
          return {input: usage_input, output: usage_output, total: usage_input + usage_output}
        end

        return nil unless fallback_tokens_present

        {input: fallback_input, output: fallback_output, total: fallback_input + fallback_output}
      end

      def copilot_cli_supports_json_output?
        return @copilot_cli_supports_json_output unless @copilot_cli_supports_json_output.nil?

        version = copilot_cli_version
        @copilot_cli_supports_json_output = version && version >= MIN_JSON_OUTPUT_VERSION
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
    end
  end
end
