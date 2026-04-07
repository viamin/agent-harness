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

    it "passes executor overrides through provider selection" do
      executor = instance_double(AgentHarness::CommandExecutor)

      expect(mock_provider_manager).to receive(:select_provider).with(:test_provider, executor: executor)
        .and_return(mock_provider)

      conductor.send_message("Hello", executor: executor)
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

    it "retries with the switched provider for executor-scoped requests" do
      executor = instance_double(AgentHarness::CommandExecutor)
      fallback_provider = instance_double(AgentHarness::Providers::Base)

      allow(mock_provider).to receive(:send_message).and_raise(
        AgentHarness::RateLimitError.new("rate limited", reset_time: Time.now + 3600)
      )
      allow(fallback_provider).to receive_message_chain(:class, :provider_name).and_return(:fallback_provider)
      allow(fallback_provider).to receive(:send_message).and_return(
        AgentHarness::Response.new(
          output: "fallback response",
          exit_code: 0,
          duration: 1.0,
          provider: :fallback_provider
        )
      )

      expect(mock_provider_manager).to receive(:select_provider).with(:test_provider, executor: executor)
        .ordered.and_return(mock_provider)
      expect(mock_provider_manager).to receive(:switch_provider).with(
        from: :test_provider,
        reason: "AgentHarness::RateLimitError",
        context: {error: "rate limited"},
        executor: executor
      ).ordered.and_return(fallback_provider)
      expect(mock_provider_manager).to receive(:select_provider).with(:fallback_provider, executor: executor)
        .ordered.and_return(fallback_provider)

      response = conductor.send_message("Hello", executor: executor)

      expect(response.output).to eq("fallback response")
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

  describe "idle timeout error without retry" do
    before do
      allow(mock_provider).to receive(:send_message).and_raise(
        AgentHarness::IdleTimeoutError.new("command exceeded idle timeout")
      )
    end

    it "raises without retrying the run" do
      expect(mock_provider).to receive(:send_message).once
      expect { conductor.send_message("Hello") }.to raise_error(AgentHarness::IdleTimeoutError)
    end

    it "records the provider failure" do
      expect(mock_provider_manager).to receive(:record_failure).with(:test_provider)
      expect { conductor.send_message("Hello") }.to raise_error(AgentHarness::IdleTimeoutError)
    end
  end

  describe "authentication error" do
    before do
      allow(mock_provider).to receive(:send_message).and_raise(
        AgentHarness::AuthenticationError.new("session expired", provider: :test_provider)
      )
    end

    it "raises AuthenticationError without retrying" do
      expect(mock_provider).to receive(:send_message).once
      expect { conductor.send_message("Hello") }.to raise_error(AgentHarness::AuthenticationError)
    end

    it "does not switch providers" do
      expect(mock_provider_manager).not_to receive(:switch_provider)
      expect { conductor.send_message("Hello") }.to raise_error(AgentHarness::AuthenticationError)
    end

    it "does not record provider failure to avoid tripping circuit breaker" do
      expect(mock_provider_manager).not_to receive(:record_failure)
      expect { conductor.send_message("Hello") }.to raise_error(AgentHarness::AuthenticationError)
    end

    it "records failure in metrics" do
      expect { conductor.send_message("Hello") }.to raise_error(AgentHarness::AuthenticationError)
      expect(conductor.metrics.summary[:total_failures]).to be >= 1
    end
  end

  describe "executor-scoped failures do not poison global health" do
    let(:executor) { instance_double(AgentHarness::CommandExecutor) }

    before do
      allow(mock_provider_manager).to receive(:select_provider)
        .with(:test_provider, executor: executor).and_return(mock_provider)
    end

    it "does not mark_rate_limited on the shared provider manager for rate-limit errors" do
      allow(mock_provider).to receive(:send_message).and_raise(
        AgentHarness::RateLimitError.new("rate limited", reset_time: Time.now + 3600)
      )

      expect(mock_provider_manager).not_to receive(:mark_rate_limited)

      expect { conductor.send_message("Hello", executor: executor) }
        .to raise_error(AgentHarness::RateLimitError)
    end

    it "does not record_failure on the shared provider manager for timeout errors" do
      allow(mock_provider).to receive(:send_message).and_raise(
        AgentHarness::TimeoutError.new("timed out")
      )

      expect(mock_provider_manager).not_to receive(:record_failure)

      expect { conductor.send_message("Hello", executor: executor) }
        .to raise_error(AgentHarness::TimeoutError)
    end

    it "does not record_failure on the shared provider manager for generic errors" do
      allow(mock_provider).to receive(:send_message).and_raise(
        StandardError.new("unexpected error")
      )
      allow(config.orchestration_config).to receive(:auto_switch_on_error).and_return(true)

      expect(mock_provider_manager).not_to receive(:record_failure)

      expect { conductor.send_message("Hello", executor: executor) }
        .to raise_error(AgentHarness::ProviderError)
    end

    it "still records metrics for executor-scoped failures" do
      allow(mock_provider).to receive(:send_message).and_raise(
        AgentHarness::TimeoutError.new("timed out")
      )

      expect { conductor.send_message("Hello", executor: executor) }
        .to raise_error(AgentHarness::TimeoutError)

      expect(conductor.metrics.summary[:total_failures]).to be >= 1
    end

    it "does not record_success on the shared provider manager for executor-scoped requests" do
      expect(mock_provider_manager).not_to receive(:record_success)

      conductor.send_message("Hello", executor: executor)
    end

    it "still records success metrics for executor-scoped requests" do
      conductor.send_message("Hello", executor: executor)

      expect(conductor.metrics.summary[:total_successes]).to be >= 1
    end
  end

  describe "executor-scoped timeout retries fall back via switch" do
    let(:executor) { instance_double(AgentHarness::CommandExecutor) }

    let(:fallback_provider) do
      instance_double(AgentHarness::Providers::Base).tap do |p|
        allow(p).to receive_message_chain(:class, :provider_name).and_return(:fallback_provider)
        allow(p).to receive(:send_message).and_return(
          AgentHarness::Response.new(
            output: "fallback response",
            exit_code: 0,
            duration: 1.0,
            provider: :fallback_provider
          )
        )
      end
    end

    before do
      allow(mock_provider).to receive(:send_message).and_raise(
        AgentHarness::TimeoutError.new("timed out")
      )
      allow(config.orchestration_config).to receive(:auto_switch_on_error).and_return(true)
    end

    it "switches provider on timeout instead of retrying the same one" do
      expect(mock_provider_manager).to receive(:select_provider)
        .with(:test_provider, executor: executor).ordered.and_return(mock_provider)
      expect(mock_provider_manager).to receive(:switch_provider).with(
        from: :test_provider,
        reason: "AgentHarness::TimeoutError",
        context: {error: "timed out"},
        executor: executor
      ).ordered.and_return(fallback_provider)
      expect(mock_provider_manager).to receive(:select_provider)
        .with(:fallback_provider, executor: executor).ordered.and_return(fallback_provider)

      response = conductor.send_message("Hello", executor: executor)

      expect(response.output).to eq("fallback response")
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

    it "passes executor overrides to the provider manager" do
      executor = instance_double(AgentHarness::CommandExecutor)

      expect(mock_provider_manager).to receive(:get_provider).with(:direct, executor: executor)
        .and_return(direct_provider)

      conductor.execute_direct("Hello", provider: :direct, executor: executor)
    end
  end
end
