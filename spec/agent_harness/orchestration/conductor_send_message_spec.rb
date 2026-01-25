# frozen_string_literal: true

RSpec.describe AgentHarness::Orchestration::Conductor, "#send_message" do
  let(:mock_provider) do
    instance_double(AgentHarness::Providers::Base).tap do |p|
      allow(p).to receive_message_chain(:class, :provider_name).and_return(:test_provider)
      allow(p).to receive(:send_message).and_return(
        AgentHarness::Response.new(
          output: "response",
          exit_code: 0,
          duration: 1.0,
          provider: :test_provider
        )
      )
    end
  end

  let(:mock_provider_manager) do
    instance_double(AgentHarness::Orchestration::ProviderManager).tap do |pm|
      allow(pm).to receive(:select_provider).and_return(mock_provider)
      allow(pm).to receive(:record_success)
      allow(pm).to receive(:record_failure)
      allow(pm).to receive(:mark_rate_limited)
      allow(pm).to receive(:switch_provider).and_return(nil)
      allow(pm).to receive(:current_provider).and_return(:test_provider)
      allow(pm).to receive(:available_providers).and_return([:test_provider])
      allow(pm).to receive(:health_status).and_return([])
      allow(pm).to receive(:reset!)
    end
  end

  let(:config) do
    AgentHarness::Configuration.new.tap do |c|
      c.default_provider = :test_provider
      c.provider(:test_provider) { |p| p.enabled = true }
      c.orchestration do |o|
        o.enabled = true
        o.retry do |r|
          r.enabled = true
          r.max_attempts = 2
          r.base_delay = 0.01
          r.jitter = false
        end
      end
    end
  end

  subject(:conductor) do
    described_class.new(config: config).tap do |c|
      c.instance_variable_set(:@provider_manager, mock_provider_manager)
    end
  end

  describe "successful request" do
    it "returns the response" do
      response = conductor.send_message("Hello")
      expect(response.output).to eq("response")
    end

    it "records success metrics" do
      expect(mock_provider_manager).to receive(:record_success).with(:test_provider)
      conductor.send_message("Hello")
    end

    it "records attempt in metrics" do
      conductor.send_message("Hello")
      expect(conductor.metrics.summary[:total_attempts]).to eq(1)
    end
  end

  describe "rate limit error" do
    before do
      # Always raise rate limit error to exhaust retries
      allow(mock_provider).to receive(:send_message).and_raise(
        AgentHarness::RateLimitError.new("rate limited", reset_time: Time.now + 3600)
      )
    end

    it "marks provider as rate limited" do
      expect(mock_provider_manager).to receive(:mark_rate_limited).at_least(:once)
      expect { conductor.send_message("Hello") }.to raise_error(AgentHarness::RateLimitError)
    end
  end

  describe "timeout error with retry" do
    before do
      call_count = 0
      allow(mock_provider).to receive(:send_message) do
        call_count += 1
        if call_count == 1
          raise AgentHarness::TimeoutError.new("timed out")
        else
          AgentHarness::Response.new(output: "ok", exit_code: 0, duration: 1.0, provider: :test_provider)
        end
      end
    end

    it "retries on timeout" do
      response = conductor.send_message("Hello")
      expect(response.output).to eq("ok")
    end
  end

  describe "all retries exhausted" do
    before do
      allow(mock_provider).to receive(:send_message).and_raise(
        AgentHarness::TimeoutError.new("timed out")
      )
    end

    it "raises after max retries" do
      expect { conductor.send_message("Hello") }.to raise_error(AgentHarness::TimeoutError)
    end

    it "records failures" do
      expect(mock_provider_manager).to receive(:record_failure).at_least(:once)
      expect { conductor.send_message("Hello") }.to raise_error(AgentHarness::TimeoutError)
    end
  end

  describe "generic error with switch" do
    before do
      # Use generic error which triggers switch strategy (not caught by specific handlers)
      allow(mock_provider).to receive(:send_message).and_raise(
        StandardError.new("unexpected error")
      )
      allow(config.orchestration_config).to receive(:auto_switch_on_error).and_return(true)
    end

    it "attempts to switch provider" do
      expect(mock_provider_manager).to receive(:switch_provider).at_least(:once)
      expect { conductor.send_message("Hello") }.to raise_error(AgentHarness::ProviderError)
    end
  end

  describe "#execute_direct" do
    let(:direct_provider) do
      instance_double(AgentHarness::Providers::Base).tap do |p|
        allow(p).to receive(:send_message).and_return(
          AgentHarness::Response.new(output: "direct", exit_code: 0, duration: 1.0, provider: :direct)
        )
      end
    end

    before do
      allow(mock_provider_manager).to receive(:get_provider).and_return(direct_provider)
    end

    it "bypasses orchestration" do
      response = conductor.execute_direct("Hello", provider: :direct)
      expect(response.output).to eq("direct")
    end
  end
end
