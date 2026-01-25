# frozen_string_literal: true

RSpec.describe AgentHarness::CallbackRegistry do
  subject(:registry) { described_class.new }

  describe "#register" do
    it "registers callbacks for events" do
      callback = proc { |data| data }
      registry.register(:test_event, callback)

      expect(registry.registered?(:test_event)).to be true
    end

    it "allows multiple callbacks for same event" do
      callback1 = proc { |data| data }
      callback2 = proc { |data| data }

      registry.register(:test_event, callback1)
      registry.register(:test_event, callback2)

      expect(registry.registered?(:test_event)).to be true
    end
  end

  describe "#emit" do
    it "calls all registered callbacks with data" do
      results = []
      registry.register(:test_event, proc { |data| results << data[:value] })
      registry.register(:test_event, proc { |data| results << data[:value] * 2 })

      registry.emit(:test_event, {value: 5})

      expect(results).to eq([5, 10])
    end

    it "handles callback errors gracefully" do
      registry.register(:test_event, proc { |data| raise "boom" })

      # Should not raise
      expect { registry.emit(:test_event, {}) }.not_to raise_error
    end

    it "does nothing when no callbacks registered" do
      expect { registry.emit(:nonexistent, {}) }.not_to raise_error
    end
  end

  describe "#registered?" do
    it "returns false when no callbacks" do
      expect(registry.registered?(:test_event)).to be false
    end

    it "returns true when callbacks exist" do
      registry.register(:test_event, proc {})
      expect(registry.registered?(:test_event)).to be true
    end
  end
end
