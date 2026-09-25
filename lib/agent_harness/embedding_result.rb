# frozen_string_literal: true

module AgentHarness
  # Normalized result returned by AgentHarness.embed.
  class EmbeddingResult
    attr_reader :vectors, :model, :usage

    def initialize(vectors:, model:, input_tokens: nil)
      @vectors = vectors
      @model = model
      @usage = {input_tokens: input_tokens}.freeze
    end

    # Batch usage is never guessed or divided among individual vectors.
    def per_vector_usage
      nil
    end
  end
end
