# frozen_string_literal: true

RSpec.describe AgentHarness::Providers::Registry do
  let(:registry) { described_class.instance }

  before do
    registry.reset!
  end

  describe ".instance" do
    it "returns a singleton instance" do
      expect(described_class.instance).to be(described_class.instance)
    end
  end

  describe "#register" do
    let(:mock_provider) do
      Class.new do
        def self.provider_name
          :test_provider
        end

        def self.available?
          true
        end

        def self.binary_name
          "test"
        end
      end
    end

    it "registers a provider class" do
      registry.register(:test, mock_provider)
      expect(registry.registered?(:test)).to be true
    end

    it "registers aliases" do
      registry.register(:test, mock_provider, aliases: [:t, :testing])
      expect(registry.registered?(:t)).to be true
      expect(registry.registered?(:testing)).to be true
    end
  end

  describe "#get" do
    it "returns registered provider class" do
      # Force registration of builtin providers
      registry.send(:ensure_builtin_providers_registered)

      # Claude/anthropic should be registered
      expect { registry.get(:claude) }.not_to raise_error
    end

    it "raises ConfigurationError for unknown provider" do
      expect {
        registry.get(:nonexistent_provider_xyz)
      }.to raise_error(AgentHarness::ConfigurationError, /Unknown provider/)
    end
  end

  describe "#all" do
    it "returns all registered provider names" do
      registry.send(:ensure_builtin_providers_registered)
      all = registry.all

      expect(all).to be_an(Array)
      expect(all).to include(:claude)
    end
  end

  describe "#available" do
    it "returns only available providers" do
      registry.send(:ensure_builtin_providers_registered)
      available = registry.available

      expect(available).to be_an(Array)
      # Available providers depend on what CLIs are installed
    end
  end

  describe "#reset!" do
    it "clears all registrations" do
      registry.send(:ensure_builtin_providers_registered)
      registry.reset!

      # After reset, builtins should not be registered yet
      expect(registry.instance_variable_get(:@builtin_registered)).to be false
    end
  end
end
