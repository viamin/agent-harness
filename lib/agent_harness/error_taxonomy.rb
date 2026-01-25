# frozen_string_literal: true

module AgentHarness
  # Error classification system for categorizing and handling errors
  #
  # Provides a standardized way to classify errors from different providers
  # into actionable categories for retry logic, provider switching, and
  # error reporting.
  module ErrorTaxonomy
    # Error categories with their metadata
    CATEGORIES = {
      rate_limited: {
        description: "Rate limit exceeded",
        action: :switch_provider,
        retryable: false
      },
      auth_expired: {
        description: "Authentication failed or expired",
        action: :switch_provider,
        retryable: false
      },
      quota_exceeded: {
        description: "Usage quota exceeded",
        action: :switch_provider,
        retryable: false
      },
      transient: {
        description: "Temporary error",
        action: :retry_with_backoff,
        retryable: true
      },
      permanent: {
        description: "Unrecoverable error",
        action: :escalate,
        retryable: false
      },
      timeout: {
        description: "Operation timed out",
        action: :retry_with_backoff,
        retryable: true
      },
      unknown: {
        description: "Unknown error",
        action: :retry_with_backoff,
        retryable: true
      }
    }.freeze

    class << self
      # Classify an error based on provider patterns
      #
      # @param error [Exception] the error to classify
      # @param patterns [Hash<Symbol, Array<Regexp>>] provider-specific patterns
      # @return [Symbol] error category
      def classify(error, patterns = {})
        message = error.message.to_s.downcase

        # Check provider-specific patterns first
        patterns.each do |category, regexes|
          return category if regexes.any? { |r| message.match?(r) }
        end

        # Fall back to generic patterns
        classify_generic(message)
      end

      # Classify a message string into error category
      #
      # @param message [String] the error message
      # @return [Symbol] error category
      def classify_message(message)
        classify_generic(message.to_s.downcase)
      end

      # Get recommended action for error category
      #
      # @param category [Symbol] the error category
      # @return [Symbol] recommended action
      def action_for(category)
        CATEGORIES.dig(category, :action) || :escalate
      end

      # Check if error category is retryable
      #
      # @param category [Symbol] the error category
      # @return [Boolean] true if the error can be retried
      def retryable?(category)
        CATEGORIES.dig(category, :retryable) || false
      end

      # Get description for error category
      #
      # @param category [Symbol] the error category
      # @return [String] human-readable description
      def description_for(category)
        CATEGORIES.dig(category, :description) || "Unknown error"
      end

      # Get all category names
      #
      # @return [Array<Symbol>] list of category names
      def categories
        CATEGORIES.keys
      end

      private

      def classify_generic(message)
        case message
        when /rate.?limit|too many requests|429/i
          :rate_limited
        when /quota|usage.?limit|billing/i
          :quota_exceeded
        when /auth|unauthorized|forbidden|invalid.*(key|token)|401|403/i
          :auth_expired
        when /timeout|timed.?out/i
          :timeout
        when /temporary|retry|503|502|500/i
          :transient
        when /invalid|malformed|bad.?request|400/i
          :permanent
        else
          :unknown
        end
      end
    end
  end
end
