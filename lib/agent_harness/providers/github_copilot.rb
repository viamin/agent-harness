# frozen_string_literal: true

require "json"
require "pathname"
require "securerandom"
require "tmpdir"

module AgentHarness
  module Providers
    class GithubCopilot < Base
      include McpConfigFileSupport
      include TokenUsageParsing

      CLI_PACKAGE = "@github/copilot"
      INSTALL_COMMAND_PREFIX = ["npm", "install", "-g"].freeze
      DEFAULT_MAX_AUTOPILOT_CONTINUES = 50
      LEGACY_BINARY_NAME = "github-copilot-cli"
      MODEL_PATTERN = /^gpt-[\d.o-]+(?:-turbo)?(?:-mini)?$/i

      GITHUB_MODELS_BASE_URL = "https://models.inference.ai.azure.com"
      CHAT_DEFAULT_MODEL = "gpt-4o"
      CHAT_MODELS = %w[gpt-4o gpt-4o-mini gpt-4-turbo].freeze

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
          "copilot"
        end

        def available?
          executor = AgentHarness.configuration.command_executor
          return false unless executor.which(binary_name)

          true
        rescue
          false
        end

        def installation_contract(version: nil)
          normalized_version = normalize_install_version(version)
          package = normalized_version ? "#{CLI_PACKAGE}@#{normalized_version}" : CLI_PACKAGE
          install_command = (INSTALL_COMMAND_PREFIX + [package]).freeze

          contract = {
            source: :npm,
            package: package,
            package_name: CLI_PACKAGE,
            version: normalized_version,
            binary_name: binary_name,
            install_command_prefix: INSTALL_COMMAND_PREFIX,
            install_command: install_command
          }

          contract.each_value do |value|
            value.freeze if value.is_a?(String)
          end
          contract.freeze
        end

        def install_command(version: nil)
          installation_contract(version: version)[:install_command]
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

        def supports_chat?
          true
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

        private

        def normalize_install_version(version)
          return nil if version.nil?

          unless version.is_a?(String) && !version.strip.empty?
            raise ArgumentError, "Unsupported GitHub Copilot CLI version #{version.inspect}"
          end

          version.strip
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
          json_mode: true,
          mcp: true,
          dangerous_mode: true
        }
      end

      def supports_chat?
        true
      end

      def chat_models
        CHAT_MODELS
      end

      def chat_transport
        @chat_transport ||= OpenAICompatibleTransport.new(
          base_url: GITHUB_MODELS_BASE_URL,
          api_key: resolve_chat_api_key,
          model: CHAT_DEFAULT_MODEL,
          logger: @logger
        )
      end

      def build_runtime_chat_transport(runtime)
        OpenAICompatibleTransport.new(
          base_url: runtime.chat_base_url || GITHUB_MODELS_BASE_URL,
          api_key: runtime.chat_api_key || resolve_chat_api_key,
          model: runtime.chat_model || runtime.model || CHAT_DEFAULT_MODEL,
          logger: @logger
        )
      end

      def chat_transport_type
        :openai_compatible
      end

      def api_key_env_var_names
        ["COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"]
      end

      def api_key_unset_vars
        ["COPILOT_PROVIDER_API_KEY", "COPILOT_PROVIDER_BASE_URL"]
      end

      def subscription_unset_vars
        api_key_env_var_names + api_key_unset_vars
      end

      def auth_type
        :oauth
      end

      def dangerous_mode_flags
        ["--yolo"]
      end

      def supports_mcp?
        true
      end

      def supported_mcp_transports
        %w[stdio http sse]
      end

      def build_mcp_flags(mcp_servers, options:)
        return [] if mcp_servers.empty?

        ["--additional-mcp-config", "@#{mcp_config_plan(options, mcp_servers).fetch(:path)}"]
      end

      def supports_sessions?
        false
      end

      def execution_semantics
        {
          prompt_delivery: :arg,
          output_format: :json,
          sandbox_aware: false,
          uses_subcommand: false,
          non_interactive_flag: "--autopilot",
          legitimate_exit_codes: [0],
          stderr_is_diagnostic: true,
          parses_rate_limit_reset: false
        }
      end

      def error_patterns
        {
          auth_expired: [
            /not.?logged.?in/i,
            /not.?authorized/i,
            /authentication/i,
            /token.*invalid/i,
            /copilot requests/i
          ],
          rate_limited: [
            /rate.?limit/i,
            /too.?many.?requests/i,
            /\b429\b/
          ],
          transient: [
            /connection.?error/i,
            /timeout/i,
            /try.?again/i,
            /\b502\b/,
            /\b503\b/
          ],
          permanent: [
            /unknown.?flag/i,
            /invalid.?value/i,
            /continuation limit/i,
            /max.?autopilot.?continues/i
          ]
        }
      end

      def translate_error(message)
        case message
        when /copilot.*not found/i, /No such file or directory - copilot/i
          "GitHub Copilot CLI not installed."
        else
          message
        end
      end

      def supports_token_counting?
        true
      end

      def send_message(prompt:, **options)
        super
      ensure
        cleanup_mcp_tempfiles!
      end

      def build_command(prompt, options)
        runtime = options[:provider_runtime]
        cmd = [
          self.class.binary_name,
          "--autopilot",
          "--max-autopilot-continues",
          max_autopilot_continues(options).to_s,
          "--output-format",
          "json"
        ]
        # Smoke tests must run non-interactively; force full-permission mode
        # so autopilot does not stall on permission prompts.
        cmd += dangerous_mode_flags if (options[:dangerous_mode] || options[:smoke_test]) && supports_dangerous_mode?

        if options[:mcp_servers]&.any?
          cmd += build_mcp_flags(options[:mcp_servers], options: options)
        end

        cmd += @config.default_flags if @config.default_flags&.any?

        model = effective_model_name(runtime)
        cmd += ["--model", model] if model

        if runtime
          runtime_flags = runtime.flags
          cmd += runtime_flags unless runtime_flags.empty?
        end

        cmd += test_command_overrides if options[:smoke_test]
        cmd += ["-p", prompt]
        cmd
      end

      def build_env(options)
        env = super
        needs_full_permissions = options[:dangerous_mode] || options[:smoke_test]
        return env unless needs_full_permissions && supports_dangerous_mode?

        env.merge("COPILOT_ALLOW_ALL" => "true")
      end

      def build_execution_preparation(options)
        return nil unless options[:mcp_servers]&.any?

        plan = mcp_config_plan(options, options[:mcp_servers])
        ExecutionPreparation.new(
          file_writes: [
            {
              path: plan.fetch(:path),
              content: plan.fetch(:content),
              mode: 0o600
            }
          ]
        )
      end

      def parse_container_output(stdout:, stderr: "", exit_code: 0, duration: 0.0, **_options)
        result = CommandExecutor::Result.new(
          stdout: stdout,
          stderr: stderr,
          exit_code: exit_code,
          duration: duration
        )
        parse_response(result, duration: duration)
      end

      protected

      def parse_response(result, duration:)
        response = super
        parsed_lines = parse_jsonl_output(response.output)
        output = extract_text_from_jsonl(parsed_lines) || response.output
        tokens = extract_tokens_from_jsonl(parsed_lines)
        metadata = extract_metadata_from_jsonl(parsed_lines).merge(response.metadata)

        Response.new(
          output: output,
          exit_code: result.exit_code,
          duration: duration,
          provider: self.class.provider_name,
          model: normalized_model_name(metadata[:model]) || effective_model_name,
          tokens: tokens,
          metadata: metadata,
          error: response.error
        )
      end

      def default_timeout
        300
      end

      private

      def max_autopilot_continues(options)
        runtime = options[:provider_runtime]
        candidate = runtime&.metadata&.[](:max_autopilot_continues) ||
          runtime&.metadata&.[]("max_autopilot_continues") ||
          options[:max_autopilot_continues]
        value = Integer(candidate, exception: false)
        (value && value > 0) ? value : DEFAULT_MAX_AUTOPILOT_CONTINUES
      end

      def parse_jsonl_output(output)
        return [] if output.nil? || output.strip.empty?

        output.each_line(chomp: true).filter_map do |line|
          next if line.strip.empty?

          JSON.parse(line)
        rescue JSON::ParserError
          next
        end
      end

      def extract_metadata_from_jsonl(parsed_lines)
        metadata = {}
        parsed_lines.each do |obj|
          next unless obj.is_a?(Hash)

          model = normalized_model_name(
            obj["model"] ||
            nested_hash_value(obj, "message", "model") ||
            nested_hash_value(obj, "data", "model") ||
            nested_hash_value(obj, "data", "message", "model")
          )
          metadata[:model] = model if model
        end
        metadata
      end

      def extract_text_from_jsonl(parsed_lines)
        return nil if parsed_lines.empty?

        # Track snapshots and deltas with their position so we can merge
        # a final snapshot with any deltas that follow it.
        last_snapshot = nil
        last_snapshot_index = -1
        deltas = []

        parsed_lines.each_with_index do |obj, index|
          next unless assistant_output_event?(obj)

          snapshot = extract_non_delta_text(obj)
          if snapshot && !snapshot.empty?
            last_snapshot = snapshot
            last_snapshot_index = index
          end

          delta = extract_delta_text(obj)
          deltas << [index, delta] if delta && !delta.empty?
        end

        if last_snapshot
          # Append any delta events that arrived after the last snapshot
          trailing = deltas.select { |i, _| i > last_snapshot_index }.map(&:last)
          return trailing.any? ? last_snapshot + trailing.join : last_snapshot
        end

        return deltas.map(&:last).join if deltas.any?

        nil
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
        metrics_usages =
          model_metrics_usages(obj["modelMetrics"]) +
          model_metrics_usages(obj["model_metrics"]) +
          model_metrics_usages(nested_hash_value(obj, "data", "modelMetrics")) +
          model_metrics_usages(nested_hash_value(obj, "data", "model_metrics")) +
          model_metrics_usages(nested_hash_value(obj, "message", "modelMetrics")) +
          model_metrics_usages(nested_hash_value(obj, "message", "model_metrics")) +
          model_metrics_usages(nested_hash_value(obj, "data", "message", "modelMetrics")) +
          model_metrics_usages(nested_hash_value(obj, "data", "message", "model_metrics"))

        return metrics_usages if prefer_usage_set?(aggregate_usage_payload(metrics_usages), direct_usage)
        return [direct_usage] if direct_usage

        metrics_usages
      end

      def aggregate_token_totals(usages)
        total_input = 0
        total_output = 0
        found = false

        usages.each do |usage|
          input = token_count_for(usage, "input_tokens", "prompt_tokens", "inputTokens", "promptTokens")
          output = token_count_for(usage, "output_tokens", "completion_tokens", "outputTokens", "completionTokens")
          next if input.nil? && output.nil?

          total_input += input || 0
          total_output += output || 0
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

      MAX_METRICS_DEPTH = 5

      def model_metrics_usages(metrics, depth: 0)
        return [] unless metrics.is_a?(Hash)
        return [metrics] if usage_with_token_counts?(metrics)

        direct_usage = [
          metrics["usage"],
          metrics["totals"],
          metrics["total"],
          metrics["aggregate"]
        ].find { |value| usage_with_token_counts?(value) }
        return [direct_usage] if direct_usage
        return [] if depth >= MAX_METRICS_DEPTH

        metrics.each_value.flat_map { |value| model_metrics_usages(value, depth: depth + 1) }
      end

      def aggregate_usage_payload(usages)
        return nil if usages.empty?

        input = sum_token_field(usages, "input_tokens", "prompt_tokens", "inputTokens", "promptTokens")
        output = sum_token_field(usages, "output_tokens", "completion_tokens", "outputTokens", "completionTokens")
        return nil if input.nil? && output.nil?

        payload = {}
        payload["input_tokens"] = input unless input.nil?
        payload["output_tokens"] = output unless output.nil?
        payload
      end

      def prefer_usage_set?(candidate, current)
        return false if candidate.nil?
        return true if current.nil?

        (
          [usage_token_field_count(candidate), usage_token_total(candidate)] <=>
            [usage_token_field_count(current), usage_token_total(current)]
        ) == 1
      end

      def assistant_output_event?(obj)
        return false unless obj.is_a?(Hash)

        type = obj["type"]
        return true if type.nil? && !role_key_present?(obj)

        role = extract_event_role(obj)
        return true if role.nil? && type.to_s.match?(/\A(?:assistant\.|turn\.)/)

        role == "assistant"
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

      def usage_payload?(value)
        value.is_a?(Hash) && token_count_keys.any? { |key| value.key?(key) }
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

      def hash_key_present?(value, key)
        value.is_a?(Hash) && value.key?(key)
      end

      def resolve_chat_api_key
        key = ENV["COPILOT_GITHUB_TOKEN"] || ENV["GH_TOKEN"] || ENV["GITHUB_TOKEN"] || read_copilot_cli_access_token

        if key.nil? || key.strip.empty?
          raise AuthenticationError.new(
            "Chat mode requires a GitHub token. Set COPILOT_GITHUB_TOKEN, GH_TOKEN, or GITHUB_TOKEN, or authenticate the Copilot CLI.",
            provider: :github_copilot
          )
        end

        key.strip
      end

      def read_copilot_cli_access_token
        token = read_token_from_copilot_config
        return token if token

        path = Pathname.new(File.join(Dir.home, ".copilot-cli-access-token"))
        return nil unless path.file?

        path.read
      rescue Errno::ENOENT, Errno::EACCES, IOError
        nil
      end

      def read_token_from_copilot_config
        config_home = ENV["COPILOT_HOME"]
        base_dir = if config_home && !config_home.strip.empty?
          config_home
        else
          File.join(Dir.home, ".copilot")
        end
        path = Pathname.new(File.join(base_dir, "config.json"))
        return nil unless path.file?

        config = JSON.parse(path.read)
        normalized_model_name(
          config["oauth_token"] ||
          config["oauthToken"] ||
          config["token"] ||
          nested_hash_value(config, "auth", "token")
        )
      rescue JSON::ParserError, Errno::ENOENT, Errno::EACCES, IOError
        nil
      end

      def mcp_provider_key
        :github_copilot
      end

      def mcp_config_plan(options, mcp_servers)
        options[:_github_copilot_mcp_config] ||= {
          path: File.join(Dir.tmpdir, "agent_harness_copilot_mcp_#{SecureRandom.hex(8)}.json"),
          content: JSON.generate(McpConfigTranslator.for_provider(mcp_provider_key, mcp_servers))
        }
      end
    end
  end
end
