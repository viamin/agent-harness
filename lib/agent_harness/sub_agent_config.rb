# frozen_string_literal: true

module AgentHarness
  # Canonical provider-agnostic sub-agent definition.
  class SubAgentConfig
    attr_reader :name, :description, :instructions, :model, :tools, :mcp_servers
    attr_reader :constraints, :handoff_conditions, :type, :sub_agents, :routing

    def initialize(name:, description:, instructions:, model: "default", tools: [],
      mcp_servers: [], constraints: {}, handoff_conditions: [], type: nil,
      sub_agents: [], routing: nil)
      @name = normalize_name(name)
      @description = validate_string!(:description, description)
      @instructions = validate_string!(:instructions, instructions)
      @model = normalize_model(model)
      @tools = normalize_array(:tools, tools)
      @mcp_servers = normalize_array(:mcp_servers, mcp_servers)
      @constraints = normalize_hash(:constraints, constraints)
      @handoff_conditions = normalize_array(:handoff_conditions, handoff_conditions)
      @type = type&.to_sym
      @sub_agents = normalize_array(:sub_agents, sub_agents)
      @routing = routing.nil? ? nil : normalize_hash(:routing, routing)
    end

    def self.from_hash(hash)
      unless hash.is_a?(Hash)
        raise ConfigurationError, "Sub-agent definition must be a Hash, got #{hash.class}"
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

      new(**attrs)
    end

    def to_h
      {
        name: @name,
        description: @description,
        instructions: @instructions,
        model: @model,
        tools: deep_dup(@tools),
        mcp_servers: deep_dup(@mcp_servers),
        constraints: deep_dup(@constraints),
        handoff_conditions: deep_dup(@handoff_conditions),
        type: @type,
        sub_agents: deep_dup(@sub_agents),
        routing: deep_dup(@routing)
      }.compact
    end

    private

    def normalize_name(name)
      value = validate_string!(:name, name)
      value.tr(" ", "_").to_sym
    end

    def normalize_model(model)
      return "default" if model.nil?

      validate_string!(:model, model)
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

    def normalize_hash(field, value)
      return {}.freeze if value.nil?

      unless value.is_a?(Hash)
        raise ConfigurationError, "#{field} must be a Hash"
      end

      deep_dup(value).freeze
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
