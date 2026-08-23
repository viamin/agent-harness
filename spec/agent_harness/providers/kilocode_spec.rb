# frozen_string_literal: true

RSpec.describe AgentHarness::Providers::Kilocode do
  describe ".provider_name" do
    it "returns :kilocode" do
      expect(described_class.provider_name).to eq(:kilocode)
    end
  end

  describe ".binary_name" do
    it "returns kilo" do
      expect(described_class.binary_name).to eq("kilo")
    end
  end

  describe ".installation_contract" do
    it "returns the upstream install contract" do
      contract = described_class.installation_contract

      expect(contract[:source]).to eq({
        type: :npm,
        package: "@kilocode/cli"
      })
      expect(contract[:install_command]).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "@kilocode/cli@7.4.23"]
      )
      expect(contract[:binary_name]).to eq("kilo")
      expect(contract[:default_version]).to eq("7.4.23")
      expect(contract[:supported_version_requirement]).to eq("= 7.4.23")
    end

    it "can render an install command for an explicitly supported target" do
      contract = described_class.installation_contract(version: "7.4.23")

      expect(contract[:install_command]).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "@kilocode/cli@7.4.23"]
      )
    end

    it "rejects unsupported versions" do
      expect {
        described_class.installation_contract(version: "7.1.2")
      }.to raise_error(ArgumentError, /Unsupported Kilocode CLI version/)
    end

    it "rejects malformed version strings with a provider-specific message" do
      expect {
        described_class.installation_contract(version: "not-a-version")
      }.to raise_error(ArgumentError, /Unsupported Kilocode CLI version/)
    end

    it "rejects nil version" do
      expect {
        described_class.installation_contract(version: nil)
      }.to raise_error(ArgumentError, /Unsupported Kilocode CLI version/)
    end

    it "rejects empty version" do
      expect {
        described_class.installation_contract(version: "")
      }.to raise_error(ArgumentError, /Unsupported Kilocode CLI version/)
    end

    it "preserves non-String version in error message" do
      expect {
        described_class.installation_contract(version: 42)
      }.to raise_error(ArgumentError, /Unsupported Kilocode CLI version 42/)
    end

    it "normalizes padded version strings in the install command" do
      contract = described_class.installation_contract(version: " 7.4.23 ")

      expect(contract[:install_command]).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "@kilocode/cli@7.4.23"]
      )
    end
  end

  describe ".install_command" do
    it "returns the install command for the default supported version" do
      expect(described_class.install_command).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "@kilocode/cli@7.4.23"]
      )
    end

    it "supports an explicit supported version" do
      expect(described_class.install_command(version: "7.4.23")).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "@kilocode/cli@7.4.23"]
      )
    end
  end

  describe ".firewall_requirements" do
    it "returns empty arrays" do
      requirements = described_class.firewall_requirements
      expect(requirements[:domains]).to eq([])
      expect(requirements[:ip_ranges]).to eq([])
    end
  end

  describe ".instruction_file_paths" do
    it "returns empty array" do
      expect(described_class.instruction_file_paths).to eq([])
    end
  end

  describe ".discover_models" do
    let(:mock_executor) { instance_double(AgentHarness::CommandExecutor) }

    before do
      allow(AgentHarness.configuration).to receive(:command_executor).and_return(mock_executor)
    end

    context "when kilocode is available" do
      before do
        allow(mock_executor).to receive(:which).with("kilo").and_return("/usr/local/bin/kilo")
      end

      it "returns the bundled GLM-5 model catalog" do
        models = described_class.discover_models

        expect(models.map { |model| model.fetch(:name) }).to eq([
          "glm-5",
          "glm-5.1",
          "glm-5.1-free",
          "glm-5.1-thinking",
          "glm-5.2",
          "glm-5.2-fast",
          "glm-5.2-flex",
          "glm-5.2-free",
          "glm-5.2-nitro",
          "glm-5.2-short",
          "glm-5.2-short-fast",
          "glm-5.2-short-fast-flex",
          "glm-5.2-short-flex",
          "glm-5p1",
          "glm-5p1-fast",
          "glm-5p2",
          "glm-5p2-fast",
          "glm-5v-turbo"
        ])
        expect(models).to all(include(provider: "kilocode"))
        expect(models).to all(satisfy { |model| model.fetch(:family) == model.fetch(:name) })
      end

      it "returns mutable copies of the catalog entries" do
        described_class.discover_models.first[:name] = "changed"

        expect(described_class.discover_models.first[:name]).to eq("glm-5")
      end
    end

    it "returns empty when not available" do
      allow(mock_executor).to receive(:which).with("kilo").and_return(nil)

      expect(described_class.discover_models).to eq([])
    end
  end

  describe ".model_family" do
    it "returns the provider model name unchanged" do
      expect(described_class.model_family("glm-5.1")).to eq("glm-5.1")
    end
  end

  describe ".provider_model_name" do
    it "returns the family name unchanged" do
      expect(described_class.provider_model_name("glm-5.2")).to eq("glm-5.2")
    end
  end

  describe ".supports_model_family?" do
    it "supports every bundled catalog family" do
      described_class::MODEL_CATALOG.each do |model|
        expect(described_class.supports_model_family?(model.fetch(:family))).to be true
      end
    end

    it "returns true for GLM-5 model families" do
      expect(described_class.supports_model_family?("glm-5")).to be true
      expect(described_class.supports_model_family?("glm-5.1")).to be true
      expect(described_class.supports_model_family?("glm-5.1-free")).to be true
      expect(described_class.supports_model_family?("glm-5.1-thinking")).to be true
      expect(described_class.supports_model_family?("glm-5.2-flex")).to be true
      expect(described_class.supports_model_family?("glm-5.2-fast")).to be true
      expect(described_class.supports_model_family?("glm-5.2-short-fast-flex")).to be true
      expect(described_class.supports_model_family?("glm-5p1")).to be true
      expect(described_class.supports_model_family?("glm-5p1-fast")).to be true
      expect(described_class.supports_model_family?("glm-5p2")).to be true
      expect(described_class.supports_model_family?("glm-5p2-fast")).to be true
      expect(described_class.supports_model_family?("glm-5v-turbo")).to be true
    end

    it "returns false for non-GLM-5 model families" do
      expect(described_class.supports_model_family?("glm-4.5")).to be false
      expect(described_class.supports_model_family?("claude-3-sonnet")).to be false
      expect(described_class.supports_model_family?("glm-50")).to be false
    end
  end

  describe "instance" do
    let(:mock_executor) do
      instance_double(AgentHarness::CommandExecutor)
    end

    subject(:provider) { described_class.new(executor: mock_executor) }

    describe "#name" do
      it "returns kilocode" do
        expect(provider.name).to eq("kilocode")
      end
    end

    describe "#display_name" do
      it "returns Kilocode CLI" do
        expect(provider.display_name).to eq("Kilocode CLI")
      end
    end

    describe "#configuration_schema" do
      it "returns defaults with no configurable fields" do
        schema = provider.configuration_schema
        expect(schema[:fields]).to be_empty
        expect(schema[:auth_modes]).to eq([:api_key])
        expect(schema[:openai_compatible]).to be false
      end
    end

    describe "#capabilities" do
      it "returns minimal capabilities" do
        caps = provider.capabilities
        expect(caps[:streaming]).to be false
        expect(caps[:mcp]).to be false
        expect(caps[:dangerous_mode]).to be false
      end
    end

    describe "#send_message" do
      it "keeps the runtime binary aligned with the installation contract" do
        expect(described_class.installation_contract[:binary_name]).to eq(described_class.binary_name)
      end

      it "executes kilo run with --format json and the prompt" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: '{"type":"text","part":{"text":"response"}}',
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        expect(mock_executor).to receive(:execute).with(
          ["kilo", "run", "--format", "json", "Hello"],
          anything
        )

        provider.send_message(prompt: "Hello")
      end

      it "appends smoke-test flags for smoke test invocations" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: '{"type":"text","part":{"text":"response"}}',
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        expect(mock_executor).to receive(:execute).with(
          ["kilo", "run", "--format", "json", "--auto", "--print-logs", "Hello"],
          anything
        )

        provider.send_message(prompt: "Hello", smoke_test: true)
      end

      it "does not write a config file when no provider_runtime is supplied" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: '{"type":"text","part":{"text":"response"}}',
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        expect(mock_executor).to receive(:execute).with(
          ["kilo", "run", "--format", "json", "Hello"],
          satisfy { |opts| !opts.key?(:preparation) }
        )

        provider.send_message(prompt: "Hello")
      end

      context "with the default external_directory permission rule" do
        it "writes the permissive /tmp and home-directory permission to ~/.config/kilocode/kilo.json via the execution preparation" do
          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: '{"type":"text","part":{"text":"response"}}',
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          expect(mock_executor).to receive(:execute).with(
            ["kilo", "run", "--format", "json", "Hello"],
            hash_including(
              preparation: have_attributes(
                file_writes: [
                  have_attributes(
                    path: "~/.config/kilocode/kilo.json",
                    content: include(
                      "\"permission\":",
                      "\"external_directory\":",
                      "\"/tmp/**\": \"allow\"",
                      "\"/home/agent/**\": \"allow\"",
                      "\"model\": \"openai/gpt-5.4\""
                    ),
                    mode: 0o600
                  )
                ]
              )
            )
          )

          provider.send_message(
            prompt: "Hello",
            provider_runtime: {model: "openai/gpt-5.4"}
          )
        end

        it "writes a config file even when no other config extras are supplied" do
          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: '{"type":"text","part":{"text":"response"}}',
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          expect(mock_executor).to receive(:execute).with(
            ["kilo", "run", "--format", "json", "Hello"],
            hash_including(
              preparation: have_attributes(
                file_writes: [
                  have_attributes(
                    path: "~/.config/kilocode/kilo.json",
                    content: include("\"external_directory\":"),
                    mode: 0o600
                  )
                ]
              )
            )
          )

          provider.send_message(
            prompt: "Hello",
            provider_runtime: {model: "gpt-5.4"}
          )
        end

        it "does not mutate the shared DEFAULT_PERMISSION_CONFIG constant across invocations" do
          frozen_config = described_class::DEFAULT_PERMISSION_CONFIG
          expect(frozen_config).to be_frozen

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: '{"type":"text","part":{"text":"response"}}',
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          2.times { provider.send_message(prompt: "Hello", provider_runtime: {model: "gpt-5.4"}) }

          expect(frozen_config["external_directory"]).to eq("/tmp/**" => "allow", "/home/agent/**" => "allow")
        end

        it "merges a caller-supplied permission block on top of the default external_directory allowlist" do
          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: '{"type":"text","part":{"text":"response"}}',
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          expect(mock_executor).to receive(:execute).with(
            ["kilo", "run", "--format", "json", "Hello"],
            hash_including(
              preparation: have_attributes(
                file_writes: [
                  have_attributes(
                    path: "~/.config/kilocode/kilo.json",
                    content: satisfy do |content|
                      parsed = JSON.parse(content)
                      parsed["permission"] == {
                        "external_directory" => {
                          "/tmp/**" => "allow",
                          "/home/agent/**" => "allow"
                        },
                        "bash" => "ask",
                        "edit" => "deny"
                      }
                    end,
                    mode: 0o600
                  )
                ]
              )
            )
          )

          provider.send_message(
            prompt: "Hello",
            provider_runtime: {
              metadata: {
                config: {
                  permission: {
                    bash: "ask",
                    edit: "deny"
                  }
                }
              }
            }
          )
        end

        it "unions caller-supplied external_directory entries with the default allowlist (caller wins on conflicts)" do
          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: '{"type":"text","part":{"text":"response"}}',
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          expect(mock_executor).to receive(:execute).with(
            ["kilo", "run", "--format", "json", "Hello"],
            hash_including(
              preparation: have_attributes(
                file_writes: [
                  have_attributes(
                    path: "~/.config/kilocode/kilo.json",
                    content: satisfy do |content|
                      parsed = JSON.parse(content)
                      parsed["permission"]["external_directory"] == {
                        "/tmp/**" => "deny",
                        "/home/agent/**" => "allow",
                        "/usr/local/lib/ruby/gems/*/gems/agent-harness-*/**" => "allow"
                      }
                    end,
                    mode: 0o600
                  )
                ]
              )
            )
          )

          provider.send_message(
            prompt: "Hello",
            provider_runtime: {
              metadata: {
                config: {
                  permission: {
                    external_directory: {
                      "/tmp/**" => "deny",
                      "/usr/local/lib/ruby/gems/*/gems/agent-harness-*/**" => "allow"
                    }
                  }
                }
              }
            }
          )
        end

        it "honors a caller-supplied permission block verbatim (no defaults) when permission_replace is set via runtime config" do
          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: '{"type":"text","part":{"text":"response"}}',
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          expect(mock_executor).to receive(:execute).with(
            ["kilo", "run", "--format", "json", "Hello"],
            hash_including(
              preparation: have_attributes(
                file_writes: [
                  have_attributes(
                    path: "~/.config/kilocode/kilo.json",
                    content: satisfy do |content|
                      parsed = JSON.parse(content)
                      parsed["permission"] == {"bash" => "ask", "edit" => "deny"} &&
                        !parsed.key?("permission_replace")
                    end,
                    mode: 0o600
                  )
                ]
              )
            )
          )

          provider.send_message(
            prompt: "Hello",
            provider_runtime: {
              metadata: {
                config: {
                  permission_replace: true,
                  permission: {
                    bash: "ask",
                    edit: "deny"
                  }
                }
              }
            }
          )
        end

        it "preserves an explicitly empty permission hash when permission_replace is set via runtime config" do
          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: '{"type":"text","part":{"text":"response"}}',
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          expect(mock_executor).to receive(:execute).with(
            ["kilo", "run", "--format", "json", "Hello"],
            hash_including(
              preparation: have_attributes(
                file_writes: [
                  have_attributes(
                    path: "~/.config/kilocode/kilo.json",
                    content: satisfy do |content|
                      parsed = JSON.parse(content)
                      parsed["permission"] == {} && !parsed.key?("permission_replace")
                    end,
                    mode: 0o600
                  )
                ]
              )
            )
          )

          provider.send_message(
            prompt: "Hello",
            provider_runtime: {
              metadata: {
                config: {
                  permission_replace: true,
                  permission: {}
                }
              }
            }
          )
        end

        it "does not inject default permissions when permission_replace is set without a permission block" do
          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: '{"type":"text","part":{"text":"response"}}',
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          expect(mock_executor).to receive(:execute).with(
            ["kilo", "run", "--format", "json", "Hello"],
            hash_including(
              preparation: have_attributes(
                file_writes: [
                  have_attributes(
                    path: "~/.config/kilocode/kilo.json",
                    content: satisfy do |content|
                      parsed = JSON.parse(content)
                      !parsed.key?("permission") &&
                        !parsed.key?("permission_replace") &&
                        parsed["model"] == "gpt-5.4"
                    end,
                    mode: 0o600
                  )
                ]
              )
            )
          )

          provider.send_message(
            prompt: "Hello",
            provider_runtime: {
              model: "gpt-5.4",
              metadata: {
                config: {
                  permission_replace: true
                }
              }
            }
          )
        end

        it "does not mutate the caller-supplied permission block when merging defaults" do
          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: '{"type":"text","part":{"text":"response"}}',
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          caller_permission = {
            external_directory: {"/usr/local/lib/ruby/gems/*/gems/agent-harness-*/**" => "allow"}
          }

          provider.send_message(
            prompt: "Hello",
            provider_runtime: {
              metadata: {
                config: {
                  permission: caller_permission
                }
              }
            }
          )

          expect(caller_permission).to eq(
            external_directory: {"/usr/local/lib/ruby/gems/*/gems/agent-harness-*/**" => "allow"}
          )
        end
      end
    end

    describe "#error_patterns" do
      it "includes rate limit patterns" do
        expect(provider.error_patterns[:rate_limited]).not_to be_empty
      end

      it "includes auth patterns" do
        expect(provider.error_patterns[:auth_expired]).not_to be_empty
      end

      it "includes quota patterns" do
        expect(provider.error_patterns[:quota_exceeded]).not_to be_empty
      end

      it "includes transient patterns" do
        expect(provider.error_patterns[:transient]).not_to be_empty
      end
    end

    describe "#execution_semantics" do
      it "reports uses_subcommand as true" do
        expect(provider.execution_semantics[:uses_subcommand]).to be true
      end

      it "reports output_format as json" do
        expect(provider.execution_semantics[:output_format]).to eq(:json)
      end

      it "reports shared rate-limit reset parsing support" do
        expect(provider.execution_semantics[:parses_rate_limit_reset]).to be true
      end
    end

    describe "#parse_rate_limit_reset" do
      it "parses Z.ai coding plan reset timestamps" do
        result = provider.parse_rate_limit_reset(
          "Weekly/Monthly Limit Exhausted. Your limit will reset at 2026-05-18 11:22:32"
        )

        expect(result).to eq(Time.utc(2026, 5, 18, 11, 22, 32))
      end
    end

    context "with token usage parsing" do
      around do |example|
        tracker = AgentHarness.token_tracker
        tracker.clear!
        example.run
        tracker.clear!
      end

      it "extracts token usage from a multi-event NDJSON stream" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Hello! How can I help?"}},
          {"type" => "result", "usage" => {"input_tokens" => 100, "output_tokens" => 50}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Hello! How can I help?")
        expect(response.tokens).to eq({input: 100, output: 50, total: 150})
        expect(response.input_tokens).to eq(100)
        expect(response.output_tokens).to eq(50)
        expect(response.total_tokens).to eq(150)
      end

      it "concatenates text from multiple text events" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Hello! "}},
          {"type" => "text", "part" => {"text" => "How can I help?"}},
          {"type" => "result", "usage" => {"input_tokens" => 100, "output_tokens" => 50}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Hello! How can I help?")
        expect(response.tokens).to eq({input: 100, output: 50, total: 150})
      end

      it "extracts text chunks from top-level aliases on text events" do
        ndjson = [
          {"type" => "text", "text" => "Hello! "},
          {"type" => "text", "message" => {"text" => "How can I help?"}},
          {"type" => "result", "usage" => {"input_tokens" => 100, "output_tokens" => 50}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Hello! How can I help?")
        expect(response.tokens).to eq({input: 100, output: 50, total: 150})
      end

      it "extracts text chunks from scalar top-level message aliases on text events" do
        ndjson = [
          {"type" => "text", "message" => "Hello! "},
          {"type" => "text", "text" => "How can I help?"},
          {"type" => "result", "usage" => {"input_tokens" => 100, "output_tokens" => 50}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Hello! How can I help?")
        expect(response.tokens).to eq({input: 100, output: 50, total: 150})
      end

      it "falls through blank hash-shaped top-level message text aliases on text events" do
        ndjson = [
          {"type" => "text", "message" => {"text" => "", "message" => "Hello! "}},
          {"type" => "text", "message" => {"text" => " \t", "message" => "How can I help?"}},
          {"type" => "result", "usage" => {"input_tokens" => 100, "output_tokens" => 50}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Hello! How can I help?")
        expect(response.tokens).to eq({input: 100, output: 50, total: 150})
      end

      it "extracts text chunks from scalar part payloads on text events" do
        ndjson = [
          {"type" => "text", "part" => "Hello! "},
          {"type" => "text", "part" => {"text" => "How can I help?"}},
          {"type" => "result", "usage" => {"input_tokens" => 100, "output_tokens" => 50}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Hello! How can I help?")
        expect(response.tokens).to eq({input: 100, output: 50, total: 150})
      end

      it "preserves whitespace in hash-shaped text event aliases" do
        ndjson = [
          {"type" => "text", "message" => {"text" => "Hello! "}},
          {"type" => "text", "text" => {"message" => "How can I help?"}},
          {"type" => "result", "usage" => {"input_tokens" => 100, "output_tokens" => 50}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Hello! How can I help?")
        expect(response.tokens).to eq({input: 100, output: 50, total: 150})
      end

      it "falls through blank text aliases to populated message aliases on text events" do
        ndjson = [
          {"type" => "text", "text" => {"text" => "", "message" => "Hello! "}},
          {"type" => "text", "text" => "", "message" => "How can I help?"},
          {"type" => "result", "usage" => {"input_tokens" => 100, "output_tokens" => 50}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Hello! How can I help?")
        expect(response.tokens).to eq({input: 100, output: 50, total: 150})
      end

      it "falls through whitespace-only text aliases to populated message aliases on text events" do
        ndjson = [
          {"type" => "text", "text" => {"text" => "   ", "message" => "Hello! "}},
          {"type" => "text", "text" => " \t", "message" => "How can I help?"},
          {"type" => "result", "usage" => {"input_tokens" => 100, "output_tokens" => 50}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Hello! How can I help?")
        expect(response.tokens).to eq({input: 100, output: 50, total: 150})
      end

      it "falls through blank and whitespace part text payloads to part message aliases on text events" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "", "message" => "Hello! "}},
          {"type" => "text", "part" => {"text" => " \t", "message" => "How can I help?"}},
          {"type" => "result", "usage" => {"input_tokens" => 100, "output_tokens" => 50}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Hello! How can I help?")
        expect(response.tokens).to eq({input: 100, output: 50, total: 150})
      end

      it "extracts hash-shaped part text aliases on text events" do
        ndjson = [
          {"type" => "text", "part" => {"text" => {"message" => "Hello! "}}},
          {"type" => "text", "part" => {"text" => {"text" => "How can I help?"}}},
          {"type" => "result", "usage" => {"input_tokens" => 100, "output_tokens" => 50}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Hello! How can I help?")
        expect(response.tokens).to eq({input: 100, output: 50, total: 150})
      end

      it "falls through whitespace-only part message aliases to populated top-level aliases on text events" do
        ndjson = [
          {"type" => "text", "part" => {"message" => " \t"}, "text" => "Hello! "},
          {"type" => "text", "part" => {"message" => "\n"}, "message" => {"text" => "How can I help?"}},
          {"type" => "result", "usage" => {"input_tokens" => 100, "output_tokens" => 50}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Hello! How can I help?")
        expect(response.tokens).to eq({input: 100, output: 50, total: 150})
      end

      it "falls through blank hash-shaped part message aliases on text events" do
        ndjson = [
          {"type" => "text", "part" => {"message" => {"text" => "", "message" => "Hello! "}}},
          {"type" => "text", "part" => {"message" => {"text" => " \t", "message" => "How can I help?"}}},
          {"type" => "result", "usage" => {"input_tokens" => 100, "output_tokens" => 50}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Hello! How can I help?")
        expect(response.tokens).to eq({input: 100, output: 50, total: 150})
      end

      it "handles NDJSON output without usage data" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Hello!"}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Hello!")
        expect(response.tokens).to be_nil
      end

      it "handles non-JSON output gracefully" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "plain text response",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("plain text response")
        expect(response.tokens).to be_nil
      end

      it "preserves raw output for non-event JSON objects" do
        raw_json = JSON.generate({"message" => "plain json response"})

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: raw_json,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq(raw_json)
        expect(response.tokens).to be_nil
      end

      it "preserves raw output for JSON objects with unknown type values" do
        raw_json = JSON.generate({
          "type" => "object",
          "message" => "plain json response",
          "usage" => {"input_tokens" => 100, "output_tokens" => 50}
        })

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: raw_json,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq(raw_json)
        expect(response.tokens).to be_nil
      end

      it "handles usage containing only input tokens" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response text"}},
          {"type" => "result", "usage" => {"input_tokens" => 80}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 80, output: 0, total: 80})
      end

      it "handles usage containing only output tokens" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response text"}},
          {"type" => "result", "usage" => {"output_tokens" => 30}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 0, output: 30, total: 30})
      end

      it "extracts usage from a standalone usage event" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {"type" => "usage", "usage" => {"input_tokens" => 10, "output_tokens" => 5}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Response")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "ignores usage hashes on non-usage event types" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}, "usage" => {"input_tokens" => 999, "output_tokens" => 999}},
          {"type" => "error", "message" => "boom", "usage" => {"input_tokens" => 888, "output_tokens" => 888}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Response")
        expect(response.tokens).to be_nil
        expect(response.error).to eq("boom")
        expect(response.failed?).to be true
      end

      it "records tokens with the global token tracker" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Tracked response"}},
          {"type" => "result", "usage" => {"input_tokens" => 50, "output_tokens" => 25}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        provider.send_message(prompt: "Hello")

        summary = AgentHarness.token_tracker.summary
        expect(summary[:total_input_tokens]).to eq(50)
        expect(summary[:total_output_tokens]).to eq(25)
        expect(summary[:total_tokens]).to eq(75)
      end

      it "sets error and output when failed but stdout contains valid NDJSON" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Partial response"}},
          {"type" => "result", "usage" => {"input_tokens" => 10, "output_tokens" => 5}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "something went wrong",
            exit_code: 1,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.failed?).to be true
        expect(response.error).to eq("something went wrong")
        expect(response.output).to eq("Partial response")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "uses a generic exit error when structured output fails without stderr" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Partial response"}},
          {"type" => "result", "usage" => {"input_tokens" => 10, "output_tokens" => 5}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 1,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.failed?).to be true
        expect(response.error).to eq("Kilocode exited with code 1")
        expect(response.error).not_to include("\"type\":\"text\"")
        expect(response.output).to eq("Partial response")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "preserves fallback stdout diagnostics for mixed structured failures" do
        stdout = [
          JSON.generate({"type" => "text", "part" => {"text" => "Partial response"}}),
          "network timeout while uploading transcript"
        ].join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: stdout,
            stderr: "",
            exit_code: 1,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.failed?).to be true
        expect(response.error).to eq("network timeout while uploading transcript")
        expect(response.error).to include("network timeout while uploading transcript")
        expect(response.output).to eq("Partial response")
      end

      it "classifies errors on non-zero exit code" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "",
            stderr: "rate limit exceeded",
            exit_code: 1,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.failed?).to be true
        expect(response.error).to eq("rate limit exceeded")
      end

      it "combines stderr before stdout for non-structured failures" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "stdout error detail",
            stderr: "stderr error detail",
            exit_code: 1,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.failed?).to be true
        expect(response.output).to eq("stdout error detail")
        expect(response.error).to eq("stderr error detail\nstdout error detail")
      end

      it "treats structured error events as failures even on zero exit" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Partial response"}},
          {"type" => "error", "message" => "Provider request failed"}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.failed?).to be true
        expect(response.output).to eq("Partial response")
        expect(response.error).to eq("Provider request failed")
      end

      it "captures structured error text from nested payloads" do
        ndjson = [
          {"type" => "error", "error" => {"message" => "Nested provider failure"}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 10, "output" => 5}}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.failed?).to be true
        expect(response.error).to eq("Nested provider failure")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "captures structured error text from hash-shaped nested payload aliases" do
        ndjson = [
          {"type" => "error", "error" => {"message" => {"text" => "Nested provider failure"}}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 10, "output" => 5}}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.failed?).to be true
        expect(response.error).to eq("Nested provider failure")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "preserves plain-text stdout diagnostics alongside structured error messages" do
        stdout = [
          JSON.generate({"type" => "error", "message" => "Provider request failed"}),
          JSON.generate({"type" => "step_finish", "part" => {"tokens" => {"input" => 10, "output" => 5}}}),
          "network timeout while uploading transcript"
        ].join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: stdout,
            stderr: "",
            exit_code: 1,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.failed?).to be true
        expect(response.error).to eq("Provider request failed\nnetwork timeout while uploading transcript")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "deduplicates identical stderr and structured error messages" do
        ndjson = [
          {"type" => "error", "message" => "Provider request failed"},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 10, "output" => 5}}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "Provider request failed",
            exit_code: 1,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.failed?).to be true
        expect(response.error).to eq("Provider request failed")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "deduplicates identical structured and plain-text stdout error messages" do
        stdout = [
          JSON.generate({"type" => "error", "message" => "Provider request failed"}),
          JSON.generate({"type" => "step_finish", "part" => {"tokens" => {"input" => 10, "output" => 5}}}),
          "Provider request failed"
        ].join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: stdout,
            stderr: "",
            exit_code: 1,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.failed?).to be true
        expect(response.error).to eq("Provider request failed")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "captures structured error text from nested error data payloads" do
        ndjson = [
          {"type" => "error", "error" => {"data" => {"message" => "Nested data failure"}}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 10, "output" => 5}}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.failed?).to be true
        expect(response.error).to eq("Nested data failure")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "captures structured error text from nested part error payloads" do
        ndjson = [
          {"type" => "error", "part" => {"error" => {"data" => {"message" => "Nested part failure"}}}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 10, "output" => 5}}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.failed?).to be true
        expect(response.error).to eq("Nested part failure")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "captures structured error text from direct part error message payloads" do
        ndjson = [
          {"type" => "error", "message" => "   ", "part" => {"error" => {"message" => "Direct part failure"}}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 10, "output" => 5}}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.failed?).to be true
        expect(response.error).to eq("Direct part failure")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "captures structured error text from hash-shaped direct part error message payloads" do
        ndjson = [
          {"type" => "error", "message" => "   ", "part" => {"error" => {"message" => {"text" => "Direct part failure"}}}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 10, "output" => 5}}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.failed?).to be true
        expect(response.error).to eq("Direct part failure")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "captures structured error text from scalar part error payloads" do
        ndjson = [
          {"type" => "error", "message" => "   ", "part" => {"error" => "Scalar part failure"}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 10, "output" => 5}}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.failed?).to be true
        expect(response.error).to eq("Scalar part failure")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "captures structured error text from part message payloads" do
        ndjson = [
          {"type" => "error", "message" => "   ", "part" => {"message" => "Part message failure"}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 10, "output" => 5}}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.failed?).to be true
        expect(response.error).to eq("Part message failure")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "captures structured error text from scalar part payloads" do
        ndjson = [
          {"type" => "error", "message" => "   ", "part" => "Scalar part failure"},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 10, "output" => 5}}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.failed?).to be true
        expect(response.error).to eq("Scalar part failure")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "captures structured error text from top-level message hash aliases" do
        ndjson = [
          {"type" => "error", "message" => {"text" => "Top-level hash failure"}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 10, "output" => 5}}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.failed?).to be true
        expect(response.error).to eq("Top-level hash failure")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "falls through blank top-level message hash aliases on structured errors" do
        ndjson = [
          {"type" => "error", "message" => {"text" => " \t", "message" => "Top-level hash failure"}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 10, "output" => 5}}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.failed?).to be true
        expect(response.error).to eq("Top-level hash failure")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "captures structured error text from top-level text aliases" do
        ndjson = [
          {"type" => "error", "text" => {"message" => "Top-level text failure"}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 10, "output" => 5}}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.failed?).to be true
        expect(response.error).to eq("Top-level text failure")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "falls through blank top-level text aliases on structured errors" do
        ndjson = [
          {"type" => "error", "text" => {"text" => " \t", "message" => "Top-level text failure"}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 10, "output" => 5}}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.failed?).to be true
        expect(response.error).to eq("Top-level text failure")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "captures structured error text from part message hash aliases" do
        ndjson = [
          {"type" => "error", "message" => "   ", "part" => {"message" => {"text" => "Part hash failure"}}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 10, "output" => 5}}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.failed?).to be true
        expect(response.error).to eq("Part hash failure")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "falls through blank part message hash aliases on structured errors" do
        ndjson = [
          {"type" => "error", "message" => "   ", "part" => {"message" => {"text" => " \t", "message" => "Part hash failure"}}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 10, "output" => 5}}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.failed?).to be true
        expect(response.error).to eq("Part hash failure")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "captures structured error text from part text payloads" do
        ndjson = [
          {"type" => "error", "message" => "   ", "part" => {"text" => "Part text failure"}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 10, "output" => 5}}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.failed?).to be true
        expect(response.error).to eq("Part text failure")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "falls through blank hash-shaped part text aliases on structured errors" do
        ndjson = [
          {"type" => "error", "message" => "   ", "part" => {"text" => {"text" => " \t", "message" => "Part text failure"}}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 10, "output" => 5}}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.failed?).to be true
        expect(response.error).to eq("Part text failure")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "handles scalar structured error payloads without raising" do
        ndjson = [
          {"type" => "error", "error" => "Provider request failed"},
          {"type" => "error", "part" => 42},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 10, "output" => 5}}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.failed?).to be true
        expect(response.error).to eq("Provider request failed\n{\"type\":\"error\",\"part\":42}")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "handles empty stdout" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("")
        expect(response.tokens).to be_nil
      end

      it "handles nil stdout" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: nil,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to be_nil
        expect(response.tokens).to be_nil
      end

      it "does not return raw NDJSON when structured output has no text events" do
        ndjson = [
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 20, "output" => 10}}},
          {"type" => "result", "usage" => {"input_tokens" => 25, "output_tokens" => 12}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to be_nil
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "uses terminal result payload text when no text events are emitted" do
        ndjson = [
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 20, "output" => 10}}},
          {"type" => "result", "result" => "Final answer", "usage" => {"input_tokens" => 25, "output_tokens" => 12}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Final answer")
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "preserves leading and trailing whitespace in terminal result payload text" do
        ndjson = [
          {"type" => "result", "result" => "  Final answer  ", "usage" => {"input_tokens" => 25, "output_tokens" => 12}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("  Final answer  ")
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "uses terminal result payload text from structured hash payloads" do
        ndjson = [
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 20, "output" => 10}}},
          {"type" => "result", "result" => {"text" => "Final answer"}, "usage" => {"input_tokens" => 25, "output_tokens" => 12}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Final answer")
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "preserves leading and trailing whitespace in terminal result hash aliases" do
        ndjson = [
          {
            "type" => "result",
            "result" => {"text" => "   ", "message" => "  Final answer  "},
            "usage" => {"input_tokens" => 25, "output_tokens" => 12}
          }
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("  Final answer  ")
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "uses terminal result payload message from structured hash payloads" do
        ndjson = [
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 20, "output" => 10}}},
          {"type" => "result", "result" => {"text" => "", "message" => "Final answer"}, "usage" => {"input_tokens" => 25, "output_tokens" => 12}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Final answer")
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "uses terminal result payload text from part aliases when result is absent" do
        ndjson = [
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 20, "output" => 10}}},
          {"type" => "result", "part" => {"text" => "Final answer"}, "usage" => {"input_tokens" => 25, "output_tokens" => 12}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Final answer")
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "uses terminal result payload message from part aliases when result is absent" do
        ndjson = [
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 20, "output" => 10}}},
          {"type" => "result", "part" => {"text" => "", "message" => "Final answer"}, "usage" => {"input_tokens" => 25, "output_tokens" => 12}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Final answer")
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "falls through blank hash-shaped part text aliases on terminal result events" do
        ndjson = [
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 20, "output" => 10}}},
          {
            "type" => "result",
            "part" => {"text" => {"text" => " \t", "message" => "Final answer"}},
            "usage" => {"input_tokens" => 25, "output_tokens" => 12}
          }
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Final answer")
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "falls through blank hash-shaped part message aliases on terminal result events" do
        ndjson = [
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 20, "output" => 10}}},
          {
            "type" => "result",
            "part" => {"message" => {"text" => " \t", "message" => "Final answer"}},
            "usage" => {"input_tokens" => 25, "output_tokens" => 12}
          }
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Final answer")
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "uses terminal result payload message when result and part payloads are absent" do
        ndjson = [
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 20, "output" => 10}}},
          {"type" => "result", "message" => "Final answer", "usage" => {"input_tokens" => 25, "output_tokens" => 12}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Final answer")
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "uses terminal result payload text when result and part payloads are absent" do
        ndjson = [
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 20, "output" => 10}}},
          {"type" => "result", "text" => "Final answer", "usage" => {"input_tokens" => 25, "output_tokens" => 12}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Final answer")
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "uses terminal result payload message from top-level hash aliases" do
        ndjson = [
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 20, "output" => 10}}},
          {"type" => "result", "message" => {"text" => "", "message" => "Final answer"}, "usage" => {"input_tokens" => 25, "output_tokens" => 12}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Final answer")
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "uses terminal result payload text from top-level hash aliases" do
        ndjson = [
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 20, "output" => 10}}},
          {"type" => "result", "message" => {"text" => "Final answer", "message" => "Ignored alias"}, "usage" => {"input_tokens" => 25, "output_tokens" => 12}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Final answer")
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "falls through blank top-level result text hash aliases to nested messages" do
        ndjson = [
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 20, "output" => 10}}},
          {
            "type" => "result",
            "text" => {"text" => " \t", "message" => "Final answer"},
            "usage" => {"input_tokens" => 25, "output_tokens" => 12}
          }
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Final answer")
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "falls through blank result and part payloads to a top-level message alias" do
        ndjson = [
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 20, "output" => 10}}},
          {
            "type" => "result",
            "result" => {"text" => " ", "message" => "\n"},
            "part" => {"text" => "", "message" => "\t"},
            "message" => "Final answer",
            "usage" => {"input_tokens" => 25, "output_tokens" => 12}
          }
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Final answer")
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "preserves terminal result payload text across later usage-only result events" do
        ndjson = [
          {"type" => "result", "result" => {"text" => "Final answer"}},
          {"type" => "result", "usage" => {"input_tokens" => 25, "output_tokens" => 12}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Final answer")
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "preserves terminal result payload message aliases across later usage-only result events" do
        ndjson = [
          {"type" => "result", "result" => {"text" => "", "message" => "Final answer"}},
          {"type" => "result", "usage" => {"input_tokens" => 25, "output_tokens" => 12}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Final answer")
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "preserves scalar part result payloads across later usage-only result events" do
        ndjson = [
          {"type" => "result", "part" => "Final answer"},
          {"type" => "result", "usage" => {"input_tokens" => 25, "output_tokens" => 12}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Final answer")
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "preserves top-level text hash aliases across later usage-only result events" do
        ndjson = [
          {"type" => "result", "text" => {"text" => "Final answer", "message" => "Ignored alias"}},
          {"type" => "result", "usage" => {"input_tokens" => 25, "output_tokens" => 12}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Final answer")
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "preserves top-level text aliases across later usage-only result events" do
        ndjson = [
          {"type" => "result", "text" => "Final answer"},
          {"type" => "result", "usage" => {"input_tokens" => 25, "output_tokens" => 12}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Final answer")
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "uses nested terminal result message hash aliases" do
        ndjson = [
          {"type" => "result", "result" => {"message" => {"text" => "Final answer"}}, "usage" => {"input_tokens" => 25, "output_tokens" => 12}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Final answer")
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "falls back to terminal result payload text when text events are blank" do
        ndjson = [
          {"type" => "text", "part" => {"text" => ""}},
          {"type" => "result", "result" => "Final answer", "usage" => {"input_tokens" => 25, "output_tokens" => 12}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Final answer")
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "falls back to terminal result payload text when text events are only whitespace" do
        ndjson = [
          {"type" => "text", "part" => {"text" => " \n\t "}},
          {"type" => "result", "result" => "Final answer", "usage" => {"input_tokens" => 25, "output_tokens" => 12}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Final answer")
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "preserves plain-text stdout mixed with structured events" do
        stdout = [
          JSON.generate({"type" => "step_finish", "part" => {"tokens" => {"input" => 20, "output" => 10}}}),
          "Final answer",
          JSON.generate({"type" => "result", "usage" => {"input_tokens" => 25, "output_tokens" => 12}})
        ].join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: stdout,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Final answer")
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "preserves leading and trailing whitespace in plain-text stdout mixed with structured events" do
        stdout = [
          JSON.generate({"type" => "step_finish", "part" => {"tokens" => {"input" => 20, "output" => 10}}}),
          "  Final answer  ",
          JSON.generate({"type" => "result", "usage" => {"input_tokens" => 25, "output_tokens" => 12}})
        ].join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: stdout,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("  Final answer  ")
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "preserves non-event JSON stdout mixed with structured events" do
        raw_json = JSON.generate({"message" => "Final answer"})
        stdout = [
          JSON.generate({"type" => "step_finish", "part" => {"tokens" => {"input" => 20, "output" => 10}}}),
          raw_json,
          JSON.generate({"type" => "result", "usage" => {"input_tokens" => 25, "output_tokens" => 12}})
        ].join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: stdout,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq(raw_json)
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "preserves non-event JSON arrays mixed with structured events" do
        raw_json = JSON.generate([{"message" => "Final answer"}])
        stdout = [
          JSON.generate({"type" => "step_finish", "part" => {"tokens" => {"input" => 20, "output" => 10}}}),
          raw_json,
          JSON.generate({"type" => "result", "usage" => {"input_tokens" => 25, "output_tokens" => 12}})
        ].join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: stdout,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq(raw_json)
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "does not treat whitespace-only terminal result strings as output" do
        ndjson = [
          {"type" => "result", "result" => " \n\t ", "usage" => {"input_tokens" => 25, "output_tokens" => 12}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to be_nil
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "preserves earlier terminal result text when a later result string is only whitespace" do
        ndjson = [
          {"type" => "result", "result" => "Final answer"},
          {"type" => "result", "result" => " \n\t ", "usage" => {"input_tokens" => 25, "output_tokens" => 12}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Final answer")
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "preserves earlier terminal result text when a later result hash is blank" do
        ndjson = [
          {"type" => "result", "result" => {"text" => "Final answer"}},
          {"type" => "result", "result" => {"text" => "   ", "message" => "\t"}, "usage" => {"input_tokens" => 25, "output_tokens" => 12}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Final answer")
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "preserves earlier top-level result message aliases across later usage-only result events" do
        ndjson = [
          {"type" => "result", "message" => "Final answer"},
          {"type" => "result", "usage" => {"input_tokens" => 25, "output_tokens" => 12}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Final answer")
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "preserves earlier top-level result hash aliases across later usage-only result events" do
        ndjson = [
          {"type" => "result", "message" => {"text" => "Final answer", "message" => "Ignored alias"}},
          {"type" => "result", "usage" => {"input_tokens" => 25, "output_tokens" => 12}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Final answer")
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "preserves nested top-level result hash fallback output across later usage-only result events" do
        ndjson = [
          {"type" => "result", "message" => {"text" => " \t", "message" => "Final answer"}},
          {"type" => "result", "usage" => {"input_tokens" => 25, "output_tokens" => 12}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Final answer")
        expect(response.tokens).to eq({input: 25, output: 12, total: 37})
      end

      it "does not return raw NDJSON for structured error-only output" do
        ndjson = [
          {"type" => "error", "message" => "Provider request failed"}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.failed?).to be true
        expect(response.output).to be_nil
        expect(response.error).to eq("Provider request failed")
      end

      it "skips scalar JSON values (true, false, null, numbers, strings) in the event stream" do
        ndjson = [
          "true",
          "false",
          "null",
          "42",
          "\"ok\"",
          JSON.generate({"type" => "text", "part" => {"text" => "valid text"}}),
          JSON.generate({"type" => "result", "usage" => {"input_tokens" => 5, "output_tokens" => 3}})
        ].join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("valid text")
        expect(response.tokens).to eq({input: 5, output: 3, total: 8})
      end

      it "does not leak scalar JSON lines into fallback diagnostics for structured streams" do
        stdout = [
          "true",
          "42",
          "\"ignored\"",
          JSON.generate({"type" => "error", "message" => "Provider request failed"}),
          JSON.generate({"type" => "step_finish", "part" => {"tokens" => {"input" => 10, "output" => 5}}})
        ].join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: stdout,
            stderr: "",
            exit_code: 1,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.failed?).to be true
        expect(response.error).to eq("Provider request failed")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "skips malformed JSON lines in the event stream" do
        ndjson = [
          "not-json",
          JSON.generate({"type" => "text", "part" => {"text" => "valid text"}}),
          "",
          JSON.generate({"type" => "result", "usage" => {"input_tokens" => 5, "output_tokens" => 3}})
        ].join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("valid text")
        expect(response.tokens).to eq({input: 5, output: 3, total: 8})
      end

      it "extracts tokens from step_finish event part.tokens" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Done!"}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 200, "output" => 100}}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Done!")
        expect(response.tokens).to eq({input: 200, output: 100, total: 300})
      end

      it "prefers usage from result event over step_finish when both present" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 10, "output" => 5}}},
          {"type" => "result", "usage" => {"input_tokens" => 50, "output_tokens" => 25}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 50, output: 25, total: 75})
      end

      it "handles step_finish with only input token count" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Partial"}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 42}}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 42, output: 0, total: 42})
      end

      it "handles step_finish with only output token count" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Partial"}},
          {"type" => "step_finish", "part" => {"tokens" => {"output" => 37}}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 0, output: 37, total: 37})
      end

      it "skips step_finish when part.tokens is not a Hash" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Done!"}},
          {"type" => "step_finish", "part" => {"tokens" => "not-a-hash"}},
          {"type" => "result", "usage" => {"input_tokens" => 10, "output_tokens" => 5}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Done!")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "skips non-integer token values in step_finish payloads" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Done!"}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => {"bad" => true}, "output" => [1, 2]}}},
          {"type" => "result", "usage" => {"input_tokens" => 10, "output_tokens" => 5}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Done!")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "accepts plain decimal string token values" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Done!"}},
          {"type" => "result", "usage" => {"input_tokens" => "120", "output_tokens" => "40", "total_tokens" => "160"}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Done!")
        expect(response.tokens).to eq({input: 120, output: 40, total: 160})
      end

      it "accepts plain decimal strings in extra result usage token categories" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Done!"}},
          {
            "type" => "result",
            "usage" => {
              "input_tokens" => "120",
              "output_tokens" => "40",
              "reasoning_tokens" => "10",
              "cache_creation_input_tokens" => "3",
              "cache_read_input_tokens" => "2"
            }
          }
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Done!")
        expect(response.tokens).to eq({input: 120, output: 40, total: 175})
      end

      it "accepts plain decimal string token values in step_finish payloads" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Done!"}},
          {
            "type" => "step_finish",
            "part" => {
              "tokens" => {
                "input" => "120",
                "output" => "40",
                "reasoning" => "10",
                "cache" => {"read" => "3", "write" => "2"}
              }
            }
          }
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Done!")
        expect(response.tokens).to eq({input: 120, output: 40, total: 175})
      end

      it "ignores malformed numeric string token values" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Done!"}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 100, "output" => 50}}},
          {"type" => "result", "usage" => {"input_tokens" => "0x10", "output_tokens" => "1_000", "total_tokens" => "+20"}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Done!")
        expect(response.tokens).to eq({input: 100, output: 50, total: 150})
      end

      it "ignores non-integral float token values in step_finish payloads" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Done!"}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 12.5, "output" => 3.75}}},
          {"type" => "result", "usage" => {"input_tokens" => 10, "output_tokens" => 5}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Done!")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "ignores negative token values in step_finish payloads" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Done!"}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => -10, "output" => 5}}},
          {"type" => "result", "usage" => {"input_tokens" => 10, "output_tokens" => 5}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Done!")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "skips text and step_finish events whose part payloads are malformed scalars" do
        ndjson = [
          {"type" => "text", "part" => 42},
          {"type" => "step_finish", "part" => 42},
          {"type" => "text", "part" => {"text" => "Done!"}},
          {"type" => "result", "usage" => {"input_tokens" => 10, "output_tokens" => 5}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Done!")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "ignores text events whose part.text payload is not a String" do
        ndjson = [
          {"type" => "text", "part" => {"text" => {"bad" => true}}},
          {"type" => "text", "part" => {"text" => 42}},
          {"type" => "text", "part" => {"text" => "Done!"}},
          {"type" => "result", "usage" => {"input_tokens" => 10, "output_tokens" => 5}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Done!")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "skips usage payloads that are not Hashes" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Done!"}, "usage" => "invalid"},
          {"type" => "result", "usage" => {"input_tokens" => 10, "output_tokens" => 5}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Done!")
        expect(response.tokens).to eq({input: 10, output: 5, total: 15})
      end

      it "uses last usage event when multiple events contain usage" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}, "usage" => {"input_tokens" => 10, "output_tokens" => 5}},
          {"type" => "result", "usage" => {"input_tokens" => 50, "output_tokens" => 25}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Response")
        expect(response.tokens).to eq({input: 50, output: 25, total: 75})
      end

      it "preserves earlier valid usage fields when a later usage event is only partial" do
        ndjson = [
          {"type" => "usage", "usage" => {"input_tokens" => 100, "output_tokens" => 50, "total_tokens" => 150}},
          {"type" => "result", "usage" => {"input_tokens" => 120}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 120, output: 50, total: 170})
      end

      it "recomputes totals when a later usage event adds only extra token categories" do
        ndjson = [
          {"type" => "usage", "usage" => {"input_tokens" => 100, "output_tokens" => 50, "total_tokens" => 150}},
          {"type" => "result", "usage" => {"reasoning_tokens" => 20}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 100, output: 50, total: 170})
      end

      it "clears stale extra usage categories when a later usage event updates both input and output" do
        ndjson = [
          {"type" => "usage", "usage" => {"input_tokens" => 100, "output_tokens" => 50, "reasoning_tokens" => 20}},
          {"type" => "result", "usage" => {"input_tokens" => 120, "output_tokens" => 40}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 120, output: 40, total: 160})
      end

      it "clears stale omitted extra usage categories when a later usage event updates both input and output" do
        ndjson = [
          {
            "type" => "usage",
            "usage" => {
              "input_tokens" => 100,
              "output_tokens" => 50,
              "reasoning_tokens" => 20,
              "cache_read_input_tokens" => 15
            }
          },
          {"type" => "result", "usage" => {"input_tokens" => 120, "output_tokens" => 40, "reasoning_tokens" => 10}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 120, output: 40, total: 170})
      end

      it "clears stale extra usage categories when a later usage event provides full counts and an explicit total" do
        ndjson = [
          {
            "type" => "usage",
            "usage" => {
              "input_tokens" => 100,
              "output_tokens" => 50,
              "reasoning_tokens" => 20,
              "cache_read_input_tokens" => 15
            }
          },
          {
            "type" => "result",
            "usage" => {
              "input_tokens" => 120,
              "output_tokens" => 40,
              "total_tokens" => 165
            }
          }
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 120, output: 40, total: 165})
      end

      it "clears stale extra usage categories when a later usage event provides full counts and an explicit total alias" do
        ndjson = [
          {
            "type" => "usage",
            "usage" => {
              "input_tokens" => 100,
              "output_tokens" => 50,
              "reasoning_tokens" => 20,
              "cache_read_input_tokens" => 15
            }
          },
          {
            "type" => "result",
            "usage" => {
              "input_tokens" => 120,
              "output_tokens" => 40,
              "total" => 162
            }
          }
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 120, output: 40, total: 162})
      end

      it "clears stale extra usage categories when a later usage event provides full counts, fresh extras, and an explicit total alias" do
        ndjson = [
          {
            "type" => "usage",
            "usage" => {
              "input_tokens" => 100,
              "output_tokens" => 50,
              "reasoning_tokens" => 20,
              "cache_read_input_tokens" => 15
            }
          },
          {
            "type" => "result",
            "usage" => {
              "input_tokens" => 120,
              "output_tokens" => 40,
              "reasoning_tokens" => 10,
              "total" => 175
            }
          }
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 120, output: 40, total: 175})
      end

      it "clears stale extra usage categories when a later usage event provides full counts, fresh extras, and explicit total_tokens" do
        ndjson = [
          {
            "type" => "usage",
            "usage" => {
              "input_tokens" => 100,
              "output_tokens" => 50,
              "reasoning_tokens" => 20,
              "cache_read_input_tokens" => 15
            }
          },
          {
            "type" => "result",
            "usage" => {
              "input_tokens" => 120,
              "output_tokens" => 40,
              "reasoning_tokens" => 10,
              "total_tokens" => 175
            }
          }
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 120, output: 40, total: 175})
      end

      it "clears an earlier total alias when a later usage event adds only extra token categories" do
        ndjson = [
          {"type" => "usage", "usage" => {"input_tokens" => 100, "output_tokens" => 50, "total" => 190}},
          {"type" => "result", "usage" => {"reasoning_tokens" => 20}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 100, output: 50, total: 170})
      end

      it "preserves earlier input and output counts when a later usage event updates only total_tokens" do
        ndjson = [
          {"type" => "usage", "usage" => {"input_tokens" => 100, "output_tokens" => 50, "total_tokens" => 150}},
          {"type" => "result", "usage" => {"total_tokens" => 175}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 100, output: 50, total: 175})
      end

      it "preserves earlier input and output counts when a later usage event updates only total" do
        ndjson = [
          {"type" => "usage", "usage" => {"input_tokens" => 100, "output_tokens" => 50, "total_tokens" => 150}},
          {"type" => "result", "usage" => {"total" => 180}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 100, output: 50, total: 180})
      end

      it "fills missing input and output from step totals when result usage updates only total alias" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 100, "output" => 50}}},
          {"type" => "result", "usage" => {"total" => 180}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 100, output: 50, total: 180})
      end

      it "fills missing input and output from step totals when result usage updates only total_tokens" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 100, "output" => 50}}},
          {"type" => "result", "usage" => {"total_tokens" => 180}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 100, output: 50, total: 180})
      end

      it "clears an earlier total alias when a later usage event updates non-total fields" do
        ndjson = [
          {"type" => "usage", "usage" => {"input_tokens" => 100, "output_tokens" => 50, "total" => 190}},
          {"type" => "result", "usage" => {"input_tokens" => 120}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 120, output: 50, total: 170})
      end

      it "clears stale total aliases and extra categories on a later full usage replacement" do
        ndjson = [
          {
            "type" => "usage",
            "usage" => {
              "input_tokens" => 100,
              "output_tokens" => 50,
              "total" => 190,
              "reasoning_tokens" => 20,
              "cache_read_input_tokens" => 20
            }
          },
          {
            "type" => "result",
            "usage" => {
              "input_tokens" => 120,
              "output_tokens" => 40,
              "reasoning_tokens" => 10
            }
          }
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 120, output: 40, total: 170})
      end

      it "preserves earlier valid usage when a later usage hash is empty" do
        ndjson = [
          {"type" => "result", "usage" => {"input_tokens" => 50, "output_tokens" => 25}},
          {"type" => "usage", "usage" => {}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 50, output: 25, total: 75})
      end

      it "preserves earlier valid usage when a later usage hash has no usable token counts" do
        ndjson = [
          {"type" => "result", "usage" => {"input_tokens" => 50, "output_tokens" => 25}},
          {"type" => "usage", "usage" => {"input_tokens" => {"bad" => true}, "output_tokens" => -1}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 50, output: 25, total: 75})
      end

      it "falls back to accumulated step_finish tokens when usage token values are invalid" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 100, "output" => 50}}},
          {"type" => "result", "usage" => {"input_tokens" => {"bad" => true}, "output_tokens" => [1, 2]}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Response")
        expect(response.tokens).to eq({input: 100, output: 50, total: 150})
      end

      it "falls back to accumulated step_finish tokens when usage token values are non-integral floats" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 100, "output" => 50}}},
          {"type" => "result", "usage" => {"input_tokens" => 120.5, "output_tokens" => 40.25}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Response")
        expect(response.tokens).to eq({input: 100, output: 50, total: 150})
      end

      it "falls back to accumulated step_finish tokens when usage token values are negative" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 100, "output" => 50}}},
          {"type" => "result", "usage" => {"input_tokens" => -1, "output_tokens" => -2}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Response")
        expect(response.tokens).to eq({input: 100, output: 50, total: 150})
      end

      it "accumulates token counts across multiple step_finish events" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Step 1"}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 100, "output" => 50}}},
          {"type" => "text", "part" => {"text" => "Step 2"}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 80, "output" => 40}}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.output).to eq("Step 1Step 2")
        expect(response.tokens).to eq({input: 180, output: 90, total: 270})
      end

      it "prefers result usage over accumulated step_finish tokens" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 100, "output" => 50}}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 80, "output" => 40}}},
          {"type" => "result", "usage" => {"input_tokens" => 200, "output_tokens" => 100}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 200, output: 100, total: 300})
      end

      it "preserves explicit step totals when step metadata includes extra token categories" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 100, "output" => 50, "total" => 175}}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 80, "output" => 40, "total_tokens" => 150}}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 180, output: 90, total: 325})
      end

      it "falls back to total when step total_tokens is malformed" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 100, "output" => 50, "total_tokens" => "bad", "total" => 175}}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 100, output: 50, total: 175})
      end

      it "honors plain decimal string step total aliases over synthesized totals" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {
            "type" => "step_finish",
            "part" => {
              "tokens" => {
                "input" => "100",
                "output" => "50",
                "reasoning" => "20",
                "cache" => {"read" => "15", "write" => "10"},
                "total" => "175"
              }
            }
          }
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 100, output: 50, total: 175})
      end

      it "includes reasoning and cache tokens in step totals when total is omitted" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {
            "type" => "step_finish",
            "part" => {
              "tokens" => {
                "input" => 100,
                "output" => 50,
                "reasoning" => 20,
                "cache" => {"read" => 15, "write" => 10}
              }
            }
          }
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 100, output: 50, total: 195})
      end

      it "accumulates synthesized step totals across multiple step_finish events" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {
            "type" => "step_finish",
            "part" => {
              "tokens" => {
                "input" => 100,
                "output" => 50,
                "reasoning" => 20,
                "cache" => {"read" => 15}
              }
            }
          },
          {
            "type" => "step_finish",
            "part" => {
              "tokens" => {
                "input" => 80,
                "output" => 40,
                "reasoning" => 10,
                "cache" => {"write" => 5}
              }
            }
          }
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 180, output: 90, total: 320})
      end

      it "preserves explicit result usage totals when usage includes extra token categories" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {"type" => "result", "usage" => {"input_tokens" => 100, "output_tokens" => 50, "total_tokens" => 175}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 100, output: 50, total: 175})
      end

      it "counts known extra result usage token categories when total is omitted" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {
            "type" => "result",
            "usage" => {
              "input_tokens" => 100,
              "output_tokens" => 50,
              "reasoning_tokens" => 20,
              "cache_creation_input_tokens" => 10,
              "cache_read_input_tokens" => 15,
              "cache_write_input_tokens" => 5
            }
          }
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 100, output: 50, total: 200})
      end

      it "counts extra result usage token categories when input and output tokens are absent" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {
            "type" => "result",
            "usage" => {
              "reasoning_tokens" => 20,
              "cache_creation_input_tokens" => 10,
              "cache_read_input_tokens" => 15,
              "cache_write_input_tokens" => 5
            }
          }
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 0, output: 0, total: 50})
      end

      it "ignores malformed extra result usage token categories when synthesizing totals" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {
            "type" => "result",
            "usage" => {
              "input_tokens" => 100,
              "output_tokens" => 50,
              "reasoning_tokens" => 20.5,
              "cache_creation_input_tokens" => -1,
              "cache_read_input_tokens" => {"bad" => true},
              "cache_write_input_tokens" => 5
            }
          }
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 100, output: 50, total: 155})
      end

      it "falls back to total when usage total_tokens is malformed" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {"type" => "result", "usage" => {"input_tokens" => 100, "output_tokens" => 50, "total_tokens" => "bad", "total" => 175}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 100, output: 50, total: 175})
      end

      it "keeps explicit result totals over larger accumulated step totals" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {
            "type" => "step_finish",
            "part" => {
              "tokens" => {
                "input" => 100,
                "output" => 50,
                "reasoning" => 20,
                "cache" => {"read" => 15, "write" => 10}
              }
            }
          },
          {"type" => "result", "usage" => {"input_tokens" => 100, "output_tokens" => 50, "total_tokens" => 150}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 100, output: 50, total: 150})
      end

      it "prefers synthesized result totals over larger accumulated step totals" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {
            "type" => "step_finish",
            "part" => {
              "tokens" => {
                "input" => 100,
                "output" => 50,
                "reasoning" => 20,
                "cache" => {"read" => 15, "write" => 10}
              }
            }
          },
          {"type" => "result", "usage" => {"input_tokens" => 100, "output_tokens" => 50, "reasoning_tokens" => 10}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 100, output: 50, total: 160})
      end

      it "preserves total-only usage payloads" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {"type" => "result", "usage" => {"total_tokens" => 175}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 0, output: 0, total: 175})
      end

      it "falls back to accumulated step_finish tokens when usage is empty" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 100, "output" => 50}}},
          {"type" => "result", "usage" => {}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 100, output: 50, total: 150})
      end

      it "merges known extra usage token categories with accumulated step_finish totals" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 100, "output" => 50}}},
          {"type" => "result", "usage" => {"cache_creation_input_tokens" => 25}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 100, output: 50, total: 175})
      end

      it "returns nil tokens when usage is empty and no token counts were reported" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {"type" => "result", "usage" => {}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to be_nil
      end

      it "counts known result usage token categories without input or output totals" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {"type" => "result", "usage" => {"cache_creation_input_tokens" => 25}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 0, output: 0, total: 25})
      end

      it "returns nil tokens when usage has no known token keys and no fallback totals exist" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {"type" => "result", "usage" => {"cost_usd" => "0.12"}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to be_nil
      end

      it "fills missing usage token keys from accumulated step_finish totals" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 100, "output" => 50}}},
          {"type" => "result", "usage" => {"input_tokens" => 120}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 120, output: 50, total: 170})
      end

      it "preserves step-derived extra totals when usage only updates one token side" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {
            "type" => "step_finish",
            "part" => {
              "tokens" => {
                "input" => 100,
                "output" => 50,
                "reasoning" => 20,
                "cache" => {"read" => 5}
              }
            }
          },
          {"type" => "result", "usage" => {"input_tokens" => 120}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 120, output: 50, total: 195})
      end

      it "preserves explicit step totals that cannot be reconstructed from partial final usage" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {"type" => "step_finish", "part" => {"tokens" => {"total" => 175}}},
          {"type" => "result", "usage" => {"input_tokens" => 120}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 120, output: 0, total: 175})
      end

      it "uses result extra token categories when partial usage falls back to a step token side" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {
            "type" => "step_finish",
            "part" => {
              "tokens" => {
                "input" => 100,
                "output" => 50,
                "reasoning" => 20,
                "cache" => {"read" => 5}
              }
            }
          },
          {"type" => "result", "usage" => {"input_tokens" => 120, "reasoning_tokens" => 10}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 120, output: 50, total: 180})
      end

      it "uses result extra token categories when partial usage updates only output_tokens" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {
            "type" => "step_finish",
            "part" => {
              "tokens" => {
                "input" => 100,
                "output" => 50,
                "reasoning" => 20,
                "cache" => {"read" => 5}
              }
            }
          },
          {"type" => "result", "usage" => {"output_tokens" => 40, "reasoning_tokens" => 10}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 100, output: 40, total: 150})
      end

      it "preserves unreconstructable step totals when partial usage adds extra categories" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {"type" => "step_finish", "part" => {"tokens" => {"total" => 175}}},
          {"type" => "result", "usage" => {"input_tokens" => 120, "reasoning_tokens" => 10}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 120, output: 0, total: 175})
      end

      it "uses an explicit result total when partial usage falls back to a step token side" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {
            "type" => "step_finish",
            "part" => {
              "tokens" => {
                "input" => 100,
                "output" => 50,
                "reasoning" => 20,
                "cache" => {"read" => 5}
              }
            }
          },
          {"type" => "result", "usage" => {"output_tokens" => 40, "total_tokens" => 170}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 100, output: 40, total: 170})
      end

      it "fills malformed usage token values from accumulated step_finish totals" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {"type" => "step_finish", "part" => {"tokens" => {"input" => 100, "output" => 50}}},
          {"type" => "result", "usage" => {"input_tokens" => 120, "output_tokens" => {"bad" => true}}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 120, output: 50, total: 170})
      end

      it "recomputes total from updated usage instead of keeping a larger step fallback total" do
        ndjson = [
          {"type" => "text", "part" => {"text" => "Response"}},
          {
            "type" => "step_finish",
            "part" => {
              "tokens" => {
                "input" => 100,
                "output" => 50,
                "reasoning" => 20,
                "cache" => {"read" => 5}
              }
            }
          },
          {"type" => "result", "usage" => {"input_tokens" => 80, "output_tokens" => 40}}
        ].map { |e| JSON.generate(e) }.join("\n")

        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: ndjson,
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        response = provider.send_message(prompt: "Hello")
        expect(response.tokens).to eq({input: 80, output: 40, total: 120})
      end
    end
  end

  describe "#config_file_content" do
    let(:executor) { instance_double(AgentHarness::CommandExecutor, which: "/usr/bin/kilo") }
    let(:provider) { described_class.new(executor: executor) }

    it "returns JSON config with provider as nested object" do
      content = provider.config_file_content(
        provider_name: "anthropic",
        model_id: "claude-sonnet-4-6"
      )
      parsed = JSON.parse(content)

      expect(parsed["provider"]).to eq({"anthropic" => {}})
      expect(parsed["model"]).to eq("anthropic/claude-sonnet-4-6")
    end

    it "uses provider_name over api_provider when both given" do
      content = provider.config_file_content(
        provider_name: "openai",
        api_provider: "anthropic",
        model_id: "gpt-4o"
      )
      parsed = JSON.parse(content)

      expect(parsed["provider"]).to eq({"openai" => {}})
      expect(parsed["model"]).to eq("openai/gpt-4o")
    end

    it "ignores api_provider and defaults to openai when provider_name is not given" do
      content = provider.config_file_content(
        api_provider: "openrouter",
        model_id: "gpt-4o"
      )
      parsed = JSON.parse(content)

      # api_provider is a generic backend label (e.g. "openrouter"), not a valid
      # Kilo provider ID, so it must be ignored in favor of the "openai" default.
      expect(parsed["provider"]).to eq({"openai" => {}})
      expect(parsed["model"]).to eq("openai/gpt-4o")
    end

    it "defaults provider to openai with empty options" do
      content = provider.config_file_content
      parsed = JSON.parse(content)

      expect(parsed).to be_a(Hash)
      expect(parsed["provider"]).to eq({"openai" => {}})
      expect(parsed["model"]).to be_nil
    end

    context "with the default external_directory permission rule" do
      it "default-merges a permissive /tmp and home-directory external_directory permission into the config" do
        content = provider.config_file_content(
          provider_name: "anthropic",
          model_id: "claude-sonnet-4-6"
        )
        parsed = JSON.parse(content)

        expect(parsed["permission"]).to eq({
          "external_directory" => {"/tmp/**" => "allow", "/home/agent/**" => "allow"}
        })
      end

      it "writes the permission rule even when no provider/model is supplied" do
        parsed = JSON.parse(provider.config_file_content)

        expect(parsed["permission"]).to eq({
          "external_directory" => {"/tmp/**" => "allow", "/home/agent/**" => "allow"}
        })
      end

      it "merges a caller-supplied permission block on top of the default external_directory allowlist" do
        content = provider.config_file_content(
          provider_name: "openai",
          permission: {
            "external_directory" => {"/var/tmp/**" => "allow"},
            "bash" => "ask"
          }
        )
        parsed = JSON.parse(content)

        expect(parsed["permission"]).to eq({
          "external_directory" => {
            "/tmp/**" => "allow",
            "/home/agent/**" => "allow",
            "/var/tmp/**" => "allow"
          },
          "bash" => "ask"
        })
      end

      it "unions default and caller external_directory entries and lets the caller win on conflicts" do
        content = provider.config_file_content(
          permission: {
            "external_directory" => {
              "/tmp/**" => "deny",
              "/usr/local/lib/ruby/gems/*/gems/agent-harness-*/**" => "allow"
            }
          }
        )
        parsed = JSON.parse(content)

        expect(parsed["permission"]).to eq({
          "external_directory" => {
            "/tmp/**" => "deny",
            "/home/agent/**" => "allow",
            "/usr/local/lib/ruby/gems/*/gems/agent-harness-*/**" => "allow"
          }
        })
      end

      it "accepts a string-keyed caller permission option and merges it with the defaults" do
        content = provider.config_file_content(
          "permission" => {"external_directory" => {"/workspace/**" => "allow"}}
        )
        parsed = JSON.parse(content)

        expect(parsed["permission"]).to eq({
          "external_directory" => {
            "/tmp/**" => "allow",
            "/home/agent/**" => "allow",
            "/workspace/**" => "allow"
          }
        })
      end

      it "accepts a symbol-keyed external_directory category and merges it with the defaults" do
        content = provider.config_file_content(
          permission: {
            external_directory: {"/workspace/**" => "allow"}
          }
        )
        parsed = JSON.parse(content)

        expect(parsed["permission"]).to eq({
          "external_directory" => {
            "/tmp/**" => "allow",
            "/home/agent/**" => "allow",
            "/workspace/**" => "allow"
          }
        })
      end

      it "honors a caller-supplied permission block verbatim when permission_replace is set" do
        content = provider.config_file_content(
          provider_name: "openai",
          permission_replace: true,
          permission: {
            "external_directory" => {"/var/tmp/**" => "allow"},
            "bash" => "ask"
          }
        )
        parsed = JSON.parse(content)

        expect(parsed["permission"]).to eq({
          "external_directory" => {"/var/tmp/**" => "allow"},
          "bash" => "ask"
        })
        expect(parsed["permission"]["external_directory"]).not_to have_key("/tmp/**")
        expect(parsed["permission"]["external_directory"]).not_to have_key("/home/agent/**")
      end

      it "honors permission_replace as a string-keyed option" do
        content = provider.config_file_content(
          "permission_replace" => true,
          "permission" => {"bash" => "ask"}
        )
        parsed = JSON.parse(content)

        expect(parsed["permission"]).to eq({"bash" => "ask"})
      end

      it "preserves an explicitly empty permission hash when permission_replace is set" do
        content = provider.config_file_content(
          permission_replace: true,
          permission: {}
        )
        parsed = JSON.parse(content)

        expect(parsed["permission"]).to eq({})
      end

      it "does not inject default permissions when permission_replace is set without a permission block" do
        content = provider.config_file_content(
          provider_name: "openai",
          model_id: "gpt-4o",
          permission_replace: true
        )
        parsed = JSON.parse(content)

        expect(parsed).not_to have_key("permission")
        expect(parsed["provider"]).to eq({"openai" => {}})
        expect(parsed["model"]).to eq("openai/gpt-4o")
      end

      it "ignores a non-Hash caller permission and falls back to the default rule" do
        parsed = JSON.parse(provider.config_file_content(permission: "banana"))

        expect(parsed["permission"]).to eq({
          "external_directory" => {"/tmp/**" => "allow", "/home/agent/**" => "allow"}
        })
      end

      it "ignores an empty caller permission hash and falls back to the default rule" do
        parsed = JSON.parse(provider.config_file_content(permission: {}))

        expect(parsed["permission"]).to eq({
          "external_directory" => {"/tmp/**" => "allow", "/home/agent/**" => "allow"}
        })
      end

      it "does not mutate the shared DEFAULT_PERMISSION_CONFIG constant across invocations" do
        frozen_config = described_class::DEFAULT_PERMISSION_CONFIG
        expect(frozen_config).to be_frozen

        2.times { provider.config_file_content(provider_name: "openai", model_id: "gpt-4o") }

        expect(frozen_config["external_directory"]).to eq("/tmp/**" => "allow", "/home/agent/**" => "allow")
      end

      it "returns an independent permission copy on each invocation" do
        first = JSON.parse(provider.config_file_content)["permission"]
        first["external_directory"]["/tmp/**"] = "deny"

        second = JSON.parse(provider.config_file_content)["permission"]
        expect(second["external_directory"]["/tmp/**"]).to eq("allow")
      end

      it "does not mutate a caller-supplied permission block" do
        caller_permission = {"external_directory" => {"/var/tmp/**" => "allow"}}

        provider.config_file_content(permission: caller_permission)

        expect(caller_permission).to eq("external_directory" => {"/var/tmp/**" => "allow"})
      end
    end
  end

  describe "#notify_hook_content" do
    let(:executor) { instance_double(AgentHarness::CommandExecutor, which: "/usr/bin/kilo") }
    let(:provider) { described_class.new(executor: executor) }

    it "returns nil (not supported)" do
      expect(provider.notify_hook_content).to be_nil
    end
  end

  describe "#auth_lock_config" do
    let(:executor) { instance_double(AgentHarness::CommandExecutor, which: "/usr/bin/kilo") }
    let(:provider) { described_class.new(executor: executor) }

    it "returns nil (not supported)" do
      expect(provider.auth_lock_config).to be_nil
    end
  end

  describe "#test_command_overrides" do
    it "returns kilocode-specific test flags" do
      provider = described_class.new
      expect(provider.test_command_overrides).to eq(["--auto", "--print-logs"])
    end
  end

  describe "#supports_activity_heartbeat?" do
    let(:executor) { instance_double(AgentHarness::CommandExecutor) }
    let(:provider) { described_class.new(executor: executor) }

    it "returns true" do
      expect(provider.supports_activity_heartbeat?).to be true
    end
  end

  describe "#heartbeat_integration" do
    let(:executor) { instance_double(AgentHarness::CommandExecutor) }
    let(:provider) { described_class.new(executor: executor) }
    let(:heartbeat_path) { "/paid-heartbeat/.paid-heartbeat" }
    let(:hooks_config_path) { File.expand_path("~/.config/kilocode/hooks.json") }

    subject(:integration) { provider.heartbeat_integration(heartbeat_file_path: heartbeat_path) }

    before do
      # Keep the merge hermetic: a developer machine (or agent container) may
      # carry a real ~/.config/kilocode/hooks.json written by a heartbeat
      # integration, and merging it would change the expectations below.
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(hooks_config_path).and_return(false)
    end

    it "returns a supported integration" do
      expect(integration[:supported]).to be true
    end

    it "sets the KILO_HEARTBEAT_FILE env var" do
      expect(integration[:env]).to eq("KILO_HEARTBEAT_FILE" => heartbeat_path)
    end

    it "returns an ExecutionPreparation with hook config" do
      preparation = integration[:preparation]
      expect(preparation).to be_a(AgentHarness::ExecutionPreparation)
      expect(preparation.file_writes).not_to be_empty

      hook_write = preparation.file_writes.first
      expect(hook_write.path).to eq("~/.config/kilocode/hooks.json")
      expect(hook_write.mode).to eq(0o600)

      parsed = JSON.parse(hook_write.content)
      expect(parsed).to have_key("hooks")
      expect(parsed["hooks"]["on_activity"]).to be_an(Array)
      expect(parsed["hooks"]["on_activity"].first["command"]).to include(heartbeat_path)
    end

    it "reports tool_call granularity" do
      expect(integration[:granularity]).to eq(:tool_call)
    end

    it "raises ArgumentError for nil heartbeat_file_path" do
      expect {
        provider.heartbeat_integration(heartbeat_file_path: nil)
      }.to raise_error(ArgumentError, /heartbeat_file_path must be a non-empty String/)
    end

    it "raises ArgumentError for blank heartbeat_file_path" do
      expect {
        provider.heartbeat_integration(heartbeat_file_path: "  ")
      }.to raise_error(ArgumentError, /heartbeat_file_path must be a non-empty String/)
    end

    it "raises ArgumentError for relative heartbeat_file_path" do
      expect {
        provider.heartbeat_integration(heartbeat_file_path: "relative/path")
      }.to raise_error(ArgumentError, /heartbeat_file_path must be an absolute path/)
    end

    context "when existing hooks.json is present" do
      let(:existing_config) do
        {"hooks" => {"on_activity" => [{"command" => "echo existing"}], "on_error" => [{"command" => "echo error"}]}}
      end

      before do
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with(hooks_config_path).and_return(true)
        allow(File).to receive(:read).and_call_original
        allow(File).to receive(:read).with(hooks_config_path).and_return(JSON.generate(existing_config))
      end

      it "merges heartbeat hook with existing on_activity hooks" do
        hook_write = integration[:preparation].file_writes.first
        parsed = JSON.parse(hook_write.content)

        expect(parsed["hooks"]["on_activity"].length).to eq(2)
        expect(parsed["hooks"]["on_activity"].first["command"]).to eq("echo existing")
        expect(parsed["hooks"]["on_activity"].last["command"]).to include("touch")
      end

      it "preserves other hook types" do
        hook_write = integration[:preparation].file_writes.first
        parsed = JSON.parse(hook_write.content)

        expect(parsed["hooks"]["on_error"]).to eq([{"command" => "echo error"}])
      end
    end

    context "with shell-sensitive characters in heartbeat_file_path" do
      let(:heartbeat_path) { "/tmp/heartbeat file;touch /tmp/pwned" }

      it "shell-escapes the heartbeat command path" do
        hook_write = integration[:preparation].file_writes.first
        parsed = JSON.parse(hook_write.content)

        expect(parsed["hooks"]["on_activity"].first["command"]).to eq(
          "touch /tmp/heartbeat\\ file\\;touch\\ /tmp/pwned"
        )
      end
    end
  end
end
