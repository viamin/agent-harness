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
    # @param idle_timeout [Integer, Float, nil] idle timeout in seconds based on output activity
    # @param env [Hash] environment variables
    # @param stdin_data [String, nil] data to send to stdin
    # @param on_stdout_chunk [Proc, nil] callback for stdout chunks as they are produced
    # @param on_stderr_chunk [Proc, nil] callback for stderr chunks as they are produced
    # @param on_heartbeat [Proc, nil] callback invoked periodically while the command is running
    # @param heartbeat_interval [Integer, Float] heartbeat interval in seconds
    # @param observer [Object, nil] optional observer responding to
    #   +on_stdout_chunk+, +on_stderr_chunk+, and +on_heartbeat+
    # @return [Result] execution result
    # @raise [TimeoutError] if the command times out
    # @raise [IdleTimeoutError] if the command exceeds the idle timeout
    def execute(command, timeout: nil, idle_timeout: nil, env: {}, stdin_data: nil,
      on_stdout_chunk: nil, on_stderr_chunk: nil, on_heartbeat: nil,
      heartbeat_interval: 1.0, observer: nil)
      validate_duration!(timeout, name: :timeout, allow_nil: true)
      validate_duration!(idle_timeout, name: :idle_timeout, allow_nil: true)
      validate_duration!(heartbeat_interval, name: :heartbeat_interval, allow_nil: true)

      cmd_array = normalize_command(command)
      cmd_string = cmd_array.shelljoin

      log_debug("Executing command",
        command: cmd_string,
        timeout: timeout,
        idle_timeout: idle_timeout)

      start_time = Time.now

      stdout, stderr, status = execute_streaming(
        cmd_array,
        timeout: timeout,
        idle_timeout: idle_timeout,
        env: env,
        stdin_data: stdin_data,
        on_stdout_chunk: on_stdout_chunk,
        on_stderr_chunk: on_stderr_chunk,
        on_heartbeat: on_heartbeat,
        heartbeat_interval: heartbeat_interval,
        observer: observer
      )

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

    def execute_streaming(cmd_array, timeout:, idle_timeout:, env:, stdin_data:,
      on_stdout_chunk:, on_stderr_chunk:, on_heartbeat:, heartbeat_interval:, observer:)
      stdout = +""
      stderr = +""

      Open3.popen3(env, *cmd_array, pgroup: true) do |stdin, stdout_io, stderr_io, wait_thr|
        unless selectable_streams?(stdin, stdout_io, stderr_io)
          return execute_buffered(
            stdout_io,
            stderr_io,
            wait_thr,
            stdout: stdout,
            stderr: stderr,
            timeout: timeout,
            cmd_array: cmd_array,
            on_stdout_chunk: on_stdout_chunk,
            on_stderr_chunk: on_stderr_chunk,
            observer: observer
          )
        end

        start_time = monotonic_time
        last_activity_at = start_time
        last_heartbeat_at = start_time
        stdin_buffer = stdin_data.to_s.b
        stdin_offset = 0
        streams = {
          stdout_io => [stdout, on_stdout_chunk, :on_stdout_chunk],
          stderr_io => [stderr, on_stderr_chunk, :on_stderr_chunk]
        }

        until streams.empty? && stdin.nil?
          now = monotonic_time
          check_wall_timeout!(timeout, now - start_time, wait_thr, cmd_array)
          check_idle_timeout!(idle_timeout, now - last_activity_at, wait_thr, cmd_array)

          if should_emit_heartbeat?(on_heartbeat, observer, heartbeat_interval, now - last_heartbeat_at)
            emit_heartbeat(
              on_heartbeat,
              observer,
              elapsed: now - start_time,
              idle_for: now - last_activity_at
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
              idle_for: now - last_activity_at,
              heartbeat_age: now - last_heartbeat_at,
              heartbeat_requested: on_heartbeat || observer_responds_to?(observer, :on_heartbeat)
            )
          )

          next unless ready

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
              buffer, callback, observer_method = streams.fetch(io)
              buffer << chunk
              last_activity_at = monotonic_time
              emit_chunk(callback, observer, observer_method, chunk)
            end
          end
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

    def execute_buffered(stdout_io, stderr_io, wait_thr, stdout:, stderr:, timeout:, cmd_array:,
      on_stdout_chunk:, on_stderr_chunk:, observer:)
      result = lambda do
        stdout_chunk = stdout_io.read.to_s
        stderr_chunk = stderr_io.read.to_s

        unless stdout_chunk.empty?
          stdout << stdout_chunk
          emit_chunk(on_stdout_chunk, observer, :on_stdout_chunk, stdout_chunk)
        end

        unless stderr_chunk.empty?
          stderr << stderr_chunk
          emit_chunk(on_stderr_chunk, observer, :on_stderr_chunk, stderr_chunk)
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

    def write_stdin_nonblock(stdin, stdin_buffer, stdin_offset)
      return stdin_buffer.bytesize if stdin_offset >= stdin_buffer.bytesize

      chunk = stdin_buffer.byteslice(stdin_offset, 4096)
      written = stdin.write_nonblock(chunk, exception: false)
      return stdin_offset if written == :wait_writable

      stdin_offset + written
    end

    def close_stream(stream)
      stream.close unless stream.closed?
    rescue IOError
      nil
    end

    def validate_duration!(value, name:, allow_nil: false)
      return if allow_nil && value.nil?
      return if value.is_a?(Numeric) && value.positive?

      raise ArgumentError, "#{name} must be a positive number"
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

    def emit_chunk(callback, observer, observer_method, chunk)
      callback&.call(chunk)
      observer.public_send(observer_method, chunk) if observer_responds_to?(observer, observer_method)
    end

    def emit_heartbeat(callback, observer, elapsed:, idle_for:)
      callback&.call(elapsed: elapsed, idle_for: idle_for)
      observer.on_heartbeat(elapsed: elapsed, idle_for: idle_for) if observer_responds_to?(observer, :on_heartbeat)
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
