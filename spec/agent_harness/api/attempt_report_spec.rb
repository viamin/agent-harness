# frozen_string_literal: true

require "spec_helper"

RSpec.describe AgentHarness::Api::AttemptReport do
  let(:attributes) do
    {
      attempt_id: "attempt-1", request_id: "request-1", number: 1,
      provider: :anthropic, model: "claude-test", status: :succeeded,
      started_at: "2026-09-25T12:00:00.000000Z", finished_at: "2026-09-25T12:00:01.000000Z",
      usage: {input_tokens: 0, output_tokens: 2},
      cost: {input: 0.0, output: 0.00002, total: 0.00002, currency: "USD",
             source: :estimated, priced_at: "2026-09-25T12:00:01.000000Z"},
      provider_reported: true, error: nil
    }
  end

  it "preserves unknown counts separately from reported zeroes" do
    usage = described_class.new(**attributes).to_h.fetch(:usage)

    expect(usage).to include(input_tokens: 0, output_tokens: 2)
    expect(usage[:cache_read_tokens]).to be_nil
  end

  it "round trips persisted pricing without recalculation" do
    stored = JSON.parse(JSON.generate(described_class.new(**attributes).to_h))
    restored = described_class.from_h(stored).to_h

    expect(restored[:cost]).to include(total: 0.00002, source: :estimated,
      priced_at: "2026-09-25T12:00:01.000000Z")
  end

  it "keeps the same deduplication identity across repeated restoration" do
    stored = described_class.new(**attributes).to_h

    expect([described_class.from_h(stored), described_class.from_h(stored)]
      .map { |report| report.to_h[:attempt_id] }).to eq(%w[attempt-1 attempt-1])
  end
end
