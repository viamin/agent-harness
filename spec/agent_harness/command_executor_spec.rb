# frozen_string_literal: true

require "shellwords"
require "tmpdir"

RSpec.describe AgentHarness::CommandExecutor do
  subject(:executor) { described_class.new }

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
              ["bash", "-lc", "sleep 5 & echo $! > #{pidfile.shellescape}; wait"],
              timeout: 0.2
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
            ["ruby", "-e", "$stdout.sync = true; puts 'ready'; sleep 0.3"],
            timeout: 5,
            idle_timeout: 0.1
          )
        }.to raise_error(AgentHarness::IdleTimeoutError)
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
            timeout: 0.2,
            stdin_data: "x" * 5_000_000
          )
        }.to raise_error(AgentHarness::TimeoutError)

        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        expect(elapsed).to be < 2
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
          ["ruby", "-e", "sleep 0.2"],
          on_heartbeat: ->(**heartbeat) { heartbeats << heartbeat },
          heartbeat_interval: 0.05
        )

        expect(heartbeats).not_to be_empty
        expect(heartbeats).to all(include(:elapsed, :idle_for))
      end

      it "rejects non-positive heartbeat interval values" do
        expect {
          executor.execute(["echo", "quick"], heartbeat_interval: 0)
        }.to raise_error(ArgumentError, /heartbeat_interval must be a positive number/)
      end
    end

    context "with stdin_data" do
      it "sends data to stdin" do
        result = executor.execute(["cat"], stdin_data: "hello from stdin")

        expect(result.stdout).to eq("hello from stdin")
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
end
