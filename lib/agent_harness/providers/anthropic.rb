# frozen_string_literal: true

require "json"
require "shellwords"

module AgentHarness
  module Providers
    # Anthropic Claude Code CLI provider
    #
    # Provides integration with the Claude Code CLI tool for AI-powered
    # coding assistance.
    #
    # @example Basic usage
    #   provider = AgentHarness::Providers::Anthropic.new
    #   response = provider.send_message(prompt: "Hello!")
    class Anthropic < Base
      # Model name pattern for Anthropic Claude models
      MODEL_PATTERN = /^claude-[\d.-]+-(?:opus|sonnet|haiku)(?:-\d{8})?$/i
      SUPPORTED_CLI_VERSION = "2.1.92"
      SUPPORTED_CLI_REQUIREMENT = Gem::Requirement.new(">= #{SUPPORTED_CLI_VERSION}", "< 2.2.0").freeze

      # Matches semver (e.g. "2.1.92"), optional pre-release (e.g. "2.1.92-beta.1"),
      # or channel tokens (e.g. "latest", "stable").
      VALID_VERSION_PATTERN = /\A(?:\d+\.\d+\.\d+(?:-[a-zA-Z0-9.]+)?|latest|stable)\z/

      class << self
        def provider_name
          :claude
        end

        def binary_name
          "claude"
        end

        def install_contract(version: nil)
          target_version = version || SUPPORTED_CLI_VERSION
          validate_version!(target_version)
          version_requirement = SUPPORTED_CLI_REQUIREMENT.requirements
            .map { |op, ver| "#{op} #{ver}" }
            .join(", ")
          channel_token = %w[latest stable].include?(target_version.to_s)

          warning = "Review the downloaded installer before execution and verify any published checksum or signature metadata when available."
          if channel_token
            warning += " Channel '#{target_version}' is not pinned; the resolved version may fall " \
              "outside the supported range (#{version_requirement}). Verify the installed version " \
              "after installation."
          end

          {
            provider: provider_name,
            binary_name: binary_name,
            binary_paths: [
              "$HOME/.local/bin/claude",
              binary_name
            ],
            install: {
              strategy: :shell,
              source: "official",
              command: "tmp_script=$(mktemp) && trap 'rm -f \"$tmp_script\"' EXIT && curl -fsSL https://claude.ai/install.sh -o \"$tmp_script\" && bash \"$tmp_script\" #{Shellwords.shellescape(target_version)}",
              warning: warning,
              post_install_binary_path: "$HOME/.local/bin/claude",
              # When a channel token is used, include the requirement so
              # consumers can validate the installed version post-install.
              version_not_pinned: channel_token
            },
            supported_versions: {
              default: SUPPORTED_CLI_VERSION,
              requirement: version_requirement,
              channel: "stable"
            },
            runtime_contract: {
              available_via: binary_name,
              build_command: [
                binary_name,
                "--print",
                "--output-format=json"
              ],
              required_features: [
                "print_mode",
                "json_output",
                "mcp_config",
                "mcp_list",
                "dangerously_skip_permissions",
                "models_list"
              ]
            }
          }
        end

        def available?
          executor = AgentHarness.configuration.command_executor
          !!executor.which(binary_name)
        end

        def provider_metadata_overrides
          {
            auth: {
              service: :anthropic,
              api_family: :anthropic
            },
            identity: {
              bot_usernames: %w[claude anthropic]
            }
          }
        end

        def firewall_requirements
          {
            domains: [
              "api.anthropic.com",
              "claude.ai",
              "console.anthropic.com"
            ],
            ip_ranges: []
          }
        end

        def instruction_file_paths
          [
            {
              path: "CLAUDE.md",
              description: "Claude Code CLI agent instructions",
              symlink: true
            }
          ]
        end

        def discover_models
          return [] unless available?

          begin
            require "open3"
            output, _, status = Open3.capture3("claude", "models", "list", {timeout: 10})
            return [] unless status.success?

            parse_models_list(output)
          rescue => e
            AgentHarness.logger&.debug("[AgentHarness::Anthropic] Model discovery failed: #{e.message}")
            []
          end
        end

        # Normalize a provider-specific model name to its model family
        def model_family(provider_model_name)
          provider_model_name.sub(/-\d{8}$/, "")
        end

        # Convert a model family name to the provider's preferred model name
        def provider_model_name(family_name)
          family_name
        end

        # Check if this provider supports a given model family
        def supports_model_family?(family_name)
          MODEL_PATTERN.match?(family_name)
        end

        def smoke_test_contract
          Base::DEFAULT_SMOKE_TEST_CONTRACT
        end

        private

        def validate_version!(version)
          version_str = version.to_s

          unless VALID_VERSION_PATTERN.match?(version_str)
            raise ArgumentError, "Invalid version: #{version.inspect}. " \
              "Must be a semver string (e.g. '2.1.92'), optional pre-release suffix, or a channel token ('latest', 'stable')."
          end

          # Channel tokens are not concrete versions; skip requirement check.
          return if %w[latest stable].include?(version_str)

          # Validate concrete versions against the supported range.
          gem_version = Gem::Version.new(version_str)
          return if SUPPORTED_CLI_REQUIREMENT.satisfied_by?(gem_version)

          raise ArgumentError, "Version #{version.inspect} is outside the supported range " \
            "(#{SUPPORTED_CLI_REQUIREMENT}). Update SUPPORTED_CLI_REQUIREMENT before targeting this version."
        end

        def parse_models_list(output)
          return [] if output.nil? || output.empty?

          models = []
          lines = output.lines.map(&:strip)

          # Skip header and separator lines
          lines.reject! { |line| line.empty? || line.match?(/^[-=]+$/) || line.match?(/^(Model|Name)/i) }

          lines.each do |line|
            model_info = parse_model_line(line)
            models << model_info if model_info
          end

          models
        end

        def parse_model_line(line)
          # Format 1: Simple list of model names
          if line.match?(/^claude-\d/)
            model_name = line.split.first
            return build_model_info(model_name)
          end

          # Format 2: Table format with columns
          parts = line.split(/\s{2,}/)
          if parts.size >= 1 && parts[0].match?(/^claude/)
            model_name = parts[0]
            model_name = "#{model_name}-#{parts[1]}" if parts.size > 1 && parts[1].match?(/^\d{8}$/)
            return build_model_info(model_name)
          end

          nil
        end

        def build_model_info(model_name)
          family = model_family(model_name)
          tier = classify_tier(model_name)

          {
            name: model_name,
            family: family,
            tier: tier,
            capabilities: extract_capabilities(model_name),
            context_window: infer_context_window(family),
            provider: "anthropic"
          }
        end

        def classify_tier(model_name)
          name_lower = model_name.downcase
          return "advanced" if name_lower.include?("opus")
          return "mini" if name_lower.include?("haiku")
          return "standard" if name_lower.include?("sonnet")
          "standard"
        end

        def extract_capabilities(model_name)
          capabilities = ["chat", "code"]
          name_lower = model_name.downcase
          capabilities << "vision" unless name_lower.include?("haiku")
          capabilities
        end

        def infer_context_window(family)
          family.match?(/claude-3/) ? 200_000 : nil
        end
      end

      def name
        "anthropic"
      end

      def display_name
        "Anthropic Claude CLI"
      end

      def configuration_schema
        {
          fields: [
            {
              name: :model,
              type: :string,
              label: "Model",
              required: false,
              hint: "Claude model to use (e.g. claude-3-5-sonnet-20241022)",
              accepts_arbitrary: false
            }
          ],
          auth_modes: [:oauth],
          openai_compatible: false
        }
      end

      def capabilities
        {
          streaming: true,
          file_upload: true,
          vision: true,
          tool_use: true,
          json_mode: true,
          mcp: true,
          dangerous_mode: true
        }
      end

      def send_message(prompt:, **options)
        super
      ensure
        cleanup_mcp_tempfiles!
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
        ["--mcp-config", config_path]
      end

      def dangerous_mode_flags
        ["--dangerously-skip-permissions"]
      end

      def auth_type
        :oauth
      end

      def execution_semantics
        {
          prompt_delivery: :arg,
          output_format: :json,
          sandbox_aware: true,
          uses_subcommand: false,
          non_interactive_flag: "--print",
          legitimate_exit_codes: [0],
          stderr_is_diagnostic: true,
          parses_rate_limit_reset: false
        }
      end

      def error_patterns
        {
          rate_limited: [
            /rate.?limit/i,
            /too.?many.?requests/i,
            /\b429\b/,
            /overloaded/i,
            /session.?limit/i
          ],
          auth_expired: [
            /oauth.*token.*expired/i,
            /authentication.*error/i,
            /invalid.*api.*key/i,
            /unauthorized/i,
            /\b401\b/,
            /session.*expired/i,
            /not.*logged.*in/i,
            /login.*required/i,
            /credentials.*expired/i
          ],
          quota_exceeded: [
            /quota.*exceeded/i,
            /usage.*limit/i,
            /credit.*exhausted/i
          ],
          transient: [
            /timeout/i,
            /connection.*reset/i,
            /temporary.*error/i,
            /service.*unavailable/i,
            /\b503\b/,
            /\b502\b/,
            /\b504\b/
          ],
          permanent: [
            /invalid.*model/i,
            /unsupported.*operation/i,
            /not.*found/i,
            /\b404\b/,
            /bad.*request/i,
            /\b400\b/,
            /model.*deprecated/i,
            /end-of-life/i
          ]
        }
      end

      def fetch_mcp_servers
        return [] unless self.class.available?

        begin
          result = @executor.execute(["claude", "mcp", "list"], timeout: 5)
          return [] unless result.success?

          parse_claude_mcp_output(result.stdout)
        rescue => e
          log_debug("fetch_mcp_servers_failed", error: e.message)
          []
        end
      end

      protected

      def build_command(prompt, options)
        cmd = [self.class.binary_name]

        cmd += ["--print", "--output-format=json"]

        # Add model if specified
        if @config.model && !@config.model.empty?
          cmd += ["--model", @config.model]
        end

        # Add dangerous mode if requested
        if options[:dangerous_mode] && supports_dangerous_mode?
          cmd += dangerous_mode_flags
        end

        # Add MCP server flags (validated/normalized by Base#send_message)
        if options[:mcp_servers]&.any?
          cmd += build_mcp_flags(options[:mcp_servers])
        end

        # Add custom flags from config
        cmd += @config.default_flags if @config.default_flags&.any?

        cmd << prompt

        cmd
      end

      def parse_response(result, duration:)
        output = result.stdout
        error = nil
        tokens = nil

        if result.failed?
          combined = [result.stdout, result.stderr].compact.join("\n")
          error = classify_error_message(combined)
        end

        # Parse JSON output to extract result text and token usage
        parsed = parse_json_output(output)
        if parsed
          output = parsed["result"] || output
          tokens = extract_tokens(parsed)
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

      def parse_json_output(output)
        return nil if output.nil? || output.empty?

        JSON.parse(output)
      rescue JSON::ParserError
        nil
      end

      def extract_tokens(parsed)
        usage = parsed["usage"]
        return nil unless usage

        input = usage["input_tokens"]
        output = usage["output_tokens"]
        return nil unless input || output

        input ||= 0
        output ||= 0

        {input: input, output: output, total: input + output}
      end

      def classify_error_message(message)
        msg_lower = message.downcase

        if msg_lower.include?("rate limit") || msg_lower.include?("session limit")
          "Rate limit exceeded"
        elsif msg_lower.include?("deprecat") || msg_lower.include?("end-of-life")
          "Model deprecated"
        elsif msg_lower.include?("oauth token") || msg_lower.include?("authentication")
          "Authentication error"
        else
          message
        end
      end

      def parse_claude_mcp_output(output)
        servers = []
        return servers unless output

        lines = output.lines
        lines.reject! { |line| /checking mcp server health/i.match?(line) }

        lines.each do |line|
          line = line.strip
          next if line.empty?

          # Parse format: "name: command - ✓ Connected"
          if line =~ /^([^:]+):\s*(.+?)\s*-\s*(✓|✗)\s*(.+)$/
            name = Regexp.last_match(1).strip
            command = Regexp.last_match(2).strip
            status_symbol = Regexp.last_match(3)
            status_text = Regexp.last_match(4).strip

            servers << {
              name: name,
              status: (status_symbol == "✓") ? "connected" : "error",
              description: command,
              enabled: status_symbol == "✓",
              error: (status_symbol == "✗") ? status_text : nil,
              source: "claude_cli"
            }
          end
        end

        servers
      end

      def write_mcp_config_file(mcp_servers, working_dir: nil)
        require "tempfile"
        require "tmpdir"
        require "securerandom"

        config = build_claude_mcp_config(mcp_servers)
        config_json = JSON.generate(config)

        if @executor.is_a?(DockerCommandExecutor)
          # When running inside a Docker container, write the config file
          # inside the container so the CLI process can read it.
          # Track the path so cleanup_mcp_tempfiles! can remove it after execution.
          container_path = "/tmp/agent_harness_mcp_#{SecureRandom.hex(8)}.json"
          result = @executor.execute(
            ["sh", "-c", "cat > #{container_path}"],
            stdin_data: config_json,
            timeout: 5
          )
          unless result.success?
            raise McpConfigurationError,
              "Failed to write MCP config inside container: #{result.stderr}"
          end

          @mcp_docker_config_paths ||= []
          @mcp_docker_config_paths << container_path

          container_path
        else
          dir = working_dir || Dir.tmpdir
          file = Tempfile.new(["agent_harness_mcp_", ".json"], dir)
          file.write(config_json)
          file.close

          # Hold a reference so the Tempfile is not garbage-collected (and
          # therefore deleted) before the CLI process reads it.
          # Cleaned up by cleanup_mcp_tempfiles! after execution.
          @mcp_config_tempfiles ||= []
          @mcp_config_tempfiles << file

          file.path
        end
      end

      def build_claude_mcp_config(mcp_servers)
        servers = {}
        mcp_servers.each do |server|
          h = if server.stdio?
            entry = {command: server.command.first}
            remaining_args = server.command[1..] + server.args
            entry[:args] = remaining_args unless remaining_args.empty?
            entry
          else
            {url: server.url}
          end
          h[:env] = server.env unless server.env.empty?
          servers[server.name] = h
        end
        {mcpServers: servers}
      end

      def cleanup_mcp_tempfiles!
        if @mcp_config_tempfiles
          @mcp_config_tempfiles.each do |file|
            file.close unless file.closed?
            file.unlink
          rescue
            nil
          end
          @mcp_config_tempfiles = nil
        end

        if @mcp_docker_config_paths
          @mcp_docker_config_paths.each do |path|
            @executor.execute(["rm", "-f", path], timeout: 5)
          rescue
            nil
          end
          @mcp_docker_config_paths = nil
        end
      end

      def log_debug(action, **context)
        @logger&.debug("[AgentHarness::Anthropic] #{action}: #{context.inspect}")
      end
    end
  end
end
