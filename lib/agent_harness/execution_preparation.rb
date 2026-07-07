# frozen_string_literal: true

module AgentHarness
  # Structured runtime bootstrap contract for request-scoped executor setup.
  #
  # Providers can use this to request file materialization or similar
  # preparation without forcing downstream applications to shell-wrap the main
  # provider command.
  class ExecutionPreparation
    # Declarative file write request that executors can materialize in their
    # own runtime environment.
    FileWrite = Struct.new(:path, :content, :mode) do
      def initialize(path:, content:, mode: nil)
        raise ArgumentError, "path must be a non-empty String" unless path.is_a?(String) && !path.empty?
        raise ArgumentError, "content must be a String" unless content.is_a?(String)
        if !mode.nil? && (!mode.is_a?(Integer) || mode.negative?)
          raise ArgumentError, "mode must be a non-negative Integer or nil"
        end

        super
        freeze
      end
    end

    attr_reader :file_writes

    def initialize(file_writes: [])
      writes = file_writes || []
      unless writes.is_a?(Array)
        raise ArgumentError, "file_writes must be an Array (got #{writes.class})"
      end

      @file_writes = writes.map.with_index do |write, index|
        case write
        when FileWrite
          write
        when Hash
          FileWrite.new(
            path: fetch_value(write, :path),
            content: fetch_value(write, :content),
            mode: write.key?(:mode) ? write[:mode] : write["mode"]
          )
        else
          raise ArgumentError,
            "file_writes must contain FileWrite or Hash entries; invalid element at index #{index}: #{write.inspect} (#{write.class})"
        end
      end.freeze

      freeze
    end

    def empty?
      file_writes.empty?
    end

    private

    def fetch_value(hash, key)
      return hash[key] if hash.key?(key)

      hash[key.to_s]
    end
  end
end
