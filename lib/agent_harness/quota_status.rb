# frozen_string_literal: true

require "time"

module AgentHarness
  # Serializable snapshot of a provider's remaining quota for the current
  # billing period.
  #
  # {QuotaStatus} is the unified return type for {Providers::Base#check_quota}
  # and {TokenUsageTracker#estimated_usage}. It lets the orchestration layer
  # compare runners on the same axis (remaining/limit/unit) so Paid can
  # auto-balance weights and let multiple runners exhaust their quotas at
  # roughly the same rate.
  #
  # All instances are frozen so callers can safely cache, share, and persist
  # them (for example, to a database column) without worrying about mutation.
  #
  # @example A real API-backed status
  #   AgentHarness::QuotaStatus.new(
  #     available: true,
  #     remaining: 1_500_000,
  #     limit: 2_000_000,
  #     reset_at: Time.utc(2026, 8, 1),
  #     unit: :tokens
  #   )
  #
  # @example Sentinel returned by providers that do not expose a quota API
  #   AgentHarness::QuotaStatus.unavailable
  #
  class QuotaStatus < Struct.new(
    :available,
    :remaining,
    :limit,
    :reset_at,
    :unit,
    :checked_at
  )
    # Units recognized by the harness. Providers may return other Symbols,
    # but the documented set is enumerated here so callers can switch on it
    # without typos. New units should be added here when a provider exposes
    # one that does not fit an existing bucket.
    UNITS = %i[
      tokens
      requests
      credits
      cost_cents
    ].freeze

    def initialize(available: false, remaining: nil, limit: nil, reset_at: nil, unit: nil, checked_at: nil)
      unless reset_at.nil? || reset_at.is_a?(Time)
        raise ArgumentError, "reset_at must be a Time or nil (got #{reset_at.class})"
      end
      unless unit.nil? || unit.is_a?(Symbol)
        raise ArgumentError, "unit must be a Symbol or nil (got #{unit.class})"
      end
      unless available == true || available == false
        raise ArgumentError, "available must be a boolean (got #{available.class})"
      end

      # Snap the check time when an available status is built without one so
      # cached/stored statuses always record when the underlying lookup ran.
      resolved_checked_at = checked_at || (available ? Time.now.utc : nil)

      super(
        available: available,
        remaining: remaining,
        limit: limit,
        reset_at: reset_at,
        unit: unit,
        checked_at: resolved_checked_at
      )
      freeze
    end

    # Whether this provider exposes any quota information at all.
    #
    # @return [Boolean]
    def available? = available == true

    # Whether the tracked quota is exhausted. Returns false when availability
    # is unknown so callers can treat the status conservatively.
    #
    # @return [Boolean]
    def exhausted?
      return false unless available?
      return false if remaining.nil?

      remaining <= 0
    end

    # Human-friendly label for the +unit+ value, useful for logs and UIs.
    #
    # @return [String]
    def unit_label
      return "unknown" if unit.nil?

      unit.to_s
    end

    # Serializable hash suitable for database persistence.
    #
    # +reset_at+ and +checked_at+ are serialized as ISO8601 strings in UTC so
    # the hash round-trips through JSON without losing timezone information.
    #
    # @return [Hash{Symbol => Object}]
    def to_h
      {
        available: available,
        remaining: remaining,
        limit: limit,
        reset_at: serialize_time(reset_at),
        unit: unit,
        checked_at: serialize_time(checked_at)
      }
    end

    # Build a QuotaStatus from a Hash produced by {#to_h}.
    #
    # @param hash [Hash] serialized QuotaStatus
    # @return [QuotaStatus]
    def self.from_h(hash)
      return unavailable if hash.nil? || hash.empty?

      new(
        available: fetch_value(hash, :available),
        remaining: fetch_value(hash, :remaining),
        limit: fetch_value(hash, :limit),
        reset_at: parse_time(fetch_value(hash, :reset_at)),
        unit: normalize_unit(fetch_value(hash, :unit)),
        checked_at: parse_time(fetch_value(hash, :checked_at))
      )
    end

    def self.fetch_value(hash, key)
      symbol_value = hash[key]
      return symbol_value unless symbol_value.nil?

      hash[key.to_s]
    end
    private_class_method :fetch_value

    # Sentinel for "this provider does not expose a quota API." The default
    # implementation of {Providers::Base#check_quota} returns this so callers
    # can treat all providers uniformly.
    #
    # @return [QuotaStatus]
    def self.unavailable
      new(available: false)
    end

    def self.normalize_unit(value)
      return nil if value.nil?

      value.to_sym
    end
    private_class_method :normalize_unit

    def self.parse_time(value)
      return nil if value.nil?

      Time.parse(value).utc
    rescue ArgumentError
      nil
    end
    private_class_method :parse_time

    private

    def serialize_time(value)
      return nil unless value.is_a?(Time)

      value.utc.iso8601
    end
  end
end
