# frozen_string_literal: true

RSpec.describe AgentHarness::Response do
  describe "#initialize" do
    it "sets all attributes" do
      response = described_class.new(
        output: "Hello!",
        exit_code: 0,
        duration: 1.5,
        provider: :claude,
        model: "claude-3-5-sonnet",
        tokens: {input: 100, output: 50, total: 150},
        metadata: {key: "value"},
        error: nil
      )

      expect(response.output).to eq("Hello!")
      expect(response.exit_code).to eq(0)
      expect(response.duration).to eq(1.5)
      expect(response.provider).to eq(:claude)
      expect(response.model).to eq("claude-3-5-sonnet")
      expect(response.tokens).to eq({input: 100, output: 50, total: 150})
      expect(response.metadata).to eq({key: "value"})
      expect(response.error).to be_nil
    end
  end

  describe "#success?" do
    it "returns true when exit_code is 0 and no error" do
      response = described_class.new(
        output: "ok", exit_code: 0, duration: 1.0, provider: :claude
      )
      expect(response.success?).to be true
    end

    it "returns false when exit_code is non-zero" do
      response = described_class.new(
        output: "error", exit_code: 1, duration: 1.0, provider: :claude
      )
      expect(response.success?).to be false
    end

    it "returns false when there is an error" do
      response = described_class.new(
        output: "error", exit_code: 0, duration: 1.0, provider: :claude, error: "Something went wrong"
      )
      expect(response.success?).to be false
    end
  end

  describe "#failed?" do
    it "returns true when not successful" do
      response = described_class.new(
        output: "error", exit_code: 1, duration: 1.0, provider: :claude
      )
      expect(response.failed?).to be true
    end

    it "returns false when successful" do
      response = described_class.new(
        output: "ok", exit_code: 0, duration: 1.0, provider: :claude
      )
      expect(response.failed?).to be false
    end
  end

  describe "token accessors" do
    let(:response) do
      described_class.new(
        output: "ok",
        exit_code: 0,
        duration: 1.0,
        provider: :claude,
        tokens: {input: 100, output: 50, total: 150}
      )
    end

    it "returns total_tokens" do
      expect(response.total_tokens).to eq(150)
    end

    it "returns input_tokens" do
      expect(response.input_tokens).to eq(100)
    end

    it "returns output_tokens" do
      expect(response.output_tokens).to eq(50)
    end

    it "returns nil when tokens not set" do
      response = described_class.new(
        output: "ok", exit_code: 0, duration: 1.0, provider: :claude
      )
      expect(response.total_tokens).to be_nil
    end
  end

  describe "#to_h" do
    it "returns a hash representation" do
      response = described_class.new(
        output: "Hello!",
        exit_code: 0,
        duration: 1.5,
        provider: :claude,
        model: "sonnet"
      )

      hash = response.to_h

      expect(hash[:output]).to eq("Hello!")
      expect(hash[:exit_code]).to eq(0)
      expect(hash[:duration]).to eq(1.5)
      expect(hash[:provider]).to eq(:claude)
      expect(hash[:model]).to eq("sonnet")
      expect(hash[:success]).to be true
    end
  end

  describe "#inspect" do
    it "returns a debug string" do
      response = described_class.new(
        output: "ok", exit_code: 0, duration: 1.234, provider: :claude
      )

      expect(response.inspect).to include("AgentHarness::Response")
      expect(response.inspect).to include("provider=claude")
      expect(response.inspect).to include("success=true")
    end
  end
end
