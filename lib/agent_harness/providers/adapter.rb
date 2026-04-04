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

        # Installation contract for the provider CLI.
        #
        # Downstream apps can use this metadata to build container images
        # without duplicating package names, binary names, or supported
        # version pins outside agent-harness.
        #
        # @return [Hash, nil] installation metadata or nil when the provider
        #   does not expose a first-class install contract
        def installation_contract
          nil
        end

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
