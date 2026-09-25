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
      return unless rows.is_a?(Array)

      indices = rows.map { |row| row["index"] if row.is_a?(Hash) }
      unless indices.all?(Integer) && indices.sort == (0...rows.length).to_a
        raise MalformedEmbeddingError, "Provider returned invalid embedding indices"
      end

      payload["data"] = rows.sort_by { |row| row.fetch("index") }
      response.body = JSON.generate(payload)
    rescue JSON::ParserError
      nil
    end
  end
end
