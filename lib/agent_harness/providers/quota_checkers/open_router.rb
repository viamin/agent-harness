# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module AgentHarness
  module Providers
    # Standalone quota-check helpers for backends that do not have a dedicated
    # provider class but can still be queried proactively before a run starts.
    #
    # Today this hosts the OpenRouter credits lookup, which Paid's runners can
    # route through even though there is no canonical +:openrouter+ provider
    # class (it is selected via +ProviderRuntime#api_provider+). Other backends
    # that surface through OpenAI-compatible transports but expose their own
    # balance endpoint belong here too.
    module QuotaCheckers
      # Quota checker for OpenRouter's credit balance API.
      #
      # OpenRouter is selected by Paid runners via +ProviderRuntime+ overrides
      # rather than a dedicated provider class, so the check is implemented as
      # a standalone helper that any provider can call from its own
      # +check_quota+ implementation when the request env points at OpenRouter.
      #
      # @example Direct usage
      #   AgentHarness::Providers::QuotaCheckers::OpenRouter.check(
      #     env: { "OPENROUTER_API_KEY" => "sk-..." }
      #   )
      #   # => #<AgentHarness::QuotaStatus available=true remaining=12.5 unit=:credits ...>
      module OpenRouter
        DEFAULT_BASE_URL = "https://openrouter.ai/api/v1"
        DEFAULT_TIMEOUT = 10
        USER_AGENT = "AgentHarness/1.0"
        HOST_FRAGMENT = "openrouter.ai"

        class << self
          # Detect whether a request env would route through OpenRouter.
          #
          # Used by providers (Codex, Kilocode, etc.) to decide whether to
          # delegate +check_quota+ to this checker.
          #
          # @param env [Hash{String=>String}] request-scoped environment
          # @return [Boolean]
          def routes_through_open_router?(env)
            return false if env.nil?

            values = env.values_at("OPENROUTER_API_KEY", :OPENROUTER_API_KEY)
            return true if values.any? { |value| value.respond_to?(:to_str) && !value.to_str.empty? }

            base_url_values = env.values_at("OPENAI_BASE_URL", :OPENAI_BASE_URL)
            base_url_values.any? { |value| value.to_s.include?(HOST_FRAGMENT) }
          end

          # Resolve the API key the OpenRouter quota endpoint should use.
          #
          # Order of precedence: explicit +OPENROUTER_API_KEY+, then
          # +OPENAI_API_KEY+ (since OpenRouter accepts it under that name when
          # routed via the OpenAI-compatible transport).
          #
          # @param env [Hash{String=>String}] request-scoped environment
          # @return [String, nil]
          def resolve_api_key(env)
            env_value(env, "OPENROUTER_API_KEY") ||
              env_value(env, "OPENAI_API_KEY")
          end

          # Query OpenRouter's +/credits+ endpoint and return a {QuotaStatus}.
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
              logger&.debug("[AgentHarness::QuotaCheckers::OpenRouter] no API key present in env")
              return QuotaStatus.unavailable
            end

            uri = URI.parse("#{resolve_base_url(env, base_url)}/credits")
            response = perform_get(uri:, api_key:, timeout:, logger:)
            return QuotaStatus.unavailable unless response

            parse_credits_response(response)
          rescue IOError, SocketError, SystemCallError, Timeout::Error, JSON::ParserError => e
            logger&.warn("[AgentHarness::QuotaCheckers::OpenRouter] credit check failed: #{e.message}")
            QuotaStatus.unavailable
          end

          private

          def resolve_base_url(env, override)
            base = override || env_value(env, "OPENROUTER_BASE_URL") || DEFAULT_BASE_URL
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
            request["Authorization"] = "Bearer #{api_key}"
            request["User-Agent"] = USER_AGENT

            logger&.debug("[AgentHarness::QuotaCheckers::OpenRouter] GET #{uri}")

            response = http.request(request)
            return response if response.is_a?(Net::HTTPSuccess)

            logger&.warn("[AgentHarness::QuotaCheckers::OpenRouter] #{uri} returned HTTP #{response.code}")
            nil
          end

          # OpenRouter returns: {"data": {"total_credits": 20.0, "total_usage": 7.5}}
          def parse_credits_response(response)
            body = response.body
            return QuotaStatus.unavailable if body.nil? || body.empty?

            parsed = JSON.parse(body)
            data = parsed.is_a?(Hash) ? parsed["data"] : nil
            return QuotaStatus.unavailable unless data.is_a?(Hash)

            total = data["total_credits"]
            usage = data["total_usage"]
            return QuotaStatus.unavailable if total.nil? || usage.nil?

            limit = total.to_f
            used = usage.to_f
            remaining = limit - used

            QuotaStatus.new(
              available: true,
              remaining: remaining,
              limit: limit,
              reset_at: nil,
              unit: :credits
            )
          end
        end
      end
    end
  end
end
