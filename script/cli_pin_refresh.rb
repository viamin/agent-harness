# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "uri"

require_relative "sync-cli-pins"

module AgentHarness
  # Scheduled refresh for CLI artifact pins Dependabot cannot see.
  #
  # The gem's `Providers::Cursor` install contract pins an artifact URL + SHA256
  # (plus a checksum for `cursor.com/install`) that no npm/PyPI manifest tracks.
  # The Claude install oracle (npm `@anthropic-ai/claude-code`) and the
  # `claude.ai/install.sh` curl installer historically publish lockstep, but
  # that is an assumption, not a contract.
  #
  # This module implements the step-3 scheduled job from issue #338: a weekly
  # cron that (a) refreshes the Cursor pins from the build id embedded in
  # Cursor's upstream install script, (b) verifies Claude oracle parity, and
  # (c) runs an advisory parity sweep across every pinned CLI version.
  #
  # The code lives under `script/` (like `sync-cli-pins.rb`) rather than
  # `lib/agent_harness/` because it exists solely to drive this repository's
  # scheduled workflow: it edits `lib/agent_harness/providers/cursor.rb`,
  # scans `vendor/pins/`, and is consumed by `refresh-artifact-pins.rb`. The
  # gemspec excludes `script/`, so none of this ships to gem consumers.
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
      # Matches every pin constant regardless of value or surrounding
      # whitespace. cursor.rb pins three Dependabot-invisible values -
      # build id, install-script checksum, and artifact checksum - and
      # the refresh must cover all of them (the script URL is read too
      # so the checksum probe follows whatever host the provider
      # declares).
      CONSTANT_PATTERN = /
        \b(?<name>INSTALL_(?:BUILD|SCRIPT_URL|SCRIPT_SHA256|LINUX_X64_PACKAGE_SHA256))\s*=\s*
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

      # @return [String] the value of `INSTALL_SCRIPT_SHA256`
      def current_script_sha256
        constants.fetch(:script_sha256)
      end

      # @return [String] the value of `INSTALL_LINUX_X64_PACKAGE_SHA256`
      def current_sha256
        constants.fetch(:linux_x64_package_sha256)
      end

      # @return [String] the value of `INSTALL_SCRIPT_URL`
      def current_script_url
        constants.fetch(:script_url)
      end

      # @return [Hash{Symbol=>String}] parsed constants, e.g.
      #   `{build: "2026.03.30-a5d3e17", script_sha256: "8371...", linux_x64_package_sha256: "e0d4..."}`
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
      # @param script_sha256 [String] new `INSTALL_SCRIPT_SHA256`
      # @return [String] updated file content
      def render(build:, sha256:, script_sha256:)
        content = File.read(file_path)
        content.sub(/(\bINSTALL_BUILD\s*=\s*)"[^"]+"/, "\\1\"#{build}\"")
          .sub(/(\bINSTALL_SCRIPT_SHA256\s*=\s*)"[^"]+"/, "\\1\"#{script_sha256}\"")
          .sub(/(\bINSTALL_LINUX_X64_PACKAGE_SHA256\s*=\s*)"[^"]+"/, "\\1\"#{sha256}\"")
      end

      # Raised when the Cursor source file cannot be parsed.
      class ParseError < StandardError; end

      private

      def constant_key(name)
        case name
        when "INSTALL_BUILD" then :build
        when "INSTALL_SCRIPT_SHA256" then :script_sha256
        when "INSTALL_SCRIPT_URL" then :script_url
        when "INSTALL_LINUX_X64_PACKAGE_SHA256" then :linux_x64_package_sha256
        else name.downcase.to_sym
        end
      end
    end

    # Resolves the latest Cursor agent build from the upstream install
    # script. Cursor ships agent builds from `downloads.cursor.com` with
    # no GitHub releases API (there is no public cursor/agent
    # repository); the install script itself embeds the canonical
    # download URL carrying the current build id, so the script is the
    # authoritative release channel - the same contract
    # `ClaudeInstallerProbe` applies to `claude.ai/install.sh`.
    class CursorInstallerProbe
      # The script embeds the artifact URL directly, e.g.
      #   DOWNLOAD_URL="https://downloads.cursor.com/lab/2027.01.01-abcdef0/${OS}/${ARCH}/agent-cli-package.tar.gz"
      # Anchoring on the canonical download host keeps unrelated
      # date-hash strings in the script (temp dir names) from matching.
      BUILD_PATTERN = %r{https://downloads\.cursor\.com/lab/(?<build>\d{4}\.\d{2}\.\d{2}-[a-f0-9]+)}

      attr_reader :install_script_url

      def initialize(http_client:, install_script_url:)
        @http_client = http_client
        @install_script_url = install_script_url
      end

      # @return [String, nil] latest build id, or nil when the fetched
      #   script does not embed a recognizable download URL
      # @raise [HttpClient::FetchError] when the script cannot be fetched
      def latest_build
        match = script_body.match(BUILD_PATTERN)
        match && match[:build]
      end

      # @return [String] SHA256 of the fetched install script, taken
      #   from the same body as #latest_build so the build id and the
      #   script checksum always describe one consistent upstream
      #   snapshot (Cursor can re-ship the script without a new build).
      # @raise [HttpClient::FetchError] when the script cannot be fetched
      def script_sha256
        Digest::SHA256.hexdigest(script_body)
      end

      private

      # Memoized so the build id and the script checksum share a single
      # network round trip; the body is immutable for the lifetime of
      # this instance.
      def script_body
        @script_body ||= @http_client.get(@install_script_url)
      end
    end

    # Downloads an artifact from a URL and computes its SHA256. Used after
    # `CursorInstallerProbe#latest_build` to confirm the artifact the
    # build's canonical cursor.com download path serves matches the
    # checksum we pin.
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

    # Decides whether the Cursor pins need to be refreshed. Returns a
    # `Result` with `:status` (`:unchanged` or `:changed`) plus the upstream
    # facts the runner needs to build a PR. All three Dependabot-invisible
    # pins are refreshed together: the build id, the artifact SHA256, and
    # the `cursor.com/install` script SHA256 that `install_metadata`'s
    # checksum targets consume - otherwise the script checksum would
    # silently rot as Cursor updates its installer.
    class CursorRefresh
      def initialize(build_source:, downloader:, source:, artifact_url_builder: CursorArtifactUrl)
        @build_source = build_source
        @downloader = downloader
        @source = source
        @artifact_url_builder = artifact_url_builder
      end

      def call
        build = @build_source.latest_build
        if build.nil?
          return Result.new(
            status: :failed,
            details: {reason: "install script at #{@build_source.install_script_url} did not advertise a build id"}
          )
        end

        current_build = @source.current_build
        current_sha256 = @source.current_sha256
        current_script_sha256 = @source.current_script_sha256
        artifact_url = @artifact_url_builder.call(build: build)
        upstream_sha256 = @downloader.sha256(artifact_url)
        upstream_script_sha256 = @build_source.script_sha256

        if build == current_build && upstream_sha256 == current_sha256 &&
            upstream_script_sha256 == current_script_sha256
          return Result.new(
            status: :unchanged,
            details: {build: build, sha256: upstream_sha256, script_sha256: upstream_script_sha256}
          )
        end

        Result.new(
          status: :changed,
          details: {
            build: build,
            sha256: upstream_sha256,
            script_sha256: upstream_script_sha256,
            artifact_url: artifact_url,
            install_script_url: @build_source.install_script_url,
            previous_build: current_build,
            previous_sha256: current_sha256,
            previous_script_sha256: current_script_sha256
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
      rescue HttpClient::FetchError, JSON::ParserError
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

    # Advisory parity sweep across every pinned CLI version constant vs
    # the manifest it should mirror. Mirrors the CI parity spec
    # (`spec/vendor_pins_parity_spec.rb`) so a hand-edited constant
    # drifts visibly inside one cron window instead of waiting for the
    # next Dependabot bump.
    #
    # The inventory is derived from `CliPinSync::PINS`
    # (script/sync-cli-pins.rb) so the sweep, the step-2 sync script,
    # and the parity spec cannot drift apart when a provider or pin is
    # added - the `CliPinSync::PINS inventory` spec fails until PINS
    # covers every package the manifests pin. Provider constants are
    # parsed out of the source text (the same trick sync-cli-pins.rb
    # uses) so the sweep never loads or evaluates repo Ruby.
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
        offenders = CliPinSync::PINS.filter_map { |pin| offender_for(pin) }
        return Result.new(status: :unchanged, details: {}) if offenders.empty?

        Result.new(status: :divergent, details: {offenders: offenders})
      end

      private

      # @return [Hash, nil] offender entry, or nil when the pin is in
      #   sync (or its manifest does not exist yet - defensive, the same
      #   skip the previous hand-maintained version had).
      def offender_for(pin)
        manifest_path = File.join(pins_dir, pin.provider_dir, pin.manifest)
        return nil unless File.exist?(manifest_path)

        pinned = manifest_pinned_version(pin, manifest_path)
        expected = constant_version(pin)
        return nil if pinned == expected

        {
          ecosystem: pip_manifest?(pin) ? "pip" : "npm",
          provider: pin.provider_dir,
          package: pin.package,
          manifest_value: pinned,
          constant_value: expected,
          manifest_path: manifest_path
        }
      end

      def manifest_pinned_version(pin, manifest_path)
        if pip_manifest?(pin)
          pip_pinned_version(manifest_path, pin.package)
        else
          npm_pinned_version(manifest_path, pin.package)
        end
      end

      def npm_pinned_version(manifest_path, package)
        JSON.parse(File.read(manifest_path, encoding: "UTF-8")).fetch("devDependencies", {})[package]
      rescue Errno::ENOENT, JSON::ParserError
        nil
      end

      def pip_pinned_version(manifest_path, package)
        File.readlines(manifest_path, chomp: true, encoding: "UTF-8").each do |line|
          stripped = line.strip
          next if stripped.empty? || stripped.start_with?("#")

          name, version = stripped.split("==", 2)
          return version&.strip if name&.strip == package
        end
        nil
      rescue Errno::ENOENT
        nil
      end

      # Parses the constant assignment from the provider source without
      # loading it. nil means the file no longer matches the pinned
      # shape, which is itself drift the advisory issue should surface.
      def constant_version(pin)
        source = File.read(File.join(repo_root, pin.provider_file), encoding: "UTF-8")
        match = source.match(/^\s*#{Regexp.escape(pin.constant)}\s*=\s*"(?<version>[^"]+)"/)
        match && match[:version]
      rescue Errno::ENOENT
        nil
      end

      def pip_manifest?(pin)
        pin.manifest == "requirements.txt"
      end
    end
  end
end
