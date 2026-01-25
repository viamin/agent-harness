# frozen_string_literal: true

RSpec.describe AgentHarness do
  it "has a version number" do
    expect(AgentHarness::VERSION).not_to be_nil
  end

  describe ".configuration" do
    it "returns a Configuration instance" do
      expect(AgentHarness.configuration).to be_a(AgentHarness::Configuration)
    end

    it "returns the same instance on subsequent calls" do
      config1 = AgentHarness.configuration
      config2 = AgentHarness.configuration
      expect(config1).to be(config2)
    end
  end

  describe ".configure" do
    it "yields the configuration" do
      AgentHarness.configure do |config|
        config.default_provider = :claude
        config.log_level = :debug
      end

      expect(AgentHarness.configuration.default_provider).to eq(:claude)
      expect(AgentHarness.configuration.log_level).to eq(:debug)
    end
  end

  describe ".reset!" do
    it "resets configuration to defaults" do
      AgentHarness.configure do |config|
        config.default_provider = :claude
      end

      AgentHarness.reset!

      expect(AgentHarness.configuration.default_provider).to eq(:cursor)
    end
  end

  describe ".token_tracker" do
    it "returns a TokenTracker instance" do
      expect(AgentHarness.token_tracker).to be_a(AgentHarness::TokenTracker)
    end
  end
end
