# frozen_string_literal: true

require_relative "lib/agent_harness/version"

Gem::Specification.new do |spec|
  spec.name = "agent-harness"
  spec.version = AgentHarness::VERSION
  spec.authors = ["Bart Agapinan"]
  spec.email = ["bart@sonic.net"]

  spec.summary = "Unified interface for CLI-based AI coding agents"
  spec.description = <<~DESC
    AgentHarness provides a unified interface for CLI-based AI coding agents like
    Claude Code, Cursor, Gemini CLI, and others. It offers full orchestration with
    provider switching, circuit breakers, health monitoring, flexible configuration,
    dynamic provider registration, and token usage tracking.
  DESC
  spec.homepage = "https://github.com/viamin/agent-harness"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/viamin/agent-harness"
  spec.metadata["changelog_uri"] = "https://github.com/viamin/agent-harness/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github .standard.yml Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.0"
  spec.add_development_dependency "standard", "~> 1.3"
end
