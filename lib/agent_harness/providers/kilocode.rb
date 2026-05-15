# frozen_string_literal: true

require "json"
require "shellwords"

module AgentHarness
  module Providers
    # Kilocode CLI provider
    #
    # Provides integration with the Kilocode CLI tool.
    class Kilocode < Base
      PACKAGE_NAME = "@kilocode/cli"
      DEFAULT_VERSION = "7.1.3"
      SUPPORTED_VERSION_REQUIREMENT = "= #{DEFAULT_VERSION}"
      STRUCTURED_EVENT_TYPES = %w[text error step_finish result usage].freeze
      USAGE_EVENT_TYPES = %w[result usage].freeze
      TOKEN_USAGE_KEYS = %w[
        input_tokens
        output_tokens
        total_tokens
        total
        reasoning_tokens
        cache_creation_input_tokens
        cache_read_input_tokens
        cache_write_input_tokens
      ].freeze

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

      def test_command_overrides
        ["--auto", "--print-logs"]
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

      def supports_activity_heartbeat?
        true
      end

      def heartbeat_integration(heartbeat_file_path:)
        unless heartbeat_file_path.is_a?(String) && !heartbeat_file_path.strip.empty?
          raise ArgumentError, "heartbeat_file_path must be a non-empty String"
        end
        unless heartbeat_file_path.start_with?("/")
          raise ArgumentError, "heartbeat_file_path must be an absolute path (got #{heartbeat_file_path.inspect})"
        end

        hook_script = heartbeat_hook_script(heartbeat_file_path)
        config_payload = merge_heartbeat_hooks(hook_script)

        preparation = ExecutionPreparation.new(
          file_writes: [
            {
              path: heartbeat_hook_config_path,
              content: JSON.pretty_generate(config_payload),
              mode: 0o600
            }
          ]
        )

        {
          supported: true,
          env: {"KILO_HEARTBEAT_FILE" => heartbeat_file_path},
          preparation: preparation,
          granularity: :tool_call
        }
      end

      def config_file_content(options = {})
        # Only use explicit provider_name or default to "openai".
        # api_provider is a generic backend label (e.g. "openrouter") that is not
        # a valid Kilo built-in provider ID, so we must not fall back to it here.
        provider_name = options[:provider_name] || "openai"
        model_id = options[:model_id]

        config = {provider: {provider_name => {}}}
        config[:model] = "#{provider_name}/#{model_id}" if model_id

        config.to_json
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
          parses_rate_limit_reset: true
        }
      end

      protected

      def build_command(prompt, options)
        cmd = [self.class.binary_name, "run", "--format", "json"]
        cmd.concat(test_command_overrides) if options[:smoke_test]
        cmd << prompt
        cmd
      end

      def parse_response(result, duration:)
        output = result.stdout
        tokens = nil
        structured_errors = []
        error = nil
        unstructured_output = nil

        if result.failed?
          combined = [result.stderr, result.stdout]
            .map { |s| s.to_s.strip }
            .reject(&:empty?)
            .join("\n")
          error = combined unless combined.empty?
        end

        text_parts = []
        accumulated_input = 0
        accumulated_output = 0
        accumulated_total = 0
        accumulated_extra_total = 0
        has_step_tokens = false
        result_usage = nil
        result_text = nil
        saw_structured_event = false

        each_json_event(output) do |event|
          next unless structured_event?(event)

          saw_structured_event = true
          part = event["part"]

          if event["type"] == "text"
            text = extract_text_chunk(event, part)
            text_parts << text if text.is_a?(String)
          end

          if event["type"] == "result"
            extracted_result_text = extract_terminal_result_text(event["result"]) ||
              extract_terminal_result_text(part) ||
              extract_terminal_result_text(event["text"]) ||
              extract_terminal_result_text(event["message"])
            result_text = extracted_result_text if extracted_result_text
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
                accumulated_extra_total += portable_step_extra_total(part_tokens, step_token_counts[:total])
                has_step_tokens = true
              end
            end
          end

          usage = event["usage"]
          if USAGE_EVENT_TYPES.include?(event["type"]) && usage.is_a?(Hash) && usage_has_token_data?(usage)
            result_usage = merge_usage_data(result_usage, usage)
          end
        end

        if saw_structured_event
          unstructured_output = extract_unstructured_output(result.stdout)
          joined_text = text_parts.join if text_parts.any?
          output = if joined_text && !joined_text.strip.empty?
            joined_text
          else
            result_text || unstructured_output
          end
          if result.failed? || structured_errors.any?
            error = build_structured_error(
              result,
              structured_errors,
              unstructured_output:
            )
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
        fallback_total_remainder = [accumulated_total - accumulated_input - accumulated_output - accumulated_extra_total, 0].max
        if result_usage
          tokens = resolve_token_counts(
            result_usage,
            fallback: step_tokens,
            fallback_extra_total: accumulated_extra_total,
            fallback_total_remainder:
          )
        end
        tokens ||= step_tokens

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

      def heartbeat_hook_script(heartbeat_file_path)
        "touch #{Shellwords.escape(heartbeat_file_path)}"
      end

      def heartbeat_hook_config_path
        "~/.config/kilocode/hooks.json"
      end

      def merge_heartbeat_hooks(hook_script)
        existing = load_existing_hooks_config(heartbeat_hook_config_path)
        hooks = existing.fetch("hooks", {})
        on_activity = hooks.fetch("on_activity", [])
        on_activity = on_activity.dup
        on_activity << {"command" => hook_script}
        existing.merge("hooks" => hooks.merge("on_activity" => on_activity))
      end

      def load_existing_hooks_config(path)
        expanded = File.expand_path(path)
        return {} unless File.exist?(expanded)

        JSON.parse(File.read(expanded))
      rescue JSON::ParserError
        {}
      end

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

      def resolve_token_counts(usage, fallback: nil, fallback_extra_total: 0, fallback_total_remainder: 0)
        input = coerce_token_count(usage["input_tokens"])
        output = coerce_token_count(usage["output_tokens"])
        explicit_total = extract_explicit_total_token_count(usage)
        usage_extra_total = usage_extra_token_total(usage)

        input_from_fallback = input.nil? && fallback && !fallback[:input].nil?
        output_from_fallback = output.nil? && fallback && !fallback[:output].nil?
        fallback_total = fallback[:total] if fallback
        input = fallback[:input] if input_from_fallback
        output = fallback[:output] if output_from_fallback
        return nil unless input || output || explicit_total || usage_extra_total || fallback_total

        input ||= 0
        output ||= 0

        total = if explicit_total
          explicit_total
        elsif usage_extra_total
          resolved_total = input + output + usage_extra_total
          if (input_from_fallback || output_from_fallback) && fallback_total_remainder.positive?
            [resolved_total, fallback_total].compact.max
          else
            resolved_total
          end
        elsif input_from_fallback || output_from_fallback
          resolved_total = input + output + fallback_extra_total
          fallback_total_remainder.positive? ? [resolved_total, fallback_total].compact.max : resolved_total
        else
          input + output
        end

        {input: input, output: output, total: total}
      end

      def usage_has_token_data?(usage)
        input = coerce_token_count(usage["input_tokens"])
        output = coerce_token_count(usage["output_tokens"])
        explicit_total = extract_explicit_total_token_count(usage)
        usage_extra_total = usage_extra_token_total(usage)

        input || output || explicit_total || usage_extra_total
      end

      def merge_usage_data(previous_usage, current_usage)
        return current_usage if previous_usage.nil?

        merged_usage = previous_usage.slice(*TOKEN_USAGE_KEYS)
        if usage_updates_explicit_total?(current_usage)
          merged_usage.delete("total_tokens")
          merged_usage.delete("total")
        end

        if usage_replaces_extra_fields?(current_usage)
          merged_usage.delete("reasoning_tokens")
          merged_usage.delete("cache_creation_input_tokens")
          merged_usage.delete("cache_read_input_tokens")
          merged_usage.delete("cache_write_input_tokens")
        end

        merged_usage.merge!(
          current_usage.slice(*TOKEN_USAGE_KEYS).select { |key, value| usable_usage_token_field?(key, value) }
        )

        if usage_updates_non_total_fields?(current_usage) && !usage_updates_explicit_total?(current_usage)
          merged_usage.delete("total_tokens")
          merged_usage.delete("total")
        end

        merged_usage
      end

      def usable_usage_token_field?(key, value)
        case key
        when "input_tokens", "output_tokens", "total_tokens", "total", "reasoning_tokens",
          "cache_creation_input_tokens", "cache_read_input_tokens", "cache_write_input_tokens"
          !coerce_token_count(value).nil?
        else
          false
        end
      end

      def usage_updates_non_total_fields?(usage)
        %w[
          input_tokens
          output_tokens
          reasoning_tokens
          cache_creation_input_tokens
          cache_read_input_tokens
          cache_write_input_tokens
        ].any? { |key| usable_usage_token_field?(key, usage[key]) }
      end

      def usage_updates_explicit_total?(usage)
        %w[total_tokens total].any? { |key| usable_usage_token_field?(key, usage[key]) }
      end

      def usage_replaces_extra_fields?(usage)
        usable_usage_token_field?("input_tokens", usage["input_tokens"]) &&
          usable_usage_token_field?("output_tokens", usage["output_tokens"])
      end

      def extract_error_message(event)
        error_payload = event["error"]
        part = event["part"]
        part_error_payload = part["error"] if part.is_a?(Hash)
        candidates = [
          extract_result_text(event["message"]),
          extract_result_text(event["text"]),
          extract_result_text(error_payload),
          extract_result_text(error_payload.is_a?(Hash) ? error_payload["message"] : nil),
          extract_result_text(error_payload.is_a?(Hash) ? error_payload["data"] : nil),
          extract_result_text(part_error_payload),
          extract_result_text(part_error_payload.is_a?(Hash) ? part_error_payload["message"] : nil),
          extract_result_text(part_error_payload.is_a?(Hash) ? part_error_payload["data"] : nil),
          extract_result_text(part.is_a?(Hash) ? nil : part),
          extract_result_text(part.is_a?(Hash) ? part["text"] : nil),
          extract_result_text(part.is_a?(Hash) ? part["message"] : nil)
        ]

        message = candidates.find { |value| value }
        return message if message

        JSON.generate(event)
      end

      def extract_result_text(payload)
        case payload
        when String
          return if payload.strip.empty?

          payload.strip
        when Hash
          extract_result_text(payload["text"]) || extract_result_text(payload["message"])
        end
      end

      def extract_terminal_result_text(payload)
        if payload.is_a?(String)
          return if payload.strip.empty?

          return payload
        end

        return unless payload.is_a?(Hash)

        text = extract_terminal_result_text(payload["text"])
        return text if text.is_a?(String) && !text.strip.empty?

        extract_terminal_result_text(payload["message"]) || text
      end

      def extract_text_chunk(event, part)
        scalar_part_chunk = extract_text_alias_chunk(part.is_a?(String) ? part : nil)
        return scalar_part_chunk if scalar_part_chunk.is_a?(String) && !scalar_part_chunk.strip.empty?

        part_text_chunk = extract_text_alias_chunk(part.is_a?(Hash) ? part["text"] : nil)
        return part_text_chunk if part_text_chunk.is_a?(String) && !part_text_chunk.strip.empty?

        part_message_chunk = extract_text_alias_chunk(part.is_a?(Hash) ? part["message"] : nil)
        return part_message_chunk if part_message_chunk.is_a?(String) && !part_message_chunk.strip.empty?

        text_chunk = extract_text_alias_chunk(event["text"])
        return text_chunk if text_chunk.is_a?(String) && !text_chunk.strip.empty?

        message_chunk = extract_text_alias_chunk(event["message"])
        return message_chunk if message_chunk.is_a?(String) && !message_chunk.strip.empty?

        scalar_part_chunk || part_text_chunk || part_message_chunk || text_chunk || message_chunk
      end

      def extract_text_alias_chunk(payload)
        if payload.is_a?(String)
          return if payload.empty?

          return payload
        end

        return unless payload.is_a?(Hash)

        text_chunk = extract_text_alias_chunk(payload["text"])
        return text_chunk if text_chunk.is_a?(String) && !text_chunk.strip.empty?

        extract_text_alias_chunk(payload["message"]) || text_chunk
      end

      def build_structured_error(result, structured_errors, unstructured_output:)
        stderr = result.stderr.to_s.strip
        error_lines = [stderr, *structured_errors, unstructured_output].compact.reject(&:empty?).uniq
        return error_lines.join("\n") if error_lines.any?

        return "Kilocode exited with code #{result.exit_code}" if result.failed?

        nil
      end

      def extract_unstructured_output(output)
        return if output.nil? || output.empty?

        lines = output.each_line.filter_map do |line|
          stripped_line = line.strip
          next if stripped_line.empty?

          parsed_line = JSON.parse(stripped_line)
          next if parsed_structured_event?(parsed_line)
          next if parsed_json_scalar?(parsed_line)

          line.chomp
        rescue JSON::ParserError
          line.chomp
        end

        lines.empty? ? nil : lines.join("\n")
      end

      def structured_event?(event)
        STRUCTURED_EVENT_TYPES.include?(event["type"])
      end

      def parsed_structured_event?(parsed_line)
        parsed_line.is_a?(Hash) && structured_event?(parsed_line)
      end

      def parsed_json_scalar?(parsed_line)
        !parsed_line.is_a?(Hash) && !parsed_line.is_a?(Array)
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
          return nil unless value.match?(/\A\d+\z/)

          return value.to_i
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

      def portable_step_extra_total(tokens, total)
        return 0 unless step_component_tokens_present?(tokens)

        input = coerce_token_count(tokens["input"]) || 0
        output = coerce_token_count(tokens["output"]) || 0

        [total - input - output, 0].max
      end

      def step_component_tokens_present?(tokens)
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

        counts.any?
      end

      def extract_explicit_total_token_count(usage)
        coerce_token_count(usage["total_tokens"]) || coerce_token_count(usage["total"])
      end

      def usage_extra_token_total(usage)
        counts = [
          coerce_token_count(usage["reasoning_tokens"]),
          coerce_token_count(usage["cache_creation_input_tokens"]),
          coerce_token_count(usage["cache_read_input_tokens"]),
          coerce_token_count(usage["cache_write_input_tokens"])
        ]

        counts.compact!
        return nil if counts.empty?

        counts.sum
      end
    end
  end
end
