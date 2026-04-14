# frozen_string_literal: true

require "digest"
require "json"
require "rubygems"

module AgentHarness
  module Providers
    class GithubCopilot < Base
      MODEL_PATTERN = /^gpt-[\d.o-]+(?:-turbo)?(?:-mini)?$/i
      JSON_OUTPUT_MIN_VERSION = Gem::Version.new("0.0.422").freeze

      SMOKE_TEST_CONTRACT = {
        prompt: "Reply with exactly OK.",
        expected_output: "OK",
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
          fields: [
            {
              name: :model,
              type: :string,
              label: "Model",
              required: false,
              hint: "Copilot model identifier (for example gpt-4o or gpt-4o-mini)",
              accepts_arbitrary: true
            }
          ],
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

      def dangerous_mode_flags(probe_timeout: nil, env: {})
        if supports_json_output_format?(probe_timeout: probe_timeout, env: env)
          ["--allow-all"]
        else
          ["--allow-all-tools"]
        end
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
          # Older Copilot CLIs fall back to plain-text prompt mode, so metadata
          # must not claim JSON-only output even though newer versions support it.
          output_format: :text,
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
        supports_json_output_format?
      end

      def send_message(prompt:, **options)
        log_debug("send_message_start", prompt_length: prompt.length, options: options.keys)

        options = normalize_provider_runtime(options)
        options = normalize_mcp_servers(options)
        validate_mcp_servers!(options[:mcp_servers]) if options[:mcp_servers]&.any?

        timeout = options[:timeout] || @config.timeout || default_timeout
        raise TimeoutError, "Command timed out before execution started" if timeout <= 0

        env = build_env(options)
        options = options.merge(_version_probe_timeout: [timeout, 5].min, _command_env: env)

        start_time = Time.now
        command = build_command(prompt, options)
        preparation = build_execution_preparation(options)
        remaining_timeout = timeout - (Time.now - start_time)
        raise TimeoutError, "Command timed out before execution started" if remaining_timeout <= 0

        json_output_requested = command.include?("--output-format") && command.include?("json")

        result = execute_with_timeout(
          command,
          timeout: remaining_timeout,
          env: env,
          preparation: preparation,
          **command_execution_options(options)
        )
        duration = Time.now - start_time

        response = parse_response(result, duration: duration, json_output_requested: json_output_requested)
        runtime = options[:provider_runtime]
        effective_runtime_model = normalized_model_name(runtime&.model)
        if effective_runtime_model
          response = Response.new(
            output: response.output,
            exit_code: response.exit_code,
            duration: response.duration,
            provider: response.provider,
            model: effective_runtime_model,
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
      end

      protected

      def build_command(prompt, options)
        cmd = [self.class.binary_name, "-p", prompt]
        env = options.fetch(:_command_env) { build_env(options) }
        runtime = options[:provider_runtime]

        if supports_json_output_format?(probe_timeout: options[:_version_probe_timeout], env: env)
          cmd += ["--output-format", "json"]
        else
          # Silent mode suppresses the model/stats decoration older CLIs print in
          # prompt mode, which keeps smoke-test output stable on the plain-text path.
          cmd << "-s"
        end

        model = effective_model_name(runtime)
        cmd += ["--model", model] if model

        if options[:dangerous_mode] && supports_dangerous_mode?
          cmd += dangerous_mode_flags(probe_timeout: options[:_version_probe_timeout], env: env)
        end

        if options[:session] && !options[:session].empty?
          cmd += session_flags(options[:session])
        end

        cmd
      end

      def parse_response(result, duration:, json_output_requested: false)
        response = super(result, duration: duration)
        output = response.output
        tokens = nil

        parsed_lines = if json_output_requested && response.error.nil?
          parse_jsonl_output(output)
        end
        if parsed_lines
          output = extract_text_from_jsonl(parsed_lines) || output
          tokens = extract_tokens_from_jsonl(parsed_lines)
        end

        Response.new(
          output: output,
          exit_code: result.exit_code,
          duration: duration,
          provider: self.class.provider_name,
          model: effective_model_name,
          tokens: tokens,
          metadata: response.metadata,
          error: response.error
        )
      end

      def default_timeout
        300
      end

      private

      def supports_json_output_format?(probe_timeout: nil, env: {})
        version = copilot_cli_version(probe_timeout: probe_timeout, env: env)
        !version.nil? && version >= JSON_OUTPUT_MIN_VERSION
      end

      def effective_model_name(runtime = nil)
        normalized_model_name(runtime&.model) || normalized_model_name(@config.model)
      end

      def normalized_model_name(value)
        return nil unless value.is_a?(String)

        stripped = value.strip
        stripped.empty? ? nil : stripped
      end

      def copilot_cli_version(probe_timeout: nil, env: {})
        return nil if env.empty? && !copilot_cli_binary_available?

        cache_key = version_probe_cache_key(env)
        @copilot_cli_versions ||= {}
        return @copilot_cli_versions[cache_key] if @copilot_cli_versions.key?(cache_key)

        result = @executor.execute([self.class.binary_name, "--version"], timeout: probe_timeout || 5, env: env)
        version = extract_version(result)
        @copilot_cli_versions[cache_key] = version if version
        version
      rescue => e
        log_debug("copilot_cli_version_check_failed", error: e.message)
        nil
      end

      def version_probe_cache_key(env)
        [
          probe_env_cache_component(env, "PATH", inherited: :inherited_path, label: :path_override),
          probe_env_cache_component(env, "PATHEXT", inherited: :inherited_pathext, label: :pathext_override)
        ]
      end

      def probe_env_cache_component(env, key, inherited:, label:)
        return inherited unless env.key?(key)

        value = env[key]
        return [label, :unset] if value.nil?

        [label, Digest::SHA256.hexdigest(value)]
      end

      def copilot_cli_binary_available?
        @executor.which(self.class.binary_name)
      rescue => e
        log_debug("copilot_cli_binary_check_failed", error: e.message)
        nil
      end

      def extract_version(result)
        return nil unless result.success?

        version_string = [result.stdout, result.stderr].compact.join("\n")[/\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?/]
        return nil if version_string.nil? || version_string.empty?

        Gem::Version.new(version_string)
      rescue ArgumentError
        nil
      end

      def parse_jsonl_output(output)
        return nil if output.nil? || output.strip.empty?

        parsed = output.each_line(chomp: true).filter_map do |line|
          next if line.strip.empty?

          JSON.parse(line)
        rescue JSON::ParserError
          return nil
        end

        parsed.empty? ? nil : parsed
      end

      def extract_text_from_jsonl(parsed_lines)
        output = +""
        saw_text = false
        saw_delta = false

        parsed_lines.each do |obj|
          next unless obj.is_a?(Hash)
          next unless assistant_output_event?(obj)

          full_text = extract_non_delta_text(obj)
          if full_text
            output = if replace_output_with_full_text?(
              output,
              full_text,
              saw_delta: saw_delta,
              authoritative_snapshot: authoritative_full_snapshot?(obj)
            )
              full_text.dup
            else
              output + full_text
            end
            saw_text = true
            saw_delta = false
          end

          delta_text = extract_delta_text(obj)
          next unless delta_text

          output << delta_text
          saw_text = true
          saw_delta = true
        end

        saw_text ? output : nil
      end

      def replace_output_with_full_text?(existing_output, full_text, saw_delta:, authoritative_snapshot:)
        saw_delta ||
          authoritative_snapshot_replacement?(existing_output, full_text, authoritative_snapshot: authoritative_snapshot) ||
          (!existing_output.empty? && (
            full_text.start_with?(existing_output) ||
            existing_output.start_with?(full_text)
          ))
      end

      def authoritative_snapshot_replacement?(existing_output, full_text, authoritative_snapshot:)
        authoritative_snapshot &&
          !existing_output.empty? &&
          (
            existing_output.length == full_text.length ||
            full_text.start_with?(existing_output) ||
            existing_output.start_with?(full_text) ||
            longest_common_substring_length(existing_output, full_text) >= 2
          )
      end

      def longest_common_substring_length(left, right)
        return 0 if left.empty? || right.empty?

        longest = 0
        row = Array.new(right.length + 1, 0)

        left.each_char do |left_char|
          previous = 0

          right.each_char.with_index(1) do |right_char, index|
            current = row[index]
            row[index] = if left_char == right_char
              previous + 1
            else
              0
            end
            longest = [longest, row[index]].max
            previous = current
          end
        end

        longest
      end

      def authoritative_full_snapshot?(obj)
        obj["type"].to_s.match?(/\A(?:assistant\.message|turn\.)/) ||
          obj["message"].is_a?(Hash) ||
          nested_hash_value(obj, "data", "message").is_a?(Hash)
      end

      def assistant_output_event?(obj)
        type = obj["type"]
        return true if type.nil? && !role_key_present?(obj)

        role = extract_event_role(obj)
        return true if role.nil? && type.to_s.match?(/\A(?:assistant\.|turn\.)/)

        role == "assistant"
      end

      def role_key_present?(obj)
        obj.key?("role") ||
          hash_key_present?(obj["data"], "role") ||
          hash_key_present?(obj["message"], "role") ||
          hash_key_present?(nested_hash_value(obj, "data", "message"), "role")
      end

      def extract_event_role(obj)
        [
          obj["role"],
          nested_hash_value(obj, "data", "role"),
          nested_hash_value(obj, "message", "role"),
          nested_hash_value(obj, "data", "message", "role")
        ].compact.first&.to_s
      end

      def extract_tokens_from_jsonl(parsed_lines)
        authoritative = authoritative_usage_set(parsed_lines)

        if authoritative.nil?
          usages = parsed_lines.flat_map { |obj| find_usages(obj) }
          return aggregate_token_totals(usages)
        end

        auth_input = sum_token_field(authoritative, "input_tokens", "prompt_tokens", "inputTokens", "promptTokens")
        auth_output = sum_token_field(authoritative, "output_tokens", "completion_tokens", "outputTokens", "completionTokens")

        if !auth_input.nil? && !auth_output.nil?
          return {input: auth_input, output: auth_output, total: auth_input + auth_output}
        end

        fallback_usages = parsed_lines.flat_map { |obj| find_usages(obj) }
        fallback_input = sum_token_field(fallback_usages, "input_tokens", "prompt_tokens", "inputTokens", "promptTokens")
        fallback_output = sum_token_field(fallback_usages, "output_tokens", "completion_tokens", "outputTokens", "completionTokens")

        input = auth_input.nil? ? fallback_input : auth_input
        output = auth_output.nil? ? fallback_output : auth_output

        return nil if input.nil? && output.nil?

        input ||= 0
        output ||= 0
        {input: input, output: output, total: input + output}
      end

      def aggregate_token_totals(usages)
        total_input = 0
        total_output = 0
        found = false

        usages.each do |usage|
          input = token_count_for(usage, "input_tokens", "prompt_tokens", "inputTokens", "promptTokens")
          output_tok = token_count_for(usage, "output_tokens", "completion_tokens", "outputTokens", "completionTokens")
          next if input.nil? && output_tok.nil?

          total_input += input || 0
          total_output += output_tok || 0
          found = true
        end

        return nil unless found

        {input: total_input, output: total_output, total: total_input + total_output}
      end

      def sum_token_field(usages, *keys)
        total = nil
        usages.each do |usage|
          value = token_count_for(usage, *keys)
          next if value.nil?

          total = total.nil? ? value : total + value
        end
        total
      end

      def authoritative_usage_set(parsed_lines)
        usages = parsed_lines.flat_map do |obj|
          next [] unless authoritative_usage_event?(obj)

          find_usages(obj)
        end

        usages.any? ? usages : nil
      end

      def authoritative_usage_event?(obj)
        return false unless obj.is_a?(Hash)

        type = obj["type"].to_s
        type == "session.shutdown" ||
          type.end_with?(".shutdown") ||
          model_metrics_present?(obj)
      end

      def model_metrics_present?(obj)
        obj["modelMetrics"].is_a?(Hash) ||
          obj["model_metrics"].is_a?(Hash) ||
          nested_hash_value(obj, "data", "modelMetrics").is_a?(Hash) ||
          nested_hash_value(obj, "data", "model_metrics").is_a?(Hash) ||
          nested_hash_value(obj, "message", "modelMetrics").is_a?(Hash) ||
          nested_hash_value(obj, "message", "model_metrics").is_a?(Hash) ||
          nested_hash_value(obj, "data", "message", "modelMetrics").is_a?(Hash) ||
          nested_hash_value(obj, "data", "message", "model_metrics").is_a?(Hash)
      end

      def find_usages(obj)
        return [] unless obj.is_a?(Hash)

        direct_usage = select_best_usage_payload([
          obj["usage"],
          obj["tokens"],
          usage_payload?(obj) ? obj : nil,
          usage_payload?(obj["data"]) ? obj["data"] : nil,
          usage_payload?(obj["message"]) ? obj["message"] : nil,
          usage_payload?(nested_hash_value(obj, "data", "message")) ? nested_hash_value(obj, "data", "message") : nil,
          nested_hash_value(obj, "data", "usage"),
          nested_hash_value(obj, "data", "tokens"),
          nested_hash_value(obj, "message", "usage"),
          nested_hash_value(obj, "message", "tokens"),
          nested_hash_value(obj, "data", "message", "usage"),
          nested_hash_value(obj, "data", "message", "tokens")
        ])
        return [direct_usage] if direct_usage

        model_metrics_usages(obj["modelMetrics"]) +
          model_metrics_usages(obj["model_metrics"]) +
          model_metrics_usages(nested_hash_value(obj, "data", "modelMetrics")) +
          model_metrics_usages(nested_hash_value(obj, "data", "model_metrics")) +
          model_metrics_usages(nested_hash_value(obj, "message", "modelMetrics")) +
          model_metrics_usages(nested_hash_value(obj, "message", "model_metrics")) +
          model_metrics_usages(nested_hash_value(obj, "data", "message", "modelMetrics")) +
          model_metrics_usages(nested_hash_value(obj, "data", "message", "model_metrics"))
      end

      def model_metrics_usages(metrics)
        return [] unless metrics.is_a?(Hash)

        return [metrics] if usage_with_token_counts?(metrics)

        direct_usage = [
          metrics["usage"],
          metrics["totals"],
          metrics["total"],
          metrics["aggregate"]
        ].find { |value| usage_with_token_counts?(value) }
        return [direct_usage] if direct_usage

        metrics.each_value.flat_map { |value| model_metrics_usages(value) }
      end

      def normalize_token_count(value)
        count = case value
        when Integer
          value
        when String
          Integer(value, exception: false)
        end

        count if count && count >= 0
      end

      def token_count_for(usage, *keys)
        keys.each do |key|
          value = normalize_token_count(usage[key])
          return value unless value.nil?
        end
        nil
      end

      def select_best_usage_payload(candidates)
        candidates
          .select { |usage| usage_with_token_counts?(usage) }
          .max_by { |usage| [usage_token_field_count(usage), usage_token_total(usage)] }
      end

      def usage_token_field_count(usage)
        return 0 unless usage.is_a?(Hash)

        [
          token_count_for(usage, "input_tokens", "prompt_tokens", "inputTokens", "promptTokens"),
          token_count_for(usage, "output_tokens", "completion_tokens", "outputTokens", "completionTokens")
        ].count { |value| !value.nil? }
      end

      def usage_token_total(usage)
        return 0 unless usage.is_a?(Hash)

        [
          token_count_for(usage, "input_tokens", "prompt_tokens", "inputTokens", "promptTokens"),
          token_count_for(usage, "output_tokens", "completion_tokens", "outputTokens", "completionTokens")
        ].compact.sum
      end

      def usage_with_token_counts?(usage)
        return false unless usage_payload?(usage)
        return false if negative_token_count_present?(usage)

        token_count_for(usage, "input_tokens", "prompt_tokens", "inputTokens", "promptTokens") ||
          token_count_for(usage, "output_tokens", "completion_tokens", "outputTokens", "completionTokens")
      end

      def negative_token_count_present?(usage)
        token_count_keys.any? do |key|
          count = case usage[key]
          when Integer
            usage[key]
          when String
            Integer(usage[key], exception: false)
          end

          count && count < 0
        end
      end

      def extract_text_value(value)
        case value
        when String
          value
        when Array
          parts = value.filter_map { |part| extract_text_value(part) }
          parts.empty? ? nil : parts.join
        when Hash
          extract_text_value(value["text"]) ||
            extract_text_value(value["content"]) ||
            extract_text_value(value["parts"]) ||
            extract_text_value(value["result"]) ||
            extract_text_value(value["deltaContent"]) ||
            extract_text_value(value["delta_content"]) ||
            extract_text_value(value["delta"]) ||
            extract_text_value(value["message"]) ||
            extract_text_value(value["data"])
        end
      end

      def extract_non_delta_text(obj)
        extract_text_value(obj["text"]) ||
          extract_text_value(obj["content"]) ||
          extract_text_value(obj["parts"]) ||
          extract_text_value(obj["result"]) ||
          extract_text_value(nested_hash_value(obj, "message", "text")) ||
          extract_text_value(nested_hash_value(obj, "message", "content")) ||
          extract_text_value(nested_hash_value(obj, "message", "parts")) ||
          extract_text_value(nested_hash_value(obj, "message", "result")) ||
          extract_text_value(nested_hash_value(obj, "data", "text")) ||
          extract_text_value(nested_hash_value(obj, "data", "content")) ||
          extract_text_value(nested_hash_value(obj, "data", "parts")) ||
          extract_text_value(nested_hash_value(obj, "data", "result")) ||
          extract_text_value(nested_hash_value(obj, "data", "message", "text")) ||
          extract_text_value(nested_hash_value(obj, "data", "message", "content")) ||
          extract_text_value(nested_hash_value(obj, "data", "message", "parts")) ||
          extract_text_value(nested_hash_value(obj, "data", "message", "result"))
      end

      def extract_delta_text(obj)
        extract_text_value(obj["deltaContent"]) ||
          extract_text_value(obj["delta_content"]) ||
          extract_text_value(obj["delta"]) ||
          extract_text_value(nested_hash_value(obj, "data", "deltaContent")) ||
          extract_text_value(nested_hash_value(obj, "data", "delta_content")) ||
          extract_text_value(nested_hash_value(obj, "data", "delta")) ||
          extract_text_value(nested_hash_value(obj, "message", "deltaContent")) ||
          extract_text_value(nested_hash_value(obj, "message", "delta_content")) ||
          extract_text_value(nested_hash_value(obj, "message", "delta")) ||
          extract_text_value(nested_hash_value(obj, "data", "message", "deltaContent")) ||
          extract_text_value(nested_hash_value(obj, "data", "message", "delta_content")) ||
          extract_text_value(nested_hash_value(obj, "data", "message", "delta"))
      end

      def usage_payload?(value)
        value.is_a?(Hash) && token_count_keys.any? { |key| value.key?(key) }
      end

      def nested_hash_value(value, *keys)
        keys.reduce(value) do |current, key|
          break nil unless current.is_a?(Hash)

          current[key]
        end
      end

      def hash_key_present?(value, key)
        value.is_a?(Hash) && value.key?(key)
      end

      def token_count_keys
        %w[
          input_tokens
          prompt_tokens
          output_tokens
          completion_tokens
          inputTokens
          promptTokens
          outputTokens
          completionTokens
        ]
      end
    end
  end
end
