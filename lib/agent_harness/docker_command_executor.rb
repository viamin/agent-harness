# frozen_string_literal: true

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
      apply_container_preparation(preparation, timeout: timeout)
      docker_cmd = build_docker_command(command, env: env, stdin_data: stdin_data)
      super(docker_cmd, timeout: timeout, env: {}, stdin_data: stdin_data)
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

    def apply_container_preparation(preparation, timeout:)
      return if preparation.nil? || preparation.empty?

      preparation.file_writes.each do |write|
        materialize_file_write(write, timeout: timeout)
      end
    end

    def materialize_file_write(write, timeout:)
      path = shell_path(write.path)
      dir = shell_path(File.dirname(write.path))
      mkdir_cmd = ["docker", "exec", @container_id, "sh", "-lc", "mkdir -p #{dir}"]
      run_host_command(mkdir_cmd, timeout: timeout)

      write_cmd = ["docker", "exec", "-i", @container_id, "sh", "-lc", "cat > #{path}"]
      run_host_command(write_cmd, timeout: timeout, stdin_data: write.content)

      return unless write.mode

      chmod_cmd = ["docker", "exec", @container_id, "sh", "-lc", "chmod #{write.mode.to_s(8)} #{path}"]
      run_host_command(chmod_cmd, timeout: timeout)
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

    def shell_path(path)
      return Shellwords.escape(path) unless path.start_with?("~/")

      suffix = path.delete_prefix("~/")
      escaped_suffix = suffix.split("/").map { |segment| Shellwords.escape(segment) }.join("/")
      %("$HOME"/#{escaped_suffix})
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
