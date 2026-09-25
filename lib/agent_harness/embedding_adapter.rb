# frozen_string_literal: true

require "faraday"
require "faraday/net_http"
require "json"

module AgentHarness
  # Builds a request-local Faraday adapter for headers and cancellation.
  module EmbeddingAdapter
    module_function

    def build(headers:, cancellation: nil)
      Class.new(Faraday::Adapter::NetHttp) do
        define_method(:call) do |env|
          raise CancelledError, "Embedding request cancelled" if cancellation&.call

          env.request_headers.update(headers)
          super(env).on_complete { |response| EmbeddingAdapter.order_rows(response) }
        end
      end
    end

    def order_rows(response)
      payload = JSON.parse(response.body)
      rows = payload["data"]
      return unless indexed_rows?(rows)
      unless rows.map { |row| row["index"] }.sort == (0...rows.length).to_a
        raise MalformedEmbeddingError, "Provider returned invalid embedding indices"
      end

      payload["data"] = rows.sort_by { |row| row["index"] }
      response.body = JSON.generate(payload)
    rescue JSON::ParserError
      nil
    end

    def indexed_rows?(rows)
      rows.is_a?(Array) && rows.all? { |row| row.is_a?(Hash) && row["index"].is_a?(Integer) }
    end
  end
end
