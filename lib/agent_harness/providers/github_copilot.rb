# frozen_string_literal: true

require "json"

module AgentHarness
  module Providers
    class GithubCopilot < Base
      MODEL_PATTERN = /^gpt-[\d.o-]+(?:-turbo)?(?:-mini)?$/i

      SMOKE_TEST_CONTRACT = {
        prompt: "Reply with exactly OK.",
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
          output_format: :json,
          sandbox_aware: false,
          uses_subcommand: false,
          non_interactive_flag: "-p",
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

      def supports_token_counting?
        true
      end

      protected

      def build_command(prompt, options)
        cmd = [self.class.binary_name, "-p", prompt]

        cmd += ["--output-format", "json"]

        if options[:dangerous_mode] && supports_dangerous_mode?
          cmd += dangerous_mode_flags
        end

        if options[:session] && !options[:session].empty?
          cmd += session_flags(options[:session])
        end

        cmd
      end

      def parse_response(result, duration:)
        output = result.stdout
        error = nil
        tokens = nil

        if result.failed?
          combined = [result.stdout, result.stderr].compact.join("\n")
          error = combined unless combined.strip.empty?
        end

        parsed_lines = parse_jsonl_output(output)
        if parsed_lines
          output = extract_text_from_jsonl(parsed_lines) || output
          tokens = extract_tokens_from_jsonl(parsed_lines)
        end

        Response.new(
          output: output,
          exit_code: result.exit_code,
          duration: duration,
          provider: self.class.provider_name,
          model: @config.model,
          tokens: tokens,
          error: error
        )
      end

      def default_timeout
        300
      end

      private

      def parse_jsonl_output(output)
        return nil if output.nil? || output.strip.empty?

        lines = output.strip.split("\n")
        parsed = lines.filter_map do |line|
          JSON.parse(line)
        rescue JSON::ParserError
          nil
        end
        parsed.empty? ? nil : parsed
      end

      def extract_text_from_jsonl(parsed_lines)
        text_parts = parsed_lines.filter_map do |obj|
          obj["text"] || obj["content"] || obj["result"]
        end
        text_parts.empty? ? nil : text_parts.join
      end

      def extract_tokens_from_jsonl(parsed_lines)
        total_input = 0
        total_output = 0
        found = false

        parsed_lines.each do |obj|
          usage = find_usage(obj)
          next unless usage

          input = usage["input_tokens"] || usage["prompt_tokens"] || 0
          output_tok = usage["output_tokens"] || usage["completion_tokens"] || 0
          total_input += input
          total_output += output_tok
          found = true
        end

        return nil unless found
        return nil if total_input.zero? && total_output.zero?

        {input: total_input, output: total_output, total: total_input + total_output}
      end

      def find_usage(obj)
        return obj["usage"] if obj["usage"].is_a?(Hash)
        return obj.dig("message", "usage") if obj.dig("message", "usage").is_a?(Hash)
        nil
      end
    end
  end
end
