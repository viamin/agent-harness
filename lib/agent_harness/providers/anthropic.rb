# frozen_string_literal: true

require "json"

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

      class << self
        def provider_name
          :claude
        end

        def binary_name
          "claude"
        end

        def available?
          executor = AgentHarness.configuration.command_executor
          !!executor.which(binary_name)
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

        private

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

      def supports_mcp?
        true
      end

      def supports_dangerous_mode?
        true
      end

      def dangerous_mode_flags
        ["--dangerously-skip-permissions"]
      end

      def error_patterns
        {
          rate_limited: [
            /rate.?limit/i,
            /too.?many.?requests/i,
            /429/,
            /overloaded/i,
            /session.?limit/i
          ],
          auth_expired: [
            /oauth.*token.*expired/i,
            /authentication.*error/i,
            /invalid.*api.*key/i,
            /unauthorized/i,
            /401/
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
            /503/,
            /502/,
            /504/
          ],
          permanent: [
            /invalid.*model/i,
            /unsupported.*operation/i,
            /not.*found/i,
            /404/,
            /bad.*request/i,
            /400/,
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

        cmd += ["--print", "--output-format=text"]

        # Add model if specified
        if @config.model && !@config.model.empty?
          cmd += ["--model", @config.model]
        end

        # Add dangerous mode if requested
        if options[:dangerous_mode] && supports_dangerous_mode?
          cmd += dangerous_mode_flags
        end

        # Add custom flags from config
        cmd += @config.default_flags if @config.default_flags&.any?

        cmd += ["--prompt", prompt]

        cmd
      end

      def parse_response(result, duration:)
        output = result.stdout
        error = nil

        if result.failed?
          combined = [result.stdout, result.stderr].compact.join("\n")
          error = classify_error_message(combined)
        end

        Response.new(
          output: output,
          exit_code: result.exit_code,
          duration: duration,
          provider: self.class.provider_name,
          model: @config.model,
          error: error
        )
      end

      def default_timeout
        300
      end

      private

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

      def log_debug(action, **context)
        @logger&.debug("[AgentHarness::Anthropic] #{action}: #{context.inspect}")
      end
    end
  end
end
