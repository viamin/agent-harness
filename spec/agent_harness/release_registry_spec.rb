# frozen_string_literal: true

RSpec.describe AgentHarness::ReleaseRegistry do
  subject(:registry) { described_class.new }

  describe "#register" do
    it "registers a version release with timestamp" do
      time = Time.now
      entry = registry.register(:claude, "2.1.90", released_at: time)

      expect(entry[:version]).to eq("2.1.90")
      expect(entry[:released_at]).to eq(time)
    end

    it "converts provider name to symbol" do
      registry.register("claude", "2.1.90")
      expect(registry.registered?("claude", "2.1.90")).to be true
    end

    it "converts version to string" do
      registry.register(:claude, :latest)
      expect(registry.registered?(:claude, "latest")).to be true
    end

    it "raises for empty version" do
      expect { registry.register(:claude, "") }.to raise_error(ArgumentError, /non-empty string/)
    end

    it "raises for non-Time released_at" do
      expect { registry.register(:claude, "1.0", released_at: "2025-01-01") }.to raise_error(ArgumentError, /must be a Time/)
    end

    it "defaults released_at to Time.now" do
      before_register = Time.now
      registry.register(:claude, "1.0")
      after_register = Time.now

      released = registry.released_at(:claude, "1.0")
      expect(released).to be_between(before_register, after_register)
    end

    it "updates existing version entry" do
      old_time = Time.now - 100
      new_time = Time.now
      registry.register(:claude, "2.1.90", released_at: old_time)
      registry.register(:claude, "2.1.90", released_at: new_time)

      expect(registry.released_at(:claude, "2.1.90")).to eq(new_time)
    end
  end

  describe "#versions_for" do
    it "returns versions for a registered provider" do
      registry.register(:claude, "2.1.88", released_at: Time.now - 200_000)
      registry.register(:claude, "2.1.90", released_at: Time.now - 100_000)

      versions = registry.versions_for(:claude)
      expect(versions.size).to eq(2)
      expect(versions.map { |v| v[:version] }).to contain_exactly("2.1.88", "2.1.90")
    end

    it "returns nil for unregistered provider" do
      expect(registry.versions_for(:nonexistent)).to be_nil
    end

    it "returns a copy of the entries" do
      registry.register(:claude, "1.0")
      versions = registry.versions_for(:claude)
      versions.clear

      expect(registry.versions_for(:claude).size).to eq(1)
    end
  end

  describe "#released_at" do
    it "returns release time for a known version" do
      time = Time.now - 50_000
      registry.register(:claude, "2.1.90", released_at: time)

      expect(registry.released_at(:claude, "2.1.90")).to eq(time)
    end

    it "returns nil for unknown version" do
      registry.register(:claude, "2.1.90")
      expect(registry.released_at(:claude, "2.1.91")).to be_nil
    end

    it "returns nil for unknown provider" do
      expect(registry.released_at(:nonexistent, "1.0")).to be_nil
    end
  end

  describe "#registered?" do
    it "returns true for registered version" do
      registry.register(:claude, "2.1.90")
      expect(registry.registered?(:claude, "2.1.90")).to be true
    end

    it "returns false for unregistered version" do
      expect(registry.registered?(:claude, "9.9.9")).to be false
    end
  end

  describe "#providers" do
    it "lists registered providers" do
      registry.register(:claude, "1.0")
      registry.register(:codex, "0.1")

      expect(registry.providers).to contain_exactly(:claude, :codex)
    end
  end

  describe "#clear" do
    it "removes all entries" do
      registry.register(:claude, "1.0")
      registry.clear
      expect(registry.providers).to be_empty
    end
  end

  describe "#clear_provider" do
    it "removes entries for a specific provider" do
      registry.register(:claude, "1.0")
      registry.register(:codex, "0.1")
      registry.clear_provider(:claude)

      expect(registry.providers).to eq([:codex])
    end
  end

  describe "#merge!" do
    it "merges entries from another registry" do
      other = described_class.new
      other.register(:claude, "2.1.90", released_at: Time.now - 50_000)
      other.register(:codex, "0.100", released_at: Time.now - 30_000)

      registry.register(:claude, "2.1.88", released_at: Time.now - 100_000)
      registry.merge!(other)

      expect(registry.registered?(:claude, "2.1.88")).to be true
      expect(registry.registered?(:claude, "2.1.90")).to be true
      expect(registry.registered?(:codex, "0.100")).to be true
    end

    it "overwrites existing entries on merge" do
      old_time = Time.now - 100_000
      new_time = Time.now - 10_000

      registry.register(:claude, "2.1.90", released_at: old_time)
      other = described_class.new
      other.register(:claude, "2.1.90", released_at: new_time)
      registry.merge!(other)

      expect(registry.released_at(:claude, "2.1.90")).to eq(new_time)
    end
  end
end
