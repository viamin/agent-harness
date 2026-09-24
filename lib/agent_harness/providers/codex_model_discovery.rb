# frozen_string_literal: true

module AgentHarness
  module Providers
    # Runs the interactive protocol beside the CLI, including for executors that
    # only expose execute (Docker/remote transports). Codex's npm installation
    # already requires Node. No shell, host credentials, or host CLI is used.
    module CodexModelDiscovery
      SCRIPT = <<~'JS'
        const { spawn } = require('node:child_process');
        const child = spawn(process.argv[1], ['app-server', '--listen', 'stdio://'], {stdio: ['pipe', 'pipe', 'pipe']});
        let buffer = '', bytes = 0, page = 0, done = false;
        const models = [], cursors = new Set();
        const send = value => child.stdin.write(JSON.stringify(value) + '\n');
        const finish = (code, value) => {
          if (done) return;
          done = true;
          clearTimeout(timer);
          if (value) process.stdout.write(JSON.stringify(value) + '\n');
          process.exitCode = code;
          child.stdin.end();
          child.kill('SIGTERM');
          setTimeout(() => child.kill('SIGKILL'), 250).unref();
        };
        const timer = setTimeout(() => finish(1), Number(process.argv[2]));
        child.on('error', () => finish(1));
        child.stdin.on('error', () => finish(1));
        child.stderr.on('data', () => {});
        child.on('close', () => { if (!done) finish(1); });
        child.stdout.on('data', chunk => {
          bytes += chunk.length;
          if (bytes > 1048576) return finish(1);
          buffer += chunk.toString();
          let end;
          while (!done && (end = buffer.indexOf('\n')) >= 0) {
            const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
            let msg; try { msg = JSON.parse(line); } catch { continue; }
            if (msg.id !== 1 && msg.id !== 2) continue;
            if (msg.error) return finish(0, {id: 2, error: msg.error});
            if (msg.id === 1) {
              send({method: 'initialized', params: {}});
              send({id: 2, method: 'model/list', params: {limit: 100}});
            } else {
              if (!Array.isArray(msg.result?.data)) return finish(1);
              models.push(...msg.result.data);
              const cursor = msg.result.nextCursor;
              if (!cursor) return finish(0, {id: 2, result: {data: models}});
              if (++page >= 10 || cursors.has(cursor)) return finish(1);
              cursors.add(cursor);
              send({id: 2, method: 'model/list', params: {limit: 100, cursor}});
            }
          }
        });
        send({id: 1, method: 'initialize', params: {clientInfo: {name: 'agent-harness', version: '1.0.0'}}});
      JS

      # Fresh account-local discovery. The caller owns selection policy and must
      # still smoke-test its selected model; model/list is not execution proof.
      def discover_available_models(env:, timeout: 15)
        result = execute_model_discovery(env: env, timeout: timeout)
        return unavailable_model_discovery(:app_server_failed) unless result.success?

        response = parse_app_server_response(result.stdout, 2)
        return unavailable_model_discovery(:model_list_missing_response) unless response
        return unavailable_model_discovery(:model_list_error) if response["error"]

        entries = Array(response.dig("result", "data")).filter_map { |entry| normalize_model_entry(entry) }
          .reject { |entry| entry[:hidden] }.uniq { |entry| entry[:id] }
        return unavailable_model_discovery(:no_compatible_model) if entries.empty?

        preferred = entries.find { |entry| entry[:is_default] } || entries.first
        self.class::ModelDiscovery.new(status: :available, models: entries,
          recommended_model_id: preferred[:id], source: :codex_app_server_model_list)
      rescue TimeoutError
        unavailable_model_discovery(:app_server_timeout)
      end

      private

      def execute_model_discovery(env:, timeout:)
        @executor.execute(
          ["node", "-e", SCRIPT, self.class.binary_name, [(timeout * 1000).to_i - 500, 100].max.to_s],
          env: env, timeout: timeout
        )
      end
    end
  end
end
