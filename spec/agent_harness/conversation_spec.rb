# frozen_string_literal: true

RSpec.describe AgentHarness::Conversation do
  subject(:conversation) { described_class.new }

  describe "#initialize" do
    it "creates an empty conversation" do
      expect(conversation.message_count).to eq(0)
      expect(conversation.messages).to eq([])
    end

    it "accepts an optional system prompt" do
      convo = described_class.new(system_prompt: "You are helpful.")
      expect(convo.message_count).to eq(1)
      expect(convo.messages.first[:role]).to eq(:system)
      expect(convo.messages.first[:content]).to eq("You are helpful.")
    end

    it "accepts an optional token limit" do
      convo = described_class.new(token_limit: 8000)
      expect(convo.token_limit).to eq(8000)
    end
  end

  describe "#add_message" do
    it "adds a user message" do
      msg = conversation.add_message(:user, "Hello")
      expect(msg[:role]).to eq(:user)
      expect(msg[:content]).to eq("Hello")
      expect(msg[:created_at]).to be_a(Time)
      expect(conversation.message_count).to eq(1)
    end

    it "adds an assistant message with token metadata" do
      msg = conversation.add_message(:assistant, "Hi!", tokens: {input: 10, output: 5})
      expect(msg[:tokens]).to eq({input: 10, output: 5})
    end

    it "adds a tool message with tool_call_id" do
      msg = conversation.add_message(:tool, "result", tool_call_id: "call_123")
      expect(msg[:role]).to eq(:tool)
      expect(msg[:tool_call_id]).to eq("call_123")
    end

    it "adds an assistant message with tool_calls" do
      tool_calls = [{id: "call_1", name: "search", arguments: '{"q":"test"}'}]
      msg = conversation.add_message(:assistant, nil, tool_calls: tool_calls)
      expect(msg[:tool_calls]).to eq(tool_calls)
    end

    it "accepts string roles and converts to symbols" do
      msg = conversation.add_message("user", "Hello")
      expect(msg[:role]).to eq(:user)
    end

    it "raises ArgumentError for invalid roles" do
      expect { conversation.add_message(:invalid, "Hello") }
        .to raise_error(ArgumentError, /Invalid role/)
    end

    it "stores optional metadata fields" do
      msg = conversation.add_message(:tool, "ok",
        tool_call_id: "tc_1",
        tool_name: "search",
        tool_arguments: '{"q":"x"}',
        tool_result: "found",
        model: "gpt-4o")
      expect(msg[:tool_name]).to eq("search")
      expect(msg[:tool_arguments]).to eq('{"q":"x"}')
      expect(msg[:tool_result]).to eq("found")
      expect(msg[:model]).to eq("gpt-4o")
    end
  end

  describe "#messages" do
    it "returns a copy of the messages array" do
      conversation.add_message(:user, "Hello")
      msgs = conversation.messages
      msgs.clear
      expect(conversation.message_count).to eq(1)
    end
  end

  describe "#token_count" do
    it "returns 0 when no tokens tracked" do
      conversation.add_message(:user, "Hello")
      expect(conversation.token_count).to eq(0)
    end

    it "sums input and output tokens across messages" do
      conversation.add_message(:user, "Hello", tokens: {input: 10, output: 0})
      conversation.add_message(:assistant, "Hi!", tokens: {input: 15, output: 8})
      expect(conversation.token_count).to eq(33)
    end

    it "handles messages with partial token data" do
      conversation.add_message(:user, "Hello", tokens: {input: 10})
      expect(conversation.token_count).to eq(10)
    end
  end

  describe "#token_remaining" do
    it "returns nil when no limit is set" do
      expect(conversation.token_remaining).to be_nil
    end

    it "returns remaining tokens" do
      convo = described_class.new(token_limit: 1000)
      convo.add_message(:user, "Hello", tokens: {input: 100, output: 0})
      expect(convo.token_remaining).to eq(900)
    end
  end

  describe "#approaching_limit?" do
    it "returns false when no limit is set" do
      expect(conversation.approaching_limit?).to be false
    end

    it "returns false when under threshold" do
      convo = described_class.new(token_limit: 1000)
      convo.add_message(:user, "Hello", tokens: {input: 100, output: 0})
      expect(convo.approaching_limit?).to be false
    end

    it "returns true when at or above threshold" do
      convo = described_class.new(token_limit: 1000)
      convo.add_message(:user, "Hello", tokens: {input: 800, output: 0})
      expect(convo.approaching_limit?).to be true
    end

    it "supports custom threshold" do
      convo = described_class.new(token_limit: 1000)
      convo.add_message(:user, "Hello", tokens: {input: 500, output: 0})
      expect(convo.approaching_limit?(threshold: 0.5)).to be true
      expect(convo.approaching_limit?(threshold: 0.6)).to be false
    end
  end

  describe "#truncate" do
    let(:convo) { described_class.new(system_prompt: "System") }

    before do
      convo.add_message(:user, "msg1")
      convo.add_message(:assistant, "resp1")
      convo.add_message(:user, "msg2")
      convo.add_message(:assistant, "resp2")
      convo.add_message(:user, "msg3")
      convo.add_message(:assistant, "resp3")
    end

    it "preserves system prompt and keeps recent messages" do
      removed = convo.truncate(keep_recent: 2)
      expect(removed).to eq(4)
      expect(convo.message_count).to eq(3) # system + 2 recent
      expect(convo.messages.first[:role]).to eq(:system)
      expect(convo.messages.last[:content]).to eq("resp3")
    end

    it "returns 0 when keep_recent covers all messages" do
      removed = convo.truncate(keep_recent: 10)
      expect(removed).to eq(0)
      expect(convo.message_count).to eq(7)
    end

    it "returns 0 when keep_recent is nil" do
      removed = convo.truncate
      expect(removed).to eq(0)
    end

    it "removes system prompt when keep_system_prompt is false" do
      removed = convo.truncate(keep_recent: 2, keep_system_prompt: false)
      expect(removed).to eq(4)
      expect(convo.message_count).to eq(2)
      expect(convo.messages.none? { |m| m[:role] == :system }).to be true
    end
  end

  describe "#to_openai_messages" do
    it "formats basic messages" do
      conversation.add_message(:user, "Hello")
      conversation.add_message(:assistant, "Hi!")

      result = conversation.to_openai_messages
      expect(result).to eq([
        {role: "user", content: "Hello"},
        {role: "assistant", content: "Hi!"}
      ])
    end

    it "includes system prompt" do
      convo = described_class.new(system_prompt: "You are helpful.")
      convo.add_message(:user, "Hello")

      result = convo.to_openai_messages
      expect(result.first).to eq({role: "system", content: "You are helpful."})
    end

    it "formats assistant messages with tool_calls" do
      tool_calls = [{id: "call_1", name: "search", arguments: '{"q":"test"}'}]
      conversation.add_message(:assistant, nil, tool_calls: tool_calls)

      result = conversation.to_openai_messages
      expect(result.first[:tool_calls]).to eq([{
        id: "call_1",
        type: "function",
        function: {name: "search", arguments: '{"q":"test"}'}
      }])
    end

    it "formats tool result messages" do
      conversation.add_message(:tool, "result text", tool_call_id: "call_1")

      result = conversation.to_openai_messages
      expect(result.first).to eq({
        role: "tool",
        content: "result text",
        tool_call_id: "call_1"
      })
    end

    it "serializes hash arguments to JSON string" do
      tool_calls = [{id: "call_1", name: "search", arguments: {q: "test"}}]
      conversation.add_message(:assistant, nil, tool_calls: tool_calls)

      result = conversation.to_openai_messages
      expect(result.first[:tool_calls].first[:function][:arguments]).to eq('{"q":"test"}')
    end
  end

  describe "#to_anthropic_messages" do
    it "separates system prompt" do
      convo = described_class.new(system_prompt: "You are helpful.")
      convo.add_message(:user, "Hello")

      result = convo.to_anthropic_messages
      expect(result[:system]).to eq("You are helpful.")
      expect(result[:messages].size).to eq(1)
    end

    it "returns nil system when no system prompt" do
      conversation.add_message(:user, "Hello")

      result = conversation.to_anthropic_messages
      expect(result[:system]).to be_nil
    end

    it "wraps user content in text blocks" do
      conversation.add_message(:user, "Hello")

      result = conversation.to_anthropic_messages
      expect(result[:messages].first).to eq({
        role: "user",
        content: [{type: "text", text: "Hello"}]
      })
    end

    it "formats assistant messages with tool_use blocks" do
      tool_calls = [{id: "call_1", name: "search", arguments: '{"q":"test"}'}]
      conversation.add_message(:assistant, "Let me search.", tool_calls: tool_calls)

      result = conversation.to_anthropic_messages
      assistant = result[:messages].first
      expect(assistant[:content].size).to eq(2)
      expect(assistant[:content][0]).to eq({type: "text", text: "Let me search."})
      expect(assistant[:content][1]).to eq({
        type: "tool_use",
        id: "call_1",
        name: "search",
        input: {"q" => "test"}
      })
    end

    it "formats tool results as user messages with tool_result block" do
      conversation.add_message(:tool, "found it", tool_call_id: "call_1")

      result = conversation.to_anthropic_messages
      expect(result[:messages].first).to eq({
        role: "user",
        content: [{
          type: "tool_result",
          tool_use_id: "call_1",
          content: "found it"
        }]
      })
    end

    it "handles assistant messages with only tool_calls and no content" do
      tool_calls = [{id: "call_1", name: "search", arguments: '{"q":"test"}'}]
      conversation.add_message(:assistant, nil, tool_calls: tool_calls)

      result = conversation.to_anthropic_messages
      assistant = result[:messages].first
      expect(assistant[:content].size).to eq(1)
      expect(assistant[:content].first[:type]).to eq("tool_use")
    end

    it "handles hash arguments in tool_calls" do
      tool_calls = [{id: "call_1", name: "search", arguments: {q: "test"}}]
      conversation.add_message(:assistant, nil, tool_calls: tool_calls)

      result = conversation.to_anthropic_messages
      expect(result[:messages].first[:content].first[:input]).to eq({q: "test"})
    end
  end

  describe "#last_assistant_message" do
    it "returns nil when no assistant messages exist" do
      conversation.add_message(:user, "Hello")
      expect(conversation.last_assistant_message).to be_nil
    end

    it "returns the most recent assistant message" do
      conversation.add_message(:assistant, "First")
      conversation.add_message(:user, "Hello")
      conversation.add_message(:assistant, "Second")

      msg = conversation.last_assistant_message
      expect(msg[:content]).to eq("Second")
    end
  end

  describe "#clear!" do
    it "removes all non-system messages" do
      convo = described_class.new(system_prompt: "System")
      convo.add_message(:user, "Hello")
      convo.add_message(:assistant, "Hi!")
      convo.clear!

      expect(convo.message_count).to eq(1)
      expect(convo.messages.first[:role]).to eq(:system)
    end

    it "results in empty conversation when no system prompt" do
      conversation.add_message(:user, "Hello")
      conversation.clear!
      expect(conversation.message_count).to eq(0)
    end
  end

  describe "edge cases" do
    it "handles empty conversation for all methods" do
      expect(conversation.messages).to eq([])
      expect(conversation.message_count).to eq(0)
      expect(conversation.token_count).to eq(0)
      expect(conversation.last_assistant_message).to be_nil
      expect(conversation.to_openai_messages).to eq([])
      expect(conversation.to_anthropic_messages).to eq({system: nil, messages: []})
    end

    it "handles system-prompt-only conversation" do
      convo = described_class.new(system_prompt: "System")
      expect(convo.message_count).to eq(1)
      expect(convo.to_openai_messages).to eq([{role: "system", content: "System"}])

      anthropic = convo.to_anthropic_messages
      expect(anthropic[:system]).to eq("System")
      expect(anthropic[:messages]).to eq([])
    end

    it "handles conversation with only tool messages" do
      conversation.add_message(:tool, "result1", tool_call_id: "call_1")
      conversation.add_message(:tool, "result2", tool_call_id: "call_2")

      openai = conversation.to_openai_messages
      expect(openai.size).to eq(2)
      expect(openai.all? { |m| m[:role] == "tool" }).to be true
    end

    it "handles a full multi-turn tool-use conversation" do
      convo = described_class.new(system_prompt: "You can search.")
      convo.add_message(:user, "Find info about Ruby")
      convo.add_message(:assistant, "Let me search.", tool_calls: [
        {id: "call_1", name: "search", arguments: '{"q":"Ruby"}'}
      ])
      convo.add_message(:tool, '{"results":["Ruby lang"]}', tool_call_id: "call_1")
      convo.add_message(:assistant, "Ruby is a programming language.")

      expect(convo.message_count).to eq(5)

      openai = convo.to_openai_messages
      expect(openai.size).to eq(5)
      expect(openai[0][:role]).to eq("system")
      expect(openai[2][:tool_calls]).to be_a(Array)
      expect(openai[3][:role]).to eq("tool")

      anthropic = convo.to_anthropic_messages
      expect(anthropic[:system]).to eq("You can search.")
      expect(anthropic[:messages].size).to eq(4)
    end
  end
end
