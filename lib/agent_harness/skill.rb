# frozen_string_literal: true

require "yaml"

module AgentHarness
  # Canonical provider-agnostic skill definition loaded from SKILL.md.
  class Skill
    PROVIDER_FAMILY_ALIASES = {
      anthropic: :anthropic,
      google: :google,
      openai: :openai,
      openai_compatible: :openai
    }.freeze

    attr_reader :name, :description, :instructions, :trigger, :tools, :mcp_servers
    attr_reader :provider_overrides, :source_path

    def initialize(name:, description:, instructions:, trigger: nil, tools: [], mcp_servers: [],
      providers: {}, source_path: nil)
      @name = normalize_name(name)
      @description = validate_string!(:description, description)
      @instructions = validate_string!(:instructions, instructions)
      @trigger = trigger.nil? ? nil : validate_string!(:trigger, trigger)
      @tools = normalize_array(:tools, tools)
      @mcp_servers = normalize_mcp_servers(mcp_servers)
      @provider_overrides = normalize_provider_overrides(providers)
      @source_path = source_path && File.expand_path(source_path)
    end

    def self.from_hash(hash = nil, source_path: nil, **kwargs)
      hash = kwargs if hash.nil? && !kwargs.empty?

      unless hash.is_a?(Hash)
        raise ConfigurationError, "Skill definition must be a Hash, got #{hash.class}"
      end

      attrs = hash.each_with_object({}) do |(key, value), memo|
        memo[key.to_sym] = value
      end

      %i[name description instructions].each do |field|
        value = attrs[field]
        next if value.is_a?(String) && !value.strip.empty?
        next if value.is_a?(Symbol)

        raise ConfigurationError, "#{field} is required"
      end

      new(**attrs.merge(source_path: source_path))
    end

    def self.load_file(path)
      expanded_path = File.expand_path(path)
      content = File.read(expanded_path)
      frontmatter, body = parse_markdown(content)
      from_hash(frontmatter.merge(instructions: body), source_path: expanded_path)
    rescue Errno::ENOENT
      raise ConfigurationError, "Skill file not found: #{path}"
    rescue Psych::Exception => e
      raise ConfigurationError, "Invalid YAML frontmatter in skill #{path}: #{e.message}"
    end

    def provider_override_for(provider)
      merged = provider_override_keys_for(provider).reduce(nil) do |runtime, key|
        override = @provider_overrides[key]
        next runtime unless override

        runtime ? runtime.merge(override) : ProviderRuntime.wrap(override)
      end

      merged ? merged.to_h : {}
    end

    def to_h
      {
        name: @name,
        description: @description,
        instructions: @instructions,
        trigger: @trigger,
        tools: deep_dup(@tools),
        mcp_servers: deep_dup(@mcp_servers),
        providers: deep_dup(@provider_overrides),
        source_path: @source_path
      }.compact
    end

    private

    def self.parse_markdown(content)
      match = content.match(/\A---\s*\n(.*?)\n---\s*\n?(.*)\z/m)
      raise ConfigurationError, "Skill markdown must begin with YAML frontmatter" unless match

      frontmatter = YAML.safe_load(match[1], permitted_classes: [], aliases: false) || {}
      unless frontmatter.is_a?(Hash)
        raise ConfigurationError, "Skill frontmatter must be a Hash"
      end

      [frontmatter, match[2].to_s.strip]
    end
    private_class_method :parse_markdown

    def normalize_name(name)
      value = validate_string!(:name, name)
      value.tr(" -", "__").to_sym
    end

    def validate_string!(field, value)
      unless value.is_a?(String) || value.is_a?(Symbol)
        raise ConfigurationError, "#{field} must be a String or Symbol"
      end

      string = value.to_s.strip
      raise ConfigurationError, "#{field} is required" if string.empty?

      string
    end

    def normalize_array(field, value)
      return [].freeze if value.nil?

      unless value.is_a?(Array)
        raise ConfigurationError, "#{field} must be an Array"
      end

      deep_dup(value).freeze
    end

    def normalize_mcp_servers(mcp_servers)
      normalize_array(:mcp_servers, mcp_servers).map do |server|
        case server
        when McpServer
          server.to_h.freeze
        when Hash
          McpServer.from_hash(server).to_h.freeze
        else
          raise ConfigurationError, "Unsupported MCP server reference #{server.inspect} in skill definition"
        end
      end.freeze
    end

    def normalize_provider_overrides(providers)
      return {}.freeze if providers.nil?

      unless providers.is_a?(Hash)
        raise ConfigurationError, "providers must be a Hash"
      end

      providers.each_with_object({}) do |(key, value), memo|
        provider_key = normalize_provider_key(key)
        memo[provider_key] = normalize_provider_override_value(provider_key, value)
      end.freeze
    end

    def normalize_provider_override_value(provider_key, value)
      case value
      when true
        (provider_key == :all) ? nil : {}
      when nil
        {}
      when Hash
        deep_dup(value).transform_keys(&:to_sym).freeze
      else
        raise ConfigurationError, "providers.#{provider_key} must be true or a Hash"
      end
    end

    def normalize_provider_key(provider)
      key = provider.to_sym
      return :all if key == :all

      return PROVIDER_FAMILY_ALIASES[key] if PROVIDER_FAMILY_ALIASES.key?(key)

      registry = Providers::Registry.instance
      canonical = registry.canonical_name(key)
      raise ConfigurationError, "Unknown provider in skill definition: #{provider}" unless registry.registered?(canonical)

      canonical.to_sym
    end

    def provider_override_keys_for(provider)
      key = provider.to_sym
      return [:all] if key == :all

      registry = Providers::Registry.instance
      canonical = registry.canonical_name(key)
      concrete = registry.registered?(canonical) ? canonical.to_sym : key
      family = normalize_provider_family(concrete)

      [:all, family, concrete].uniq
    end

    def normalize_provider_family(provider)
      case provider
      when :claude then :anthropic
      when :gemini then :google
      when :cursor, :github_copilot, :codex, :opencode, :openai_compatible then :openai
      else provider
      end
    end

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
end
