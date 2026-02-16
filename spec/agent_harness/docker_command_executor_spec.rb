# frozen_string_literal: true

require "logger"

RSpec.describe AgentHarness::DockerCommandExecutor do
  let(:container_id) { "test-container-abc123" }
  let(:logger) { instance_double(Logger, debug: nil) }

  before do
    # Stub Docker CLI as available on host PATH
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("PATH").and_return("/usr/local/bin:/usr/bin")
    allow(File).to receive(:executable?).and_call_original
    allow(File).to receive(:executable?).with("/usr/local/bin/docker").and_return(true)
  end

  describe "#initialize" do
    it "stores the container_id" do
      executor = described_class.new(container_id: container_id)
      expect(executor.container_id).to eq(container_id)
    end

    it "accepts an optional logger" do
      executor = described_class.new(container_id: container_id, logger: logger)
      expect(executor.logger).to eq(logger)
    end

    it "raises ArgumentError when container_id is nil" do
      expect {
        described_class.new(container_id: nil)
      }.to raise_error(ArgumentError, /container_id cannot be nil or empty/)
    end

    it "raises ArgumentError when container_id is empty" do
      expect {
        described_class.new(container_id: "")
      }.to raise_error(ArgumentError, /container_id cannot be nil or empty/)
    end

    it "raises CommandExecutionError when docker CLI is not found" do
      allow(File).to receive(:executable?).with("/usr/local/bin/docker").and_return(false)
      allow(File).to receive(:executable?).with("/usr/bin/docker").and_return(false)

      expect {
        described_class.new(container_id: container_id)
      }.to raise_error(AgentHarness::CommandExecutionError, /Docker CLI not found/)
    end
  end

  describe "#execute" do
    subject(:executor) { described_class.new(container_id: container_id) }

    let(:mock_result) do
      AgentHarness::CommandExecutor::Result.new(
        stdout: "output",
        stderr: "",
        exit_code: 0,
        duration: 0.5
      )
    end

    before do
      allow(Open3).to receive(:popen3).and_return(nil)
    end

    it "wraps command with docker exec" do
      expect_popen3_with(["docker", "exec", container_id, "echo", "hello"])
      executor.execute(["echo", "hello"])
    end

    it "translates env vars to --env flags" do
      expect_popen3_with(["docker", "exec", "--env", "FOO=bar", "--env", "BAZ=qux", container_id, "echo", "hi"])
      executor.execute(["echo", "hi"], env: {"FOO" => "bar", "BAZ" => "qux"})
    end

    it "adds -i flag when stdin_data is present" do
      expect_popen3_with(["docker", "exec", "-i", container_id, "cat"])
      executor.execute(["cat"], stdin_data: "input data")
    end

    it "passes empty env to the host process" do
      expect_popen3_with(["docker", "exec", "--env", "CONTAINER_VAR=value", container_id, "ls"], env: {})
      executor.execute(["ls"], env: {"CONTAINER_VAR" => "value"})
    end

    it "passes timeout through to parent" do
      expect(Timeout).to receive(:timeout).with(30).and_call_original
      allow(Open3).to receive(:popen3) do |*_args, &block|
        stdin = StringIO.new
        stdout = StringIO.new("output")
        stderr = StringIO.new("")
        wait_thr = instance_double(Process::Waiter, value: instance_double(Process::Status, exitstatus: 0))
        block.call(stdin, stdout, stderr, wait_thr)
      end

      executor.execute(["echo", "test"], timeout: 30)
    end

    it "handles string commands" do
      expect_popen3_with(["docker", "exec", container_id, "echo", "hello world"])
      executor.execute("echo hello\\ world")
    end

    private

    def expect_popen3_with(expected_cmd, env: {})
      allow(Open3).to receive(:popen3) do |actual_env, *actual_cmd, &block|
        expect(actual_env).to eq(env)
        expect(actual_cmd).to eq(expected_cmd)
        stdin = StringIO.new
        stdout = StringIO.new("output")
        stderr = StringIO.new("")
        wait_thr = instance_double(Process::Waiter, value: instance_double(Process::Status, exitstatus: 0))
        block.call(stdin, stdout, stderr, wait_thr)
      end
    end
  end

  describe "#which" do
    subject(:executor) { described_class.new(container_id: container_id) }

    it "returns the path when binary is found" do
      expect(Timeout).to receive(:timeout).with(5).and_call_original
      allow(Open3).to receive(:popen3) do |_env, *_cmd, &block|
        stdin = StringIO.new
        stdout = StringIO.new("/usr/bin/ruby\n")
        stderr = StringIO.new("")
        wait_thr = instance_double(Process::Waiter, value: instance_double(Process::Status, exitstatus: 0))
        block.call(stdin, stdout, stderr, wait_thr)
      end

      expect(executor.which("ruby")).to eq("/usr/bin/ruby")
    end

    it "returns nil when binary is not found" do
      allow(Open3).to receive(:popen3) do |_env, *_cmd, &block|
        stdin = StringIO.new
        stdout = StringIO.new("")
        stderr = StringIO.new("which: no nonexistent in PATH")
        wait_thr = instance_double(Process::Waiter, value: instance_double(Process::Status, exitstatus: 1))
        block.call(stdin, stdout, stderr, wait_thr)
      end

      expect(executor.which("nonexistent")).to be_nil
    end
  end

  describe "#available?" do
    subject(:executor) { described_class.new(container_id: container_id) }

    it "returns true when which finds the binary" do
      allow(executor).to receive(:which).with("ruby").and_return("/usr/bin/ruby")
      expect(executor.available?("ruby")).to be true
    end

    it "returns false when which returns nil" do
      allow(executor).to receive(:which).with("nonexistent").and_return(nil)
      expect(executor.available?("nonexistent")).to be false
    end
  end
end
