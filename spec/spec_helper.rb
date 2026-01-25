# frozen_string_literal: true

require "bundler/setup"

# Coverage must start before any application files are loaded.
if ENV["COVERAGE"] == "1" || ENV["SIMPLECOV"] == "1"
  require "simplecov"
  SimpleCov.command_name "RSpec"
  puts "[SimpleCov] Coverage enabled" if ENV["DEBUG"]
end

require "agent_harness"

# When collecting coverage, load all library files so SimpleCov includes every line
if ENV["COVERAGE"] == "1" || ENV["SIMPLECOV"] == "1" || ENV["CI"]
  Dir[File.expand_path("../lib/**/*.rb", __dir__)].sort.each { |file| require file }
end

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  unless ENV["CI"]
    config.example_status_persistence_file_path = ".rspec_status"
  end

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.order = :random

  # Show the 5 slowest examples at the end of the test run
  config.profile_examples = 5

  # Reset AgentHarness configuration between tests
  config.before(:each) do
    AgentHarness.reset!
  end
end
