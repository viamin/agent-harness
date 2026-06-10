# frozen_string_literal: true

module AgentHarness
  class ReleaseRegistry
    attr_reader :releases

    def initialize
      @releases = {}
    end

    def register(provider_name, version, released_at: Time.now)
      provider_name = provider_name.to_sym
      version = version.to_s

      raise ArgumentError, "version must be a non-empty string" if version.empty?
      raise ArgumentError, "released_at must be a Time" unless released_at.is_a?(Time)

      @releases[provider_name] ||= []
      entry = {version: version, released_at: released_at}
      existing = @releases[provider_name].find { |e| e[:version] == version }
      if existing
        existing[:released_at] = released_at
      else
        @releases[provider_name] << entry
      end

      entry
    end

    def versions_for(provider_name)
      provider_name = provider_name.to_sym
      return nil unless @releases.key?(provider_name)

      @releases[provider_name].dup
    end

    def released_at(provider_name, version)
      provider_name = provider_name.to_sym
      version = version.to_s

      entries = @releases[provider_name]
      return nil unless entries

      entry = entries.find { |e| e[:version] == version }
      entry&.fetch(:released_at, nil)
    end

    def registered?(provider_name, version)
      provider_name = provider_name.to_sym
      version = version.to_s

      entries = @releases[provider_name]
      return false unless entries

      entries.any? { |e| e[:version] == version }
    end

    def providers
      @releases.keys
    end

    def clear
      @releases.clear
    end

    def clear_provider(provider_name)
      @releases.delete(provider_name.to_sym)
    end

    def merge!(other_registry)
      other_registry.releases.each do |provider_name, entries|
        @releases[provider_name] ||= []
        entries.each do |entry|
          existing = @releases[provider_name].find { |e| e[:version] == entry[:version] }
          if existing
            existing[:released_at] = entry[:released_at]
          else
            @releases[provider_name] << entry.dup
          end
        end
      end

      self
    end
  end
end
