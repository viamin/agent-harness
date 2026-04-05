# frozen_string_literal: true

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

      it "completes before timeout" do
        result = executor.execute(["echo", "quick"], timeout: 5)

        expect(result.success?).to be true
      end
    end

    context "with stdin_data" do
      it "sends data to stdin" do
        result = executor.execute(["cat"], stdin_data: "hello from stdin")

        expect(result.stdout).to eq("hello from stdin")
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

          allow(FileUtils).to receive(:mkdir_p).and_wrap_original do |original, *args|
            sleep 0.05
            original.call(*args)
          end

          expect {
            executor.execute(["true"], timeout: 0.01, preparation: preparation)
          }.to raise_error(AgentHarness::TimeoutError)
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
        end
      end

      it "counts cleanup time against the timeout budget" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "config.json")
          preparation = AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: file_path, content: "{\"ok\":true}"}]
          )

          allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC)
            .and_return(100.0, 100.0, 105.0, 110.0, 125.0)
          timeouts = []
          allow(Timeout).to receive(:timeout).and_wrap_original do |original, value, &block|
            timeouts << value
            original.call(value, &block)
          end

          result = executor.execute(["true"], timeout: 30, preparation: preparation)

          expect(result).to be_success
          expect(timeouts).to eq([25.0, 20.0, 5.0])
        end
      end

      it "cleans up prepared files after the main command timeout expires" do
        Dir.mktmpdir do |dir|
          file_path = File.join(dir, "config.json")
          preparation = AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: file_path, content: "{\"ok\":true}"}]
          )

          expect {
            executor.execute(["ruby", "-e", "sleep 0.05"], timeout: 0.001, preparation: preparation)
          }.to raise_error(AgentHarness::TimeoutError)

          expect(File.exist?(file_path)).to be false
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

          allow(executor).to receive(:execute_without_timeout) do |_cmd_array, env:, stdin_data:|
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
