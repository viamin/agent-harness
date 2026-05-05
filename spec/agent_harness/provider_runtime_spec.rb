# frozen_string_literal: true

RSpec.describe AgentHarness::ProviderRuntime do
  describe "#initialize" do
    it "accepts all keyword arguments" do
      runtime = described_class.new(
        model: "gpt-5",
        base_url: "https://example.com",
        api_provider: "openrouter",
        env: {"API_KEY" => "sk-123"},
        flags: ["--verbose"],
        metadata: {tier: "premium"},
        chat_tools: [{type: "function", function: {name: "lookup_weather"}}]
      )

      expect(runtime.model).to eq("gpt-5")
      expect(runtime.base_url).to eq("https://example.com")
      expect(runtime.api_provider).to eq("openrouter")
      expect(runtime.env).to eq("API_KEY" => "sk-123")
      expect(runtime.flags).to eq(["--verbose"])
      expect(runtime.metadata).to eq(tier: "premium")
      expect(runtime.chat_tools).to eq([{type: "function", function: {name: "lookup_weather"}}])
    end

    it "defaults optional fields" do
      runtime = described_class.new
      expect(runtime.model).to be_nil
      expect(runtime.base_url).to be_nil
      expect(runtime.api_provider).to be_nil
      expect(runtime.env).to eq({})
      expect(runtime.flags).to eq([])
      expect(runtime.metadata).to eq({})
    end

    it "normalizes blank string overrides to nil" do
      runtime = described_class.new(
        model: "  ",
        base_url: "  ",
        api_provider: "  ",
        chat_base_url: "  ",
        chat_model: "  ",
        chat_api_key: "  "
      )

      expect(runtime.model).to be_nil
      expect(runtime.base_url).to be_nil
      expect(runtime.api_provider).to be_nil
      expect(runtime.chat_base_url).to be_nil
      expect(runtime.chat_model).to be_nil
      expect(runtime.chat_api_key).to be_nil
    end

    it "converts symbol env keys to strings" do
      runtime = described_class.new(env: {MY_VAR: "val"})
      expect(runtime.env).to eq("MY_VAR" => "val")
    end

    it "converts unset_env entries to strings" do
      runtime = described_class.new(unset_env: [:OPENAI_BASE_URL, "ANTHROPIC_API_KEY"])

      expect(runtime.unset_env).to eq(["OPENAI_BASE_URL", "ANTHROPIC_API_KEY"])
    end

    it "raises ArgumentError for non-String env values" do
      expect { described_class.new(env: {"PORT" => 3000}) }
        .to raise_error(ArgumentError, /env value for "PORT" must be a String \(got Integer\)/)
    end

    it "raises ArgumentError for boolean env values" do
      expect { described_class.new(env: {"DEBUG" => true}) }
        .to raise_error(ArgumentError, /env value for "DEBUG" must be a String/)
    end

    it "coerces nil env to empty hash" do
      runtime = described_class.new(env: nil)
      expect(runtime.env).to eq({})
    end

    it "coerces nil metadata to empty hash" do
      runtime = described_class.new(metadata: nil)
      expect(runtime.metadata).to eq({})
    end

    it "accepts nil chat_tools" do
      runtime = described_class.new(chat_tools: nil)
      expect(runtime.chat_tools).to be_nil
    end

    it "coerces nil unset_env to empty array" do
      runtime = described_class.new(unset_env: nil)

      expect(runtime.unset_env).to eq([])
    end

    it "raises ArgumentError when flags is not an Array" do
      expect { described_class.new(flags: "--verbose") }
        .to raise_error(ArgumentError, /flags must be an Array \(got String\)/)
    end

    it "coerces nil flags to empty array" do
      runtime = described_class.new(flags: nil)
      expect(runtime.flags).to eq([])
    end

    it "raises ArgumentError for non-String flags" do
      expect { described_class.new(flags: ["--verbose", 42]) }
        .to raise_error(ArgumentError, /flags must be an Array of Strings.*index 1.*42/)
    end

    it "raises ArgumentError when flags contain a Hash" do
      expect { described_class.new(flags: [{key: "val"}]) }
        .to raise_error(ArgumentError, /flags must be an Array of Strings/)
    end

    it "freezes the instance" do
      runtime = described_class.new(model: "gpt-5")
      expect(runtime).to be_frozen
    end

    it "freezes env, flags, and metadata" do
      runtime = described_class.new(
        env: {"K" => "V"},
        flags: ["--foo"],
        metadata: {a: 1}
      )

      expect(runtime.env).to be_frozen
      expect(runtime.flags).to be_frozen
      expect(runtime.metadata).to be_frozen
    end

    it "does not freeze the caller's flags array" do
      caller_flags = ["--verbose"]
      described_class.new(flags: caller_flags)
      expect(caller_flags).not_to be_frozen
    end

    it "does not freeze the caller's metadata hash" do
      caller_metadata = {tier: "premium"}
      described_class.new(metadata: caller_metadata)
      expect(caller_metadata).not_to be_frozen
    end

    it "raises ArgumentError when env is not a Hash" do
      expect { described_class.new(env: "bad") }
        .to raise_error(ArgumentError, /env must be a Hash/)
    end

    it "raises ArgumentError when metadata is not a Hash" do
      expect { described_class.new(metadata: "bad") }
        .to raise_error(ArgumentError, /metadata must be a Hash/)
    end

    it "raises ArgumentError when chat_tools is not an Array" do
      expect { described_class.new(chat_tools: {type: "function"}) }
        .to raise_error(ArgumentError, /chat_tools must be an Array or nil/)
    end

    it "raises ArgumentError when chat_tools contain a non-Hash" do
      expect { described_class.new(chat_tools: ["bad"]) }
        .to raise_error(ArgumentError, /chat_tools must be an Array of Hashes/)
    end

    it "raises ArgumentError when unset_env is not an Array" do
      expect { described_class.new(unset_env: "OPENAI_BASE_URL") }
        .to raise_error(ArgumentError, /unset_env must be an Array/)
    end

    it "raises ArgumentError when model is not a String" do
      expect { described_class.new(model: 42) }
        .to raise_error(ArgumentError, /model must be a String or nil/)
    end

    it "raises ArgumentError when base_url is not a String" do
      expect { described_class.new(base_url: 123) }
        .to raise_error(ArgumentError, /base_url must be a String or nil/)
    end

    it "raises ArgumentError when api_provider is not a String" do
      expect { described_class.new(api_provider: :openrouter) }
        .to raise_error(ArgumentError, /api_provider must be a String or nil/)
    end
  end

  describe ".from_hash" do
    it "builds from symbol-keyed hash" do
      runtime = described_class.from_hash(
        model: "claude-opus",
        base_url: "https://api.example.com",
        api_provider: "openrouter"
      )

      expect(runtime.model).to eq("claude-opus")
      expect(runtime.base_url).to eq("https://api.example.com")
      expect(runtime.api_provider).to eq("openrouter")
    end

    it "builds from string-keyed hash" do
      runtime = described_class.from_hash(
        "model" => "gpt-5",
        "base_url" => "https://api.example.com"
      )

      expect(runtime.model).to eq("gpt-5")
      expect(runtime.base_url).to eq("https://api.example.com")
    end

    it "defaults missing keys" do
      runtime = described_class.from_hash({})
      expect(runtime.model).to be_nil
      expect(runtime.env).to eq({})
      expect(runtime.flags).to eq([])
      expect(runtime.chat_tools).to be_nil
    end

    it "raises ArgumentError when given a non-Hash" do
      expect { described_class.from_hash("bad") }
        .to raise_error(ArgumentError, /expected a Hash/)
    end

    it "raises ArgumentError when model is explicitly false" do
      expect { described_class.from_hash(model: false) }
        .to raise_error(ArgumentError, /model must be a String or nil/)
    end

    it "raises ArgumentError when base_url is explicitly false" do
      expect { described_class.from_hash(base_url: false) }
        .to raise_error(ArgumentError, /base_url must be a String or nil/)
    end

    it "raises ArgumentError when api_provider is explicitly false" do
      expect { described_class.from_hash(api_provider: false) }
        .to raise_error(ArgumentError, /api_provider must be a String or nil/)
    end

    it "raises ArgumentError when a string-keyed model is explicitly false" do
      expect { described_class.from_hash("model" => false) }
        .to raise_error(ArgumentError, /model must be a String or nil/)
    end

    it "raises ArgumentError when env is explicitly false" do
      expect { described_class.from_hash(env: false) }
        .to raise_error(ArgumentError, /env must be a Hash/)
    end
  end

  describe ".wrap" do
    it "returns nil for nil" do
      expect(described_class.wrap(nil)).to be_nil
    end

    it "returns the same instance for a ProviderRuntime" do
      runtime = described_class.new(model: "gpt-5")
      expect(described_class.wrap(runtime)).to be(runtime)
    end

    it "coerces a Hash into a ProviderRuntime" do
      result = described_class.wrap({model: "gpt-5", base_url: "https://example.com"})
      expect(result).to be_a(described_class)
      expect(result.model).to eq("gpt-5")
      expect(result.base_url).to eq("https://example.com")
    end

    it "raises ArgumentError for unsupported types" do
      expect { described_class.wrap("bad") }.to raise_error(ArgumentError, /Cannot coerce/)
    end
  end

  describe "#empty?" do
    it "returns true when no overrides are set" do
      expect(described_class.new).to be_empty
    end

    it "returns false when model is set" do
      expect(described_class.new(model: "gpt-5")).not_to be_empty
    end

    it "returns false when base_url is set" do
      expect(described_class.new(base_url: "https://example.com")).not_to be_empty
    end

    it "returns false when api_provider is set" do
      expect(described_class.new(api_provider: "openrouter")).not_to be_empty
    end

    it "returns false when env is set" do
      expect(described_class.new(env: {"K" => "V"})).not_to be_empty
    end

    it "returns false when flags are set" do
      expect(described_class.new(flags: ["--foo"])).not_to be_empty
    end

    it "returns false when metadata is set" do
      expect(described_class.new(metadata: {a: 1})).not_to be_empty
    end

    it "returns false when unset_env is set" do
      expect(described_class.new(unset_env: ["OPENAI_BASE_URL"])).not_to be_empty
    end

    it "returns false when chat_tools is set" do
      runtime = described_class.new(chat_tools: [{type: "function", function: {name: "lookup_weather"}}])

      expect(runtime).not_to be_empty
    end
  end

  describe "#merge" do
    it "merges hashes and arrays while letting explicit overrides win" do
      base = described_class.new(
        model: "skill-model",
        env: {"SKILL_ENV" => "1"},
        flags: ["--from-skill"],
        metadata: {skill: true},
        chat_tools: [{type: "function", function: {name: "skill_tool"}}]
      )
      override = described_class.new(
        model: "user-model",
        env: {"USER_ENV" => "1"},
        flags: ["--from-user"],
        metadata: {user: true},
        chat_tools: [{type: "function", function: {name: "user_tool"}}]
      )

      merged = base.merge(override)

      expect(merged.model).to eq("user-model")
      expect(merged.env).to eq("SKILL_ENV" => "1", "USER_ENV" => "1")
      expect(merged.flags).to eq(["--from-skill", "--from-user"])
      expect(merged.metadata).to eq(skill: true, user: true)
      expect(merged.chat_tools).to eq([
        {type: "function", function: {name: "skill_tool"}},
        {type: "function", function: {name: "user_tool"}}
      ])
    end
  end
end
