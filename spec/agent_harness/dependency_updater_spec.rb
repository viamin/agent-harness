# frozen_string_literal: true

RSpec.describe AgentHarness::DependencyUpdater do
  let(:registry) { AgentHarness::ReleaseRegistry.new }
  let(:now) { Time.now }

  subject(:updater) { described_class.new(release_registry: registry) }

  describe "#initialize" do
    it "defaults to 3-day cooldown" do
      expect(updater.cooldown_period).to eq(3 * 24 * 60 * 60)
    end

    it "accepts custom cooldown period" do
      updater = described_class.new(cooldown_period: 3600)
      expect(updater.cooldown_period).to eq(3600)
    end

    it "creates a default release registry when none provided" do
      updater = described_class.new
      expect(updater.release_registry).to be_a(AgentHarness::ReleaseRegistry)
    end

    it "raises for non-positive cooldown" do
      expect { described_class.new(cooldown_period: 0) }.to raise_error(ArgumentError, /must be positive/)
      expect { described_class.new(cooldown_period: -1) }.to raise_error(ArgumentError, /must be positive/)
    end

    it "raises for non-numeric cooldown" do
      expect { described_class.new(cooldown_period: "1 day") }.to raise_error(ArgumentError, /must be a positive number/)
    end
  end

  describe "#cooldown_period=" do
    it "updates the global cooldown period" do
      updater.cooldown_period = 7200
      expect(updater.cooldown_period).to eq(7200)
    end

    it "validates the new value" do
      expect { updater.cooldown_period = -1 }.to raise_error(ArgumentError)
    end
  end

  describe "#set_cooldown / #cooldown_for" do
    it "sets per-provider cooldown" do
      updater.set_cooldown(:claude, 86400)
      expect(updater.cooldown_for(:claude)).to eq(86400)
    end

    it "falls back to global cooldown" do
      expect(updater.cooldown_for(:unknown)).to eq(described_class::DEFAULT_COOLDOWN_SECONDS)
    end

    it "clears a per-provider cooldown" do
      updater.set_cooldown(:claude, 86400)
      updater.clear_cooldown(:claude)
      expect(updater.cooldown_for(:claude)).to eq(described_class::DEFAULT_COOLDOWN_SECONDS)
    end
  end

  describe "#register_release" do
    it "delegates to the release registry" do
      updater.register_release(:claude, "2.1.90", released_at: now)
      expect(registry.registered?(:claude, "2.1.90")).to be true
    end
  end

  describe "#resolve_latest_version" do
    before do
      updater.cooldown_period = 86_400
    end

    it "returns nil when no versions registered" do
      expect(updater.resolve_latest_version(:claude, now: now)).to be_nil
    end

    it "returns the newest eligible version" do
      updater.register_release(:claude, "2.1.88", released_at: now - 200_000)
      updater.register_release(:claude, "2.1.90", released_at: now - 100_000)
      updater.register_release(:claude, "2.1.92", released_at: now - 87_000)

      result = updater.resolve_latest_version(:claude, now: now)
      expect(result[:version]).to eq("2.1.92")
    end

    it "excludes versions still in cooldown" do
      updater.register_release(:claude, "2.1.90", released_at: now - 200_000)
      updater.register_release(:claude, "2.1.92", released_at: now - 10)

      result = updater.resolve_latest_version(:claude, now: now)
      expect(result[:version]).to eq("2.1.90")
    end

    it "returns nil when all versions are in cooldown" do
      updater.register_release(:claude, "2.1.92", released_at: now - 10)

      result = updater.resolve_latest_version(:claude, now: now)
      expect(result).to be_nil
    end

    it "bypasses cooldown when requested" do
      updater.register_release(:claude, "2.1.92", released_at: now - 10)

      result = updater.resolve_latest_version(:claude, bypass_cooldown: true, now: now)
      expect(result[:version]).to eq("2.1.92")
    end

    it "respects per-provider cooldown" do
      updater.set_cooldown(:claude, 3600)
      updater.register_release(:claude, "2.1.90", released_at: now - 7200)
      updater.register_release(:claude, "2.1.92", released_at: now - 5000)

      result = updater.resolve_latest_version(:claude, now: now)
      expect(result[:version]).to eq("2.1.92")
    end

    it "includes versions with nil released_at (always eligible)" do
      registry.register(:claude, "2.1.92")
      allow(registry).to receive(:versions_for).and_return(
        [{version: "2.1.92", released_at: nil}]
      )

      result = updater.resolve_latest_version(:claude, now: now)
      expect(result[:version]).to eq("2.1.92")
    end
  end

  describe "#eligible?" do
    before do
      updater.cooldown_period = 86_400
    end

    it "returns true when version is past cooldown" do
      updater.register_release(:claude, "2.1.90", released_at: now - 100_000)
      expect(updater.eligible?(:claude, "2.1.90", now: now)).to be true
    end

    it "returns false when version is in cooldown" do
      updater.register_release(:claude, "2.1.92", released_at: now - 10)
      expect(updater.eligible?(:claude, "2.1.92", now: now)).to be false
    end

    it "returns true when bypass_cooldown is set" do
      updater.register_release(:claude, "2.1.92", released_at: now - 10)
      expect(updater.eligible?(:claude, "2.1.92", bypass_cooldown: true, now: now)).to be true
    end

    it "returns true for unknown version (no release date tracked)" do
      expect(updater.eligible?(:claude, "9.9.9", now: now)).to be true
    end
  end

  describe "#resolve_latest_installation_contract" do
    it "returns version info with installation contract" do
      updater.register_release(:codex, "0.116.0", released_at: now - 200_000)
      updater.cooldown_period = 86_400

      result = updater.resolve_latest_installation_contract(:codex, now: now)
      expect(result).not_to be_nil
      expect(result[:provider]).to eq(:codex)
      expect(result[:version]).to eq("0.116.0")
      expect(result[:installation_contract]).not_to be_nil
    end

    it "returns nil installation_contract for provider without one" do
      updater.register_release(:nonexistent_provider, "1.0.0", released_at: now - 200_000)
      updater.cooldown_period = 86_400

      result = updater.resolve_latest_installation_contract(:nonexistent_provider, now: now)
      expect(result[:provider]).to eq(:nonexistent_provider)
      expect(result[:installation_contract]).to be_nil
    end

    it "returns nil when no eligible version exists" do
      updater.register_release(:codex, "0.116.0", released_at: now - 10)
      updater.cooldown_period = 86_400

      result = updater.resolve_latest_installation_contract(:codex, now: now)
      expect(result).to be_nil
    end
  end

  describe "#resolve_all_latest" do
    it "resolves latest versions for all registered providers" do
      updater.cooldown_period = 86_400
      updater.register_release(:claude, "2.1.90", released_at: now - 200_000)
      updater.register_release(:codex, "0.116.0", released_at: now - 200_000)

      results = updater.resolve_all_latest(now: now)
      expect(results.keys).to contain_exactly(:claude, :codex)
      expect(results[:claude][:version]).to eq("2.1.90")
      expect(results[:codex][:version]).to eq("0.116.0")
    end

    it "omits providers with no eligible versions" do
      updater.cooldown_period = 86_400
      updater.register_release(:claude, "2.1.92", released_at: now - 10)

      results = updater.resolve_all_latest(now: now)
      expect(results).to be_empty
    end
  end
end
