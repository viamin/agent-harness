# frozen_string_literal: true

require "open3"
require "timeout"
require "shellwords"

module AgentHarness
  # Executes shell commands with timeout support
  #
  # Provides a clean interface for running CLI commands with proper
  # error handling, timeout support, and result capture.
  #
  # @example Basic usage
  #   executor = AgentHarness::CommandExecutor.new
  #   result = executor.execute(["claude", "--print", "--prompt", "Hello"])
  #   puts result.stdout
  #
  # @example With timeout
  #   result = executor.execute("claude --print", timeout: 300)
  class CommandExecutor
    # Result of a command execution
    Result = Struct.new(:stdout, :stderr, :exit_code, :duration, keyword_init: true) do
      def success?
        exit_code == 0
      end

      def failed?
        !success?
      end
    end

    attr_reader :logger

    def initialize(logger: nil)
      @logger = logger
    end

    # Execute a command with optional timeout
    #
    # @param command [Array<String>, String] command to execute
    # @param timeout [Integer, nil] timeout in seconds
    # @param env [Hash] environment variables
    # @param stdin_data [String, nil] data to send to stdin
    # @return [Result] execution result
    # @raise [TimeoutError] if the command times out
    def execute(command, timeout: nil, env: {}, stdin_data: nil)
      cmd_array = normalize_command(command)
      cmd_string = cmd_array.shelljoin

      log_debug("Executing command", command: cmd_string, timeout: timeout)

      start_time = Time.now

      stdout, stderr, status = if timeout
        execute_with_timeout(cmd_array, timeout: timeout, env: env, stdin_data: stdin_data)
      else
        execute_without_timeout(cmd_array, env: env, stdin_data: stdin_data)
      end

      duration = Time.now - start_time

      Result.new(
        stdout: stdout,
        stderr: stderr,
        exit_code: status.exitstatus,
        duration: duration
      )
    end

    # Check if a binary exists in PATH
    #
    # @param binary [String] binary name
    # @return [String, nil] full path or nil
    def which(binary)
      ENV["PATH"].split(File::PATH_SEPARATOR).each do |path|
        full_path = File.join(path, binary)
        return full_path if File.executable?(full_path)
      end
      nil
    end

    # Check if a binary is available
    #
    # @param binary [String] binary name
    # @return [Boolean] true if available
    def available?(binary)
      !which(binary).nil?
    end

    private

    def normalize_command(command)
      case command
      when Array
        command.map(&:to_s)
      when String
        Shellwords.split(command)
      else
        raise ArgumentError, "Command must be Array or String"
      end
    end

    def execute_with_timeout(cmd_array, timeout:, env:, stdin_data:)
      stdout = ""
      stderr = ""
      status = nil

      Timeout.timeout(timeout) do
        Open3.popen3(env, *cmd_array) do |stdin, stdout_io, stderr_io, wait_thr|
          if stdin_data
            stdin.write(stdin_data)
            stdin.close
          else
            stdin.close
          end

          # Read output streams
          stdout = stdout_io.read
          stderr = stderr_io.read
          status = wait_thr.value
        end
      end

      [stdout, stderr, status]
    rescue Timeout::Error
      raise TimeoutError, "Command timed out after #{timeout} seconds: #{cmd_array.first}"
    end

    def execute_without_timeout(cmd_array, env:, stdin_data:)
      Open3.popen3(env, *cmd_array) do |stdin, stdout_io, stderr_io, wait_thr|
        if stdin_data
          stdin.write(stdin_data)
          stdin.close
        else
          stdin.close
        end

        stdout = stdout_io.read
        stderr = stderr_io.read
        status = wait_thr.value

        [stdout, stderr, status]
      end
    end

    def log_debug(message, **context)
      @logger&.debug("[AgentHarness::CommandExecutor] #{message}: #{context.inspect}")
    end
  end
end
