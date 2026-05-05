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
    attr_reader :model, :base_url, :api_provider, :env, :flags, :metadata, :unset_env,
      :chat_base_url, :chat_model, :chat_api_key, :chat_max_tokens, :chat_tools

    # @param model [String, nil] model identifier override
    # @param base_url [String, nil] upstream API base URL override
    # @param api_provider [String, nil] API-compatible backend name
    # @param env [Hash<String,String>] extra environment variables for the subprocess
    # @param flags [Array<String>] extra CLI flags to append
    # @param unset_env [Array<String>] environment variable names to remove from inherited env
    # @param metadata [Hash] arbitrary provider-specific data
    # @param chat_base_url [String, nil] override transport base URL for chat
    # @param chat_model [String, nil] override model for chat
    # @param chat_api_key [String, nil] override API key for chat
    # @param chat_max_tokens [Integer, nil] max tokens for chat response
    # @param chat_tools [Array<Hash>, nil] default tool definitions for chat requests
    def initialize(model: nil, base_url: nil, api_provider: nil, env: {}, flags: [], unset_env: [], metadata: {},
      chat_base_url: nil, chat_model: nil, chat_api_key: nil, chat_max_tokens: nil, chat_tools: nil)
      validate_optional_string!(:model, model)
      validate_optional_string!(:base_url, base_url)
      validate_optional_string!(:api_provider, api_provider)

      @model = normalize_optional_string(model)
      @base_url = normalize_optional_string(base_url)
      @api_provider = normalize_optional_string(api_provider)

      env_hash = env.nil? ? {} : env
      unless env_hash.is_a?(Hash)
        raise ArgumentError, "env must be a Hash (got #{env_hash.class})"
      end
      normalized_env = env_hash.each_with_object({}) do |(key, value), acc|
        string_key = key.to_s
        unless value.is_a?(String)
          raise ArgumentError, "env value for #{string_key.inspect} must be a String (got #{value.class})"
        end
        acc[string_key] = value
      end
      @env = normalized_env.freeze

      normalized_flags = flags.nil? ? [] : flags
      unless normalized_flags.is_a?(Array)
        raise ArgumentError, "flags must be an Array (got #{normalized_flags.class})"
      end
      normalized_flags = normalized_flags.dup
      normalized_flags.each_with_index do |flag, index|
        unless flag.is_a?(String)
          raise ArgumentError,
            "flags must be an Array of Strings; invalid element at index #{index}: #{flag.inspect} (#{flag.class})"
        end
      end
      @flags = normalized_flags.freeze

      metadata_hash = metadata.nil? ? {} : metadata
      unless metadata_hash.is_a?(Hash)
        raise ArgumentError, "metadata must be a Hash (got #{metadata_hash.class})"
      end
      @metadata = metadata_hash.dup.freeze

      # Unset environment variables for the request. These are variable names that
      # should be removed from the inherited environment before the provider
      # command runs.
      unset_array = unset_env.nil? ? [] : unset_env
      unless unset_array.is_a?(Array)
        raise ArgumentError, "unset_env must be an Array (got #{unset_array.class})"
      end
      normalized_unset_env = unset_array.map.with_index do |key, index|
        key.to_s
      rescue NoMethodError
        raise ArgumentError,
          "unset_env must contain values convertible to String; invalid element at index #{index}: #{key.inspect} (#{key.class})"
      end
      @unset_env = normalized_unset_env.freeze

      validate_optional_string!(:chat_base_url, chat_base_url)
      validate_optional_string!(:chat_model, chat_model)
      validate_optional_string!(:chat_api_key, chat_api_key)
      unless chat_max_tokens.nil? || chat_max_tokens.is_a?(Integer)
        raise ArgumentError, "chat_max_tokens must be an Integer or nil (got #{chat_max_tokens.class})"
      end
      unless chat_tools.nil? || chat_tools.is_a?(Array)
        raise ArgumentError, "chat_tools must be an Array or nil (got #{chat_tools.class})"
      end
      normalized_chat_tools = chat_tools&.dup
      normalized_chat_tools&.each_with_index do |tool, index|
        unless tool.is_a?(Hash)
          raise ArgumentError,
            "chat_tools must be an Array of Hashes; invalid element at index #{index}: #{tool.inspect} (#{tool.class})"
        end
      end
      @chat_base_url = normalize_optional_string(chat_base_url)
      @chat_model = normalize_optional_string(chat_model)
      @chat_api_key = normalize_optional_string(chat_api_key)
      @chat_max_tokens = chat_max_tokens
      @chat_tools = normalized_chat_tools&.freeze

      freeze
    end

    # Build a ProviderRuntime from a Hash.
    #
    # @param hash [Hash] runtime attributes
    # @return [ProviderRuntime]
    def self.from_hash(hash)
      raise ArgumentError, "expected a Hash, got #{hash.class}" unless hash.is_a?(Hash)

      env_val = hash_value(hash, :env)
      flags_val = hash_value(hash, :flags)
      unset_env_val = hash_value(hash, :unset_env)
      metadata_val = hash_value(hash, :metadata)

      new(
        model: hash_value(hash, :model),
        base_url: hash_value(hash, :base_url),
        api_provider: hash_value(hash, :api_provider),
        env: env_val.nil? ? {} : env_val,
        flags: flags_val.nil? ? [] : flags_val,
        unset_env: unset_env_val.nil? ? [] : unset_env_val,
        metadata: metadata_val.nil? ? {} : metadata_val,
        chat_base_url: hash_value(hash, :chat_base_url),
        chat_model: hash_value(hash, :chat_model),
        chat_api_key: hash_value(hash, :chat_api_key),
        chat_max_tokens: hash_value(hash, :chat_max_tokens),
        chat_tools: hash_value(hash, :chat_tools)
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
        env.empty? && flags.empty? && metadata.empty? && unset_env.empty? &&
        chat_base_url.nil? && chat_model.nil? && chat_api_key.nil? && chat_max_tokens.nil? &&
        chat_tools.nil?
    end

    def to_h
      {
        model: model,
        base_url: base_url,
        api_provider: api_provider,
        env: env.empty? ? nil : env.dup,
        flags: flags.empty? ? nil : flags.dup,
        unset_env: unset_env.empty? ? nil : unset_env.dup,
        metadata: metadata.empty? ? nil : metadata.dup,
        chat_base_url: chat_base_url,
        chat_model: chat_model,
        chat_api_key: chat_api_key,
        chat_max_tokens: chat_max_tokens,
        chat_tools: chat_tools&.dup
      }.compact
    end

    def merge(other)
      other_runtime = ProviderRuntime.wrap(other)
      return self if other_runtime.nil? || other_runtime.empty?

      ProviderRuntime.new(
        model: other_runtime.model || model,
        base_url: other_runtime.base_url || base_url,
        api_provider: other_runtime.api_provider || api_provider,
        env: env.merge(other_runtime.env),
        flags: flags + other_runtime.flags,
        unset_env: unset_env + other_runtime.unset_env,
        metadata: metadata.merge(other_runtime.metadata),
        chat_base_url: other_runtime.chat_base_url || chat_base_url,
        chat_model: other_runtime.chat_model || chat_model,
        chat_api_key: other_runtime.chat_api_key || chat_api_key,
        chat_max_tokens: other_runtime.chat_max_tokens.nil? ? chat_max_tokens : other_runtime.chat_max_tokens,
        chat_tools: merge_chat_tools(chat_tools, other_runtime.chat_tools)
      )
    end

    private_class_method def self.hash_value(hash, key)
      sym_value = hash[key]
      str_value = hash[key.to_s]
      # Prefer the symbol key; fall back to the string key only when the
      # symbol key is nil (not just falsy) so that an explicit `false` is
      # not silently discarded.
      sym_value.nil? ? str_value : sym_value
    end

    private

    def merge_chat_tools(base_tools, override_tools)
      return override_tools unless base_tools
      return base_tools unless override_tools

      base_tools + override_tools
    end

    def validate_optional_string!(name, value)
      return if value.nil?
      return if value.is_a?(String)

      raise ArgumentError, "#{name} must be a String or nil (got #{value.class})"
    end

    def normalize_optional_string(value)
      return value unless value.respond_to?(:strip)

      normalized = value.strip
      normalized.empty? ? nil : normalized
    end
  end
end
