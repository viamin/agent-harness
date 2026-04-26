# frozen_string_literal: true

module AgentHarness
  # Configuration for AgentHarness
  #
  # Supports configuration via Ruby DSL, YAML files, and environment variables.
  # Configuration sources are merged with priority: Ruby DSL > YAML > Environment.
  #
  # @example Ruby DSL configuration
  #   AgentHarness.configure do |config|
  #     config.logger = Logger.new(STDOUT)
  #     config.default_provider = :cursor
  #     config.fallback_providers = [:claude, :gemini]
  #
  #     config.provider :claude do |p|
  #       p.enabled = true
  #       p.timeout = 600
  #     end
  #   end
  class Configuration
    attr_accessor :logger, :log_level, :default_provider, :fallback_providers
    attr_accessor :config_file_path, :default_timeout
    attr_writer :command_executor

    attr_reader :providers, :orchestration_config, :callbacks, :custom_provider_classes
    attr_reader :sub_agents, :tool_registry, :mcp_servers, :extension_registry

    def initialize
      @logger = nil # Will use null logger if not set
      @log_level = :info
      @default_provider = :cursor
      @fallback_providers = []
      @command_executor = nil # Lazy-initialized
      @config_file_path = nil
      @default_timeout = 300
      @providers = {}
      @orchestration_config = OrchestrationConfig.new
      @callbacks = CallbackRegistry.new
      @custom_provider_classes = {}
      @sub_agents = {}
      @tool_registry = ToolRegistry.new
      @mcp_servers = {}
      @extension_registry = Extensions::Registry.new
    end

    # Get or lazily initialize the command executor
    #
    # @return [CommandExecutor] the command executor
    def command_executor
      @command_executor ||= CommandExecutor.new(logger: @logger)
    end

    # Configure orchestration settings
    #
    # @yield [OrchestrationConfig] the orchestration configuration
    # @return [OrchestrationConfig] the orchestration configuration
    def orchestration(&block)
      yield(@orchestration_config) if block_given?
      @orchestration_config
    end

    # Configure a provider
    #
    # @param name [Symbol, String] the provider name
    # @yield [ProviderConfig] the provider configuration
    # @return [ProviderConfig] the provider configuration
    def provider(name, &block)
      config = ProviderConfig.new(name)
      yield(config) if block_given?
      @providers[name.to_sym] = config
    end

    # Register a custom provider class
    #
    # @param name [Symbol, String] the provider name
    # @param klass [Class] the provider class
    # @return [void]
    def register_provider(name, klass)
      @custom_provider_classes[name.to_sym] = klass
    end

    # Set MCP servers from an array of server definitions.
    #
    # @param servers [Array<Hash, McpServer>] server definitions
    def mcp_servers=(servers)
      normalized = McpConfigTranslator.normalize_servers(servers)
      @mcp_servers = normalized.each_with_object({}) { |s, h| h[s.name.to_sym] = s }
    end

    # Load MCP server definitions from a configuration file.
    #
    # @param path [String] file path
    def load_mcp_servers_file(path)
      loaded = McpConfigLoader.load_file(path)
      @mcp_servers = loaded.each_with_object({}) { |s, h| h[s.name.to_sym] = s }
    end

    # Configure a provider-agnostic sub-agent definition.
    #
    # @param name [Symbol, String] sub-agent name
    # @param attributes [Hash] sub-agent attributes
    # @yield [Hash] mutable attributes hash before validation
    # @return [SubAgentConfig] registered sub-agent config
    def sub_agent(name, attributes = {})
      attributes = attributes.dup
      yield(attributes) if block_given?
      attributes[:name] = name

      config = SubAgentConfig.from_hash(attributes)
      @sub_agents[config.name] = config
    end

    # Load sub-agent definitions from a YAML or Markdown file.
    #
    # @param path [String] file path
    # @return [Array<SubAgentConfig>] loaded sub-agents
    def load_sub_agents(path)
      SubAgentFileLoader.load(path).each do |sub_agent|
        @sub_agents[sub_agent.name] = sub_agent
      end
    end

    # Register a generic tool definition that sub-agents can reference.
    #
    # @param name [Symbol, String] tool name
    # @param description [String, nil] tool description
    # @param provider_mappings [Hash] provider-specific mappings
    # @return [ToolDefinition]
    def register_tool(name, description: nil, **provider_mappings)
      @tool_registry.register(name, description: description, **provider_mappings)
    end

    # Register a named MCP server for later reference by sub-agents.
    #
    # @param name [Symbol, String] server name
    # @param definition [Hash, McpServer, nil] server definition
    # @param attributes [Hash] server attributes
    # @return [McpServer]
    def register_mcp_server(name, definition = nil, **attributes)
      server = if definition.is_a?(McpServer)
        definition
      else
        payload = (definition || attributes).dup
        payload[:name] ||= name.to_s
        McpServer.from_hash(payload)
      end

      @mcp_servers[name.to_sym] = server
    end

    # Register a provider-agnostic runtime extension.
    #
    # @param extension [Extensions::Base] extension instance
    # @param as [Symbol, String, nil] optional registry key override
    # @return [Extensions::Base]
    def register_extension(extension, as: nil)
      @extension_registry.register(extension, as: as)
      extension
    end

    # Load one or more extensions from disk through an adapter.
    #
    # @param path [String] extension file, directory, or package root
    # @param adapter [Symbol, String, nil] optional explicit adapter name
    # @return [Array<Extensions::Base>]
    def load_extensions(path, adapter: nil)
      Extensions::Loader.load(path, adapter: adapter).each do |extension|
        register_extension(extension)
      end
    end

    # Discover and register all extensions found in a directory.
    #
    # Each child entry (subdirectory or file) is loaded through the
    # appropriate adapter; entries that cannot be parsed are silently
    # skipped.
    #
    # @param directory [String] directory to scan
    # @return [Array<Extensions::Base>]
    def discover_extensions(directory)
      Extensions::Loader.discover(directory).each do |extension|
        register_extension(extension)
      end
    end

    # Resolve a registered or inline extension reference.
    #
    # @param reference [Symbol, String, Extensions::Base, nil]
    # @return [Extensions::Base, nil]
    def resolve_extension(reference)
      case reference
      when nil
        nil
      when Extensions::Base
        reference
      else
        @extension_registry.fetch(reference)
      end
    end

    # Resolve a named or inline sub-agent definition.
    #
    # @param reference [Symbol, String, Hash, SubAgentConfig, nil] sub-agent reference
    # @return [SubAgentConfig, nil] resolved sub-agent config
    def resolve_sub_agent(reference)
      case reference
      when nil
        nil
      when SubAgentConfig
        reference
      when Hash
        SubAgentConfig.from_hash(reference)
      else
        @sub_agents.fetch(reference.to_sym) do
          raise ConfigurationError, "Unknown sub-agent: #{reference}"
        end
      end
    end

    # Register callback for token usage events
    #
    # @yield [TokenEvent] called when tokens are used
    # @return [void]
    def on_tokens_used(&block)
      @callbacks.register(:tokens_used, block)
    end

    # Register callback for provider switch events
    #
    # @yield [Hash] event data with :from_provider, :to_provider, :reason
    # @return [void]
    def on_provider_switch(&block)
      @callbacks.register(:provider_switch, block)
    end

    # Register callback for circuit open events
    #
    # @yield [Hash] event data with :provider, :failure_count
    # @return [void]
    def on_circuit_open(&block)
      @callbacks.register(:circuit_open, block)
    end

    # Register callback for circuit close events
    #
    # @yield [Hash] event data with :provider
    # @return [void]
    def on_circuit_close(&block)
      @callbacks.register(:circuit_close, block)
    end

    # Validate the configuration
    #
    # @raise [ConfigurationError] if configuration is invalid
    # @return [void]
    def validate!
      errors = []

      errors << "No providers configured" if @providers.empty?
      errors << "Default provider '#{@default_provider}' not configured" unless @providers[@default_provider]

      raise ConfigurationError, errors.join(", ") unless errors.empty?
    end

    # Check if configuration is valid
    #
    # @return [Boolean] true if valid
    def valid?
      validate!
      true
    rescue ConfigurationError
      false
    end
  end

  # Orchestration configuration
  class OrchestrationConfig
    attr_accessor :enabled, :auto_switch_on_error, :auto_switch_on_rate_limit

    attr_reader :circuit_breaker_config, :retry_config, :rate_limit_config, :health_check_config

    def initialize
      @enabled = true
      @auto_switch_on_error = true
      @auto_switch_on_rate_limit = true
      @circuit_breaker_config = CircuitBreakerConfig.new
      @retry_config = RetryConfig.new
      @rate_limit_config = RateLimitConfig.new
      @health_check_config = HealthCheckConfig.new
    end

    # Configure circuit breaker
    #
    # @yield [CircuitBreakerConfig] the circuit breaker configuration
    # @return [CircuitBreakerConfig]
    def circuit_breaker(&block)
      yield(@circuit_breaker_config) if block_given?
      @circuit_breaker_config
    end

    # Configure retry behavior
    #
    # @yield [RetryConfig] the retry configuration
    # @return [RetryConfig]
    def retry(&block)
      yield(@retry_config) if block_given?
      @retry_config
    end

    # Configure rate limiting
    #
    # @yield [RateLimitConfig] the rate limit configuration
    # @return [RateLimitConfig]
    def rate_limit(&block)
      yield(@rate_limit_config) if block_given?
      @rate_limit_config
    end

    # Configure health checking
    #
    # @yield [HealthCheckConfig] the health check configuration
    # @return [HealthCheckConfig]
    def health_check(&block)
      yield(@health_check_config) if block_given?
      @health_check_config
    end
  end

  # Circuit breaker configuration
  class CircuitBreakerConfig
    attr_accessor :enabled, :failure_threshold, :timeout, :half_open_max_calls

    def initialize
      @enabled = true
      @failure_threshold = 5
      @timeout = 300 # 5 minutes
      @half_open_max_calls = 3
    end
  end

  # Retry configuration
  class RetryConfig
    attr_accessor :enabled, :max_attempts, :base_delay, :max_delay, :exponential_base, :jitter

    def initialize
      @enabled = true
      @max_attempts = 3
      @base_delay = 1.0
      @max_delay = 60.0
      @exponential_base = 2.0
      @jitter = true
    end
  end

  # Rate limit configuration
  class RateLimitConfig
    attr_accessor :enabled, :default_reset_time

    def initialize
      @enabled = true
      @default_reset_time = 3600 # 1 hour
    end
  end

  # Health check configuration
  class HealthCheckConfig
    attr_accessor :enabled, :interval, :failure_threshold, :timeout

    def initialize
      @enabled = true
      @interval = 60 # 1 minute
      @failure_threshold = 3
      @timeout = 5 # seconds per provider check
    end
  end

  # Provider-specific configuration
  class ProviderConfig
    attr_accessor :enabled, :type, :priority, :models, :default_flags, :timeout, :model,
      :externally_sandboxed

    attr_reader :name

    def initialize(name)
      @name = name.to_sym
      @enabled = true
      @type = :usage_based
      @priority = 10
      @models = []
      @default_flags = []
      @timeout = nil
      @model = nil
      @externally_sandboxed = false
    end

    # Merge options into this configuration
    #
    # @param options [Hash] options to merge
    # @return [self]
    def merge!(options)
      options.each do |key, value|
        setter = "#{key}="
        send(setter, value) if respond_to?(setter)
      end
      self
    end
  end

  # Provider-agnostic tool definition used during sub-agent translation.
  class ToolDefinition
    attr_reader :name, :description, :provider_mappings

    def initialize(name:, description: nil, provider_mappings: {})
      @name = name.to_sym
      @description = description
      @provider_mappings = deep_dup(provider_mappings).each_with_object({}) do |(provider, value), mappings|
        mappings[provider.to_sym] = value
      end.freeze
    end

    def mapping_for(provider)
      deep_dup(@provider_mappings[provider.to_sym])
    end

    def to_h
      {name: @name, description: @description, provider_mappings: deep_dup(@provider_mappings)}
    end

    private

    def deep_dup(value)
      case value
      when Array
        value.map { |entry| deep_dup(entry) }
      when Hash
        value.each_with_object({}) { |(key, entry), copy| copy[key] = deep_dup(entry) }
      else
        value.dup
      end
    rescue TypeError
      value
    end
  end

  # Registry for canonical tool definitions referenced by sub-agents.
  class ToolRegistry
    def initialize
      @tools = {}
    end

    def register(name, description: nil, **provider_mappings)
      @tools[name.to_sym] = ToolDefinition.new(
        name: name,
        description: description,
        provider_mappings: provider_mappings
      )
    end

    def fetch(name)
      @tools.fetch(name.to_sym) do
        raise ConfigurationError, "Unknown tool: #{name}"
      end
    end

    def registered?(name)
      @tools.key?(name.to_sym)
    end
  end

  # Registry for event callbacks
  class CallbackRegistry
    def initialize
      @callbacks = Hash.new { |h, k| h[k] = [] }
    end

    # Register a callback for an event
    #
    # @param event [Symbol] the event name
    # @param block [Proc] the callback
    # @return [void]
    def register(event, block)
      @callbacks[event] << block
    end

    # Emit an event to all registered callbacks
    #
    # @param event [Symbol] the event name
    # @param data [Hash] event data
    # @return [void]
    def emit(event, data)
      @callbacks[event].each do |callback|
        callback.call(data)
      rescue => e
        AgentHarness.logger&.error("[AgentHarness::CallbackRegistry] Callback error for #{event}: #{e.message}")
      end
    end

    # Check if any callbacks are registered for an event
    #
    # @param event [Symbol] the event name
    # @return [Boolean] true if callbacks exist
    def registered?(event)
      @callbacks[event].any?
    end
  end
end
