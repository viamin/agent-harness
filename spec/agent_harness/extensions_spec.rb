# frozen_string_literal: true

require "fileutils"

RSpec.describe AgentHarness::Extensions do
  let(:extension_class) do
    Class.new(AgentHarness::Extensions::Base) do
      def name
        :research
      end

      def description
        "Adds research instructions"
      end

      def version
        "1.0.0"
      end

      def system_prompt_additions
        ["Research before answering when context is missing."]
      end
    end
  end

  let(:extension) { extension_class.new }

  let(:provider_class) do
    Class.new(AgentHarness::Providers::Base) do
      class << self
        def provider_name
          :extension_test_provider
        end

        def binary_name
          "test-cli"
        end

        def available?
          true
        end
      end

      def capabilities
        super.merge(tool_use: true, streaming: true)
      end

      protected

      def build_command(prompt, _options)
        ["echo", prompt]
      end
    end
  end

  let(:provider) { provider_class.new }

  describe AgentHarness::Extensions::Registry do
    it "registers and fetches extensions" do
      registry = described_class.new
      registry.register(extension)

      expect(registry.fetch(:research)).to be(extension)
      expect(registry.registered?(:research)).to be(true)
    end
  end

  describe AgentHarness::Configuration do
    it "registers and resolves extensions" do
      config = described_class.new
      config.register_extension(extension)

      expect(config.resolve_extension(:research)).to be(extension)
    end
  end

  describe ".extension" do
    it "resolves configured extensions" do
      AgentHarness.configuration.register_extension(extension)

      expect(AgentHarness.extension(:research)).to be(extension)
    end
  end

  describe ".extension_compatibility" do
    it "returns compatibility reports for compatible extensions" do
      AgentHarness.configuration.register_extension(extension)

      report = AgentHarness.extension_compatibility(provider: provider, extensions: [:research]).first

      expect(report).to be_a(AgentHarness::Extensions::CompatibilityReport)
      expect(report).to be_compatible
    end

    it "reports missing provider capabilities" do
      tool_extension = Class.new(AgentHarness::Extensions::Base) do
        def name
          :tooling
        end

        def tools
          [{name: "web_search"}]
        end
      end.new

      AgentHarness.configuration.register_extension(tool_extension)

      provider_without_tools = Class.new(provider_class) do
        def capabilities
          super.merge(tool_use: false)
        end
      end.new

      report = AgentHarness.extension_compatibility(provider: provider_without_tools, extensions: [:tooling]).first
      expect(report.compatible?).to be(false)
      expect(report.missing_provider_capabilities).to eq([:tool_use])
    end
  end

  describe ".load_extensions" do
    it "loads pi package extensions from a local directory" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "package.json"), <<~JSON)
          {
            "name": "pi-autoresearch",
            "description": "Portable research helper",
            "version": "0.2.0",
            "pi": {
              "extensions": ["./extensions"]
            }
          }
        JSON

        FileUtils.mkdir_p(File.join(dir, "extensions", "autoresearch"))
        File.write(File.join(dir, "extensions", "autoresearch", "index.ts"), <<~TS)
          export default function (pi) {
            pi.registerTool({
              name: "web_research",
              description: "Look things up when context is missing"
            });
            pi.registerCommand("autoresearch", {});
          }
        TS

        loaded = AgentHarness.load_extensions(dir, adapter: :pi)

        expect(loaded.length).to eq(1)
        extension = loaded.first
        expect(extension.name).to eq(:pi_autoresearch)
        expect(extension.description).to eq("Portable research helper")
        expect(extension.version).to eq("0.2.0")
        expect(extension.tools).to eq([{name: "web_research", description: "Look things up when context is missing"}])
        expect(extension.unsupported_features).to include(:commands)
      end
    end
  end
end
