# frozen_string_literal: true

RSpec.describe "token_usage_from_api_response" do
  describe AgentHarness::Providers::Base do
    let(:provider_class) do
      Class.new(described_class) do
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

    it "returns an empty hash by default" do
      expect(provider.token_usage_from_api_response({"usage" => {"tokens" => 10}})).to eq({})
    end

    it "returns an empty hash for nil body" do
      expect(provider.token_usage_from_api_response(nil)).to eq({})
    end
  end

  describe AgentHarness::Providers::Anthropic do
    let(:provider) { described_class.new }

    it "extracts input and output tokens from Anthropic response shape" do
      body = {
        "usage" => {
          "input_tokens" => 150,
          "output_tokens" => 42
        }
      }

      result = provider.token_usage_from_api_response(body)

      expect(result).to eq(input_tokens: 150, output_tokens: 42)
    end

    it "returns empty hash when usage is missing" do
      expect(provider.token_usage_from_api_response({})).to eq({})
    end

    it "returns empty hash for nil body" do
      expect(provider.token_usage_from_api_response(nil)).to eq({})
    end

    it "coerces string values to integers" do
      body = {
        "usage" => {
          "input_tokens" => "100",
          "output_tokens" => "50"
        }
      }

      result = provider.token_usage_from_api_response(body)

      expect(result).to eq(input_tokens: 100, output_tokens: 50)
    end

    it "treats nil token values as zero" do
      body = {"usage" => {}}

      result = provider.token_usage_from_api_response(body)

      expect(result).to eq(input_tokens: 0, output_tokens: 0)
    end
  end

  describe AgentHarness::Providers::Codex do
    let(:provider) { described_class.new }

    it "extracts input and output tokens from OpenAI response shape" do
      body = {
        "usage" => {
          "prompt_tokens" => 200,
          "completion_tokens" => 80
        }
      }

      result = provider.token_usage_from_api_response(body)

      expect(result).to eq(input_tokens: 200, output_tokens: 80)
    end

    it "returns empty hash when usage is missing" do
      expect(provider.token_usage_from_api_response({})).to eq({})
    end

    it "returns empty hash for nil body" do
      expect(provider.token_usage_from_api_response(nil)).to eq({})
    end

    it "coerces string values to integers" do
      body = {
        "usage" => {
          "prompt_tokens" => "300",
          "completion_tokens" => "120"
        }
      }

      result = provider.token_usage_from_api_response(body)

      expect(result).to eq(input_tokens: 300, output_tokens: 120)
    end

    it "treats nil token values as zero" do
      body = {"usage" => {}}

      result = provider.token_usage_from_api_response(body)

      expect(result).to eq(input_tokens: 0, output_tokens: 0)
    end
  end

  describe AgentHarness::Providers::Gemini do
    let(:provider) { described_class.new }

    it "extracts input and output tokens from Google response shape" do
      body = {
        "usageMetadata" => {
          "promptTokenCount" => 500,
          "candidatesTokenCount" => 250
        }
      }

      result = provider.token_usage_from_api_response(body)

      expect(result).to eq(input_tokens: 500, output_tokens: 250)
    end

    it "returns empty hash when usageMetadata is missing" do
      expect(provider.token_usage_from_api_response({})).to eq({})
    end

    it "returns empty hash for nil body" do
      expect(provider.token_usage_from_api_response(nil)).to eq({})
    end

    it "coerces string values to integers" do
      body = {
        "usageMetadata" => {
          "promptTokenCount" => "1000",
          "candidatesTokenCount" => "400"
        }
      }

      result = provider.token_usage_from_api_response(body)

      expect(result).to eq(input_tokens: 1000, output_tokens: 400)
    end

    it "treats nil token values as zero" do
      body = {"usageMetadata" => {}}

      result = provider.token_usage_from_api_response(body)

      expect(result).to eq(input_tokens: 0, output_tokens: 0)
    end
  end
end
