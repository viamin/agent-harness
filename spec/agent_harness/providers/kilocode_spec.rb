# frozen_string_literal: true

RSpec.describe AgentHarness::Providers::Kilocode do
  describe ".provider_name" do
    it "returns :kilocode" do
      expect(described_class.provider_name).to eq(:kilocode)
    end
  end

  describe ".binary_name" do
    it "returns kilocode" do
      expect(described_class.binary_name).to eq("kilocode")
    end
  end

  describe ".firewall_requirements" do
    it "returns empty arrays" do
      requirements = described_class.firewall_requirements
      expect(requirements[:domains]).to eq([])
      expect(requirements[:ip_ranges]).to eq([])
    end
  end

  describe ".instruction_file_paths" do
    it "returns empty array" do
      expect(described_class.instruction_file_paths).to eq([])
    end
  end

  describe ".discover_models" do
    it "returns empty when not available" do
      allow(described_class).to receive(:available?).and_return(false)
      expect(described_class.discover_models).to eq([])
    end
  end

  describe "instance" do
    subject(:provider) { described_class.new }

    describe "#name" do
      it "returns kilocode" do
        expect(provider.name).to eq("kilocode")
      end
    end

    describe "#display_name" do
      it "returns Kilocode CLI" do
        expect(provider.display_name).to eq("Kilocode CLI")
      end
    end

    describe "#capabilities" do
      it "returns minimal capabilities" do
        caps = provider.capabilities
        expect(caps[:streaming]).to be false
        expect(caps[:mcp]).to be false
        expect(caps[:dangerous_mode]).to be false
      end
    end
  end
end
