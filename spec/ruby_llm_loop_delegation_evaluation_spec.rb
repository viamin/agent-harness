# frozen_string_literal: true

require "spec_helper"

Encoding.default_external = Encoding::UTF_8

# RubyLLM derives tool names from class names (EvaluationReadTool ->
# "evaluation_read"), so the evaluation tools need named classes.
class EvaluationReadTool < RubyLLM::Tool
  description "reads a record"

  def execute(id:) = "read result:#{id}"
end

class EvaluationWriteTool < RubyLLM::Tool
  description "writes a record"
  requires_approval

  def execute(id:) = "write result:#{id}"
end

# RDR-072 resumable-loop delegation evaluation evidence. These examples pin
# the RubyLLM 2.0 public loop behaviors the retained-loop decision in
# docs/provider-neutral-api-execution-contract.md rests on, using only the
# public Chat/Tool API. If a RubyLLM upgrade changes one of these facts, the
# delegation evaluation must be revisited before adopting loop controls.
RSpec.describe "RubyLLM 2.0 loop controls (RDR-072 delegation evaluation)" do
  let(:messages_url) { "https://api.anthropic.com/v1/messages" }

  def tool_round(*calls)
    {id: "msg_#{calls.map { |call| call[:id] }.join}", type: "message", role: "assistant", model: "claude-test",
     content: calls.map { |call| {type: "tool_use", id: call[:id], name: call[:name], input: call.fetch(:input, {"id" => call[:id].split("_").last})} },
     stop_reason: "tool_use", usage: {input_tokens: 10, output_tokens: 5}}
  end

  def text_round(text)
    {id: "msg_final", type: "message", role: "assistant", model: "claude-test",
     content: [{type: "text", text: text}], stop_reason: "end_turn",
     usage: {input_tokens: 10, output_tokens: 5}}
  end

  def stub_messages(*bodies)
    responses = bodies.map { |body| {body: JSON.generate(body), headers: {"Content-Type" => "application/json"}} }
    stub_request(:post, messages_url).to_return(responses)
  end

  def build_chat(retries: 0, instrumenter: nil)
    context = RubyLLM.context do |config|
      config.anthropic_api_key = "evaluation-secret"
      config.max_retries = retries
      config.retry_interval = 0 if retries.positive?
      config.instrumenter = instrumenter if instrumenter
    end
    context.chat(model: "claude-test", provider: :anthropic, protocol: :anthropic, assume_model_exists: true).tap do |chat|
      chat.with_tools(EvaluationReadTool, EvaluationWriteTool)
      chat.add_message(role: :user, content: "proceed")
    end
  end

  it "executes single steps and reports completion through the public loop API" do
    chat = build_chat
    stub_messages(tool_round(id: "toolu_read_1", name: "evaluation_read"), text_round("finished"))

    chat.generate
    expect(chat.complete?).to be false
    expect(chat.step.tool_result?).to be true
    final = chat.step

    expect(final.content).to eq("finished")
    expect(chat.complete?).to be true
    expect(chat.messages.map(&:role)).to eq(%i[user assistant tool assistant])
  end

  it "runs mixed read/write batches by executing reads and pausing only writes" do
    chat = build_chat
    stub_messages(
      tool_round({id: "toolu_read_1", name: "evaluation_read"}, {id: "toolu_write_1", name: "evaluation_write"}),
      text_round("finished")
    )

    chat.generate
    chat.run_tools

    expect(chat.messages.filter_map { |message| message.tool_call_id }).to eq(["toolu_read_1"])
    expect(chat.pending_approvals.map(&:id)).to eq(["toolu_write_1"])
    expect(chat.awaiting_approval?).to be true
  end

  it "resolves multiple pending decisions independently and continues after denial" do
    chat = build_chat
    stub_messages(
      tool_round({id: "toolu_write_1", name: "evaluation_write"}, {id: "toolu_write_2", name: "evaluation_write"}),
      text_round("finished")
    )

    chat.generate
    expect(chat.pending_approvals.map(&:id)).to eq(%w[toolu_write_1 toolu_write_2])

    chat.approve("toolu_write_1")
    chat.deny("toolu_write_2")
    final = chat.complete

    expect(final.content).to eq("finished")
    denial = chat.messages.find { |message| message.tool_call_id == "toolu_write_2" }
    expect(denial.content).to include("denied")
    executed = chat.messages.find { |message| message.tool_call_id == "toolu_write_1" }
    expect(executed.content).to eq("write result:1")
  end

  it "preserves completed tool results and does not re-execute them on resume" do
    chat = build_chat
    stub_messages(
      tool_round({id: "toolu_read_a", name: "evaluation_read"}, {id: "toolu_read_b", name: "evaluation_read"}),
      text_round("finished")
    )

    chat.generate
    chat.add_message(role: :tool, content: "already persisted", tool_call_id: "toolu_read_a")
    chat.run_tools

    results = chat.messages.filter_map { |message| [message.tool_call_id, message.content] if message.role == :tool }
    expect(results).to contain_exactly(
      ["toolu_read_a", "already persisted"], ["toolu_read_b", "read result:b"]
    )
  end

  it "raises at loop checkpoints after cancellation and clears the flag" do
    chat = build_chat
    chat.cancel

    expect { chat.step }.to raise_error(RubyLLM::CancelledError)
    expect(chat.cancelled?).to be false
  end

  it "keys tool-call identity on the provider wire id only" do
    chat = build_chat
    stub_messages(tool_round(id: "toolu_read_1", name: "evaluation_read"))

    response = chat.generate

    expect(response.tool_calls.values.map(&:id)).to eq(["toolu_read_1"])
    expect(chat.messages.last.tool_calls.values.map(&:id)).to eq(["toolu_read_1"])
  end

  it "loses recorded approval decisions when a plain Ruby chat is reconstructed" do
    chat = build_chat
    stub_messages(tool_round(id: "toolu_write_1", name: "evaluation_write"), text_round("finished"))

    chat.generate
    chat.approve("toolu_write_1")
    expect(chat.awaiting_approval?).to be false

    rebuilt = build_chat
    rebuilt.messages = chat.messages

    expect(rebuilt.awaiting_approval?).to be true
    expect(rebuilt.pending_approvals.map(&:id)).to eq(["toolu_write_1"])
  end

  it "does not bound loop iterations by itself" do
    chat = build_chat
    stub_messages(*(1..4).map { |round| tool_round(id: "toolu_read_#{round}", name: "evaluation_read") })

    4.times do
      chat.step
      chat.step
      expect(chat.complete?).to be false
    end
    expect(chat.tool_options).to eq(choice: nil, calls: nil, concurrency: nil)
  end

  it "retries beneath the caller inside the delegated loop by default" do
    chat = build_chat(retries: 3)
    stub_request(:post, messages_url)
      .to_return(
        {status: 500, body: JSON.generate({type: "error", error: {type: "api_error", message: "boom"}}),
         headers: {"Content-Type" => "application/json"}},
        {body: JSON.generate(text_round("recovered")), headers: {"Content-Type" => "application/json"}}
      )

    expect(chat.generate.content).to eq("recovered")
    expect(a_request(:post, messages_url)).to have_been_made.twice
  end

  it "reports loop usage without attempt identity" do
    capture = Class.new do
      attr_reader :events

      def initialize
        @events = []
      end

      def instrument(name, payload)
        @events << payload if name == "usage.ruby_llm"
        yield payload if block_given?
      end
    end.new
    chat = build_chat(instrumenter: capture)
    stub_messages(text_round("accounted"))

    chat.generate

    expect(capture.events).not_to be_empty
    expect(capture.events).to all(include(operation: :chat, provider: "anthropic", model: "claude-test"))
    expect(capture.events.flat_map(&:keys).uniq)
      .to contain_exactly(:operation, :provider, :model, :status, :tokens, :cost)
  end
end
