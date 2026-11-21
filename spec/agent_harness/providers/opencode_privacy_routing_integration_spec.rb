# frozen_string_literal: true

require "open3"
require "socket"
require "timeout"

RSpec.describe "OpenCode privacy routing integration" do
  def provider
    AgentHarness::Providers::Opencode.new
  end

  def runtime(overrides = {})
    {
      model: "openrouter/openai/gpt-4o-mini",
      api_provider: "openrouter",
      privacy_routing: {zdr: true, data_collection: "deny"}
    }.merge(overrides)
  end

  def plan_config(overrides = {})
    plan = provider.plan_execution(prompt: "Reply OK", provider_runtime: runtime(overrides))
    plan.fetch(:preparation).file_writes.fetch(0).content
  end

  def decode_config(home, config)
    path = File.join(home, "opencode.json")
    File.write(path, config, mode: "w", perm: 0o600)
    Open3.capture3({"HOME" => home, "OPENCODE_CONFIG" => path}, "opencode", "debug", "config")
  end

  def assert_pinned_cli!
    stdout, status = Open3.capture2("opencode", "--version")
    expect(status).to be_success
    expect(stdout.strip).to eq(AgentHarness::Providers::Opencode::SUPPORTED_CLI_VERSION)
  end

  it "survives the pinned CLI decoder through the public plan contract" do
    assert_pinned_cli!

    Dir.mktmpdir("opencode-privacy-config") do |directory|
      stdout, stderr, status = decode_config(directory, plan_config)

      expect(status).to be_success, stderr
      decoded = JSON.parse(stdout)
      expect(decoded.dig("provider", "openrouter", "options", "extraBody", "provider")).to eq(
        "zdr" => true,
        "data_collection" => "deny"
      )
    end
  end

  it "sends both fields in the pinned CLI OpenRouter body to loopback only" do
    assert_pinned_cli!
    server = TCPServer.new("127.0.0.1", 0)
    requests = Queue.new
    server_thread = start_server(server, requests)

    Dir.mktmpdir("opencode-privacy-home") do |home|
      endpoint = "http://127.0.0.1:#{server.local_address.ip_port}/api/v1"
      overrides = {metadata: {config: {provider: {openrouter: {
        models: {"openai/gpt-4o-mini" => {}},
        options: {baseURL: endpoint}
      }}}}}
      _stdout, stderr, status = decode_config(home, plan_config(overrides))
      expect(status).to be_success, stderr

      provider.send_message(
        prompt: "Reply with OK",
        timeout: 60,
        provider_runtime: runtime(
          env: {"HOME" => home, "OPENROUTER_API_KEY" => "dummy-loopback-key"},
          **overrides
        )
      )

      request = Timeout.timeout(5) { requests.pop }
      body = JSON.parse(request.fetch(:body))
      expect(request.fetch(:path)).to end_with("/chat/completions")
      expect(body.fetch("provider")).to include("zdr" => true, "data_collection" => "deny")
      expect(request.fetch(:authorization)).to eq("Bearer dummy-loopback-key")
    end
  ensure
    server&.close
    server_thread&.join(2)
  end

  def start_server(server, requests)
    Thread.new do
      loop do
        socket = server.accept
        begin
          request = read_request(socket)
          requests << request if request[:method] == "POST"
          socket.write(loopback_response(request))
        ensure
          socket.close
        end
      end
    rescue IOError, Errno::EBADF
      nil
    end
  end

  def read_request(socket)
    method, path = socket.gets.to_s.split(" ", 3)
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      key, value = line.split(":", 2)
      headers[key.downcase] = value.to_s.strip
    end
    body = socket.read(headers.fetch("content-length", "0").to_i)
    {method: method, path: path, body: body, authorization: headers["authorization"]}
  end

  def loopback_response(request)
    return model_discovery_response if request[:method] == "GET"

    body = JSON.generate(error: {message: "request captured", type: "invalid_request_error"})
    "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
  end

  def model_discovery_response
    body = JSON.generate(object: "list", data: [{id: "openai/gpt-4o-mini", object: "model"}])
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
  end
end
