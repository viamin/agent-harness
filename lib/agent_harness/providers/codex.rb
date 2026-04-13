# frozen_string_literal: true

require "json"

module AgentHarness
  module Providers
    # OpenAI Codex CLI provider
    #
    # Provides integration with the OpenAI Codex CLI tool.
    class Codex < Base
      SUPPORTED_CLI_VERSION = "0.116.0"
      SUPPORTED_CLI_REQUIREMENT = Gem::Requirement.new(">= #{SUPPORTED_CLI_VERSION}", "< 0.117.0").freeze
      OAUTH_REFRESH_FAILURE_PATTERNS = [
        /refresh_token_reused/i,
        /failed to refresh token\b.*\b401\b/im,
        /failed to refresh token\b.*unauthorized/im,
        /failed to refresh token\b.*\binvalid_client\b/im,
        /failed to refresh token\b.*\binvalid_grant\b/im,
        /failed to refresh token\b.*invalid.*refresh.*token/im,
        /failed to refresh token\b.*refresh.*token.*invalid/im,
        /your access token could not be refreshed because\b.*\b401\b/im,
        /your access token could not be refreshed because\b.*unauthorized/im,
        /your access token could not be refreshed because\b.*\binvalid_client\b/im,
        /your access token could not be refreshed because\b.*\binvalid_grant\b/im,
        /your access token could not be refreshed because\b.*invalid.*refresh.*token/im,
        /your access token could not be refreshed because\b.*refresh.*token.*invalid/im,
        /your access token could not be refreshed because\s+your refresh token .*already (?:been )?used/im,
        /refresh token .*already (?:been )?used/im
      ].freeze
      OAUTH_REFRESH_TRANSIENT_PATTERNS = [
        /your access token could not be refreshed because\s+(?:the\s+)?auth(?:entication)? service(?:\s+(?:is|was))?\s+(?:temporarily\s+)?unavailable/im,
        /your access token could not be refreshed because .*connection.*error/im,
        /failed to refresh token\b.*connection.*error/im,
        /failed to refresh token\b.*service(?:\s+(?:is|was))?\s+(?:temporarily\s+)?unavailable/im
      ].freeze

      class << self
        def provider_name
          :codex
        end

        def binary_name
          "codex"
        end

        def available?
          executor = AgentHarness.configuration.command_executor
          !!executor.which(binary_name)
        end

        def provider_metadata_overrides
          {
            auth: {
              service: :openai,
              api_family: :openai
            }
          }
        end

        def firewall_requirements
          {
            domains: [
              "api.openai.com",
              "openai.com"
            ],
            ip_ranges: []
          }
        end

        def instruction_file_paths
          [
            {
              path: "AGENTS.md",
              description: "OpenAI Codex agent instructions",
              symlink: false
            }
          ]
        end

        def discover_models
          return [] unless available?

          [
            {name: "codex", family: "codex", tier: "standard", provider: "codex"}
          ]
        end

        def installation_contract(version: SUPPORTED_CLI_VERSION)
          version = version.strip if version.respond_to?(:strip)

          unless version.is_a?(String) && !version.empty?
            raise ArgumentError,
              "Unsupported Codex CLI version #{version.inspect}; " \
              "supported versions must satisfy #{SUPPORTED_CLI_REQUIREMENT}"
          end

          parsed_version = begin
            Gem::Version.new(version)
          rescue ArgumentError
            raise ArgumentError,
              "Unsupported Codex CLI version #{version.inspect}; " \
              "supported versions must satisfy #{SUPPORTED_CLI_REQUIREMENT}"
          end

          unless SUPPORTED_CLI_REQUIREMENT.satisfied_by?(parsed_version)
            raise ArgumentError,
              "Unsupported Codex CLI version #{version.inspect}; " \
              "supported versions must satisfy #{SUPPORTED_CLI_REQUIREMENT}"
          end

          default_package = "@openai/codex@#{version}".freeze
          install_command_prefix = ["npm", "install", "-g", "--ignore-scripts"].freeze
          install_command = (install_command_prefix + [default_package]).freeze
          supported_versions = [version].freeze
          version_requirement = SUPPORTED_CLI_REQUIREMENT.requirements
            .map { |op, ver| "#{op} #{ver}".freeze }
            .freeze

          contract = {
            source: :npm,
            package: default_package,
            package_name: "@openai/codex",
            version: version,
            version_requirement: version_requirement,
            binary_name: binary_name,
            install_command_prefix: install_command_prefix,
            install_command: install_command,
            supported_versions: supported_versions
          }

          contract.each_value do |value|
            value.freeze if value.is_a?(String)
          end
          contract.freeze
        end

        def smoke_test_contract
          Base::DEFAULT_SMOKE_TEST_CONTRACT
        end
      end

      def name
        "codex"
      end

      def display_name
        "OpenAI Codex CLI"
      end

      def configuration_schema
        {
          fields: [],
          auth_modes: [:api_key],
          openai_compatible: true
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
        ["--full-auto"]
      end

      def execution_semantics
        {
          prompt_delivery: :arg,
          output_format: :json,
          sandbox_aware: true,
          uses_subcommand: true,
          non_interactive_flag: nil,
          legitimate_exit_codes: [0],
          stderr_is_diagnostic: true,
          parses_rate_limit_reset: false
        }
      end

      def supports_sessions?
        true
      end

      def session_flags(session_id)
        return [] unless session_id && !session_id.empty?
        ["--session", session_id]
      end

      def error_patterns
        {
          rate_limited: COMMON_ERROR_PATTERNS[:rate_limited],
          timeout: [
            /your access token could not be refreshed.*(?:timeout|timed.?out)/im,
            /failed to refresh token\b.*(?:timeout|timed.?out)/im
          ],
          transient: COMMON_ERROR_PATTERNS[:transient] + [
            /connection.*reset/i
          ] + OAUTH_REFRESH_TRANSIENT_PATTERNS,
          auth_expired: COMMON_ERROR_PATTERNS[:auth_expired] + [
            /\b401\b/,
            /incorrect.*api.*key/i
          ] + OAUTH_REFRESH_FAILURE_PATTERNS,
          quota_exceeded: COMMON_ERROR_PATTERNS[:quota_exceeded],
          sandbox_failure: [
            /bwrap.*no permissions/i,
            /no permissions to create a new namespace/i,
            /unprivileged.*namespace/i
          ]
        }
      end

      def auth_status
        api_key = ENV["OPENAI_API_KEY"]
        if api_key && !api_key.strip.empty?
          if api_key.strip.start_with?("sk-")
            return {valid: true, expires_at: nil, error: nil, auth_method: :api_key}
          else
            return {valid: false, expires_at: nil, error: "OPENAI_API_KEY is set but does not appear to be a valid OpenAI API key", auth_method: nil}
          end
        end

        credentials = read_codex_credentials
        if credentials
          key = credentials["api_key"] || credentials["apiKey"] || credentials["OPENAI_API_KEY"]
          if key.is_a?(String) && !key.strip.empty?
            if key.strip.start_with?("sk-")
              return {valid: true, expires_at: nil, error: nil, auth_method: :config_file}
            else
              return {valid: false, expires_at: nil, error: "Config file API key is set but does not appear to be a valid OpenAI API key", auth_method: nil}
            end
          end
        end

        {valid: false, expires_at: nil, error: "No OpenAI API key found. Set OPENAI_API_KEY or configure in #{codex_config_path}", auth_method: nil}
      rescue IOError, JSON::ParserError => e
        {valid: false, expires_at: nil, error: e.message, auth_method: nil}
      end

      def health_status
        unless self.class.available?
          return {healthy: false, message: "Codex CLI not found in PATH. Install from https://github.com/openai/codex"}
        end

        auth = auth_status
        unless auth[:valid]
          return {healthy: false, message: auth[:error]}
        end

        {healthy: true, message: "Codex CLI available and authenticated"}
      end

      def validate_config
        errors = []

        flags = @config.default_flags
        unless flags.nil?
          if flags.is_a?(Array)
            invalid = flags.reject { |f| f.is_a?(String) }
            errors << "default_flags contains non-string values" if invalid.any?
          else
            errors << "default_flags must be an array of strings"
          end
        end

        {valid: errors.empty?, errors: errors}
      end

      protected

      def parse_response(result, duration:)
        output = result.stdout
        error = nil
        tokens = nil
        legitimate = execution_semantics[:legitimate_exit_codes] || [0]

        unless legitimate.include?(result.exit_code)
          combined = [result.stderr, result.stdout]
            .map { |stream| stream.to_s.strip }
            .reject(&:empty?)
            .join("\n")
          error = combined unless combined.empty?
        end

        parsed = parse_jsonl_output(output)
        if parsed
          output = parsed[:text].nil? ? output : parsed[:text]
          tokens = parsed[:tokens]
        end

        response = Response.new(
          output: output,
          exit_code: result.exit_code,
          duration: duration,
          provider: self.class.provider_name,
          model: @config.model,
          tokens: tokens,
          metadata: {
            legitimate_exit_codes: legitimate
          },
          error: error
        )

        if response.success? && sandbox_failure_detected?(result.stderr)
          return Response.new(
            output: output,
            exit_code: 1,
            duration: duration,
            provider: self.class.provider_name,
            model: @config.model,
            tokens: tokens,
            metadata: {
              legitimate_exit_codes: legitimate
            },
            error: "Sandbox failure detected: #{result.stderr.strip}"
          )
        end

        response
      end

      def build_command(prompt, options)
        cmd = [self.class.binary_name, "exec", "--json"]
        externally_sandboxed = externally_sandboxed?(options)
        adding_full_auto = !externally_sandboxed && (sandboxed_environment? || options[:dangerous_mode])

        # When externally_sandboxed is set, use --dangerously-bypass-approvals-and-sandbox
        # instead of --full-auto. In the Codex CLI, full_auto is checked first and
        # selects workspace-write sandbox mode, which overrides the bypass flag.
        # Passing both would leave the run in the wrong sandbox mode.
        #
        # When NOT externally sandboxed: use --full-auto for Docker containers
        # (to skip nested sandboxing) or when dangerous_mode is explicitly requested.
        if adding_full_auto
          cmd += dangerous_mode_flags
        end

        flags = @config.default_flags
        if flags
          unless flags.is_a?(Array)
            raise ArgumentError, "Codex configuration error: default_flags must be an array of strings"
          end
          flags = normalize_sandbox_flags(
            flags,
            externally_sandboxed: externally_sandboxed,
            adding_full_auto: adding_full_auto
          )
          cmd += flags if flags.any?
        end

        if externally_sandboxed
          cmd += sandbox_bypass_flags
        end

        if options[:session]
          cmd += session_flags(options[:session])
        end

        runtime = options[:provider_runtime]
        if runtime
          cmd += ["--model", runtime.model] if runtime.model
          runtime_flags = normalize_sandbox_flags(
            runtime.flags,
            externally_sandboxed: externally_sandboxed,
            adding_full_auto: adding_full_auto
          )
          cmd += runtime_flags unless runtime_flags.empty?
        end

        cmd = dedupe_managed_sandbox_flags(cmd)
        cmd << prompt

        cmd
      end

      def build_env(options)
        env = super
        runtime = options[:provider_runtime]
        return env unless runtime

        env["OPENAI_BASE_URL"] = runtime.base_url if runtime.base_url
        env
      end

      def default_timeout
        300
      end

      private

      def parse_jsonl_output(raw_output)
        return nil if raw_output.nil? || raw_output.strip.empty?

        events = raw_output.lines.filter_map do |line|
          line = line.strip
          next if line.empty?
          JSON.parse(line)
        rescue JSON::ParserError
          nil
        end

        events.select! { |event| event.is_a?(Hash) }
        return nil if events.empty?

        latest_completed_parts = []
        current_turn_parts = []
        total_input = 0
        total_output = 0
        total_tokens = 0
        has_usage = false
        saw_assistant_output = false
        pending_turn_usage = nil
        pending_turn_usage_source = nil
        pending_wrapped_output_parts = nil
        turn_completed = false
        current_turn_finalized_output = false

        commit_pending_turn = lambda do
          next unless pending_turn_usage

          total_input += pending_turn_usage[:input]
          total_output += pending_turn_usage[:output]
          total_tokens += pending_turn_usage[:total]
          pending_turn_usage = nil
          pending_turn_usage_source = nil
          pending_wrapped_output_parts = nil
        end

        start_new_turn = lambda do
          next unless turn_completed

          commit_pending_turn.call
          turn_completed = false
          current_turn_finalized_output = false
        end

        start_new_finalized_turn = lambda do
          start_new_turn.call
        end

        start_new_streaming_turn = lambda do
          start_new_turn.call
          next unless pending_turn_usage_source == :wrapped && pending_turn_usage && current_turn_finalized_output

          latest_completed_parts = current_turn_parts.dup
          commit_pending_turn.call
          current_turn_parts = []
          current_turn_finalized_output = false
        end

        replace_current_turn_parts = lambda do |parts|
          next if parts.nil?

          current_turn_parts = parts
          saw_assistant_output = true
          current_turn_finalized_output = true
        end

        finalize_current_turn = lambda do
          latest_completed_parts = current_turn_parts.dup
          current_turn_parts = []
          turn_completed = true
          current_turn_finalized_output = false
        end

        finalize_pending_wrapped_turn = lambda do
          next unless pending_turn_usage_source == :wrapped && pending_turn_usage

          wrapped_output_parts = pending_wrapped_output_parts || current_turn_parts
          latest_completed_parts = wrapped_output_parts.dup
          current_turn_parts = [] if current_turn_parts.equal?(wrapped_output_parts)
          commit_pending_turn.call
          turn_completed = false
          current_turn_finalized_output = false
        end

        fail_current_turn = lambda do
          latest_completed_parts = []
          current_turn_parts = []
          turn_completed = true
          current_turn_finalized_output = false
        end

        events.each do |event|
          type = event["type"]

          case type
          when "message.delta"
            start_new_streaming_turn.call
            appended = append_delta_text(current_turn_parts, event["delta"])
            current_turn_finalized_output = false if appended
            saw_assistant_output ||= appended
          when "agent_message_delta"
            next unless wrapped_assistant_payload?(event)

            start_new_streaming_turn.call
            appended = append_wrapped_delta_text(current_turn_parts, event)
            current_turn_finalized_output = false if appended
            saw_assistant_output ||= appended
          when "agent_message"
            next unless wrapped_assistant_payload?(event)

            start_new_turn.call
            replace_current_turn_parts.call(extract_message_content_parts(event))
          when "item.completed"
            item = event["item"]
            next unless item.is_a?(Hash)
            next unless assistant_message_item?(item)

            start_new_finalized_turn.call
            replace_current_turn_parts.call(extract_message_content_parts(item))
          when "turn.completed"
            turn_usage = build_token_usage(event["usage"])
            result = event["result"]
            wrapped_completion_without_new_data =
              pending_turn_usage_source == :wrapped &&
              pending_turn_usage &&
              turn_usage.nil? &&
              !result.is_a?(String)

            if wrapped_completion_without_new_data
              if pending_wrapped_output_parts && !current_turn_parts.empty? && !current_turn_parts.equal?(pending_wrapped_output_parts)
                commit_pending_turn.call
                finalize_current_turn.call
                next
              end

              wrapped_output_parts = pending_wrapped_output_parts || current_turn_parts
              latest_completed_parts = wrapped_output_parts.dup
              current_turn_parts = [] if current_turn_parts.equal?(wrapped_output_parts)
              commit_pending_turn.call
              turn_completed = true
              current_turn_finalized_output = false
              next
            end

            # Wrapped streams can emit token_count before the matching top-level
            # turn.completed for the same turn; treat matching usage as a replacement.
            same_streaming_wrapped_turn =
              pending_turn_usage_source == :wrapped &&
              pending_wrapped_output_parts&.equal?(current_turn_parts) &&
              !current_turn_finalized_output
            same_wrapped_turn = pending_turn_usage_source == :wrapped &&
              same_turn_usage?(pending_turn_usage, turn_usage) &&
              (
                same_turn_output?(current_turn_parts, current_turn_finalized_output, result) ||
                same_streaming_wrapped_turn
              )

            finalize_pending_wrapped_turn.call unless same_wrapped_turn

            if turn_completed && !same_wrapped_turn
              commit_pending_turn.call
              turn_completed = false
            end

            if turn_usage
              has_usage = true
              turn_usage = merge_same_turn_usage(pending_turn_usage, turn_usage) if same_wrapped_turn
              pending_turn_usage = turn_usage
              pending_turn_usage_source = :turn_completed
            end

            if result.is_a?(String)
              current_turn_parts = [result]
              saw_assistant_output = true
              current_turn_finalized_output = true
            end

            finalize_current_turn.call
          when "turn.failed"
            turn_usage = build_token_usage(event["usage"])
            same_wrapped_turn = pending_turn_usage_source == :wrapped &&
              same_turn_usage?(pending_turn_usage, turn_usage)

            finalize_pending_wrapped_turn.call unless same_wrapped_turn

            if turn_completed && !same_wrapped_turn
              commit_pending_turn.call
              turn_completed = false
            end

            if turn_usage
              has_usage = true
              turn_usage = merge_same_turn_usage(pending_turn_usage, turn_usage) if same_wrapped_turn
              pending_turn_usage = turn_usage
              pending_turn_usage_source = :turn_completed
            end

            fail_current_turn.call
          when "event_msg"
            payload = event["payload"]
            next unless payload.is_a?(Hash)

            case payload["type"]
            when "agent_message_delta"
              next unless wrapped_assistant_payload?(payload)

              start_new_streaming_turn.call
              appended = append_wrapped_delta_text(current_turn_parts, payload)
              current_turn_finalized_output = false if appended
              saw_assistant_output ||= appended
            when "agent_message"
              next unless wrapped_assistant_payload?(payload)

              start_new_turn.call
              replace_current_turn_parts.call(extract_message_content_parts(payload))
            when "token_count"
              wrapped_token_usage = extract_wrapped_tokens(payload["info"])
              if wrapped_token_usage
                has_usage = true
                if wrapped_token_usage_starts_new_turn?(pending_turn_usage, pending_turn_usage_source, turn_completed, wrapped_token_usage)
                  commit_pending_turn.call
                  turn_completed = false
                end
                pending_turn_usage, pending_turn_usage_source = merge_wrapped_turn_usage(
                  pending_turn_usage,
                  pending_turn_usage_source,
                  wrapped_token_usage
                )
                pending_wrapped_output_parts =
                  (pending_turn_usage_source == :wrapped) ? current_turn_parts : nil
              end
            end
          when "response_item"
            payload = event["payload"]
            next unless payload.is_a?(Hash) && response_item_assistant_payload?(payload)

            start_new_finalized_turn.call
            replace_current_turn_parts.call(extract_message_content_parts(payload))
          end
        end

        commit_pending_turn.call
        final_parts = current_turn_parts.empty? ? latest_completed_parts : current_turn_parts
        text = if final_parts.empty?
          (turn_completed && saw_assistant_output) ? "" : nil
        else
          final_parts.join
        end

        {
          text: text,
          tokens: has_usage ? {
            input: total_input,
            output: total_output,
            total: total_tokens
          } : nil
        }
      rescue
        nil
      end

      def append_delta_text(parts, delta)
        return false unless delta.is_a?(Hash)

        delta_parts = extract_delta_content_parts(delta)
        return false if delta_parts.nil?

        appended = false
        delta_parts.each do |part|
          next if part.empty?

          parts << part
          appended = true
        end

        appended
      end

      def append_wrapped_delta_text(parts, payload)
        delta_parts = extract_wrapped_delta_parts(payload)
        return false if delta_parts.nil?

        appended = false
        delta_parts.each do |part|
          next if part.empty?

          parts << part
          appended = true
        end

        appended
      end

      def assistant_message_item?(item)
        item_role = item["role"]
        item_type = item["type"]
        item_item_type = item["item_type"]
        message_shaped_item =
          (
            message_item_type?(item_type) ||
            item_type == "agent_message"
          ) && assistant_message_item_type?(item_item_type)

        (
          item_role == "assistant" && message_shaped_item
        ) || (
          item_role.nil? && message_shaped_item && (
            item_type == "agent_message" ||
            item_item_type == "assistant_message"
          )
        )
      end

      def wrapped_assistant_payload?(payload)
        role = payload["role"]
        item_type = payload["item_type"]

        assistant_message_item_type?(item_type) &&
          (role == "assistant" || role.nil?)
      end

      def response_item_assistant_payload?(payload)
        payload_type = payload["type"]
        payload_role = payload["role"]
        payload_item_type = payload["item_type"]

        return false unless assistant_message_item_type?(payload_item_type)

        (payload_type == "message" && payload_role == "assistant") ||
          (payload_type == "agent_message" && (
            payload_role == "assistant" ||
            (payload_role.nil? && assistant_message_item_type?(payload_item_type))
          )) ||
          (
            payload_role.nil? &&
            message_item_type?(payload_type) &&
            payload_item_type == "assistant_message"
          )
      end

      def assistant_message_item_type?(item_type)
        item_type.nil? || item_type == "assistant_message"
      end

      def message_item_type?(item_type)
        item_type.nil? || item_type == "message"
      end

      def extract_message_content_parts(item)
        item_text = item["text"]
        return [item_text] if item_text.is_a?(String) && !item_text.empty?

        item_message = item["message"]
        return [item_message] if item_message.is_a?(String) && !item_message.empty?

        if item_text.is_a?(String)
          return extract_fallback_content_parts(item, item_text)
        end

        if item_message.is_a?(String)
          return extract_fallback_content_parts(item, item_message)
        end

        item_content = item["content"]
        return nil unless item_content.is_a?(Array)

        extract_content_parts(item_content)
      end

      def extract_fallback_content_parts(item, empty_value)
        item_content = item["content"]
        return [empty_value] unless item_content.is_a?(Array)

        content_parts = extract_content_parts(item_content)
        content_parts.nil? ? [empty_value] : content_parts
      end

      def extract_wrapped_delta_parts(payload)
        delta = payload["delta"]
        if delta.is_a?(Hash)
          delta_parts = extract_delta_content_parts(delta)
          return delta_parts unless delta_parts.nil?
        end

        extract_delta_content_parts(payload)
      end

      def extract_delta_content_parts(item)
        direct_parts = extract_message_content_parts(item)
        return direct_parts unless direct_parts == [""]

        item_content = item["content"]
        return direct_parts unless item_content.is_a?(Array)

        content_parts = extract_content_parts(item_content)
        content_parts.nil? ? direct_parts : content_parts
      end

      def output_text_block?(block)
        block_type = block["type"]

        block_type.nil? || block_type == "output_text"
      end

      def extract_content_parts(item_content)
        completed_parts = []
        extracted_content = false

        item_content.each do |block|
          next unless block.is_a?(Hash)
          next unless output_text_block?(block)

          block_text = block["text"]
          next unless block_text.is_a?(String)

          extracted_content = true
          completed_parts << block_text
        end

        extracted_content ? completed_parts : nil
      end

      def extract_wrapped_tokens(info)
        return unless info.is_a?(Hash)

        last_usage = build_token_usage(info["last_token_usage"])
        total_usage = build_token_usage(info["total_token_usage"])

        return unless last_usage || total_usage

        {last: last_usage, total: total_usage}
      end

      def token_usage_fields_present?(usage)
        usage.is_a?(Hash) && (
          !parse_token_count(usage["input_tokens"]).nil? ||
          !parse_token_count(usage["output_tokens"]).nil? ||
          !parse_token_count(usage["total_tokens"]).nil?
        )
      end

      def build_token_usage(usage)
        return unless token_usage_fields_present?(usage)

        input_value = parse_token_count(usage["input_tokens"])
        output_value = parse_token_count(usage["output_tokens"])
        total_value = parse_token_count(usage["total_tokens"])

        input = input_value || 0
        output = output_value || 0
        total = total_value
        total ||= (input + output)

        {
          input: input,
          output: output,
          total: total,
          input_reported: !input_value.nil?,
          output_reported: !output_value.nil?,
          total_reported: !total_value.nil?
        }
      end

      def merge_wrapped_turn_usage(existing_usage, existing_source, wrapped_token_usage)
        total_usage = wrapped_token_usage[:total]
        last_usage = wrapped_token_usage[:last]

        if existing_source == :turn_completed
          replacement_usage = merged_wrapped_usage(existing_usage, existing_source, last_usage, total_usage)
          return [existing_usage, existing_source] unless replacement_usage

          return [merge_same_turn_usage(existing_usage, replacement_usage), :turn_completed]
        end

        merged_usage = merged_wrapped_usage(existing_usage, existing_source, last_usage, total_usage)
        [merged_usage, :wrapped]
      end

      def merged_wrapped_usage(existing_usage, existing_source, last_usage, total_usage)
        if last_usage
          replacement_usage = last_usage
          if total_usage && same_turn_usage?(replacement_usage, total_usage)
            replacement_usage = merge_same_turn_usage(replacement_usage, total_usage)
          end

          return replacement_usage unless existing_source == :wrapped && existing_usage

          merged_usage = add_token_usage(existing_usage, last_usage)
          if total_usage && same_turn_usage?(merged_usage, total_usage)
            return merge_same_turn_usage(merged_usage, total_usage)
          end

          return replacement_usage if total_usage && same_turn_usage?(last_usage, total_usage)

          return merged_usage
        end

        total_usage
      end

      def wrapped_token_usage_starts_new_turn?(existing_usage, existing_source, turn_completed, wrapped_token_usage)
        return false unless turn_completed && existing_source == :turn_completed && existing_usage

        candidate_usage = wrapped_token_usage[:total] || wrapped_token_usage[:last]
        return false unless candidate_usage

        return false if same_turn_usage?(existing_usage, candidate_usage)

        existing_detailed = existing_usage[:input_reported] && existing_usage[:output_reported]
        candidate_detailed = candidate_usage[:input_reported] && candidate_usage[:output_reported]

        existing_detailed && candidate_detailed
      end

      def add_token_usage(left, right)
        {
          input: left[:input] + right[:input],
          output: left[:output] + right[:output],
          total: left[:total] + right[:total],
          input_reported: left[:input_reported] || right[:input_reported],
          output_reported: left[:output_reported] || right[:output_reported],
          total_reported: left[:total_reported] || right[:total_reported]
        }
      end

      def merge_same_turn_usage(left, right)
        return right unless left
        return left unless right

        merged_input_reported = left[:input_reported] || right[:input_reported]
        merged_output_reported = left[:output_reported] || right[:output_reported]
        merged_total_reported = left[:total_reported] || right[:total_reported]

        input = if right[:input_reported]
          right[:input]
        elsif left[:input_reported]
          left[:input]
        else
          0
        end

        output = if right[:output_reported]
          right[:output]
        elsif left[:output_reported]
          left[:output]
        else
          0
        end

        total = if right[:total_reported]
          right[:total]
        elsif left[:total_reported]
          left[:total]
        else
          input + output
        end

        {
          input: input,
          output: output,
          total: total,
          input_reported: merged_input_reported,
          output_reported: merged_output_reported,
          total_reported: merged_total_reported
        }
      end

      def same_turn_usage?(left, right)
        return false unless left && right

        detailed_usage_matches = left[:input_reported] &&
          right[:input_reported] &&
          left[:output_reported] &&
          right[:output_reported]
        return left[:input] == right[:input] && left[:output] == right[:output] if detailed_usage_matches

        mixed_total_match = (
          left[:input_reported] &&
          left[:output_reported] &&
          right[:total_reported]
        ) || (
          right[:input_reported] &&
          right[:output_reported] &&
          left[:total_reported]
        )
        return left[:total] == right[:total] if mixed_total_match

        left[:total_reported] && right[:total_reported] && left[:total] == right[:total]
      end

      def same_turn_output?(current_turn_parts, current_turn_finalized_output, result)
        return true if current_turn_parts.empty?
        return false unless current_turn_finalized_output
        return true unless result.is_a?(String)

        current_turn_parts.join == result
      end

      def parse_token_count(value)
        case value
        when Integer
          value
        when String
          stripped = value.strip
          return nil unless /\A\d+\z/.match?(stripped)

          stripped.to_i
        end
      end

      def normalize_sandbox_flags(flags, externally_sandboxed:, adding_full_auto:)
        normalized_flags = flags.dup
        explicit_full_auto_requested = (normalized_flags & dangerous_mode_flags).any?
        normalized_flags -= dangerous_mode_flags if externally_sandboxed || adding_full_auto
        full_auto_requested = adding_full_auto || explicit_full_auto_requested
        normalized_flags -= sandbox_bypass_flags if externally_sandboxed || full_auto_requested
        normalized_flags
      end

      def dedupe_managed_sandbox_flags(command)
        managed_flags = (dangerous_mode_flags + sandbox_bypass_flags).each_with_object({}) do |flag, flags|
          flags[flag] = true
        end
        seen_flags = {}

        command.each_with_object([]) do |part, deduped_command|
          if managed_flags[part]
            next if seen_flags[part]

            seen_flags[part] = true
          end

          deduped_command << part
        end
      end

      def externally_sandboxed?(options)
        if options.key?(:externally_sandboxed)
          !!options[:externally_sandboxed]
        else
          !!@config.externally_sandboxed
        end
      end

      def sandbox_failure_detected?(stderr)
        return false if stderr.nil? || stderr.empty?

        error_patterns[:sandbox_failure].any? { |pattern| stderr.match?(pattern) }
      end

      def sandbox_bypass_flags
        ["--dangerously-bypass-approvals-and-sandbox"]
      end

      def read_codex_credentials
        path = codex_config_path
        return nil unless File.exist?(path)

        parsed = JSON.parse(File.read(path))
        return nil unless parsed.is_a?(Hash)

        parsed
      rescue Errno::ENOENT
        nil
      rescue Errno::EACCES => e
        raise IOError, "Permission denied reading Codex config at #{path}: #{e.message}"
      rescue JSON::ParserError
        raise JSON::ParserError, "Invalid JSON in Codex config at #{path}"
      end

      def codex_config_path
        config_dir = ENV["CODEX_CONFIG_DIR"] || File.expand_path("~/.codex")
        File.join(config_dir, "config.json")
      end
    end
  end
end
