# frozen_string_literal: true

require "json"

module AgentHarness
  module Providers
    # Kilocode CLI provider
    #
    # Provides integration with the Kilocode CLI tool.
    class Kilocode < Base
      PACKAGE_NAME = "@kilocode/cli"
      DEFAULT_VERSION = "7.1.3"
      SUPPORTED_VERSION_REQUIREMENT = "= #{DEFAULT_VERSION}"

      class << self
        def provider_name
          :kilocode
        end

        def binary_name
          "kilo"
        end

        def available?
          executor = AgentHarness.configuration.command_executor
          !!executor.which(binary_name)
        end

        def firewall_requirements
          {
            domains: [],
            ip_ranges: []
          }
        end

        def instruction_file_paths
          []
        end

        def discover_models
          return [] unless available?
          []
        end

        def installation_contract(version: DEFAULT_VERSION)
          version = version.strip if version.respond_to?(:strip)
          validate_install_version!(version)
          package_spec = "#{PACKAGE_NAME}@#{version}"

          {
            source: {
              type: :npm,
              package: PACKAGE_NAME
            },
            install_command: ["npm", "install", "-g", "--ignore-scripts", package_spec],
            binary_name: binary_name,
            default_version: DEFAULT_VERSION,
            supported_version_requirement: SUPPORTED_VERSION_REQUIREMENT
          }
        end

        def install_command(version: DEFAULT_VERSION)
          installation_contract(version: version)[:install_command]
        end

        def smoke_test_contract
          Base::DEFAULT_SMOKE_TEST_CONTRACT
        end

        private

        def validate_install_version!(version)
          unless version.is_a?(String) && !version.strip.empty?
            raise ArgumentError,
              "Unsupported Kilocode CLI version #{version.inspect}; " \
              "supported versions must satisfy #{SUPPORTED_VERSION_REQUIREMENT}"
          end

          parsed_version = begin
            Gem::Version.new(version)
          rescue ArgumentError
            raise ArgumentError,
              "Unsupported Kilocode CLI version #{version.inspect}; " \
              "supported versions must satisfy #{SUPPORTED_VERSION_REQUIREMENT}"
          end

          requirement = Gem::Requirement.new(SUPPORTED_VERSION_REQUIREMENT)
          return if requirement.satisfied_by?(parsed_version)

          raise ArgumentError,
            "Unsupported Kilocode CLI version #{version.inspect}; " \
            "supported versions must satisfy #{SUPPORTED_VERSION_REQUIREMENT}"
        end
      end

      def name
        "kilocode"
      end

      def display_name
        "Kilocode CLI"
      end

      def capabilities
        {
          streaming: false,
          file_upload: false,
          vision: false,
          tool_use: false,
          json_mode: false,
          mcp: false,
          dangerous_mode: false
        }
      end

      def error_patterns
        COMMON_ERROR_PATTERNS
      end

      def execution_semantics
        {
          prompt_delivery: :arg,
          output_format: :json,
          sandbox_aware: false,
          uses_subcommand: true,
          non_interactive_flag: nil,
          legitimate_exit_codes: [0],
          stderr_is_diagnostic: true,
          parses_rate_limit_reset: false
        }
      end

      protected

      def build_command(prompt, options)
        cmd = [self.class.binary_name, "run", "--format", "json"]
        cmd << prompt
        cmd
      end

      def parse_response(result, duration:)
        output = result.stdout
        tokens = nil
        structured_errors = []
        error = nil

        if result.failed?
          combined = [result.stdout, result.stderr]
            .map { |s| s.to_s.strip }
            .reject(&:empty?)
            .join("\n")
          error = combined unless combined.empty?
        end

        text_parts = []
        accumulated_input = 0
        accumulated_output = 0
        accumulated_total = 0
        has_step_tokens = false
        result_usage = nil
        saw_structured_event = false

        each_json_event(output) do |event|
          saw_structured_event = true
          part = event["part"]

          if event["type"] == "text"
            text = part["text"] if part.is_a?(Hash)
            text_parts << text if text.is_a?(String)
          end

          if event["type"] == "error"
            structured_error = extract_error_message(event)
            structured_errors << structured_error if structured_error
          end

          if event["type"] == "step_finish"
            part_tokens = part["tokens"] if part.is_a?(Hash)
            if part_tokens.is_a?(Hash)
              step_total = coerce_step_total_token_count(part_tokens)
              step_token_counts = build_token_counts({
                "input_tokens" => part_tokens["input"],
                "output_tokens" => part_tokens["output"],
                "total_tokens" => step_total
              })

              if step_token_counts
                accumulated_input += step_token_counts[:input]
                accumulated_output += step_token_counts[:output]
                accumulated_total += step_token_counts[:total]
                has_step_tokens = true
              end
            end
          end

          usage = event["usage"]
          result_usage = usage if usage.is_a?(Hash)
        end

        if saw_structured_event
          output = text_parts.empty? ? nil : text_parts.join
          if result.failed? || structured_errors.any?
            error = build_structured_error(result, structured_errors, fallback: error)
          end
        end
        step_tokens = nil
        if has_step_tokens
          step_tokens = build_token_counts({
            "input_tokens" => accumulated_input,
            "output_tokens" => accumulated_output,
            "total_tokens" => accumulated_total
          })
        end
        tokens = resolve_token_counts(result_usage, fallback: step_tokens) if result_usage
        tokens ||= step_tokens
        if structured_errors.any? && !saw_structured_event
          error_lines = [error, *structured_errors].compact.reject(&:empty?).uniq
          error = error_lines.join("\n")
        end

        Response.new(
          output: output,
          exit_code: result.exit_code,
          duration: duration,
          provider: self.class.provider_name,
          model: @config.model,
          tokens: tokens,
          error: error,
          metadata: {
            legitimate_exit_codes: execution_semantics[:legitimate_exit_codes]
          }
        )
      end

      def default_timeout
        300
      end

      private

      def each_json_event(output)
        return if output.nil? || output.empty?

        output.each_line do |line|
          line = line.strip
          next if line.empty?

          event = JSON.parse(line)
          next unless event.is_a?(Hash)

          yield event
        rescue JSON::ParserError
          next
        end
      end

      def build_token_counts(usage)
        input = coerce_token_count(usage["input_tokens"])
        output = coerce_token_count(usage["output_tokens"])
        total = coerce_total_token_count(usage, input:, output:)
        return nil unless input || output || total

        input ||= 0
        output ||= 0

        {input: input, output: output, total: total}
      end

      def resolve_token_counts(usage, fallback: nil)
        input = coerce_token_count(usage["input_tokens"])
        output = coerce_token_count(usage["output_tokens"])
        explicit_total = extract_explicit_total_token_count(usage)
        synthesized_total = synthesize_usage_total_token_count(usage, input:, output:)

        input = fallback[:input] if input.nil? && fallback
        output = fallback[:output] if output.nil? && fallback
        fallback_total = fallback[:total] if fallback
        return nil unless input || output || explicit_total || synthesized_total || fallback_total

        input ||= 0
        output ||= 0

        total = explicit_total || [synthesized_total, input + output, fallback_total].compact.max

        {input: input, output: output, total: total}
      end

      def extract_error_message(event)
        error_payload = event["error"]
        part = event["part"]
        candidates = [
          event["message"],
          error_payload,
          error_payload.is_a?(Hash) ? error_payload["message"] : nil,
          (error_payload.is_a?(Hash) && error_payload["data"].is_a?(Hash)) ? error_payload["data"]["message"] : nil,
          part.is_a?(Hash) ? part["text"] : nil,
          part.is_a?(Hash) ? part["message"] : nil
        ]

        message = candidates.find { |value| value.is_a?(String) && !value.strip.empty? }
        return message.strip if message

        JSON.generate(event)
      end

      def build_structured_error(result, structured_errors, fallback:)
        stderr = result.stderr.to_s.strip
        error_lines = [stderr, *structured_errors].compact.reject(&:empty?).uniq
        return error_lines.join("\n") if error_lines.any?

        return "Kilocode exited with code #{result.exit_code}" if result.failed?

        fallback
      end

      def coerce_token_count(value)
        if value.is_a?(Integer)
          return value if value >= 0

          return nil
        end

        if value.is_a?(Float) && value.finite?
          return nil unless value == value.to_i

          coerced = value.to_i
          return coerced if coerced >= 0

          return nil
        end

        return if value.nil?

        if value.is_a?(String)
          coerced = Integer(value, exception: false)
          return coerced if coerced && coerced >= 0
        end

        nil
      end

      def coerce_total_token_count(usage, input:, output:)
        explicit_total = extract_explicit_total_token_count(usage)
        return explicit_total if explicit_total
        return nil if input.nil? && output.nil?

        (input || 0) + (output || 0)
      end

      def coerce_step_total_token_count(tokens)
        explicit_total = extract_explicit_total_token_count(tokens)
        return explicit_total if explicit_total

        counts = [
          coerce_token_count(tokens["input"]),
          coerce_token_count(tokens["output"]),
          coerce_token_count(tokens["reasoning"])
        ]

        cache = tokens["cache"]
        if cache.is_a?(Hash)
          counts << coerce_token_count(cache["read"])
          counts << coerce_token_count(cache["write"])
        end

        counts.compact!
        return nil if counts.empty?

        counts.sum
      end

      def extract_explicit_total_token_count(usage)
        coerce_token_count(usage["total_tokens"]) || coerce_token_count(usage["total"])
      end

      def synthesize_usage_total_token_count(usage, input:, output:)
        return nil if input.nil? && output.nil?

        counts = [
          input,
          output,
          coerce_token_count(usage["reasoning_tokens"]),
          coerce_token_count(usage["cache_creation_input_tokens"]),
          coerce_token_count(usage["cache_read_input_tokens"]),
          coerce_token_count(usage["cache_write_input_tokens"])
        ]

        counts.compact.sum
      end
    end
  end
end
