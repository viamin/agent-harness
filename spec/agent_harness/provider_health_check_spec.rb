# frozen_string_literal: true

RSpec.describe AgentHarness::ProviderHealthCheck do
  let(:registry) { AgentHarness::Providers::Registry.instance }

  before do
    registry.reset!
    allow_any_instance_of(AgentHarness::CommandExecutor).to receive(:which) do |_executor, binary|
      case binary
      when "test-cli", "provider-a"
        "/tmp/#{binary}"
      end
    end
  end

  describe ".check" do
    context "when provider is not registered" do
      it "returns error status" do
        result = described_class.check(:nonexistent)

        expect(result[:name]).to eq(:nonexistent)
        expect(result[:status]).to eq("error")
        expect(result[:message]).to eq("Provider not registered")
        expect(result[:latency_ms]).to be_a(Integer)
      end
    end

    context "when provider CLI is not available" do
      let(:provider_class) do
        Class.new(AgentHarness::Providers::Base) do
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

      before do
        registry.register(:test_provider, provider_class)
        allow_any_instance_of(AgentHarness::CommandExecutor).to receive(:which).with("test-cli").and_return(nil)
      end

      it "returns error status with CLI info" do
        result = described_class.check(:test_provider)

        expect(result[:name]).to eq(:test_provider)
        expect(result[:status]).to eq("error")
        expect(result[:message]).to include("test-cli")
        expect(result[:message]).to include("not found")
        expect(result[:error_category]).to eq(:installation)
        expect(result[:check]).to eq(:availability)
      end

      it "still runs host preflight when provider_runtime is an empty hash" do
        result = described_class.check(:test_provider, provider_runtime: {})

        expect(result[:name]).to eq(:test_provider)
        expect(result[:status]).to eq("error")
        expect(result[:message]).to include("test-cli")
        expect(result[:message]).to include("not found")
        expect(result[:error_category]).to eq(:installation)
        expect(result[:check]).to eq(:availability)
      end

      it "still runs host preflight when provider_runtime only contains local overrides" do
        result = described_class.check(:test_provider, provider_runtime: {model: "runtime-only"})

        expect(result[:name]).to eq(:test_provider)
        expect(result[:status]).to eq("error")
        expect(result[:message]).to include("test-cli")
        expect(result[:message]).to include("not found")
        expect(result[:error_category]).to eq(:installation)
        expect(result[:check]).to eq(:availability)
      end
    end

    context "when authentication fails" do
      let(:provider_class) do
        Class.new(AgentHarness::Providers::Base) do
          class << self
            def provider_name
              :test_provider
            end

            def binary_name
              "test-cli"
            end

            def available?
              true
            end
          end

          def smoke_test(timeout: nil, provider_runtime: nil)
            {ok: true, status: "ok", message: "Smoke test passed", error_category: nil}
          end
        end
      end

      before do
        registry.register(:test_provider, provider_class)
        allow(AgentHarness::Authentication).to receive(:auth_status)
          .with(:test_provider)
          .and_return({valid: false, expires_at: nil, error: "Invalid API key"})
      end

      it "returns error status with auth message" do
        result = described_class.check(:test_provider)

        expect(result[:name]).to eq(:test_provider)
        expect(result[:status]).to eq("error")
        expect(result[:message]).to eq("Invalid API key")
        expect(result[:error_category]).to eq(:authentication)
        expect(result[:check]).to eq(:authentication)
      end
    end

    context "when provider health check reports unhealthy" do
      let(:provider_class) do
        Class.new(AgentHarness::Providers::Base) do
          class << self
            def provider_name
              :test_provider
            end

            def binary_name
              "test-cli"
            end

            def available?
              true
            end
          end

          def health_status
            {healthy: false, message: "Endpoint unreachable"}
          end
        end
      end

      before do
        registry.register(:test_provider, provider_class)
        allow(AgentHarness::Authentication).to receive(:auth_status)
          .with(:test_provider)
          .and_return({valid: true, expires_at: nil, error: nil})
      end

      it "returns degraded status" do
        result = described_class.check(:test_provider)

        expect(result[:name]).to eq(:test_provider)
        expect(result[:status]).to eq("degraded")
        expect(result[:message]).to eq("Endpoint unreachable")
        expect(result[:error_category]).to eq(:transient)
        expect(result[:check]).to eq(:provider_health)
      end
    end

    context "when provider config validation fails" do
      let(:provider_class) do
        Class.new(AgentHarness::Providers::Base) do
          class << self
            def provider_name
              :test_provider
            end

            def binary_name
              "test-cli"
            end

            def available?
              true
            end
          end

          def validate_config
            {valid: false, errors: ["Missing model name"]}
          end
        end
      end

      before do
        registry.register(:test_provider, provider_class)
        allow(AgentHarness::Authentication).to receive(:auth_status)
          .with(:test_provider)
          .and_return({valid: true, expires_at: nil, error: nil})
      end

      it "returns degraded status with config errors" do
        result = described_class.check(:test_provider)

        expect(result[:name]).to eq(:test_provider)
        expect(result[:status]).to eq("degraded")
        expect(result[:message]).to include("Missing model name")
        expect(result[:error_category]).to eq(:configuration)
        expect(result[:check]).to eq(:configuration)
      end
    end

    context "when provider config validation fails with nil errors" do
      let(:provider_class) do
        Class.new(AgentHarness::Providers::Base) do
          class << self
            def provider_name
              :test_provider
            end

            def binary_name
              "test-cli"
            end

            def available?
              true
            end
          end

          def validate_config
            {valid: false, errors: nil}
          end
        end
      end

      before do
        registry.register(:test_provider, provider_class)
        allow(AgentHarness::Authentication).to receive(:auth_status)
          .with(:test_provider)
          .and_return({valid: true, expires_at: nil, error: nil})
      end

      it "returns degraded status with a fallback message" do
        result = described_class.check(:test_provider)

        expect(result[:name]).to eq(:test_provider)
        expect(result[:status]).to eq("degraded")
        expect(result[:message]).to eq("Configuration issues: check provider configuration")
        expect(result[:error_category]).to eq(:configuration)
      end
    end

    context "when all checks pass" do
      let(:provider_class) do
        Class.new(AgentHarness::Providers::Base) do
          class << self
            def provider_name
              :test_provider
            end

            def binary_name
              "test-cli"
            end

            def available?
              true
            end
          end

          def smoke_test(timeout: nil, provider_runtime: nil)
            {ok: true, status: "ok", message: "Smoke test passed", error_category: nil}
          end
        end
      end

      before do
        registry.register(:test_provider, provider_class)
        allow(AgentHarness::Authentication).to receive(:auth_status)
          .with(:test_provider)
          .and_return({valid: true, expires_at: nil, error: nil})
      end

      it "returns ok status" do
        result = described_class.check(:test_provider)

        expect(result[:name]).to eq(:test_provider)
        expect(result[:status]).to eq("ok")
        expect(result[:message]).to eq(
          "Registered, authenticated, and smoke test passed (health/config checks use defaults)"
        )
        expect(result[:check]).to eq(:smoke_test)
        expect(result[:latency_ms]).to be_a(Integer)
        expect(result[:latency_ms]).to be >= 0
      end
    end

    context "when the provider does not publish a smoke-test contract" do
      let(:provider_class) do
        Class.new(AgentHarness::Providers::Base) do
          class << self
            def provider_name
              :test_provider
            end

            def binary_name
              "test-cli"
            end

            def available?
              true
            end
          end
        end
      end

      before do
        registry.register(:test_provider, provider_class)
        allow(AgentHarness::Authentication).to receive(:auth_status)
          .with(:test_provider)
          .and_return({valid: true, expires_at: nil, error: nil})
      end

      it "returns degraded without attempting a smoke test" do
        result = described_class.check(:test_provider)

        expect(result[:status]).to eq("degraded")
        expect(result[:message]).to eq(
          "Registered and authenticated; health/config checks use defaults and smoke test is unavailable"
        )
        expect(result[:error_category]).to eq(:configuration)
        expect(result[:check]).to eq(:smoke_test)
      end
    end

    context "when provider overrides health_status" do
      let(:provider_class) do
        Class.new(AgentHarness::Providers::Base) do
          class << self
            def provider_name
              :test_provider
            end

            def binary_name
              "test-cli"
            end

            def available?
              true
            end
          end

          def health_status
            {healthy: true, message: "Endpoint reachable"}
          end

          def smoke_test(timeout: nil, provider_runtime: nil)
            {ok: true, status: "ok", message: "Smoke test passed", error_category: nil}
          end
        end
      end

      before do
        registry.register(:test_provider, provider_class)
        allow(AgentHarness::Authentication).to receive(:auth_status)
          .with(:test_provider)
          .and_return({valid: true, expires_at: nil, error: nil})
      end

      it "returns ok with 'All checks passed' message" do
        result = described_class.check(:test_provider)

        expect(result[:name]).to eq(:test_provider)
        expect(result[:status]).to eq("ok")
        expect(result[:message]).to eq("All checks passed")
      end
    end

    context "when auth status check is not implemented" do
      let(:provider_class) do
        Class.new(AgentHarness::Providers::Base) do
          class << self
            def provider_name
              :test_provider
            end

            def binary_name
              "test-cli"
            end

            def available?
              true
            end
          end

          def smoke_test(timeout: nil, provider_runtime: nil)
            {ok: true, status: "ok", message: "Smoke test passed", error_category: nil}
          end
        end
      end

      before do
        registry.register(:test_provider, provider_class)
        allow(AgentHarness::Authentication).to receive(:auth_status)
          .with(:test_provider)
          .and_return({valid: false, expires_at: nil, error: "Auth status check not implemented for test_provider"})
      end

      it "returns degraded status but continues through health and config checks" do
        result = described_class.check(:test_provider)

        expect(result[:name]).to eq(:test_provider)
        expect(result[:status]).to eq("degraded")
        expect(result[:message]).to eq("Auth status check not implemented; health, config, and smoke tests passed")
      end
    end

    context "when auth status returns explicit implemented: false flag" do
      let(:provider_class) do
        Class.new(AgentHarness::Providers::Base) do
          class << self
            def provider_name
              :test_provider
            end

            def binary_name
              "test-cli"
            end

            def available?
              true
            end
          end

          def smoke_test(timeout: nil, provider_runtime: nil)
            {ok: true, status: "ok", message: "Smoke test passed", error_category: nil}
          end
        end
      end

      before do
        registry.register(:test_provider, provider_class)
        allow(AgentHarness::Authentication).to receive(:auth_status)
          .with(:test_provider)
          .and_return({valid: false, expires_at: nil, implemented: false, error: nil})
      end

      it "returns degraded status via explicit flag" do
        result = described_class.check(:test_provider)

        expect(result[:name]).to eq(:test_provider)
        expect(result[:status]).to eq("degraded")
        expect(result[:message]).to eq("Auth status check not implemented; health, config, and smoke tests passed")
      end
    end

    context "when auth status returns explicit reason: :not_implemented flag" do
      let(:provider_class) do
        Class.new(AgentHarness::Providers::Base) do
          class << self
            def provider_name
              :test_provider
            end

            def binary_name
              "test-cli"
            end

            def available?
              true
            end
          end

          def smoke_test(timeout: nil, provider_runtime: nil)
            {ok: true, status: "ok", message: "Smoke test passed", error_category: nil}
          end
        end
      end

      before do
        registry.register(:test_provider, provider_class)
        allow(AgentHarness::Authentication).to receive(:auth_status)
          .with(:test_provider)
          .and_return({valid: false, expires_at: nil, reason: :not_implemented, error: nil})
      end

      it "returns degraded status via explicit reason flag" do
        result = described_class.check(:test_provider)

        expect(result[:name]).to eq(:test_provider)
        expect(result[:status]).to eq("degraded")
        expect(result[:message]).to eq("Auth status check not implemented; health, config, and smoke tests passed")
      end
    end

    context "when auth is not implemented but health check fails" do
      let(:provider_class) do
        Class.new(AgentHarness::Providers::Base) do
          class << self
            def provider_name
              :test_provider
            end

            def binary_name
              "test-cli"
            end

            def available?
              true
            end
          end

          def health_status
            {healthy: false, message: "Endpoint unreachable"}
          end
        end
      end

      before do
        registry.register(:test_provider, provider_class)
        allow(AgentHarness::Authentication).to receive(:auth_status)
          .with(:test_provider)
          .and_return({valid: false, expires_at: nil, error: "Auth status check not implemented for test_provider"})
      end

      it "surfaces the health check failure instead of just auth degraded" do
        result = described_class.check(:test_provider)

        expect(result[:name]).to eq(:test_provider)
        expect(result[:status]).to eq("degraded")
        expect(result[:message]).to eq("Endpoint unreachable")
      end
    end

    context "when the provider smoke test fails with a normalized category" do
      let(:provider_class) do
        Class.new(AgentHarness::Providers::Base) do
          class << self
            def provider_name
              :test_provider
            end

            def binary_name
              "test-cli"
            end

            def available?
              true
            end
          end

          def smoke_test(timeout: nil, provider_runtime: nil)
            @seen_timeout = timeout
            @seen_provider_runtime = provider_runtime
            {
              ok: false,
              status: "error",
              message: "Rate limit exceeded",
              error_category: :rate_limited
            }
          end
        end
      end

      before do
        registry.register(:test_provider, provider_class)
        allow(AgentHarness::Authentication).to receive(:auth_status)
          .with(:test_provider)
          .and_return({valid: true, expires_at: nil, error: nil})
      end

      it "maps adapter taxonomy categories onto the public health-check vocabulary" do
        result = described_class.check(:test_provider, timeout: 7, provider_runtime: {model: "test-model"})

        expect(result[:status]).to eq("error")
        expect(result[:message]).to eq("Rate limit exceeded")
        expect(result[:error_category]).to eq(:rate_limit)
        expect(result[:check]).to eq(:smoke_test)
      end
    end

    context "when a custom executor is provided" do
      let(:custom_executor) { instance_double(AgentHarness::CommandExecutor) }
      let(:provider_class) do
        Class.new(AgentHarness::Providers::Base) do
          class << self
            attr_reader :last_executor, :last_provider_runtime, :last_timeout

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

          def health_status
            {healthy: false, message: "Host auth check should not run here"}
          end

          def smoke_test(timeout: nil, provider_runtime: nil)
            self.class.instance_variable_set(:@last_executor, executor)
            self.class.instance_variable_set(:@last_provider_runtime, provider_runtime)
            self.class.instance_variable_set(:@last_timeout, timeout)
            {ok: true, status: "ok", message: "Smoke test passed", error_category: nil}
          end
        end
      end

      before do
        registry.register(:test_provider, provider_class)
      end

      it "skips host-only preflight checks and runs the smoke test through the supplied executor" do
        expect(AgentHarness::Authentication).not_to receive(:auth_status)

        result = described_class.check(
          :test_provider,
          timeout: 9,
          executor: custom_executor,
          provider_runtime: {model: "runtime-model"}
        )

        expect(result[:status]).to eq("ok")
        expect(result[:message]).to eq("Smoke test passed using the supplied execution context")
        expect(provider_class.last_executor).to eq(custom_executor)
        expect(provider_class.last_timeout).to eq(9)
        expect(provider_class.last_provider_runtime).to eq({model: "runtime-model"})
      end
    end

    context "when a local CommandExecutor subclass is provided explicitly" do
      let(:logging_executor_class) do
        Class.new(AgentHarness::CommandExecutor) do
          def which(binary)
            return "/tmp/#{binary}" if binary == "test-cli"

            super
          end
        end
      end
      let(:logging_executor) { logging_executor_class.new }
      let(:provider_class) do
        Class.new(AgentHarness::Providers::Base) do
          class << self
            attr_reader :last_executor

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

          def smoke_test(timeout: nil, provider_runtime: nil)
            self.class.instance_variable_set(:@last_executor, executor)
            {ok: true, status: "ok", message: "Smoke test passed", error_category: nil}
          end
        end
      end

      before do
        registry.register(:test_provider, provider_class)
        allow(AgentHarness::Authentication).to receive(:auth_status)
          .with(:test_provider)
          .and_return({valid: true, expires_at: nil, error: nil})
      end

      it "runs host preflight against the supplied executor" do
        result = described_class.check(:test_provider, executor: logging_executor)

        expect(result[:status]).to eq("ok")
        expect(result[:message]).to eq(
          "Registered, authenticated, and smoke test passed (health/config checks use defaults)"
        )
        expect(provider_class.last_executor).to eq(logging_executor)
      end
    end

    context "when a non-host executor is configured globally" do
      let(:container_executor) { AgentHarness::DockerCommandExecutor.allocate }
      let(:provider_class) do
        Class.new(AgentHarness::Providers::Base) do
          class << self
            attr_reader :last_executor

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

          def smoke_test(timeout: nil, provider_runtime: nil)
            self.class.instance_variable_set(:@last_executor, executor)
            {ok: true, status: "ok", message: "Smoke test passed", error_category: nil}
          end
        end
      end

      before do
        registry.register(:test_provider, provider_class)
        allow(AgentHarness.configuration).to receive(:command_executor).and_return(container_executor)
      end

      it "skips host-only preflight checks and uses the configured executor for the smoke test" do
        expect(AgentHarness::Authentication).not_to receive(:auth_status)

        result = described_class.check(:test_provider)

        expect(result[:status]).to eq("ok")
        expect(result[:message]).to eq("Smoke test passed using the supplied execution context")
        expect(provider_class.last_executor).to eq(container_executor)
      end
    end

    context "when a local CommandExecutor subclass is configured globally" do
      let(:logging_executor_class) { Class.new(AgentHarness::CommandExecutor) }
      let(:logging_executor) { logging_executor_class.new }
      let(:provider_class) do
        Class.new(AgentHarness::Providers::Base) do
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

          def smoke_test(timeout: nil, provider_runtime: nil)
            {ok: true, status: "ok", message: "Smoke test passed", error_category: nil}
          end
        end
      end

      before do
        registry.register(:test_provider, provider_class)
        allow(AgentHarness.configuration).to receive(:command_executor).and_return(logging_executor)
        allow(logging_executor).to receive(:which).with("test-cli").and_return(nil)
      end

      it "still runs host preflight checks" do
        expect(AgentHarness::Authentication).not_to receive(:auth_status)

        result = described_class.check(:test_provider)

        expect(result[:status]).to eq("error")
        expect(result[:message]).to include("test-cli")
        expect(result[:message]).to include("not found")
        expect(result[:error_category]).to eq(:installation)
        expect(result[:check]).to eq(:availability)
      end
    end

    context "when the smoke test reports an authentication-specific adapter category" do
      let(:provider_class) do
        Class.new(AgentHarness::Providers::Base) do
          class << self
            def provider_name
              :test_provider
            end

            def binary_name
              "test-cli"
            end

            def available?
              true
            end
          end

          def smoke_test(timeout: nil, provider_runtime: nil)
            {
              ok: false,
              status: "error",
              message: "Session expired",
              error_category: :auth_expired
            }
          end
        end
      end

      before do
        registry.register(:test_provider, provider_class)
        allow(AgentHarness::Authentication).to receive(:auth_status)
          .with(:test_provider)
          .and_return({valid: true, expires_at: nil, error: nil})
      end

      it "normalizes the failure to :authentication" do
        result = described_class.check(:test_provider)

        expect(result[:status]).to eq("error")
        expect(result[:error_category]).to eq(:authentication)
        expect(result[:check]).to eq(:smoke_test)
      end
    end

    context "when an unexpected error occurs" do
      before do
        allow(AgentHarness::Providers::Registry).to receive(:instance).and_raise(RuntimeError, "Unexpected failure")
      end

      it "returns error status with a sanitized message (class only, no raw details)" do
        result = described_class.check(:claude)

        expect(result[:status]).to eq("error")
        expect(result[:message]).to eq("Health check failed: RuntimeError")
        expect(result[:message]).not_to include("Unexpected failure")
      end

      it "logs only the exception class without the message" do
        require "logger"
        logger = instance_double(Logger, error: nil)
        allow(AgentHarness).to receive(:logger).and_return(logger)

        described_class.check(:claude)

        expect(logger).to have_received(:error).with("ProviderHealthCheck error for claude: RuntimeError")
      end
    end

    context "when a NotImplementedError occurs" do
      before do
        allow(AgentHarness::Providers::Registry).to receive(:instance)
          .and_raise(NotImplementedError, "provider must implement #health_status")
      end

      it "includes the exception message for easier diagnosis" do
        result = described_class.check(:claude)

        expect(result[:status]).to eq("error")
        expect(result[:message]).to eq("Health check failed: NotImplementedError: provider must implement #health_status")
      end
    end

    context "when a ConfigurationError occurs" do
      before do
        allow(AgentHarness::Providers::Registry).to receive(:instance)
          .and_raise(AgentHarness::ConfigurationError, "smoke_test_contract must define a non-empty :prompt")
      end

      it "includes the configuration failure details for easier diagnosis" do
        result = described_class.check(:claude)

        expect(result[:status]).to eq("error")
        expect(result[:message]).to eq(
          "Health check failed: AgentHarness::ConfigurationError: smoke_test_contract must define a non-empty :prompt"
        )
        expect(result[:error_category]).to eq(:configuration)
        expect(result[:check]).to eq(:provider_health)
      end
    end

    context "when the check exceeds the timeout" do
      before do
        allow(Timeout).to receive(:timeout).and_raise(Timeout::Error)
      end

      it "returns error status with timeout message" do
        result = described_class.check(:claude, timeout: 2)

        expect(result[:status]).to eq("error")
        expect(result[:message]).to include("timed out")
        expect(result[:message]).to include("2s")
        expect(result[:error_category]).to eq(:timeout)
        expect(result[:check]).to eq(:timeout)
      end
    end

    context "when timeout is nil or non-positive" do
      before do
        registry.register(:test_provider, Class.new(AgentHarness::Providers::Base) do
          class << self
            def provider_name = :test_provider
            def binary_name = "test-cli"
            def available? = false
          end
        end)
        allow_any_instance_of(AgentHarness::CommandExecutor).to receive(:which).with("test-cli").and_return(nil)
      end

      it "falls back to configured timeout when nil is passed" do
        result = described_class.check(:test_provider, timeout: nil)
        expect(result[:status]).to eq("error")
        expect(result[:message]).not_to include("timed out")
      end

      it "falls back to configured timeout when zero is passed" do
        result = described_class.check(:test_provider, timeout: 0)
        expect(result[:status]).to eq("error")
        expect(result[:message]).not_to include("timed out")
      end

      it "falls back to configured timeout when negative value is passed" do
        result = described_class.check(:test_provider, timeout: -1)
        expect(result[:status]).to eq("error")
        expect(result[:message]).not_to include("timed out")
      end
    end

    context "when provider_name is nil" do
      it "returns error status with a safe name" do
        result = described_class.check(nil)

        expect(result[:name]).to eq(:unknown)
        expect(result[:status]).to eq("error")
      end
    end
  end

  describe ".configured_timeout" do
    after do
      AgentHarness.reset!
    end

    it "honors a user-specified timeout from configuration" do
      AgentHarness.configure do |config|
        config.orchestration do |o|
          o.health_check do |h|
            h.timeout = 10
          end
        end
      end

      # Use a provider that will fail fast (unregistered) so we can inspect
      # the timeout value that gets embedded in a Timeout::Error message.
      allow(Timeout).to receive(:timeout).and_raise(Timeout::Error)

      result = described_class.check(:nonexistent)
      expect(result[:status]).to eq("error")
      expect(result[:message]).to include("10s")
    end
  end

  describe ".check_all" do
    let(:provider_class_a) do
      Class.new(AgentHarness::Providers::Base) do
        class << self
          def provider_name
            :provider_a
          end

          def binary_name
            "provider-a"
          end

          def available?
            true
          end
        end

        def smoke_test(timeout: nil, provider_runtime: nil)
          {ok: true, status: "ok", message: "Smoke test passed", error_category: nil}
        end
      end
    end

    let(:provider_class_b) do
      Class.new(AgentHarness::Providers::Base) do
        class << self
          def provider_name
            :provider_b
          end

          def binary_name
            "provider-b"
          end

          def available?
            false
          end
        end
      end
    end

    before do
      registry.register(:provider_a, provider_class_a)
      registry.register(:provider_b, provider_class_b)

      AgentHarness.configure do |config|
        config.provider(:provider_a) { |p| p.enabled = true }
        config.provider(:provider_b) { |p| p.enabled = true }
      end

      allow(AgentHarness::Authentication).to receive(:auth_status)
        .and_return({valid: false, expires_at: nil, error: "Not configured"})
      allow(AgentHarness::Authentication).to receive(:auth_status)
        .with(:provider_a)
        .and_return({valid: true, expires_at: nil, error: nil})
    end

    after do
      AgentHarness.reset!
    end

    it "returns results for all configured providers" do
      results = described_class.check_all

      names = results.map { |r| r[:name] }
      expect(names).to contain_exactly(:provider_a, :provider_b)
    end

    it "includes both passing and failing providers" do
      results = described_class.check_all

      ok_result = results.find { |r| r[:name] == :provider_a }
      error_result = results.find { |r| r[:name] == :provider_b }

      expect(ok_result[:status]).to eq("ok")
      expect(error_result[:status]).to eq("error")
    end

    it "accepts a timeout parameter" do
      results = described_class.check_all(timeout: 10)
      expect(results).to be_an(Array)
    end

    it "rejects a shared provider_runtime override" do
      expect {
        described_class.check_all(provider_runtime: {env: {"API_KEY" => "secret"}})
      }.to raise_error(ArgumentError, "provider_runtime is only supported for single-provider health checks")
    end

    it "skips disabled providers" do
      AgentHarness.configure do |config|
        config.provider(:provider_b) { |p| p.enabled = false }
      end

      results = described_class.check_all
      names = results.map { |r| r[:name] }
      expect(names).to contain_exactly(:provider_a)
    end

    it "returns empty results when all configured providers are disabled" do
      AgentHarness.configure do |config|
        config.provider(:provider_a) { |p| p.enabled = false }
        config.provider(:provider_b) { |p| p.enabled = false }
      end

      results = described_class.check_all
      expect(results).to be_empty
    end

    it "falls back to all registered providers when none are configured" do
      AgentHarness.reset!
      results = described_class.check_all

      names = results.map { |r| r[:name] }
      expect(names).to include(:provider_a, :provider_b)
    end
  end

  describe ".format_results" do
    it "formats successful results with checkmarks" do
      results = [
        {name: :openai, status: "ok", message: "Authenticated successfully", latency_ms: 120}
      ]

      output = described_class.format_results(results)

      expect(output).to include("✓")
      expect(output).to include("openai")
      expect(output).to include("OK")
      expect(output).to include("120ms")
      expect(output).to include("All 1 provider healthy.")
    end

    it "formats failed results with X marks" do
      results = [
        {name: :anthropic, status: "error", message: "Invalid API key", latency_ms: 50}
      ]

      output = described_class.format_results(results)

      expect(output).to include("✗")
      expect(output).to include("anthropic")
      expect(output).to include("Invalid API key")
      expect(output).to include("1 failed")
    end

    it "formats degraded results with tilde markers" do
      results = [
        {name: :gemini, status: "degraded", message: "Endpoint unreachable", latency_ms: 200}
      ]

      output = described_class.format_results(results)

      expect(output).to include("~")
      expect(output).to include("gemini")
      expect(output).to include("Endpoint unreachable")
      expect(output).to include("1 degraded")
    end

    it "formats mixed results correctly" do
      results = [
        {name: :openai, status: "ok", message: "Authenticated successfully", latency_ms: 120},
        {name: :anthropic, status: "error", message: "Invalid API key", latency_ms: nil},
        {name: :gemini, status: "degraded", message: "Endpoint unreachable", latency_ms: 50}
      ]

      output = described_class.format_results(results)

      expect(output).to include("Checking providers...")
      expect(output).to include("✓")
      expect(output).to include("✗")
      expect(output).to include("~")
      expect(output).to include("1 failed")
      expect(output).to include("1 degraded")
    end

    it "uses singular 'provider' when only one result" do
      results = [
        {name: :openai, status: "error", message: "Failed", latency_ms: 50}
      ]

      output = described_class.format_results(results)

      expect(output).to include("1 provider checked")
      expect(output).not_to include("providers checked")
    end

    it "uses plural 'providers' when multiple results" do
      results = [
        {name: :openai, status: "ok", message: "OK", latency_ms: 50},
        {name: :claude, status: "ok", message: "OK", latency_ms: 50}
      ]

      output = described_class.format_results(results)

      expect(output).to include("All 2 providers healthy.")
    end

    it "handles empty results with explicit message" do
      output = described_class.format_results([])

      expect(output).to include("Checking providers...")
      expect(output).to include("No providers checked.")
      expect(output).not_to include("All 0")
    end

    it "handles nil latency for ok results" do
      results = [
        {name: :test, status: "ok", message: "OK", latency_ms: nil}
      ]

      output = described_class.format_results(results)
      expect(output).to include("✓")
      expect(output).not_to include("ms")
    end
  end

  describe "integration with AgentHarness module" do
    let(:provider_class) do
      Class.new(AgentHarness::Providers::Base) do
        class << self
          def provider_name
            :test_provider
          end

          def binary_name
            "test-cli"
          end

          def available?
            true
          end

          def smoke_test_contract
            AgentHarness::Providers::Base::DEFAULT_SMOKE_TEST_CONTRACT
          end
        end

        def smoke_test(timeout: nil, provider_runtime: nil)
          {ok: true, status: "ok", message: "Smoke test passed", error_category: nil}
        end
      end
    end

    before do
      registry.register(:test_provider, provider_class)

      AgentHarness.configure do |config|
        config.provider(:test_provider) { |p| p.enabled = true }
      end

      allow(AgentHarness::Authentication).to receive(:auth_status)
        .and_return({valid: false, expires_at: nil, error: "Not configured"})
      allow(AgentHarness::Authentication).to receive(:auth_status)
        .with(:test_provider)
        .and_return({valid: true, expires_at: nil, error: nil})
    end

    after do
      AgentHarness.reset!
    end

    it "exposes check_providers on the module" do
      results = AgentHarness.check_providers
      expect(results).to be_an(Array)
      test_result = results.find { |r| r[:name] == :test_provider }
      expect(test_result[:status]).to eq("ok")
      expect(test_result[:message]).to eq(
        "Registered, authenticated, and smoke test passed (health/config checks use defaults)"
      )
    end

    it "exposes check_provider on the module" do
      result = AgentHarness.check_provider(:test_provider)
      expect(result[:name]).to eq(:test_provider)
      expect(result[:status]).to eq("ok")
      expect(result[:message]).to eq(
        "Registered, authenticated, and smoke test passed (health/config checks use defaults)"
      )
    end

    it "rejects provider_runtime on check_providers" do
      expect {
        AgentHarness.check_providers(provider_runtime: {env: {"API_KEY" => "secret"}})
      }.to raise_error(ArgumentError, "provider_runtime is only supported for single-provider health checks")
    end

    it "exposes smoke_test_contract on the module" do
      contract = AgentHarness.smoke_test_contract(:test_provider)

      expect(contract).to include(prompt: "Reply with exactly OK.")
    end
  end
end
