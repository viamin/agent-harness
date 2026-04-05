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

    it "translates nil env values into in-container unsets" do
      expect_popen3_with(["docker", "exec", "--env", "FOO=bar", container_id, "env", "-u", "BAR", "echo", "hi"])
      executor.execute(["echo", "hi"], env: {"FOO" => "bar", "BAR" => nil})
    end

    it "supports multiple in-container env unsets" do
      expect_popen3_with(["docker", "exec", container_id, "env", "-u", "BAR", "-u", "BAZ", "echo", "hi"])
      executor.execute(["echo", "hi"], env: {"BAR" => nil, "BAZ" => nil})
    end

    it "adds -i flag when stdin_data is present" do
      expect_popen3_with(["docker", "exec", "-i", container_id, "cat"])
      executor.execute(["cat"], stdin_data: "input data")
    end

    it "passes empty env to the host process" do
      expect_popen3_with(["docker", "exec", "--env", "CONTAINER_VAR=value", container_id, "ls"], env: {})
      executor.execute(["ls"], env: {"CONTAINER_VAR" => "value"})
    end

    it "materializes preparation file writes inside the container before executing" do
      allow(SecureRandom).to receive(:hex).and_return("deadbeefcafebabe")

      expect_popen3_sequence(
        [
          {
            env: {},
            cmd: ["docker", "exec", container_id, "sh", "-lc", "[ ! -e \"$HOME\"/.config/opencode/opencode.json ] || cp -p \"$HOME\"/.config/opencode/opencode.json /tmp/agent-harness-preparation-deadbeefcafebabe"]
          },
          {
            env: {},
            cmd: ["docker", "exec", container_id, "sh", "-lc", "mkdir -p \"$HOME\"/.config/opencode"]
          },
          {
            env: {},
            cmd: ["docker", "exec", "-i", container_id, "sh", "-lc", "cat > \"$HOME\"/.config/opencode/opencode.json"],
            stdin: "{\"ok\":true}"
          },
          {
            env: {},
            cmd: ["docker", "exec", container_id, "sh", "-lc", "chmod 600 \"$HOME\"/.config/opencode/opencode.json"]
          },
          {
            env: {},
            cmd: ["docker", "exec", container_id, "echo", "hello"]
          },
          {
            env: {},
            cmd: ["docker", "exec", container_id, "sh", "-lc", "if [ -e /tmp/agent-harness-preparation-deadbeefcafebabe ]; then cp -p /tmp/agent-harness-preparation-deadbeefcafebabe \"$HOME\"/.config/opencode/opencode.json && rm -f /tmp/agent-harness-preparation-deadbeefcafebabe; else rm -f \"$HOME\"/.config/opencode/opencode.json; fi"]
          }
        ]
      )

      executor.execute(
        ["echo", "hello"],
        preparation: AgentHarness::ExecutionPreparation.new(
          file_writes: [{path: "~/.config/opencode/opencode.json", content: "{\"ok\":true}", mode: 0o600}]
        )
      )
    end

    it "uses request env overrides for container preparation commands" do
      allow(SecureRandom).to receive(:hex).and_return("deadbeefcafebabe")

      expect_popen3_sequence(
        [
          {
            env: {},
            cmd: ["docker", "exec", "--env", "HOME=/tmp/request-home", container_id, "sh", "-lc", "[ ! -e \"$HOME\"/.config/opencode/opencode.json ] || cp -p \"$HOME\"/.config/opencode/opencode.json /tmp/agent-harness-preparation-deadbeefcafebabe"]
          },
          {
            env: {},
            cmd: ["docker", "exec", "--env", "HOME=/tmp/request-home", container_id, "sh", "-lc", "mkdir -p \"$HOME\"/.config/opencode"]
          },
          {
            env: {},
            cmd: ["docker", "exec", "--env", "HOME=/tmp/request-home", "-i", container_id, "sh", "-lc", "cat > \"$HOME\"/.config/opencode/opencode.json"],
            stdin: "{\"ok\":true}"
          },
          {
            env: {},
            cmd: ["docker", "exec", "--env", "HOME=/tmp/request-home", container_id, "echo", "hello"]
          },
          {
            env: {},
            cmd: ["docker", "exec", "--env", "HOME=/tmp/request-home", container_id, "sh", "-lc", "if [ -e /tmp/agent-harness-preparation-deadbeefcafebabe ]; then cp -p /tmp/agent-harness-preparation-deadbeefcafebabe \"$HOME\"/.config/opencode/opencode.json && rm -f /tmp/agent-harness-preparation-deadbeefcafebabe; else rm -f \"$HOME\"/.config/opencode/opencode.json; fi"]
          }
        ]
      )

      executor.execute(
        ["echo", "hello"],
        env: {"HOME" => "/tmp/request-home"},
        preparation: AgentHarness::ExecutionPreparation.new(
          file_writes: [{path: "~/.config/opencode/opencode.json", content: "{\"ok\":true}"}]
        )
      )
    end

    it "preserves shell env expansion in container preparation paths" do
      allow(SecureRandom).to receive(:hex).and_return("deadbeefcafebabe")

      expect_popen3_sequence(
        [
          {
            env: {},
            cmd: ["docker", "exec", "--env", "XDG_CONFIG_HOME=/tmp/opencode-config", container_id, "sh", "-lc", "[ ! -e $XDG_CONFIG_HOME/opencode.json ] || cp -p $XDG_CONFIG_HOME/opencode.json /tmp/agent-harness-preparation-deadbeefcafebabe"]
          },
          {
            env: {},
            cmd: ["docker", "exec", "--env", "XDG_CONFIG_HOME=/tmp/opencode-config", container_id, "sh", "-lc", "mkdir -p $XDG_CONFIG_HOME"]
          },
          {
            env: {},
            cmd: ["docker", "exec", "--env", "XDG_CONFIG_HOME=/tmp/opencode-config", "-i", container_id, "sh", "-lc", "cat > $XDG_CONFIG_HOME/opencode.json"],
            stdin: "{\"ok\":true}"
          },
          {
            env: {},
            cmd: ["docker", "exec", "--env", "XDG_CONFIG_HOME=/tmp/opencode-config", container_id, "echo", "hello"]
          },
          {
            env: {},
            cmd: ["docker", "exec", "--env", "XDG_CONFIG_HOME=/tmp/opencode-config", container_id, "sh", "-lc", "if [ -e /tmp/agent-harness-preparation-deadbeefcafebabe ]; then cp -p /tmp/agent-harness-preparation-deadbeefcafebabe $XDG_CONFIG_HOME/opencode.json && rm -f /tmp/agent-harness-preparation-deadbeefcafebabe; else rm -f $XDG_CONFIG_HOME/opencode.json; fi"]
          }
        ]
      )

      executor.execute(
        ["echo", "hello"],
        env: {"XDG_CONFIG_HOME" => "/tmp/opencode-config"},
        preparation: AgentHarness::ExecutionPreparation.new(
          file_writes: [{path: "$XDG_CONFIG_HOME/opencode.json", content: "{\"ok\":true}"}]
        )
      )
    end

    it "uses the remaining timeout budget for preparation and execution" do
      allow(SecureRandom).to receive(:hex).and_return("deadbeefcafebabe")
      time_values = [
        100.0, 100.0, 100.0, 100.0, 100.0,
        105.0, 105.0, 105.0, 105.0, 105.0,
        110.0, 110.0, 110.0, 110.0, 110.0,
        115.0, 115.0, 115.0, 115.0, 115.0,
        120.0, 120.0, 120.0, 120.0, 120.0
      ]
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(*time_values)
      timeouts = []
      allow(Timeout).to receive(:timeout).and_wrap_original do |original, value, &block|
        timeouts << value
        original.call(value, &block)
      end
      allow(Open3).to receive(:popen3) do |*_args, &block|
        stdin = StringIO.new
        stdout = StringIO.new("output")
        stderr = StringIO.new("")
        wait_thr = instance_double(Process::Waiter, value: instance_double(Process::Status, exitstatus: 0))
        block.call(stdin, stdout, stderr, wait_thr)
      end

      executor.execute(
        ["echo", "test"],
        timeout: 30,
        preparation: AgentHarness::ExecutionPreparation.new(
          file_writes: [{path: "~/.config/opencode/opencode.json", content: "{\"ok\":true}"}]
        )
      )

      expect(timeouts.length).to eq(5)
      expect(timeouts).to all(be > 0)
      expect(timeouts).to eq(timeouts.sort.reverse)
      expect(timeouts.last).to be < timeouts.first
    end

    it "cleans up the current prepared file if container preparation fails after writing" do
      allow(SecureRandom).to receive(:hex).and_return("deadbeefcafebabe")
      calls = []

      allow(Open3).to receive(:popen3) do |actual_env, *actual_cmd, &block|
        calls << {env: actual_env, cmd: actual_cmd}
        stderr = if actual_cmd == ["docker", "exec", container_id, "sh", "-lc", "chmod 600 \"$HOME\"/.config/opencode/opencode.json"]
          StringIO.new("chmod failed")
        else
          StringIO.new("")
        end
        exit_code = stderr.string.empty? ? 0 : 1
        stdin = StringIO.new
        stdout = StringIO.new("output")
        wait_thr = instance_double(Process::Waiter, value: instance_double(Process::Status, exitstatus: exit_code))
        block.call(stdin, stdout, stderr, wait_thr)
      end

      expect {
        executor.execute(
          ["echo", "hello"],
          preparation: AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: "~/.config/opencode/opencode.json", content: "{\"ok\":true}", mode: 0o600}]
          )
        )
      }.to raise_error(AgentHarness::CommandExecutionError, /chmod failed/)

      expect(calls).to eq(
        [
          {env: {}, cmd: ["docker", "exec", container_id, "sh", "-lc", "[ ! -e \"$HOME\"/.config/opencode/opencode.json ] || cp -p \"$HOME\"/.config/opencode/opencode.json /tmp/agent-harness-preparation-deadbeefcafebabe"]},
          {env: {}, cmd: ["docker", "exec", container_id, "sh", "-lc", "mkdir -p \"$HOME\"/.config/opencode"]},
          {env: {}, cmd: ["docker", "exec", "-i", container_id, "sh", "-lc", "cat > \"$HOME\"/.config/opencode/opencode.json"]},
          {env: {}, cmd: ["docker", "exec", container_id, "sh", "-lc", "chmod 600 \"$HOME\"/.config/opencode/opencode.json"]},
          {env: {}, cmd: ["docker", "exec", container_id, "sh", "-lc", "if [ -e /tmp/agent-harness-preparation-deadbeefcafebabe ]; then cp -p /tmp/agent-harness-preparation-deadbeefcafebabe \"$HOME\"/.config/opencode/opencode.json && rm -f /tmp/agent-harness-preparation-deadbeefcafebabe; else rm -f \"$HOME\"/.config/opencode/opencode.json; fi"]}
        ]
      )
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

    def expect_popen3_sequence(expected_calls)
      index = 0

      allow(Open3).to receive(:popen3) do |actual_env, *actual_cmd, &block|
        expected = expected_calls.fetch(index)
        index += 1

        expect(actual_env).to eq(expected[:env])
        expect(actual_cmd).to eq(expected[:cmd])

        stdin = StringIO.new
        stdout = StringIO.new("output")
        stderr = StringIO.new("")
        wait_thr = instance_double(Process::Waiter, value: instance_double(Process::Status, exitstatus: 0))
        result = block.call(stdin, stdout, stderr, wait_thr)

        expect(stdin.string).to eq(expected[:stdin]) if expected.key?(:stdin)
        result
      end
    end
  end

  describe "#which" do
    subject(:executor) { described_class.new(container_id: container_id) }

    it "returns the path when binary is found" do
      expect(Timeout).to receive(:timeout).with(be_within(0.01).of(5)).and_call_original
      allow(Open3).to receive(:popen3) do |actual_env, *actual_cmd, &block|
        expect(actual_env).to eq({})
        expect(actual_cmd).to eq(["docker", "exec", container_id, "which", "ruby"])
        stdin = StringIO.new
        stdout = StringIO.new("/usr/bin/ruby\n")
        stderr = StringIO.new("")
        wait_thr = instance_double(Process::Waiter, value: instance_double(Process::Status, exitstatus: 0))
        block.call(stdin, stdout, stderr, wait_thr)
      end

      expect(executor.which("ruby")).to eq("/usr/bin/ruby")
    end

    it "returns nil when binary is not found" do
      allow(Open3).to receive(:popen3) do |actual_env, *actual_cmd, &block|
        expect(actual_env).to eq({})
        expect(actual_cmd).to eq(["docker", "exec", container_id, "which", "nonexistent"])
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
