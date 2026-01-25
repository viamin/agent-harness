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
      # @return [Response] response object with output and metadata
      def send_message(prompt:, **options)
        raise NotImplementedError, "#{self.class} must implement #send_message"
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
    end
  end
end
