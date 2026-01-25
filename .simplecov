# frozen_string_literal: true

# Central SimpleCov configuration.
# Run with: COVERAGE=1 bundle exec rspec

require "simplecov"

SimpleCov.start do
  enable_coverage :branch

  track_files "lib/**/*.rb"

  add_filter "lib/agent_harness/version.rb"
  add_filter "/spec/"
  add_filter "/pkg/"
  add_filter "/tmp/"

  add_group "Core", "lib/agent_harness"
  add_group "Providers", "lib/agent_harness/providers"
  add_group "Orchestration", "lib/agent_harness/orchestration"
  add_group "Configuration", "lib/agent_harness/configuration"

  # Match AIDP coverage thresholds
  minimum_coverage line: 82, branch: 64
  minimum_coverage_by_file 58
end
