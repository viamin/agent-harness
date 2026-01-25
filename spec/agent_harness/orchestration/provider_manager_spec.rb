# frozen_string_literal: true

RSpec.describe AgentHarness::Orchestration::ProviderManager do
  let(:config) do
    AgentHarness::Configuration.new.tap do |c|
      c.default_provider = :claude
      c.fallback_providers = [:cursor]
      c.provider(:claude) { |p| p.enabled = true }
      c.provider(:cursor) { |p| p.enabled = true }
    end
  end

  subject(:manager) { described_class.new(config) }

  describe "#initialize" do
    it "sets up circuit breakers for each provider" do
      expect(manager.circuit_open?(:claude)).to be false
      expect(manager.circuit_open?(:cursor)).to be false
    end

    it "sets current provider to default" do
      expect(manager.current_provider).to eq(:claude)
    end
  end

  describe "#select_provider" do
    context "when preferred provider is healthy" do
      before do
        allow_any_instance_of(AgentHarness::Providers::Registry).to receive(:get).and_return(
          Class.new(AgentHarness::Providers::Base) do
            def self.provider_name
              :claude
            end

            def self.binary_name
              "claude"
            end

            def self.available?
              true
            end
          end
        )
      end

      it "returns the preferred provider" do
        provider = manager.select_provider(:claude)
        expect(provider).to be_a(AgentHarness::Providers::Base)
      end
    end

    context "when preferred provider circuit is open" do
      before do
        # Open all circuits by recording failures for all configured providers
        5.times { manager.record_failure(:claude) }
        5.times { manager.record_failure(:cursor) }
      end

      it "raises NoProvidersAvailableError when all providers are unavailable" do
        expect(manager.circuit_open?(:claude)).to be true
        expect(manager.circuit_open?(:cursor)).to be true
        expect { manager.select_provider(:claude) }.to raise_error(AgentHarness::NoProvidersAvailableError)
      end
    end
  end

  describe "#get_provider" do
    before do
      allow_any_instance_of(AgentHarness::Providers::Registry).to receive(:get).and_return(
        Class.new(AgentHarness::Providers::Base) do
          def self.provider_name
            :claude
          end

          def self.binary_name
            "claude"
          end

          def self.available?
            true
          end
        end
      )
    end

    it "returns provider instance" do
      provider = manager.get_provider(:claude)
      expect(provider).to be_a(AgentHarness::Providers::Base)
    end

    it "caches provider instances" do
      provider1 = manager.get_provider(:claude)
      provider2 = manager.get_provider(:claude)
      expect(provider1).to be(provider2)
    end
  end

  describe "#record_success" do
    it "records success in health monitor" do
      manager.record_success(:claude)
      expect(manager.healthy?(:claude)).to be true
    end

    it "records success in circuit breaker" do
      manager.record_success(:claude)
      expect(manager.circuit_open?(:claude)).to be false
    end
  end

  describe "#record_failure" do
    it "records failure in health monitor" do
      5.times { manager.record_failure(:claude) }
      # After many failures, health may degrade
    end

    it "can open circuit after threshold" do
      5.times { manager.record_failure(:claude) }
      expect(manager.circuit_open?(:claude)).to be true
    end
  end

  describe "#mark_rate_limited" do
    it "marks provider as rate limited" do
      reset_time = Time.now + 3600
      manager.mark_rate_limited(:claude, reset_at: reset_time)
      expect(manager.rate_limited?(:claude)).to be true
    end
  end

  describe "#available_providers" do
    it "returns providers that are healthy and not limited" do
      available = manager.available_providers
      expect(available).to be_an(Array)
    end
  end

  describe "#health_status" do
    it "returns health status for all providers" do
      status = manager.health_status
      expect(status).to be_an(Array)
    end
  end

  describe "#reset!" do
    it "resets all state" do
      5.times { manager.record_failure(:claude) }
      manager.reset!

      expect(manager.circuit_open?(:claude)).to be false
      expect(manager.current_provider).to eq(:claude)
    end
  end

  describe "#circuit_open?" do
    it "returns false initially" do
      expect(manager.circuit_open?(:claude)).to be false
    end

    it "returns true after failures exceed threshold" do
      5.times { manager.record_failure(:claude) }
      expect(manager.circuit_open?(:claude)).to be true
    end
  end

  describe "#rate_limited?" do
    it "returns false initially" do
      expect(manager.rate_limited?(:claude)).to be false
    end

    it "returns true after being marked" do
      manager.mark_rate_limited(:claude)
      expect(manager.rate_limited?(:claude)).to be true
    end
  end

  describe "#healthy?" do
    it "returns true initially" do
      expect(manager.healthy?(:claude)).to be true
    end
  end

  describe "#switch_provider" do
    let(:cursor_class) do
      Class.new(AgentHarness::Providers::Base) do
        def self.provider_name
          :cursor
        end

        def self.binary_name
          "cursor"
        end

        def self.available?
          true
        end
      end
    end

    before do
      allow_any_instance_of(AgentHarness::Providers::Registry).to receive(:get).and_return(cursor_class)
    end

    it "switches to a fallback provider" do
      # Mark claude as having an issue
      5.times { manager.record_failure(:claude) }

      result = manager.switch_provider(reason: :circuit_open)
      expect(result).to be_a(AgentHarness::Providers::Base)
      expect(manager.current_provider).to eq(:cursor)
    end

    it "raises error when no fallback is available" do
      5.times { manager.record_failure(:claude) }
      5.times { manager.record_failure(:cursor) }

      expect { manager.switch_provider(reason: :all_failed, context: {}) }
        .to raise_error(AgentHarness::NoProvidersAvailableError)
    end
  end

  describe "#select_provider with fallback" do
    let(:cursor_class) do
      Class.new(AgentHarness::Providers::Base) do
        def self.provider_name
          :cursor
        end

        def self.binary_name
          "cursor"
        end

        def self.available?
          true
        end
      end
    end

    before do
      allow_any_instance_of(AgentHarness::Providers::Registry).to receive(:get).and_return(cursor_class)
    end

    context "when preferred provider is rate limited" do
      before do
        manager.mark_rate_limited(:claude, reset_at: Time.now + 3600)
      end

      it "falls back to another provider" do
        provider = manager.select_provider(:claude)
        expect(provider).to be_a(AgentHarness::Providers::Base)
      end
    end

    context "when all providers are rate limited" do
      before do
        manager.mark_rate_limited(:claude)
        manager.mark_rate_limited(:cursor)
      end

      it "raises NoProvidersAvailableError" do
        expect { manager.select_provider(:claude) }.to raise_error(AgentHarness::NoProvidersAvailableError)
      end
    end
  end
end
