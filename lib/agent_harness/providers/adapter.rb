# frozen_string_literal: true

module AgentHarness
  module Providers
    # Interface that all providers must implement
    #
    # This module defines the contract that provider implementations must follow.
    # Include this module in provider classes to ensure they implement the required interface.
    #
    # @example Implementing a provider
    #   class MyProvider < AgentHarness::Providers::Base
    #     include AgentHarness::Providers::Adapter
    #
    #     def self.provider_name
    #       :my_provider
    #     end
    #   end
    module Adapter
      def self.included(base)
        base.extend(ClassMethods)
      end

      # Class methods that all providers must implement
      module ClassMethods
        # Human-readable provider name
        #
        # @return [Symbol] unique identifier for this provider
        def provider_name
          raise NotImplementedError, "#{self} must implement .provider_name"
        end

        # Check if provider CLI is available on the system
        #
        # @return [Boolean] true if the CLI is installed and accessible
        def available?
          raise NotImplementedError, "#{self} must implement .available?"
        end

        # CLI binary name
        #
        # @return [String] the name of the CLI binary
        def binary_name
          raise NotImplementedError, "#{self} must implement .binary_name"
        end

        # Installation contract for the provider CLI.
        #
        # Downstream applications can use this metadata to install a provider's
        # supported CLI without hardcoding package names, install flags, or
        # version pins outside AgentHarness.
        #
        # @return [Hash, nil] installation metadata or nil when not provided
        def install_contract(version: nil)
          nil
        end

        # Required domains for firewall configuration
        #
        # @return [Hash] with :domains and :ip_ranges arrays
        def firewall_requirements
          {domains: [], ip_ranges: []}
        end

        # Paths to instruction files (e.g., CLAUDE.md, .cursorrules)
        #
        # @return [Array<Hash>] instruction file configurations
        def instruction_file_paths
          []
        end

        # Discover available models
        #
        # @return [Array<Hash>] list of available models
        def discover_models
          []
        end

        # Installation contract for this provider's CLI.
        #
        # Downstream apps can use this metadata to provision the provider CLI
        # without hardcoding package names, versions, or binary expectations
        # outside agent-harness.
        #
        # @return [Hash, nil] install metadata, or nil when no first-class
        #   installation contract is defined for the provider
        def installation_contract(**options)
          return install_contract unless options.key?(:version)

          install_contract(version: options[:version])
        end

        # Stable provider metadata for downstream configuration and policy UIs.
        #
        # This contract consolidates provider identifier aliases, auth/runtime
        # details, installability, and health-check characteristics so apps do
        # not need to maintain their own partial mirrors of adapter behavior.
        #
        # @param aliases [Array<Symbol, String>] alternate identifiers registered
        #   for this provider
        # @return [Hash] provider metadata
        def provider_metadata(aliases: [])
          normalized_aliases = aliases.map(&:to_sym)
          provider = metadata_provider_instance
          configuration = provider&.configuration_schema || default_configuration_schema
          execution = provider&.execution_semantics || default_execution_semantics
          installation = installation_contract
          supports_registry_checks = registry_check_initializer_compatible?
          provider_status_check = supports_registry_checks && overrides_instance_method?(:health_status)
          configuration_validation = supports_registry_checks && overrides_instance_method?(:validate_config)
          lightweight_checks = supports_registry_checks && !provider_status_check && !configuration_validation

          deep_merge_metadata(
            {
              provider: provider_name,
              canonical_provider: provider_name,
              aliases: normalized_aliases,
              display_name: provider_display_name(provider),
              binary_name: binary_name,
              auth: {
                default_mode: provider&.auth_type || default_auth_type,
                supported_modes: Array(configuration[:auth_modes]).map(&:to_sym),
                service: provider_name,
                api_family: configuration[:openai_compatible] ? :openai : provider_name
              },
              runtime: {
                interface: :cli,
                requires_cli: true,
                available: available?,
                installable: !installation.nil?,
                installation: installation,
                prompt_delivery: execution[:prompt_delivery],
                output_format: execution[:output_format],
                sandbox_aware: execution[:sandbox_aware],
                uses_subcommand: execution[:uses_subcommand],
                supports_mcp: provider&.supports_mcp? || default_supports_mcp,
                supported_mcp_transports: provider&.supported_mcp_transports || default_supported_mcp_transports,
                supports_sessions: provider&.supports_sessions? || default_supports_sessions,
                supports_dangerous_mode: provider&.supports_dangerous_mode? || default_supports_dangerous_mode
              },
              configuration: configuration,
              capabilities: provider&.capabilities || default_capabilities,
              health_check: {
                supports_registry_checks: supports_registry_checks,
                provider_status: provider_status_check,
                configuration_validation: configuration_validation,
                lightweight: lightweight_checks
              },
              identity: {
                bot_usernames: provider_bot_usernames(aliases: normalized_aliases)
              }
            },
            provider_metadata_overrides
          )
        end

        # Optional provider-specific metadata overrides for provider_metadata.
        #
        # @return [Hash]
        def provider_metadata_overrides
          {}
        end

        private

        def provider_bot_usernames(aliases: [])
          [provider_name, *aliases]
            .filter_map do |identity|
              normalized_identity = identity.to_s.strip
              normalized_identity unless normalized_identity.empty?
            end
            .uniq
        end

        def metadata_provider_instance
          return nil unless parameterless_initializer?

          new
        end

        def parameterless_initializer?
          instance_method(:initialize).parameters.none? do |type, _name|
            type == :req || type == :keyreq
          end
        end

        def registry_check_initializer_compatible?
          parameters = instance_method(:initialize).parameters
          return false if parameters.any? { |type, _name| type == :req }
          return true if parameters.any? { |type, _name| type == :keyrest }

          keyword_names = parameters
            .filter_map { |type, name| name if type == :key || type == :keyreq }

          supported_keywords = %i[config executor logger]
          required_keywords = parameters
            .filter_map { |type, name| name if type == :keyreq }

          return false unless (required_keywords - supported_keywords).empty?

          (supported_keywords - keyword_names).empty?
        end

        def overrides_instance_method?(method_name)
          instance_method(method_name).owner != AgentHarness::Providers::Adapter
        end

        def deep_merge_metadata(base, overrides)
          return base unless overrides.is_a?(Hash)

          base.merge(overrides) do |_key, left, right|
            if left.is_a?(Hash) && right.is_a?(Hash)
              deep_merge_metadata(left, right)
            else
              right
            end
          end
        end

        def provider_display_name(provider)
          return provider.display_name if provider.respond_to?(:display_name)

          provider_name.to_s.tr("_", " ").capitalize
        end

        def default_configuration_schema
          {
            fields: [],
            auth_modes: [default_auth_type],
            openai_compatible: false
          }
        end

        def default_execution_semantics
          {
            prompt_delivery: :arg,
            output_format: :text,
            sandbox_aware: false,
            uses_subcommand: false,
            non_interactive_flag: nil,
            legitimate_exit_codes: [0],
            stderr_is_diagnostic: true,
            parses_rate_limit_reset: false
          }
        end

        def default_auth_type
          :api_key
        end

        def default_capabilities
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

        def default_supports_mcp
          false
        end

        def default_supported_mcp_transports
          []
        end

        def default_supports_sessions
          false
        end

        def default_supports_dangerous_mode
          false
        end

        public

        # Build the install command from the provider installation contract.
        #
        # @param version [String, nil] optional explicit version override
        # @return [Array<String>, nil] install command argv or nil when the
        #   provider has no install contract
        def install_command(version: nil)
          contract = installation_contract
          return nil unless contract

          return contract[:install_command] unless version

          package_name = contract[:package_name]
          unless package_name
            raise ArgumentError, "installation_contract must define :package_name when overriding version"
          end

          Array(contract[:install_command_prefix]) + ["#{package_name}@#{version}"]
        end
      end

      # Instance methods

      # Send a message/prompt to the provider
      #
      # @param prompt [String] the prompt to send
      # @param options [Hash] provider-specific options
      # @option options [String] :model model to use
      # @option options [Integer] :timeout timeout in seconds
      # @option options [String] :session session identifier
      # @option options [Boolean] :dangerous_mode skip permission checks
      # @option options [ProviderRuntime, Hash, nil] :provider_runtime per-request
      #   runtime overrides (model, base_url, api_provider, env, flags, metadata).
      #   For providers that delegate to Providers::Base#send_message, a plain Hash
      #   is automatically coerced into a ProviderRuntime. Providers that override
      #   #send_message directly are responsible for handling this option.
      # @return [Response] response object with output and metadata
      def send_message(prompt:, **options)
        raise NotImplementedError, "#{self.class} must implement #send_message"
      end

      # Provider configuration schema for app-driven setup UIs
      #
      # Returns metadata describing the configurable fields, supported
      # authentication modes, and backend compatibility for this provider.
      # Applications use this to build generic provider-entry forms without
      # hardcoding provider-specific knowledge.
      #
      # @return [Hash] with :fields, :auth_modes, :openai_compatible keys
      def configuration_schema
        {
          fields: [],
          auth_modes: [auth_type],
          openai_compatible: false
        }
      end

      # Provider capabilities
      #
      # @return [Hash] capability flags
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

      # Error patterns for classification
      #
      # @return [Hash<Symbol, Array<Regexp>>] error patterns by category
      def error_patterns
        {}
      end

      # Authentication type for this provider
      #
      # @return [Symbol] :oauth for token-based auth that can expire,
      #   :api_key for static API key auth
      def auth_type
        :api_key
      end

      # Check if provider supports MCP
      #
      # @return [Boolean] true if MCP is supported
      def supports_mcp?
        capabilities[:mcp]
      end

      # Fetch configured MCP servers
      #
      # @return [Array<Hash>] MCP server configurations
      def fetch_mcp_servers
        []
      end

      # Supported MCP transport types for this provider
      #
      # @return [Array<String>] supported transports (e.g. ["stdio", "http"])
      def supported_mcp_transports
        []
      end

      # Build provider-specific MCP flags/arguments for CLI invocation
      #
      # @param mcp_servers [Array<McpServer>] MCP server definitions
      # @param working_dir [String, nil] working directory for temp files
      # @return [Array<String>] CLI flags to append to the command
      def build_mcp_flags(mcp_servers, working_dir: nil)
        []
      end

      # Validate that this provider can handle the given MCP servers
      #
      # @param mcp_servers [Array<McpServer>] MCP server definitions
      # @raise [McpUnsupportedError] if MCP is not supported
      # @raise [McpTransportUnsupportedError] if a transport is not supported
      def validate_mcp_servers!(mcp_servers)
        return if mcp_servers.nil? || mcp_servers.empty?

        unless supports_mcp?
          raise McpUnsupportedError.new(
            "Provider '#{self.class.provider_name}' does not support MCP servers",
            provider: self.class.provider_name
          )
        end

        supported = supported_mcp_transports

        if supported.empty?
          raise McpUnsupportedError.new(
            "Provider '#{self.class.provider_name}' does not support request-time MCP servers",
            provider: self.class.provider_name
          )
        end

        mcp_servers.each do |server|
          next if supported.include?(server.transport)

          raise McpTransportUnsupportedError.new(
            "Provider '#{self.class.provider_name}' does not support MCP transport " \
            "'#{server.transport}' (server: '#{server.name}'). " \
            "Supported transports: #{supported.join(", ")}",
            provider: self.class.provider_name
          )
        end
      end

      # Check if provider supports dangerous mode
      #
      # @return [Boolean] true if dangerous mode is supported
      def supports_dangerous_mode?
        capabilities[:dangerous_mode]
      end

      # Get dangerous mode flags
      #
      # @return [Array<String>] CLI flags for dangerous mode
      def dangerous_mode_flags
        []
      end

      # Check if provider supports session continuation
      #
      # @return [Boolean] true if sessions are supported
      def supports_sessions?
        false
      end

      # Get session flags for continuation
      #
      # @param session_id [String] the session ID
      # @return [Array<String>] CLI flags for session continuation
      def session_flags(session_id)
        []
      end

      # Validate provider configuration
      #
      # @return [Hash] with :valid, :errors keys
      def validate_config
        {valid: true, errors: []}
      end

      # Health check
      #
      # @return [Hash] with :healthy, :message keys
      def health_status
        {healthy: true, message: "OK"}
      end

      # Execution semantics for this provider
      #
      # Returns a hash describing provider-specific execution behavior so
      # downstream apps do not need to hardcode CLI quirks. This metadata
      # can be used to select the right flags and interpret output.
      #
      # @return [Hash] execution semantics
      def execution_semantics
        {
          prompt_delivery: :arg,       # :arg, :stdin, or :flag
          output_format: :text,        # :text or :json
          sandbox_aware: false,        # adjusts behavior inside containers
          uses_subcommand: false,      # e.g. "codex exec", "opencode run"
          non_interactive_flag: nil,   # flag to suppress interactive prompts
          legitimate_exit_codes: [0],  # exit codes that are NOT errors
          stderr_is_diagnostic: true,  # stderr may contain non-error output
          parses_rate_limit_reset: false # can extract Retry-After from output
        }
      end

      # Parse a rate-limit reset time from provider output
      #
      # Providers that include rate-limit reset information in their error
      # output can override this to extract it, so the orchestration layer
      # can schedule retries accurately.
      #
      # @param output [String] combined stdout+stderr from the CLI
      # @return [Time, nil] when the rate limit resets, or nil if unknown
      def parse_rate_limit_reset(output)
        nil
      end
    end
  end
end
