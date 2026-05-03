# frozen_string_literal: true

require "open3"
require "timeout"
require "shellwords"
require "fileutils"
require "tempfile"
require "tmpdir"
require "digest"

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
    PREPARATION_LOCK_POLL_INTERVAL = 0.01
    PREPARATION_CLEANUP_GRACE_PERIOD = 5
    PREPARATION_LOCK_ROOT = File.join(Dir.tmpdir, "agent-harness-preparation-locks")

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
    # @param idle_timeout [Integer, Float, nil] idle timeout in seconds based on output activity
    # @param env [Hash] environment variables
    # @param stdin_data [String, nil] data to send to stdin
    # @param preparation [ExecutionPreparation, nil] request-scoped bootstrap
    #   work for the runtime environment
    # @param on_stdout_chunk [Proc, nil] callback for stdout chunks as they are produced
    # @param on_stderr_chunk [Proc, nil] callback for stderr chunks as they are produced
    # @param on_heartbeat [Proc, nil] callback invoked periodically while the command is running
    # @param heartbeat_interval [Integer, Float] heartbeat interval in seconds
    # @param observer [Object, nil] optional observer responding to
    #   +on_stdout_chunk+, +on_stderr_chunk+, and +on_heartbeat+
    # @return [Result] execution result
    # @raise [TimeoutError] if the command times out
    # @raise [IdleTimeoutError] if the command exceeds the idle timeout
    def execute(command, timeout: nil, idle_timeout: nil, env: {}, stdin_data: nil, preparation: nil,
      on_stdout_chunk: nil, on_stderr_chunk: nil, on_heartbeat: nil,
      heartbeat_interval: 1.0, observer: nil)
      validate_duration!(timeout, name: :timeout, allow_nil: true)
      validate_duration!(idle_timeout, name: :idle_timeout, allow_nil: true)
      validate_duration!(heartbeat_interval, name: :heartbeat_interval, allow_nil: true)

      cmd_array = normalize_command(command)
      cmd_string = cmd_array.shelljoin
      command_name = cmd_array.first
      start_time = current_time
      deadline = timeout_deadline(timeout)
      applied_preparation = []
      held_preparation_locks = []
      background_cleanup_scheduled = false

      log_debug("Executing command",
        command: cmd_string,
        timeout: timeout,
        idle_timeout: idle_timeout)

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

      begin
        stdout, stderr, status = execute_streaming(
          cmd_array,
          timeout: remaining_timeout(deadline, timeout:, command_name: command_name),
          idle_timeout: idle_timeout,
          env: env,
          stdin_data: stdin_data,
          on_stdout_chunk: on_stdout_chunk,
          on_stderr_chunk: on_stderr_chunk,
          on_heartbeat: on_heartbeat,
          heartbeat_interval: heartbeat_interval,
          observer: observer
        )
      rescue TimeoutError => e
        raise e if e.is_a?(IdleTimeoutError)

        raise TimeoutError, "Command timed out after #{timeout} seconds: #{command_name}"
      end

      begin
        cleanup_preparation(
          applied_preparation,
          command_name: command_name,
          timeout: timeout,
          deadline: cleanup_deadline(deadline, timeout:)
        )
      rescue TimeoutError
        schedule_cleanup_preparation(
          applied_preparation,
          held_preparation_locks,
          command_name: command_name
        )
        background_cleanup_scheduled = true
        held_preparation_locks = []
      end
      duration = current_time - start_time

      Result.new(
        stdout: stdout,
        stderr: stderr,
        exit_code: status.exitstatus,
        duration: duration
      )
    ensure
      pending_exception = $!
      unless background_cleanup_scheduled || applied_preparation.nil? || applied_preparation.empty?
        begin
          cleanup_preparation(
            applied_preparation,
            command_name: command_name,
            timeout: timeout,
            deadline: cleanup_deadline(deadline, timeout:)
          )
        rescue TimeoutError => e
          raise e if pending_exception.nil?

          if pending_exception.is_a?(TimeoutError)
            schedule_cleanup_preparation(
              applied_preparation,
              held_preparation_locks,
              command_name: command_name
            )
            background_cleanup_scheduled = true
            held_preparation_locks = []
          else
            # Preserve the original non-timeout exception; surface that
            # cleanup also timed out so callers know bootstrap state may
            # have leaked.
            raise pending_exception.class,
              "#{pending_exception.message} (cleanup also failed: #{e.message})"
          end
        rescue => e
          raise e if pending_exception.nil?

          # Surface cleanup failures even when unwinding from another exception,
          # so callers know request-scoped bootstrap state may have leaked.
          raise pending_exception.class,
            "#{pending_exception.message} (cleanup also failed: #{e.message})"
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

      preparation.file_writes.each { |write| validate_preparation_path_security!(write.path) }

      acquired_locks = []

      preparation_lock_keys(preparation, env).each do |key|
        acquired_locks << acquire_preparation_lock(key, timeout:, deadline:, command_name:)
      end
      acquired_locks
    rescue
      release_preparation_locks(acquired_locks) if acquired_locks && !acquired_locks.empty?
      raise
    end

    def acquire_preparation_lock(key, timeout:, deadline:, command_name:)
      lock_path = preparation_lock_path(key)
      FileUtils.mkdir_p(File.dirname(lock_path), mode: 0o700)
      lock_file = File.open(lock_path, File::RDWR | File::CREAT, 0o600)

      begin
        if timeout.nil?
          lock_file.flock(File::LOCK_EX)
        else
          until lock_file.flock(File::LOCK_EX | File::LOCK_NB)
            sleep([PREPARATION_LOCK_POLL_INTERVAL, remaining_timeout(deadline, timeout:, command_name:)].min)
          end
        end
      rescue
        lock_file.close unless lock_file.closed?
        raise
      end

      {key: key, file: lock_file}
    end

    def release_preparation_locks(held_preparation_locks)
      held_preparation_locks.reverse_each do |lock|
        file = lock[:file]
        next if file.nil? || file.closed?

        file.flock(File::LOCK_UN)
        file.close
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

    def preparation_lock_path(key)
      File.join(PREPARATION_LOCK_ROOT, "#{Digest::SHA256.hexdigest(key)}.lock")
    end

    def apply_preparation(preparation, env:, timeout:, deadline:, command_name:, applied_preparation:)
      return if preparation.nil? || preparation.empty?

      preparation.file_writes.each do |write|
        validate_preparation_path_security!(write.path)
        validate_preparation_path_env!(write.path, env)
        validate_home_relative_preparation_path!(write.path, env)
        resolved_path = expand_preparation_path(write.path, env)
        created_directories = missing_parent_directories(resolved_path)
        snapshot = within_timeout(deadline, timeout:, command_name:) do
          snapshot_file_state(resolved_path)
        end
        applied_preparation << {
          path: resolved_path,
          snapshot: snapshot,
          created_directories: created_directories
        }

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
          unless entry[:restored]
            restore_file_state(entry[:path], entry[:snapshot])
            entry[:restored] = true
          end
          cleanup_created_directories(entry[:created_directories])
        end
      end
      applied_preparation.clear
    end

    def missing_parent_directories(path)
      directories = []
      current = File.dirname(path)

      until current == File.dirname(current) || File.exist?(current) || File.symlink?(current)
        directories << current
        current = File.dirname(current)
      end

      directories
    end

    def cleanup_created_directories(directories)
      directories.each do |directory|
        next unless File.directory?(directory) && !File.symlink?(directory)

        Dir.rmdir(directory)
      rescue Errno::ENOENT
        next
      rescue Errno::ENOTEMPTY, Errno::EEXIST
        break
      end
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

    def validate_preparation_path_security!(path)
      if path.include?("\x00")
        raise ArgumentError, "preparation path must not contain null bytes"
      end

      if path.include?("\n")
        raise ArgumentError, "preparation path must not contain newline characters"
      end

      if path.include?("\r")
        raise ArgumentError, "preparation path must not contain carriage return characters"
      end

      if path.include?("`")
        raise ArgumentError, "preparation path must not contain backtick characters"
      end

      if path.include?(";")
        raise ArgumentError, "preparation path must not contain semicolon characters"
      end

      if path.include?("|")
        raise ArgumentError, "preparation path must not contain pipe characters"
      end

      if path.include?("$(")
        raise ArgumentError, "preparation path must not contain command substitution"
      end

      if path.include?("..")
        raise ArgumentError, "preparation path must not contain path traversal"
      end
    end

    def validate_home_relative_preparation_path!(path, env)
      return unless path == "~" || path.start_with?("~/")
      return unless env.key?("HOME")

      home = env["HOME"]
      raise ArgumentError, "HOME cannot be nil or empty for home-relative preparation paths" if home.nil? || home.empty?
      raise ArgumentError, "HOME must not contain path traversal" if home.include?("..")
    end

    def resolve_preparation_path_env_var(key, env)
      unless env.key?(key)
        raise ArgumentError, "#{key} cannot be nil or empty for env-backed preparation paths"
      end

      value = env[key]
      raise ArgumentError, "#{key} cannot be nil or empty for env-backed preparation paths" if value.nil? || value.empty?
      raise ArgumentError, "#{key} must not contain path traversal" if value.include?("..")

      value
    end

    def resolve_preparation_home(env)
      if env.key?("HOME")
        home = env["HOME"]
        raise ArgumentError, "HOME cannot be nil or empty for home-relative preparation paths" if home.nil? || home.empty?
        raise ArgumentError, "HOME must not contain path traversal" if home.include?("..")

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

      # Only remove the backup after restore succeeds. If restore fails (e.g. the
      # prepared path was replaced by a directory), the backup must survive so
      # later cleanup retries can still restore the original user file.
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

      # Keep synchronous cleanup within the caller's original timeout budget.
      # If cleanup overruns after a successful command or after a timeout/error,
      # execute schedules bounded background cleanup instead of extending execute.
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

    def execute_streaming(cmd_array, timeout:, idle_timeout:, env:, stdin_data:,
      on_stdout_chunk:, on_stderr_chunk:, on_heartbeat:, heartbeat_interval:, observer:)
      stdout = +""
      stderr = +""

      Open3.popen3(env, *cmd_array, pgroup: true) do |stdin, stdout_io, stderr_io, wait_thr|
        unless selectable_streams?(stdin, stdout_io, stderr_io)
          return execute_buffered(
            stdin,
            stdout_io,
            stderr_io,
            wait_thr,
            stdin_data: stdin_data,
            stdout: stdout,
            stderr: stderr,
            timeout: timeout,
            idle_timeout: idle_timeout,
            cmd_array: cmd_array,
            on_stdout_chunk: on_stdout_chunk,
            on_stderr_chunk: on_stderr_chunk,
            on_heartbeat: on_heartbeat,
            heartbeat_interval: heartbeat_interval,
            observer: observer
          )
        end

        start_time = monotonic_time
        last_output_at = start_time
        last_heartbeat_at = start_time
        stdin_buffer = stdin_data.is_a?(String) ? stdin_data : stdin_data.to_s
        stdin_offset = 0
        streams = {
          stdout_io => [stdout, on_stdout_chunk, :on_stdout_chunk],
          stderr_io => [stderr, on_stderr_chunk, :on_stderr_chunk]
        }

        until streams.empty? && stdin.nil?
          ready = IO.select(streams.keys, stdin ? [stdin] : nil, nil, 0)

          if ready
            stdin, stdin_offset, last_output_at = process_ready_streams(
              ready,
              streams: streams,
              stdin: stdin,
              stdin_buffer: stdin_buffer,
              stdin_offset: stdin_offset,
              last_output_at: last_output_at,
              observer: observer,
              wait_thr: wait_thr
            )

            if process_exited?(wait_thr)
              stdin, last_output_at = finalize_exited_process(
                stdin, streams, observer, last_output_at, wait_thr,
                timeout: timeout, idle_timeout: idle_timeout, start_time: start_time, cmd_array: cmd_array
              )
              next
            end

            now = monotonic_time
            if should_emit_heartbeat?(on_heartbeat, observer, heartbeat_interval, now - last_heartbeat_at)
              emit_heartbeat(
                on_heartbeat,
                observer,
                elapsed: now - start_time,
                idle_for: now - last_output_at,
                wait_thr: wait_thr
              )
              last_heartbeat_at = now
            end

            check_wall_timeout!(timeout, now - start_time, wait_thr, cmd_array)
            check_idle_timeout!(idle_timeout, now - last_output_at, wait_thr, cmd_array)
            next
          end

          if process_exited?(wait_thr)
            stdin, last_output_at = finalize_exited_process(
              stdin, streams, observer, last_output_at, wait_thr,
              timeout: timeout, idle_timeout: idle_timeout, start_time: start_time, cmd_array: cmd_array
            )
            next
          end

          now = monotonic_time
          check_wall_timeout!(timeout, now - start_time, wait_thr, cmd_array)
          check_idle_timeout!(idle_timeout, now - last_output_at, wait_thr, cmd_array)

          if should_emit_heartbeat?(on_heartbeat, observer, heartbeat_interval, now - last_heartbeat_at)
            emit_heartbeat(
              on_heartbeat,
              observer,
              elapsed: now - start_time,
              idle_for: now - last_output_at,
              wait_thr: wait_thr
            )
            last_heartbeat_at = now
          end

          ready = IO.select(
            streams.keys,
            stdin ? [stdin] : nil,
            nil,
            select_timeout(
              timeout,
              idle_timeout,
              heartbeat_interval,
              elapsed: now - start_time,
              idle_for: now - last_output_at,
              heartbeat_age: now - last_heartbeat_at,
              heartbeat_requested: on_heartbeat || observer_responds_to?(observer, :on_heartbeat)
            )
          )

          unless ready
            if process_exited?(wait_thr)
              stdin, last_output_at = finalize_exited_process(
                stdin, streams, observer, last_output_at, wait_thr,
                timeout: timeout, idle_timeout: idle_timeout, start_time: start_time, cmd_array: cmd_array
              )
            end
            next
          end

          stdin, stdin_offset, last_output_at = process_ready_streams(
            ready,
            streams: streams,
            stdin: stdin,
            stdin_buffer: stdin_buffer,
            stdin_offset: stdin_offset,
            last_output_at: last_output_at,
            observer: observer,
            wait_thr: wait_thr
          )

          if process_exited?(wait_thr)
            stdin, last_output_at = finalize_exited_process(
              stdin, streams, observer, last_output_at, wait_thr,
              timeout: timeout, idle_timeout: idle_timeout, start_time: start_time, cmd_array: cmd_array
            )
          end
        end

        # Supervise the wait for process exit so a child that closed its
        # stdio but keeps running cannot hang past the configured timeouts.
        unless process_exited?(wait_thr)
          supervise_process_exit(
            wait_thr,
            timeout: timeout,
            idle_timeout: idle_timeout,
            start_time: start_time,
            last_output_at: last_output_at,
            cmd_array: cmd_array,
            on_heartbeat: on_heartbeat,
            observer: observer,
            heartbeat_interval: heartbeat_interval,
            last_heartbeat_at: last_heartbeat_at
          )
        end

        [stdout, stderr, wait_thr.value]
      end
    end

    def log_debug(message, **context)
      @logger&.debug("[AgentHarness::CommandExecutor] #{message}: #{context.inspect}")
    end

    def selectable_streams?(*streams)
      streams.all? { |stream| stream.is_a?(IO) }
    end

    def execute_buffered(stdin, stdout_io, stderr_io, wait_thr, stdin_data:, stdout:, stderr:, timeout:, idle_timeout:,
      cmd_array:, on_stdout_chunk:, on_stderr_chunk:, on_heartbeat:, heartbeat_interval:, observer:)
      validate_buffered_execution_support!(
        idle_timeout: idle_timeout,
        on_heartbeat: on_heartbeat,
        heartbeat_interval: heartbeat_interval,
        observer: observer
      )

      result = lambda do
        write_stdin_buffered(stdin, stdin_data)

        stdout_chunk = stdout_io.read.to_s
        stderr_chunk = stderr_io.read.to_s

        unless stdout_chunk.empty?
          stdout << stdout_chunk
          emit_chunk(on_stdout_chunk, observer, :on_stdout_chunk, stdout_chunk, wait_thr: wait_thr)
        end

        unless stderr_chunk.empty?
          stderr << stderr_chunk
          emit_chunk(on_stderr_chunk, observer, :on_stderr_chunk, stderr_chunk, wait_thr: wait_thr)
        end

        [stdout, stderr, wait_thr.value]
      end

      return result.call unless timeout

      Timeout.timeout(timeout) do
        result.call
      end
    rescue Timeout::Error
      terminate_process(wait_thr)
      raise TimeoutError, "Command timed out after #{timeout} seconds: #{cmd_array.first}"
    end

    def write_stdin_buffered(stdin, stdin_data)
      return unless stdin

      stdin.write(stdin_data.to_s)
      close_stream(stdin)
    rescue Errno::EPIPE, IOError
      close_stream(stdin)
    end

    def write_stdin_nonblock(stdin, stdin_buffer, stdin_offset)
      return stdin_buffer.bytesize if stdin_offset >= stdin_buffer.bytesize

      chunk = stdin_buffer.byteslice(stdin_offset, 4096)
      written = stdin.write_nonblock(chunk, exception: false)
      return stdin_offset if written == :wait_writable

      stdin_offset + written
    end

    def process_ready_streams(ready, streams:, stdin:, stdin_buffer:, stdin_offset:, last_output_at:, observer:, wait_thr:)
      ready[1]&.each do |io|
        stdin_offset = write_stdin_nonblock(io, stdin_buffer, stdin_offset)
        next unless stdin_offset >= stdin_buffer.bytesize

        close_stream(io)
        stdin = nil
      rescue Errno::EPIPE, IOError
        close_stream(io)
        stdin = nil
      end

      ready[0]&.each do |io|
        chunk = io.read_nonblock(4096, exception: false)

        case chunk
        when :wait_readable
          next
        when nil
          streams.delete(io)
          io.close
        else
          buffer, callback, observer_method = streams.fetch(io) do
            raise KeyError, "Unexpected ready stream for command execution"
          end
          buffer << chunk
          last_output_at = monotonic_time
          emit_chunk(callback, observer, observer_method, chunk, wait_thr: wait_thr)
        end
      end

      [stdin, stdin_offset, last_output_at]
    end

    def close_stream(stream)
      return unless stream

      stream.close
    rescue IOError
      nil
    end

    def process_exited?(wait_thr)
      !wait_thr.join(0).nil?
    end

    # Drain remaining output from an exited process's streams.
    #
    # Uses nonblocking reads with timeout supervision so that descendant
    # processes holding stdout/stderr open cannot hang past the configured
    # wall-clock or idle timeout.
    def finalize_exited_process(stdin, streams, observer, last_output_at, wait_thr,
      timeout: nil, idle_timeout: nil, start_time: nil, cmd_array: nil)
      close_stream(stdin) if stdin

      until streams.empty?
        ready = IO.select(streams.keys, nil, nil, 0.1)

        if ready
          ready[0].each do |io|
            chunk = io.read_nonblock(4096, exception: false)

            case chunk
            when :wait_readable
              next
            when nil
              streams.delete(io)
              close_stream(io)
            else
              buffer, callback, observer_method = streams.fetch(io)
              buffer << chunk
              last_output_at = monotonic_time
              emit_chunk(callback, observer, observer_method, chunk, wait_thr: wait_thr)
            end
          end
        end

        now = monotonic_time
        check_wall_timeout!(timeout, now - start_time, wait_thr, cmd_array) if start_time
        check_idle_timeout!(idle_timeout, now - last_output_at, wait_thr, cmd_array)
      end

      [nil, last_output_at]
    end

    # Poll for process exit with timeout and heartbeat supervision.
    # Called after all streams are closed when the child is still running.
    def supervise_process_exit(wait_thr, timeout:, idle_timeout:, start_time:,
      last_output_at:, cmd_array:, on_heartbeat:, observer:,
      heartbeat_interval:, last_heartbeat_at:)
      loop do
        break if process_exited?(wait_thr)

        now = monotonic_time
        check_wall_timeout!(timeout, now - start_time, wait_thr, cmd_array)
        check_idle_timeout!(idle_timeout, now - last_output_at, wait_thr, cmd_array)

        if should_emit_heartbeat?(on_heartbeat, observer, heartbeat_interval, now - last_heartbeat_at)
          emit_heartbeat(
            on_heartbeat,
            observer,
            elapsed: now - start_time,
            idle_for: now - last_output_at,
            wait_thr: wait_thr
          )
          last_heartbeat_at = now
        end

        wait_timeout = select_timeout(
          timeout, idle_timeout, heartbeat_interval,
          elapsed: now - start_time,
          idle_for: now - last_output_at,
          heartbeat_age: now - last_heartbeat_at,
          heartbeat_requested: on_heartbeat || observer_responds_to?(observer, :on_heartbeat)
        )
        # Sleep briefly before re-checking, bounded by the next deadline
        sleep([wait_timeout || 0.1, 0.1].min)
      end
    end

    def validate_duration!(value, name:, allow_nil: false)
      return if allow_nil && value.nil?
      return if value.is_a?(Numeric) && value.positive?

      raise InvalidDurationError, "#{name} must be a positive number"
    end

    def validate_buffered_execution_support!(idle_timeout:, on_heartbeat:, heartbeat_interval:, observer:)
      heartbeat_requested = on_heartbeat || observer_responds_to?(observer, :on_heartbeat)
      unsupported_supervision = idle_timeout || (heartbeat_requested && !heartbeat_interval.nil?)
      return unless unsupported_supervision

      raise ArgumentError, "Buffered command execution does not support idle timeouts or heartbeats"
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def check_wall_timeout!(timeout, elapsed, wait_thr, cmd_array)
      return unless timeout && elapsed >= timeout

      terminate_process(wait_thr)
      raise TimeoutError, "Command timed out after #{timeout} seconds: #{cmd_array.first}"
    end

    def check_idle_timeout!(idle_timeout, idle_for, wait_thr, cmd_array)
      return unless idle_timeout && idle_for >= idle_timeout

      terminate_process(wait_thr)
      raise IdleTimeoutError,
        "Command exceeded idle timeout after #{idle_timeout} seconds: #{cmd_array.first}"
    end

    def should_emit_heartbeat?(callback, observer, heartbeat_interval, heartbeat_age)
      return false unless callback || observer_responds_to?(observer, :on_heartbeat)
      return false if heartbeat_interval.nil?

      heartbeat_age >= heartbeat_interval
    end

    def emit_chunk(callback, observer, observer_method, chunk, wait_thr: nil)
      callback&.call(chunk)
      observer.public_send(observer_method, chunk) if observer_responds_to?(observer, observer_method)
    rescue
      terminate_process(wait_thr) if wait_thr
      raise
    end

    def emit_heartbeat(callback, observer, elapsed:, idle_for:, wait_thr: nil)
      callback&.call(elapsed: elapsed, idle_for: idle_for)
      observer.on_heartbeat(elapsed: elapsed, idle_for: idle_for) if observer_responds_to?(observer, :on_heartbeat)
    rescue
      terminate_process(wait_thr) if wait_thr
      raise
    end

    def observer_responds_to?(observer, method_name)
      observer&.respond_to?(method_name)
    end

    def select_timeout(timeout, idle_timeout, heartbeat_interval, elapsed:, idle_for:, heartbeat_age:, heartbeat_requested:)
      timeouts = []
      timeouts << (timeout - elapsed) if timeout
      timeouts << (idle_timeout - idle_for) if idle_timeout
      timeouts << (heartbeat_interval - heartbeat_age) if heartbeat_requested && heartbeat_interval

      min_timeout = timeouts.min
      return nil unless min_timeout

      [min_timeout, 0].max
    end

    def terminate_process(wait_thr)
      pid = wait_thr.pid
      signal_process("TERM", pid)
      Timeout.timeout(1) { wait_thr.join }
    rescue Errno::ESRCH, Timeout::Error
      begin
        signal_process("KILL", pid)
      rescue Errno::ESRCH
        nil
      end
    end

    def signal_process(signal, pid)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH
      Process.kill(signal, pid)
    end
  end
end
