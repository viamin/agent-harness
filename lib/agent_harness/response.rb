# frozen_string_literal: true

module AgentHarness
  # Response object returned from provider send_message calls
  #
  # Contains the output, status, and metadata from a provider interaction.
  #
  # @example
  #   response = provider.send_message(prompt: "Hello")
  #   if response.success?
  #     puts response.output
  #   else
  #     puts "Error: #{response.error}"
  #   end
  class Response
    attr_reader :output, :exit_code, :duration, :provider, :model
    attr_reader :tokens, :metadata, :error

    # Create a new Response
    #
    # @param output [String] the output from the provider
    # @param exit_code [Integer] the exit code (0 for success)
    # @param duration [Float] execution duration in seconds
    # @param provider [Symbol, String] the provider name
    # @param model [String, nil] the model used
    # @param tokens [Hash, nil] token usage information
    # @param metadata [Hash] additional metadata
    # @param error [String, nil] error message if failed
    def initialize(output:, exit_code:, duration:, provider:, model: nil,
      tokens: nil, metadata: {}, error: nil)
      @output = output
      @exit_code = exit_code
      @duration = duration
      @provider = provider.to_sym
      @model = model
      @tokens = tokens
      @metadata = metadata
      @error = error
    end

    # Check if the response indicates success
    #
    # @return [Boolean] true if exit_code is 0 and no error
    def success?
      @exit_code == 0 && @error.nil?
    end

    # Check if the response indicates failure
    #
    # @return [Boolean] true if not successful
    def failed?
      !success?
    end

    # Get total tokens used
    #
    # @return [Integer, nil] total tokens or nil if not tracked
    def total_tokens
      @tokens&.[](:total)
    end

    # Get input tokens used
    #
    # @return [Integer, nil] input tokens or nil if not tracked
    def input_tokens
      @tokens&.[](:input)
    end

    # Get output tokens used
    #
    # @return [Integer, nil] output tokens or nil if not tracked
    def output_tokens
      @tokens&.[](:output)
    end

    # Convert to hash representation
    #
    # @return [Hash] hash representation of the response
    def to_h
      {
        output: @output,
        exit_code: @exit_code,
        duration: @duration,
        provider: @provider,
        model: @model,
        tokens: @tokens,
        metadata: @metadata,
        error: @error,
        success: success?
      }
    end

    # String representation for debugging
    #
    # @return [String] debug string
    def inspect
      "#<AgentHarness::Response provider=#{@provider} success=#{success?} duration=#{@duration.round(2)}s>"
    end
  end
end
