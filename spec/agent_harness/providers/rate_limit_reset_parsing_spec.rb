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

    context "reset at datetime" do
      it "parses 'reset at YYYY-MM-DD HH:MM:SS'" do
        result = provider.parse_rate_limit_reset(
          "Weekly/Monthly Limit Exhausted. Your limit will reset at 2026-05-18 11:22:32"
        )

        expect(result).to eq(Time.utc(2026, 5, 18, 11, 22, 32))
      end

      it "returns nil for invalid datetime values" do
        expect(provider.parse_rate_limit_reset("reset at 2026-13-18 11:22:32")).to be_nil
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
      it "returns nil for invalid month abbreviation" do
        expect(provider.parse_rate_limit_reset("resets Xyz 15, 5pm (UTC)")).to be_nil
      end

      it "returns nil for an impossible date like Feb 31" do
        expect(provider.parse_rate_limit_reset("resets Feb 31, 5pm (UTC)")).to be_nil
      end

      it "returns nil when month is far in the past (beyond 8-day ceiling)" do
        past_month = Time.now.utc.month - 2
        past_month += 12 if past_month < 1

        month_name = Date::ABBR_MONTHNAMES[past_month]
        result = provider.parse_rate_limit_reset("resets #{month_name} 15, 5pm (UTC)")
        expect(result).to be_nil
      end

      it "returns nil for a date more than 8 days in the future" do
        future_month = Time.now.utc.month + 1
        future_month -= 12 if future_month > 12
        month_name = Date::ABBR_MONTHNAMES[future_month]
        result = provider.parse_rate_limit_reset("resets #{month_name} 15, 5pm (UTC)")
        expect(result).to be_nil
      end

      context "when now is 2026-06-02 12:00 UTC" do
        before do
          allow(Time).to receive(:now).and_return(Time.utc(2026, 6, 2, 12, 0, 0))
        end

        it "parses a near-future date in the same month" do
          result = provider.parse_rate_limit_reset("resets Jun 4, 10pm (UTC)")
          expect(result).to eq(Time.utc(2026, 6, 4, 22, 0, 0))
        end

        it "parses a near-future date within 8 days" do
          result = provider.parse_rate_limit_reset("resets Jun 9, 10pm (UTC)")
          expect(result).to eq(Time.utc(2026, 6, 9, 22, 0, 0))
        end

        it "parses without comma after day" do
          result = provider.parse_rate_limit_reset("resets Jun 4 10pm (UTC)")
          expect(result).to eq(Time.utc(2026, 6, 4, 22, 0))
        end

        it "parses uppercase month abbreviation (case insensitive)" do
          result = provider.parse_rate_limit_reset("resets JUN 4, 10pm (UTC)")
          expect(result).to eq(Time.utc(2026, 6, 4, 22, 0, 0))
        end

        it "returns nil for a date exactly 8 days from now (at the boundary)" do
          result = provider.parse_rate_limit_reset("resets Jun 10, 12pm (UTC)")
          expect(result).to be_nil
        end

        it "returns nil for a past month that would be almost a year away with year+1" do
          result = provider.parse_rate_limit_reset("resets Apr 6, 10pm (UTC)")
          expect(result).to be_nil
        end

        it "returns candidate within grace window even if slightly in the past" do
          result = provider.parse_rate_limit_reset("resets Jun 2, 11am (UTC)")
          expect(result).to eq(Time.utc(2026, 6, 2, 11, 0, 0))
        end

        it "returns candidate at exactly the 2-hour grace boundary" do
          result = provider.parse_rate_limit_reset("resets Jun 2, 10am (UTC)")
          expect(result).to eq(Time.utc(2026, 6, 2, 10, 0, 0))
        end

        it "returns a UTC time" do
          result = provider.parse_rate_limit_reset("resets Jun 4, 5pm (UTC)")
          expect(result.utc?).to be true
          expect(result.hour).to eq(17)
          expect(result.min).to eq(0)
        end
      end

      context "when now is 2026-01-14 12:00 UTC" do
        before do
          allow(Time).to receive(:now).and_return(Time.utc(2026, 1, 14, 12, 0, 0))
        end

        it "parses 'resets Jan 15, 5pm (UTC)' as tomorrow" do
          result = provider.parse_rate_limit_reset("resets Jan 15, 5pm (UTC)")
          expect(result.month).to eq(1)
          expect(result.day).to eq(15)
          expect(result.hour).to eq(17)
          expect(result.min).to eq(0)
        end

        it "parses 'resets Mar 1, 9:30am (UTC)' as nil (beyond 8 days)" do
          result = provider.parse_rate_limit_reset("resets Mar 1, 9:30am (UTC)")
          expect(result).to be_nil
        end
      end

      context "when now is 2026-12-28 12:00 UTC" do
        before do
          allow(Time).to receive(:now).and_return(Time.utc(2026, 12, 28, 12, 0, 0))
        end

        it "resolves a January date from late December within 8 days" do
          result = provider.parse_rate_limit_reset("resets Jan 3, 5pm (UTC)")
          expect(result).to eq(Time.utc(2027, 1, 3, 17, 0, 0))
        end
      end
    end
  end
end
