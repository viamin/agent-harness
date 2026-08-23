# frozen_string_literal: true

require "rubygems/requirement"

module AgentHarness
  module Providers
    # Oh My Pi coding agent CLI provider
    #
    # Provides integration with the Oh My Pi (can1357/oh-my-pi) terminal
    # coding agent, a Bun-based fork of the Pi coding agent. Distinct from
    # the {Pi} provider, which targets the upstream @mariozechner/pi-coding-agent
    # CLI.
    class OhMyPi < Base
      CLI_PACKAGE = "@oh-my-pi/pi-coding-agent"
      SUPPORTED_CLI_VERSION = "17.3.5"
      SUPPORTED_CLI_REQUIREMENT = Gem::Requirement.new("= #{SUPPORTED_CLI_VERSION}").freeze

      # Bun runtime requirements. The omp entrypoint is
      # `#!/usr/bin/env bun` and the published package metadata requires
      # Bun `>= 1.3.14`. Consumers must provision a compatible Bun runtime
      # before installing the @oh-my-pi/pi-coding-agent package.
      #
      # The `bun` npm package relies on its `postinstall` script to fetch the
      # platform binary; installing it with `npm install --ignore-scripts`
      # ships only the Windows shims (`bin/bun.exe`, `bunx.exe`) and leaves
      # Linux/macOS without a working `bun` binary. Provision Bun via the
      # official installer script instead, which fetches the correct
      # platform binary directly.
      BUN_BINARY = "bun"
      BUN_INSTALL_SCRIPT_URL = "https://bun.sh/install"
      SUPPORTED_BUN_VERSION = "1.4.0"
      BUN_REQUIREMENT_STRING = ">= #{SUPPORTED_BUN_VERSION}".freeze

      # Smoke-test contract suitable for container health probes.
      #
      # Oh My Pi runs non-interactively via `-p` with `--no-session`, so the
      # probe is a single deterministic round trip. The contract is tuned for
      # a tight probe budget: a short prompt that elicits a predictable reply
      # and a bounded timeout that accommodates a cold Bun runtime start.
      SMOKE_TEST_CONTRACT = {
        prompt: "Reply with exactly OK.",
        expected_output: "OK",
        timeout: 30,
        require_output: true,
        success_message: "Oh My Pi smoke test passed"
      }.freeze

      # Oh My Pi is a multi-provider CLI: it routes to a backend through
      # `--provider` and surfaces that backend's error vocabulary. The
      # patterns below extend the shared HTTP-style set with Oh My Pi /
      # upstream-Pi specific phrasing observed for auth expiry, quota and
      # rate-limit surfaces, model resolution failures, and transient
      # network faults.
      ERROR_PATTERNS = {
        rate_limited: COMMON_ERROR_PATTERNS[:rate_limited],
        auth_expired: COMMON_ERROR_PATTERNS[:auth_expired] + [
          /\b401\b/,
          /session.*(?:expired|invalid)/i,
          /log(?:ged)?.?in.*required/i,
          /api.?key.*(?:invalid|missing|expired|revoked)/i,
          /token.*(?:expired|invalid|revoked)/i,
          /credentials.*(?:expired|invalid|missing)/i
        ],
        quota_exceeded: COMMON_ERROR_PATTERNS[:quota_exceeded],
        # Model resolution is surfaced by both the omp CLI (unknown
        # `--model`/`--provider` combination) and the upstream backend.
        # Treat it as a distinct, non-retryable category so callers can
        # fall back to a known-good model instead of retrying the same id.
        model_not_found: [
          /model.*not.*found/i,
          /no.*such.*model/i,
          /unknown.*model/i,
          /model.*does.*not.*exist/i,
          /invalid.*model/i,
          /model.*unavailable/i,
          /provider.*does.*not.*support.*model/i
        ],
        transient: COMMON_ERROR_PATTERNS[:transient] + [
          /connection.*reset/i,
          /econnreset/i,
          /socket.*hang.*up/i,
          /network.*error/i
        ]
      }.tap { |patterns| patterns.each_value(&:freeze) }.freeze

      # Non-actionable output that Oh My Pi writes while the Bun runtime and
      # the agent bootstrap. Downstream consumers use these to filter probe
      # and run output so startup banners do not masquerade as failures.
      NOISY_OUTPUT_PATTERNS = [
        /oh.?my.?pi\b/i,
        /pi(?:-coding.?agent)?\s+v?\d+\.\d+/i,
        /\bbun\s+v?\d+\.\d+/i,
        /\bloading/i,
        /\binitializing/i,
        /\bwarming.?up/i,
        /fetching.*model/i
      ].freeze

      class << self
        def provider_name
          :omp
        end

        def binary_name
          "omp"
        end

        def available?
          executor = AgentHarness.configuration.command_executor
          !!executor.which(binary_name)
        end

        def provider_metadata_overrides
          {
            auth: {
              service: :omp,
              api_family: :multi_provider,
              # Oh My Pi routes to a backend through `--provider` and reads
              # that backend's API key from its conventional env var. The
              # harness never reuses the upstream Pi credential store
              # (paid_pi_auth_entry); callers pass backend keys per request
              # through ProviderRuntime#env, which build_env materializes into
              # the subprocess environment. This keeps the omp runner an
              # independent entity from :pi.
              #
              # Deliberately do NOT advertise a harness-managed credential
              # store here. Authentication has no omp read/write/validate path,
              # so auth_status(:omp) reports "not implemented"; exposing
              # credential_store would imply a session store that does not
              # exist and let callers infer harness-managed session auth.
              # Surface the implemented per-request env model instead.
              api_key_source: :provider_runtime_env
            }
          }
        end

        def firewall_requirements
          {
            domains: [
              "pi.dev"
            ],
            ip_ranges: []
          }
        end

        def instruction_file_paths
          [
            {
              path: "AGENTS.md",
              description: "Oh My Pi agent instructions",
              symlink: false
            },
            {
              path: "SYSTEM.md",
              description: "Oh My Pi system prompt override",
              symlink: false
            }
          ]
        end

        def discover_models
          return [] unless available?
          []
        end

        def bun_runtime_contract
          # The official Bun installer reads `BUN_VERSION` to pin the release
          # it downloads, and fetches the platform-appropriate binary itself.
          install_command_prefix = ["sh", "-c"].freeze
          inner_script = "curl -fsSL #{BUN_INSTALL_SCRIPT_URL} | " \
                          "BUN_VERSION=#{SUPPORTED_BUN_VERSION} bash"
          install_command = (install_command_prefix + [inner_script]).freeze

          {
            name: :bun,
            binary_name: BUN_BINARY,
            pinned_version: SUPPORTED_BUN_VERSION,
            version_requirement: BUN_REQUIREMENT_STRING,
            source: :script,
            install_script_url: BUN_INSTALL_SCRIPT_URL,
            install_command_prefix: install_command_prefix,
            install_command: install_command,
            install_command_string: inner_script,
            rationale: "omp entrypoint is #!/usr/bin/env bun; the bun npm package relies on " \
                       "its postinstall script to fetch the platform binary, so install Bun " \
                       "via the official installer script rather than npm --ignore-scripts"
          }.freeze
        end

        def installation_contract(version: SUPPORTED_CLI_VERSION)
          version = version.strip if version.respond_to?(:strip)

          unless version.is_a?(String) && !version.empty?
            raise ArgumentError,
              "Unsupported Oh My Pi CLI version #{version.inspect}; " \
              "supported versions must satisfy #{SUPPORTED_CLI_REQUIREMENT}"
          end

          parsed_version = begin
            Gem::Version.new(version)
          rescue ArgumentError
            raise ArgumentError,
              "Unsupported Oh My Pi CLI version #{version.inspect}; " \
              "supported versions must satisfy #{SUPPORTED_CLI_REQUIREMENT}"
          end

          unless SUPPORTED_CLI_REQUIREMENT.satisfied_by?(parsed_version)
            raise ArgumentError,
              "Unsupported Oh My Pi CLI version #{version.inspect}; " \
              "supported versions must satisfy #{SUPPORTED_CLI_REQUIREMENT}"
          end

          package = "#{CLI_PACKAGE}@#{version}".freeze
          install_command_prefix = ["npm", "install", "-g", "--ignore-scripts"].freeze
          install_command = (install_command_prefix + [package]).freeze
          supported_versions = [version].freeze
          version_requirement = SUPPORTED_CLI_REQUIREMENT.requirements
            .map { |op, ver| "#{op} #{ver}".freeze }
            .freeze

          contract = {
            source: :npm,
            package: package,
            package_name: CLI_PACKAGE,
            version: version,
            version_requirement: version_requirement,
            binary_name: binary_name,
            install_command_prefix: install_command_prefix,
            install_command: install_command,
            supported_versions: supported_versions,
            runtime_requirements: [bun_runtime_contract]
          }

          contract.each_value do |value|
            value.freeze if value.is_a?(String)
          end
          contract.freeze
        end

        def smoke_test_contract
          SMOKE_TEST_CONTRACT
        end
      end

      def name
        "omp"
      end

      def display_name
        "Oh My Pi"
      end

      def configuration_schema
        {
          fields: [
            {
              name: :model,
              type: :string,
              label: "Model",
              required: false,
              hint: "Oh My Pi model pattern or ID passed to --model"
            },
            {
              name: :provider,
              type: :string,
              label: "Provider",
              required: false,
              hint: "Oh My Pi provider name passed to --provider"
            }
          ],
          auth_modes: %i[api_key oauth],
          openai_compatible: false
        }
      end

      def capabilities
        {
          streaming: false,
          file_upload: true,
          vision: true,
          tool_use: true,
          # Oh My Pi's non-interactive CLI currently exposes only text print mode.
          # Keep JSON mode disabled until the CLI ships a structured output flag.
          json_mode: false,
          # MCP capability decision: the omp non-interactive print-mode path
          # (`omp --no-session -p`) does not accept an MCP server config flag
          # in the harness's supported CLI version. Keep MCP disabled here so
          # callers do not attempt to attach servers that the runtime would
          # reject. Revisit once omp ships a stable `--mcp-config` flag.
          mcp: false,
          dangerous_mode: false
        }
      end

      def error_patterns
        ERROR_PATTERNS
      end

      # Downstream-facing error classification. Augments the shared quota set
      # with auth-expiry, model-resolution, and authentication-specific
      # phrasing so consumers can route omp failures without re-deriving the
      # CLI vocabulary. The inherited `:quota` set is deliberately preserved
      # (not overridden) so omp's multi-provider backends surface their full
      # credit/balance vocabulary (requires more credits, insufficient
      # balance, spend limit reached, billing limit, etc.).
      def error_classification_patterns
        super.merge(
          auth_expired: ERROR_PATTERNS[:auth_expired],
          authentication: [
            /api.?key.*not.*(?:set|configured)/i,
            /no.*api.?key/i,
            /missing.*credentials/i,
            /log(?:ged)?.?in.*required/i
          ],
          model_not_found: ERROR_PATTERNS[:model_not_found]
        )
      end

      # Oh My Pi emits a startup banner (version, Bun runtime, model fetch)
      # that is not actionable. Expose it so callers can strip probe noise.
      def noisy_error_patterns
        NOISY_OUTPUT_PATTERNS
      end

      def translate_error(message)
        if ERROR_PATTERNS[:model_not_found].any? { |p| message.match?(p) }
          "Oh My Pi could not resolve the requested model. Check --model/--provider."
        elsif /api.?key.*not.*(?:set|configured)/i.match?(message) || /no.*api.?key/i.match?(message)
          "Oh My Pi API key not set for the selected provider."
        else
          message
        end
      end

      # Oh My Pi runs stateless through `--no-session`; the harness does not
      # expose session persistence, so callers cannot resume a session.
      def supports_sessions?
        false
      end

      def supports_tool_control?
        true
      end

      def auth_type
        :oauth
      end

      # Conventional backend API-key env vars the omp CLI reads. Oh My Pi is
      # multi-provider: the effective var is the one matching the selected
      # `--provider`, supplied per request through ProviderRuntime#env.
      def api_key_env_var_names
        [
          "ANTHROPIC_API_KEY",
          "OPENAI_API_KEY",
          "GEMINI_API_KEY",
          "GOOGLE_API_KEY",
          "XAI_API_KEY",
          "DEEPSEEK_API_KEY",
          "OPENROUTER_API_KEY",
          "GROQ_API_KEY",
          "MISTRAL_API_KEY"
        ]
      end

      # omp routes through `--provider` rather than an env-driven proxy/base
      # URL, so there are no known proxy header vars to scrub when a caller
      # supplies its own key.
      def api_key_unset_vars
        []
      end

      # When running against an OAuth/subscription session, drop backend
      # API-key env vars so the CLI prefers the stored session credentials.
      def subscription_unset_vars
        api_key_env_var_names
      end

      def execution_semantics
        {
          prompt_delivery: :flag,
          output_format: :text,
          sandbox_aware: false,
          uses_subcommand: false,
          non_interactive_flag: "-p",
          legitimate_exit_codes: [0],
          stderr_is_diagnostic: true,
          parses_rate_limit_reset: false
        }
      end

      protected

      def build_command(prompt, options)
        runtime = options[:provider_runtime]
        provider = runtime&.api_provider || @config.provider
        model = runtime&.model || @config.model

        cmd = [self.class.binary_name, "--no-session"]
        cmd += @config.default_flags if @config.default_flags&.any?
        cmd += runtime.flags if runtime
        cmd += ["--provider", provider] if provider
        cmd += ["--model", model] if model
        cmd << "--no-tools" if options[:tools] == :none
        cmd += ["-p", prompt]

        cmd
      end

      def default_timeout
        300
      end
    end
  end
end
