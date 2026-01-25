# frozen_string_literal: true

RSpec.describe AgentHarness::ProviderConfig do
  subject(:config) { described_class.new(:claude) }

  describe "#initialize" do
    it "sets name" do
      expect(config.name).to eq(:claude)
    end

    it "sets defaults" do
      expect(config.enabled).to be true
      expect(config.type).to eq(:usage_based)
      expect(config.priority).to eq(10)
      expect(config.models).to eq([])
      expect(config.default_flags).to eq([])
    end
  end

  describe "#merge!" do
    it "merges options into config" do
      config.merge!(enabled: false, timeout: 600, model: "sonnet")

      expect(config.enabled).to be false
      expect(config.timeout).to eq(600)
      expect(config.model).to eq("sonnet")
    end

    it "returns self" do
      result = config.merge!(enabled: false)
      expect(result).to be(config)
    end

    it "ignores unknown options" do
      expect { config.merge!(unknown_option: "value") }.not_to raise_error
    end
  end
end
