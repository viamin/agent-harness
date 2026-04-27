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

  describe AgentHarness::Extensions::Base do
    it "provides default name from class" do
      ext = AgentHarness::Extensions::Base.new
      expect(ext.name).to be_a(Symbol)
    end

    it "returns nil for optional metadata" do
      ext = AgentHarness::Extensions::Base.new
      expect(ext.description).to be_nil
      expect(ext.version).to be_nil
    end

    it "returns empty arrays for capability declarations" do
      ext = AgentHarness::Extensions::Base.new
      expect(ext.tools).to eq([])
      expect(ext.mcp_servers).to eq([])
      expect(ext.system_prompt_additions).to eq([])
    end

    it "infers required capabilities from tools" do
      tool_ext = Class.new(AgentHarness::Extensions::Base) do
        def tools
          [{name: "search"}]
        end
      end.new

      expect(tool_ext.required_provider_capabilities).to include(:tool_use)
    end

    it "infers required capabilities from mcp_servers" do
      mcp_ext = Class.new(AgentHarness::Extensions::Base) do
        def mcp_servers
          [{name: "my-server", command: "npx server"}]
        end
      end.new

      expect(mcp_ext.required_provider_capabilities).to include(:mcp)
    end

    it "passes through context in lifecycle hooks" do
      ext = AgentHarness::Extensions::Base.new
      context = double("context")
      expect(ext.on_message_before(context)).to be(context)
      expect(ext.on_message_after(context)).to be(context)
      expect(ext.on_tools_available(context)).to be(context)
    end
  end

  describe AgentHarness::Extensions::MessageContext do
    it "exposes mutable and immutable attributes" do
      context = AgentHarness::Extensions::MessageContext.new(
        provider: provider,
        extensions: [extension],
        mode: :message,
        prompt: "Hello",
        options: {timeout: 30}
      )

      expect(context.provider).to be(provider)
      expect(context.extensions).to eq([extension])
      expect(context.extensions).to be_frozen
      expect(context.mode).to eq(:message)
      expect(context.prompt).to eq("Hello")

      context.prompt = "Updated"
      expect(context.prompt).to eq("Updated")
    end
  end

  describe AgentHarness::Extensions::Registry do
    it "registers and fetches extensions" do
      registry = described_class.new
      registry.register(extension)

      expect(registry.fetch(:research)).to be(extension)
      expect(registry.registered?(:research)).to be(true)
    end

    it "registers with a custom name" do
      registry = described_class.new
      registry.register(extension, as: :my_research)

      expect(registry.fetch(:my_research)).to be(extension)
      expect(registry.registered?(:my_research)).to be(true)
    end

    it "raises on unknown extension" do
      registry = described_class.new
      expect { registry.fetch(:missing) }.to raise_error(AgentHarness::ConfigurationError, /Unknown extension/)
    end

    it "rejects non-Base instances" do
      registry = described_class.new
      expect { registry.register("not_an_extension") }.to raise_error(AgentHarness::ConfigurationError)
    end

    it "lists all registered extensions" do
      registry = described_class.new
      registry.register(extension)
      expect(registry.all).to eq([extension])
    end
  end

  describe AgentHarness::Extensions::CompatibilityReport do
    it "reports compatible when no issues" do
      report = AgentHarness::Extensions::CompatibilityReport.new(
        extension: extension,
        provider: provider,
        missing_provider_capabilities: [],
        unsupported_features: []
      )

      expect(report).to be_compatible
      expect(report.to_h[:compatible]).to be(true)
    end

    it "reports incompatible when missing capabilities" do
      report = AgentHarness::Extensions::CompatibilityReport.new(
        extension: extension,
        provider: provider,
        missing_provider_capabilities: [:vision],
        unsupported_features: []
      )

      expect(report).not_to be_compatible
      expect(report.to_h[:missing_provider_capabilities]).to eq([:vision])
    end
  end

  describe AgentHarness::Extensions::Compatibility do
    it "reports compatible extensions" do
      report = described_class.report(provider: provider, extension: extension)
      expect(report).to be_compatible
    end

    it "reports missing provider capabilities" do
      tool_ext = Class.new(AgentHarness::Extensions::Base) do
        def name = :tooling
        def tools = [{name: "web_search"}]
      end.new

      no_tools_provider = Class.new(provider_class) do
        def capabilities
          super.merge(tool_use: false)
        end
      end.new

      report = described_class.report(provider: no_tools_provider, extension: tool_ext)
      expect(report).not_to be_compatible
      expect(report.missing_provider_capabilities).to eq([:tool_use])
    end

    it "raises in strict mode on incompatibility" do
      tool_ext = Class.new(AgentHarness::Extensions::Base) do
        def name = :tooling
        def tools = [{name: "web_search"}]
      end.new

      no_tools_provider = Class.new(provider_class) do
        def capabilities
          super.merge(tool_use: false)
        end
      end.new

      expect {
        described_class.check!(provider: no_tools_provider, extension: tool_ext, strict: true)
      }.to raise_error(AgentHarness::ExtensionCompatibilityError)
    end

    it "returns report without raising in non-strict mode" do
      tool_ext = Class.new(AgentHarness::Extensions::Base) do
        def name = :tooling
        def tools = [{name: "web_search"}]
      end.new

      no_tools_provider = Class.new(provider_class) do
        def capabilities
          super.merge(tool_use: false)
        end
      end.new

      report = described_class.check!(provider: no_tools_provider, extension: tool_ext, strict: false)
      expect(report).not_to be_compatible
      expect(report.missing_provider_capabilities).to eq([:tool_use])
    end

    it "checks all harness capabilities as supported" do
      AgentHarness::Extensions::Compatibility::HARNESS_CAPABILITIES.each_key do |cap|
        expect(described_class.capability_supported?(provider, cap)).to be(true)
      end
    end

    it "checks provider capabilities" do
      expect(described_class.capability_supported?(provider, :tool_use)).to be(true)
      expect(described_class.capability_supported?(provider, :streaming)).to be(true)
      expect(described_class.capability_supported?(provider, :vision)).to be(false)
    end
  end

  describe AgentHarness::Extensions::Composition do
    let(:ext_a) do
      Class.new(AgentHarness::Extensions::Base) do
        def name = :ext_a
        def tools = [{name: "tool_a"}]
        def system_prompt_additions = ["Instruction A"]
      end.new
    end

    let(:ext_b) do
      Class.new(AgentHarness::Extensions::Base) do
        def name = :ext_b
        def tools = [{name: "tool_b"}]
        def system_prompt_additions = ["Instruction B"]
      end.new
    end

    it "composes multiple extensions without conflicts" do
      result = described_class.compose([ext_a, ext_b])
      expect(result).to eq([ext_a, ext_b])
    end

    it "detects tool name conflicts" do
      ext_conflict = Class.new(AgentHarness::Extensions::Base) do
        def name = :ext_conflict
        def tools = [{name: "tool_a"}]
      end.new

      expect {
        described_class.compose([ext_a, ext_conflict])
      }.to raise_error(AgentHarness::ConfigurationError, /Tool name conflict.*tool_a/)
    end

    it "merges system prompts from multiple extensions" do
      prompts = described_class.merge_system_prompts([ext_a, ext_b])
      expect(prompts).to eq(["Instruction A", "Instruction B"])
    end

    it "merges tools from multiple extensions" do
      tools = described_class.merge_tools([ext_a, ext_b])
      expect(tools).to eq([{name: "tool_a"}, {name: "tool_b"}])
    end

    it "detects MCP server name conflicts" do
      mcp_a = Class.new(AgentHarness::Extensions::Base) do
        def name = :mcp_a
        def mcp_servers = [{name: "server"}]
      end.new

      mcp_b = Class.new(AgentHarness::Extensions::Base) do
        def name = :mcp_b
        def mcp_servers = [{name: "server"}]
      end.new

      expect {
        described_class.merge_mcp_servers([mcp_a, mcp_b])
      }.to raise_error(AgentHarness::ConfigurationError, /MCP server name conflict/)
    end

    it "returns empty array for nil or empty input" do
      expect(described_class.compose(nil)).to eq([])
      expect(described_class.compose([])).to eq([])
    end
  end

  describe AgentHarness::Configuration do
    it "registers and resolves extensions" do
      config = described_class.new
      config.register_extension(extension)

      expect(config.resolve_extension(:research)).to be(extension)
    end

    it "resolves inline extension instances" do
      config = described_class.new
      expect(config.resolve_extension(extension)).to be(extension)
    end

    it "returns nil for nil reference" do
      config = described_class.new
      expect(config.resolve_extension(nil)).to be_nil
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

  describe ".discover_extensions" do
    it "discovers extensions from a directory" do
      Dir.mktmpdir do |dir|
        # Create a pi extension subdirectory
        pi_dir = File.join(dir, "pi-autoresearch")
        FileUtils.mkdir_p(pi_dir)
        File.write(File.join(pi_dir, "package.json"), <<~JSON)
          {
            "name": "pi-autoresearch",
            "description": "Research helper",
            "version": "1.0.0"
          }
        JSON
        File.write(File.join(pi_dir, "index.ts"), <<~TS)
          export default function(pi) {
            pi.registerTool({ name: "research", description: "Research things" });
          }
        TS

        # Create a skill file
        File.write(File.join(dir, "summarize.md"), <<~MD)
          ---
          name: summarize
          description: Summarizes text
          ---

          Summarize the given text concisely.
        MD

        loaded = AgentHarness.discover_extensions(dir)
        expect(loaded.length).to eq(2)
        names = loaded.map(&:name)
        expect(names).to include(:pi_autoresearch)
        expect(names).to include(:summarize)
      end
    end

    it "skips entries that cannot be loaded" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "invalid.txt"), "not a valid extension")

        File.write(File.join(dir, "valid.md"), <<~MD)
          ---
          name: valid_skill
          ---

          Do something useful.
        MD

        loaded = AgentHarness.discover_extensions(dir)
        expect(loaded.length).to eq(1)
        expect(loaded.first.name).to eq(:valid_skill)
      end
    end

    it "returns empty array for non-existent directory" do
      loaded = AgentHarness::Extensions::Loader.discover("/tmp/nonexistent_dir_#{SecureRandom.hex(8)}")
      expect(loaded).to eq([])
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
        ext = loaded.first
        expect(ext.name).to eq(:pi_autoresearch)
        expect(ext.description).to eq("Portable research helper")
        expect(ext.version).to eq("0.2.0")
        expect(ext.tools).to eq([{name: "web_research", description: "Look things up when context is missing"}])
        expect(ext.unsupported_features).to include(:commands)
      end
    end

    it "loads Claude Code skill extensions from a markdown file" do
      Dir.mktmpdir do |dir|
        skill_path = File.join(dir, "autoresearch.md")
        File.write(skill_path, <<~MD)
          ---
          name: autoresearch
          description: Automatic research when context is missing
          version: "1.0.0"
          tools:
            - name: web_search
              description: Search the web
          ---

          When you encounter a question that cannot be answered from the current context,
          automatically search the web for relevant information before responding.
        MD

        loaded = AgentHarness.load_extensions(skill_path, adapter: :skill)

        expect(loaded.length).to eq(1)
        ext = loaded.first
        expect(ext.name).to eq(:autoresearch)
        expect(ext.description).to eq("Automatic research when context is missing")
        expect(ext.version).to eq("1.0.0")
        expect(ext.tools).to eq([{name: "web_search", description: "Search the web"}])
        expect(ext.system_prompt_additions.first).to include("automatically search the web")
      end
    end

    it "infers skill adapter for .md files" do
      Dir.mktmpdir do |dir|
        skill_path = File.join(dir, "helper.md")
        File.write(skill_path, <<~MD)
          ---
          name: helper
          ---

          Be helpful.
        MD

        loaded = AgentHarness.load_extensions(skill_path)
        expect(loaded.first.name).to eq(:helper)
      end
    end
  end

  describe AgentHarness::Extensions::Adapters::Skill do
    it "raises for missing file" do
      expect {
        described_class.load("/tmp/nonexistent_#{SecureRandom.hex(8)}.md")
      }.to raise_error(AgentHarness::ConfigurationError, /not found/)
    end

    it "raises for non-markdown file" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "skill.txt")
        File.write(path, "content")

        expect {
          described_class.load(path)
        }.to raise_error(AgentHarness::ConfigurationError, /Markdown/)
      end
    end

    it "handles files without frontmatter" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "simple.md")
        File.write(path, "Just some instructions without frontmatter.")

        loaded = described_class.load(path)
        expect(loaded.first.name).to eq(:simple)
        expect(loaded.first.system_prompt_additions).to eq(["Just some instructions without frontmatter."])
      end
    end

    it "handles empty body after frontmatter" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "empty_body.md")
        File.write(path, <<~MD)
          ---
          name: empty
          description: No instructions
          ---

        MD

        loaded = described_class.load(path)
        expect(loaded.first.name).to eq(:empty)
        expect(loaded.first.system_prompt_additions).to eq([])
      end
    end

    it "parses MCP servers from frontmatter" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "with_mcp.md")
        File.write(path, <<~MD)
          ---
          name: with_mcp
          mcp_servers:
            - name: my-server
              command: npx my-server
          ---

          Use the server.
        MD

        loaded = described_class.load(path)
        expect(loaded.first.mcp_servers).to eq([{name: "my-server", command: "npx my-server"}])
        expect(loaded.first.required_provider_capabilities).to include(:mcp)
      end
    end

    it "raises on invalid YAML frontmatter" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "bad_yaml.md")
        File.write(path, "---\n: invalid: yaml: :\n---\nBody")

        expect {
          described_class.load(path)
        }.to raise_error(AgentHarness::ConfigurationError, /Invalid YAML/)
      end
    end
  end

  describe AgentHarness::Extensions::Adapters::PiExtension do
    it "returns defensive copies of tools" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "package.json"), '{"name": "test-ext"}')
        File.write(File.join(dir, "index.ts"), <<~TS)
          pi.registerTool({ name: "my_tool", description: "A tool" });
        TS

        loaded = AgentHarness::Extensions::Adapters::Pi.load(dir)
        ext = loaded.first

        tools1 = ext.tools
        tools2 = ext.tools
        expect(tools1).to eq(tools2)
        expect(tools1).not_to be(tools2)
      end
    end
  end

  describe AgentHarness::Extensions::Loader do
    it "raises for unknown adapter" do
      expect {
        described_class.load("/tmp/something", adapter: :unknown)
      }.to raise_error(AgentHarness::ConfigurationError, /Unknown extension adapter/)
    end

    it "raises when adapter cannot be inferred" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "mystery.xyz")
        File.write(path, "content")

        expect {
          described_class.load(path)
        }.to raise_error(AgentHarness::ConfigurationError, /Could not infer adapter/)
      end
    end

    it "infers pi adapter for directories with package.json" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "package.json"), '{"name": "test"}')
        File.write(File.join(dir, "index.ts"), "// ext")

        loaded = described_class.load(dir)
        expect(loaded.first).to be_a(AgentHarness::Extensions::Adapters::PiExtension)
      end
    end

    it "infers skill adapter for .md files" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "skill.md")
        File.write(path, "---\nname: test\n---\nInstructions")

        loaded = described_class.load(path)
        expect(loaded.first).to be_a(AgentHarness::Extensions::Adapters::SkillExtension)
      end
    end
  end
end
