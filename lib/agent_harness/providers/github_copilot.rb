# frozen_string_literal: true

require "json"
require "pathname"

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

      def cli_env_overrides
        {"COPILOT_ALLOW_ALL" => "true"}
      end

      def supports_mcp?
        true
      end

      def supported_mcp_transports
        %w[stdio http sse]
      end

      def build_mcp_flags(mcp_servers, working_dir: nil)
        return [] if mcp_servers.empty?

        config_path = write_mcp_config_file(mcp_servers, working_dir: working_dir)
        ["--additional-mcp-config", "@#{config_path}"]
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
          "--yolo",
          "--max-autopilot-continues",
          max_autopilot_continues(options).to_s,
          "--output-format",
          "json"
        ]

        if options[:mcp_servers]&.any?
          cmd += build_mcp_flags(options[:mcp_servers])
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
        super.merge(cli_env_overrides)
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

        snapshots = []
        deltas = []

        parsed_lines.each do |obj|
          next unless assistant_output_event?(obj)

          snapshot = extract_non_delta_text(obj)
          snapshots << snapshot if snapshot && !snapshot.empty?

          delta = extract_delta_text(obj)
          deltas << delta if delta && !delta.empty?
        end

        return snapshots.last if snapshots.any?
        return deltas.join if deltas.any?

        nil
      end

      def extract_tokens_from_jsonl(parsed_lines)
        usage = select_best_usage_payload(parsed_lines.flat_map { |obj| find_usages(obj) })
        return nil unless usage

        input = token_count_for(usage, "input_tokens", "prompt_tokens", "inputTokens", "promptTokens") || 0
        output = token_count_for(usage, "output_tokens", "completion_tokens", "outputTokens", "completionTokens") || 0

        {
          input: input,
          output: output,
          total: input + output
        }
      end

      def find_usages(obj)
        return [] unless obj.is_a?(Hash)

        candidates = [
          obj["usage"],
          obj["tokens"],
          obj["modelMetrics"],
          obj["model_metrics"],
          nested_hash_value(obj, "data", "usage"),
          nested_hash_value(obj, "data", "tokens"),
          nested_hash_value(obj, "data", "modelMetrics"),
          nested_hash_value(obj, "data", "model_metrics"),
          nested_hash_value(obj, "message", "usage"),
          nested_hash_value(obj, "message", "tokens"),
          nested_hash_value(obj, "message", "modelMetrics"),
          nested_hash_value(obj, "message", "model_metrics"),
          nested_hash_value(obj, "data", "message", "usage"),
          nested_hash_value(obj, "data", "message", "tokens"),
          nested_hash_value(obj, "data", "message", "modelMetrics"),
          nested_hash_value(obj, "data", "message", "model_metrics")
        ]

        direct = select_best_usage_payload(candidates)
        direct ? [direct] : []
      end

      def assistant_output_event?(obj)
        return false unless obj.is_a?(Hash)

        role = [
          obj["role"],
          nested_hash_value(obj, "data", "role"),
          nested_hash_value(obj, "message", "role"),
          nested_hash_value(obj, "data", "message", "role")
        ].compact.first

        type = obj["type"].to_s
        role.to_s == "assistant" || type.start_with?("assistant.") || type.start_with?("turn.")
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
    end
  end
end
