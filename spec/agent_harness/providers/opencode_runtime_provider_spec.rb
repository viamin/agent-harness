# frozen_string_literal: true

RSpec.describe AgentHarness::Providers::Opencode do
  describe "runtime provider configuration" do
    let(:provider_config) do
      {
        "minimax" => {
          "npm" => "@ai-sdk/anthropic",
          "models" => {"MiniMax-M3" => {"name" => "MiniMax-M3"}}
        }
      }
    end

    def configuration_for(runtime)
      preparation = described_class.new.send(:build_execution_preparation, provider_runtime: runtime)
      JSON.parse(preparation.file_writes.first.content)
    end

    it "preserves the provider registry when MiniMax transport identity is selected" do
      runtime = AgentHarness::ProviderRuntime.new(
        api_provider: "minimax", model: "minimax/MiniMax-M3",
        metadata: {config: {provider: provider_config}}
      )

      config = configuration_for(runtime)

      expect(config.fetch("provider")).to eq(provider_config)
      expect(config.fetch("model")).to eq("minimax/MiniMax-M3")
      expect(runtime.api_provider).to eq("minimax")
    end

    it "does not turn a transport identity into a scalar CLI provider field" do
      runtime = AgentHarness::ProviderRuntime.new(api_provider: "minimax", model: "minimax/MiniMax-M3")

      expect(configuration_for(runtime)).not_to have_key("provider")
    end

    it "retains caller provider options without a transport identity" do
      config = provider_config.merge("openrouter" => {"options" => {"baseURL" => "https://example.test/v1"}})
      runtime = AgentHarness::ProviderRuntime.new(metadata: {"config" => {"provider" => config}})

      expect(configuration_for(runtime).fetch("provider")).to eq(config)
      expect(config.fetch("minimax")).to eq(provider_config.fetch("minimax"))
    end
  end
end
