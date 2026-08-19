# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "uri"

module AgentHarness
  # Scheduled refresh for CLI artifact pins Dependabot cannot see.
  #
  # The gem's `Providers::Cursor` install contract pins an artifact URL + SHA256
  # that no npm/PyPI manifest tracks. The Claude install oracle (npm
  # `@anthropic-ai/claude-code`) and the `claude.ai/install.sh` curl installer
  # historically publish lockstep, but that is an assumption, not a contract.
  #
  # This module implements the step-3 scheduled job from issue #338: a weekly
  # cron that (a) refreshes the Cursor pin via the upstream GitHub releases
  # API, (b) verifies Claude oracle parity, and (c) runs an advisory parity
  # sweep across every provider's `SUPPORTED_CLI_VERSION`.
  #
  # The library is decoupled from any single HTTP/file/CLI backend so the
  # weekly job and `script/refresh-artifact-pins.rb` can share logic, and so
  # RSpec can exercise each step without touching the network, the working
  # tree, or the `gh` CLI.
  module CliPinRefresh
    # Outcome of a refresh step. The status is one of:
    #
    #   :unchanged  - upstream matches what is already pinned (no-op)
    #   :changed    - upstream differs; a PR was opened or should be opened
    #   :divergent  - sources disagree with each other (e.g. install.sh vs npm)
    #   :failed     - a transient infrastructure error prevented a decision
    #
    # `details` carries the structured facts that drove the decision so the
    # script can produce a useful PR/issue body and specs can assert on it.
    class Result
      attr_reader :status, :details

      def initialize(status:, details: {})
        @status = status.to_sym
        @details = details
      end

      def unchanged?
        @status == :unchanged
      end

      def changed?
        @status == :changed
      end

      def divergent?
        @status == :divergent
      end

      def failed?
        @status == :failed
      end

      def to_h
        {status: @status, details: @details}
      end
    end

    # Minimal HTTP client the refresh steps share. Tests substitute an
    # instance_double; production uses Net::HTTP so we avoid pulling in a
    # heavy HTTP gem just for two GET requests.
    class HttpClient
      DEFAULT_TIMEOUT = 30
      MAX_REDIRECTS = 5

      # @param timeout [Integer] per-request timeout in seconds
      def initialize(timeout: DEFAULT_TIMEOUT)
        @timeout = timeout
      end

      # @param url [String] absolute URL to GET
      # @return [String] response body of the final response in the
      #   redirect chain
      # @raise [FetchError] on transport failure, non-2xx response, or a
      #   redirect chain longer than MAX_REDIRECTS
      def get(url)
        get_following_redirects(url, 0)
      end

      # Raised when an HTTP request cannot be completed.
      class FetchError < StandardError; end

      private

      # Net::HTTP does not follow redirects on its own, and endpoints we
      # probe (e.g. https://claude.ai/install.sh) answer with a 302 to a
      # different host, so the chain is resolved explicitly with a hop
      # limit to keep a redirect loop from hanging the job.
      def get_following_redirects(url, hops)
        raise FetchError, "GET #{url} exceeded #{MAX_REDIRECTS} redirects" if hops > MAX_REDIRECTS

        response = get_response(URI.parse(url))
        case response
        when Net::HTTPRedirection
          location = response["Location"].to_s
          raise FetchError, "GET #{url} redirected without a Location header" if location.empty?

          get_following_redirects(redirect_target(url, location), hops + 1)
        when Net::HTTPSuccess
          response.body
        else
          raise FetchError, "GET #{url} returned #{response.code}: #{response.message}"
        end
      rescue Net::OpenTimeout, Net::ReadTimeout, EOFError, SocketError, Errno::ECONNREFUSED,
        URI::InvalidURIError, ArgumentError => e
        raise FetchError, "GET #{url} failed: #{e.class}: #{e.message}"
      end

      # Location may be absolute or relative; anything that is not
      # http(s) after resolution (a compromised endpoint could redirect
      # to file:/// or similar) is rejected.
      def redirect_target(url, location)
        target = URI.join(url, location)
        return target.to_s if target.is_a?(URI::HTTP)

        raise FetchError, "GET #{url} redirected to unsupported scheme #{target.scheme.inspect}"
      end

      def get_response(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = @timeout
        http.read_timeout = @timeout
        http.get(uri.request_uri)
      end
    end

    # Reads the Cursor pin constants in
    # `lib/agent_harness/providers/cursor.rb`. The script edits that file
    # in place because the install contract is generated from those
    # constants; updating just `cursor.rb` keeps the existing spec
    # coverage (and the parity spec) the gate.
    class CursorSource
      # Matches both constants regardless of value or surrounding whitespace.
      CONSTANT_PATTERN = /
        \b(?<name>INSTALL_(?:BUILD|LINUX_X64_PACKAGE_SHA256))\s*=\s*
        "(?<value>[^"]+)"
      /x

      attr_reader :file_path

      def initialize(file_path:)
        @file_path = file_path
      end

      # @return [String] the value of `INSTALL_BUILD`
      def current_build
        constants.fetch(:build)
      end

      # @return [String] the value of `INSTALL_LINUX_X64_PACKAGE_SHA256`
      def current_sha256
        constants.fetch(:linux_x64_package_sha256)
      end

      # @return [Hash{Symbol=>String}] parsed constants, e.g.
      #   `{build: "2026.03.30-a5d3e17", linux_x64_package_sha256: "e0d4..."}`
      def constants
        match_data = File.read(file_path).scan(CONSTANT_PATTERN)
        raise ParseError, "Could not parse Cursor pin constants in #{file_path}" if match_data.empty?

        match_data.each_with_object({}) do |(name, value), acc|
          acc[constant_key(name)] = value
        end
      end

      # Render the file with the new constants substituted. Returns the
      # updated content without writing to disk so the caller can decide
      # whether to commit, dry-run, or pipe to `gh`.
      #
      # @param build [String] new `INSTALL_BUILD`
      # @param sha256 [String] new `INSTALL_LINUX_X64_PACKAGE_SHA256`
      # @return [String] updated file content
      def render(build:, sha256:)
        content = File.read(file_path)
        content.sub(/(\bINSTALL_BUILD\s*=\s*)"[^"]+"/, "\\1\"#{build}\"")
          .sub(/(\bINSTALL_LINUX_X64_PACKAGE_SHA256\s*=\s*)"[^"]+"/, "\\1\"#{sha256}\"")
      end

      # Raised when the Cursor source file cannot be parsed.
      class ParseError < StandardError; end

      private

      def constant_key(name)
        case name
        when "INSTALL_BUILD" then :build
        when "INSTALL_LINUX_X64_PACKAGE_SHA256" then :linux_x64_package_sha256
        else name.downcase.to_sym
        end
      end
    end

    # Queries the Cursor agent GitHub releases API for the latest published
    # build identifier. The repository is configurable so the same class can
    # target whatever upstream source ships the `linux/x64` artifact.
    class GithubCursorReleases
      DEFAULT_REPOSITORY = "cursor/agent"

      def initialize(http_client:, repository: DEFAULT_REPOSITORY)
        @http_client = http_client
        @repository = repository
      end

      # @return [String, nil] latest build identifier, or nil if no asset for
      #   the linux/x64 target is attached to the latest release
      def latest_linux_x64_build
        release = latest_release
        asset = linux_x64_asset(release)
        return nil unless asset

        build_from_asset(asset)
      end

      # @return [String] release-notes URL for the latest release, or nil
      #   when the API response did not include one (defensive: don't fail
      #   the whole step just because html_url was missing).
      def latest_release_url
        latest_release["html_url"]
      rescue HttpClient::FetchError
        nil
      end

      private

      # @return [Hash] parsed GitHub release payload
      def latest_release
        body = @http_client.get(releases_url)
        JSON.parse(body)
      end

      def releases_url
        "https://api.github.com/repos/#{@repository}/releases/latest"
      end

      # GitHub release assets are usually named after the target triple; we
      # accept any asset whose name contains both "linux" and "x64".
      def linux_x64_asset(release)
        Array(release["assets"]).find do |asset|
          name = asset["name"].to_s.downcase
          name.include?("linux") && name.include?("x64")
        end
      end

      # The asset name typically encodes the build (e.g.
      # `cursor-agent-linux-x64-2026.03.30-a5d3e17.tar.gz`); the build id is
      # the segment that matches the cursor.rb URL pattern.
      def build_from_asset(asset)
        match = asset["name"].match(/\b(\d{4}\.\d{2}\.\d{2}-[a-f0-9]+)\b/)
        match && match[1]
      end
    end

    # Downloads an artifact from a URL and computes its SHA256. Used after
    # `GithubCursorReleases#latest_linux_x64_build` to confirm the artifact
    # the GitHub release points at matches the same checksum we'd get by
    # pinning the cursor.com download path.
    class ArtifactDownloader
      def initialize(http_client:)
        @http_client = http_client
      end

      # @param url [String] artifact URL
      # @return [String] lowercase hex SHA256 of the response body
      def sha256(url)
        body = @http_client.get(url)
        Digest::SHA256.hexdigest(body)
      end
    end

    # Builds the canonical Cursor `linux/x64` download URL. Mirrors the
    # helper inside `Providers::Cursor` so we can verify the GitHub release
    # asset points at the same artifact the install contract pins.
    module CursorArtifactUrl
      PACKAGE_BASENAME = "agent-cli-package.tar.gz"

      def self.call(build:, os: "linux", arch: "x64")
        "https://downloads.cursor.com/lab/#{build}/#{os}/#{arch}/#{PACKAGE_BASENAME}"
      end
    end

    # Decides whether the Cursor pin needs to be refreshed. Returns a
    # `Result` with `:status` (`:unchanged` or `:changed`) plus the upstream
    # facts the runner needs to build a PR.
    class CursorRefresh
      def initialize(releases:, downloader:, source:, artifact_url_builder: CursorArtifactUrl)
        @releases = releases
        @downloader = downloader
        @source = source
        @artifact_url_builder = artifact_url_builder
      end

      def call
        build = @releases.latest_linux_x64_build
        if build.nil?
          return Result.new(status: :failed, details: {reason: "no linux/x64 asset on latest release"})
        end

        current_build = @source.current_build
        current_sha256 = @source.current_sha256
        artifact_url = @artifact_url_builder.call(build: build)
        upstream_sha256 = @downloader.sha256(artifact_url)
        release_url = @releases.latest_release_url

        if build == current_build && upstream_sha256 == current_sha256
          return Result.new(status: :unchanged, details: {build: build, sha256: upstream_sha256})
        end

        Result.new(
          status: :changed,
          details: {
            build: build,
            sha256: upstream_sha256,
            artifact_url: artifact_url,
            release_url: release_url,
            previous_build: current_build,
            previous_sha256: current_sha256
          }
        )
      rescue HttpClient::FetchError => e
        Result.new(status: :failed, details: {reason: e.message})
      end
    end

    # Resolves which Claude CLI version `claude.ai/install.sh` actually
    # installs. We never execute the script (security: never execute
    # untrusted code outside a sandbox); instead we fetch it (following
    # its redirect to the real installer host), read the download base
    # URL it resolves versions from, and then ask that host's `latest`
    # endpoint for the plain-text version - the exact lookup the
    # installer performs via `version=$(download_file
    # "$DOWNLOAD_BASE_URL/latest")`. Probing the endpoint the script
    # calls keeps working when the version moves out of the script body.
    class ClaudeInstallerProbe
      # The installer defines its download base as a quoted assignment:
      #   DOWNLOAD_BASE_URL="https://downloads.claude.ai/claude-code-releases"
      DOWNLOAD_BASE_URL_PATTERN = /DOWNLOAD_BASE_URL=["'](?<url>[^"']+)["']/

      # The `latest` endpoint answers with a bare version, optionally
      # `v`-prefixed, e.g. `2.1.235` or `v2.1.235`.
      VERSION_PATTERN = /\A\s*v?(?<version>\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?)\s*\z/

      attr_reader :install_script_url

      def initialize(http_client:, install_script_url:)
        @http_client = http_client
        @install_script_url = install_script_url
      end

      # @return [String, nil] version string the installer would install,
      #   or nil when the script or the version endpoint cannot be
      #   resolved.
      def resolved_version
        base_url = download_base_url
        return nil if base_url.nil?

        body = @http_client.get("#{base_url}/latest")
        match = body.match(VERSION_PATTERN)
        match && match[:version]
      rescue HttpClient::FetchError
        nil
      end

      private

      def download_base_url
        script = @http_client.get(install_script_url)
        match = script.match(DOWNLOAD_BASE_URL_PATTERN)
        match && match[:url].sub(%r{/\z}, "")
      rescue HttpClient::FetchError
        nil
      end
    end

    # Reads the canonical version of an npm package from the public registry.
    # We only need the published `version` field, so the lightweight
    # `/{package}/latest` endpoint is enough.
    class NpmRegistry
      DEFAULT_REGISTRY = "https://registry.npmjs.org"

      def initialize(http_client:, registry_url: DEFAULT_REGISTRY)
        @http_client = http_client
        @registry_url = registry_url
      end

      # @param package_name [String] npm package name (e.g.
      #   `"@anthropic-ai/claude-code"`)
      # @return [String, nil] latest published version, or nil on failure
      def latest_version(package_name)
        encoded = URI.encode_www_form_component(package_name)
        body = @http_client.get("#{@registry_url}/#{encoded}/latest")
        JSON.parse(body)["version"]
      rescue HttpClient::FetchError
        nil
      end
    end

    # Compares the version the Claude installer resolves to with the
    # version pinned as the npm oracle in `vendor/pins/claude/package.json`.
    # Returns `:divergent` when they disagree - the script then opens an
    # issue rather than guessing which side is right.
    class ClaudeOracleCheck
      DEFAULT_PACKAGE_NAME = "@anthropic-ai/claude-code"

      def initialize(
        installer_probe:,
        npm_registry:,
        pinned_version:,
        package_name: DEFAULT_PACKAGE_NAME
      )
        @installer_probe = installer_probe
        @npm_registry = npm_registry
        @pinned_version = pinned_version
        @package_name = package_name
      end

      def call
        installer_version = @installer_probe.resolved_version
        npm_version = @npm_registry.latest_version(@package_name)

        if installer_version.nil? || npm_version.nil?
          return Result.new(
            status: :failed,
            details: {
              pinned_version: @pinned_version,
              installer_version: installer_version,
              npm_version: npm_version
            }
          )
        end

        if installer_version == npm_version
          return Result.new(
            status: :unchanged,
            details: {
              pinned_version: @pinned_version,
              installer_version: installer_version,
              npm_version: npm_version
            }
          )
        end

        Result.new(
          status: :divergent,
          details: {
            pinned_version: @pinned_version,
            installer_version: installer_version,
            npm_version: npm_version
          }
        )
      end
    end

    # Advisory parity sweep across every provider's `SUPPORTED_CLI_VERSION`
    # constant vs the manifest it should mirror. Mirrors the CI parity
    # spec (`spec/vendor_pins_parity_spec.rb`) so a hand-edited constant
    # drifts visibly inside one cron window instead of waiting for the
    # next Dependabot bump.
    class ParitySweep
      attr_reader :pins_dir, :repo_root

      def initialize(pins_dir:, repo_root:)
        @pins_dir = pins_dir
        @repo_root = repo_root
      end

      # @return [Result] `:unchanged` when every provider constant agrees
      #   with its manifest, `:divergent` otherwise (with the offenders in
      #   `details[:offenders]`).
      def call
        offenders = (npm_offenders + pip_offenders).compact
        if offenders.empty?
          return Result.new(status: :unchanged, details: {})
        end

        Result.new(status: :divergent, details: {offenders: offenders})
      end

      private

      def npm_offenders
        npm_cases.flat_map do |provider_dir, spec_data|
          scan_npm_manifest(provider_dir, spec_data)
        end
      end

      def scan_npm_manifest(provider_dir, spec_data)
        manifest_path = File.join(pins_dir, provider_dir, spec_data[:manifest])
        return [] unless File.exist?(manifest_path)

        manifest = JSON.parse(File.read(manifest_path))

        spec_data[:packages].filter_map do |package, resolver|
          expected = resolver.call
          pinned = manifest.dig("devDependencies", package)
          next if pinned == expected

          {
            ecosystem: "npm",
            provider: provider_dir,
            package: package,
            manifest_value: pinned,
            constant_value: expected,
            manifest_path: manifest_path
          }
        end
      end

      def pip_offenders
        pip_cases.flat_map do |provider_dir, spec_data|
          scan_pip_manifest(provider_dir, spec_data)
        end
      end

      def scan_pip_manifest(provider_dir, spec_data)
        manifest_path = File.join(pins_dir, provider_dir, spec_data[:manifest])
        return [] unless File.exist?(manifest_path)

        File.readlines(manifest_path, chomp: true).filter_map do |line|
          stripped = line.strip
          next if stripped.empty? || stripped.start_with?("#")

          name, version = stripped.split("==", 2)
          package = name&.strip
          resolver = spec_data[:packages][package]
          next unless resolver

          expected = resolver.call
          next if version&.strip == expected

          {
            ecosystem: "pip",
            provider: provider_dir,
            package: package,
            manifest_value: version&.strip,
            constant_value: expected,
            manifest_path: manifest_path
          }
        end
      end

      # Each entry maps the tracked packages to a resolver for the
      # provider constant the manifest must mirror. omp needs two
      # resolvers, which is why the resolver hangs off the package, not
      # the provider. pi and omp are lazy-loaded via the provider
      # registry, so callers must require them explicitly (the same way
      # spec/vendor_pins_parity_spec.rb does).
      def npm_cases
        {
          "claude" => {
            manifest: "package.json",
            packages: {
              "@anthropic-ai/claude-code" => -> { AgentHarness::Providers::Anthropic::SUPPORTED_CLI_VERSION }
            }
          },
          "codex" => {
            manifest: "package.json",
            packages: {
              "@openai/codex" => -> { AgentHarness::Providers::Codex::SUPPORTED_CLI_VERSION }
            }
          },
          "opencode" => {
            manifest: "package.json",
            packages: {
              "opencode-ai" => -> { AgentHarness::Providers::Opencode::SUPPORTED_CLI_VERSION }
            }
          },
          "gemini" => {
            manifest: "package.json",
            packages: {
              "@google/gemini-cli" => -> { AgentHarness::Providers::Gemini::SUPPORTED_CLI_VERSION }
            }
          },
          "pi" => {
            manifest: "package.json",
            packages: {
              "@mariozechner/pi-coding-agent" => -> { AgentHarness::Providers::Pi::SUPPORTED_CLI_VERSION }
            }
          },
          "omp" => {
            manifest: "package.json",
            packages: {
              "@oh-my-pi/pi-coding-agent" => -> { AgentHarness::Providers::OhMyPi::SUPPORTED_CLI_VERSION },
              "bun" => -> { AgentHarness::Providers::OhMyPi::SUPPORTED_BUN_VERSION }
            }
          },
          "kilocode" => {
            manifest: "package.json",
            packages: {
              "@kilocode/cli" => -> { AgentHarness::Providers::Kilocode::DEFAULT_VERSION }
            }
          }
        }
      end

      def pip_cases
        {
          "aider" => {
            manifest: "requirements.txt",
            packages: {
              "aider-chat" => -> { AgentHarness::Providers::Aider::SUPPORTED_CLI_VERSION }
            }
          }
        }
      end
    end
  end
end
