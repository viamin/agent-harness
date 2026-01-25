# frozen_string_literal: true

RSpec.describe AgentHarness::Providers::Base do
  # Create a minimal test provider
  let(:test_provider_class) do
    Class.new(described_class) do
      class << self
        def provider_name
          :test_provider
        end

        def binary_name
          "test-cli"
        end

        def available?
          false # Not actually installed
        end
      end

      def name
        "test_provider"
      end

      protected

      def build_command(prompt, options)
        ["echo", prompt]
      end
    end
  end

  let(:provider) { test_provider_class.new }

  describe "#initialize" do
    it "sets up default configuration" do
      expect(provider.config).to be_a(AgentHarness::ProviderConfig)
    end

    it "accepts custom config" do
      config = AgentHarness::ProviderConfig.new(:test)
      config.timeout = 600

      provider = test_provider_class.new(config: config)
      expect(provider.config.timeout).to eq(600)
    end
  end

  describe "#configure" do
    it "merges options into config" do
      provider.configure(timeout: 999, model: "test-model")

      expect(provider.config.timeout).to eq(999)
      expect(provider.config.model).to eq("test-model")
    end

    it "returns self for chaining" do
      result = provider.configure(timeout: 100)
      expect(result).to be(provider)
    end
  end

  describe "#name" do
    it "returns provider name" do
      expect(provider.name).to eq("test_provider")
    end
  end

  describe "#display_name" do
    it "returns capitalized name by default" do
      expect(provider.display_name).to eq("Test_provider")
    end
  end

  describe "#capabilities" do
    it "returns default capabilities" do
      caps = provider.capabilities

      expect(caps).to be_a(Hash)
      expect(caps).to have_key(:streaming)
      expect(caps).to have_key(:mcp)
    end
  end

  describe "#error_patterns" do
    it "returns empty hash by default" do
      expect(provider.error_patterns).to eq({})
    end
  end
end
