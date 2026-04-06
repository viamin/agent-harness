# frozen_string_literal: true

require "singleton"

module AgentHarness
  module Providers
    # Registry for provider classes
    #
    # Manages registration and lookup of provider classes. Supports dynamic
    # registration of custom providers and aliasing of provider names.
    #
    # @example Registering a custom provider
    #   AgentHarness::Providers::Registry.instance.register(:my_provider, MyProviderClass)
    #
    # @example Looking up a provider
    #   klass = AgentHarness::Providers::Registry.instance.get(:claude)
    class Registry
      include Singleton

      BUILTIN_PROVIDER_DEFINITIONS = [
        {name: :claude, require_path: "agent_harness/providers/anthropic", class_name: :Anthropic, aliases: [:anthropic]},
        {name: :cursor, require_path: "agent_harness/providers/cursor", class_name: :Cursor, aliases: []},
        {name: :gemini, require_path: "agent_harness/providers/gemini", class_name: :Gemini, aliases: []},
        {
          name: :github_copilot,
          require_path: "agent_harness/providers/github_copilot",
          class_name: :GithubCopilot,
          aliases: [:copilot]
        },
        {name: :codex, require_path: "agent_harness/providers/codex", class_name: :Codex, aliases: []},
        {name: :opencode, require_path: "agent_harness/providers/opencode", class_name: :Opencode, aliases: []},
        {name: :kilocode, require_path: "agent_harness/providers/kilocode", class_name: :Kilocode, aliases: []},
        {name: :aider, require_path: "agent_harness/providers/aider", class_name: :Aider, aliases: []},
        {name: :mistral_vibe, require_path: "agent_harness/providers/mistral_vibe", class_name: :MistralVibe, aliases: []}
      ].freeze

      def initialize
        @providers = {}
        @aliases = {}
        @provider_aliases = Hash.new { |hash, key| hash[key] = [] }
        @metadata_runtime_available = {}
        @provider_metadata_cache = {}
        @provider_metadata_catalog_cache = nil
        @builtin_registered = false
      end

      # Register a provider class
      #
      # @param name [Symbol, String] the provider name
      # @param klass [Class] the provider class
      # @param aliases [Array<Symbol, String>] alternative names
      # @return [void]
      def register(name, klass, aliases: [])
        name = name.to_sym
        validate_provider_class!(klass)
        normalized_aliases = aliases
          .filter_map do |alias_name|
            normalized_alias = alias_name.to_s.strip
            next if normalized_alias.empty?

            normalized_alias.to_sym
          end
          .uniq - [name]

        validate_provider_name!(name)
        validate_aliases!(name, normalized_aliases)
        unregister_aliases_for(name)

        @providers[name] = klass
        @provider_aliases[name] = normalized_aliases
        @metadata_runtime_available.delete(name)
        clear_registry_metadata_cache!
        clear_metadata_caches!(klass)

        normalized_aliases.each do |alias_name|
          previous_owner = @aliases[alias_name]
          if previous_owner && previous_owner != name
            @provider_aliases[previous_owner] = @provider_aliases[previous_owner] - [alias_name]
          end

          @aliases[alias_name] = name
        end

        AgentHarness.logger&.debug("[AgentHarness::Registry] Registered provider: #{name}")
      end

      # Get provider class by name
      #
      # @param name [Symbol, String] the provider name
      # @return [Class] the provider class
      # @raise [ConfigurationError] if provider not found
      def get(name)
        ensure_builtin_providers_registered
        name = resolve_alias(name.to_sym)
        @providers[name] || raise(ConfigurationError, "Unknown provider: #{name}")
      end

      # Check if provider is registered
      #
      # @param name [Symbol, String] the provider name
      # @return [Boolean] true if registered
      def registered?(name)
        ensure_builtin_providers_registered
        name = resolve_alias(name.to_sym)
        @providers.key?(name)
      end

      # Resolve a provider lookup key to its canonical registered name.
      #
      # @param name [Symbol, String] the provider name or alias
      # @return [Symbol] canonical provider name
      def canonical_name(name)
        ensure_builtin_providers_registered
        resolve_alias(name.to_sym)
      end

      # List all registered provider names
      #
      # @return [Array<Symbol>] provider names
      def all
        ensure_builtin_providers_registered
        @providers.keys
      end

      # List available providers (CLI installed)
      #
      # @return [Array<Symbol>] available provider names
      def available
        ensure_builtin_providers_registered
        @providers.select { |_, klass| klass.available? }.keys
      end

      # Fetch installation metadata for a provider.
      #
      # @param name [Symbol, String] the provider name
      # @param options [Hash] optional target selection (for example, `version:`)
      # @return [Hash, nil] provider installation contract, or nil when the
      #   registered provider class does not define `.installation_contract`
      # @raise [ConfigurationError] if provider not found
      def installation_contract(name, **options)
        provider_class = get(name)
        return nil unless provider_class.respond_to?(:installation_contract)

        provider_class.installation_contract(**options)
      end

      # Get installation metadata for all providers that expose it.
      #
      # @return [Hash<Symbol, Hash>] installation contracts keyed by provider
      def installation_contracts
        ensure_builtin_providers_registered

        @providers.each_with_object({}) do |(name, klass), contracts|
          next unless klass.respond_to?(:installation_contract)

          contract = klass.installation_contract
          contracts[name] = contract if contract
        end
      end

      # Fetch consolidated provider metadata for a provider.
      #
      # @param name [Symbol, String] the provider name or alias
      # @return [Hash] provider metadata
      # @raise [ConfigurationError] if provider not found
      def provider_metadata(name, refresh: false)
        ensure_builtin_providers_registered

        requested_name = name.to_sym
        canonical_name = resolve_alias(requested_name)
        cache_key = [requested_name, canonical_name]

        return duplicate_metadata(@provider_metadata_cache[cache_key]) if !refresh && @provider_metadata_cache.key?(cache_key)

        refresh_provider_metadata_cache!(requested_name, canonical_name, refresh: refresh)
      end

      # Get consolidated metadata for all registered providers.
      #
      # @param refresh [Boolean] when true, refresh live runtime metadata such
      #   as CLI availability instead of reusing cached values
      # @return [Hash<Symbol, Hash>] provider metadata keyed by canonical provider
      def provider_metadata_catalog(refresh: false)
        ensure_builtin_providers_registered

        return duplicate_metadata(@provider_metadata_catalog_cache) if !refresh && @provider_metadata_catalog_cache

        if refresh
          clear_registry_metadata_cache!
          clear_all_auth_status_metadata_caches!
        end

        catalog = @providers.keys.each_with_object({}) do |name, result|
          result[name] = refresh_provider_metadata_cache!(
            name,
            name,
            refresh: refresh,
            invalidate_provider_cache: false,
            invalidate_catalog: false
          )
        end

        @provider_metadata_catalog_cache = duplicate_metadata(catalog)
        duplicate_metadata(catalog)
      end

      def reset!
        @providers.each_value { |klass| clear_metadata_caches!(klass) }
        @providers.clear
        @aliases.clear
        @provider_aliases.clear
        @metadata_runtime_available.clear
        clear_registry_metadata_cache!
        @builtin_registered = false
      end

      private

      def clear_registry_metadata_cache!
        @provider_metadata_cache.clear
        @provider_metadata_catalog_cache = nil
      end

      def invalidate_provider_metadata_cache!(canonical_name)
        @provider_metadata_cache.delete_if do |(_, cached_canonical_name), _|
          cached_canonical_name == canonical_name
        end
      end

      def duplicate_metadata(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, nested_value), copy|
            copy[key] = duplicate_metadata(nested_value)
          end
        when Array
          value.map { |nested_value| duplicate_metadata(nested_value) }
        when String
          value.dup
        else
          value
        end
      end

      def resolve_alias(name)
        @aliases[name] || name
      end

      def unregister_aliases_for(name)
        previous_aliases = @provider_aliases[name]
        return if previous_aliases.nil? || previous_aliases.empty?

        previous_aliases.each do |alias_name|
          @aliases.delete(alias_name)
        end
      end

      def clear_metadata_caches!(klass)
        clear_class_metadata_cache!(klass, :@metadata_runtime_available)
        clear_class_metadata_cache!(klass, :@auth_status_available)
      end

      def clear_all_auth_status_metadata_caches!
        @providers.each_value { |klass| clear_class_auth_status_metadata_cache!(klass) }
      end

      def clear_class_auth_status_metadata_cache!(klass, canonical_name = nil)
        return unless klass.instance_variable_defined?(:@auth_status_available)

        return clear_class_metadata_cache!(klass, :@auth_status_available) unless canonical_name

        auth_status_cache = klass.instance_variable_get(:@auth_status_available)
        auth_status_cache.delete_if do |(_requested_name, cached_canonical_name), _|
          cached_canonical_name == canonical_name
        end
      end

      def build_provider_metadata(requested_name, canonical_name, refresh:)
        klass = @providers[canonical_name] || raise(ConfigurationError, "Unknown provider: #{canonical_name}")
        aliases = @provider_aliases[canonical_name]

        if klass.respond_to?(:provider_metadata)
          klass.provider_metadata(
            aliases: aliases,
            refresh: refresh,
            requested_name: requested_name,
            canonical_name: canonical_name
          )
        else
          fallback_provider_metadata(canonical_name, klass, aliases, refresh: refresh)
        end
      end

      def refresh_provider_metadata_cache!(
        requested_name,
        canonical_name,
        refresh:,
        invalidate_provider_cache: refresh,
        invalidate_catalog: true
      )
        cache_key = [requested_name, canonical_name]
        invalidate_provider_metadata_cache!(canonical_name) if invalidate_provider_cache
        clear_class_auth_status_metadata_cache!(@providers[canonical_name], canonical_name) if refresh
        @provider_metadata_catalog_cache = nil if refresh && invalidate_catalog

        metadata = build_provider_metadata(requested_name, canonical_name, refresh: refresh)
        @provider_metadata_cache[cache_key] = duplicate_metadata(metadata)
        duplicate_metadata(metadata)
      end

      def clear_class_metadata_cache!(klass, ivar_name)
        return unless klass.instance_variable_defined?(ivar_name)

        klass.remove_instance_variable(ivar_name)
      end

      def validate_provider_class!(klass)
        includes_adapter = klass.include?(Adapter)
        has_required_methods = klass.respond_to?(:provider_name) &&
          klass.respond_to?(:available?) &&
          klass.respond_to?(:binary_name)

        return if includes_adapter || has_required_methods

        raise ConfigurationError, "Provider class must include AgentHarness::Providers::Adapter or implement required class methods"
      end

      def validate_provider_name!(name)
        conflicting_provider = @aliases[name]
        return unless conflicting_provider && conflicting_provider != name

        raise ConfigurationError, "Provider #{name.inspect} conflicts with registered alias for #{conflicting_provider.inspect}"
      end

      def validate_aliases!(name, aliases)
        conflicting_alias = aliases.find do |alias_name|
          next false if alias_name == name

          @providers.key?(alias_name) ||
            (@aliases.key?(alias_name) && @aliases[alias_name] != name)
        end
        return unless conflicting_alias

        owner = if @providers.key?(conflicting_alias)
          conflicting_alias
        else
          @aliases[conflicting_alias]
        end
        raise ConfigurationError, "Alias #{conflicting_alias.inspect} conflicts with registered provider #{owner.inspect}"
      end

      def fallback_provider_metadata(name, klass, aliases, refresh: false)
        normalized_aliases = aliases
          .filter_map do |alias_name|
            normalized_alias = alias_name.to_s.strip
            next if normalized_alias.empty?

            normalized_alias.to_sym
          end
          .uniq
          .reject { |alias_name| alias_name == name }
        installation = if klass.respond_to?(:installation_contract)
          Adapter.normalize_metadata_installation(
            klass.installation_contract,
            provider_name: name,
            binary_name: klass.binary_name
          )
        end

        {
          provider: name,
          canonical_provider: name,
          aliases: normalized_aliases,
          display_name: name.to_s.split("_").map(&:capitalize).join(" "),
          binary_name: klass.binary_name,
          auth: {
            default_mode: nil,
            supported_modes: [],
            service: nil,
            api_family: nil
          },
          runtime: {
            interface: :cli,
            requires_cli: true,
            available: metadata_runtime_available(name, klass, refresh: refresh),
            installable: !installation.nil?,
            installation: installation,
            prompt_delivery: nil,
            output_format: nil,
            sandbox_aware: nil,
            uses_subcommand: nil,
            supports_mcp: false,
            supported_mcp_transports: [],
            supports_sessions: false,
            supports_dangerous_mode: false
          },
          configuration: {fields: [], auth_modes: [], openai_compatible: false},
          capabilities: {streaming: false, file_upload: false, vision: false, tool_use: false, json_mode: false, mcp: false, dangerous_mode: false},
          health_check: {
            supports_registry_checks: false,
            auth_check_supported: false,
            provider_status: false,
            configuration_validation: false,
            lightweight: false
          },
          identity: {
            bot_usernames: [name, *normalized_aliases]
              .filter_map do |identity|
                normalized_identity = identity.to_s.strip
                normalized_identity unless normalized_identity.empty?
              end
              .uniq
          }
        }
      end

      def metadata_runtime_available(name, klass, refresh: false)
        if refresh || !@metadata_runtime_available.key?(name)
          @metadata_runtime_available[name] = klass.available?
        end

        @metadata_runtime_available[name]
      end

      def ensure_builtin_providers_registered
        return if @builtin_registered

        register_builtin_providers
        @builtin_registered = true
      end

      def register_builtin_providers
        BUILTIN_PROVIDER_DEFINITIONS.each do |definition|
          register_if_available(
            definition[:name],
            definition[:require_path],
            definition[:class_name],
            aliases: definition[:aliases]
          )
        end
      end

      def register_if_available(name, require_path, class_name, aliases: [])
        require_relative require_path.sub("agent_harness/providers/", "")
        klass = AgentHarness::Providers.const_get(class_name)
        register(name, klass, aliases: builtin_aliases_for(name, aliases))
      rescue LoadError, NameError => e
        AgentHarness.logger&.debug("[AgentHarness::Registry] Provider #{name} not available: #{e.message}")
      end

      def builtin_aliases_for(name, aliases)
        Array(aliases).reject do |alias_name|
          alias_key = alias_name.to_sym
          next false if alias_key == name

          @providers.key?(alias_key) || @aliases.key?(alias_key)
        end
      end
    end
  end
end
