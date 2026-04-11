# frozen_string_literal: true

require "shellwords"
require "tmpdir"

RSpec.describe AgentHarness::CommandExecutor do
  subject(:executor) { described_class.new }

  before do
    FileUtils.rm_rf(described_class::PREPARATION_LOCK_ROOT)
  end

  after do
    FileUtils.rm_rf(described_class::PREPARATION_LOCK_ROOT)
  end

  describe "#execute" do
    it "executes a simple command" do
      result = executor.execute(["echo", "hello"])

      expect(result.stdout.strip).to eq("hello")
      expect(result.exit_code).to eq(0)
      expect(result.success?).to be true
    end

    it "captures stderr" do
      result = executor.execute(["sh", "-c", "echo error >&2"])

      expect(result.stderr.strip).to eq("error")
      expect(result.exit_code).to eq(0)
    end

    it "returns non-zero exit code for failing commands" do
      result = executor.execute(["sh", "-c", "exit 1"])

      expect(result.exit_code).to eq(1)
      expect(result.failed?).to be true
    end

    it "accepts string commands" do
      result = executor.execute("echo hello")

      expect(result.stdout.strip).to eq("hello")
    end

    it "tracks duration" do
      result = executor.execute(["sleep", "0.1"])

      expect(result.duration).to be >= 0.1
    end

    context "with timeout" do
      it "raises TimeoutError when command exceeds timeout" do
        expect {
          executor.execute(["sleep", "1"], timeout: 0.1)
        }.to raise_error(AgentHarness::TimeoutError)
      end

      it "terminates the entire process group when timing out shell-wrapped commands" do
        Dir.mktmpdir do |dir|
          pidfile = File.join(dir, "child.pid")

          expect {
            executor.execute(
              ["bash", "-c", "sleep 5 & echo $! > #{pidfile.shellescape}; wait"],
              timeout: 0.5
            )
          }.to raise_error(AgentHarness::TimeoutError)

          child_pid = Integer(File.read(pidfile).strip)

          expect {
            Timeout.timeout(2) do
              loop do
                process_state = `ps -o stat= -p #{child_pid}`.strip
                break if process_state.empty? || process_state.start_with?("Z")

                sleep 0.01
              end
            end
          }.not_to raise_error
        end
      end

      it "raises IdleTimeoutError when command stops producing output" do
        expect {
          executor.execute(
            ["ruby", "-e", "$stdout.sync = true; puts 'ready'; sleep 5"],
            timeout: 10,
            idle_timeout: 0.2
          )
        }.to raise_error(AgentHarness::IdleTimeoutError)
      end

      it "drains readable output before enforcing the idle timeout" do
        stdin = instance_double(IO, close: nil, closed?: false)
        stdout_io = instance_double(IO, close: nil)
        stderr_io = instance_double(IO, close: nil)
        status = instance_double(Process::Status, exitstatus: 0, success?: true)
        wait_thr = instance_double(Thread, value: status)

        allow(Open3).to receive(:popen3).and_yield(stdin, stdout_io, stderr_io, wait_thr)
        allow(executor).to receive(:selectable_streams?).and_return(true)
        allow(IO).to receive(:select).and_return(
          [[stdout_io, stderr_io], [stdin], nil],
          [[stdout_io], nil, nil]
        )
        # Return nil (not exited) during the main loop, then wait_thr (exited)
        # once streams are drained so supervise_process_exit is skipped
        allow(wait_thr).to receive(:join).with(0).and_return(nil, nil, wait_thr)
        allow(stdout_io).to receive(:read_nonblock).and_return("tick\n", nil)
        allow(stderr_io).to receive(:read_nonblock).and_return(nil)
        allow(executor).to receive(:monotonic_time).and_return(0.0, 0.05, 0.051, 0.06)

        result = executor.execute(["ruby", "-e", "puts 'tick'"], idle_timeout: 0.05)

        expect(result.stdout).to eq("tick\n")
      end

      it "does not raise a timeout after the process has already exited" do
        stdin = instance_double(IO, close: nil, closed?: false)
        stdout_io = instance_double(IO, close: nil)
        stderr_io = instance_double(IO, close: nil)
        status = instance_double(Process::Status, exitstatus: 0, success?: true)
        wait_thr = instance_double(Thread, value: status)

        allow(Open3).to receive(:popen3).and_yield(stdin, stdout_io, stderr_io, wait_thr)
        allow(executor).to receive(:selectable_streams?).and_return(true)
        # First select returns nil (no ready streams), triggering the exit check
        allow(IO).to receive(:select).with(anything, anything, anything, anything).and_return(nil)
        # Drain select during finalize returns EOF immediately
        allow(IO).to receive(:select).with([stdout_io, stderr_io], nil, nil, 0.1).and_return(
          [[stdout_io, stderr_io], nil, nil]
        )
        allow(stdout_io).to receive(:read_nonblock).and_return(nil)
        allow(stderr_io).to receive(:read_nonblock).and_return(nil)
        allow(wait_thr).to receive(:join).with(0).and_return(wait_thr)

        result = executor.execute(["ruby", "-e", "sleep 0.03"], timeout: 0.05, idle_timeout: 0.05)

        expect(result.exit_code).to eq(0)
      end

      it "enforces wall-clock timeout when draining an exited process with open descendants" do
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        expect {
          executor.execute(
            ["bash", "-c", "sleep 10 & wait"],
            timeout: 0.5
          )
        }.to raise_error(AgentHarness::TimeoutError)

        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        expect(elapsed).to be < 3
      end

      it "enforces idle timeout during post-exit drain of descendant-held pipes" do
        stdin = instance_double(IO, close: nil, closed?: false)
        stdout_io = instance_double(IO, close: nil)
        stderr_io = instance_double(IO, close: nil)
        wait_thr = double("wait thread", pid: 12_345)

        allow(Open3).to receive(:popen3).and_yield(stdin, stdout_io, stderr_io, wait_thr)
        allow(executor).to receive(:selectable_streams?).and_return(true)
        # First select returns nil so the loop checks for process exit
        allow(IO).to receive(:select).with(anything, anything, anything, anything).and_return(nil)
        # Process has exited, triggering finalize_exited_process
        allow(wait_thr).to receive(:join).with(0).and_return(wait_thr)
        # During drain, select keeps returning nil (descendants hold pipes but produce no data)
        allow(IO).to receive(:select).with([stdout_io, stderr_io], nil, nil, 0.1).and_return(nil)
        # Monotonic time advances past idle timeout
        allow(executor).to receive(:monotonic_time).and_return(0.0, 0.0, 0.06, 0.12)
        allow(executor).to receive(:terminate_process)

        expect {
          executor.execute(["cmd"], idle_timeout: 0.05)
        }.to raise_error(AgentHarness::IdleTimeoutError)
      end

      it "enforces wall-clock timeouts even while output stays readable" do
        stdin = instance_double(IO, close: nil, closed?: false)
        stdout_io = instance_double(IO, close: nil)
        stderr_io = instance_double(IO, close: nil)
        wait_thr = instance_double(Thread)

        allow(Open3).to receive(:popen3).and_yield(stdin, stdout_io, stderr_io, wait_thr)
        allow(executor).to receive(:selectable_streams?).and_return(true)
        allow(IO).to receive(:select).and_return(
          [[stdout_io, stderr_io], [stdin], nil],
          [[stdout_io], nil, nil]
        )
        allow(wait_thr).to receive(:join).with(0).and_return(nil)
        allow(stdout_io).to receive(:read_nonblock).and_return("tick\n", "tick\n")
        allow(stderr_io).to receive(:read_nonblock).and_return(nil, nil)
        allow(executor).to receive(:monotonic_time).and_return(0.0, 0.03, 0.031, 0.06)
        allow(executor).to receive(:terminate_process)

        expect {
          executor.execute(["ruby", "-e", "loop { puts 'tick' }"], timeout: 0.05)
        }.to raise_error(AgentHarness::TimeoutError)
      end

      it "enforces wall-clock timeout when child closes stdio but keeps running" do
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        expect {
          executor.execute(
            ["ruby", "-e", "$stdout.close; $stderr.close; sleep 10"],
            timeout: 0.5
          )
        }.to raise_error(AgentHarness::TimeoutError)

        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        expect(elapsed).to be < 3
      end

      it "enforces idle timeout when child closes stdio but keeps running" do
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        expect {
          executor.execute(
            ["ruby", "-e", "$stdout.sync = true; puts 'ready'; $stdout.close; $stderr.close; sleep 10"],
            idle_timeout: 0.3
          )
        }.to raise_error(AgentHarness::IdleTimeoutError)

        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        expect(elapsed).to be < 3
      end

      it "completes before timeout" do
        result = executor.execute(["echo", "quick"], timeout: 5)

        expect(result.success?).to be true
      end

      it "rejects non-positive timeout values" do
        expect {
          executor.execute(["echo", "quick"], timeout: 0)
        }.to raise_error(ArgumentError, /timeout must be a positive number/)
      end

      it "rejects non-positive idle timeout values" do
        expect {
          executor.execute(["echo", "quick"], idle_timeout: -1)
        }.to raise_error(ArgumentError, /idle_timeout must be a positive number/)
      end

      it "applies wall-clock timeouts while stdin is still being uploaded" do
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        expect {
          executor.execute(
            ["ruby", "-e", "sleep 5"],
            timeout: 0.5,
            stdin_data: "x" * 5_000_000
          )
        }.to raise_error(AgentHarness::TimeoutError)

        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        expect(elapsed).to be < 3
      end
    end

    context "with streaming hooks" do
      it "streams stdout and stderr chunks while returning the final result" do
        stdout_chunks = []
        stderr_chunks = []

        result = executor.execute(
          ["ruby", "-e", "$stdout.sync = true; $stderr.sync = true; puts 'out'; warn 'err'"],
          on_stdout_chunk: ->(chunk) { stdout_chunks << chunk },
          on_stderr_chunk: ->(chunk) { stderr_chunks << chunk }
        )

        expect(stdout_chunks.join).to include("out")
        expect(stderr_chunks.join).to include("err")
        expect(result.stdout).to include("out")
        expect(result.stderr).to include("err")
      end

      it "emits heartbeats while the command remains active" do
        heartbeats = []

        executor.execute(
          ["ruby", "-e", "sleep 0.5"],
          on_heartbeat: ->(**heartbeat) { heartbeats << heartbeat },
          heartbeat_interval: 0.1
        )

        expect(heartbeats).not_to be_empty
        expect(heartbeats).to all(include(:elapsed, :idle_for))
      end

      it "does not emit heartbeats after the process has exited" do
        stdin = instance_double(IO, close: nil, closed?: false)
        stdout_io = instance_double(IO, close: nil)
        stderr_io = instance_double(IO, close: nil)
        status = instance_double(Process::Status, exitstatus: 0, success?: true)
        wait_thr = instance_double(Thread, value: status)
        heartbeats = []

        allow(Open3).to receive(:popen3).and_yield(stdin, stdout_io, stderr_io, wait_thr)
        allow(executor).to receive(:selectable_streams?).and_return(true)
        allow(IO).to receive(:select).with(anything, anything, anything, anything).and_return(nil)
        allow(IO).to receive(:select).with([stdout_io, stderr_io], nil, nil, 0.1).and_return(
          [[stdout_io, stderr_io], nil, nil]
        )
        allow(stdout_io).to receive(:read_nonblock).and_return(nil)
        allow(stderr_io).to receive(:read_nonblock).and_return(nil)
        allow(wait_thr).to receive(:join).with(0).and_return(wait_thr)

        executor.execute(
          ["ruby", "-e", "sleep 0.12"],
          on_heartbeat: ->(**heartbeat) { heartbeats << heartbeat },
          heartbeat_interval: 0.05
        )

        expect(heartbeats).to be_empty
      end

      it "rejects non-positive heartbeat interval values" do
        expect {
          executor.execute(["echo", "quick"], heartbeat_interval: 0)
        }.to raise_error(ArgumentError, /heartbeat_interval must be a positive number/)
      end

      it "terminates the process before re-raising stdout callback failures" do
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        expect {
          executor.execute(
            ["ruby", "-e", "$stdout.sync = true; puts :hi; sleep 5"],
            on_stdout_chunk: ->(_chunk) { raise "boom" }
          )
        }.to raise_error(RuntimeError, "boom")

        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        expect(elapsed).to be < 3
      end

      it "terminates the process before re-raising heartbeat callback failures" do
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        expect {
          executor.execute(
            ["ruby", "-e", "sleep 5"],
            on_heartbeat: ->(**_heartbeat) { raise "boom" },
            heartbeat_interval: 0.1
          )
        }.to raise_error(RuntimeError, "boom")

        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        expect(elapsed).to be < 3
      end
    end

    context "with stdin_data" do
      it "sends data to stdin" do
        result = executor.execute(["cat"], stdin_data: "hello from stdin")

        expect(result.stdout).to eq("hello from stdin")
      end

      it "streams the original stdin string without duplicating it" do
        input = +"hello from stdin"
        stdin = instance_double(IO, close: nil, closed?: false)
        stdout = instance_double(IO, close: nil)
        stderr = instance_double(IO, close: nil)
        status = instance_double(Process::Status, exitstatus: 0, success?: true)
        wait_thr = instance_double(Thread, value: status)

        allow(Open3).to receive(:popen3).and_yield(stdin, stdout, stderr, wait_thr)
        allow(executor).to receive(:selectable_streams?).and_return(true)
        allow(IO).to receive(:select).and_return(
          [[], [stdin], nil],
          [[stdout, stderr], nil, nil]
        )
        # Return nil during the main loop, then wait_thr (exited) once streams are drained
        allow(wait_thr).to receive(:join).with(0).and_return(nil, nil, wait_thr)
        allow(stdin).to receive(:write_nonblock).and_return(input.bytesize)
        allow(stdout).to receive(:read_nonblock).and_return(nil)
        allow(stderr).to receive(:read_nonblock).and_return(nil)
        allow(executor).to receive(:monotonic_time).and_return(0.0, 0.01, 0.02)
        expect(executor).to receive(:write_stdin_nonblock).with(stdin, input, 0).and_call_original

        executor.execute(["cat"], stdin_data: input)
      end

      it "does not treat successful stdin writes as output activity for idle timeouts" do
        input = "x" * 8192
        stdin = instance_double(IO, close: nil, closed?: false)
        stdout = instance_double(IO, close: nil)
        stderr = instance_double(IO, close: nil)
        wait_thr = double("wait thread", pid: 12_345)

        allow(Open3).to receive(:popen3).and_yield(stdin, stdout, stderr, wait_thr)
        allow(executor).to receive(:selectable_streams?).and_return(true)
        allow(IO).to receive(:select).and_return(
          [[], [stdin], nil],
          [[], [stdin], nil],
          nil
        )
        allow(wait_thr).to receive(:join).with(0).and_return(nil, nil, nil)
        allow(stdin).to receive(:write_nonblock).and_return(4096, 4096)
        allow(executor).to receive(:monotonic_time).and_return(0.0, 0.02, 0.03, 0.06)
        allow(executor).to receive(:terminate_process)

        expect {
          executor.execute(["cat"], stdin_data: input, idle_timeout: 0.05)
        }.to raise_error(AgentHarness::IdleTimeoutError)
      end

      it "writes stdin data before buffered fallback reads output" do
        stdin = StringIO.new
        stdout = StringIO.new("buffered stdout")
        stderr = StringIO.new
        status = instance_double(Process::Status, exitstatus: 0, success?: true)
        wait_thr = instance_double(Thread, value: status)

        allow(Open3).to receive(:popen3).and_yield(stdin, stdout, stderr, wait_thr)

        result = executor.execute(["buffered-command"], stdin_data: "hello from stdin")

        expect(stdin).to be_closed
        expect(stdin.string).to eq("hello from stdin")
        expect(result.stdout).to eq("buffered stdout")
      end

      it "fails fast when buffered fallback cannot honor idle timeout supervision" do
        stdin = StringIO.new
        stdout = StringIO.new("buffered stdout")
        stderr = StringIO.new
        wait_thr = instance_double(Thread)

        allow(Open3).to receive(:popen3).and_yield(stdin, stdout, stderr, wait_thr)

        expect {
          executor.execute(["buffered-command"], idle_timeout: 1)
        }.to raise_error(ArgumentError, /does not support idle timeouts or heartbeats/)
      end

      it "fails fast when buffered fallback cannot honor heartbeats" do
        stdin = StringIO.new
        stdout = StringIO.new("buffered stdout")
        stderr = StringIO.new
        wait_thr = instance_double(Thread)

        allow(Open3).to receive(:popen3).and_yield(stdin, stdout, stderr, wait_thr)

        expect {
          executor.execute(
            ["buffered-command"],
            on_heartbeat: ->(**_heartbeat) {},
            heartbeat_interval: 1
          )
        }.to raise_error(ArgumentError, /does not support idle timeouts or heartbeats/)
      end
    end

    context "with environment variables" do
      it "passes environment variables" do
        result = executor.execute(["sh", "-c", "echo $MY_VAR"], env: {"MY_VAR" => "test_value"})

        expect(result.stdout.strip).to eq("test_value")
      end

      it "unsets inherited environment variables when given nil values" do
        original = ENV["AGENT_HARNESS_TEST_UNSET"]
        ENV["AGENT_HARNESS_TEST_UNSET"] = "inherited"

        result = executor.execute(
          ["sh", "-c", "printf '%s' \"${AGENT_HARNESS_TEST_UNSET-unset}\""],
          env: {"AGENT_HARNESS_TEST_UNSET" => nil}
        )

        expect(result.stdout).to eq("unset")
      ensure
        ENV["AGENT_HARNESS_TEST_UNSET"] = original
      end
    end

    context "with execution preparation" do
      it "materializes requested files before executing" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "config", "runtime.json")
          preparation = AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: file_path, content: "{\"ok\":true}", mode: 0o600}]
          )

          result = executor.execute(
            [
              "ruby",
              "-e",
              "path = ARGV.fetch(0); print File.binread(path); print '|'; print((File.stat(path).mode & 0o777).to_s(8))",
              file_path
            ],
            preparation: preparation
          )

          expect(result.stdout).to eq("{\"ok\":true}|600")
          expect(File.exist?(file_path)).to be false
        end
      end

      it "resolves home-relative file paths against request env overrides" do
        Dir.mktmpdir do |dir|
          preparation = AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: "~/.config/test.json", content: "{\"ok\":true}"}]
          )

          executor.execute(["true"], env: {"HOME" => dir}, preparation: preparation)

          expect(File.exist?(File.join(dir, ".config", "test.json"))).to be false
        end
      end

      it "removes empty parent directories created for request-scoped files" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "config", "nested", "runtime.json")
          preparation = AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: file_path, content: "{\"ok\":true}"}]
          )

          executor.execute(["true"], preparation: preparation)

          expect(File.exist?(file_path)).to be false
          expect(File.exist?(File.join(dir, "config", "nested"))).to be false
          expect(File.exist?(File.join(dir, "config"))).to be false
        end
      end

      it "rejects home-relative preparation paths when HOME is explicitly unset" do
        preparation = AgentHarness::ExecutionPreparation.new(
          file_writes: [{path: "~/.config/test.json", content: "{\"ok\":true}"}]
        )

        expect {
          executor.execute(["true"], env: {"HOME" => nil}, preparation: preparation)
        }.to raise_error(ArgumentError, /HOME cannot be nil or empty/)
      end

      it "expands env vars in preparation paths against request env overrides" do
        Dir.mktmpdir do |dir|
          preparation = AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: "$XDG_CONFIG_HOME/test.json", content: "{\"ok\":true}"}]
          )

          executor.execute(["true"], env: {"XDG_CONFIG_HOME" => dir}, preparation: preparation)

          expect(File.exist?(File.join(dir, "test.json"))).to be false
        end
      end

      it "rejects env-backed preparation paths when the env var is missing" do
        preparation = AgentHarness::ExecutionPreparation.new(
          file_writes: [{path: "$AGENT_HARNESS_TEST_CONFIG_HOME/test.json", content: "{\"ok\":true}"}]
        )

        expect {
          executor.execute(["true"], env: {}, preparation: preparation)
        }.to raise_error(ArgumentError, /AGENT_HARNESS_TEST_CONFIG_HOME cannot be nil or empty/)
      end

      it "does not fall back to ambient host env for env-backed preparation paths" do
        preparation = AgentHarness::ExecutionPreparation.new(
          file_writes: [{path: "$AGENT_HARNESS_TEST_CONFIG_HOME/test.json", content: "{\"ok\":true}"}]
        )
        original = ENV["AGENT_HARNESS_TEST_CONFIG_HOME"]
        ENV["AGENT_HARNESS_TEST_CONFIG_HOME"] = Dir.mktmpdir

        expect {
          executor.execute(["true"], env: {}, preparation: preparation)
        }.to raise_error(ArgumentError, /AGENT_HARNESS_TEST_CONFIG_HOME cannot be nil or empty/)
      ensure
        ENV["AGENT_HARNESS_TEST_CONFIG_HOME"] = original
      end

      it "rejects env-backed preparation paths when the env var is blank" do
        preparation = AgentHarness::ExecutionPreparation.new(
          file_writes: [{path: "$AGENT_HARNESS_TEST_CONFIG_HOME/test.json", content: "{\"ok\":true}"}]
        )

        expect {
          executor.execute(["true"], env: {"AGENT_HARNESS_TEST_CONFIG_HOME" => ""}, preparation: preparation)
        }.to raise_error(ArgumentError, /AGENT_HARNESS_TEST_CONFIG_HOME cannot be nil or empty/)
      end

      it "restores previously existing files after execution" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "config.json")
          FileUtils.mkdir_p(File.dirname(file_path))
          File.binwrite(file_path, "{\"before\":true}")
          File.chmod(0o644, file_path)
          preparation = AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: file_path, content: "{\"after\":true}", mode: 0o600}]
          )

          result = executor.execute(
            ["sh", "-c", "cat \"$1\"", "sh", file_path],
            preparation: preparation
          )

          expect(result.stdout).to eq("{\"after\":true}")
          expect(File.binread(file_path)).to eq("{\"before\":true}")
          expect(File.stat(file_path).mode & 0o777).to eq(0o644)
        end
      end

      it "restores previously existing files even if the command swaps them for symlinks" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "config.json")
          redirected_path = File.join(dir, "redirected.json")
          File.binwrite(file_path, "{\"before\":true}")
          File.binwrite(redirected_path, "{\"redirected\":true}")
          preparation = AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: file_path, content: "{\"after\":true}", mode: 0o600}]
          )

          result = executor.execute(
            ["ruby", "-e", "path, redirected = ARGV; File.delete(path); File.symlink(redirected, path); print File.binread(path)", file_path, redirected_path],
            preparation: preparation
          )

          expect(result.stdout).to eq("{\"redirected\":true}")
          expect(File.symlink?(file_path)).to be false
          expect(File.binread(file_path)).to eq("{\"before\":true}")
          expect(File.binread(redirected_path)).to eq("{\"redirected\":true}")
        end
      end

      it "restores previously existing symlinks after execution" do
        Dir.mktmpdir do |dir|
          target_path = File.join(dir, "managed.json")
          link_path = File.join(dir, "config.json")
          File.binwrite(target_path, "{\"managed\":true}")
          File.symlink(target_path, link_path)
          preparation = AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: link_path, content: "{\"runtime\":true}"}]
          )

          result = executor.execute(
            ["sh", "-c", "cat \"$1\"", "sh", link_path],
            preparation: preparation
          )

          expect(result.stdout).to eq("{\"runtime\":true}")
          expect(File.symlink?(link_path)).to be true
          expect(File.readlink(link_path)).to eq(target_path)
          expect(File.binread(target_path)).to eq("{\"managed\":true}")
        end
      end

      it "counts preparation time against the timeout budget" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "config.json")
          preparation = AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: file_path, content: "{\"ok\":true}"}]
          )

          allow(FileUtils).to receive(:mkdir_p).and_wrap_original do |original, *args, **kwargs|
            sleep 0.05
            original.call(*args, **kwargs)
          end

          expect {
            executor.execute(["true"], timeout: 0.01, preparation: preparation)
          }.to raise_error(AgentHarness::TimeoutError)
        end
      end

      it "counts snapshot time against the timeout budget for existing files" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "config.json")
          File.binwrite(file_path, "existing")
          preparation = AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: file_path, content: "{\"ok\":true}"}]
          )

          allow(FileUtils).to receive(:cp).and_wrap_original do |original, *args|
            sleep 0.05 if args.first == file_path && args.last == {preserve: true}
            original.call(*args)
          end

          expect {
            executor.execute(["true"], timeout: 0.01, preparation: preparation)
          }.to raise_error(AgentHarness::TimeoutError)

          expect(File.binread(file_path)).to eq("existing")
        end
      end

      it "preserves the configured timeout in timeout errors after preparation" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "config.json")
          preparation = AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: file_path, content: "{\"ok\":true}"}]
          )

          expect {
            executor.execute(["ruby", "-e", "sleep 0.05"], timeout: 0.01, preparation: preparation)
          }.to raise_error(AgentHarness::TimeoutError, /Command timed out after 0\.01 seconds: ruby/)

          Timeout.timeout(1) do
            sleep 0.01 while File.exist?(file_path)
          end
        end
      end

      it "removes newly prepared files after a timed out command without blocking past the timeout" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "config.json")
          preparation = AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: file_path, content: "{\"ok\":true}"}]
          )

          expect {
            executor.execute(["ruby", "-e", "sleep 0.05"], timeout: 0.01, preparation: preparation)
          }.to raise_error(AgentHarness::TimeoutError, /Command timed out after 0\.01 seconds: ruby/)

          Timeout.timeout(1) do
            sleep 0.01 while File.exist?(file_path)
          end

          expect(File.exist?(file_path)).to be false
        end
      end

      it "restores overwritten files after a timed out command" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "config.json")
          File.binwrite(file_path, "{\"before\":true}")
          preparation = AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: file_path, content: "{\"ok\":true}"}]
          )

          expect {
            executor.execute(["ruby", "-e", "sleep 0.05"], timeout: 0.01, preparation: preparation)
          }.to raise_error(AgentHarness::TimeoutError, /Command timed out after 0\.01 seconds: ruby/)

          Timeout.timeout(1) do
            sleep 0.01 until File.exist?(file_path) && File.binread(file_path) == "{\"before\":true}"
          end

          expect(File.binread(file_path)).to eq("{\"before\":true}")
        end
      end

      it "counts cleanup time against the timeout budget" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "config.json")
          preparation = AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: file_path, content: "{\"ok\":true}"}]
          )
          success_status = instance_double(Process::Status, exitstatus: 0)

          allow(executor).to receive(:execute_streaming).and_return(["", "", success_status])

          cleanup_deadlines = []
          allow(executor).to receive(:cleanup_preparation).and_wrap_original do |original, entries, command_name:, timeout: nil, deadline: nil|
            cleanup_deadlines << deadline
            original.call(entries, command_name: command_name, timeout: timeout, deadline: deadline)
          end

          result = executor.execute(["true"], timeout: 30, preparation: preparation)

          expect(result).to be_success
          expect(cleanup_deadlines.length).to eq(1)
        end
      end

      it "does not extend cleanup past the configured timeout" do
        expect(executor.send(:cleanup_deadline, 101.0, timeout: 1.0)).to eq(101.0)
      end

      it "returns success and schedules async cleanup when post-run cleanup times out" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "config.json")
          preparation = AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: file_path, content: "{\"ok\":true}"}]
          )
          cleanup_timeouts = Queue.new
          success_status = instance_double(Process::Status, exitstatus: 0)

          allow(executor).to receive(:execute_streaming).and_return(["", "", success_status])

          allow(executor).to receive(:cleanup_preparation).and_wrap_original do |original, applied_preparation, command_name:, timeout: nil, deadline: nil|
            if timeout && (timeout - 0.01).abs < Float::EPSILON
              raise AgentHarness::TimeoutError, "Command timed out after 0.01 seconds: true"
            end

            cleanup_timeouts << timeout
            original.call(applied_preparation, command_name: command_name, timeout: timeout, deadline: deadline)
          end

          result = executor.execute(["true"], timeout: 0.01, preparation: preparation)

          expect(result).to be_success
          expect(Timeout.timeout(1) { cleanup_timeouts.pop }).to eq(
            AgentHarness::CommandExecutor::PREPARATION_CLEANUP_GRACE_PERIOD
          )
          Timeout.timeout(1) do
            sleep 0.01 while File.exist?(file_path)
          end
        end
      end

      it "retries cleanup after restoring an existing file without requiring the backup again" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "config.json")
          File.binwrite(file_path, "{\"before\":true}")
          snapshot = executor.send(:snapshot_file_state, file_path)
          File.binwrite(file_path, "{\"runtime\":true}")
          applied_preparation = [{
            path: file_path,
            snapshot: snapshot,
            created_directories: []
          }]
          cleanup_attempts = 0

          allow(executor).to receive(:cleanup_created_directories).and_wrap_original do |original, directories|
            cleanup_attempts += 1
            raise AgentHarness::TimeoutError, "Command timed out after 0.01 seconds: true" if cleanup_attempts == 1

            original.call(directories)
          end

          expect {
            executor.send(:cleanup_preparation, applied_preparation, command_name: "true")
          }.to raise_error(AgentHarness::TimeoutError, /Command timed out after 0\.01 seconds: true/)

          expect(File.binread(file_path)).to eq("{\"before\":true}")
          expect {
            executor.send(:cleanup_preparation, applied_preparation, command_name: "true")
          }.not_to raise_error
          expect(File.binread(file_path)).to eq("{\"before\":true}")
        end
      end

      it "fails cleanup without deleting nested contents when the command replaces a prepared file with a directory" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "config.json")
          nested_file_path = File.join(file_path, "nested", "keep.txt")
          preparation = AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: file_path, content: "{\"ok\":true}"}]
          )

          expect {
            executor.execute(
              [
                "ruby", "-e",
                "path = ARGV.fetch(0); File.delete(path); Dir.mkdir(path); Dir.mkdir(File.join(path, 'nested')); " \
                  "File.write(File.join(path, 'nested', 'keep.txt'), 'keep')",
                file_path
              ],
              preparation: preparation
            )
          }.to raise_error(ArgumentError, /preparation target changed into a directory/)

          expect(File).to be_directory(file_path)
          expect(File.read(nested_file_path)).to eq("keep")
        end
      end

      it "restores files if preparation fails after writing" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "config.json")
          preparation = AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: file_path, content: "{\"ok\":true}", mode: 0o600}]
          )

          allow(File).to receive(:chmod).and_call_original
          allow(File).to receive(:chmod).with(0o600, file_path).and_raise(Errno::EPERM)

          expect {
            executor.execute(["true"], preparation: preparation)
          }.to raise_error(Errno::EPERM)

          expect(File.exist?(file_path)).to be false
        end
      end

      it "serializes concurrent preparation for the same path across execution and cleanup" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "config.json")
          File.binwrite(file_path, "old")

          allow(executor).to receive(:execute_streaming) do |_cmd_array, env:, stdin_data:, **|
            observed = File.binread(file_path)
            env.fetch("SIGNAL") << observed
            env["WAIT"]&.pop
            ["", stdin_data.to_s, instance_double(Process::Status, exitstatus: 0)]
          end

          signal_a = Queue.new
          wait_a = Queue.new
          signal_b = Queue.new

          thread_a = Thread.new do
            executor.execute(
              ["true"],
              env: {"SIGNAL" => signal_a, "WAIT" => wait_a},
              preparation: AgentHarness::ExecutionPreparation.new(
                file_writes: [{path: file_path, content: "A"}]
              )
            )
          end

          expect(signal_a.pop).to eq("A")

          thread_b = Thread.new do
            executor.execute(
              ["true"],
              env: {"SIGNAL" => signal_b},
              preparation: AgentHarness::ExecutionPreparation.new(
                file_writes: [{path: file_path, content: "B"}]
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

      it "counts lock acquisition wait against the timeout budget" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "config.json")
          signal = Queue.new
          wait = Queue.new

          allow(executor).to receive(:execute_streaming) do |_cmd_array, env:, stdin_data:, **|
            env["SIGNAL"]&.push(:entered)
            env["WAIT"]&.pop
            ["", stdin_data.to_s, instance_double(Process::Status, exitstatus: 0)]
          end

          thread = Thread.new do
            executor.execute(
              ["true"],
              env: {"SIGNAL" => signal, "WAIT" => wait},
              preparation: AgentHarness::ExecutionPreparation.new(
                file_writes: [{path: file_path, content: "A"}]
              )
            )
          end

          expect(signal.pop).to eq(:entered)

          expect {
            executor.execute(
              ["true"],
              timeout: 0.01,
              preparation: AgentHarness::ExecutionPreparation.new(
                file_writes: [{path: file_path, content: "B"}]
              )
            )
          }.to raise_error(AgentHarness::TimeoutError, /Command timed out after 0\.01 seconds: true/)
        ensure
          wait << :continue
          thread&.join
        end
      end

      it "serializes preparation locks across Ruby processes" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "config.json")
          preparation = AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: file_path, content: "A"}]
          )
          lock_key = executor.send(:preparation_lock_keys, preparation, {}).fetch(0)
          held_lock = executor.send(
            :acquire_preparation_lock,
            lock_key,
            timeout: nil,
            deadline: nil,
            command_name: "true"
          )
          script = <<~RUBY
            require "agent_harness"

            preparation = AgentHarness::ExecutionPreparation.new(
              file_writes: [{path: #{file_path.inspect}, content: "B"}]
            )

            begin
              AgentHarness::CommandExecutor.new.execute(["true"], timeout: 0.05, preparation: preparation)
              puts "success"
            rescue => e
              puts "\#{e.class}: \#{e.message}"
            end
          RUBY

          stdout, stderr, status = Open3.capture3(
            RbConfig.ruby,
            "-I",
            File.expand_path("../../lib", __dir__),
            "-e",
            script
          )

          expect(status.success?).to be true
          expect(stderr).to eq("")
          expect(stdout.strip).to eq("AgentHarness::TimeoutError: Command timed out after 0.05 seconds: true")
        ensure
          executor.send(:release_preparation_locks, [held_lock]) if held_lock
        end
      end

      it "releases earlier preparation locks when a later acquisition times out" do
        Dir.mktmpdir do |dir|
          first_path = File.join(dir, "a.json")
          second_path = File.join(dir, "b.json")
          first_key = "host:#{File.expand_path(first_path)}"
          second_key = "host:#{File.expand_path(second_path)}"
          blocked_lock = executor.send(
            :acquire_preparation_lock,
            second_key,
            timeout: nil,
            deadline: nil,
            command_name: "true"
          )

          expect {
            executor.send(
              :acquire_preparation_locks,
              AgentHarness::ExecutionPreparation.new(
                file_writes: [
                  {path: first_path, content: "A"},
                  {path: second_path, content: "B"}
                ]
              ),
              env: {},
              timeout: 0.01,
              deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.01,
              command_name: "true"
            )
          }.to raise_error(AgentHarness::TimeoutError, /Command timed out after 0\.01 seconds: true/)

          reacquired_lock = executor.send(
            :acquire_preparation_lock,
            first_key,
            timeout: 0.05,
            deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.05,
            command_name: "true"
          )
          executor.send(:release_preparation_locks, [reacquired_lock])
        ensure
          executor.send(:release_preparation_locks, [blocked_lock]) if blocked_lock
        end
      end
      it "surfaces cleanup errors during exception unwinding instead of silently suppressing them" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "config.json")
          preparation = AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: file_path, content: "{\"ok\":true}"}]
          )

          allow(executor).to receive(:execute_streaming).and_raise(
            AgentHarness::TimeoutError, "Command timed out after 1 seconds: test"
          )
          allow(executor).to receive(:restore_file_state).and_raise(
            Errno::EACCES, "Permission denied"
          )

          expect {
            executor.execute(["test"], timeout: 1, preparation: preparation)
          }.to raise_error(AgentHarness::TimeoutError, /cleanup also failed.*Permission denied/)
        end
      end

      it "rejects preparation paths containing backticks" do
        preparation = AgentHarness::ExecutionPreparation.new(
          file_writes: [{path: "/tmp/`whoami`/config.json", content: "{}"}]
        )

        expect {
          executor.execute(["true"], preparation: preparation)
        }.to raise_error(ArgumentError, /backtick/)
      end

      it "rejects preparation paths containing semicolons" do
        preparation = AgentHarness::ExecutionPreparation.new(
          file_writes: [{path: "/tmp/;rm -rf /;/config.json", content: "{}"}]
        )

        expect {
          executor.execute(["true"], preparation: preparation)
        }.to raise_error(ArgumentError, /semicolon/)
      end

      it "rejects preparation paths containing pipes" do
        preparation = AgentHarness::ExecutionPreparation.new(
          file_writes: [{path: "/tmp/|cat /etc/passwd|/config.json", content: "{}"}]
        )

        expect {
          executor.execute(["true"], preparation: preparation)
        }.to raise_error(ArgumentError, /pipe/)
      end

      it "rejects preparation paths containing path traversal" do
        preparation = AgentHarness::ExecutionPreparation.new(
          file_writes: [{path: "/tmp/../../../etc/passwd", content: "{}"}]
        )

        expect {
          executor.execute(["true"], preparation: preparation)
        }.to raise_error(ArgumentError, /path traversal/)
      end

      it "rejects env-var-prefixed paths containing literal traversal sequences" do
        preparation = AgentHarness::ExecutionPreparation.new(
          file_writes: [{path: "$CONFIG_DIR/../../../etc/passwd", content: "{}"}]
        )

        expect {
          executor.execute(["true"], env: {"CONFIG_DIR" => "/opt/app"}, preparation: preparation)
        }.to raise_error(ArgumentError, /path traversal/)
      end

      it "rejects preparation paths containing command substitution" do
        preparation = AgentHarness::ExecutionPreparation.new(
          file_writes: [{path: "/tmp/$(whoami)/config.json", content: "{}"}]
        )

        expect {
          executor.execute(["true"], preparation: preparation)
        }.to raise_error(ArgumentError, /command substitution/)
      end

      it "rejects preparation paths containing null bytes" do
        preparation = AgentHarness::ExecutionPreparation.new(
          file_writes: [{path: "/tmp/config\x00.json", content: "{}"}]
        )

        expect {
          executor.execute(["true"], preparation: preparation)
        }.to raise_error(ArgumentError, /null bytes/)
      end

      it "rejects preparation paths containing newlines" do
        preparation = AgentHarness::ExecutionPreparation.new(
          file_writes: [{path: "/tmp/con\nfig.json", content: "{}"}]
        )

        expect {
          executor.execute(["true"], preparation: preparation)
        }.to raise_error(ArgumentError, /newline/)
      end

      it "rejects preparation paths containing carriage returns" do
        preparation = AgentHarness::ExecutionPreparation.new(
          file_writes: [{path: "/tmp/con\rfig.json", content: "{}"}]
        )

        expect {
          executor.execute(["true"], preparation: preparation)
        }.to raise_error(ArgumentError, /carriage return/)
      end

      it "rejects env-backed preparation paths when the env value contains path traversal" do
        preparation = AgentHarness::ExecutionPreparation.new(
          file_writes: [{path: "$TRaversal_VAR/config.json", content: "{}"}]
        )

        expect {
          executor.execute(["true"], env: {"TRaversal_VAR" => "/tmp/../../etc"}, preparation: preparation)
        }.to raise_error(ArgumentError, /path traversal/)
      end

      it "rejects home-relative preparation paths when HOME contains path traversal" do
        preparation = AgentHarness::ExecutionPreparation.new(
          file_writes: [{path: "~/.config/test.json", content: "{}"}]
        )

        expect {
          executor.execute(["true"], env: {"HOME" => "/tmp/../../etc"}, preparation: preparation)
        }.to raise_error(ArgumentError, /path traversal/)
      end

      it "allows env-var prefixed paths that may contain dots after expansion" do
        Dir.mktmpdir do |dir|
          preparation = AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: "$TEST_DOT_VAR/config.json", content: "{\"ok\":true}"}]
          )

          executor.execute(["true"], env: {"TEST_DOT_VAR" => dir}, preparation: preparation)

          expect(File.exist?(File.join(dir, "config.json"))).to be false
        end
      end
    end
  end

  describe "#which" do
    it "finds existing binaries" do
      path = executor.which("ruby")
      expect(path).not_to be_nil
      expect(File.executable?(path)).to be true
    end

    it "returns nil for non-existent binaries" do
      path = executor.which("nonexistent_binary_xyz123")
      expect(path).to be_nil
    end
  end

  describe "#available?" do
    it "returns true for existing binaries" do
      expect(executor.available?("ruby")).to be true
    end

    it "returns false for non-existent binaries" do
      expect(executor.available?("nonexistent_binary_xyz123")).to be false
    end
  end

  describe "#execute process management" do
    it "spawns commands in their own process group" do
      result = executor.execute(["ruby", "-e", "puts Process.getpgrp"], timeout: 5)
      child_pgrp = result.stdout.strip.to_i
      expect(child_pgrp).not_to eq(Process.getpgrp)
    end

    it "terminates the child process on timeout" do
      expect {
        executor.execute(["sleep", "60"], timeout: 0.1)
      }.to raise_error(AgentHarness::TimeoutError, /Command timed out/)
    end
  end
end
