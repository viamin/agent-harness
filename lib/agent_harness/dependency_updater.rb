# frozen_string_literal: true

module AgentHarness
  class DependencyUpdater
    DEFAULT_COOLDOWN_SECONDS = 3 * 24 * 60 * 60

    attr_reader :release_registry, :cooldown_period

    def initialize(cooldown_period: DEFAULT_COOLDOWN_SECONDS, release_registry: nil)
      @cooldown_period = validate_cooldown(cooldown_period)
      @per_provider_cooldown = {}
      @release_registry = release_registry || ReleaseRegistry.new
    end

    def cooldown_period=(value)
      @cooldown_period = validate_cooldown(value)
    end

    def set_cooldown(provider_name, period)
      provider_name = provider_name.to_sym
      @per_provider_cooldown[provider_name] = validate_cooldown(period)
    end

    def clear_cooldown(provider_name)
      @per_provider_cooldown.delete(provider_name.to_sym)
    end

    def cooldown_for(provider_name)
      @per_provider_cooldown[provider_name.to_sym] || @cooldown_period
    end

    def register_release(provider_name, version, released_at: Time.now)
      @release_registry.register(provider_name, version, released_at: released_at)
    end

    def resolve_latest_version(provider_name, bypass_cooldown: false, now: Time.now)
      provider_name = provider_name.to_sym
      available = @release_registry.versions_for(provider_name)
      return nil if available.nil? || available.empty?

      if bypass_cooldown
        return newest_version(available)
      end

      cooldown = cooldown_for(provider_name)
      eligible = available.select do |entry|
        entry[:released_at].nil? || (now - entry[:released_at]) >= cooldown
      end

      return nil if eligible.empty?

      newest_version(eligible)
    end

    def eligible?(provider_name, version, bypass_cooldown: false, now: Time.now)
      return true if bypass_cooldown

      provider_name = provider_name.to_sym
      version = version.to_s

      released_at = @release_registry.released_at(provider_name, version)
      return true if released_at.nil?

      cooldown = cooldown_for(provider_name)
      (now - released_at) >= cooldown
    end

    def resolve_latest_installation_contract(provider_name, bypass_cooldown: false, now: Time.now)
      provider_name = provider_name.to_sym
      version_info = resolve_latest_version(provider_name, bypass_cooldown: bypass_cooldown, now: now)
      return nil unless version_info

      version = version_info[:version]
      begin
        contract = Providers::Registry.instance.installation_contract(provider_name, version: version)
        {
          provider: provider_name,
          version: version,
          released_at: version_info[:released_at],
          installation_contract: contract
        }
      rescue ConfigurationError
        {
          provider: provider_name,
          version: version,
          released_at: version_info[:released_at],
          installation_contract: nil
        }
      end
    end

    def resolve_all_latest(bypass_cooldown: false, now: Time.now)
      @release_registry.providers.each_with_object({}) do |provider_name, results|
        version_info = resolve_latest_version(provider_name, bypass_cooldown: bypass_cooldown, now: now)
        results[provider_name] = version_info if version_info
      end
    end

    private

    def validate_cooldown(value)
      numeric = case value
      when Integer
        value
      when Float
        value
      when Numeric
        value
      else
        raise ArgumentError, "cooldown period must be a positive number of seconds, got #{value.inspect}"
      end

      raise ArgumentError, "cooldown period must be positive, got #{numeric}" unless numeric > 0

      numeric
    end

    def newest_version(entries)
      entries.max_by do |entry|
        parse_version(entry[:version])
      end
    end

    def parse_version(version_string)
      Gem::Version.new(version_string)
    rescue ArgumentError
      Gem::Version.new("0")
    end
  end
end
