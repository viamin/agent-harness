# frozen_string_literal: true

module AgentHarness
  module Providers
    # Base class for all providers
    #
    # Provides common functionality for provider implementations including
    # command execution, error handling, and response parsing.
    #
    # @example Implementing a provider
    #   class MyProvider < AgentHarness::Providers::Base
    #     class << self
    #       def provider_name
    #         :my_provider
    #       end
    #
    #       def binary_name
    #         "my-cli"
    #       end
    #
    #       def available?
    #         system("which my-cli > /dev/null 2>&1")
    #       end
    #     end
    #
    #     protected
    #
    #     def build_command(prompt, options)
    #       [self.class.binary_name, "--prompt", prompt]
    #     end
    #   end
    class Base
      include Adapter

      attr_reader :config, :executor, :logger

      # Initialize the provider
      #
      # @param config [ProviderConfig, nil] provider configuration
      # @param executor [CommandExecutor, nil] command executor
      # @param logger [Logger, nil] logger instance
      def initialize(config: nil, executor: nil, logger: nil)
        @config = config || ProviderConfig.new(self.class.provider_name)
        @executor = executor || AgentHarness.configuration.command_executor
        @logger = logger || AgentHarness.logger
      end

      # Configure the provider instance
      #
      # @param options [Hash] configuration options
      # @return [self]
      def configure(options = {})
        @config.merge!(options)
        self
      end

      # Main send_message implementation
      #
      # @param prompt [String] the prompt to send
      # @param options [Hash] additional options
      # @return [Response] the response
      def send_message(prompt:, **options)
        log_debug("send_message_start", prompt_length: prompt.length, options: options.keys)

        # Build command
        command = build_command(prompt, options)

        # Calculate timeout
        timeout = options[:timeout] || @config.timeout || default_timeout

        # Execute command
        start_time = Time.now
        result = execute_with_timeout(command, timeout: timeout, env: build_env(options))
        duration = Time.now - start_time

        # Parse response
        response = parse_response(result, duration: duration)

        # Track tokens
        track_tokens(response) if response.tokens

        log_debug("send_message_complete", duration: duration, tokens: response.tokens)

        response
      rescue => e
        handle_error(e, prompt: prompt, options: options)
      end

      # Provider name for display
      #
      # @return [String] display name
      def name
        self.class.provider_name.to_s
      end

      # Human-friendly display name
      #
      # @return [String] display name
      def display_name
        name.capitalize
      end

      protected

      # Build CLI command - override in subclasses
      #
      # @param prompt [String] the prompt
      # @param options [Hash] options
      # @return [Array<String>] command array
      def build_command(prompt, options)
        raise NotImplementedError, "#{self.class} must implement #build_command"
      end

      # Build environment variables - override in subclasses
      #
      # @param options [Hash] options
      # @return [Hash] environment variables
      def build_env(options)
        {}
      end

      # Parse CLI output into Response - override in subclasses
      #
      # @param result [CommandExecutor::Result] execution result
      # @param duration [Float] execution duration
      # @return [Response] parsed response
      def parse_response(result, duration:)
        Response.new(
          output: result.stdout,
          exit_code: result.exit_code,
          duration: duration,
          provider: self.class.provider_name,
          model: @config.model,
          error: result.failed? ? result.stderr : nil
        )
      end

      # Default timeout
      #
      # @return [Integer] timeout in seconds
      def default_timeout
        300
      end

      private

      def execute_with_timeout(command, timeout:, env:)
        @executor.execute(command, timeout: timeout, env: env)
      end

      def track_tokens(response)
        return unless response.tokens

        AgentHarness.token_tracker.record(
          provider: self.class.provider_name,
          model: @config.model,
          input_tokens: response.tokens[:input] || 0,
          output_tokens: response.tokens[:output] || 0,
          total_tokens: response.tokens[:total]
        )
      end

      def handle_error(error, prompt:, options:)
        # Classify error
        classification = ErrorTaxonomy.classify(error, error_patterns)

        log_error("send_message_error",
          error: error.class.name,
          message: error.message,
          classification: classification)

        # Wrap in appropriate error class
        raise map_to_error_class(classification, error)
      end

      def map_to_error_class(classification, original_error)
        case classification
        when :rate_limited
          RateLimitError.new(original_error.message, original_error: original_error)
        when :auth_expired
          AuthenticationError.new(original_error.message, original_error: original_error)
        when :timeout
          TimeoutError.new(original_error.message, original_error: original_error)
        else
          ProviderError.new(original_error.message, original_error: original_error)
        end
      end

      def log_debug(action, **context)
        @logger&.debug("[AgentHarness::#{self.class.provider_name}] #{action}: #{context.inspect}")
      end

      def log_error(action, **context)
        @logger&.error("[AgentHarness::#{self.class.provider_name}] #{action}: #{context.inspect}")
      end
    end
  end
end
