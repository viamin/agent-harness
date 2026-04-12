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
        error = nil
        tokens = nil

        if result.failed?
          combined = [result.stdout, result.stderr]
            .map { |s| s.to_s.strip }
            .reject(&:empty?)
            .join("\n")
          error = combined unless combined.empty?
        end

        parsed = parse_json_output(output)
        if parsed
          output = parsed["result"] || parsed["text"] || output
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
    end
  end
end
