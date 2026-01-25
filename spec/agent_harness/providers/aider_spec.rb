# frozen_string_literal: true

RSpec.describe AgentHarness::Providers::Aider do
  describe ".provider_name" do
    it "returns :aider" do
      expect(described_class.provider_name).to eq(:aider)
    end
  end

  describe ".binary_name" do
    it "returns aider" do
      expect(described_class.binary_name).to eq("aider")
    end
  end

  describe ".firewall_requirements" do
    it "returns required domains" do
      requirements = described_class.firewall_requirements
      expect(requirements[:domains]).to include("api.openai.com")
      expect(requirements[:domains]).to include("api.anthropic.com")
    end
  end

  describe ".instruction_file_paths" do
    it "returns aider config" do
      paths = described_class.instruction_file_paths
      expect(paths.first[:path]).to eq(".aider.conf.yml")
    end
  end

  describe "instance" do
    subject(:provider) { described_class.new }

    describe "#name" do
      it "returns aider" do
        expect(provider.name).to eq("aider")
      end
    end

    describe "#display_name" do
      it "returns Aider" do
        expect(provider.display_name).to eq("Aider")
      end
    end

    describe "#capabilities" do
      it "includes streaming" do
        expect(provider.capabilities[:streaming]).to be true
      end
    end

    describe "#supports_sessions?" do
      it "returns true" do
        expect(provider.supports_sessions?).to be true
      end
    end

    describe "#session_flags" do
      it "returns restore flags when session provided" do
        flags = provider.session_flags("session-123")
        expect(flags).to eq(["--restore-chat-history", "session-123"])
      end
    end
  end
end
