# frozen_string_literal: true

require "json"

module AgentHarness
  module Extensions
    class Base
      def name
        self.class.name.split("::").last&.downcase&.to_sym
      end

      def description
        nil
      end

      def version
        nil
      end

      def on_message_before(context)
        context
      end

      def on_message_after(context)
        context
      end

      def on_tool_call(context)
        context
      end

      def tools
        []
      end

      def mcp_servers
        []
      end

      def system_prompt_additions
        []
      end

      def required_provider_capabilities
        required = []
        required << :tool_use if tools.any?
        required << :mcp if mcp_servers.any?
        required
      end
    end

    class MessageContext
      attr_accessor :prompt, :messages, :tools, :options, :response, :metadata
      attr_reader :provider, :extensions, :mode

      def initialize(provider:, extensions:, mode:, options:, prompt: nil, messages: nil, tools: nil, response: nil,
        metadata: {})
        @provider = provider
        @extensions = extensions.freeze
        @mode = mode
        @options = options
        @prompt = prompt
        @messages = messages
        @tools = tools
        @response = response
        @metadata = metadata
      end
    end

    class CompatibilityReport
      attr_reader :extension, :provider, :missing_provider_capabilities, :unsupported_features

      def initialize(extension:, provider:, missing_provider_capabilities:, unsupported_features:)
        @extension = extension
        @provider = provider
        @missing_provider_capabilities = missing_provider_capabilities.freeze
        @unsupported_features = unsupported_features.freeze
      end

      def compatible?
        @missing_provider_capabilities.empty? && @unsupported_features.empty?
      end

      def to_h
        {
          extension: extension.name,
          provider: provider.class.provider_name,
          compatible: compatible?,
          missing_provider_capabilities: missing_provider_capabilities.dup,
          unsupported_features: unsupported_features.dup
        }
      end
    end

    module Compatibility
      HARNESS_CAPABILITIES = {
        message_hooks: true,
        response_hooks: true,
        system_prompt_additions: true
      }.freeze

      module_function

      def report(provider:, extension:)
        required = Array(extension.required_provider_capabilities).map(&:to_sym)
        missing = required.reject { |capability| capability_supported?(provider, capability) }
        unsupported = Array(extension.respond_to?(:unsupported_features) ? extension.unsupported_features : []).map(&:to_sym)

        CompatibilityReport.new(
          extension: extension,
          provider: provider,
          missing_provider_capabilities: missing,
          unsupported_features: unsupported
        )
      end

      def check!(provider:, extension:)
        compatibility = report(provider: provider, extension: extension)
        return compatibility if compatibility.compatible?

        raise ExtensionCompatibilityError.new(
          "Extension '#{extension.name}' is not compatible with provider '#{provider.class.provider_name}'",
          provider: provider.class.provider_name,
          extension: extension.name,
          report: compatibility.to_h
        )
      end

      def capability_supported?(provider, capability)
        return HARNESS_CAPABILITIES.fetch(capability) if HARNESS_CAPABILITIES.key?(capability)

        case capability
        when :tool_use
          provider.capabilities[:tool_use]
        when :mcp
          provider.capabilities[:mcp]
        when :streaming
          provider.capabilities[:streaming]
        when :file_upload
          provider.capabilities[:file_upload]
        when :vision
          provider.capabilities[:vision]
        when :json_mode
          provider.capabilities[:json_mode]
        when :dangerous_mode
          provider.capabilities[:dangerous_mode]
        when :chat
          provider.supports_chat?
        when :text_mode
          provider.supports_text_mode?
        else
          false
        end
      end
    end

    class Registry
      def initialize
        @extensions = {}
      end

      def register(extension, as: nil)
        unless extension.is_a?(Base)
          raise ConfigurationError, "Extension must be an AgentHarness::Extensions::Base instance"
        end

        key = (as || extension.name).to_sym
        @extensions[key] = extension
      end

      def fetch(name)
        @extensions.fetch(name.to_sym) do
          raise ConfigurationError, "Unknown extension: #{name}"
        end
      end

      def registered?(name)
        @extensions.key?(name.to_sym)
      end

      def all
        @extensions.values.dup
      end
    end

    module Loader
      module_function

      def load(path, adapter: nil)
        resolved_path = File.expand_path(path)
        adapter_name = normalize_adapter(adapter, resolved_path)

        case adapter_name
        when :pi
          Adapters::Pi.load(resolved_path)
        else
          raise ConfigurationError, "Unknown extension adapter: #{adapter_name.inspect}"
        end
      end

      def normalize_adapter(adapter, path)
        return adapter.to_sym if adapter
        return :pi if File.directory?(path) || File.extname(path).match?(/\A\.(?:[jt]s|json)\z/i)

        raise ConfigurationError, "Could not infer adapter for extension source: #{path}"
      end
    end

    module Adapters
      class PiExtension < Base
        attr_reader :name, :description, :version, :entry_paths, :source_path

        def initialize(name:, source_path:, entry_paths:, description: nil, version: nil, tools: [],
          system_prompt_additions: [], mcp_servers: [], required_provider_capabilities: [],
          unsupported_features: [])
          @name = name.to_s.strip.gsub(/[^a-zA-Z0-9]+/, "_").gsub(/\A_+|_+\z/, "").downcase.to_sym
          @description = description
          @version = version
          @tools = tools.freeze
          @system_prompt_additions = system_prompt_additions.freeze
          @mcp_servers = mcp_servers.freeze
          @required_provider_capabilities = required_provider_capabilities.freeze
          @unsupported_features = unsupported_features.freeze
          @source_path = source_path
          @entry_paths = entry_paths.freeze
        end

        def tools
          @tools.map(&:dup)
        end

        def mcp_servers
          @mcp_servers.map { |server| deep_dup(server) }
        end

        def system_prompt_additions
          @system_prompt_additions.dup
        end

        def required_provider_capabilities
          inferred = []
          inferred << :tool_use if @tools.any?
          inferred << :mcp if @mcp_servers.any?
          (@required_provider_capabilities + inferred).uniq
        end

        def unsupported_features
          @unsupported_features.dup
        end

        private

        def deep_dup(value)
          case value
          when Array
            value.map { |entry| deep_dup(entry) }
          when Hash
            value.each_with_object({}) { |(key, entry), copy| copy[key] = deep_dup(entry) }
          else
            value.dup
          end
        rescue TypeError
          value
        end
      end

      module Pi
        module_function

        def load(path)
          root = resolve_root(path)
          package = load_package_json(root)
          entry_paths = discover_entry_paths(root, package)
          ext_config = package.fetch("agent_harness", {})
          tools = ext_config["tools"] || discover_tools(entry_paths)
          system_prompt_additions = Array(ext_config["system_prompt_additions"])
          mcp_servers = Array(ext_config["mcp_servers"])
          required_provider_capabilities = Array(ext_config["required_provider_capabilities"])
          unsupported_features = Array(ext_config["unsupported_features"])
          unsupported_features |= infer_unsupported_features(entry_paths)

          [
            PiExtension.new(
              name: ext_config["name"] || package["name"] || File.basename(root),
              description: ext_config["description"] || package["description"],
              version: ext_config["version"] || package["version"],
              tools: tools.map { |tool| normalize_tool(tool) },
              system_prompt_additions: system_prompt_additions,
              mcp_servers: mcp_servers.map { |server| normalize_mcp_server(server) },
              required_provider_capabilities: required_provider_capabilities.map(&:to_sym),
              unsupported_features: unsupported_features.map(&:to_sym),
              source_path: root,
              entry_paths: entry_paths
            )
          ]
        end

        def resolve_root(path)
          if File.file?(path)
            return File.dirname(path) if File.basename(path) == "package.json"
            return File.dirname(path) if %w[.ts .js].include?(File.extname(path))
          end

          return path if File.directory?(path)

          raise ConfigurationError, "Unsupported pi extension source: #{path}"
        end

        def load_package_json(root)
          package_path = File.join(root, "package.json")
          return {} unless File.exist?(package_path)

          JSON.parse(File.read(package_path))
        rescue JSON::ParserError => e
          raise ConfigurationError, "Invalid package.json for pi extension at #{root}: #{e.message}"
        end

        def discover_entry_paths(root, package)
          manifest_entries = Array(package.dig("pi", "extensions"))
          candidates = if manifest_entries.empty?
            convention_extension_paths(root)
          else
            manifest_entries.flat_map { |entry| expand_manifest_entry(root, entry) }
          end

          paths = candidates.select { |candidate| File.file?(candidate) }
          raise ConfigurationError, "No pi extension entry points found in #{root}" if paths.empty?

          paths.uniq.sort
        end

        def convention_extension_paths(root)
          extensions_dir = File.join(root, "extensions")
          return direct_extension_entry_paths(root) unless File.directory?(extensions_dir)

          direct_extension_entry_paths(extensions_dir)
        end

        def expand_manifest_entry(root, entry)
          absolute = File.expand_path(entry, root)
          return direct_extension_entry_paths(absolute) if File.directory?(absolute)
          return Dir.glob(absolute).flat_map { |match| direct_extension_entry_paths(match) } unless File.exist?(absolute)

          direct_extension_entry_paths(absolute)
        end

        def direct_extension_entry_paths(path)
          if File.file?(path)
            return [path] if extension_script?(path)
            return []
          end

          return [] unless File.directory?(path)

          entries = []
          entries.concat(Dir.glob(File.join(path, "*.{ts,js}")))
          Dir.glob(File.join(path, "*")).sort.each do |child|
            next unless File.directory?(child)

            %w[index.ts index.js].each do |entry|
              entry_path = File.join(child, entry)
              entries << entry_path if File.file?(entry_path)
            end
          end
          entries
        end

        def extension_script?(path)
          %w[.ts .js].include?(File.extname(path))
        end

        def discover_tools(entry_paths)
          entry_paths.flat_map do |entry_path|
            source = File.read(entry_path)
            source.scan(/registerTool\s*\(\s*\{(.*?)\}\s*\)/m).filter_map do |match|
              block = match.first
              name = block[/name:\s*["']([^"']+)["']/, 1]
              next unless name

              description = block[/description:\s*["']([^"']+)["']/, 1]
              {name: name, description: description}.compact
            end
          end.uniq
        end

        def infer_unsupported_features(entry_paths)
          features = []

          entry_paths.each do |entry_path|
            source = File.read(entry_path)
            features << :commands if source.include?("registerCommand")
            features << :shortcuts if source.include?("registerShortcut")
            features << :ui if source.match?(/ctx\.ui\.|setWidget|setStatus|setTitle/)
            features << :session_persistence if source.match?(/appendEntry|session_start|session_end/)
          end

          features.uniq
        end

        def normalize_tool(tool)
          case tool
          when Hash
            tool.transform_keys(&:to_sym)
          when String, Symbol
            {name: tool.to_s}
          else
            raise ConfigurationError, "Unsupported tool definition in pi adapter: #{tool.inspect}"
          end
        end

        def normalize_mcp_server(server)
          case server
          when Hash
            server.transform_keys(&:to_sym)
          else
            raise ConfigurationError, "Unsupported MCP server definition in pi adapter: #{server.inspect}"
          end
        end
      end
    end
  end
end
