# frozen_string_literal: true

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
