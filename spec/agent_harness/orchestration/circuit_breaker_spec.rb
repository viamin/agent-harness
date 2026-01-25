# frozen_string_literal: true

RSpec.describe AgentHarness::Orchestration::CircuitBreaker do
  subject(:breaker) { described_class.new(failure_threshold: 3, timeout: 60, half_open_max_calls: 2) }

  describe "#initialize" do
    it "starts in closed state" do
      expect(breaker.closed?).to be true
      expect(breaker.open?).to be false
    end

    it "starts with zero counts" do
      expect(breaker.failure_count).to eq(0)
      expect(breaker.success_count).to eq(0)
    end
  end

  describe "#record_failure" do
    it "increments failure count" do
      breaker.record_failure
      expect(breaker.failure_count).to eq(1)
    end

    it "opens circuit when threshold reached" do
      3.times { breaker.record_failure }
      expect(breaker.open?).to be true
    end

    it "does not open circuit before threshold" do
      2.times { breaker.record_failure }
      expect(breaker.open?).to be false
    end
  end

  describe "#record_success" do
    context "when closed" do
      it "increments success count" do
        breaker.record_success
        expect(breaker.success_count).to eq(1)
      end
    end

    context "when half-open" do
      before do
        3.times { breaker.record_failure }
        # Simulate timeout elapsed by manually setting state
        breaker.instance_variable_set(:@state, :half_open)
        breaker.instance_variable_set(:@success_count, 0)
      end

      it "closes circuit after enough successes" do
        2.times { breaker.record_success }
        expect(breaker.closed?).to be true
      end
    end
  end

  describe "#reset!" do
    it "resets to initial state" do
      3.times { breaker.record_failure }
      expect(breaker.open?).to be true

      breaker.reset!

      expect(breaker.closed?).to be true
      expect(breaker.failure_count).to eq(0)
      expect(breaker.success_count).to eq(0)
    end
  end

  describe "#status" do
    it "returns status hash" do
      status = breaker.status

      expect(status[:state]).to eq(:closed)
      expect(status[:failure_count]).to eq(0)
      expect(status[:failure_threshold]).to eq(3)
      expect(status[:enabled]).to be true
    end
  end
end
