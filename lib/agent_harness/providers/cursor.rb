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
      end

      def name
        "cursor"
      end

      def display_name
        "Cursor AI"
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

      def fetch_mcp_servers
        # Try CLI first, then config file
        fetch_mcp_servers_cli || fetch_mcp_servers_config
      end

      def error_patterns
        {
          rate_limited: [
            /rate.?limit/i,
            /too.?many.?requests/i,
            /429/
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

        # Build command (without prompt in args - we send via stdin)
        command = [self.class.binary_name, "-p"]

        # Calculate timeout
        timeout = options[:timeout] || @config.timeout || default_timeout

        # Execute command with prompt on stdin
        start_time = Time.now
        result = @executor.execute(command, timeout: timeout, stdin_data: prompt)
        duration = Time.now - start_time

        # Parse response
        response = parse_response(result, duration: duration)

        # Track tokens
        track_tokens(response) if response.tokens

        log_debug("send_message_complete", duration: duration)

        response
      rescue => e
        handle_error(e, prompt: prompt, options: options)
      end

      protected

      def build_command(prompt, options)
        # Use -p mode (designed for non-interactive/script use)
        [self.class.binary_name, "-p"]
      end

      def build_env(options)
        {}
      end

      def default_timeout
        300
      end

      private

      def fetch_mcp_servers_cli
        return nil unless self.class.available?

        begin
          result = @executor.execute(["cursor-agent", "mcp", "list"], timeout: 5)
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
          raise AuthenticationError.new(error.message, original_error: error)
        when :timeout
          raise TimeoutError.new(error.message, original_error: error)
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
