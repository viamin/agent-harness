# frozen_string_literal: true

RSpec.describe AgentHarness::OrchestrationConfig do
  subject(:config) { described_class.new }

  describe "#initialize" do
    it "sets defaults" do
      expect(config.enabled).to be true
      expect(config.auto_switch_on_error).to be true
      expect(config.auto_switch_on_rate_limit).to be true
    end

    it "creates nested configs" do
      expect(config.circuit_breaker_config).to be_a(AgentHarness::CircuitBreakerConfig)
      expect(config.retry_config).to be_a(AgentHarness::RetryConfig)
      expect(config.rate_limit_config).to be_a(AgentHarness::RateLimitConfig)
      expect(config.health_check_config).to be_a(AgentHarness::HealthCheckConfig)
    end
  end

  describe "#circuit_breaker" do
    it "yields circuit breaker config" do
      config.circuit_breaker do |cb|
        cb.failure_threshold = 10
      end

      expect(config.circuit_breaker_config.failure_threshold).to eq(10)
    end

    it "returns circuit breaker config" do
      result = config.circuit_breaker
      expect(result).to be(config.circuit_breaker_config)
    end
  end

  describe "#retry" do
    it "yields retry config" do
      config.retry do |r|
        r.max_attempts = 5
      end

      expect(config.retry_config.max_attempts).to eq(5)
    end
  end

  describe "#rate_limit" do
    it "yields rate limit config" do
      config.rate_limit do |rl|
        rl.default_reset_time = 7200
      end

      expect(config.rate_limit_config.default_reset_time).to eq(7200)
    end
  end

  describe "#health_check" do
    it "yields health check config" do
      config.health_check do |hc|
        hc.interval = 120
      end

      expect(config.health_check_config.interval).to eq(120)
    end
  end
end

RSpec.describe AgentHarness::CircuitBreakerConfig do
  subject(:config) { described_class.new }

  it "has default values" do
    expect(config.enabled).to be true
    expect(config.failure_threshold).to eq(5)
    expect(config.timeout).to eq(300)
    expect(config.half_open_max_calls).to eq(3)
  end
end

RSpec.describe AgentHarness::RetryConfig do
  subject(:config) { described_class.new }

  it "has default values" do
    expect(config.enabled).to be true
    expect(config.max_attempts).to eq(3)
    expect(config.base_delay).to eq(1.0)
    expect(config.max_delay).to eq(60.0)
    expect(config.exponential_base).to eq(2.0)
    expect(config.jitter).to be true
  end
end

RSpec.describe AgentHarness::RateLimitConfig do
  subject(:config) { described_class.new }

  it "has default values" do
    expect(config.enabled).to be true
    expect(config.default_reset_time).to eq(3600)
  end
end

RSpec.describe AgentHarness::HealthCheckConfig do
  subject(:config) { described_class.new }

  it "has default values" do
    expect(config.enabled).to be true
    expect(config.interval).to eq(60)
    expect(config.failure_threshold).to eq(3)
  end
end
