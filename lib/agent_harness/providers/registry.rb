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
        unless klass.included_modules.include?(Adapter) ||
            (klass.respond_to?(:provider_name) && klass.respond_to?(:available?) && klass.respond_to?(:binary_name))
          raise ConfigurationError, "Provider class must include AgentHarness::Providers::Adapter or implement required class methods"
        end
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
