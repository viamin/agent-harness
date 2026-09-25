# frozen_string_literal: true

require "open3"

RSpec.describe "hyphenated require entrypoint" do
  it 'loads the gem via `require "agent-harness"`' do
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      "-I",
      File.expand_path("../../lib", __dir__),
      "-e",
      'require "agent-harness"; print AgentHarness::VERSION'
    )

    expect(status).to be_success, stderr
    expect(stdout).to eq(AgentHarness::VERSION)
  end

  it "does not load Rails persistence in a plain Ruby process" do
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      "-I",
      File.expand_path("../../lib", __dir__),
      "-e",
      'require "agent-harness"; print [defined?(Rails), defined?(ActiveRecord)].inspect'
    )

    expect(status).to be_success, stderr
    expect(stdout).to eq("[nil, nil]")
  end
end
