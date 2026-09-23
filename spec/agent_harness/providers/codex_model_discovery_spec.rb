# frozen_string_literal: true

RSpec.describe "Codex subscription model discovery" do
  let(:executor) { instance_double(AgentHarness::CommandExecutor) }
  let(:provider) { AgentHarness::Providers::Codex.new(executor: executor) }
  let(:env) { {"HOME" => "/tmp/account-a"} }
  let(:version_result) do
    AgentHarness::CommandExecutor::Result.new(stdout: "codex 0.149.1", stderr: "", exit_code: 0, duration: 0.1)
  end

  before do
    AgentHarness::Providers::Codex::MODEL_REJECTION_CACHE.clear
  end

  it "ignores assistant and tool prose but recognizes an explicit error event" do
    message = "The 'old-model' model is not supported when using Codex with a ChatGPT account."
    klass = AgentHarness::Providers::Codex
    prose = {type: "item.completed", item: {type: "agent_message", text: message}}.to_json
    expect(klass.classify_model_rejection_from_result(stdout: prose, stderr: "")).to be_nil
    expect(klass.classify_model_rejection_from_result(stdout: message, stderr: "")).to be_nil
    error = {type: "turn.failed", error: {message: message}}.to_json
    expect(klass.classify_model_rejection_from_result(stdout: error, stderr: "")).to include(model: "old-model")
  end

  it "discovers alternatives through an execute-only container transport without a pinned-model restriction" do
    Dir.mktmpdir do |directory|
      executable = File.join(directory, "codex")
      File.write(executable, app_server_fixture)
      File.chmod(0o755, executable)
      # This is the minimal remote/container executor protocol, not a mock of
      # the provider. Exercise the real JSON-RPC exchange and subprocess exit.
      transport = Object.new
      transport.define_singleton_method(:execute) do |command, **options|
        AgentHarness::CommandExecutor.new.execute(command, **options)
      end
      provider = AgentHarness::Providers::Codex.new(executor: transport)
      discovery = provider.discover_available_models(
        env: {"PATH" => "#{directory}#{File::PATH_SEPARATOR}#{ENV.fetch("PATH")}"}, timeout: 5
      )

      expect(discovery).to be_available
      expect(discovery.models.map { |model| model[:id] }).to eq(["gpt-5.2-codex"])
    end
  end

  it "collects all pages, excludes hidden entries, and handles model-list errors" do
    Dir.mktmpdir do |directory|
      executable = File.join(directory, "codex")
      script = app_server_fixture.sub(
        'models = [{"id" => "gpt-5.2-codex", "isDefault" => true}]',
        <<~RUBY
          STDOUT.puts(JSON.generate({"id" => 2, "result" => {"data" => [{"id" => "hidden", "hidden" => true}], "nextCursor" => "page2"}}))
          STDOUT.flush
          page = JSON.parse(STDIN.readline)
          exit 12 unless page.dig("params", "cursor") == "page2"
          models = [{"id" => "working-model", "isDefault" => true}]
        RUBY
      )
      File.write(executable, script)
      File.chmod(0o755, executable)
      real_provider = AgentHarness::Providers::Codex.new
      discovery = real_provider.discover_available_models(
        env: {"PATH" => "#{directory}#{File::PATH_SEPARATOR}#{ENV.fetch("PATH")}"}, timeout: 5
      )
      expect(discovery.models.map { |entry| entry[:id] }).to eq(["working-model"])
      expect(discovery.recommended_model_id).to eq("working-model")
    end
  end

  it "reports timeout without returning an unverified fallback" do
    expect(executor).to receive(:execute).with(array_including("node"), hash_including(timeout: 1))
      .and_raise(AgentHarness::TimeoutError, "discovery timed out")
    discovery = provider.discover_available_models(env: env, timeout: 1)
    expect(discovery).not_to be_available
    expect(discovery.recommended_model_id).to be_nil
    expect(discovery.reason).to eq(:app_server_timeout)
  end

  it "classifies nested subscription model rejections" do
    output = JSON.generate({
      error: {
        message: JSON.generate({
          error: {
            message: "The 'gpt-5.4' model is not supported when using Codex with a ChatGPT account."
          }
        })
      }
    })

    rejection = AgentHarness::Providers::Codex.classify_model_rejection(output)

    expect(rejection).to include(
      type: :subscription_model_rejected,
      model: "gpt-5.4",
      auth_mode: :subscription,
      source: :codex_cli_error
    )
  end

  it "discovers the model/list default as a replacement" do
    allow(executor).to receive(:execute).with(["codex", "--version"], timeout: 2, env: env).and_return(version_result)
    expect_model_list(
      env: env,
      models: [
        {"id" => "gpt-5.4", "model" => "gpt-5.4", "isDefault" => false},
        {"id" => "gpt-5.2-codex", "model" => "gpt-5.2-codex", "isDefault" => true}
      ]
    )

    recovery = provider.resolve_model_rejection_recovery(
      failure: {message: "The 'gpt-5.4' model is not supported when using Codex with a ChatGPT account."},
      provider_runtime: nil,
      env: env,
      timeout: 5
    )

    expect(recovery[:rejection][:model]).to eq("gpt-5.4")
    expect(recovery[:discovery]).to include(
      status: :available,
      recommended_model_id: "gpt-5.2-codex",
      source: :codex_app_server_model_list
    )
    expect(recovery[:provider_runtime].model).to eq("gpt-5.2-codex")
  end

  it "does not replace a rejected explicitly selected model outside caller policy" do
    allow(executor).to receive(:execute).with(["codex", "--version"], timeout: 2, env: env).and_return(version_result)
    expect_model_list(
      env: env,
      models: [
        {"id" => "gpt-5.4", "model" => "gpt-5.4", "isDefault" => true},
        {"id" => "gpt-5.2-codex", "model" => "gpt-5.2-codex", "isDefault" => false}
      ]
    )

    recovery = provider.resolve_model_rejection_recovery(
      failure: {message: "The 'gpt-5.4' model is not supported when using Codex with a ChatGPT account."},
      provider_runtime: {model: "gpt-5.4"},
      env: env,
      timeout: 5
    )

    expect(recovery[:discovery]).to include(status: :unavailable, reason: :no_compatible_model)
    expect(recovery[:provider_runtime]).to be_nil
  end

  it "selects an allowed alternative instead of a disallowed default" do
    allow(executor).to receive(:execute).with(["codex", "--version"], timeout: 2, env: env).and_return(version_result)
    expect_model_list(
      env: env,
      models: [
        {"id" => "gpt-5.2-codex", "isDefault" => true},
        {"id" => "gpt-5-codex", "isDefault" => false}
      ]
    )

    discovery = provider.send(
      :discover_compatible_model,
      rejected_model_id: "gpt-5.4",
      allowed_model_ids: ["gpt-5-codex"],
      env: env,
      timeout: 5,
      refresh: true
    )

    expect(discovery.to_h).to include(status: :available, recommended_model_id: "gpt-5-codex")
  end

  it "reports no alternative when discovery only returns the rejected model" do
    allow(executor).to receive(:execute).with(["codex", "--version"], timeout: 2, env: env).and_return(version_result)
    expect_model_list(env: env, models: [{"id" => "gpt-5.4", "isDefault" => true}])

    recovery = provider.resolve_model_rejection_recovery(
      failure: {message: "The 'gpt-5.4' model is not supported when using Codex with a ChatGPT account."},
      provider_runtime: {model: "gpt-5.4"},
      env: env,
      timeout: 5
    )

    expect(recovery[:discovery]).to include(status: :unavailable, reason: :no_compatible_model)
    expect(recovery[:provider_runtime]).to be_nil
  end

  it "surfaces unavailable discovery when model/list is unsupported" do
    allow(executor).to receive(:execute).with(["codex", "--version"], timeout: 2, env: env).and_return(version_result)
    app_server = AgentHarness::CommandExecutor::Result.new(
      stdout: JSON.generate({"id" => 2, "error" => {"code" => -32601, "message" => "Method not found"}}),
      stderr: "",
      exit_code: 0,
      duration: 0.1
    )
    expect(executor).to receive(:execute_interactive)
      .with(["codex", "app-server", "--listen", "stdio://"], hash_including(env: env, timeout: 5))
      .and_return(app_server)

    recovery = provider.resolve_model_rejection_recovery(
      failure: {message: "The 'gpt-5.4' model is not supported when using Codex with a ChatGPT account."},
      provider_runtime: nil,
      env: env,
      timeout: 5
    )

    expect(recovery[:discovery]).to include(status: :unavailable, reason: :model_list_error)
    expect(recovery[:provider_runtime]).to be_nil
  end

  it "scopes cached discovery by account identity" do
    env_b = {"HOME" => "/tmp/account-b"}
    allow(executor).to receive(:execute).with(["codex", "--version"], timeout: 2, env: env).and_return(version_result)
    allow(executor).to receive(:execute).with(["codex", "--version"], timeout: 2, env: env_b).and_return(version_result)
    expect_model_list(env: env, models: [{"id" => "gpt-5.2-codex", "isDefault" => true}])
    expect_model_list(env: env_b, models: [{"id" => "gpt-5-codex", "isDefault" => true}])

    first = provider.send(:discover_compatible_model, rejected_model_id: "gpt-5.4", env: env, timeout: 5)
    second = provider.send(:discover_compatible_model, rejected_model_id: "gpt-5.4", env: env_b, timeout: 5)

    expect(first.recommended_model_id).to eq("gpt-5.2-codex")
    expect(second.recommended_model_id).to eq("gpt-5-codex")
  end

  it "waits for initialize before sending model/list to a real subprocess" do
    Dir.mktmpdir do |directory|
      executable = File.join(directory, "codex")
      File.write(executable, app_server_fixture)
      File.chmod(0o755, executable)
      real_provider = AgentHarness::Providers::Codex.new(executor: AgentHarness::CommandExecutor.new)

      discovery = real_provider.send(
        :discover_compatible_model,
        rejected_model_id: "gpt-5.4",
        env: {"PATH" => "#{directory}#{File::PATH_SEPARATOR}#{ENV.fetch("PATH")}"},
        timeout: 5,
        refresh: true
      )

      expect(discovery.to_h).to include(status: :available, recommended_model_id: "gpt-5.2-codex")
    end
  end

  def expect_model_list(env:, models:)
    stdout = [
      JSON.generate({"id" => 1, "result" => {}}),
      JSON.generate({"id" => 2, "result" => {"data" => models, "nextCursor" => nil}})
    ].join("\n")
    result = AgentHarness::CommandExecutor::Result.new(stdout: stdout, stderr: "", exit_code: 0, duration: 0.1)

    expect(executor).to receive(:execute_interactive)
      .with(
        ["codex", "app-server", "--listen", "stdio://"],
        hash_including(env: env, timeout: 5)
      )
      .and_return(result)
  end

  def app_server_fixture
    <<~RUBY
      #!#{RbConfig.ruby}
      require "json"
      initialize_request = JSON.parse(STDIN.readline)
      exit 10 unless initialize_request["method"] == "initialize"
      STDOUT.puts(JSON.generate({"id" => 1, "result" => {}}))
      STDOUT.flush
      initialized = JSON.parse(STDIN.readline)
      model_list = JSON.parse(STDIN.readline)
      exit 11 unless initialized["method"] == "initialized" && model_list["method"] == "model/list"
      models = [{"id" => "gpt-5.2-codex", "isDefault" => true}]
      STDOUT.puts(JSON.generate({"id" => 2, "result" => {"data" => models}}))
      STDOUT.flush
    RUBY
  end
end
