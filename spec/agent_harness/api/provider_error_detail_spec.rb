# frozen_string_literal: true

require "spec_helper"

RSpec.describe AgentHarness::Api::ProviderErrorDetail do
  def detail_for(message)
    described_class.call(StandardError.new(message))
  end

  it "keeps redaction markers whole when truncation splits them" do
    detail = detail_for("#{"x" * 995} Authorization: very-secret-token-value")

    expect(detail).to end_with("[REDACTED]")
    expect(detail).not_to include("very-secret")
    expect(detail.length).to be <= described_class::MAX_LENGTH + 13
  end

  it "keeps redacted URL markers whole when truncation splits them" do
    detail = detail_for("#{"y" * 989} https://tenant.example/secret-path")

    expect(detail).to end_with("[REDACTED URL]")
    expect(detail).not_to include("tenant.example")
    expect(detail.length).to be <= described_class::MAX_LENGTH + 13
  end

  it "emits at most one trailing redaction marker past the limit" do
    detail = detail_for("#{"z" * 986} api_key=shhh-1234567890 https://a.example/x https://b.example/y")

    expect(detail.scan("[").count).to eq(detail.scan("]").count)
    expect(detail).to end_with("]")
  end

  it "truncates without extending when the boundary falls between markers" do
    detail = detail_for("#{"a" * 950} Authorization: token-1 keep listening b" * 3)

    expect(detail.length).to be <= described_class::MAX_LENGTH + 13
    expect(detail).not_to match(/\[REDACTED[^\]]*\z/)
  end
end
