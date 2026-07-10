# frozen_string_literal: true

RSpec.describe AgentHarness::Providers::Codex, ".model_compatibility" do
  it "returns supported for baseline models on any CLI version" do
    result = described_class.model_compatibility(
      model_id: "gpt-5-codex",
      auth_mode: :api_key,
      cli_version: "0.122.0"
    )

    expect(result).to be_a(AgentHarness::ModelCompatibility::Result)
    expect(result.runner).to eq(:codex)
    expect(result.supported?).to be(true)
    expect(result.reason).to eq(:supported)
    expect(result.source).to eq(:static_contract)
  end

  it "returns supported when CLI version satisfies the model's minimum requirement" do
    result = described_class.model_compatibility(
      model_id: "gpt-5.5",
      auth_mode: :subscription,
      cli_version: "0.122.0"
    )

    expect(result.supported?).to be(true)
    expect(result.minimum_cli_version).to eq("0.116.0")
    expect(result.cli_version_requirement).to include("0.116.0")
  end

  it "returns unsupported with :cli_version_too_old when CLI is older than the model requires" do
    result = described_class.model_compatibility(
      model_id: "gpt-5.5",
      auth_mode: :subscription,
      cli_version: "0.115.0"
    )

    expect(result.supported?).to be(false)
    expect(result.unsupported?).to be(true)
    expect(result.reason).to eq(:cli_version_too_old)
    expect(result.minimum_cli_version).to eq("0.116.0")
    expect(result.fallback_model_id).to eq(described_class::DEFAULT_COMPATIBLE_MODEL_ID)
    expect(result.source).to eq(:static_contract)
  end

  it "returns unsupported for models disallowed under subscription auth" do
    result = described_class.model_compatibility(
      model_id: "gpt-5.5-pro",
      auth_mode: :subscription,
      cli_version: "0.122.0"
    )

    expect(result.supported?).to be(false)
    expect(result.unsupported?).to be(true)
    expect(result.reason).to eq(:unsupported_auth_mode_for_model)
    expect(result.details).to include(supported_auth_modes: [:api_key])
    expect(result.fallback_model_id).to eq(described_class::DEFAULT_COMPATIBLE_MODEL_ID)
    expect(result.source).to eq(:static_contract)
  end

  it "returns supported for models restricted to api_key when api_key auth is requested" do
    result = described_class.model_compatibility(
      model_id: "gpt-5.5-pro",
      auth_mode: :api_key,
      cli_version: "0.122.0"
    )

    expect(result.supported?).to be(true)
    expect(result.reason).to eq(:supported)
    expect(result.source).to eq(:static_contract)
  end

  it "returns :auth_mode_unknown when an auth-gated model is queried without an auth mode" do
    # `auth_mode` defaults to nil on the public API, so querying an
    # api-key-only model without an auth mode must NOT collapse to :supported
    # — that would let a caller treat it as approval and schedule the run
    # under subscription. Surface :unknown with the allowed auth modes so
    # callers decide deliberately. Mirrors the sibling CLI-version dimension.
    result = described_class.model_compatibility(
      model_id: "gpt-5.5-pro",
      auth_mode: nil,
      cli_version: "0.122.0"
    )

    expect(result.unknown?).to be(true)
    expect(result.supported).to be_nil
    expect(result.reason).to eq(:auth_mode_unknown)
    expect(result.details).to include(supported_auth_modes: [:api_key])
    expect(result.fallback_model_id).to eq(described_class::DEFAULT_COMPATIBLE_MODEL_ID)
    expect(result.source).to eq(:static_contract)
  end

  it "returns :auth_mode_unknown through the public API default when auth_mode is omitted" do
    result = AgentHarness.model_compatibility(
      runner: :codex,
      model_id: "gpt-5.5-pro"
    )

    expect(result.unknown?).to be(true)
    expect(result.reason).to eq(:auth_mode_unknown)
    expect(result.details).to include(supported_auth_modes: [:api_key])
  end

  it "returns unknown_model for models not in the static contract" do
    result = described_class.model_compatibility(
      model_id: "gpt-future-9000",
      auth_mode: :api_key,
      cli_version: "0.122.0"
    )

    expect(result.unknown?).to be(true)
    expect(result.supported).to be_nil
    expect(result.reason).to eq(:unknown_model)
    expect(result.fallback_model_id).to eq(described_class::DEFAULT_COMPATIBLE_MODEL_ID)
    expect(result.source).to eq(:unknown)
  end

  it "returns :unknown with the minimum requirement when no CLI version is supplied for a CLI-gated model" do
    # No installed-version signal: the runner cannot confirm the installed
    # CLI is new enough, so it must NOT collapse to :supported (that would
    # re-introduce the `gpt-5.5` on old-CLI failure class). Surface :unknown
    # with the requirement attached so callers can decide deliberately.
    result = described_class.model_compatibility(
      model_id: "gpt-5.5",
      auth_mode: :subscription,
      cli_version: nil
    )

    expect(result.unknown?).to be(true)
    expect(result.supported).to be_nil
    expect(result.reason).to eq(:cli_version_unknown)
    expect(result.minimum_cli_version).to eq("0.116.0")
    expect(result.cli_version_requirement).to include("0.116.0")
    expect(result.fallback_model_id).to eq(described_class::DEFAULT_COMPATIBLE_MODEL_ID)
    expect(result.source).to eq(:static_contract)
  end

  it "returns :auth_mode_not_supported for unrecognised auth modes" do
    result = described_class.model_compatibility(
      model_id: "gpt-5-codex",
      auth_mode: :sso,
      cli_version: "0.122.0"
    )

    expect(result.unsupported?).to be(true)
    expect(result.reason).to eq(:auth_mode_not_supported)
    expect(result.details).to include(supported_auth_modes: described_class::SUPPORTED_AUTH_MODES)
  end

  it "normalizes model_id symbols and Gem::Version cli_version inputs" do
    result = described_class.model_compatibility(
      model_id: :"gpt-5.5",
      auth_mode: :subscription,
      cli_version: Gem::Version.new("0.116.0")
    )

    expect(result.model_id).to eq("gpt-5.5")
    expect(result.supported?).to be(true)
  end

  it "treats unparseable cli_version as :unknown for CLI-gated models rather than upgrading to supported" do
    result = described_class.model_compatibility(
      model_id: "gpt-5.5",
      auth_mode: :subscription,
      cli_version: "not-a-version"
    )

    # Cannot determine version too-old without a parseable version. The
    # runner stays explicit (:unknown) rather than reporting :supported, so
    # callers do not silently schedule onto an unverified CLI.
    expect(result.unknown?).to be(true)
    expect(result.reason).to eq(:cli_version_unknown)
    expect(result.minimum_cli_version).to eq("0.116.0")
    expect(result.fallback_model_id).to eq(described_class::DEFAULT_COMPATIBLE_MODEL_ID)
  end

  it "is reachable through AgentHarness.model_compatibility" do
    result = AgentHarness.model_compatibility(
      runner: :codex,
      model_id: "gpt-5.5-pro",
      auth_mode: :subscription,
      cli_version: "0.122.0"
    )

    expect(result.runner).to eq(:codex)
    expect(result.reason).to eq(:unsupported_auth_mode_for_model)
  end

  it "is reachable through Providers::Registry#model_compatibility" do
    result = AgentHarness::Providers::Registry.instance.model_compatibility(
      :codex,
      model_id: "gpt-5-codex",
      auth_mode: :api_key,
      cli_version: "0.122.0"
    )

    expect(result.supported?).to be(true)
  end
end

RSpec.describe AgentHarness::Providers, "default model_compatibility" do
  # Pick a provider that does not override model_compatibility to confirm the
  # default Adapter implementation returns an :unknown result rather than a
  # silent success.
  let(:provider_class) { AgentHarness::Providers::Cursor }

  it "returns an :unknown result so callers must handle the case explicitly" do
    result = provider_class.model_compatibility(
      model_id: "anything",
      auth_mode: :api_key,
      cli_version: "1.2.3"
    )

    expect(result).to be_a(AgentHarness::ModelCompatibility::Result)
    expect(result.unknown?).to be(true)
    expect(result.reason).to eq(:unknown)
    expect(result.source).to eq(:unknown)
  end
end
