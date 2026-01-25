# frozen_string_literal: true

RSpec.describe AgentHarness::Configuration do
  subject(:config) { described_class.new }

  describe "#initialize" do
    it "sets default values" do
      expect(config.default_provider).to eq(:cursor)
      expect(config.log_level).to eq(:info)
      expect(config.fallback_providers).to eq([])
      expect(config.default_timeout).to eq(300)
    end
  end

  describe "#provider" do
    it "configures a provider" do
      config.provider(:claude) do |p|
        p.enabled = true
        p.timeout = 600
        p.models = ["claude-3-5-sonnet"]
      end

      expect(config.providers[:claude]).to be_a(AgentHarness::ProviderConfig)
      expect(config.providers[:claude].enabled).to be true
      expect(config.providers[:claude].timeout).to eq(600)
      expect(config.providers[:claude].models).to eq(["claude-3-5-sonnet"])
    end
  end

  describe "#orchestration" do
    it "configures orchestration settings" do
      config.orchestration do |orch|
        orch.enabled = false
        orch.auto_switch_on_error = false

        orch.circuit_breaker do |cb|
          cb.failure_threshold = 10
          cb.timeout = 600
        end

        orch.retry do |r|
          r.max_attempts = 5
          r.base_delay = 2.0
        end
      end

      expect(config.orchestration_config.enabled).to be false
      expect(config.orchestration_config.auto_switch_on_error).to be false
      expect(config.orchestration_config.circuit_breaker_config.failure_threshold).to eq(10)
      expect(config.orchestration_config.retry_config.max_attempts).to eq(5)
    end
  end

  describe "#register_provider" do
    it "registers a custom provider class" do
      custom_class = Class.new
      config.register_provider(:custom, custom_class)

      expect(config.custom_provider_classes[:custom]).to eq(custom_class)
    end
  end

  describe "#on_tokens_used" do
    it "registers a callback" do
      callback_called = false
      config.on_tokens_used { callback_called = true }

      config.callbacks.emit(:tokens_used, {})
      expect(callback_called).to be true
    end
  end

  describe "#on_provider_switch" do
    it "registers a callback" do
      event_data = nil
      config.on_provider_switch { |data| event_data = data }

      config.callbacks.emit(:provider_switch, {from: :claude, to: :cursor})
      expect(event_data).to eq({from: :claude, to: :cursor})
    end
  end

  describe "#validate!" do
    it "raises error when no providers configured" do
      expect { config.validate! }.to raise_error(AgentHarness::ConfigurationError, /No providers configured/)
    end

    it "raises error when default provider not configured" do
      config.provider(:claude) { |p| p.enabled = true }
      config.default_provider = :gemini

      expect { config.validate! }.to raise_error(AgentHarness::ConfigurationError, /Default provider/)
    end

    it "does not raise when properly configured" do
      config.provider(:cursor) { |p| p.enabled = true }

      expect { config.validate! }.not_to raise_error
    end
  end
end
