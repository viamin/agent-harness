#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

# Syncs the Dependabot CLI-pin manifests under vendor/pins/ into the Ruby
# constants each provider ships (step 2 of the vendor/pins loop; see
# vendor/pins/README.md and issue #337).
#
# Usage: ruby script/sync-cli-pins.rb [REPO_ROOT]
#
# For every pin manifest the script reads the bumped version, parses the
# provider's requirement out of the source text (it never loads or evaluates
# the PR's Ruby), validates the bump against that requirement as currently
# written, and rewrites only the constant assignment when the bump is in
# range. Every manifest is validated before anything is written, so a
# blocked bump can never leave a half-synced tree behind.
#
# Exit codes:
#   0 - constants synced (or already in sync)
#   1 - one or more bumps blocked by a requirement range; a ready-to-post
#       PR comment is written to $CLI_PIN_SYNC_COMMENT_FILE when set
#   2 - structural error (missing manifest, unparseable source, ...)
class CliPinSync
  # The bumped version violates the provider's requirement as currently
  # declared. Expected condition that needs a human decision; #message is a
  # ready-to-post PR comment.
  class BlockedBump < StandardError; end

  # The manifests or provider sources no longer match the shapes this script
  # knows how to parse or rewrite. A loud bug, not an expected outcome.
  class SyncError < StandardError; end

  Pin = Struct.new(:provider_dir, :manifest, :package, :provider_file, :constant, :requirement_name)

  # Mirror of the inventory in spec/vendor_pins_parity_spec.rb and
  # vendor/pins/README.md. One entry per manifest package; omp carries two
  # (CLI + Bun runtime) in one manifest and provider file.
  PINS = [
    Pin.new(
      provider_dir: "claude", manifest: "package.json", package: "@anthropic-ai/claude-code",
      provider_file: "lib/agent_harness/providers/anthropic.rb",
      constant: "SUPPORTED_CLI_VERSION", requirement_name: "SUPPORTED_CLI_REQUIREMENT"
    ),
    Pin.new(
      provider_dir: "codex", manifest: "package.json", package: "@openai/codex",
      provider_file: "lib/agent_harness/providers/codex.rb",
      constant: "SUPPORTED_CLI_VERSION", requirement_name: "SUPPORTED_CLI_REQUIREMENT"
    ),
    Pin.new(
      provider_dir: "opencode", manifest: "package.json", package: "opencode-ai",
      provider_file: "lib/agent_harness/providers/opencode.rb",
      constant: "SUPPORTED_CLI_VERSION", requirement_name: "SUPPORTED_CLI_REQUIREMENT"
    ),
    Pin.new(
      provider_dir: "gemini", manifest: "package.json", package: "@google/gemini-cli",
      provider_file: "lib/agent_harness/providers/gemini.rb",
      constant: "SUPPORTED_CLI_VERSION", requirement_name: "SUPPORTED_CLI_REQUIREMENT"
    ),
    Pin.new(
      provider_dir: "pi", manifest: "package.json", package: "@mariozechner/pi-coding-agent",
      provider_file: "lib/agent_harness/providers/pi.rb",
      constant: "SUPPORTED_CLI_VERSION", requirement_name: "SUPPORTED_CLI_REQUIREMENT"
    ),
    Pin.new(
      provider_dir: "omp", manifest: "package.json", package: "@oh-my-pi/pi-coding-agent",
      provider_file: "lib/agent_harness/providers/omp.rb",
      constant: "SUPPORTED_CLI_VERSION", requirement_name: "SUPPORTED_CLI_REQUIREMENT"
    ),
    Pin.new(
      provider_dir: "omp", manifest: "package.json", package: "bun",
      provider_file: "lib/agent_harness/providers/omp.rb",
      constant: "SUPPORTED_BUN_VERSION", requirement_name: "BUN_REQUIREMENT_STRING"
    ),
    Pin.new(
      provider_dir: "kilocode", manifest: "package.json", package: "@kilocode/cli",
      provider_file: "lib/agent_harness/providers/kilocode.rb",
      constant: "DEFAULT_VERSION", requirement_name: "SUPPORTED_VERSION_REQUIREMENT"
    ),
    Pin.new(
      provider_dir: "aider", manifest: "requirements.txt", package: "aider-chat",
      provider_file: "lib/agent_harness/providers/aider.rb",
      constant: "SUPPORTED_CLI_VERSION", requirement_name: "SUPPORTED_CLI_REQUIREMENT"
    )
  ].freeze

  Plan = Struct.new(:pin, :bumped_version, :current_version, :requirement_strings, :status)

  BLOCKED_COMMENT_MARKER = "<!-- cli-pin-sync-blocked -->"

  def initialize(repo_root)
    @repo_root = File.expand_path(repo_root)
  end

  attr_reader :repo_root

  # Returns a human-readable summary string. Raises BlockedBump (with a PR
  # comment as #message) when any bump falls outside its requirement.
  def call
    plans = PINS.map { |pin| plan_for(pin) }
    raise_blocked(plans.select { |plan| plan.status == :blocked })
    apply(plans.select { |plan| plan.status == :update })
    summary_for(plans)
  end

  private

  def plan_for(pin)
    bumped = manifest_version(pin)
    source = read_provider_source(pin)
    current = constant_version(source, pin)
    if bumped.to_s == current
      return Plan.new(pin:, bumped_version: bumped, current_version: current, status: :in_sync)
    end

    constraints = requirement_strings(source, pin, current)
    status = requirement_for(constraints, pin).satisfied_by?(bumped) ? :update : :blocked
    Plan.new(pin:, bumped_version: bumped, current_version: current, requirement_strings: constraints, status:)
  end

  def manifest_version(pin)
    path = manifest_path(pin)
    raw = (pin.manifest == "requirements.txt") ? pip_pin(path, pin.package) : npm_pin(path, pin.package)
    parse_version(raw, path, pin.package)
  end

  def manifest_path(pin)
    File.join(repo_root, "vendor", "pins", pin.provider_dir, pin.manifest)
  end

  def npm_pin(path, package)
    JSON.parse(File.read(path, encoding: "UTF-8")).fetch("devDependencies", {})[package]
  rescue Errno::ENOENT, JSON::ParserError
    raise SyncError, "cannot read pin manifest #{relative(path)}"
  end

  def pip_pin(path, package)
    File.readlines(path, chomp: true, encoding: "UTF-8").each do |line|
      name, version = line.split("==", 2)
      return version.strip if name&.strip == package && version
    end
    nil
  rescue Errno::ENOENT
    raise SyncError, "cannot read pin manifest #{relative(path)}"
  end

  def parse_version(raw, path, package)
    if raw.nil?
      raise SyncError, "#{relative(path)} does not pin #{package} to an exact version (got #{raw.inspect})"
    end

    Gem::Version.new(raw)
  rescue ArgumentError
    raise SyncError, "#{relative(path)} pins #{package} to unparseable version #{raw.inspect}"
  end

  def read_provider_source(pin)
    File.read(File.join(repo_root, pin.provider_file), encoding: "UTF-8")
  rescue Errno::ENOENT
    raise SyncError, "missing provider source #{pin.provider_file}"
  end

  def constant_version(source, pin)
    match = source.match(/^\s*#{pin.constant}\s*=\s*"(?<version>[^"]+)"/)
    unless match
      raise SyncError, "#{pin.provider_file} no longer assigns #{pin.constant} = \"...\""
    end

    match[:version]
  end

  # Extracts the requirement's constraint strings ("gem" or pip style) from
  # the provider source without evaluating any Ruby. Interpolations of the
  # synced constant (e.g. ">= #{SUPPORTED_CLI_VERSION}") resolve to the
  # constant's current value so the bump is checked against the requirement
  # as it stands today.
  def requirement_strings(source, pin, current_version)
    assignment = source.match(/^[ \t]*#{pin.requirement_name}\s*=\s*(?<rhs>.+)$/)
    unless assignment
      raise SyncError, "#{pin.provider_file} no longer assigns #{pin.requirement_name}"
    end

    rhs = assignment[:rhs]
    if rhs.rstrip.end_with?(",")
      raise SyncError, "#{pin.provider_file}: #{pin.requirement_name} continues on the next line; cannot parse its constraints safely"
    end

    literals = rhs.scan(/"([^"]*)"/).flatten
    if literals.empty?
      raise SyncError, "#{pin.provider_file}: cannot parse requirement strings from #{pin.requirement_name}"
    end

    literals.map { |literal| interpolate(literal, pin, current_version) }
  end

  def interpolate(literal, pin, current_version)
    resolved = literal.gsub("\#{#{pin.constant}}", current_version)
    if resolved.include?("\#{")
      raise SyncError, "#{pin.provider_file}: cannot evaluate #{literal.inspect} in #{pin.requirement_name}"
    end

    resolved
  end

  def requirement_for(strings, pin)
    Gem::Requirement.new(*strings)
  rescue ArgumentError => e
    raise SyncError, "#{pin.provider_file}: illformed requirement #{strings.inspect} (#{e.message})"
  end

  def raise_blocked(plans)
    return if plans.empty?

    raise BlockedBump, blocked_comment(plans)
  end

  def blocked_comment(plans)
    rows = plans.map do |plan|
      "| `#{plan.pin.package}` | `#{plan.bumped_version}` | `#{plan.requirement_strings.join(", ")}` | " \
        "`#{plan.pin.constant}` in `#{plan.pin.provider_file}` |"
    end.join("\n")
    <<~COMMENT
      #{BLOCKED_COMMENT_MARKER}
      ## :no_entry: CLI pin sync blocked

      The manifest bump for the package(s) below cannot be synced automatically: the target version falls outside the requirement the provider currently declares, so a human must widen it deliberately. **Nothing was written to this branch.**

      | Package | Bumped to | Current requirement | Constant |
      | --- | --- | --- | --- |
      #{rows}

      `script/sync-cli-pins.rb` deliberately refuses to rewrite a constant when the manifest version violates the provider's requirement — that guard keeps an out-of-range install command from shipping silently. To land this bump, widen the requirement in the provider (plus any code that depends on the bound) and update the constant and manifest together; the parity spec (`spec/vendor_pins_parity_spec.rb`) keeps both sides honest.
    COMMENT
  end

  def apply(plans)
    plans.group_by { |plan| plan.pin.provider_file }.each_value do |file_plans|
      path = File.join(repo_root, file_plans.first.pin.provider_file)
      content = File.read(path, encoding: "UTF-8")
      file_plans.each { |plan| content = rewrite_constant(content, plan) }
      File.write(path, content)
    end
  end

  def rewrite_constant(content, plan)
    pattern = /^(\s*#{plan.pin.constant}\s*=\s*)"[^"]*"/
    unless content.match?(pattern)
      raise SyncError, "#{plan.pin.provider_file}: lost #{plan.pin.constant} assignment while rewriting"
    end

    content.sub(pattern, "\\1\"#{plan.bumped_version}\"")
  end

  def summary_for(plans)
    updated = plans.select { |plan| plan.status == :update }
    return "vendor/pins manifests and provider constants are in sync" if updated.empty?

    updated.map { |plan| "#{plan.pin.provider_file}: #{plan.pin.constant} #{plan.current_version} -> #{plan.bumped_version}" }
      .join("\n")
  end

  def relative(path)
    path.delete_prefix("#{repo_root}/")
  end
end

if $PROGRAM_NAME == __FILE__
  repo_root = ARGV[0] || File.expand_path("..", __dir__)
  begin
    puts CliPinSync.new(repo_root).call
  rescue CliPinSync::BlockedBump => e
    comment_file = ENV["CLI_PIN_SYNC_COMMENT_FILE"]
    File.write(comment_file, e.message) if comment_file && !comment_file.empty?
    warn e.message
    exit 1
  rescue CliPinSync::SyncError => e
    warn "sync-cli-pins: #{e.message}"
    exit 2
  end
end
