# frozen_string_literal: true

module AgentHarness
  # Normalized runtime configuration for per-request provider overrides.
  #
  # ProviderRuntime lets callers pass a single, provider-agnostic payload
  # into +send_message+ that each provider materializes into CLI args, env
  # vars, or config files as needed.
  #
  # @example Routing OpenCode through OpenRouter with a specific model
  #   runtime = AgentHarness::ProviderRuntime.new(
  #     model: "anthropic/claude-opus-4.1",
  #     base_url: "https://openrouter.ai/api/v1",
  #     api_provider: "openrouter",
  #     env: { "OPENROUTER_API_KEY" => "sk-..." }
  #   )
  #   provider.send_message(prompt: "Hello", provider_runtime: runtime)
  #
  # @example Passing a Hash (auto-coerced by Base#send_message)
  #   provider.send_message(
  #     prompt: "Hello",
  #     provider_runtime: {
  #       model: "openai/gpt-5.3-codex",
  #       base_url: "https://openrouter.ai/api/v1"
  #     }
  #   )
  class ProviderRuntime
    attr_reader :model, :base_url, :api_provider, :env, :flags, :metadata

    # @param model [String, nil] model identifier override
    # @param base_url [String, nil] upstream API base URL override
    # @param api_provider [String, nil] API-compatible backend name
    # @param env [Hash<String,String>] extra environment variables for the subprocess
    # @param flags [Array<String>] extra CLI flags to append
    # @param metadata [Hash] arbitrary provider-specific data
    def initialize(model: nil, base_url: nil, api_provider: nil, env: {}, flags: [], metadata: {})
      @model = model
      @base_url = base_url
      @api_provider = api_provider
      @env = env.transform_keys(&:to_s).freeze
      @flags = Array(flags).freeze
      @metadata = metadata.freeze

      freeze
    end

    # Build a ProviderRuntime from a Hash.
    #
    # @param hash [Hash] runtime attributes
    # @return [ProviderRuntime]
    def self.from_hash(hash)
      new(
        model: hash[:model] || hash["model"],
        base_url: hash[:base_url] || hash["base_url"],
        api_provider: hash[:api_provider] || hash["api_provider"],
        env: hash[:env] || hash["env"] || {},
        flags: hash[:flags] || hash["flags"] || [],
        metadata: hash[:metadata] || hash["metadata"] || {}
      )
    end

    # Coerce a value into a ProviderRuntime.
    #
    # @param value [ProviderRuntime, Hash, nil] input
    # @return [ProviderRuntime, nil]
    def self.wrap(value)
      case value
      when ProviderRuntime then value
      when Hash then from_hash(value)
      when nil then nil
      else
        raise ArgumentError, "Cannot coerce #{value.class} into ProviderRuntime"
      end
    end

    # Whether any meaningful overrides are present.
    #
    # @return [Boolean]
    def empty?
      model.nil? && base_url.nil? && api_provider.nil? &&
        env.empty? && flags.empty? && metadata.empty?
    end
  end
end
