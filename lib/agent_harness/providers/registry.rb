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

      def initialize
        @providers = {}
        @aliases = {}
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

        @providers[name] = klass

        aliases.each do |alias_name|
          @aliases[alias_name.to_sym] = name
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

      # Fetch install contract metadata for a provider.
      #
      # @param name [Symbol, String] the provider name
      # @return [Hash] the provider install contract
      # @raise [ConfigurationError] if the provider does not implement
      #   `.install_contract`
      def install_contract(name)
        provider_class = get(name)

        unless provider_class.respond_to?(:install_contract)
          raise ConfigurationError, "Provider #{provider_class} does not implement .install_contract"
        end

        provider_class.install_contract
      rescue NotImplementedError
        raise ConfigurationError, "Provider #{provider_class} does not implement .install_contract"
      end

      # Get installation metadata for a provider.
      #
      # @param name [Symbol, String] the provider name
      # @return [Hash, nil] installation contract
      # @raise [ConfigurationError] if the provider name is not registered
      def installation_contract(name)
        klass = get(name)
        return nil unless klass.respond_to?(:installation_contract)

        klass.installation_contract
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

      # Reset registry (useful for testing)
      #
      # @return [void]
      def reset!
        @providers.clear
        @aliases.clear
        @builtin_registered = false
      end

      private

      def resolve_alias(name)
        @aliases[name] || name
      end

      def validate_provider_class!(klass)
        includes_adapter = klass.include?(Adapter)
        has_required_methods = klass.respond_to?(:provider_name) &&
          klass.respond_to?(:available?) &&
          klass.respond_to?(:binary_name)

        return if includes_adapter
        return if has_required_methods

        raise ConfigurationError,
          "Provider class must include AgentHarness::Providers::Adapter or implement required class methods"
      end

      def ensure_builtin_providers_registered
        return if @builtin_registered

        register_builtin_providers
        @builtin_registered = true
      end

      def register_builtin_providers
        # Only register providers that exist
        # These will be loaded on demand
        register_if_available(:claude, "agent_harness/providers/anthropic", :Anthropic, aliases: [:anthropic])
        register_if_available(:cursor, "agent_harness/providers/cursor", :Cursor)
        register_if_available(:gemini, "agent_harness/providers/gemini", :Gemini)
        register_if_available(:github_copilot, "agent_harness/providers/github_copilot", :GithubCopilot, aliases: [:copilot])
        register_if_available(:codex, "agent_harness/providers/codex", :Codex)
        register_if_available(:opencode, "agent_harness/providers/opencode", :Opencode)
        register_if_available(:kilocode, "agent_harness/providers/kilocode", :Kilocode)
        register_if_available(:aider, "agent_harness/providers/aider", :Aider)
        register_if_available(:mistral_vibe, "agent_harness/providers/mistral_vibe", :MistralVibe)
      end

      def register_if_available(name, require_path, class_name, aliases: [])
        require_relative require_path.sub("agent_harness/providers/", "")
        klass = AgentHarness::Providers.const_get(class_name)
        register(name, klass, aliases: aliases)
      rescue LoadError, NameError => e
        AgentHarness.logger&.debug("[AgentHarness::Registry] Provider #{name} not available: #{e.message}")
      end
    end
  end
end
