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
      def self.normalize_metadata_installation(contract, provider_name:, binary_name:)
        return nil unless contract.is_a?(Hash)

        source = contract[:source]
        install_command = contract[:install_command]&.dup

        {
          provider: provider_name.to_sym,
          source_type: normalize_metadata_source_type(contract[:source_type] || source),
          package_name: metadata_package_name(contract, source),
          default_version: contract[:default_version] || contract[:version] || contract[:resolved_version],
          resolved_version: contract[:resolved_version] || contract[:version] || contract[:default_version],
          supported_version_requirement: normalize_metadata_version_requirement(
            contract[:supported_version_requirement] || contract[:version_requirement]
          ),
          binary_name: contract[:binary_name] || binary_name,
          install_command: install_command,
          install_command_string: contract[:install_command_string] || install_command&.join(" ")
        }
      end

      def self.normalize_metadata_source_type(source)
        return source[:type]&.to_sym if source.is_a?(Hash)

        source&.to_sym
      end

      def self.metadata_package_name(contract, source)
        return contract[:package_name] if contract[:package_name]
        return source[:package] if source.is_a?(Hash)

        package = contract[:package]
        return package unless package.is_a?(String)

        if package.split("@").first == ""
          package.split("@", 3).first(2).join("@")
        else
          package.split("@", 2).first
        end
      end

      def self.normalize_metadata_version_requirement(requirement)
        case requirement
        when nil
          nil
        when Array
          requirement.join(", ")
        else
          requirement.to_s
        end
      end

      def self.included(base)
        base.extend(ClassMethods)
      end

      # Class methods that all providers must implement
      module ClassMethods
        SUPPORTED_OAUTH_AUTH_STATUS_PROVIDERS = %i[anthropic claude].freeze
        IMMUTABLE_METADATA_OVERRIDE_KEYS = %i[provider canonical_provider aliases binary_name].freeze

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
        # @param requested_name [Symbol, String] provider identifier originally
        #   requested by the caller; used to prefer alias-keyed config when
        #   metadata construction is config-sensitive
        # @param canonical_name [Symbol, String] canonical registry identifier
        #   for this provider; used for the public stable metadata contract
        # @return [Hash] provider metadata
        def provider_metadata(aliases: [], refresh: false, requested_name: provider_name, canonical_name: provider_name)
          normalized_aliases = normalize_metadata_aliases(aliases, canonical_name: canonical_name)
          requested_provider_name = requested_name.to_sym
          canonical_provider_name = canonical_name.to_sym
          provider = metadata_provider_instance(
            requested_name: requested_provider_name,
            canonical_name: canonical_provider_name
          )
          configuration = deep_merge_metadata(
            default_configuration_schema,
            provider_metadata_hash(provider, :configuration_schema, default: {})
          )
          execution = deep_merge_metadata(
            default_execution_semantics,
            provider_metadata_hash(provider, :execution_semantics, default: {})
          )
          installation = Adapter.normalize_metadata_installation(
            installation_contract,
            provider_name: canonical_provider_name,
            binary_name: binary_name
          )
          supported_auth_modes = Array(configuration[:auth_modes]).map(&:to_sym)
          supports_registry_checks = !provider.nil?
          auth_check_supported = auth_status_available?(
            provider,
            requested_name: requested_provider_name,
            canonical_name: canonical_provider_name,
            refresh: refresh
          )
          provider_status_check = supports_registry_checks && overrides_instance_method?(:health_status)
          configuration_validation = supports_registry_checks && overrides_instance_method?(:validate_config)
          lightweight_checks = supports_registry_checks && !provider_status_check && !configuration_validation

          metadata = {
            provider: canonical_provider_name,
            canonical_provider: canonical_provider_name,
            aliases: normalized_aliases,
            display_name: provider_display_name(provider, canonical_name: canonical_provider_name),
            binary_name: binary_name,
            auth: {
              default_mode: metadata_default_auth_mode(provider, supported_modes: supported_auth_modes),
              supported_modes: supported_auth_modes,
              service: nil,
              api_family: nil
            },
            runtime: {
              interface: :cli,
              requires_cli: true,
              available: metadata_runtime_available(refresh: refresh),
              installable: !installation.nil?,
              installation: installation,
              prompt_delivery: execution[:prompt_delivery],
              output_format: execution[:output_format],
              sandbox_aware: execution[:sandbox_aware],
              uses_subcommand: execution[:uses_subcommand],
              supports_mcp: provider_metadata_value(provider, :supports_mcp?, default: default_supports_mcp),
              supported_mcp_transports: provider_metadata_value(
                provider,
                :supported_mcp_transports,
                default: default_supported_mcp_transports
              ),
              supports_sessions: provider_metadata_value(
                provider,
                :supports_sessions?,
                default: default_supports_sessions
              ),
              supports_dangerous_mode: provider_metadata_value(
                provider,
                :supports_dangerous_mode?,
                default: default_supports_dangerous_mode
              )
            },
            configuration: configuration,
            capabilities: deep_merge_metadata(
              default_capabilities,
              provider_metadata_hash(provider, :capabilities, default: {})
            ),
            health_check: {
              supports_registry_checks: supports_registry_checks,
              auth_check_supported: auth_check_supported,
              provider_status: provider_status_check,
              configuration_validation: configuration_validation,
              lightweight: lightweight_checks
            },
            identity: {
              bot_usernames: provider_bot_usernames(
                canonical_name: canonical_provider_name,
                aliases: normalized_aliases
              )
            }
          }

          deep_merge_metadata(metadata, sanitized_provider_metadata_overrides)
        end

        # Optional provider-specific metadata overrides for provider_metadata.
        #
        # @return [Hash]
        def provider_metadata_overrides
          {}
        end

        private

        def normalize_metadata_aliases(aliases, canonical_name: provider_name)
          canonical_provider_name = canonical_name.to_sym

          Array(aliases)
            .filter_map do |alias_name|
              normalized_alias = alias_name.to_s.strip
              next if normalized_alias.empty?

              normalized_alias.to_sym
            end
            .uniq
            .reject { |alias_name| alias_name == canonical_provider_name }
        end

        def provider_bot_usernames(canonical_name: provider_name, aliases: [])
          [canonical_name, *aliases]
            .filter_map do |identity|
              normalized_identity = identity.to_s.strip
              normalized_identity unless normalized_identity.empty?
            end
            .uniq
        end

        def metadata_provider_instance(requested_name: provider_name, canonical_name: provider_name)
          build_provider_instance(
            config: metadata_provider_config(requested_name, canonical_name: canonical_name),
            executor: AgentHarness.configuration.command_executor,
            logger: AgentHarness.logger
          )
        rescue => e
          AgentHarness.logger&.debug(
            "[AgentHarness::Providers::Adapter] Falling back to default metadata for #{provider_name}: #{e.class}"
          )
          nil
        end

        def safe_metadata_provider_instance(requested_name: provider_name, canonical_name: provider_name)
          build_provider_instance(
            config: metadata_provider_config(requested_name, canonical_name: canonical_name),
            executor: AgentHarness.configuration.command_executor,
            logger: AgentHarness.logger
          )
        rescue
          # Return nil without logging - caller is responsible for handling
          nil
        end

        def build_provider_instance(config: nil, executor: nil, logger: nil)
          unless metadata_initializer_compatible?
            raise ArgumentError, "#{provider_name} does not support safe provider construction"
          end

          new(**provider_instance_kwargs(config: config, executor: executor, logger: logger))
        end

        def provider_instance_kwargs(config: nil, executor: nil, logger: nil)
          parameters = instance_method(:initialize).parameters
          accepts = lambda do |name|
            parameters.any? { |type, param_name| [:key, :keyreq].include?(type) && param_name == name } ||
              parameters.any? { |type, _| type == :keyrest }
          end

          kwargs = {}
          kwargs[:config] = config if accepts.call(:config)
          kwargs[:executor] = executor if accepts.call(:executor)
          kwargs[:logger] = logger if accepts.call(:logger)

          kwargs
        end

        def metadata_provider_config(requested_name, canonical_name: provider_name)
          requested_provider_name = requested_name.to_sym
          canonical_provider_name = canonical_name.to_sym

          AgentHarness.configuration.providers[requested_provider_name] ||
            AgentHarness.configuration.providers[canonical_provider_name] ||
            AgentHarness.configuration.providers[provider_name] ||
            AgentHarness::ProviderConfig.new(requested_provider_name)
        end

        def metadata_initializer_compatible?
          keyword_names, required_keywords = initializer_keyword_parameters
          return false if instance_method(:initialize).parameters.any? { |type, _name| type == :req }
          return false unless (required_keywords - supported_initializer_keywords).empty?
          return true if instance_method(:initialize).parameters.any? { |type, _| type == :keyrest }

          (keyword_names - supported_initializer_keywords).empty?
        end

        # Check if this provider has auth_status support available for health checks
        #
        # This differs from supports_registry_checks - it specifically indicates whether
        # the auth status check will succeed or return "not implemented"
        def auth_status_available?(
          provider_instance = nil,
          requested_name: provider_name,
          canonical_name: provider_name,
          refresh: false
        )
          @auth_status_available = {} unless instance_variable_defined?(:@auth_status_available)
          cache_key = [requested_name.to_sym, canonical_name.to_sym]
          return @auth_status_available[cache_key] if !refresh && @auth_status_available.key?(cache_key)

          @auth_status_available[cache_key] = begin
            provider_instance ||= safe_metadata_provider_instance(
              requested_name: requested_name,
              canonical_name: canonical_name
            )
            auth_status_supported_by?(
              provider_instance,
              requested_name: requested_name,
              canonical_name: canonical_name
            )
          rescue
            false
          end
        end

        def auth_status_supported_by?(provider_instance, requested_name: provider_name, canonical_name: provider_name)
          return false unless provider_instance
          return true if provider_instance.respond_to?(:auth_status)

          case provider_instance.auth_type
          when :api_key
            false
          when :oauth
            provider_class_name = provider_instance.class.provider_name.to_sym if provider_instance.class.respond_to?(:provider_name)

            return false unless provider_class_name == :claude

            [requested_name, canonical_name]
              .map(&:to_sym)
              .any? { |name| SUPPORTED_OAUTH_AUTH_STATUS_PROVIDERS.include?(name) }
          else
            false
          end
        end

        def initializer_keyword_parameters
          parameters = instance_method(:initialize).parameters

          keyword_names = parameters
            .filter_map { |type, name| name if type == :key || type == :keyreq }
          required_keywords = parameters
            .filter_map { |type, name| name if type == :keyreq }

          [keyword_names, required_keywords]
        end

        def supported_initializer_keywords
          %i[config executor logger]
        end

        def metadata_runtime_available(refresh: false)
          if refresh || !instance_variable_defined?(:@metadata_runtime_available)
            @metadata_runtime_available = available?
          end

          @metadata_runtime_available
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

        def sanitized_provider_metadata_overrides
          overrides = provider_metadata_overrides
          return {} unless overrides.is_a?(Hash)

          overrides.each_with_object({}) do |(key, value), sanitized|
            next if immutable_metadata_override_key?(key)

            sanitized[key] = value
          end
        end

        def immutable_metadata_override_key?(key)
          IMMUTABLE_METADATA_OVERRIDE_KEYS.include?(key.to_sym)
        rescue NoMethodError
          false
        end

        def provider_metadata_hash(provider, method_name, default:)
          value = provider_metadata_value(provider, method_name, default: default)
          value.is_a?(Hash) ? value : default
        end

        def provider_metadata_value(provider, method_name, default:)
          return default unless provider

          provider.public_send(method_name)
        rescue => e
          AgentHarness.logger&.debug(
            "[AgentHarness::Providers::Adapter] Falling back to default #{method_name} metadata for #{provider_name}: #{e.class}"
          )
          default
        end

        def provider_display_name(provider, canonical_name: provider_name)
          if provider&.respond_to?(:display_name) &&
              provider.method(:display_name).owner != AgentHarness::Providers::Base
            return provider.display_name
          end

          canonical_name.to_s.split("_").map(&:capitalize).join(" ")
        end

        def metadata_default_auth_mode(provider, supported_modes:)
          provider_auth_type = provider&.auth_type&.to_sym
          return provider_auth_type if provider_auth_type && supported_modes.include?(provider_auth_type)
          return supported_modes.first unless supported_modes.empty?

          provider_auth_type
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
