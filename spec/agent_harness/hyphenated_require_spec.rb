# frozen_string_literal: true

require "open3"

RSpec.describe "hyphenated require entrypoint" do
  it 'loads the gem via `require "agent-harness"`' do
    stdout, stderr, status = Open3.capture3(
      "ruby",
      "-I",
      File.expand_path("../../lib", __dir__),
      "-e",
      'require "agent-harness"; print AgentHarness::VERSION'
    )

    expect(status).to be_success, stderr
    expect(stdout).to eq(AgentHarness::VERSION)
  end
end
