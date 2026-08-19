# frozen_string_literal: true

require "tmpdir"
require "json"
require "digest"
require "fileutils"

require "agent_harness/providers/anthropic"
require "agent_harness/providers/aider"
require "agent_harness/providers/codex"
require "agent_harness/providers/cursor"
require "agent_harness/providers/gemini"
require "agent_harness/providers/kilocode"
require "agent_harness/providers/opencode"
require "agent_harness/providers/omp"
require "agent_harness/providers/pi"

RSpec.describe AgentHarness::CliPinRefresh do
  describe AgentHarness::CliPinRefresh::Result do
    it "stores status and details" do
      result = described_class.new(status: :changed, details: {build: "abc"})
      expect(result.status).to eq(:changed)
      expect(result.details).to eq({build: "abc"})
    end

    it "exposes predicate helpers for every status" do
      expect(described_class.new(status: :unchanged).unchanged?).to be true
      expect(described_class.new(status: :changed).changed?).to be true
      expect(described_class.new(status: :divergent).divergent?).to be true
      expect(described_class.new(status: :failed).failed?).to be true
    end

    it "round-trips through #to_h" do
      result = described_class.new(status: :divergent, details: {a: 1})
      expect(result.to_h).to eq(status: :divergent, details: {a: 1})
    end

    it "normalizes the status to a Symbol" do
      result = described_class.new(status: "changed")
      expect(result.status).to eq(:changed)
      expect(result.changed?).to be true
    end
  end

  describe AgentHarness::CliPinRefresh::HttpClient do
    def ok_response(body)
      Net::HTTPOK.new("1.1", "200", "OK").tap do |r|
        r.instance_variable_set(:@body, body)
        def r.body
          @body
        end
      end
    end

    def redirect_response(location)
      Net::HTTPFound.new("1.1", "302", "Found").tap { |r| r["Location"] = location }
    end

    def http_double(request_uri, response)
      instance_double(Net::HTTP).tap do |http|
        allow(http).to receive(:use_ssl=)
        allow(http).to receive(:open_timeout=)
        allow(http).to receive(:read_timeout=)
        allow(http).to receive(:get).with(request_uri).and_return(response)
      end
    end

    it "returns the response body on 2xx" do
      allow(Net::HTTP).to receive(:new).with("example.test", 443)
        .and_return(http_double("/path", ok_response("hello")))

      expect(described_class.new.get("https://example.test/path")).to eq("hello")
    end

    it "follows redirects to the final response body" do
      allow(Net::HTTP).to receive(:new).with("claude.ai", 443)
        .and_return(http_double("/install.sh",
          redirect_response("https://downloads.claude.ai/claude-code-releases/bootstrap.sh")))
      allow(Net::HTTP).to receive(:new).with("downloads.claude.ai", 443)
        .and_return(http_double("/claude-code-releases/bootstrap.sh", ok_response("script body")))

      expect(described_class.new.get("https://claude.ai/install.sh")).to eq("script body")
    end

    it "resolves a relative Location against the request URL" do
      allow(Net::HTTP).to receive(:new).with("example.test", 443)
        .and_return(
          http_double("/old", redirect_response("/new")),
          http_double("/new", ok_response("moved"))
        )

      expect(described_class.new.get("https://example.test/old")).to eq("moved")
    end

    it "raises FetchError when the redirect chain exceeds the hop limit" do
      allow(Net::HTTP).to receive(:new).with("example.test", 443)
        .and_return(http_double("/loop", redirect_response("https://example.test/loop")))

      expect {
        described_class.new.get("https://example.test/loop")
      }.to raise_error(
        AgentHarness::CliPinRefresh::HttpClient::FetchError,
        /exceeded #{described_class::MAX_REDIRECTS} redirects/
      )
    end

    it "raises FetchError when a redirect omits the Location header" do
      allow(Net::HTTP).to receive(:new).with("example.test", 443)
        .and_return(http_double("/old", Net::HTTPFound.new("1.1", "302", "Found")))

      expect {
        described_class.new.get("https://example.test/old")
      }.to raise_error(
        AgentHarness::CliPinRefresh::HttpClient::FetchError,
        /redirected without a Location header/
      )
    end

    it "raises FetchError when a redirect targets a non-http scheme" do
      allow(Net::HTTP).to receive(:new).with("example.test", 443)
        .and_return(http_double("/old", redirect_response("file:///etc/passwd")))

      expect {
        described_class.new.get("https://example.test/old")
      }.to raise_error(
        AgentHarness::CliPinRefresh::HttpClient::FetchError,
        /unsupported scheme/
      )
    end

    it "raises FetchError on non-success response" do
      allow(Net::HTTP).to receive(:new).with("example.test", 443)
        .and_return(http_double("/missing", Net::HTTPNotFound.new("1.1", "404", "Not Found")))

      expect {
        described_class.new.get("https://example.test/missing")
      }.to raise_error(AgentHarness::CliPinRefresh::HttpClient::FetchError, /returned 404/)
    end

    it "raises FetchError on transport error" do
      http = instance_double(Net::HTTP)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:get).and_raise(SocketError.new("nope"))
      allow(Net::HTTP).to receive(:new).and_return(http)

      expect {
        described_class.new.get("https://example.test/path")
      }.to raise_error(AgentHarness::CliPinRefresh::HttpClient::FetchError, /SocketError/)
    end
  end

  describe AgentHarness::CliPinRefresh::CursorSource do
    let(:original_content) do
      <<~RUBY
        # frozen_string_literal: true

        module AgentHarness
          module Providers
            class Cursor < Base
              INSTALL_SCRIPT_URL = "https://cursor.com/install"
              INSTALL_TARGET_LATEST = "latest"
              INSTALL_BUILD = "2026.03.30-a5d3e17"
              INSTALL_SCRIPT_SHA256 = "8371988b483abec13c07c10e95cccc839da81ebf9596e430d3c90835a227cbad"
              INSTALL_LINUX_X64_PACKAGE_SHA256 = "e0d4b611db111d2dbe76474386271bff3e1dbb2cc6ddf527f9d5d5801b2ce2a0"
            end
          end
        end
      RUBY
    end

    around do |example|
      Dir.mktmpdir do |dir|
        @path = File.join(dir, "cursor.rb")
        File.write(@path, original_content)
        example.run
      end
    end

    let(:source) { described_class.new(file_path: @path) }

    it "extracts both constants" do
      expect(source.constants).to eq(
        build: "2026.03.30-a5d3e17",
        linux_x64_package_sha256: "e0d4b611db111d2dbe76474386271bff3e1dbb2cc6ddf527f9d5d5801b2ce2a0"
      )
    end

    it "exposes the current build and sha256" do
      expect(source.current_build).to eq("2026.03.30-a5d3e17")
      expect(source.current_sha256).to eq("e0d4b611db111d2dbe76474386271bff3e1dbb2cc6ddf527f9d5d5801b2ce2a0")
    end

    it "renders an updated file with new constants substituted" do
      rendered = source.render(build: "2027.01.01-abcdef0", sha256: "ffff")
      expect(rendered).to include('INSTALL_BUILD = "2027.01.01-abcdef0"')
      expect(rendered).to include('INSTALL_LINUX_X64_PACKAGE_SHA256 = "ffff"')
    end

    it "leaves the script checksum untouched when rendering" do
      rendered = source.render(build: "2027.01.01-abcdef0", sha256: "ffff")
      expect(rendered).to include('INSTALL_SCRIPT_SHA256 = "8371988b483abec13c07c10e95cccc839da81ebf9596e430d3c90835a227cbad"')
    end

    it "raises ParseError when constants cannot be found" do
      File.write(@path, "# no constants here")
      expect {
        described_class.new(file_path: @path).constants
      }.to raise_error(described_class::ParseError, /Could not parse Cursor pin constants/)
    end
  end

  describe AgentHarness::CliPinRefresh::GithubCursorReleases do
    let(:http_client) { instance_double(AgentHarness::CliPinRefresh::HttpClient) }
    let(:release_body) do
      {
        "html_url" => "https://github.com/cursor/agent/releases/tag/v2027.01.01",
        "assets" => [
          {"name" => "cursor-agent-darwin-arm64-2027.01.01-abcdef0.tar.gz",
           "browser_download_url" => "https://example.test/darwin.tgz"},
          {"name" => "cursor-agent-linux-x64-2027.01.01-abcdef0.tar.gz",
           "browser_download_url" => "https://example.test/linux.tgz"}
        ]
      }.to_json
    end

    before do
      allow(http_client).to receive(:get).and_return(release_body)
    end

    it "queries the configured repository's latest release" do
      releases = described_class.new(
        http_client: http_client,
        repository: "cursor/agent"
      )
      releases.latest_linux_x64_build
      expect(http_client).to have_received(:get)
        .with("https://api.github.com/repos/cursor/agent/releases/latest")
    end

    it "extracts the linux/x64 build from the matching asset" do
      releases = described_class.new(http_client: http_client)
      expect(releases.latest_linux_x64_build).to eq("2027.01.01-abcdef0")
    end

    it "returns nil when no linux/x64 asset is present" do
      release_body_no_linux = {
        "html_url" => "https://github.com/cursor/agent/releases/tag/v2027.01.01",
        "assets" => [
          {"name" => "cursor-agent-darwin-arm64-2027.01.01-abcdef0.tar.gz"}
        ]
      }.to_json
      allow(http_client).to receive(:get).and_return(release_body_no_linux)
      releases = described_class.new(http_client: http_client)
      expect(releases.latest_linux_x64_build).to be_nil
    end

    it "returns nil when the asset name has no recognizable build" do
      release_body_no_build = {
        "html_url" => "https://github.com/cursor/agent/releases/tag/v2027.01.01",
        "assets" => [
          {"name" => "cursor-agent-linux-x64.tar.gz"}
        ]
      }.to_json
      allow(http_client).to receive(:get).and_return(release_body_no_build)
      releases = described_class.new(http_client: http_client)
      expect(releases.latest_linux_x64_build).to be_nil
    end

    it "exposes the release notes URL" do
      releases = described_class.new(http_client: http_client)
      expect(releases.latest_release_url).to eq("https://github.com/cursor/agent/releases/tag/v2027.01.01")
    end

    it "returns nil for release_url when the API call fails" do
      allow(http_client).to receive(:get)
        .and_raise(AgentHarness::CliPinRefresh::HttpClient::FetchError, "boom")
      releases = described_class.new(http_client: http_client)
      expect(releases.latest_release_url).to be_nil
    end
  end

  describe AgentHarness::CliPinRefresh::ArtifactDownloader do
    it "returns the SHA256 of the response body" do
      http_client = instance_double(AgentHarness::CliPinRefresh::HttpClient)
      allow(http_client).to receive(:get).with("https://example.test/artifact").and_return("hello")

      sha = described_class.new(http_client: http_client).sha256("https://example.test/artifact")
      expect(sha).to eq(Digest::SHA256.hexdigest("hello"))
    end
  end

  describe AgentHarness::CliPinRefresh::CursorArtifactUrl do
    it "builds the canonical downloads.cursor.com URL" do
      url = described_class.call(build: "2026.03.30-a5d3e17")
      expect(url).to eq(
        "https://downloads.cursor.com/lab/2026.03.30-a5d3e17/linux/x64/agent-cli-package.tar.gz"
      )
    end

    it "accepts os/arch overrides for future targets" do
      url = described_class.call(build: "abc", os: "darwin", arch: "arm64")
      expect(url).to eq("https://downloads.cursor.com/lab/abc/darwin/arm64/agent-cli-package.tar.gz")
    end
  end

  describe AgentHarness::CliPinRefresh::CursorRefresh do
    let(:cursor_rb_path) { File.join(__dir__, "..", "..", "lib", "agent_harness", "providers", "cursor.rb") }
    let(:source) { AgentHarness::CliPinRefresh::CursorSource.new(file_path: cursor_rb_path) }
    let(:releases) { instance_double(AgentHarness::CliPinRefresh::GithubCursorReleases) }
    let(:downloader) { instance_double(AgentHarness::CliPinRefresh::ArtifactDownloader) }

    subject(:refresh) do
      described_class.new(releases: releases, downloader: downloader, source: source)
    end

    it "returns :unchanged when upstream matches the current pin" do
      current_build = source.current_build
      current_sha = source.current_sha256
      allow(releases).to receive(:latest_linux_x64_build).and_return(current_build)
      allow(releases).to receive(:latest_release_url).and_return("https://example.test/release")
      artifact_url = AgentHarness::CliPinRefresh::CursorArtifactUrl.call(build: current_build)
      allow(downloader).to receive(:sha256).with(artifact_url).and_return(current_sha)

      result = refresh.call
      expect(result.unchanged?).to be true
      expect(result.details).to eq(build: current_build, sha256: current_sha)
    end

    it "returns :changed when the build moves" do
      new_build = "2027.04.01-fedcba9"
      allow(releases).to receive(:latest_linux_x64_build).and_return(new_build)
      allow(releases).to receive(:latest_release_url).and_return("https://example.test/release")
      new_sha = "deadbeef"
      artifact_url = AgentHarness::CliPinRefresh::CursorArtifactUrl.call(build: new_build)
      allow(downloader).to receive(:sha256).with(artifact_url).and_return(new_sha)

      result = refresh.call
      expect(result.changed?).to be true
      expect(result.details[:build]).to eq(new_build)
      expect(result.details[:sha256]).to eq(new_sha)
      expect(result.details[:previous_build]).to eq(source.current_build)
      expect(result.details[:previous_sha256]).to eq(source.current_sha256)
    end

    it "returns :failed when no linux/x64 asset is attached" do
      allow(releases).to receive(:latest_linux_x64_build).and_return(nil)
      result = refresh.call
      expect(result.failed?).to be true
      expect(result.details[:reason]).to match(/no linux\/x64 asset/)
    end

    it "returns :failed when an upstream HTTP request errors out" do
      allow(releases).to receive(:latest_linux_x64_build)
        .and_raise(AgentHarness::CliPinRefresh::HttpClient::FetchError, "503")
      result = refresh.call
      expect(result.failed?).to be true
      expect(result.details[:reason]).to eq("503")
    end
  end

  describe AgentHarness::CliPinRefresh::ClaudeInstallerProbe do
    let(:http_client) { instance_double(AgentHarness::CliPinRefresh::HttpClient) }
    let(:bootstrap_script) do
      <<~SH
        #!/usr/bin/env bash
        DOWNLOAD_BASE_URL="https://downloads.claude.ai/claude-code-releases"
        version=$(download_file "$DOWNLOAD_BASE_URL/latest")
      SH
    end

    subject(:probe) do
      described_class.new(
        http_client: http_client,
        install_script_url: "https://claude.ai/install.sh"
      )
    end

    it "asks the installer's own version endpoint what install.sh would install" do
      allow(http_client).to receive(:get).with("https://claude.ai/install.sh").and_return(bootstrap_script)
      allow(http_client).to receive(:get)
        .with("https://downloads.claude.ai/claude-code-releases/latest")
        .and_return("2.1.235\n")

      expect(probe.resolved_version).to eq("2.1.235")
    end

    it "strips an optional v prefix from the endpoint response" do
      allow(http_client).to receive(:get).with("https://claude.ai/install.sh").and_return(bootstrap_script)
      allow(http_client).to receive(:get)
        .with("https://downloads.claude.ai/claude-code-releases/latest")
        .and_return("v2.1.235")

      expect(probe.resolved_version).to eq("2.1.235")
    end

    it "handles a trailing slash in the script's download base URL" do
      allow(http_client).to receive(:get).with("https://claude.ai/install.sh")
        .and_return('DOWNLOAD_BASE_URL="https://downloads.example.test/releases/"')
      allow(http_client).to receive(:get).with("https://downloads.example.test/releases/latest")
        .and_return("2.1.235")

      expect(probe.resolved_version).to eq("2.1.235")
    end

    it "returns nil when the script declares no download base URL" do
      allow(http_client).to receive(:get).with("https://claude.ai/install.sh")
        .and_return("#!/usr/bin/env bash\necho hi\n")

      expect(probe.resolved_version).to be_nil
    end

    it "returns nil when the version endpoint answers with a non-version body" do
      allow(http_client).to receive(:get).with("https://claude.ai/install.sh").and_return(bootstrap_script)
      allow(http_client).to receive(:get)
        .with("https://downloads.claude.ai/claude-code-releases/latest")
        .and_return("<html>Service Unavailable</html>")

      expect(probe.resolved_version).to be_nil
    end

    it "returns nil on HTTP failure fetching the script" do
      allow(http_client).to receive(:get).with("https://claude.ai/install.sh")
        .and_raise(AgentHarness::CliPinRefresh::HttpClient::FetchError, "boom")

      expect(probe.resolved_version).to be_nil
    end

    it "returns nil on HTTP failure fetching the version endpoint" do
      allow(http_client).to receive(:get).with("https://claude.ai/install.sh").and_return(bootstrap_script)
      allow(http_client).to receive(:get)
        .with("https://downloads.claude.ai/claude-code-releases/latest")
        .and_raise(AgentHarness::CliPinRefresh::HttpClient::FetchError, "boom")

      expect(probe.resolved_version).to be_nil
    end
  end

  describe AgentHarness::CliPinRefresh::NpmRegistry do
    let(:http_client) { instance_double(AgentHarness::CliPinRefresh::HttpClient) }

    it "returns the latest version field from the registry payload" do
      payload = {"version" => "2.1.92", "name" => "@anthropic-ai/claude-code"}.to_json
      encoded_package = URI.encode_www_form_component("@anthropic-ai/claude-code")
      allow(http_client).to receive(:get)
        .with("https://registry.npmjs.org/#{encoded_package}/latest")
        .and_return(payload)

      registry = described_class.new(http_client: http_client)
      expect(registry.latest_version("@anthropic-ai/claude-code")).to eq("2.1.92")
    end

    it "returns nil on HTTP failure" do
      allow(http_client).to receive(:get)
        .and_raise(AgentHarness::CliPinRefresh::HttpClient::FetchError, "boom")
      registry = described_class.new(http_client: http_client)
      expect(registry.latest_version("@anthropic-ai/claude-code")).to be_nil
    end

    it "accepts a registry URL override (private mirror testing)" do
      payload = {"version" => "2.1.92"}.to_json
      encoded_package = URI.encode_www_form_component("@anthropic-ai/claude-code")
      allow(http_client).to receive(:get)
        .with("https://npm.example.test/#{encoded_package}/latest")
        .and_return(payload)

      registry = described_class.new(http_client: http_client, registry_url: "https://npm.example.test")
      expect(registry.latest_version("@anthropic-ai/claude-code")).to eq("2.1.92")
    end
  end

  describe AgentHarness::CliPinRefresh::ClaudeOracleCheck do
    let(:installer_probe) { instance_double(AgentHarness::CliPinRefresh::ClaudeInstallerProbe) }
    let(:npm_registry) { instance_double(AgentHarness::CliPinRefresh::NpmRegistry) }

    subject(:check) do
      described_class.new(
        installer_probe: installer_probe,
        npm_registry: npm_registry,
        pinned_version: "2.1.92"
      )
    end

    it "is :unchanged when installer and npm agree" do
      allow(installer_probe).to receive(:resolved_version).and_return("2.1.92")
      allow(npm_registry).to receive(:latest_version).with("@anthropic-ai/claude-code").and_return("2.1.92")

      result = check.call
      expect(result.unchanged?).to be true
      expect(result.details).to eq(
        pinned_version: "2.1.92",
        installer_version: "2.1.92",
        npm_version: "2.1.92"
      )
    end

    it "is :divergent when installer and npm disagree" do
      allow(installer_probe).to receive(:resolved_version).and_return("2.1.93")
      allow(npm_registry).to receive(:latest_version).and_return("2.1.92")

      result = check.call
      expect(result.divergent?).to be true
      expect(result.details[:installer_version]).to eq("2.1.93")
      expect(result.details[:npm_version]).to eq("2.1.92")
    end

    it "is :failed when the installer probe returns nil" do
      allow(installer_probe).to receive(:resolved_version).and_return(nil)
      allow(npm_registry).to receive(:latest_version).and_return("2.1.92")

      result = check.call
      expect(result.failed?).to be true
    end

    it "is :failed when the npm registry returns nil" do
      allow(installer_probe).to receive(:resolved_version).and_return("2.1.92")
      allow(npm_registry).to receive(:latest_version).and_return(nil)

      result = check.call
      expect(result.failed?).to be true
    end

    it "accepts an explicit npm package name override" do
      allow(installer_probe).to receive(:resolved_version).and_return("2.1.92")
      expect(npm_registry).to receive(:latest_version).with("@example/mirror").and_return("2.1.92")

      described_class.new(
        installer_probe: installer_probe,
        npm_registry: npm_registry,
        pinned_version: "2.1.92",
        package_name: "@example/mirror"
      ).call
    end
  end

  describe AgentHarness::CliPinRefresh::ParitySweep do
    let(:tmp_pins_dir) { Dir.mktmpdir("parity-spec-") }
    let(:sweep) { described_class.new(pins_dir: tmp_pins_dir, repo_root: tmp_pins_dir) }

    after { FileUtils.remove_entry(tmp_pins_dir) }

    def write_npm_manifest(provider, packages)
      dir = File.join(tmp_pins_dir, provider)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "package.json"), JSON.dump(
        "name" => "agent-harness-pin-#{provider}",
        "version" => "0.0.0",
        "private" => true,
        "devDependencies" => packages
      ))
    end

    def write_pip_manifest(provider, package, version)
      dir = File.join(tmp_pins_dir, provider)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "requirements.txt"), "#{package}==#{version}\n")
    end

    it "returns :unchanged when every constant agrees with its manifest" do
      write_npm_manifest("claude", {"@anthropic-ai/claude-code" =>
        AgentHarness::Providers::Anthropic::SUPPORTED_CLI_VERSION})
      write_npm_manifest("codex", {"@openai/codex" =>
        AgentHarness::Providers::Codex::SUPPORTED_CLI_VERSION})
      write_npm_manifest("opencode", {"opencode-ai" =>
        AgentHarness::Providers::Opencode::SUPPORTED_CLI_VERSION})
      write_npm_manifest("gemini", {"@google/gemini-cli" =>
        AgentHarness::Providers::Gemini::SUPPORTED_CLI_VERSION})
      write_npm_manifest("pi", {"@mariozechner/pi-coding-agent" =>
        AgentHarness::Providers::Pi::SUPPORTED_CLI_VERSION})
      write_npm_manifest("omp", {
        "@oh-my-pi/pi-coding-agent" => AgentHarness::Providers::OhMyPi::SUPPORTED_CLI_VERSION,
        "bun" => AgentHarness::Providers::OhMyPi::SUPPORTED_BUN_VERSION
      })
      write_npm_manifest("kilocode", {"@kilocode/cli" =>
        AgentHarness::Providers::Kilocode::DEFAULT_VERSION})
      write_pip_manifest("aider", "aider-chat",
        AgentHarness::Providers::Aider::SUPPORTED_CLI_VERSION)

      expect(sweep.call.unchanged?).to be true
    end

    it "reports omp's bun pin when it drifts from SUPPORTED_BUN_VERSION" do
      write_npm_manifest("omp", {
        "@oh-my-pi/pi-coding-agent" => AgentHarness::Providers::OhMyPi::SUPPORTED_CLI_VERSION,
        "bun" => "9.9.9" # stale
      })

      result = sweep.call
      expect(result.divergent?).to be true
      offender = result.details[:offenders].first
      expect(offender[:ecosystem]).to eq("npm")
      expect(offender[:provider]).to eq("omp")
      expect(offender[:package]).to eq("bun")
      expect(offender[:manifest_value]).to eq("9.9.9")
      expect(offender[:constant_value]).to eq(AgentHarness::Providers::OhMyPi::SUPPORTED_BUN_VERSION)
    end

    it "returns :divergent and reports the offending npm provider" do
      write_npm_manifest("claude", {"@anthropic-ai/claude-code" =>
        AgentHarness::Providers::Anthropic::SUPPORTED_CLI_VERSION})
      write_npm_manifest("codex", {"@openai/codex" => "9.9.9"}) # stale

      result = sweep.call
      expect(result.divergent?).to be true
      offender = result.details[:offenders].first
      expect(offender[:ecosystem]).to eq("npm")
      expect(offender[:provider]).to eq("codex")
      expect(offender[:package]).to eq("@openai/codex")
      expect(offender[:manifest_value]).to eq("9.9.9")
      expect(offender[:constant_value]).to eq(AgentHarness::Providers::Codex::SUPPORTED_CLI_VERSION)
    end

    it "returns :divergent and reports the offending pip provider" do
      write_pip_manifest("aider", "aider-chat", "9.9.9") # stale

      result = sweep.call
      expect(result.divergent?).to be true
      offender = result.details[:offenders].first
      expect(offender[:ecosystem]).to eq("pip")
      expect(offender[:provider]).to eq("aider")
      expect(offender[:package]).to eq("aider-chat")
      expect(offender[:manifest_value]).to eq("9.9.9")
      expect(offender[:constant_value]).to eq(AgentHarness::Providers::Aider::SUPPORTED_CLI_VERSION)
    end

    it "skips providers whose manifest is missing (defensive)" do
      # No manifests at all
      expect(sweep.call.unchanged?).to be true
    end
  end
end
