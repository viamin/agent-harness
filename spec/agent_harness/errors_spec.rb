# frozen_string_literal: true

RSpec.describe AgentHarness do
  describe "Error classes" do
    describe AgentHarness::Error do
      it "is a StandardError" do
        expect(described_class.new).to be_a(StandardError)
      end

      it "stores original_error" do
        original = RuntimeError.new("original")
        error = described_class.new("wrapped", original_error: original)

        expect(error.original_error).to eq(original)
      end

      it "stores context" do
        error = described_class.new("test", context: {key: "value"})
        expect(error.context).to eq({key: "value"})
      end
    end

    describe AgentHarness::ProviderError do
      it "inherits from Error" do
        expect(described_class.new).to be_a(AgentHarness::Error)
      end
    end

    describe AgentHarness::ProviderNotFoundError do
      it "inherits from ProviderError" do
        expect(described_class.new).to be_a(AgentHarness::ProviderError)
      end
    end

    describe AgentHarness::RateLimitError do
      it "stores reset_time" do
        reset = Time.now + 3600
        error = described_class.new("rate limited", reset_time: reset)

        expect(error.reset_time).to eq(reset)
      end

      it "stores provider" do
        error = described_class.new("rate limited", provider: :claude)
        expect(error.provider).to eq(:claude)
      end
    end

    describe AgentHarness::CircuitOpenError do
      it "stores provider" do
        error = described_class.new("circuit open", provider: :claude)
        expect(error.provider).to eq(:claude)
      end
    end

    describe AgentHarness::NoProvidersAvailableError do
      it "stores attempted_providers" do
        error = described_class.new("no providers", attempted_providers: [:claude, :cursor])
        expect(error.attempted_providers).to eq([:claude, :cursor])
      end

      it "stores errors" do
        errors = {claude: "rate limited", cursor: "auth failed"}
        error = described_class.new("no providers", errors: errors)
        expect(error.errors).to eq(errors)
      end
    end

    describe AgentHarness::TimeoutError do
      it "inherits from Error" do
        expect(described_class.new).to be_a(AgentHarness::Error)
      end
    end

    describe AgentHarness::AuthenticationError do
      it "inherits from Error" do
        expect(described_class.new).to be_a(AgentHarness::Error)
      end
    end

    describe AgentHarness::ConfigurationError do
      it "inherits from Error" do
        expect(described_class.new).to be_a(AgentHarness::Error)
      end
    end
  end
end
