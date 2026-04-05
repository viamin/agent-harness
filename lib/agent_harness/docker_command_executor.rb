# frozen_string_literal: true

require "securerandom"

module AgentHarness
  # Executes commands inside a Docker container
  #
  # Wraps commands with `docker exec` so they run inside
  # the specified container rather than on the host.
  #
  # @example Basic usage
  #   executor = AgentHarness::DockerCommandExecutor.new(container_id: "abc123")
  #   result = executor.execute(["python", "script.py"])
  #
  # @example With environment variables
  #   result = executor.execute("echo $FOO", env: { "FOO" => "bar" })
  class DockerCommandExecutor < CommandExecutor
    attr_reader :container_id

    # Initialize the Docker command executor
    #
    # @param container_id [String] the Docker container ID or name
    # @param logger [Logger, nil] optional logger
    # @raise [CommandExecutionError] if Docker CLI is not found on the host
    def initialize(container_id:, logger: nil)
      raise ArgumentError, "container_id cannot be nil or empty" if container_id.nil? || container_id.empty?

      super(logger: logger)
      @container_id = container_id
      validate_docker!
    end

    # Execute a command inside the Docker container
    #
    # Wraps the given command with `docker exec` and delegates
    # to the parent class for actual process execution.
    #
    # @param command [Array<String>, String] command to execute
    # @param timeout [Integer, nil] timeout in seconds
    # @param env [Hash] environment variables to set in the container
    # @param stdin_data [String, nil] data to send to stdin
    # @param preparation [ExecutionPreparation, nil] request-scoped bootstrap
    #   work to materialize inside the container before the main command runs
    # @return [Result] execution result
    def execute(command, timeout: nil, env: {}, stdin_data: nil, preparation: nil)
      deadline = timeout_deadline(timeout)
      cleanup_steps = []

      apply_container_preparation(preparation, timeout: timeout, deadline: deadline, env: env, cleanup_steps: cleanup_steps)
      docker_cmd = build_docker_command(command, env: env, stdin_data: stdin_data)
      result = super(
        docker_cmd,
        timeout: remaining_timeout(deadline, timeout:, command_name: normalize_command(command).first),
        env: {},
        stdin_data: stdin_data
      )
      cleanup_container_preparation(cleanup_steps, timeout:, deadline:, command_name: normalize_command(command).first)
      result
    ensure
      pending_exception = $!
      unless cleanup_steps.nil? || cleanup_steps.empty?
        begin
          cleanup_container_preparation(cleanup_steps, timeout:, deadline:, command_name: normalize_command(command).first)
        rescue => e
          raise e if pending_exception.nil?

          log_debug("Failed to clean up container runtime preparation", error: e.message)
        end
      end
    end

    # Check if a binary exists inside the container
    #
    # @param binary [String] binary name
    # @return [String, nil] full path or nil
    def which(binary)
      result = execute(["which", binary], timeout: 5)
      result.success? ? result.stdout.strip : nil
    end

    private

    def apply_container_preparation(preparation, timeout:, deadline:, env:, cleanup_steps:)
      return if preparation.nil? || preparation.empty?

      preparation.file_writes.each do |write|
        cleanup = materialize_file_write(write, timeout:, deadline:, env:)
        cleanup_steps << cleanup
      rescue
        cleanup_container_preparation(cleanup_steps, timeout:, deadline:, command_name: "docker")
        raise
      end
    end

    def cleanup_container_preparation(cleanup_steps, timeout:, deadline:, command_name:)
      cleanup_steps.reverse_each do |cleanup|
        run_host_command(
          cleanup[:command],
          timeout: remaining_timeout(deadline, timeout:, command_name:),
          stdin_data: nil
        )
      end
      cleanup_steps.clear
    end

    def materialize_file_write(write, timeout:, deadline:, env:)
      path = shell_path(write.path)
      dir = shell_path(File.dirname(write.path))
      backup = shell_path("/tmp/agent-harness-preparation-#{SecureRandom.hex(8)}")
      backup_cmd = build_container_shell_command("[ ! -e #{path} ] || cp -p #{path} #{backup}", env: env)
      run_host_command(backup_cmd, timeout: remaining_timeout(deadline, timeout:, command_name: "docker"))

      mkdir_cmd = build_container_shell_command("mkdir -p #{dir}", env: env)
      run_host_command(mkdir_cmd, timeout: remaining_timeout(deadline, timeout:, command_name: "docker"))

      write_cmd = build_container_shell_command("cat > #{path}", env: env, stdin_data: write.content)
      run_host_command(
        write_cmd,
        timeout: remaining_timeout(deadline, timeout:, command_name: "docker"),
        stdin_data: write.content
      )

      if write.mode
        chmod_cmd = build_container_shell_command("chmod #{write.mode.to_s(8)} #{path}", env: env)
        run_host_command(chmod_cmd, timeout: remaining_timeout(deadline, timeout:, command_name: "docker"))
      end

      {
        command: build_container_shell_command(
          "if [ -e #{backup} ]; then cp -p #{backup} #{path} && rm -f #{backup}; else rm -f #{path}; fi",
          env: env
        )
      }
    end

    def run_host_command(command, timeout:, stdin_data: nil)
      result = CommandExecutor.instance_method(:execute).bind_call(
        self,
        command,
        timeout: timeout,
        env: {},
        stdin_data: stdin_data,
        preparation: nil
      )
      return result if result.success?

      message = result.stderr.to_s.strip
      message = result.stdout.to_s.strip if message.empty?
      message = "command failed with exit code #{result.exit_code}" if message.empty?
      raise CommandExecutionError, "Failed to apply runtime preparation: #{message}"
    end

    def validate_docker!
      return if ENV["PATH"]&.split(File::PATH_SEPARATOR)&.any? { |path| File.executable?(File.join(path, "docker")) }

      raise CommandExecutionError, "Docker CLI not found on host PATH"
    end

    def build_container_shell_command(script, env:, stdin_data: nil)
      build_docker_command(["sh", "-lc", script], env: env, stdin_data: stdin_data)
    end

    def shell_path(path)
      return path if path.match?(/\A\$(?:\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)\z/)
      return shell_escaped_path(path) unless path.start_with?("~/")

      suffix = path.delete_prefix("~/")
      escaped_suffix = suffix.split("/").map { |segment| shell_path_segment(segment) }.join("/")
      %("$HOME"/#{escaped_suffix})
    end

    def shell_escaped_path(path)
      prefix = path.start_with?("/") ? "/" : ""
      trimmed_path = path.delete_prefix("/")
      escaped_segments = trimmed_path.split("/").map { |segment| shell_path_segment(segment) }
      "#{prefix}#{escaped_segments.join("/")}"
    end

    def shell_path_segment(segment)
      return segment if segment.match?(/\A\$(?:\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)\z/)

      Shellwords.escape(segment)
    end

    def build_docker_command(command, env:, stdin_data:)
      cmd = ["docker", "exec"]
      unset_env_keys = []

      env.each do |key, value|
        if value.nil?
          unset_env_keys << key
          next
        end

        cmd.push("--env", "#{key}=#{value}")
      end
      cmd.push("-i") if stdin_data

      cmd.push(@container_id)
      unless unset_env_keys.empty?
        cmd.push("env")
        unset_env_keys.each { |key| cmd.push("-u", key) }
      end

      cmd.concat(normalize_command(command))
    end
  end
end
