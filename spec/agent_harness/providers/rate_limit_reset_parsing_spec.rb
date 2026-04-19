# frozen_string_literal: true

RSpec.describe AgentHarness::Providers::RateLimitResetParsing do
  let(:provider_class) do
    Class.new(AgentHarness::Providers::Base) do
      include AgentHarness::Providers::RateLimitResetParsing

      class << self
        def provider_name
          :test_provider
        end

        def binary_name
          "test-cli"
        end

        def available?
          false
        end
      end
    end
  end

  let(:provider) { provider_class.new }

  describe "#parse_rate_limit_reset" do
    it "returns nil for nil input" do
      expect(provider.parse_rate_limit_reset(nil)).to be_nil
    end

    it "returns nil for unrecognized text" do
      expect(provider.parse_rate_limit_reset("something went wrong")).to be_nil
    end

    context "retry after seconds" do
      it "parses 'retry after 60s'" do
        now = Time.now.utc
        result = provider.parse_rate_limit_reset("retry after 60s")
        expect(result).to be_within(2).of(now + 60)
      end

      it "parses 'Retry After 120s' (case insensitive)" do
        now = Time.now.utc
        result = provider.parse_rate_limit_reset("Retry After 120s")
        expect(result).to be_within(2).of(now + 120)
      end

      it "parses retry after with surrounding text" do
        now = Time.now.utc
        result = provider.parse_rate_limit_reset("Rate limited. Please retry after 30s.")
        expect(result).to be_within(2).of(now + 30)
      end
    end

    context "reset at unix timestamp" do
      it "parses 'reset at <timestamp>'" do
        timestamp = Time.now.utc.to_i + 3600
        result = provider.parse_rate_limit_reset("reset at #{timestamp}")
        expect(result).to eq(Time.at(timestamp).utc)
      end

      it "parses 'Reset At <timestamp>' (case insensitive)" do
        timestamp = Time.now.utc.to_i + 3600
        result = provider.parse_rate_limit_reset("Reset At #{timestamp}")
        expect(result).to eq(Time.at(timestamp).utc)
      end
    end

    context "resets at time (UTC)" do
      it "parses 'resets 5am (UTC)'" do
        result = provider.parse_rate_limit_reset("resets 5am (UTC)")
        expect(result.utc?).to be true
        expect(result.hour).to eq(5)
        expect(result.min).to eq(0)
      end

      it "parses 'resets 5:30am (UTC)'" do
        result = provider.parse_rate_limit_reset("resets 5:30am (UTC)")
        expect(result.hour).to eq(5)
        expect(result.min).to eq(30)
      end

      it "parses 'resets 5pm (UTC)'" do
        result = provider.parse_rate_limit_reset("resets 5pm (UTC)")
        expect(result.hour).to eq(17)
        expect(result.min).to eq(0)
      end

      it "parses 'resets 12am (UTC)' as midnight" do
        result = provider.parse_rate_limit_reset("resets 12am (UTC)")
        expect(result.hour).to eq(0)
      end

      it "parses 'resets 12pm (UTC)' as noon" do
        result = provider.parse_rate_limit_reset("resets 12pm (UTC)")
        expect(result.hour).to eq(12)
      end

      it "returns a future time" do
        result = provider.parse_rate_limit_reset("resets 5am (UTC)")
        expect(result).to be > Time.now.utc
      end
    end

    context "resets at date and time (UTC)" do
      it "parses 'resets Jan 15, 5pm (UTC)'" do
        result = provider.parse_rate_limit_reset("resets Jan 15, 5pm (UTC)")
        expect(result.utc?).to be true
        expect(result.month).to eq(1)
        expect(result.day).to eq(15)
        expect(result.hour).to eq(17)
        expect(result.min).to eq(0)
      end

      it "parses 'resets Mar 1, 9:30am (UTC)'" do
        result = provider.parse_rate_limit_reset("resets Mar 1, 9:30am (UTC)")
        expect(result.month).to eq(3)
        expect(result.day).to eq(1)
        expect(result.hour).to eq(9)
        expect(result.min).to eq(30)
      end

      it "parses without comma after day" do
        result = provider.parse_rate_limit_reset("resets Jan 15 5pm (UTC)")
        expect(result.month).to eq(1)
        expect(result.day).to eq(15)
        expect(result.hour).to eq(17)
      end

      it "returns nil for invalid month abbreviation" do
        expect(provider.parse_rate_limit_reset("resets Xyz 15, 5pm (UTC)")).to be_nil
      end

      it "advances year when month is in the past" do
        past_month = Time.now.utc.month - 1
        return if past_month < 1 # skip in January

        month_name = Date::ABBR_MONTHNAMES[past_month]
        result = provider.parse_rate_limit_reset("resets #{month_name} 15, 5pm (UTC)")
        expect(result.year).to eq(Time.now.utc.year + 1)
      end
    end
  end
end
