# frozen_string_literal: true

module AgentHarness
  # Structured runner/model compatibility contract.
  #
  # ModelCompatibility is the single source of truth for whether a given
  # runner (provider) can execute a particular model under specific runtime
  # constraints such as authentication mode or installed CLI version.
  # Downstream orchestrators (for example Paid's RDR-040 tier-to-model
  # mapping) consume this contract before validating tier models, selecting
  # runners, and starting agent runs — instead of inferring compatibility
  # from scattered facts like CLI version pins, smoke-test overrides, or
  # observed runtime errors.
  #
  # @example Query Codex compatibility for a CLI-gated model
  #   AgentHarness.model_compatibility(
  #     runner: :codex,
  #     model_id: "gpt-5.5",
  #     auth_mode: :subscription,
  #     cli_version: "0.116.0"
  #   )
  #   # => #<AgentHarness::ModelCompatibility::Result supported=true ...>
  module ModelCompatibility
    # Sentinel for "the runner declares no opinion about this model."
    UNKNOWN_REASON = :unknown
    # Issued when a runner does not advertise the requested model at all.
    UNKNOWN_MODEL_REASON = :unknown_model
    # Issued when the runner needs a comparable CLI version to answer
    # definitively for a CLI-gated model but the caller did not supply one
    # (or it could not be parsed). Pairs with :minimum_cli_version on the
    # result. Distinct from :unknown_model — the runner *does* know the
    # model; it just cannot confirm the installed CLI is new enough.
    UNKNOWN_CLI_VERSION_REASON = :cli_version_unknown
    # Issued when the runner needs an auth mode to answer definitively for
    # an auth-gated model but the caller did not supply one. Pairs with
    # :supported_auth_modes on the result details. Distinct from
    # :unknown_model — the runner *does* know the model; it just cannot
    # confirm the requested auth mode is allowed for it.
    UNKNOWN_AUTH_MODE_REASON = :auth_mode_unknown
    # Issued when the runner supports the model but the installed CLI is too
    # old. Pairs with :minimum_cli_version on the result.
    UNSUPPORTED_CLI_VERSION_REASON = :cli_version_too_old
    # Issued when the runner supports the model but the requested auth mode
    # is not part of the runner's contract for it.
    UNSUPPORTED_AUTH_MODE_REASON = :auth_mode_not_supported
    # Issued when the runner accepts the requested auth mode generally, but
    # the specific model is not available under that auth mode.
    UNSUPPORTED_AUTH_MODE_FOR_MODEL_REASON = :unsupported_auth_mode_for_model
    # Default supported reason.
    SUPPORTED_REASON = :supported

    # Sources for a compatibility decision. Static contracts are baked into
    # the provider; live probes hit the provider CLI/API; entitlement checks
    # gate on subscription state. Downstream orchestrators can use this to
    # decide whether to cache the answer.
    SOURCES = %i[static_contract live_provider_probe entitlement_check unknown].freeze

    # Structured compatibility outcome.
    #
    # The struct intentionally exposes whatever facts the runner contract
    # knows. Callers should treat unknown fields as nil rather than fail.
    Result = Struct.new(
      :runner,
      :model_id,
      :auth_mode,
      :cli_version,
      :supported,
      :reason,
      :minimum_cli_version,
      :cli_version_requirement,
      :fallback_model_id,
      :source,
      :details
    ) do
      # @return [Boolean] true when compatibility is known to be supported
      def supported? = supported == true

      # @return [Boolean] true when compatibility is known to be unsupported
      def unsupported? = supported == false

      # @return [Boolean] true when the runner did not return a definite answer
      def unknown? = supported.nil?

      def to_h
        super.compact
      end
    end

    class << self
      # Build a Result with sensible defaults from a partial Hash.
      #
      # Provider implementations call this helper to return a normalized
      # Result without having to instantiate Struct fields by hand.
      #
      # @param runner [Symbol] canonical provider/runner name
      # @param model_id [String, Symbol, nil] requested model id
      # @param attributes [Hash] additional Result attributes
      # @return [Result]
      def build_result(runner:, model_id:, **attributes)
        normalized_model_id = model_id.is_a?(Symbol) ? model_id.to_s : model_id
        source = attributes.fetch(:source, :static_contract)
        supported = attributes[:supported]

        if supported == false && attributes[:reason].nil?
          raise ArgumentError,
            "AgentHarness::ModelCompatibility.build_result requires an explicit " \
            "`reason:` when `supported: false`. Pass a specific reason " \
            "(e.g. :cli_version_too_old, :auth_mode_not_supported) so " \
            "callers can distinguish unsupported from :unknown."
        end

        reason = attributes[:reason] || default_reason_for(supported)

        Result.new(
          runner: runner.to_sym,
          model_id: normalized_model_id,
          auth_mode: attributes[:auth_mode],
          cli_version: attributes[:cli_version],
          supported: supported,
          reason: reason,
          minimum_cli_version: attributes[:minimum_cli_version],
          cli_version_requirement: attributes[:cli_version_requirement],
          fallback_model_id: attributes[:fallback_model_id],
          source: source,
          details: attributes[:details]
        )
      end

      # Build an explicit "unknown" Result. Use when the runner has no
      # static contract for the requested model and cannot probe.
      def unknown_result(runner:, model_id:, fallback_model_id: nil, **attributes)
        build_result(
          runner: runner,
          model_id: model_id,
          supported: nil,
          reason: attributes.delete(:reason) || UNKNOWN_REASON,
          fallback_model_id: fallback_model_id,
          source: attributes.delete(:source) || :unknown,
          **attributes
        )
      end

      private

      def default_reason_for(supported)
        case supported
        when true then SUPPORTED_REASON
        else UNKNOWN_REASON
        end
      end
    end
  end
end
