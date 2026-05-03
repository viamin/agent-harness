# frozen_string_literal: true

require "json"

module AgentHarness
  module Providers
    # Cursor AI CLI provider
    #
    # Provides integration with the Cursor AI coding assistant via its CLI tool.
    #
    # @example Basic usage
    #   provider = AgentHarness::Providers::Cursor.new
    #   response = provider.send_message(prompt: "Hello!")
    class Cursor < Base
      include RateLimitResetParsing

      INSTALL_SCRIPT_URL = "https://cursor.com/install"
      INSTALL_TARGET_LATEST = "latest"
      INSTALL_BUILD = "2026.03.30-a5d3e17"
      INSTALL_SCRIPT_SHA256 = "8371988b483abec13c07c10e95cccc839da81ebf9596e430d3c90835a227cbad"
      INSTALL_LINUX_X64_PACKAGE_SHA256 = "e0d4b611db111d2dbe76474386271bff3e1dbb2cc6ddf527f9d5d5801b2ce2a0"

      class << self
        def provider_name
          :cursor
        end

        def binary_name
          "cursor-agent"
        end

        def available?
          executor = AgentHarness.configuration.command_executor
          !!executor.which(binary_name)
        end

        def provider_metadata_overrides
          {
            auth: {
              service: :cursor,
              api_family: :cursor
            }
          }
        end

        def firewall_requirements
          {
            domains: [
              "cursor.com",
              "www.cursor.com",
              "downloads.cursor.com",
              "api.cursor.sh",
              "cursor.sh",
              "app.cursor.sh",
              "www.cursor.sh",
              "auth.cursor.sh",
              "auth0.com",
              "*.auth0.com"
            ],
            ip_ranges: []
          }
        end

        def instruction_file_paths
          [
            {
              path: ".cursorrules",
              description: "Cursor AI agent instructions",
              symlink: true
            }
          ]
        end

        def discover_models
          return [] unless available?

          # Cursor doesn't have a public model listing API
          # Return common model families it supports
          [
            {name: "claude-3.5-sonnet", family: "claude-3-5-sonnet", tier: "standard", provider: "cursor"},
            {name: "claude-3.5-haiku", family: "claude-3-5-haiku", tier: "mini", provider: "cursor"},
            {name: "gpt-4o", family: "gpt-4o", tier: "standard", provider: "cursor"},
            {name: "cursor-small", family: "cursor-small", tier: "mini", provider: "cursor"}
          ]
        end

        # Normalize Cursor's model name to family name
        def model_family(provider_model_name)
          # Normalize cursor naming: "claude-3.5-sonnet" -> "claude-3-5-sonnet"
          provider_model_name.gsub(/(\d)\.(\d)/, '\1-\2')
        end

        # Convert family name to Cursor's naming convention
        def provider_model_name(family_name)
          # Cursor uses dots: "claude-3-5-sonnet" -> "claude-3.5-sonnet"
          family_name.gsub(/(\d)-(\d)/, '\1.\2')
        end

        # Check if this provider supports a given model family
        def supports_model_family?(family_name)
          family_name.match?(/^(claude|gpt|cursor)-/)
        end

        def install_metadata(version: nil)
          install_target = normalize_install_target(version)
          linux_x64_package_url = package_url_for(os: "linux", arch: "x64")

          {
            source: {
              type: :shell_script,
              url: INSTALL_SCRIPT_URL,
              resolved_version: INSTALL_BUILD,
              default_artifact_url: linux_x64_package_url
            },
            checksum: {
              strategy: :sha256,
              targets: {
                script: {
                  url: INSTALL_SCRIPT_URL,
                  value: INSTALL_SCRIPT_SHA256
                },
                artifacts: {
                  "linux/x64" => {
                    url: linux_x64_package_url,
                    value: INSTALL_LINUX_X64_PACKAGE_SHA256
                  }
                }
              }
            },
            binary: {
              name: binary_name,
              path: "$HOME/.local/bin/#{binary_name}",
              suggested_global_path: "/usr/local/bin/#{binary_name}"
            },
            version: {
              default: INSTALL_TARGET_LATEST,
              supported: install_target,
              command: [binary_name, "--version"]
            }
          }
        end

        def smoke_test_contract
          Base::DEFAULT_SMOKE_TEST_CONTRACT
        end

        private

        def package_url_for(os:, arch:)
          format(
            "https://downloads.cursor.com/lab/%<build>s/%<os>s/%<arch>s/agent-cli-package.tar.gz",
            build: INSTALL_BUILD,
            os: os,
            arch: arch
          )
        end

        def normalize_install_target(version)
          target = version.nil? ? INSTALL_TARGET_LATEST : version.to_s
          return target if target == INSTALL_TARGET_LATEST

          raise ArgumentError, "Unsupported Cursor install target: #{version.inspect}"
        end
      end

      def name
        "cursor"
      end

      def display_name
        "Cursor AI"
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
          file_upload: true,
          vision: false,
          tool_use: true,
          json_mode: false,
          mcp: true,
          dangerous_mode: false
        }
      end

      def supports_mcp?
        true
      end

      # Cursor supports MCP for fetching existing server configurations (via
      # fetch_mcp_servers) but does not support injecting request-time MCP
      # servers into CLI invocations. Returning an empty list causes
      # validate_mcp_servers! to raise McpUnsupportedError with a clear message.
      def supported_mcp_transports
        []
      end

      def fetch_mcp_servers
        # Try CLI first, then config file
        fetch_mcp_servers_cli || fetch_mcp_servers_config
      end

      def api_key_env_var_names = ["ANTHROPIC_API_KEY"]

      def api_key_unset_vars = ["ANTHROPIC_BASE_URL", "ANTHROPIC_HEADER_X_AGENT_RUN_ID", "ANTHROPIC_HEADER_X_PROXY_TOKEN"]

      def auth_type
        :oauth
      end

      def execution_semantics
        {
          prompt_delivery: :stdin,
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
          rate_limited: [
            /rate.?limit/i,
            /too.?many.?requests/i,
            /\b429\b/
          ],
          auth_expired: [
            /authentication.*error/i,
            /invalid.*credentials/i,
            /unauthorized/i
          ],
          transient: [
            /timeout/i,
            /connection.*error/i,
            /temporary/i
          ]
        }
      end

      # Override send_message to send prompt via stdin
      def send_message(prompt:, **options)
        log_debug("send_message_start", prompt_length: prompt.length, options: options.keys)

        # Coerce provider_runtime from Hash if needed (same as Base#send_message)
        options = normalize_provider_runtime(options)
        runtime = options[:provider_runtime]

        # Normalize and validate MCP servers (same as Base#send_message)
        options = normalize_mcp_servers(options)
        validate_mcp_servers!(options[:mcp_servers]) if options[:mcp_servers]&.any?

        # Build command (without prompt in args - we send via stdin)
        command = [self.class.binary_name, "-p"]
        command.concat(runtime.flags) if runtime&.flags&.any?

        # Calculate timeout
        timeout = options[:timeout] || @config.timeout || default_timeout

        # Execute command with prompt on stdin
        env = build_env(options)
        preparation = build_execution_preparation(options)
        start_time = Time.now
        result = execute_with_timeout(
          command,
          timeout: timeout,
          env: env,
          stdin_data: prompt,
          preparation: preparation,
          **command_execution_options(options)
        )
        duration = Time.now - start_time

        # Parse response
        response = parse_response(result, duration: duration)
        # Runtime model is a per-request override and always takes precedence
        # over both the config-level model and whatever parse_response returned.
        # See Base#send_message for rationale.
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

        # Track tokens
        track_tokens(response) if response.tokens

        log_debug("send_message_complete", duration: duration)

        response
      rescue McpConfigurationError, McpUnsupportedError, McpTransportUnsupportedError
        raise
      rescue => e
        handle_error(e, prompt: prompt, options: options)
      end

      def plan_execution(prompt:, **options)
        log_debug("plan_execution_start", prompt_length: prompt.length, options: options.keys)

        options = normalize_provider_runtime(options)
        options = normalize_mcp_servers(options)
        validate_mcp_servers!(options[:mcp_servers]) if options[:mcp_servers]&.any?

        runtime = options[:provider_runtime]
        cmd = [self.class.binary_name, "-p"]
        cmd.concat(runtime.flags) if runtime&.flags&.any?

        {
          command: cmd,
          env: build_env(options),
          preparation: build_execution_preparation(options)
        }
      rescue McpConfigurationError, McpUnsupportedError, McpTransportUnsupportedError
        raise
      rescue => e
        handle_error(e, prompt: prompt, options: options)
      end

      protected

      def build_command(prompt, options)
        # Use -p mode (designed for non-interactive/script use)
        [self.class.binary_name, "-p"]
      end

      def build_env(options)
        super
      end

      def default_timeout
        300
      end

      private

      def fetch_mcp_servers_cli
        return nil unless self.class.available?

        begin
          result = @executor.execute([self.class.binary_name, "mcp", "list"], timeout: 5)
          return nil unless result.success?

          parse_mcp_servers_output(result.stdout)
        rescue
          nil
        end
      end

      def fetch_mcp_servers_config
        cursor_config_path = File.expand_path("~/.cursor/mcp.json")
        return [] unless File.exist?(cursor_config_path)

        begin
          config = JSON.parse(File.read(cursor_config_path))
          servers = []
          mcp_servers = config["mcpServers"] || {}

          mcp_servers.each do |name, server_config|
            command_parts = [server_config["command"]]
            command_parts.concat(server_config["args"]) if server_config["args"]
            command_description = command_parts.join(" ")

            servers << {
              name: name,
              status: "configured",
              description: command_description,
              enabled: true,
              source: "cursor_config"
            }
          end

          servers
        rescue
          []
        end
      end

      def parse_mcp_servers_output(output)
        servers = []
        return servers unless output

        output.lines.each do |line|
          line = line.strip
          next if line.empty?

          if line =~ /^([^:]+):\s*(.+)$/
            name = Regexp.last_match(1).strip
            status = Regexp.last_match(2).strip

            servers << {
              name: name,
              status: status,
              enabled: status == "ready" || status == "connected",
              source: "cursor_cli"
            }
          end
        end

        servers
      end

      def log_debug(action, **context)
        @logger&.debug("[AgentHarness::Cursor] #{action}: #{context.inspect}")
      end

      def track_tokens(response)
        # Cursor doesn't provide token info, so this is a no-op
      end

      def handle_error(error, prompt:, options:)
        classification = ErrorTaxonomy.classify(error, error_patterns)

        log_error("send_message_error",
          error: error.class.name,
          message: error.message,
          classification: classification)

        case classification
        when :rate_limited
          raise RateLimitError.new(error.message, original_error: error)
        when :auth_expired
          raise AuthenticationError.new(error.message, provider: self.class.provider_name, original_error: error)
        when :timeout
          raise error if error.is_a?(TimeoutError)

          raise TimeoutError.new(error.message, original_error: error)
        when :idle_timeout
          raise error if error.is_a?(IdleTimeoutError)

          raise IdleTimeoutError.new(error.message, original_error: error)
        else
          raise ProviderError.new(error.message, original_error: error)
        end
      end

      def log_error(action, **context)
        @logger&.error("[AgentHarness::Cursor] #{action}: #{context.inspect}")
      end
    end
  end
end
