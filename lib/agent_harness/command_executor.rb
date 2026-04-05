# frozen_string_literal: true

require "open3"
require "timeout"
require "shellwords"
require "fileutils"

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
    PREPARATION_LOCK_REGISTRY_MUTEX = Mutex.new
    PREPARATION_LOCK_REGISTRY = {}

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
    # @param preparation [ExecutionPreparation, nil] request-scoped bootstrap
    #   work for the runtime environment
    # @return [Result] execution result
    # @raise [TimeoutError] if the command times out
    def execute(command, timeout: nil, env: {}, stdin_data: nil, preparation: nil)
      cmd_array = normalize_command(command)
      cmd_string = cmd_array.shelljoin
      start_time = current_time
      deadline = timeout_deadline(timeout)
      applied_preparation = []
      held_preparation_locks = []

      log_debug("Executing command", command: cmd_string, timeout: timeout)
      held_preparation_locks = acquire_preparation_locks(preparation, env: env)
      apply_preparation(
        preparation,
        env: env,
        timeout: timeout,
        deadline: deadline,
        command_name: cmd_array.first,
        applied_preparation: applied_preparation
      )

      stdout, stderr, status = if timeout
        execute_with_timeout(
          cmd_array,
          timeout: remaining_timeout(deadline, timeout:, command_name: cmd_array.first),
          env: env,
          stdin_data: stdin_data
        )
      else
        execute_without_timeout(cmd_array, env: env, stdin_data: stdin_data)
      end

      cleanup_preparation(applied_preparation, command_name: cmd_array.first, timeout: timeout, deadline: deadline)
      duration = current_time - start_time

      Result.new(
        stdout: stdout,
        stderr: stderr,
        exit_code: status.exitstatus,
        duration: duration
      )
    ensure
      pending_exception = $!
      unless applied_preparation.nil? || applied_preparation.empty?
        begin
          cleanup_preparation(
            applied_preparation,
            command_name: cmd_array.first,
            timeout: timeout,
            deadline: deadline
          )
        rescue => e
          raise e if pending_exception.nil?

          log_debug("Failed to clean up runtime preparation", error: e.message)
        end
      end
      release_preparation_locks(held_preparation_locks) unless held_preparation_locks.nil? || held_preparation_locks.empty?
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

    protected

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

    private

    def acquire_preparation_locks(preparation, env:)
      return [] if preparation.nil? || preparation.empty?

      preparation_lock_keys(preparation, env).map do |key|
        entry = PREPARATION_LOCK_REGISTRY_MUTEX.synchronize do
          PREPARATION_LOCK_REGISTRY[key] ||= {mutex: Mutex.new, refcount: 0}
          PREPARATION_LOCK_REGISTRY[key][:refcount] += 1
          PREPARATION_LOCK_REGISTRY[key]
        end
        entry[:mutex].lock
        {key: key, mutex: entry[:mutex]}
      end
    end

    def release_preparation_locks(held_preparation_locks)
      held_preparation_locks.reverse_each do |lock|
        lock[:mutex].unlock
        PREPARATION_LOCK_REGISTRY_MUTEX.synchronize do
          entry = PREPARATION_LOCK_REGISTRY[lock[:key]]
          next unless entry

          entry[:refcount] -= 1
          PREPARATION_LOCK_REGISTRY.delete(lock[:key]) if entry[:refcount].zero?
        end
      end
    end

    def preparation_lock_keys(preparation, env)
      preparation.file_writes.map do |write|
        "#{preparation_lock_scope}:#{expand_preparation_path(write.path, env)}"
      end.uniq.sort
    end

    def preparation_lock_scope
      "host"
    end

    def apply_preparation(preparation, env:, timeout:, deadline:, command_name:, applied_preparation:)
      return if preparation.nil? || preparation.empty?

      preparation.file_writes.each do |write|
        resolved_path = expand_preparation_path(write.path, env)
        snapshot = snapshot_file_state(resolved_path)
        applied_preparation << {path: resolved_path, snapshot:}

        within_timeout(deadline, timeout:, command_name:) do
          FileUtils.mkdir_p(File.dirname(resolved_path))
          File.binwrite(resolved_path, write.content)
          File.chmod(write.mode, resolved_path) if write.mode
        end
      rescue => e
        begin
          cleanup_preparation(
            applied_preparation,
            command_name: command_name,
            timeout: timeout,
            deadline: deadline
          )
        rescue => cleanup_error
          log_debug("Failed to clean up runtime preparation", error: cleanup_error.message)
        end
        raise e
      end
    end

    def cleanup_preparation(applied_preparation, command_name:, timeout: nil, deadline: nil)
      applied_preparation.reverse_each do |entry|
        within_timeout(deadline, timeout:, command_name:) do
          restore_file_state(entry[:path], entry[:snapshot])
        end
      end
      applied_preparation.clear
    end

    def expand_preparation_path(path, env)
      expanded_path = path.gsub(/\$(\w+)|\$\{([^}]+)\}/) do
        key = Regexp.last_match(1) || Regexp.last_match(2)
        env.fetch(key) { ENV[key] }.to_s
      end

      home = env.key?("HOME") ? env["HOME"] : ENV["HOME"]
      if expanded_path == "~"
        return File.expand_path(home || expanded_path)
      end

      if expanded_path.start_with?("~/")
        return File.expand_path(File.join(home || Dir.home, expanded_path.delete_prefix("~/")))
      end

      File.expand_path(expanded_path)
    end

    def snapshot_file_state(path)
      return {existed: false} unless File.exist?(path)

      {
        existed: true,
        content: File.binread(path),
        mode: File.stat(path).mode & 0o777
      }
    end

    def restore_file_state(path, snapshot)
      if snapshot[:existed]
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, snapshot[:content])
        File.chmod(snapshot[:mode], path)
      elsif File.exist?(path)
        File.delete(path)
      end
    end

    def timeout_deadline(timeout)
      return nil if timeout.nil?

      current_time + timeout
    end

    def remaining_timeout(deadline, timeout:, command_name:)
      return nil if deadline.nil?

      remaining = deadline - current_time
      raise TimeoutError, "Command timed out after #{timeout} seconds: #{command_name}" if remaining <= 0

      remaining
    end

    def within_timeout(deadline, timeout:, command_name:)
      remaining = remaining_timeout(deadline, timeout:, command_name:)
      return yield if remaining.nil?

      Timeout.timeout(remaining) { yield }
    rescue Timeout::Error
      raise TimeoutError, "Command timed out after #{timeout} seconds: #{command_name}"
    end

    def current_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def execute_with_timeout(cmd_array, timeout:, env:, stdin_data:)
      stdout = ""
      stderr = ""
      status = nil

      Timeout.timeout(timeout) do
        Open3.popen3(env, *cmd_array) do |stdin, stdout_io, stderr_io, wait_thr|
          if stdin_data
            stdin.write(stdin_data)
          end
          stdin.close

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
        end
        stdin.close

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
