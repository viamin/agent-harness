# frozen_string_literal: true

require "open3"
require "timeout"
require "shellwords"
require "fileutils"
require "tempfile"

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
    PREPARATION_LOCK_POLL_INTERVAL = 0.01
    PREPARATION_CLEANUP_GRACE_PERIOD = 5

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
      cmd_array = nil
      cmd_array = normalize_command(command)
      cmd_string = cmd_array.shelljoin
      command_name = cmd_array.first
      start_time = current_time
      deadline = timeout_deadline(timeout)
      applied_preparation = []
      held_preparation_locks = []
      background_cleanup_scheduled = false

      log_debug("Executing command", command: cmd_string, timeout: timeout)
      held_preparation_locks = acquire_preparation_locks(
        preparation,
        env: env,
        timeout: timeout,
        deadline: deadline,
        command_name: command_name
      )
      apply_preparation(
        preparation,
        env: env,
        timeout: timeout,
        deadline: deadline,
        command_name: command_name,
        applied_preparation: applied_preparation
      )

      stdout, stderr, status = if timeout
        execute_with_timeout(
          cmd_array,
          timeout: remaining_timeout(deadline, timeout:, command_name: command_name),
          configured_timeout: timeout,
          env: env,
          stdin_data: stdin_data
        )
      else
        execute_without_timeout(cmd_array, env: env, stdin_data: stdin_data)
      end

      cleanup_preparation(
        applied_preparation,
        command_name: command_name,
        timeout: timeout,
        deadline: cleanup_deadline(deadline, timeout:)
      )
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
            command_name: command_name,
            timeout: timeout,
            deadline: cleanup_deadline(deadline, timeout:)
          )
        rescue TimeoutError => e
          raise e if pending_exception.nil? || !pending_exception.is_a?(TimeoutError)

          schedule_cleanup_preparation(
            applied_preparation,
            held_preparation_locks,
            command_name: command_name
          )
          background_cleanup_scheduled = true
          held_preparation_locks = []
        rescue => e
          raise e if pending_exception.nil?

          log_debug("Failed to clean up runtime preparation", error: e.message)
        end
      end
      unless background_cleanup_scheduled || held_preparation_locks.nil? || held_preparation_locks.empty?
        release_preparation_locks(held_preparation_locks)
      end
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

    def acquire_preparation_locks(preparation, env:, timeout:, deadline:, command_name:)
      return [] if preparation.nil? || preparation.empty?

      preparation_lock_keys(preparation, env).map do |key|
        acquire_preparation_lock(key, timeout:, deadline:, command_name:)
      end
    end

    def acquire_preparation_lock(key, timeout:, deadline:, command_name:)
      entry = PREPARATION_LOCK_REGISTRY_MUTEX.synchronize do
        PREPARATION_LOCK_REGISTRY[key] ||= {mutex: Mutex.new, refcount: 0}
        PREPARATION_LOCK_REGISTRY[key][:refcount] += 1
        PREPARATION_LOCK_REGISTRY[key]
      end

      if timeout.nil?
        entry[:mutex].lock
      else
        until entry[:mutex].try_lock
          remaining = remaining_timeout(deadline, timeout:, command_name:)
          sleep([PREPARATION_LOCK_POLL_INTERVAL, remaining].min)
        end
      end

      {key: key, mutex: entry[:mutex]}
    rescue
      PREPARATION_LOCK_REGISTRY_MUTEX.synchronize do
        registry_entry = PREPARATION_LOCK_REGISTRY[key]
        next unless registry_entry

        registry_entry[:refcount] -= 1
        PREPARATION_LOCK_REGISTRY.delete(key) if registry_entry[:refcount].zero?
      end
      raise
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
        snapshot = within_timeout(deadline, timeout:, command_name:) do
          snapshot_file_state(resolved_path)
        end
        applied_preparation << {path: resolved_path, snapshot: snapshot}

        within_timeout(deadline, timeout:, command_name:) do
          FileUtils.mkdir_p(File.dirname(resolved_path))
          delete_preparation_path(resolved_path) if snapshot[:type] == :symlink
          File.binwrite(resolved_path, write.content)
          File.chmod(write.mode, resolved_path) if write.mode
        end
      rescue => e
        begin
          cleanup_preparation(
            applied_preparation,
            command_name: command_name,
            timeout: timeout,
            deadline: cleanup_deadline(deadline, timeout:)
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

    def schedule_cleanup_preparation(applied_preparation, held_preparation_locks, command_name:)
      cleanup_deadline = timeout_deadline(PREPARATION_CLEANUP_GRACE_PERIOD)
      Thread.new(applied_preparation, held_preparation_locks, cleanup_deadline, command_name) do |entries, locks, deadline_at, cleanup_command_name|
        Thread.current.report_on_exception = false if Thread.current.respond_to?(:report_on_exception=)

        begin
          cleanup_preparation(
            entries,
            command_name: cleanup_command_name,
            timeout: PREPARATION_CLEANUP_GRACE_PERIOD,
            deadline: deadline_at
          )
        rescue => e
          log_debug("Failed to clean up runtime preparation after timeout", error: e.message)
        ensure
          release_preparation_locks(locks) unless locks.nil? || locks.empty?
        end
      end
    end

    def expand_preparation_path(path, env)
      expanded_path = path.gsub(/\$(\w+)|\$\{([^}]+)\}/) do
        key = Regexp.last_match(1) || Regexp.last_match(2)
        resolve_preparation_path_env_var(key, env)
      end

      if expanded_path == "~"
        return File.expand_path(resolve_preparation_home(env))
      end

      if expanded_path.start_with?("~/")
        return File.expand_path(File.join(resolve_preparation_home(env), expanded_path.delete_prefix("~/")))
      end

      File.expand_path(expanded_path)
    end

    def validate_preparation_path_env!(path, env)
      path.scan(/\$(\w+)|\$\{([^}]+)\}/) do |match|
        key = match.compact.first
        resolve_preparation_path_env_var(key, env)
      end
    end

    def resolve_preparation_path_env_var(key, env)
      unless env.key?(key)
        raise ArgumentError, "#{key} cannot be nil or empty for env-backed preparation paths"
      end

      value = env[key]
      raise ArgumentError, "#{key} cannot be nil or empty for env-backed preparation paths" if value.nil? || value.empty?

      value
    end

    def resolve_preparation_home(env)
      if env.key?("HOME")
        home = env["HOME"]
        raise ArgumentError, "HOME cannot be nil or empty for home-relative preparation paths" if home.nil? || home.empty?

        return home
      end

      ENV["HOME"] || Dir.home
    end

    def snapshot_file_state(path)
      stat = File.lstat(path)

      if stat.symlink?
        {
          existed: true,
          type: :symlink,
          target: File.readlink(path)
        }
      elsif stat.file?
        backup_file = Tempfile.new("agent-harness-preparation")
        backup_path = backup_file.path
        backup_file.close!
        FileUtils.cp(path, backup_path, preserve: true)

        {
          existed: true,
          type: :file,
          backup_path: backup_path
        }
      else
        raise ArgumentError, "preparation target must be a regular file or symlink: #{path}"
      end
    rescue Errno::ENOENT
      {existed: false}
    rescue
      FileUtils.rm_f(backup_path) if defined?(backup_path) && backup_path
      raise
    end

    def restore_file_state(path, snapshot)
      if snapshot[:type] == :symlink
        delete_preparation_path(path)
        FileUtils.mkdir_p(File.dirname(path))
        File.symlink(snapshot[:target], path)
      elsif snapshot[:existed]
        backup_path = snapshot.fetch(:backup_path)
        raise ArgumentError, "missing runtime preparation backup: #{backup_path}" unless File.exist?(backup_path)

        delete_preparation_path(path)
        FileUtils.mkdir_p(File.dirname(path))
        FileUtils.cp(backup_path, path, preserve: true)
      else
        delete_preparation_path(path)
      end
    ensure
      FileUtils.rm_f(snapshot[:backup_path]) if snapshot[:type] == :file && snapshot[:backup_path]
    end

    def delete_preparation_path(path)
      return unless File.exist?(path) || File.symlink?(path)

      raise ArgumentError, "preparation target changed into a directory during execution: #{path}" if File.directory?(path) && !File.symlink?(path)

      File.delete(path)
    end

    def timeout_deadline(timeout)
      return nil if timeout.nil?

      current_time + timeout
    end

    def cleanup_deadline(deadline, timeout:)
      return nil if timeout.nil?

      deadline
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

    def execute_with_timeout(cmd_array, timeout:, env:, stdin_data:, configured_timeout: timeout)
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
      raise TimeoutError, "Command timed out after #{configured_timeout} seconds: #{cmd_array.first}"
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
