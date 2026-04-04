# frozen_string_literal: true

RSpec.describe AgentHarness::ExecutionPreparation do
  describe ".new" do
    it "accepts file write hashes" do
      preparation = described_class.new(
        file_writes: [
          {
            path: "/tmp/config.json",
            content: "{\"hello\":\"world\"}",
            mode: 0o600
          }
        ]
      )

      expect(preparation.file_writes.length).to eq(1)
      expect(preparation.file_writes.first.path).to eq("/tmp/config.json")
      expect(preparation.file_writes.first.content).to eq("{\"hello\":\"world\"}")
      expect(preparation.file_writes.first.mode).to eq(0o600)
    end

    it "defaults to an empty list" do
      preparation = described_class.new

      expect(preparation.file_writes).to eq([])
      expect(preparation).to be_empty
    end

    it "freezes file writes" do
      preparation = described_class.new(
        file_writes: [{path: "/tmp/config.json", content: "{}", mode: 0o600}]
      )

      expect(preparation).to be_frozen
      expect(preparation.file_writes).to be_frozen
      expect(preparation.file_writes.first).to be_frozen
    end

    it "raises for invalid file write entries" do
      expect {
        described_class.new(file_writes: ["bad"])
      }.to raise_error(ArgumentError, /file_writes must contain FileWrite or Hash entries/)
    end
  end

  describe AgentHarness::ExecutionPreparation::FileWrite do
    it "requires a non-empty path" do
      expect {
        described_class.new(path: "", content: "{}")
      }.to raise_error(ArgumentError, /path must be a non-empty String/)
    end

    it "requires string content" do
      expect {
        described_class.new(path: "/tmp/config.json", content: {foo: "bar"})
      }.to raise_error(ArgumentError, /content must be a String/)
    end

    it "requires integer mode when provided" do
      expect {
        described_class.new(path: "/tmp/config.json", content: "{}", mode: "600")
      }.to raise_error(ArgumentError, /mode must be an Integer or nil/)
    end
  end
end
