# frozen_string_literal: true

RSpec.describe AgentHarness::Orchestration::Conductor do
  let(:config) do
    AgentHarness::Configuration.new.tap do |c|
      c.default_provider = :claude
      c.fallback_providers = [:cursor]
      c.provider(:claude) { |p| p.enabled = true }
      c.provider(:cursor) { |p| p.enabled = true }

      c.orchestration do |o|
        o.enabled = true
        o.retry do |r|
          r.enabled = true
          r.max_attempts = 3
          r.base_delay = 0.01
        end
      end
    end
  end

  subject(:conductor) { described_class.new(config: config) }

  describe "#initialize" do
    it "creates provider manager" do
      expect(conductor.provider_manager).to be_a(AgentHarness::Orchestration::ProviderManager)
    end

    it "creates metrics" do
      expect(conductor.metrics).to be_a(AgentHarness::Orchestration::Metrics)
    end
  end

  describe "#status" do
    it "returns current status" do
      status = conductor.status

      expect(status).to have_key(:current_provider)
      expect(status).to have_key(:available_providers)
      expect(status).to have_key(:health)
      expect(status).to have_key(:metrics)
    end
  end

  describe "#reset!" do
    it "resets provider manager" do
      conductor.reset!
      status = conductor.status
      expect(status[:current_provider]).to eq(:claude)
    end

    it "resets metrics" do
      conductor.reset!
      expect(conductor.metrics.summary[:total_attempts]).to eq(0)
    end
  end
end
