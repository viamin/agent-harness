# frozen_string_literal: true

require "time"

module AgentHarness
  module Api
    # Serializable accounting facts for one physical provider request.
    class AttemptReport
      STATUSES = %i[succeeded failed cancelled partial].freeze
      USAGE_KEYS = %i[input_tokens output_tokens cache_read_tokens cache_write_tokens thinking_tokens total_tokens].freeze
      COST_KEYS = %i[input output cache_read cache_write thinking total].freeze

      attr_reader :attributes

      def self.from_h(attributes)
        new(**symbolize(attributes))
      end

      def self.symbolize(value)
        return value.to_h { |key, child| [key.to_sym, symbolize(child)] } if value.is_a?(Hash)
        return value.map { |child| symbolize(child) } if value.is_a?(Array)

        value
      end
      private_class_method :symbolize

      def initialize(attempt_id:, request_id:, number:, provider:, model:, status:, started_at:, finished_at:,
        usage: nil, cost: nil, provider_reported: false, error: nil)
        @attributes = {
          attempt_id: attempt_id.to_s, request_id: request_id.to_s, number: number,
          provider: provider.to_sym, model: model&.to_s, status: status.to_sym,
          started_at: timestamp(started_at), finished_at: timestamp(finished_at),
          usage: normalize_usage(usage), cost: normalize_cost(cost),
          provider_reported: provider_reported == true, error: error
        }
        validate!
        deep_freeze(@attributes)
      end

      def to_h
        deep_dup(attributes)
      end

      private

      def timestamp(value)
        value.respond_to?(:iso8601) ? value.iso8601(6) : Time.iso8601(value.to_s).utc.iso8601(6)
      end

      def normalize_usage(usage)
        return unless usage

        normalized = self.class.send(:symbolize, usage)
        USAGE_KEYS.each_with_object({}) do |key, result|
          result[key] = normalized[key] if normalized.key?(key)
        end
      end

      def normalize_cost(cost)
        return unless cost

        normalized = self.class.send(:symbolize, cost)
        amounts = COST_KEYS.to_h { |key| [key, normalized[key]] }
        amounts.merge(currency: normalized.fetch(:currency, "USD"), source: normalized.fetch(:source).to_sym,
          priced_at: timestamp(normalized.fetch(:priced_at)))
      end

      def validate!
        raise ArgumentError, "attempt_id is required" if attributes[:attempt_id].empty?
        raise ArgumentError, "request_id is required" if attributes[:request_id].empty?
        raise ArgumentError, "number must be a positive integer" unless attributes[:number].is_a?(Integer) && attributes[:number].positive?
        raise ArgumentError, "unknown attempt status" unless STATUSES.include?(attributes[:status])
      end

      def deep_freeze(value)
        value.each_value { |child| deep_freeze(child) } if value.is_a?(Hash)
        value.each { |child| deep_freeze(child) } if value.is_a?(Array)
        value.freeze
      end

      def deep_dup(value)
        return value.to_h { |key, child| [key, deep_dup(child)] } if value.is_a?(Hash)
        return value.map { |child| deep_dup(child) } if value.is_a?(Array)

        value
      end
    end
  end
end
