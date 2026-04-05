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
    AgentHarness::CommandExecutor::PREPARATION_LOCK_REGISTRY_MUTEX.synchronize do
      AgentHarness::CommandExecutor::PREPARATION_LOCK_REGISTRY.clear
    end
  end

  after do
    AgentHarness::CommandExecutor::PREPARATION_LOCK_REGISTRY_MUTEX.synchronize do
      AgentHarness::CommandExecutor::PREPARATION_LOCK_REGISTRY.clear
    end
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
      allow(SecureRandom).to receive(:hex).and_return("deadbeefcafebabe", "facefeedcafed00d", "beadfeedcafef00d")

      expect_popen3_sequence(
        [
          {
            env: {},
            cmd: ["docker", "exec", container_id, "sh", "-lc", backup_command("#{guarded_home_path}/.config/opencode/opencode.json")]
          },
          {
            env: {},
            cmd: ["docker", "exec", container_id, "sh", "-lc", "mkdir -p #{guarded_home_path}/.config/opencode"]
          },
          {
            env: {},
            cmd: ["docker", "exec", container_id, "sh", "-lc", remove_symlink_command("#{guarded_home_path}/.config/opencode/opencode.json")]
          },
          {
            env: {},
            cmd: ["docker", "exec", "-i", container_id, "sh", "-lc", "cat > #{guarded_home_path}/.config/opencode/opencode.json"],
            stdin: "{\"ok\":true}"
          },
          {
            env: {},
            cmd: ["docker", "exec", container_id, "sh", "-lc", "chmod 600 #{guarded_home_path}/.config/opencode/opencode.json"]
          },
          {
            env: {},
            cmd: ["docker", "exec", container_id, "echo", "hello"]
          },
          {
            env: {},
            cmd: ["docker", "exec", container_id, "sh", "-lc", cleanup_command("#{guarded_home_path}/.config/opencode/opencode.json", "#{guarded_home_path}/.config/opencode")]
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
      allow(SecureRandom).to receive(:hex).and_return("deadbeefcafebabe", "facefeedcafed00d", "beadfeedcafef00d")

      expect_popen3_sequence(
        [
          {
            env: {},
            cmd: ["docker", "exec", "--env", "HOME=/tmp/request-home", container_id, "sh", "-lc", backup_command("#{guarded_home_path}/.config/opencode/opencode.json")]
          },
          {
            env: {},
            cmd: ["docker", "exec", "--env", "HOME=/tmp/request-home", container_id, "sh", "-lc", "mkdir -p #{guarded_home_path}/.config/opencode"]
          },
          {
            env: {},
            cmd: ["docker", "exec", "--env", "HOME=/tmp/request-home", container_id, "sh", "-lc", remove_symlink_command("#{guarded_home_path}/.config/opencode/opencode.json")]
          },
          {
            env: {},
            cmd: ["docker", "exec", "--env", "HOME=/tmp/request-home", "-i", container_id, "sh", "-lc", "cat > #{guarded_home_path}/.config/opencode/opencode.json"],
            stdin: "{\"ok\":true}"
          },
          {
            env: {},
            cmd: ["docker", "exec", "--env", "HOME=/tmp/request-home", container_id, "echo", "hello"]
          },
          {
            env: {},
            cmd: ["docker", "exec", "--env", "HOME=/tmp/request-home", container_id, "sh", "-lc", cleanup_command("#{guarded_home_path}/.config/opencode/opencode.json", "#{guarded_home_path}/.config/opencode")]
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

    it "supports preparation targets directly under HOME" do
      allow(SecureRandom).to receive(:hex).and_return("deadbeefcafebabe", "facefeedcafed00d", "beadfeedcafef00d")

      expect_popen3_sequence(
        [
          {
            env: {},
            cmd: ["docker", "exec", container_id, "sh", "-lc", backup_command("#{guarded_home_path}/opencode.json", requested_path: "~/opencode.json")]
          },
          {
            env: {},
            cmd: ["docker", "exec", container_id, "sh", "-lc", "mkdir -p #{guarded_home_path}"]
          },
          {
            env: {},
            cmd: ["docker", "exec", container_id, "sh", "-lc", remove_symlink_command("#{guarded_home_path}/opencode.json")]
          },
          {
            env: {},
            cmd: ["docker", "exec", "-i", container_id, "sh", "-lc", "cat > #{guarded_home_path}/opencode.json"],
            stdin: "{\"ok\":true}"
          },
          {
            env: {},
            cmd: ["docker", "exec", container_id, "echo", "hello"]
          },
          {
            env: {},
            cmd: ["docker", "exec", container_id, "sh", "-lc", cleanup_command("#{guarded_home_path}/opencode.json", guarded_home_path, requested_path: "~/opencode.json")]
          }
        ]
      )

      executor.execute(
        ["echo", "hello"],
        preparation: AgentHarness::ExecutionPreparation.new(
          file_writes: [{path: "~/opencode.json", content: "{\"ok\":true}"}]
        )
      )
    end

    it "rejects home-relative preparation paths when HOME is explicitly unset" do
      expect {
        executor.execute(
          ["echo", "hello"],
          env: {"HOME" => nil},
          preparation: AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: "~/.config/opencode/opencode.json", content: "{\"ok\":true}"}]
          )
        )
      }.to raise_error(ArgumentError, /HOME cannot be nil or empty/)

      expect(Open3).not_to have_received(:popen3)
    end

    it "guards home-relative preparation paths against missing container HOME" do
      allow(SecureRandom).to receive(:hex).and_return("deadbeefcafebabe", "facefeedcafed00d", "beadfeedcafef00d")

      expect_popen3_sequence(
        [
          {
            env: {},
            cmd: ["docker", "exec", container_id, "sh", "-lc", backup_command("#{guarded_home_path}/.config/opencode/opencode.json")]
          },
          {
            env: {},
            cmd: ["docker", "exec", container_id, "sh", "-lc", "mkdir -p #{guarded_home_path}/.config/opencode"]
          },
          {
            env: {},
            cmd: ["docker", "exec", container_id, "sh", "-lc", remove_symlink_command("#{guarded_home_path}/.config/opencode/opencode.json")]
          },
          {
            env: {},
            cmd: ["docker", "exec", "-i", container_id, "sh", "-lc", "cat > #{guarded_home_path}/.config/opencode/opencode.json"],
            stdin: "{\"ok\":true}"
          },
          {
            env: {},
            cmd: ["docker", "exec", container_id, "echo", "hello"]
          },
          {
            env: {},
            cmd: ["docker", "exec", container_id, "sh", "-lc", cleanup_command("#{guarded_home_path}/.config/opencode/opencode.json", "#{guarded_home_path}/.config/opencode")]
          }
        ]
      )

      executor.execute(
        ["echo", "hello"],
        preparation: AgentHarness::ExecutionPreparation.new(
          file_writes: [{path: "~/.config/opencode/opencode.json", content: "{\"ok\":true}"}]
        )
      )
    end

    it "quotes env-backed container preparation paths for shell execution" do
      allow(SecureRandom).to receive(:hex).and_return("deadbeefcafebabe", "facefeedcafed00d", "beadfeedcafef00d")

      expect_popen3_sequence(
        [
          {
            env: {},
            cmd: ["docker", "exec", "--env", "XDG_CONFIG_HOME=/tmp/my config", container_id, "sh", "-lc", backup_command("\"${XDG_CONFIG_HOME}\"/opencode.json", requested_path: "$XDG_CONFIG_HOME/opencode.json")]
          },
          {
            env: {},
            cmd: ["docker", "exec", "--env", "XDG_CONFIG_HOME=/tmp/my config", container_id, "sh", "-lc", "mkdir -p \"${XDG_CONFIG_HOME}\""]
          },
          {
            env: {},
            cmd: ["docker", "exec", "--env", "XDG_CONFIG_HOME=/tmp/my config", container_id, "sh", "-lc", remove_symlink_command("\"${XDG_CONFIG_HOME}\"/opencode.json")]
          },
          {
            env: {},
            cmd: ["docker", "exec", "--env", "XDG_CONFIG_HOME=/tmp/my config", "-i", container_id, "sh", "-lc", "cat > \"${XDG_CONFIG_HOME}\"/opencode.json"],
            stdin: "{\"ok\":true}"
          },
          {
            env: {},
            cmd: ["docker", "exec", "--env", "XDG_CONFIG_HOME=/tmp/my config", container_id, "echo", "hello"]
          },
          {
            env: {},
            cmd: ["docker", "exec", "--env", "XDG_CONFIG_HOME=/tmp/my config", container_id, "sh", "-lc", cleanup_command("\"${XDG_CONFIG_HOME}\"/opencode.json", "\"${XDG_CONFIG_HOME}\"", requested_path: "$XDG_CONFIG_HOME/opencode.json")]
          }
        ]
      )

      executor.execute(
        ["echo", "hello"],
        env: {"XDG_CONFIG_HOME" => "/tmp/my config"},
        preparation: AgentHarness::ExecutionPreparation.new(
          file_writes: [{path: "$XDG_CONFIG_HOME/opencode.json", content: "{\"ok\":true}"}]
        )
      )
    end

    it "expands env refs embedded within container path segments" do
      allow(SecureRandom).to receive(:hex).and_return("deadbeefcafebabe", "facefeedcafed00d", "beadfeedcafef00d")

      expect_popen3_sequence(
        [
          {
            env: {},
            cmd: ["docker", "exec", "--env", "XDG_CONFIG_HOME=/tmp/my config", "--env", "BAR=baz qux", container_id, "sh", "-lc", backup_command("\"${XDG_CONFIG_HOME}\"/foo-\"${BAR}\".json", requested_path: "$XDG_CONFIG_HOME/foo-$BAR.json")]
          },
          {
            env: {},
            cmd: ["docker", "exec", "--env", "XDG_CONFIG_HOME=/tmp/my config", "--env", "BAR=baz qux", container_id, "sh", "-lc", "mkdir -p \"${XDG_CONFIG_HOME}\""]
          },
          {
            env: {},
            cmd: ["docker", "exec", "--env", "XDG_CONFIG_HOME=/tmp/my config", "--env", "BAR=baz qux", container_id, "sh", "-lc", remove_symlink_command("\"${XDG_CONFIG_HOME}\"/foo-\"${BAR}\".json")]
          },
          {
            env: {},
            cmd: ["docker", "exec", "--env", "XDG_CONFIG_HOME=/tmp/my config", "--env", "BAR=baz qux", "-i", container_id, "sh", "-lc", "cat > \"${XDG_CONFIG_HOME}\"/foo-\"${BAR}\".json"],
            stdin: "{\"ok\":true}"
          },
          {
            env: {},
            cmd: ["docker", "exec", "--env", "XDG_CONFIG_HOME=/tmp/my config", "--env", "BAR=baz qux", container_id, "echo", "hello"]
          },
          {
            env: {},
            cmd: ["docker", "exec", "--env", "XDG_CONFIG_HOME=/tmp/my config", "--env", "BAR=baz qux", container_id, "sh", "-lc", cleanup_command("\"${XDG_CONFIG_HOME}\"/foo-\"${BAR}\".json", "\"${XDG_CONFIG_HOME}\"", requested_path: "$XDG_CONFIG_HOME/foo-$BAR.json")]
          }
        ]
      )

      executor.execute(
        ["echo", "hello"],
        env: {"XDG_CONFIG_HOME" => "/tmp/my config", "BAR" => "baz qux"},
        preparation: AgentHarness::ExecutionPreparation.new(
          file_writes: [{path: "$XDG_CONFIG_HOME/foo-$BAR.json", content: "{\"ok\":true}"}]
        )
      )
    end

    it "rejects env-backed container preparation paths when the env var is missing" do
      expect {
        executor.execute(
          ["echo", "hello"],
          env: {},
          preparation: AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: "$AGENT_HARNESS_TEST_CONFIG_HOME/opencode.json", content: "{\"ok\":true}"}]
          )
        )
      }.to raise_error(ArgumentError, /AGENT_HARNESS_TEST_CONFIG_HOME cannot be nil or empty/)

      expect(Open3).not_to have_received(:popen3)
    end

    it "rejects env-backed container preparation paths when the env var is blank" do
      expect {
        executor.execute(
          ["echo", "hello"],
          env: {"AGENT_HARNESS_TEST_CONFIG_HOME" => ""},
          preparation: AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: "$AGENT_HARNESS_TEST_CONFIG_HOME/opencode.json", content: "{\"ok\":true}"}]
          )
        )
      }.to raise_error(ArgumentError, /AGENT_HARNESS_TEST_CONFIG_HOME cannot be nil or empty/)

      expect(Open3).not_to have_received(:popen3)
    end

    it "uses the remaining timeout budget for preparation and execution" do
      allow(SecureRandom).to receive(:hex).and_return("deadbeefcafebabe", "facefeedcafed00d", "beadfeedcafef00d")
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

      expect(timeouts.length).to eq(6)
      expect(timeouts).to all(be > 0)
      expect(timeouts).to eq(timeouts.sort.reverse)
      expect(timeouts.last).to be < timeouts.first
    end

    it "unlinks the current path before restoring originally existing files" do
      allow(SecureRandom).to receive(:hex).and_return("deadbeefcafebabe", "facefeedcafed00d", "beadfeedcafef00d")

      expect_popen3_sequence(
        [
          {
            env: {},
            cmd: ["docker", "exec", container_id, "sh", "-lc", backup_command("#{guarded_home_path}/.config/opencode/opencode.json")]
          },
          {
            env: {},
            cmd: ["docker", "exec", container_id, "sh", "-lc", "mkdir -p #{guarded_home_path}/.config/opencode"]
          },
          {
            env: {},
            cmd: ["docker", "exec", container_id, "sh", "-lc", remove_symlink_command("#{guarded_home_path}/.config/opencode/opencode.json")]
          },
          {
            env: {},
            cmd: ["docker", "exec", "-i", container_id, "sh", "-lc", "cat > #{guarded_home_path}/.config/opencode/opencode.json"],
            stdin: "{\"ok\":true}"
          },
          {
            env: {},
            cmd: ["docker", "exec", container_id, "echo", "hello"]
          },
          {
            env: {},
            cmd: ["docker", "exec", container_id, "sh", "-lc", cleanup_command("#{guarded_home_path}/.config/opencode/opencode.json", "#{guarded_home_path}/.config/opencode")]
          }
        ]
      )

      executor.execute(
        ["echo", "hello"],
        preparation: AgentHarness::ExecutionPreparation.new(
          file_writes: [{path: "~/.config/opencode/opencode.json", content: "{\"ok\":true}"}]
        )
      )
    end

    it "cleans up the current prepared file if container preparation fails after writing" do
      allow(SecureRandom).to receive(:hex).and_return("deadbeefcafebabe", "facefeedcafed00d", "beadfeedcafef00d")
      calls = []

      allow(Open3).to receive(:popen3) do |actual_env, *actual_cmd, &block|
        calls << {env: actual_env, cmd: actual_cmd}
        stderr = if actual_cmd == ["docker", "exec", container_id, "sh", "-lc", "chmod 600 #{guarded_home_path}/.config/opencode/opencode.json"]
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
          {env: {}, cmd: ["docker", "exec", container_id, "sh", "-lc", backup_command("#{guarded_home_path}/.config/opencode/opencode.json")]},
          {env: {}, cmd: ["docker", "exec", container_id, "sh", "-lc", "mkdir -p #{guarded_home_path}/.config/opencode"]},
          {env: {}, cmd: ["docker", "exec", container_id, "sh", "-lc", remove_symlink_command("#{guarded_home_path}/.config/opencode/opencode.json")]},
          {env: {}, cmd: ["docker", "exec", "-i", container_id, "sh", "-lc", "cat > #{guarded_home_path}/.config/opencode/opencode.json"]},
          {env: {}, cmd: ["docker", "exec", container_id, "sh", "-lc", "chmod 600 #{guarded_home_path}/.config/opencode/opencode.json"]},
          {env: {}, cmd: ["docker", "exec", container_id, "sh", "-lc", cleanup_command("#{guarded_home_path}/.config/opencode/opencode.json", "#{guarded_home_path}/.config/opencode")]}
        ]
      )
    end

    it "cleans up timed out container preparation in the background" do
      allow(SecureRandom).to receive(:hex).and_return("deadbeefcafebabe", "facefeedcafed00d", "beadfeedcafef00d")
      calls = Queue.new
      cleanup_started = Queue.new
      cleanup_finished = Queue.new
      cleanup_command_cmd = ["docker", "exec", container_id, "sh", "-lc", cleanup_command("#{guarded_home_path}/.config/opencode/opencode.json", "#{guarded_home_path}/.config/opencode")]
      preparation = AgentHarness::ExecutionPreparation.new(
        file_writes: [{path: "~/.config/opencode/opencode.json", content: "{\"ok\":true}"}]
      )
      lock_key = executor.send(:preparation_lock_keys, preparation, {}).fetch(0)

      allow(executor).to receive(:execute_with_timeout) do |cmd_array, timeout:, env:, stdin_data:, configured_timeout: timeout|
        calls << {cmd: cmd_array, timeout: timeout, env: env, stdin_data: stdin_data}

        if cmd_array == ["docker", "exec", container_id, "echo", "hello"]
          raise AgentHarness::TimeoutError, "Command timed out after #{timeout} seconds: echo"
        end

        if cmd_array == cleanup_command_cmd
          cleanup_started << timeout
          sleep 0.1
          cleanup_finished << true
        end

        ["output", "", instance_double(Process::Status, exitstatus: 0)]
      end

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect {
        executor.execute(
          ["echo", "hello"],
          timeout: 0.001,
          preparation: preparation
        )
      }.to raise_error(AgentHarness::TimeoutError)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      expect(elapsed).to be < 0.1
      cleanup_timeout = Timeout.timeout(3) { cleanup_started.pop }
      expect(cleanup_timeout).to be_within(0.05).of(AgentHarness::CommandExecutor::PREPARATION_CLEANUP_GRACE_PERIOD)
      expect(cleanup_finished).to be_empty
      Timeout.timeout(3) { cleanup_finished.pop }
      Timeout.timeout(3) do
        while AgentHarness::CommandExecutor::PREPARATION_LOCK_REGISTRY.key?(lock_key)
          sleep 0.01
        end
      end

      observed_calls = []
      observed_calls << calls.pop until calls.empty?

      expect(observed_calls.map { |call| call[:cmd] }).to eq(
        [
          ["docker", "exec", container_id, "sh", "-lc", backup_command("#{guarded_home_path}/.config/opencode/opencode.json")],
          ["docker", "exec", container_id, "sh", "-lc", "mkdir -p #{guarded_home_path}/.config/opencode"],
          ["docker", "exec", container_id, "sh", "-lc", remove_symlink_command("#{guarded_home_path}/.config/opencode/opencode.json")],
          ["docker", "exec", "-i", container_id, "sh", "-lc", "cat > #{guarded_home_path}/.config/opencode/opencode.json"],
          ["docker", "exec", container_id, "echo", "hello"],
          cleanup_command_cmd
        ]
      )
    end

    it "preserves the original timeout message for container commands after preparation" do
      allow(SecureRandom).to receive(:hex).and_return("deadbeefcafebabe", "facefeedcafed00d", "beadfeedcafef00d")

      allow(executor).to receive(:execute_with_timeout) do |cmd_array, timeout:, env:, stdin_data:, configured_timeout: timeout|
        if cmd_array == ["docker", "exec", container_id, "echo", "hello"]
          raise AgentHarness::TimeoutError, "Command timed out after #{timeout} seconds: docker"
        end

        [
          "output",
          "",
          instance_double(Process::Status, exitstatus: 0)
        ]
      end

      expect {
        executor.execute(
          ["echo", "hello"],
          timeout: 30,
          preparation: AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: "~/.config/opencode/opencode.json", content: "{\"ok\":true}"}]
          )
        )
      }.to raise_error(AgentHarness::TimeoutError, "Command timed out after 30 seconds: echo")
    end

    it "reports end-to-end duration including preparation and cleanup" do
      allow(executor).to receive(:apply_container_preparation) { sleep 0.02 }
      allow(executor).to receive(:cleanup_container_preparation) do |cleanup_steps, timeout:, deadline:, command_name:|
        cleanup_steps.clear
        sleep 0.02
      end

      expect_popen3_with(["docker", "exec", container_id, "echo", "hello"])

      result = executor.execute(["echo", "hello"])

      expect(result.duration).to be >= 0.04
    end

    it "restores originally existing symlinks after container execution" do
      allow(SecureRandom).to receive(:hex).and_return("deadbeefcafebabe", "facefeedcafed00d", "beadfeedcafef00d")

      expect_popen3_sequence(
        [
          {
            env: {},
            cmd: ["docker", "exec", container_id, "sh", "-lc", symlink_backup_command("#{guarded_home_path}/.config/opencode/opencode.json")]
          },
          {
            env: {},
            cmd: ["docker", "exec", container_id, "sh", "-lc", "mkdir -p #{guarded_home_path}/.config/opencode"]
          },
          {
            env: {},
            cmd: ["docker", "exec", container_id, "sh", "-lc", remove_symlink_command("#{guarded_home_path}/.config/opencode/opencode.json")]
          },
          {
            env: {},
            cmd: ["docker", "exec", "-i", container_id, "sh", "-lc", "cat > #{guarded_home_path}/.config/opencode/opencode.json"],
            stdin: "{\"ok\":true}"
          },
          {
            env: {},
            cmd: ["docker", "exec", container_id, "echo", "hello"]
          },
          {
            env: {},
            cmd: ["docker", "exec", container_id, "sh", "-lc", cleanup_command("#{guarded_home_path}/.config/opencode/opencode.json", "#{guarded_home_path}/.config/opencode")]
          }
        ]
      )

      executor.execute(
        ["echo", "hello"],
        preparation: AgentHarness::ExecutionPreparation.new(
          file_writes: [{path: "~/.config/opencode/opencode.json", content: "{\"ok\":true}"}]
        )
      )
    end

    it "does not delete an originally existing file when the cleanup backup is missing" do
      allow(SecureRandom).to receive(:hex).and_return("deadbeefcafebabe", "facefeedcafed00d", "beadfeedcafef00d")
      calls = []

      allow(Open3).to receive(:popen3) do |actual_env, *actual_cmd, &block|
        calls << {env: actual_env, cmd: actual_cmd}
        stderr = if actual_cmd == ["docker", "exec", container_id, "sh", "-lc", cleanup_command("#{guarded_home_path}/.config/opencode/opencode.json", "#{guarded_home_path}/.config/opencode")]
          StringIO.new("missing runtime preparation backup: /tmp/agent-harness-preparation-deadbeefcafebabe/backup")
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
            file_writes: [{path: "~/.config/opencode/opencode.json", content: "{\"ok\":true}"}]
          )
        )
      }.to raise_error(AgentHarness::CommandExecutionError, /missing runtime preparation backup/)

      expect(calls).to include(
        {env: {}, cmd: ["docker", "exec", container_id, "sh", "-lc", cleanup_command("#{guarded_home_path}/.config/opencode/opencode.json", "#{guarded_home_path}/.config/opencode")]},
        {env: {}, cmd: ["docker", "exec", container_id, "echo", "hello"]}
      )
    end

    it "fails cleanup when the prepared container path becomes a directory" do
      allow(SecureRandom).to receive(:hex).and_return("deadbeefcafebabe", "facefeedcafed00d", "beadfeedcafef00d")

      allow(Open3).to receive(:popen3) do |actual_env, *actual_cmd, &block|
        stderr = if actual_cmd == ["docker", "exec", container_id, "sh", "-lc", cleanup_command("#{guarded_home_path}/.config/opencode/opencode.json", "#{guarded_home_path}/.config/opencode")]
          StringIO.new("preparation target changed into a directory during execution: ~/.config/opencode/opencode.json")
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
            file_writes: [{path: "~/.config/opencode/opencode.json", content: "{\"ok\":true}"}]
          )
        )
      }.to raise_error(AgentHarness::CommandExecutionError, /preparation target changed into a directory/)
    end

    it "fails preparation when the target already exists as a directory" do
      allow(SecureRandom).to receive(:hex).and_return("deadbeefcafebabe")

      expected_calls = [
        {
          env: {},
          cmd: ["docker", "exec", container_id, "sh", "-lc", backup_command("#{guarded_home_path}/.config/opencode/opencode.json")],
          stderr: "preparation target must be a regular file or symlink: ~/.config/opencode/opencode.json",
          exit_code: 1
        },
        {
          env: {},
          cmd: ["docker", "exec", container_id, "sh", "-lc", "rm -rf /tmp/agent-harness-preparation-deadbeefcafebabe"],
          stderr: "",
          exit_code: 0
        }
      ]
      index = 0

      allow(Open3).to receive(:popen3) do |actual_env, *actual_cmd, &block|
        expected = expected_calls.fetch(index)
        index += 1

        expect(actual_env).to eq(expected[:env])
        expect(actual_cmd).to eq(expected[:cmd])

        stdin = StringIO.new
        stdout = StringIO.new("")
        stderr = StringIO.new(expected[:stderr])
        wait_thr = instance_double(Process::Waiter, value: instance_double(Process::Status, exitstatus: expected[:exit_code]))
        block.call(stdin, stdout, stderr, wait_thr)
      end

      expect {
        executor.execute(
          ["echo", "hello"],
          preparation: AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: "~/.config/opencode/opencode.json", content: "{\"ok\":true}"}]
          )
        )
      }.to raise_error(AgentHarness::CommandExecutionError, /preparation target must be a regular file or symlink/)

      expect(index).to eq(expected_calls.length)
    end

    it "handles string commands" do
      expect_popen3_with(["docker", "exec", container_id, "echo", "hello world"])
      executor.execute("echo hello\\ world")
    end

    it "serializes concurrent preparation for the same container path across execution and cleanup" do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, "config.json")
        File.binwrite(file_path, "old")

        request_signals = {}
        request_waits = {}

        allow(executor).to receive(:build_docker_command) do |command, env:, stdin_data:|
          request_id = env.fetch("REQUEST_ID")
          request_signals[request_id] = env.fetch("SIGNAL")
          request_waits[request_id] = env["WAIT"]
          command + [request_id]
        end
        allow(executor).to receive(:apply_container_preparation) do |preparation, timeout:, deadline:, env:, cleanup_steps:|
          write = preparation.file_writes.fetch(0)
          snapshot = File.exist?(file_path) ? File.binread(file_path) : nil
          cleanup_steps << {snapshot: snapshot}
          File.binwrite(file_path, write.content)
        end
        allow(executor).to receive(:cleanup_container_preparation) do |cleanup_steps, timeout:, deadline:, command_name:|
          cleanup_steps.reverse_each do |cleanup|
            File.binwrite(file_path, cleanup[:snapshot])
          end
          cleanup_steps.clear
        end
        allow(executor).to receive(:execute_without_timeout) do |cmd_array, env:, stdin_data:|
          request_id = cmd_array.last
          observed = File.binread(file_path)
          request_signals.fetch(request_id) << observed
          request_waits[request_id]&.pop
          ["", stdin_data.to_s, instance_double(Process::Status, exitstatus: 0)]
        end

        signal_a = Queue.new
        wait_a = Queue.new
        signal_b = Queue.new

        thread_a = Thread.new do
          executor.execute(
            ["true"],
            env: {"REQUEST_ID" => "A", "SIGNAL" => signal_a, "WAIT" => wait_a},
            preparation: AgentHarness::ExecutionPreparation.new(
              file_writes: [{path: "~/.config/opencode/opencode.json", content: "A"}]
            )
          )
        end

        expect(signal_a.pop).to eq("A")

        thread_b = Thread.new do
          executor.execute(
            ["true"],
            env: {"REQUEST_ID" => "B", "SIGNAL" => signal_b},
            preparation: AgentHarness::ExecutionPreparation.new(
              file_writes: [{path: "~/.config/opencode/opencode.json", content: "B"}]
            )
          )
        end

        sleep 0.05
        expect(signal_b).to be_empty

        wait_a << :continue

        thread_a.join
        expect(signal_b.pop).to eq("B")
        thread_b.join
        expect(File.binread(file_path)).to eq("old")
      end
    end

    it "does not serialize home-relative preparation across distinct explicit container HOME targets" do
      Dir.mktmpdir do |dir|
        resolve_file_path = lambda do |env|
          home = env.fetch("HOME", "/home/default")
          path = File.join(dir, home.delete_prefix("/"), ".config/opencode/opencode.json")
          FileUtils.mkdir_p(File.dirname(path))
          File.binwrite(path, "old") unless File.exist?(path)
          path
        end

        request_signals = {}
        request_waits = {}
        request_file_paths = {}

        allow(executor).to receive(:build_docker_command) do |command, env:, stdin_data:|
          request_id = env.fetch("REQUEST_ID")
          request_signals[request_id] = env.fetch("SIGNAL")
          request_waits[request_id] = env["WAIT"]
          request_file_paths[request_id] = resolve_file_path.call(env)
          command + [request_id]
        end
        allow(executor).to receive(:apply_container_preparation) do |preparation, timeout:, deadline:, env:, cleanup_steps:|
          write = preparation.file_writes.fetch(0)
          file_path = resolve_file_path.call(env)
          snapshot = File.exist?(file_path) ? File.binread(file_path) : nil
          cleanup_steps << {path: file_path, snapshot: snapshot}
          File.binwrite(file_path, write.content)
        end
        allow(executor).to receive(:cleanup_container_preparation) do |cleanup_steps, timeout:, deadline:, command_name:|
          cleanup_steps.reverse_each do |cleanup|
            next if cleanup[:snapshot].nil?

            File.binwrite(cleanup.fetch(:path), cleanup.fetch(:snapshot))
          end
          cleanup_steps.clear
        end
        allow(executor).to receive(:execute_without_timeout) do |cmd_array, env:, stdin_data:|
          request_id = cmd_array.last
          file_path = request_file_paths.fetch(request_id)
          observed = File.binread(file_path)
          request_signals.fetch(request_id) << observed
          request_waits[request_id]&.pop
          ["", stdin_data.to_s, instance_double(Process::Status, exitstatus: 0)]
        end

        signal_a = Queue.new
        wait_a = Queue.new
        signal_b = Queue.new

        thread_a = Thread.new do
          executor.execute(
            ["true"],
            env: {"REQUEST_ID" => "A", "SIGNAL" => signal_a, "WAIT" => wait_a, "HOME" => "/tmp/request-a"},
            preparation: AgentHarness::ExecutionPreparation.new(
              file_writes: [{path: "~/.config/opencode/opencode.json", content: "A"}]
            )
          )
        end

        expect(signal_a.pop).to eq("A")

        thread_b = Thread.new do
          executor.execute(
            ["true"],
            env: {"REQUEST_ID" => "B", "SIGNAL" => signal_b, "HOME" => "/tmp/request-b"},
            preparation: AgentHarness::ExecutionPreparation.new(
              file_writes: [{path: "~/.config/opencode/opencode.json", content: "B"}]
            )
          )
        end

        sleep 0.05
        expect(signal_b.pop).to eq("B")

        wait_a << :continue

        thread_a.join
        thread_b.join
        expect(File.binread(resolve_file_path.call("HOME" => "/tmp/request-a"))).to eq("old")
        expect(File.binread(resolve_file_path.call("HOME" => "/tmp/request-b"))).to eq("old")
      end
    end

    it "normalizes container lock paths for equivalent dot-segment spellings" do
      signal = Queue.new
      wait = Queue.new

      allow(executor).to receive(:apply_container_preparation)
      allow(executor).to receive(:cleanup_container_preparation)
      allow(executor).to receive(:execute_without_timeout) do |cmd_array, env:, stdin_data:|
        if cmd_array.last == "hold-a"
          signal << :entered
          wait.pop
        end
        ["", stdin_data.to_s, instance_double(Process::Status, exitstatus: 0)]
      end

      thread = Thread.new do
        executor.execute(
          ["echo", "hold-a"],
          preparation: AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: "~/./tmp/../.config/opencode.json", content: "A"}]
          )
        )
      end

      expect(signal.pop).to eq(:entered)

      expect {
        executor.execute(
          ["echo", "hold-b"],
          timeout: 0.01,
          preparation: AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: "~/.config/opencode.json", content: "B"}]
          )
        )
      }.to raise_error(AgentHarness::TimeoutError, /Command timed out after 0\.01 seconds: echo/)
    ensure
      wait << :continue
      thread&.join
    end

    it "counts lock acquisition wait against the timeout budget" do
      signal = Queue.new
      wait = Queue.new

      allow(executor).to receive(:apply_container_preparation)
      allow(executor).to receive(:cleanup_container_preparation)
      allow(executor).to receive(:execute_without_timeout) do |cmd_array, env:, stdin_data:|
        if cmd_array.last == "hold-a"
          signal.push(:entered)
          wait.pop
        end
        ["", stdin_data.to_s, instance_double(Process::Status, exitstatus: 0)]
      end

      thread = Thread.new do
        executor.execute(
          ["echo", "hold-a"],
          preparation: AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: "~/.config/opencode/opencode.json", content: "A"}]
          )
        )
      end

      expect(signal.pop).to eq(:entered)

      expect {
        executor.execute(
          ["echo", "hold-b"],
          timeout: 0.01,
          preparation: AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: "~/.config/opencode/opencode.json", content: "B"}]
          )
        )
      }.to raise_error(AgentHarness::TimeoutError, /Command timed out after 0\.01 seconds: echo/)
    ensure
      wait << :continue
      thread&.join
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

    def backup_command(path, requested_path: "~/.config/opencode/opencode.json")
      "umask 077 && mkdir -p /tmp/agent-harness-preparation-deadbeefcafebabe && if [ -L #{path} ]; then readlink #{path} > " \
        "/tmp/agent-harness-preparation-deadbeefcafebabe/symlink_target && printf symlink > " \
        "/tmp/agent-harness-preparation-deadbeefcafebabe/state; elif [ -d #{path} ]; then echo " \
        "\"preparation target must be a regular file or symlink: #{requested_path}\" >&2; exit 1; elif [ -e #{path} ]; then cp -p #{path} " \
        "/tmp/agent-harness-preparation-deadbeefcafebabe/backup && printf file > /tmp/agent-harness-preparation-deadbeefcafebabe/state; " \
        "else printf missing > /tmp/agent-harness-preparation-deadbeefcafebabe/state; fi"
    end

    def symlink_backup_command(path, requested_path: "~/.config/opencode/opencode.json")
      "umask 077 && mkdir -p /tmp/agent-harness-preparation-deadbeefcafebabe && if [ -L #{path} ]; then readlink #{path} > " \
        "/tmp/agent-harness-preparation-deadbeefcafebabe/symlink_target && printf symlink > " \
        "/tmp/agent-harness-preparation-deadbeefcafebabe/state; elif [ -d #{path} ]; then echo " \
        "\"preparation target must be a regular file or symlink: #{requested_path}\" >&2; exit 1; elif [ -e #{path} ]; then cp -p #{path} " \
        "/tmp/agent-harness-preparation-deadbeefcafebabe/backup && printf file > /tmp/agent-harness-preparation-deadbeefcafebabe/state; " \
        "else printf missing > /tmp/agent-harness-preparation-deadbeefcafebabe/state; fi"
    end

    def cleanup_command(path, dir, requested_path: "~/.config/opencode/opencode.json")
      "cleanup_status=0; state_value=$(cat /tmp/agent-harness-preparation-deadbeefcafebabe/state 2>/dev/null); " \
        "if [ -d #{path} ] && [ ! -L #{path} ]; then printf '%s\\n' " \
        "#{Shellwords.escape("preparation target changed into a directory during execution: #{requested_path}")} >&2; cleanup_status=1; " \
        "elif [ \"$state_value\" = symlink ]; then mkdir -p #{dir} && rm -f -- #{path} && " \
        "ln -s \"$(cat /tmp/agent-harness-preparation-deadbeefcafebabe/symlink_target)\" #{path} || cleanup_status=$?; " \
        "elif [ \"$state_value\" = file ]; then if [ -f /tmp/agent-harness-preparation-deadbeefcafebabe/backup ]; then mkdir -p #{dir} && rm -f -- #{path} && " \
        "cp -p /tmp/agent-harness-preparation-deadbeefcafebabe/backup #{path} || cleanup_status=$?; else echo " \
        "\"missing runtime preparation backup: /tmp/agent-harness-preparation-deadbeefcafebabe/backup\" >&2; cleanup_status=1; fi; " \
        "elif [ \"$state_value\" = missing ]; then rm -f -- #{path} || cleanup_status=$?; else cleanup_status=1; fi; rm -rf /tmp/agent-harness-preparation-deadbeefcafebabe; " \
        "exit $cleanup_status"
    end

    def remove_symlink_command(path)
      "state_value=$(cat /tmp/agent-harness-preparation-deadbeefcafebabe/state 2>/dev/null); if [ \"$state_value\" = symlink ]; then rm -f -- #{path}; fi"
    end

    def guarded_home_path
      "\"${HOME:?HOME cannot be nil or empty for home-relative preparation paths}\""
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
