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
    # @return [Result] execution result
    def execute(command, timeout: nil, env: {}, stdin_data: nil)
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

    def validate_docker!
      return if ENV["PATH"]&.split(File::PATH_SEPARATOR)&.any? { |path| File.executable?(File.join(path, "docker")) }

      raise CommandExecutionError, "Docker CLI not found on host PATH"
    end

    def build_docker_command(command, env:, stdin_data:)
      cmd = ["docker", "exec"]

      env.each do |key, value|
        next if value.nil?

        cmd.push("--env", "#{key}=#{value}")
      end
      cmd.push("-i") if stdin_data

      cmd.push(@container_id)

      cmd.concat(normalize_command(command))
    end
  end
end
