# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module AgentHarness
  module Providers
    # Provider-specific quota check helpers shared between provider classes.
    #
    # These modules encapsulate the HTTP plumbing needed to query a provider's
    # quota/usage endpoint, so provider classes can include them and stay
    # focused on parsing. They are tested in isolation and reused by
    # {Providers::Base#check_quota} overrides.
    module QuotaCheckers
      # Quota checker for the Anthropic admin usage API.
      #
      # Anthropic exposes organization usage via the admin API
      # (+/v1/organizations/usage_reports/messages+) when an admin API key is
      # provided. The endpoint returns token usage for a date range, which we
      # surface as a +QuotaStatus+ with +unit: :tokens+.
      #
      # @example Direct usage
      #   AgentHarness::Providers::QuotaCheckers::Anthropic.check(
      #     env: { "ANTHROPIC_ADMIN_API_KEY" => "sk-ant-..." }
      #   )
      #   # => #<AgentHarness::QuotaStatus available=true remaining=150000 unit=:tokens ...>
      module Anthropic
        DEFAULT_BASE_URL = "https://api.anthropic.com"
        DEFAULT_TIMEOUT = 10
        USER_AGENT = "AgentHarness/1.0"
        API_VERSION = "2023-06-01"

        class << self
          # Resolve the admin API key (preferred) or regular API key from env.
          #
          # @param env [Hash{String=>String}] request-scoped environment
          # @return [String, nil]
          def resolve_api_key(env)
            env_value(env, "ANTHROPIC_ADMIN_API_KEY") ||
              ENV["ANTHROPIC_ADMIN_API_KEY"] ||
              env_value(env, "ANTHROPIC_API_KEY") ||
              ENV["ANTHROPIC_API_KEY"]
          end

          # Query the Anthropic admin usage API for the current billing period.
          #
          # @param env [Hash{String=>String}] request-scoped environment
          # @param base_url [String, nil] override the API base URL
          # @param timeout [Numeric] time budget in seconds
          # @param logger [Logger, nil]
          # @return [AgentHarness::QuotaStatus] populated when credentials are
          #   present and the API responds; unavailable otherwise
          def check(env:, base_url: nil, timeout: DEFAULT_TIMEOUT, logger: nil)
            api_key = resolve_api_key(env)
            unless api_key && !api_key.empty?
              logger&.debug("[AgentHarness::QuotaCheckers::Anthropic] no API key present in env")
              return QuotaStatus.unavailable
            end

            start_date, end_date = billing_window
            uri = URI.parse(
              "#{resolve_base_url(env, base_url)}/v1/organizations/usage_reports/messages" \
                "?start_date=#{start_date}&end_date=#{end_date}"
            )

            response = perform_get(uri:, api_key:, timeout:, logger:)
            return QuotaStatus.unavailable unless response

            parse_usage_report(response)
          rescue IOError, SocketError, SystemCallError, Timeout::Error, JSON::ParserError => e
            logger&.warn("[AgentHarness::QuotaCheckers::Anthropic] quota check failed: #{e.message}")
            QuotaStatus.unavailable
          end

          private

          def billing_window
            today = Date.today
            [today.iso8601, today.iso8601]
          end

          def resolve_base_url(env, override)
            base = override || env_value(env, "ANTHROPIC_BASE_URL") || ENV["ANTHROPIC_BASE_URL"] || DEFAULT_BASE_URL
            base.to_s.chomp("/")
          end

          def env_value(env, key)
            return nil if env.nil?

            env[key] || env[key.to_sym]
          end

          def perform_get(uri:, api_key:, timeout:, logger:)
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = (uri.scheme == "https")
            http.open_timeout = timeout
            http.read_timeout = timeout

            request = Net::HTTP::Get.new(uri)
            request["x-api-key"] = api_key
            request["anthropic-version"] = API_VERSION
            request["User-Agent"] = USER_AGENT

            logger&.debug("[AgentHarness::QuotaCheckers::Anthropic] GET #{uri}")

            response = http.request(request)
            return response if response.is_a?(Net::HTTPSuccess)

            logger&.warn("[AgentHarness::QuotaCheckers::Anthropic] #{uri} returned HTTP #{response.code}")
            nil
          end

          # Anthropic returns: {"data": [{...usage buckets...}], "has_more": false, ...}
          def parse_usage_report(response)
            body = response.body
            return QuotaStatus.unavailable if body.nil? || body.empty?

            parsed = JSON.parse(body)
            data = parsed.is_a?(Hash) ? parsed["data"] : nil
            return QuotaStatus.unavailable unless data.is_a?(Array)

            # Sum token usage across every bucket in the response. Anthropic's
            # buckets carry input/output token counts per model or per day; the
            # caller wants the period total regardless of grouping. We only use
            # the sum to confirm the response actually reported usage — a zero
            # total means there is nothing to surface.
            total_input = sum_field(data, "input_tokens")
            total_output = sum_field(data, "output_tokens")
            total_tokens = total_input + total_output
            return QuotaStatus.unavailable if total_tokens.zero?

            # The usage_reports endpoint exposes *consumption*, not a billing
            # cap, so we cannot populate remaining/limit. Leave both nil rather
            # than mislabeling usage as the limit (which would make the weight
            # balancer treat observed usage as the ceiling). Callers that need a
            # cap fall back to TokenUsageTracker's configured limit.
            QuotaStatus.new(
              available: true,
              remaining: nil,
              limit: nil,
              reset_at: next_billing_reset,
              unit: :tokens
            )
          end

          def sum_field(data, field)
            data.sum do |entry|
              value = entry.is_a?(Hash) ? entry[field] : nil
              value.to_i
            end
          end

          # Anthropic usage reports are calendar-month scoped by default; the
          # reset time is the first instant of next month in UTC.
          def next_billing_reset
            now = Time.now.utc
            (now.month == 12) ? Time.utc(now.year + 1, 1, 1) : Time.utc(now.year, now.month + 1, 1)
          end
        end
      end
    end
  end
end
