# frozen_string_literal: true

require "json"

module AgentHarness
  module Providers
    # GitHub Copilot CLI provider
    #
    # Provides integration with the GitHub Copilot CLI tool.
    class GithubCopilot < Base
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
          output_format: :text,
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
        cmd = [self.class.binary_name, "what-the-shell", prompt, "--output-format", "json"]

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

      # Override parse_response to handle JSONL output and token extraction
      def parse_response(result, duration:)
        output = result.stdout
        error = nil
        tokens = nil

        # Collect error if command failed
        if result.failed?
          combined = [result.stdout, result.stderr].compact.join("\n")
          error = combined unless combined.empty?
        end

        # Attempt to parse JSONL lines for output and token usage
        total_input = 0
        total_output = 0
        aggregated_output = ""
        result.stdout.lines.each do |line|
          line = line.strip
          next if line.empty?
          begin
            obj = JSON.parse(line)
          rescue JSON::ParserError
            next
          end
          # Extract textual output (common keys)
          if obj["output"]
            aggregated_output << obj["output"]
          elsif obj["content"]
            aggregated_output << obj["content"]
          elsif obj["message"] && obj["message"]["content"]
            aggregated_output << obj["message"]["content"]
          end
          # Extract token usage (common structures)
          usage = obj["usage"] || obj["tokens"]
          if usage
            total_input += usage["input_tokens"].to_i if usage["input_tokens"]
            total_output += usage["output_tokens"].to_i if usage["output_tokens"]
            total_input += usage["input"].to_i if usage["input"]
            total_output += usage["output"].to_i if usage["output"]
          end
        end
        if total_input > 0 || total_output > 0
          tokens = {input: total_input, output: total_output, total: total_input + total_output}
        end
        final_output = aggregated_output.empty? ? output : aggregated_output

        Response.new(
          output: final_output,
          exit_code: result.exit_code,
          duration: duration,
          provider: self.class.provider_name,
          model: @config.model,
          tokens: tokens,
          error: error
        )
      end
    end
  end
end
