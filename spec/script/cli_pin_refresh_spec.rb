# frozen_string_literal: true

require "tmpdir"
require "json"
require "digest"
require "fileutils"

require_relative "../../script/cli_pin_refresh"

# In-sync fixture versions for the ParitySweep examples, keyed
# "<provider_dir>/<package>" the same way spec/sync_cli_pins_spec.rb keys
# its FIXTURE_PINS.
SWEEP_FIXTURE_VERSIONS = {
  "claude/@anthropic-ai/claude-code" => "2.1.92",
  "codex/@openai/codex" => "0.122.0",
  "opencode/opencode-ai" => "1.18.9",
  "gemini/@google/gemini-cli" => "0.35.3",
  "pi/@mariozechner/pi-coding-agent" => "0.73.0",
  "omp/@oh-my-pi/pi-coding-agent" => "17.0.1",
  "omp/bun" => "1.3.14",
  "kilocode/@kilocode/cli" => "7.4.16",
  "aider/aider-chat" => "0.86.2"
}.freeze

# Behavior of script/cli_pin_refresh.rb - the library half of the step-3
# scheduled refresh (see issue #338). The file lives under script/ (like
# sync-cli-pins.rb) so the gemspec never ships this repository's CI
# automation to gem consumers; script/refresh-artifact-pins.rb holds the
# gh/git dispatch half.
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
        /exceeded #{described_class::MAX_REDIRECTS} redirects/o
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

    it "extracts every pin constant" do
      expect(source.constants).to eq(
        script_url: "https://cursor.com/install",
        build: "2026.03.30-a5d3e17",
        script_sha256: "8371988b483abec13c07c10e95cccc839da81ebf9596e430d3c90835a227cbad",
        linux_x64_package_sha256: "e0d4b611db111d2dbe76474386271bff3e1dbb2cc6ddf527f9d5d5801b2ce2a0"
      )
    end

    it "exposes the current build and checksums" do
      expect(source.current_build).to eq("2026.03.30-a5d3e17")
      expect(source.current_sha256).to eq("e0d4b611db111d2dbe76474386271bff3e1dbb2cc6ddf527f9d5d5801b2ce2a0")
      expect(source.current_script_sha256)
        .to eq("8371988b483abec13c07c10e95cccc839da81ebf9596e430d3c90835a227cbad")
      expect(source.current_script_url).to eq("https://cursor.com/install")
    end

    it "renders an updated file with all three pins substituted" do
      rendered = source.render(
        build: "2027.01.01-abcdef0",
        sha256: "ffff",
        script_sha256: "eeee"
      )
      expect(rendered).to include('INSTALL_BUILD = "2027.01.01-abcdef0"')
      expect(rendered).to include('INSTALL_SCRIPT_SHA256 = "eeee"')
      expect(rendered).to include('INSTALL_LINUX_X64_PACKAGE_SHA256 = "ffff"')
      expect(rendered).to include('INSTALL_SCRIPT_URL = "https://cursor.com/install"')
    end

    it "raises ParseError when constants cannot be found" do
      File.write(@path, "# no constants here")
      expect {
        described_class.new(file_path: @path).constants
      }.to raise_error(described_class::ParseError, /Could not parse Cursor pin constants/)
    end
  end

  describe AgentHarness::CliPinRefresh::CursorInstallerProbe do
    let(:http_client) { instance_double(AgentHarness::CliPinRefresh::HttpClient) }
    # Mirrors the real upstream script: the temp-dir line carries a
    # date-hash string that is NOT a download URL, so the fixture also
    # proves the parser anchors on downloads.cursor.com instead of
    # matching the first date-hash-looking substring.
    let(:install_script) do
      <<~SH
        #!/usr/bin/env bash
        TEMP_EXTRACT_DIR="$HOME/.local/share/cursor-agent/versions/.tmp-2027.01.01-abcdef0-$(date +%s)"
        DOWNLOAD_URL="https://downloads.cursor.com/lab/2027.01.01-abcdef0/${OS}/${ARCH}/agent-cli-package.tar.gz"
        curl -fSL --progress-bar "${DOWNLOAD_URL}"
      SH
    end

    subject(:probe) do
      described_class.new(
        http_client: http_client,
        install_script_url: "https://cursor.com/install"
      )
    end

    before do
      allow(http_client).to receive(:get).with("https://cursor.com/install").and_return(install_script)
    end

    it "extracts the build embedded in the canonical download URL" do
      expect(probe.latest_build).to eq("2027.01.01-abcdef0")
    end

    it "checksums the same script body the build was parsed from" do
      expect(probe.script_sha256).to eq(Digest::SHA256.hexdigest(install_script))
    end

    it "shares one HTTP fetch between the build and the script checksum" do
      probe.latest_build
      probe.script_sha256

      expect(http_client).to have_received(:get).once
    end

    it "returns nil when the script embeds no recognizable download URL" do
      allow(http_client).to receive(:get).and_return("#!/usr/bin/env bash\necho hi\n")

      expect(probe.latest_build).to be_nil
    end

    it "propagates fetch failures so the caller can fail the step" do
      allow(http_client).to receive(:get)
        .and_raise(AgentHarness::CliPinRefresh::HttpClient::FetchError, "boom")

      expect { probe.latest_build }.to raise_error(
        AgentHarness::CliPinRefresh::HttpClient::FetchError, /boom/
      )
      expect { probe.script_sha256 }.to raise_error(
        AgentHarness::CliPinRefresh::HttpClient::FetchError, /boom/
      )
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
    let(:build_source) { instance_double(AgentHarness::CliPinRefresh::CursorInstallerProbe) }
    let(:downloader) { instance_double(AgentHarness::CliPinRefresh::ArtifactDownloader) }

    subject(:refresh) do
      described_class.new(build_source: build_source, downloader: downloader, source: source)
    end

    def stub_upstream(build:, artifact_sha256:, script_sha256:)
      allow(build_source).to receive(:install_script_url).and_return(source.current_script_url)
      allow(build_source).to receive(:latest_build).and_return(build)
      allow(build_source).to receive(:script_sha256).and_return(script_sha256)
      artifact_url = AgentHarness::CliPinRefresh::CursorArtifactUrl.call(build: build)
      allow(downloader).to receive(:sha256).with(artifact_url).and_return(artifact_sha256)
    end

    it "returns :unchanged when upstream matches the current pin" do
      stub_upstream(
        build: source.current_build,
        artifact_sha256: source.current_sha256,
        script_sha256: source.current_script_sha256
      )

      result = refresh.call
      expect(result.unchanged?).to be true
      expect(result.details).to eq(
        build: source.current_build,
        sha256: source.current_sha256,
        script_sha256: source.current_script_sha256
      )
    end

    it "returns :changed when the build moves" do
      new_build = "2027.04.01-fedcba9"
      stub_upstream(build: new_build, artifact_sha256: "deadbeef", script_sha256: "e" * 64)

      result = refresh.call
      expect(result.changed?).to be true
      expect(result.details[:build]).to eq(new_build)
      expect(result.details[:sha256]).to eq("deadbeef")
      expect(result.details[:script_sha256]).to eq("e" * 64)
      expect(result.details[:install_script_url]).to eq(source.current_script_url)
      expect(result.details[:previous_build]).to eq(source.current_build)
      expect(result.details[:previous_sha256]).to eq(source.current_sha256)
      expect(result.details[:previous_script_sha256]).to eq(source.current_script_sha256)
    end

    it "returns :changed when only the install script checksum moves" do
      # Cursor can re-ship cursor.com/install without a new agent build;
      # the script checksum is one of the Dependabot-invisible pins this
      # job exists to refresh, so it must drift visibly on its own.
      stub_upstream(
        build: source.current_build,
        artifact_sha256: source.current_sha256,
        script_sha256: "f" * 64
      )

      result = refresh.call
      expect(result.changed?).to be true
      expect(result.details[:build]).to eq(source.current_build)
      expect(result.details[:previous_script_sha256]).to eq(source.current_script_sha256)
      expect(result.details[:script_sha256]).to eq("f" * 64)
    end

    it "returns :failed when the install script advertises no build" do
      allow(build_source).to receive(:install_script_url).and_return("https://cursor.com/install")
      allow(build_source).to receive(:latest_build).and_return(nil)
      result = refresh.call
      expect(result.failed?).to be true
      expect(result.details[:reason]).to match(/did not advertise a build id/)
    end

    it "returns :failed when the install script cannot be fetched" do
      allow(build_source).to receive(:install_script_url).and_return("https://cursor.com/install")
      allow(build_source).to receive(:latest_build)
        .and_raise(AgentHarness::CliPinRefresh::HttpClient::FetchError, "503")
      result = refresh.call
      expect(result.failed?).to be true
      expect(result.details[:reason]).to eq("503")
    end

    it "returns :failed when the artifact checksum cannot be fetched" do
      allow(build_source).to receive(:install_script_url).and_return("https://cursor.com/install")
      allow(build_source).to receive(:latest_build).and_return("2027.04.01-fedcba9")
      allow(build_source).to receive(:script_sha256).and_return("e" * 64)
      artifact_url = AgentHarness::CliPinRefresh::CursorArtifactUrl.call(build: "2027.04.01-fedcba9")
      allow(downloader).to receive(:sha256).with(artifact_url)
        .and_raise(AgentHarness::CliPinRefresh::HttpClient::FetchError, "404")

      result = refresh.call
      expect(result.failed?).to be true
      expect(result.details[:reason]).to eq("404")
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

    it "returns nil when the registry payload is malformed JSON" do
      allow(http_client).to receive(:get).and_return("not json at all")
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
    let(:tmp_root) { Dir.mktmpdir("parity-sweep-") }
    let(:pins_dir) { File.join(tmp_root, "vendor", "pins") }
    let(:sweep) { described_class.new(pins_dir: pins_dir, repo_root: tmp_root) }

    after { FileUtils.remove_entry(tmp_root) }

    def pin(key)
      CliPinSync::PINS.find { |candidate| "#{candidate.provider_dir}/#{candidate.package}" == key }
    end

    def ecosystem_for(pin)
      return "pip" if pin.manifest == "requirements.txt"

      "npm"
    end

    # Provider fixtures are flat constant assignments; the sweep parses
    # the source text instead of loading it, so no module scaffolding is
    # needed.
    def write_provider(pin, constants)
      path = File.join(tmp_root, pin.provider_file)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, constants.map { |name, version| "#{name} = \"#{version}\"\n" }.join)
    end

    def write_manifest(pin, packages)
      dir = File.join(pins_dir, pin.provider_dir)
      FileUtils.mkdir_p(dir)
      if pin.manifest == "requirements.txt"
        File.write(File.join(dir, pin.manifest), packages.map { |pkg, version| "#{pkg}==#{version}\n" }.join)
      else
        File.write(File.join(dir, pin.manifest), JSON.dump(
          "name" => "agent-harness-pin-#{pin.provider_dir}",
          "private" => true,
          "devDependencies" => packages
        ))
      end
    end

    def write_in_sync_tree
      CliPinSync::PINS.group_by(&:provider_file).each_value do |file_pins|
        write_provider(file_pins.first, file_pins.to_h { |p|
          [p.constant, SWEEP_FIXTURE_VERSIONS.fetch("#{p.provider_dir}/#{p.package}")]
        })
      end
      CliPinSync::PINS.group_by { |p| [p.provider_dir, p.manifest] }.each_value do |manifest_pins|
        write_manifest(manifest_pins.first, manifest_pins.to_h { |p|
          [p.package, SWEEP_FIXTURE_VERSIONS.fetch("#{p.provider_dir}/#{p.package}")]
        })
      end
    end

    it "returns :unchanged when every constant agrees with its manifest" do
      write_in_sync_tree

      expect(sweep.call.unchanged?).to be true
    end

    it "reports every pin in CliPinSync::PINS when all of them drift" do
      # Proves the sweep's coverage is derived from CliPinSync::PINS: a
      # newly added pin cannot be silently forgotten.
      CliPinSync::PINS.group_by(&:provider_file).each_value do |file_pins|
        write_provider(file_pins.first, file_pins.to_h { |p|
          [p.constant, SWEEP_FIXTURE_VERSIONS.fetch("#{p.provider_dir}/#{p.package}")]
        })
      end
      CliPinSync::PINS.group_by { |p| [p.provider_dir, p.manifest] }.each_value do |manifest_pins|
        write_manifest(manifest_pins.first, manifest_pins.to_h { |p|
          [p.package, "9.9.9"]
        })
      end

      result = sweep.call
      expect(result.divergent?).to be true
      expect(result.details[:offenders].map { |o| [o[:ecosystem], o[:provider], o[:package]] }).to contain_exactly(
        *CliPinSync::PINS.map { |p| [ecosystem_for(p), p.provider_dir, p.package] }
      )
    end

    it "reports omp's bun pin when it drifts alongside a correct CLI pin" do
      write_in_sync_tree
      omp_cli = pin("omp/@oh-my-pi/pi-coding-agent")
      omp_bun = pin("omp/bun")
      write_manifest(omp_bun, {
        omp_cli.package => SWEEP_FIXTURE_VERSIONS.fetch("omp/@oh-my-pi/pi-coding-agent"),
        omp_bun.package => "9.9.9" # stale
      })

      result = sweep.call
      expect(result.divergent?).to be true
      offender = result.details[:offenders].first
      expect(offender[:ecosystem]).to eq("npm")
      expect(offender[:provider]).to eq("omp")
      expect(offender[:package]).to eq("bun")
      expect(offender[:manifest_value]).to eq("9.9.9")
      expect(offender[:constant_value]).to eq(SWEEP_FIXTURE_VERSIONS.fetch("omp/bun"))
    end

    it "returns :divergent and reports the offending npm provider" do
      write_in_sync_tree
      write_manifest(pin("codex/@openai/codex"), {"@openai/codex" => "9.9.9"}) # stale

      result = sweep.call
      expect(result.divergent?).to be true
      offender = result.details[:offenders].first
      expect(offender[:ecosystem]).to eq("npm")
      expect(offender[:provider]).to eq("codex")
      expect(offender[:package]).to eq("@openai/codex")
      expect(offender[:manifest_value]).to eq("9.9.9")
      expect(offender[:constant_value]).to eq(SWEEP_FIXTURE_VERSIONS.fetch("codex/@openai/codex"))
    end

    it "returns :divergent and reports the offending pip provider" do
      write_in_sync_tree
      write_manifest(pin("aider/aider-chat"), {"aider-chat" => "9.9.9"}) # stale

      result = sweep.call
      expect(result.divergent?).to be true
      offender = result.details[:offenders].first
      expect(offender[:ecosystem]).to eq("pip")
      expect(offender[:provider]).to eq("aider")
      expect(offender[:package]).to eq("aider-chat")
      expect(offender[:manifest_value]).to eq("9.9.9")
      expect(offender[:constant_value]).to eq(SWEEP_FIXTURE_VERSIONS.fetch("aider/aider-chat"))
    end

    it "reports a manifest that dropped the package entirely" do
      write_in_sync_tree
      write_manifest(pin("gemini/@google/gemini-cli"), {}) # package missing

      result = sweep.call
      expect(result.divergent?).to be true
      offender = result.details[:offenders].find { |o| o[:package] == "@google/gemini-cli" }
      expect(offender[:manifest_value]).to be_nil
      expect(offender[:constant_value]).to eq(SWEEP_FIXTURE_VERSIONS.fetch("gemini/@google/gemini-cli"))
    end

    it "reports a provider whose constant no longer parses" do
      write_in_sync_tree
      write_provider(pin("opencode/opencode-ai"), {"UNRELATED" => "0.0.1"})

      result = sweep.call
      expect(result.divergent?).to be true
      offender = result.details[:offenders].find { |o| o[:package] == "opencode-ai" }
      expect(offender[:constant_value]).to be_nil
      expect(offender[:manifest_value]).to eq(SWEEP_FIXTURE_VERSIONS.fetch("opencode/opencode-ai"))
    end

    it "skips providers whose manifest is missing (defensive)" do
      # No manifests at all
      expect(sweep.call.unchanged?).to be true
    end
  end
end
