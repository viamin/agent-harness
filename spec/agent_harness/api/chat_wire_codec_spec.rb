# frozen_string_literal: true

require "spec_helper"

RSpec.describe AgentHarness::Api::ChatWireCodec do
  let(:attempt) do
    AgentHarness::Api::AttemptReport.new(
      attempt_id: "attempt-1", request_id: "request-1", number: 1,
      provider: :openai, model: "gpt-test", status: :succeeded,
      started_at: "2026-11-20T10:00:00.000000Z", finished_at: "2026-11-20T10:00:01.000000Z",
      usage: {input_tokens: 0, output_tokens: nil, total_tokens: nil},
      cost: {input: 0.0, total: 0.0, currency: "USD", source: :provider_reported,
             priced_at: "2026-11-20T10:00:01.000000Z"},
      provider_reported: true, error: nil
    ).to_h
  end

  let(:result) do
    {
      request_id: "request-1", provider: :openai, model: "gpt-test", protocol: :responses,
      authentication_mode: :api_key, status: :succeeded, content: "done",
      parsed: {"status" => "completed", "type" => "text_delta"},
      tool_calls: [
        {id: "tool-1", provider_id: "provider-call-1", name: "lookup",
         arguments_json: "{\"status\":\"completed\",\"type\":\"text_delta\"}", status: :completed},
        {id: "tool-2", provider_id: nil, name: "unfinished", arguments_json: "{\"x\":", status: :incomplete}
      ],
      provider_state: {"protocol" => "responses", "continuation" => {"status" => "completed"}},
      finish_reason: :tool_calls, usage: {input_tokens: 0, output_tokens: nil}, error: nil,
      attempts: [attempt], provider_request_id: "provider-request-1"
    }
  end

  it "round trips successful, partial, failed, and cancelled results with semantic parity" do
    variants = {
      succeeded: result,
      partial: result.merge(status: :partial, error: error(:transient, :service_unavailable, retry_after_seconds: 1.25)),
      failed: result.merge(status: :failed, content: "", error: error(:invalid_request, :invalid_request)),
      cancelled: result.merge(status: :cancelled, content: "", error: error(:cancelled, :cancelled))
    }

    variants.each_value do |value|
      expect(described_class.load_result(described_class.dump_result(value))).to eq(value)
    end
  end

  it "round trips every emitted event kind with identities, order, attempts, and terminal results" do
    common = {request_id: "request-1", attempt_id: "attempt-1"}
    events = [
      common.merge(type: :response_started, sequence: 1,
        candidate: {provider: :openai, model: "gpt-test", protocol: :responses, authentication_mode: :api_key}),
      common.merge(type: :text_delta, sequence: 2, content: "hello"),
      common.merge(type: :tool_call_started, sequence: 3, id: "tool-1", provider_id: "provider-call-1", name: "lookup"),
      common.merge(type: :tool_call_delta, sequence: 4, id: "tool-1", provider_id: "provider-call-1", arguments_json: "{\"x\":"),
      common.merge(type: :tool_call_completed, sequence: 5, id: "tool-1", provider_id: "provider-call-1", name: "lookup", arguments_json: "{\"x\":1}"),
      common.merge(type: :usage_updated, sequence: 6, input_tokens: 0, output_tokens: nil, total_tokens: nil),
      common.merge(type: :attempt_completed, sequence: 7, attempt: attempt),
      common.merge(type: :fallback_selected, sequence: 8,
        from: {provider: :openai, model: "old", protocol: :responses, authentication_mode: :api_key},
        to: {provider: :anthropic, model: "new", protocol: :messages, authentication_mode: :api_key},
        error: error(:transient, :overloaded, retry_after_seconds: 0.5)),
      common.merge(type: :response_completed, sequence: 9, result: result),
      common.merge(type: :response_failed, sequence: 10, result: result.merge(status: :failed,
        error: error(:invalid_response, :invalid_tool_arguments))),
      common.merge(type: :response_cancelled, sequence: 11, result: result.merge(status: :cancelled,
        error: error(:cancelled, :cancelled)))
    ]

    restored = events.map { |event| described_class.load_event(described_class.dump_event(event)) }

    expect(restored).to eq(events)
    expect(restored.map { |event| event[:sequence] }).to eq((1..11).to_a)
  end

  it "does not reinterpret enum-looking strings inside parsed values or opaque provider state" do
    restored = described_class.load_result(described_class.dump_result(result))

    expect(restored[:parsed]).to eq("status" => "completed", "type" => "text_delta")
    expect(restored[:provider_state]).to eq("protocol" => "responses",
      "continuation" => {"status" => "completed"})
    expect(restored[:tool_calls].first[:arguments_json]).to eq(result[:tool_calls].first[:arguments_json])
  end

  it "rejects invalid versions, kinds, enums, shapes, excessive input, and excessive nesting safely" do
    invalid = [
      JSON.generate(version: 2, kind: "result", payload: result),
      JSON.generate(version: 1, kind: "event", payload: {type: "invented", request_id: "r", attempt_id: "a", sequence: 1}),
      JSON.generate(version: 1, kind: "result", payload: result.merge(status: "invented")),
      JSON.generate(version: 1, kind: "result", payload: []),
      "{not json"
    ]

    invalid.each do |wire|
      expect { described_class.load_result(wire) }
        .to raise_error(described_class::ProtocolError, /invalid chat wire payload/)
    end
    expect { described_class.load_result("x" * 200, max_bytes: 100) }
      .to raise_error(described_class::ProtocolError, /invalid chat wire payload/)
    deep = {"version" => 1, "kind" => "result", "payload" => result}
    20.times { deep = {"nested" => deep} }
    expect { described_class.from_wire(deep, expected_kind: :result, max_depth: 10) }
      .to raise_error(described_class::ProtocolError, /invalid chat wire payload/)
  end

  it "never includes untrusted payload values in protocol errors" do
    secret = "Bearer secret-token prompt=private headers=x raw-provider-body=y"
    wire = JSON.generate(version: 1, kind: "result", payload: result.merge(status: secret))

    expect { described_class.load_result(wire) }.to raise_error(described_class::ProtocolError) do |raised|
      expect(raised.message).to eq("invalid chat wire payload: invalid result status")
      expect(raised.message).not_to include(secret)
    end
  end

  it "counts object keys toward the from_wire byte limit" do
    wire = JSON.parse(JSON.generate(version: 1, kind: "result", payload: result.merge(parsed: {"x" * 1_000 => "v"})))

    expect { described_class.from_wire(wire, expected_kind: :result, max_bytes: 100) }
      .to raise_error(described_class::ProtocolError, "invalid chat wire payload: content exceeds byte limit")
  end

  it "rejects an empty result instead of decoding it as a success" do
    wire = JSON.generate(version: 1, kind: "result", payload: {})

    expect { described_class.load_result(wire) }
      .to raise_error(described_class::ProtocolError, "invalid chat wire payload: missing result request_id")
  end

  def error(category, code, retry_after_seconds: nil)
    value = {category: category, code: code, retryable: category == :transient,
             message: "Chat request failed (#{category}/#{code})"}
    value[:retry_after_seconds] = retry_after_seconds if retry_after_seconds
    value
  end
end
