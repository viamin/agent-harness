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
      start_time = current_time
      normalized_command = normalize_command(command)
      command_name = normalized_command.first
      deadline = timeout_deadline(timeout)
      cleanup_steps = []
      held_preparation_locks = acquire_preparation_locks(
        preparation,
        env: env,
        timeout: timeout,
        deadline: deadline,
        command_name: command_name
      )
      background_cleanup_scheduled = false

      apply_container_preparation(preparation, timeout: timeout, deadline: deadline, env: env, cleanup_steps: cleanup_steps)
      docker_cmd = build_docker_command(normalized_command, env: env, stdin_data: stdin_data)
      begin
        result = super(
          docker_cmd,
          timeout: remaining_timeout(deadline, timeout:, command_name: command_name),
          env: {},
          stdin_data: stdin_data
        )
      rescue TimeoutError
        schedule_container_cleanup_preparation(
          cleanup_steps,
          held_preparation_locks,
          command_name: command_name
        )
        background_cleanup_scheduled = true
        held_preparation_locks = []
        raise TimeoutError, "Command timed out after #{timeout} seconds: #{command_name}"
      end
      cleanup_container_preparation(
        cleanup_steps,
        timeout:,
        deadline: cleanup_deadline(deadline, timeout:),
        command_name: command_name
      )
      Result.new(
        stdout: result.stdout,
        stderr: result.stderr,
        exit_code: result.exit_code,
        duration: current_time - start_time
      )
    ensure
      pending_exception = $!
      unless background_cleanup_scheduled || cleanup_steps.nil? || cleanup_steps.empty?
        begin
          cleanup_container_preparation(
            cleanup_steps,
            timeout:,
            deadline: cleanup_deadline(deadline, timeout:),
            command_name: command_name
          )
        rescue TimeoutError => e
          raise e if pending_exception.nil? || !pending_exception.is_a?(TimeoutError)

          schedule_container_cleanup_preparation(
            cleanup_steps,
            held_preparation_locks,
            command_name: command_name
          )
          background_cleanup_scheduled = true
          held_preparation_locks = []
        rescue => e
          raise e if pending_exception.nil?

          log_debug("Failed to clean up container runtime preparation", error: e.message)
        end
      end
      unless background_cleanup_scheduled || held_preparation_locks.nil? || held_preparation_locks.empty?
        release_preparation_locks(held_preparation_locks)
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

    def preparation_lock_scope
      "docker:#{container_id}"
    end

    def preparation_lock_keys(preparation, env)
      preparation.file_writes.map do |write|
        "#{preparation_lock_scope}:#{normalize_container_lock_path(write.path, env)}"
      end.uniq.sort
    end

    def apply_container_preparation(preparation, timeout:, deadline:, env:, cleanup_steps:)
      return if preparation.nil? || preparation.empty?

      preparation.file_writes.each do |write|
        cleanup = materialize_file_write(write, timeout:, deadline:, env:)
        cleanup_steps << cleanup
      rescue => e
        begin
          cleanup_container_preparation(cleanup_steps, timeout:, deadline:, command_name: "docker")
        rescue => cleanup_error
          log_debug("Failed to clean up container runtime preparation", error: cleanup_error.message)
        end
        raise e
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

    def schedule_container_cleanup_preparation(cleanup_steps, held_preparation_locks, command_name:)
      cleanup_deadline = timeout_deadline(PREPARATION_CLEANUP_GRACE_PERIOD)
      Thread.new(cleanup_steps, held_preparation_locks, cleanup_deadline, command_name) do |steps, locks, deadline_at, cleanup_command_name|
        Thread.current.report_on_exception = false if Thread.current.respond_to?(:report_on_exception=)

        begin
          cleanup_container_preparation(
            steps,
            timeout: PREPARATION_CLEANUP_GRACE_PERIOD,
            deadline: deadline_at,
            command_name: cleanup_command_name
          )
        rescue => e
          log_debug("Failed to clean up container runtime preparation after timeout", error: e.message)
        ensure
          release_preparation_locks(locks) unless locks.nil? || locks.empty?
        end
      end
    end

    def materialize_file_write(write, timeout:, deadline:, env:)
      validate_preparation_path_env!(write.path, env)
      validate_home_relative_preparation_path!(write.path, env)
      path = shell_path(write.path)
      dir = shell_path(File.dirname(write.path))
      state_dir_path = "/tmp/agent-harness-preparation-#{SecureRandom.hex(8)}"
      state_dir = shell_path(state_dir_path)
      backup = shell_path(File.join(state_dir_path, "backup"))
      state = shell_path(File.join(state_dir_path, "state"))
      symlink_target = shell_path(File.join(state_dir_path, "symlink_target"))
      directory_change_message = Shellwords.escape(
        "preparation target changed into a directory during execution: #{write.path}"
      )
      cleanup_state_dir_cmd = build_container_shell_command("rm -rf #{state_dir}", env: env)
      backup_cmd = build_container_shell_command(
        "umask 077 && mkdir -p #{state_dir} && if [ -L #{path} ]; then readlink #{path} > #{symlink_target} && printf symlink > #{state}; " \
          "elif [ -e #{path} ]; then cp -p #{path} #{backup} && printf file > #{state}; " \
          "else printf missing > #{state}; fi",
        env: env
      )
      run_host_command(backup_cmd, timeout: remaining_timeout(deadline, timeout:, command_name: "docker"))
      cleanup = {
        command: build_container_shell_command(
          "cleanup_status=0; state_value=$(cat #{state} 2>/dev/null); if [ -d #{path} ] && [ ! -L #{path} ]; then " \
            "printf '%s\\n' #{directory_change_message} >&2; cleanup_status=1; " \
            "elif [ \"$state_value\" = symlink ]; then " \
            "mkdir -p #{dir} && rm -f -- #{path} && ln -s \"$(cat #{symlink_target})\" #{path} || cleanup_status=$?; " \
            "elif [ \"$state_value\" = file ]; then " \
            "if [ -f #{backup} ]; then mkdir -p #{dir} && rm -f -- #{path} && cp -p #{backup} #{path} || cleanup_status=$?; " \
            "else echo \"missing runtime preparation backup: #{backup}\" >&2; cleanup_status=1; fi; " \
            "elif [ \"$state_value\" = missing ]; then rm -f -- #{path} || cleanup_status=$?; " \
            "else cleanup_status=1; " \
            "fi; rm -rf #{state_dir}; exit $cleanup_status",
          env: env
        )
      }

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

      cleanup
    rescue => e
      if cleanup
        begin
          run_host_command(
            cleanup[:command],
            timeout: remaining_timeout(deadline, timeout:, command_name: "docker")
          )
        rescue => cleanup_error
          log_debug("Failed to clean up container runtime preparation", error: cleanup_error.message)
        end
      elsif defined?(cleanup_state_dir_cmd)
        begin
          run_host_command(
            cleanup_state_dir_cmd,
            timeout: remaining_timeout(deadline, timeout:, command_name: "docker")
          )
        rescue => cleanup_error
          log_debug("Failed to clean up container runtime preparation", error: cleanup_error.message)
        end
      end
      raise e
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

    def resolve_preparation_path_env_var(key, env)
      unless env.key?(key)
        raise ArgumentError, "#{key} cannot be nil or empty for env-backed preparation paths"
      end

      value = env[key]
      raise ArgumentError, "#{key} cannot be nil or empty for env-backed preparation paths" if value.nil? || value.empty?

      value
    end

    def normalize_container_lock_path(path, env)
      expanded_path = path.gsub(/\$(\w+)|\$\{([^}]+)\}/) do
        key = Regexp.last_match(1) || Regexp.last_match(2)
        resolve_preparation_path_env_var(key, env)
      end

      return "home" if expanded_path == "~"
      if expanded_path.start_with?("~/")
        normalized = File.expand_path(expanded_path.delete_prefix("~/"), "/").delete_prefix("/")
        return normalized.empty? ? "home" : "home/#{normalized}"
      end

      return File.expand_path(expanded_path) if expanded_path.start_with?("/")

      normalized = File.expand_path(expanded_path, "/").delete_prefix("/")
      normalized.empty? ? "relative" : "relative/#{normalized}"
    end

    def validate_home_relative_preparation_path!(path, env)
      return unless path == "~" || path.start_with?("~/")
      return unless env.key?("HOME")

      home = env["HOME"]
      raise ArgumentError, "HOME cannot be nil or empty for home-relative preparation paths" if home.nil? || home.empty?
    end

    def shell_path(path)
      return guarded_home_shell_path if path == "~"
      return shell_escaped_path(path) unless path.start_with?("~/")

      suffix = path.delete_prefix("~/")
      escaped_suffix = suffix.split("/").map { |segment| shell_path_segment(segment) }.join("/")
      %(#{guarded_home_shell_path}/#{escaped_suffix})
    end

    def guarded_home_shell_path
      %("${HOME:?HOME cannot be nil or empty for home-relative preparation paths}")
    end

    def shell_escaped_path(path)
      prefix = path.start_with?("/") ? "/" : ""
      trimmed_path = path.delete_prefix("/")
      escaped_segments = trimmed_path.split("/").map { |segment| shell_path_segment(segment) }
      "#{prefix}#{escaped_segments.join("/")}"
    end

    def shell_path_segment(segment)
      rendered = +""
      index = 0

      segment.to_enum(:scan, /\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))/).each do
        match = Regexp.last_match
        literal = segment[index...match.begin(0)]
        rendered << Shellwords.escape(literal) unless literal.empty?

        var_name = match[1] || match[2]
        rendered << %("${#{var_name}}")
        index = match.end(0)
      end

      tail = segment[index..]
      rendered << Shellwords.escape(tail) unless tail.nil? || tail.empty?

      rendered.empty? ? "''" : rendered
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
