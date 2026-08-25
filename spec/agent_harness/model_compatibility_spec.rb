# frozen_string_literal: true

RSpec.describe AgentHarness::ModelCompatibility do
  describe ".build_result" do
    it "returns a Result with normalized model_id and default source" do
      result = described_class.build_result(
        runner: :codex,
        model_id: :"gpt-5.5",
        supported: true,
        auth_mode: :subscription,
        cli_version: "0.149.1"
      )

      expect(result).to be_a(described_class::Result)
      expect(result.runner).to eq(:codex)
      expect(result.model_id).to eq("gpt-5.5")
      expect(result.supported).to be(true)
      expect(result.supported?).to be(true)
      expect(result.reason).to eq(described_class::SUPPORTED_REASON)
      expect(result.source).to eq(:static_contract)
    end

    it "defaults reason to :unknown when supported is nil" do
      result = described_class.build_result(runner: :codex, model_id: "x")

      expect(result.reason).to eq(described_class::UNKNOWN_REASON)
      expect(result.unknown?).to be(true)
    end

    it "raises ArgumentError when supported: false is passed without an explicit reason" do
      # Guards against collapsing unsupported into :unknown — the contract
      # requires a specific reason (e.g. :cli_version_too_old) so callers can
      # branch on it rather than on parsed error strings.
      expect {
        described_class.build_result(runner: :codex, model_id: "x", supported: false)
      }.to raise_error(ArgumentError, /requires an explicit `reason:`/)
    end
  end

  describe ".unknown_result" do
    it "returns an unknown result with :unknown source" do
      result = described_class.unknown_result(
        runner: :codex,
        model_id: "mystery",
        fallback_model_id: "gpt-5-codex"
      )

      expect(result.unknown?).to be(true)
      expect(result.supported).to be_nil
      expect(result.fallback_model_id).to eq("gpt-5-codex")
      expect(result.source).to eq(:unknown)
    end
  end

  describe "Result" do
    it "exposes supported?, unsupported?, and unknown? predicates" do
      supported = described_class.build_result(runner: :codex, model_id: "x", supported: true)
      unsupported = described_class.build_result(runner: :codex, model_id: "x", supported: false, reason: :cli_version_too_old)
      unknown = described_class.build_result(runner: :codex, model_id: "x")

      expect(supported.supported?).to be(true)
      expect(unsupported.unsupported?).to be(true)
      expect(unknown.unknown?).to be(true)
    end

    it "#to_h drops nil entries so callers can serialize compactly" do
      result = described_class.build_result(runner: :codex, model_id: "x", supported: true)

      expect(result.to_h.keys).to include(:runner, :model_id, :supported, :reason, :source)
      expect(result.to_h.values).not_to include(nil)
    end
  end
end
