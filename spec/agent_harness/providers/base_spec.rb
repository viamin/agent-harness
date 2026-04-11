# frozen_string_literal: true

RSpec.describe AgentHarness::Providers::Base do
  # Create a minimal test provider
  let(:test_provider_class) do
    Class.new(described_class) do
      class << self
        def provider_name
          :test_provider
        end

        def binary_name
          "test-cli"
        end

        def available?
          false # Not actually installed
        end
      end

      def name
        "test_provider"
      end

      protected

      def build_command(prompt, options)
        ["echo", prompt]
      end
    end
  end

  let(:provider) { test_provider_class.new }

  describe "#initialize" do
    it "sets up default configuration" do
      expect(provider.config).to be_a(AgentHarness::ProviderConfig)
    end

    it "accepts custom config" do
      config = AgentHarness::ProviderConfig.new(:test)
      config.timeout = 600

      provider = test_provider_class.new(config: config)
      expect(provider.config.timeout).to eq(600)
    end
  end

  describe "#configure" do
    it "merges options into config" do
      provider.configure(timeout: 999, model: "test-model")

      expect(provider.config.timeout).to eq(999)
      expect(provider.config.model).to eq("test-model")
    end

    it "returns self for chaining" do
      result = provider.configure(timeout: 100)
      expect(result).to be(provider)
    end
  end

  describe "#name" do
    it "returns provider name" do
      expect(provider.name).to eq("test_provider")
    end
  end

  describe "#display_name" do
    it "returns capitalized name by default" do
      expect(provider.display_name).to eq("Test_provider")
    end
  end

  describe "#capabilities" do
    it "returns default capabilities" do
      caps = provider.capabilities

      expect(caps).to be_a(Hash)
      expect(caps).to have_key(:streaming)
      expect(caps).to have_key(:mcp)
    end
  end

  describe "#error_patterns" do
    it "returns empty hash by default" do
      expect(provider.error_patterns).to eq({})
    end
  end

  describe "COMMON_ERROR_PATTERNS" do
    it "is defined on the Base class" do
      expect(described_class::COMMON_ERROR_PATTERNS).to be_a(Hash)
    end

    it "includes rate_limited, auth_expired, quota_exceeded, and transient categories" do
      patterns = described_class::COMMON_ERROR_PATTERNS
      expect(patterns.keys).to contain_exactly(:rate_limited, :auth_expired, :quota_exceeded, :transient)
    end

    it "is frozen to prevent accidental mutation" do
      expect(described_class::COMMON_ERROR_PATTERNS).to be_frozen
    end

    it "classifies standalone HTTP status codes through the shared patterns" do
      expect(
        AgentHarness::ErrorTaxonomy.classify(
          StandardError.new("upstream returned HTTP 429"),
          described_class::COMMON_ERROR_PATTERNS
        )
      ).to eq(:rate_limited)

      expect(
        AgentHarness::ErrorTaxonomy.classify(
          StandardError.new("upstream returned HTTP 503"),
          described_class::COMMON_ERROR_PATTERNS
        )
      ).to eq(:transient)
    end

    it "does not misclassify embedded numeric substrings as HTTP status codes" do
      expect(
        AgentHarness::ErrorTaxonomy.classify(
          StandardError.new("request id 4294967295 failed"),
          described_class::COMMON_ERROR_PATTERNS
        )
      ).to eq(:unknown)

      expect(
        AgentHarness::ErrorTaxonomy.classify(
          StandardError.new("build 50321 aborted"),
          described_class::COMMON_ERROR_PATTERNS
        )
      ).to eq(:unknown)

      expect(
        AgentHarness::ErrorTaxonomy.classify(
          StandardError.new("job 1502 failed"),
          described_class::COMMON_ERROR_PATTERNS
        )
      ).to eq(:unknown)
    end
  end

  describe ".smoke_test_contract" do
    it "does not expose a smoke-test contract by default" do
      expect(test_provider_class.smoke_test_contract).to be_nil
    end
  end

  describe "#parse_response" do
    let(:result) { instance_double("Result", stdout: "output", stderr: "", exit_code: 0) }

    it "sets legitimate_exit_codes in response metadata" do
      response = provider.send(:parse_response, result, duration: 1.0)
      expect(response.metadata[:legitimate_exit_codes]).to eq([0])
    end

    it "treats a non-zero legitimate exit code as success" do
      provider_with_codes = Class.new(test_provider_class) do
        def execution_semantics
          super.merge(legitimate_exit_codes: [0, 1])
        end
      end.new

      non_zero_result = instance_double("Result", stdout: "done", stderr: "", exit_code: 1)
      response = provider_with_codes.send(:parse_response, non_zero_result, duration: 1.0)

      expect(response.error).to be_nil
      expect(response.success?).to be true
    end
  end

  describe "#sandboxed_environment?" do
    it "returns false with standard CommandExecutor" do
      expect(provider.sandboxed_environment?).to be false
    end

    it "returns true with DockerCommandExecutor" do
      docker_executor = instance_double(AgentHarness::DockerCommandExecutor)
      allow(docker_executor).to receive(:is_a?).with(AgentHarness::DockerCommandExecutor).and_return(true)
      docker_provider = test_provider_class.new(executor: docker_executor)
      expect(docker_provider.sandboxed_environment?).to be true
    end
  end
end
