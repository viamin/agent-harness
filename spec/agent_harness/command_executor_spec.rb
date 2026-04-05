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
            ["sh", "-c", "cat \"$1\"", "sh", file_path],
            preparation: preparation
          )

          expect(result.stdout).to eq("{\"ok\":true}")
          expect(File.stat(file_path).mode & 0o777).to eq(0o600)
        end
      end

      it "resolves home-relative file paths against request env overrides" do
        Dir.mktmpdir do |dir|
          preparation = AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: "~/.config/test.json", content: "{\"ok\":true}"}]
          )

          executor.execute(["true"], env: {"HOME" => dir}, preparation: preparation)

          expect(File.read(File.join(dir, ".config", "test.json"))).to eq("{\"ok\":true}")
        end
      end

      it "expands env vars in preparation paths against request env overrides" do
        Dir.mktmpdir do |dir|
          preparation = AgentHarness::ExecutionPreparation.new(
            file_writes: [{path: "$XDG_CONFIG_HOME/test.json", content: "{\"ok\":true}"}]
          )

          executor.execute(["true"], env: {"XDG_CONFIG_HOME" => dir}, preparation: preparation)

          expect(File.read(File.join(dir, "test.json"))).to eq("{\"ok\":true}")
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
