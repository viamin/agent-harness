# frozen_string_literal: true

RSpec.describe AgentHarness::ProviderHealthCheck do
  let(:registry) { AgentHarness::Providers::Registry.instance }

  before do
    registry.reset!
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
      end

      it "returns error status with CLI info" do
        result = described_class.check(:test_provider)

        expect(result[:name]).to eq(:test_provider)
        expect(result[:status]).to eq("error")
        expect(result[:message]).to include("test-cli")
        expect(result[:message]).to include("not found")
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
        expect(result[:message]).to eq("Authenticated successfully")
        expect(result[:latency_ms]).to be_a(Integer)
        expect(result[:latency_ms]).to be >= 0
      end
    end

    context "when an unexpected error occurs" do
      before do
        allow(AgentHarness::Providers::Registry).to receive(:instance).and_raise(RuntimeError, "Unexpected failure")
      end

      it "returns error status with the exception message" do
        result = described_class.check(:claude)

        expect(result[:status]).to eq("error")
        expect(result[:message]).to eq("Unexpected failure")
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

    it "skips disabled providers" do
      AgentHarness.configure do |config|
        config.provider(:provider_b) { |p| p.enabled = false }
      end

      results = described_class.check_all
      names = results.map { |r| r[:name] }
      expect(names).to contain_exactly(:provider_a)
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
      expect(output).to include("All 1 providers healthy.")
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
    end

    it "exposes check_provider on the module" do
      result = AgentHarness.check_provider(:test_provider)
      expect(result[:name]).to eq(:test_provider)
      expect(result[:status]).to eq("ok")
    end
  end
end
