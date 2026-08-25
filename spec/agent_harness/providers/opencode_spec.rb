# frozen_string_literal: true

RSpec.describe AgentHarness::Providers::Opencode do
  describe ".provider_name" do
    it "returns :opencode" do
      expect(described_class.provider_name).to eq(:opencode)
    end
  end

  describe ".binary_name" do
    it "returns opencode" do
      expect(described_class.binary_name).to eq("opencode")
    end
  end

  describe ".installation_contract" do
    it "exposes OpenCode CLI install metadata" do
      contract = described_class.installation_contract

      expect(contract).to include(
        source: :npm,
        package_name: "opencode-ai",
        version: "1.18.19",
        binary_name: "opencode"
      )
      expect(contract[:package]).to eq("opencode-ai@1.18.19")
      expect(contract[:supported_versions]).to eq(["1.18.19"])
      expect(contract[:version_requirement]).to eq([">= 1.18.19", "< 2.0.0"])
      expect(contract[:install_command]).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "opencode-ai@1.18.19"]
      )
    end

    it "declares requires_postinstall as true" do
      contract = described_class.installation_contract

      expect(contract[:requires_postinstall]).to be true
    end

    it "exposes a postinstall_command for the trusted native binary download" do
      contract = described_class.installation_contract

      expect(contract[:postinstall_command]).to include("raw_arch=$(uname -m)")
      expect(contract[:postinstall_command]).to include("target_arch=arm64")
      expect(contract[:postinstall_command]).to include("target_arch=x64")
      expect(contract[:postinstall_command]).to include("postinstall.mjs")
      expect(contract[:postinstall_command]).to include("\"$binary_path\" --version >/dev/null")
    end

    it "keeps the runtime binary aligned with the install contract" do
      contract = described_class.installation_contract

      expect(contract[:binary_name]).to eq(described_class.binary_name)
    end

    it "supports explicit versions within the advertised requirement" do
      contract = described_class.installation_contract(version: "1.18.20")

      expect(contract[:version]).to eq("1.18.20")
      expect(contract[:install_command]).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "opencode-ai@1.18.20"]
      )
    end

    it "preserves postinstall fields in versioned contracts" do
      contract = described_class.installation_contract(version: "1.18.20")

      expect(contract[:requires_postinstall]).to be true
      expect(contract[:postinstall_command]).to include("raw_arch=$(uname -m)")
      expect(contract[:postinstall_command]).to include("\"$binary_path\" --version >/dev/null")
    end

    it "reuses the default frozen install contract" do
      expect(described_class.installation_contract).to equal(described_class.installation_contract)
    end

    it "reuses the default frozen install contract for explicit default versions" do
      default_contract = described_class.installation_contract

      expect(described_class.installation_contract(version: "1.18.19")).to equal(default_contract)
      expect(described_class.installation_contract(version: " 1.18.19 ")).to equal(default_contract)
    end

    it "normalizes surrounding whitespace in supported explicit versions" do
      contract = described_class.installation_contract(version: " 1.18.20 ")

      expect(contract[:version]).to eq("1.18.20")
      expect(contract[:package]).to eq("opencode-ai@1.18.20")
      expect(contract[:install_command]).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "opencode-ai@1.18.20"]
      )
    end

    it "rejects versions outside the advertised requirement" do
      expect {
        described_class.installation_contract(version: "2.0.0")
      }.to raise_error(ArgumentError, /Unsupported OpenCode CLI version/)
    end

    it "rejects malformed versions with the provider-specific error" do
      expect {
        described_class.installation_contract(version: "not-a-version")
      }.to raise_error(ArgumentError, /Unsupported OpenCode CLI version "not-a-version"/)
    end

    it "rejects nil versions with the provider-specific error" do
      expect {
        described_class.installation_contract(version: nil)
      }.to raise_error(ArgumentError, /Unsupported OpenCode CLI version nil/)
    end

    it "rejects blank versions with the provider-specific error" do
      expect {
        described_class.installation_contract(version: "")
      }.to raise_error(ArgumentError, /Unsupported OpenCode CLI version ""/)
    end

    it "rejects whitespace-only versions with the provider-specific error" do
      expect {
        described_class.installation_contract(version: "   ")
      }.to raise_error(ArgumentError, /Unsupported OpenCode CLI version "   "/)
    end

    it "rejects non-string versions with the provider-specific error" do
      expect {
        described_class.installation_contract(version: 1.3)
      }.to raise_error(ArgumentError, /Unsupported OpenCode CLI version 1\.3/)
    end

    it "deep-freezes nested contract values" do
      contract = described_class.installation_contract

      expect(contract).to be_frozen
      expect(contract[:package]).to be_frozen
      expect(contract[:package_name]).to be_frozen
      expect(contract[:version]).to be_frozen
      expect(contract[:binary_name]).to be_frozen
      expect(contract[:postinstall_command]).to be_frozen
      expect { contract[:install_command_prefix] << "opencode-ai" }.to raise_error(FrozenError)
      expect { contract[:install_command] << "opencode-ai" }.to raise_error(FrozenError)
      expect { contract[:supported_versions] << "1.18.17" }.to raise_error(FrozenError)
      expect { contract[:version_requirement] << ">= 1.18.17" }.to raise_error(FrozenError)
    end
  end

  describe ".install_command" do
    it "builds the default install command from the contract" do
      expect(described_class.install_command).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "opencode-ai@1.18.19"]
      )
    end

    it "supports explicit version overrides" do
      expect(described_class.install_command(version: "1.18.20")).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "opencode-ai@1.18.20"]
      )
    end

    it "reuses the default frozen install command for explicit default versions" do
      default_install_command = described_class.install_command

      expect(described_class.install_command(version: "1.18.19")).to equal(default_install_command)
      expect(described_class.install_command(version: " 1.18.19 ")).to equal(default_install_command)
    end

    it "normalizes surrounding whitespace in explicit version overrides" do
      expect(described_class.install_command(version: " 1.18.20 ")).to eq(
        ["npm", "install", "-g", "--ignore-scripts", "opencode-ai@1.18.20"]
      )
    end

    it "rejects unsupported version overrides" do
      expect {
        described_class.install_command(version: "1.18.17")
      }.to raise_error(ArgumentError, /Unsupported OpenCode CLI version/)
    end

    it "rejects malformed version overrides with the provider-specific error" do
      expect {
        described_class.install_command(version: "not-a-version")
      }.to raise_error(ArgumentError, /Unsupported OpenCode CLI version "not-a-version"/)
    end

    it "rejects nil version overrides with the provider-specific error" do
      expect {
        described_class.install_command(version: nil)
      }.to raise_error(ArgumentError, /Unsupported OpenCode CLI version nil/)
    end

    it "rejects blank version overrides with the provider-specific error" do
      expect {
        described_class.install_command(version: "")
      }.to raise_error(ArgumentError, /Unsupported OpenCode CLI version ""/)
    end

    it "rejects whitespace-only version overrides with the provider-specific error" do
      expect {
        described_class.install_command(version: "   ")
      }.to raise_error(ArgumentError, /Unsupported OpenCode CLI version "   "/)
    end

    it "rejects non-string version overrides with the provider-specific error" do
      expect {
        described_class.install_command(version: 1.3)
      }.to raise_error(ArgumentError, /Unsupported OpenCode CLI version 1\.3/)
    end
  end

  describe ".firewall_requirements" do
    it "returns required domains" do
      requirements = described_class.firewall_requirements
      expect(requirements[:domains]).to include("api.openai.com")
    end
  end

  describe ".instruction_file_paths" do
    it "returns empty array" do
      expect(described_class.instruction_file_paths).to eq([])
    end
  end

  describe ".discover_models" do
    it "returns empty when not available" do
      allow(described_class).to receive(:available?).and_return(false)
      expect(described_class.discover_models).to eq([])
    end
  end

  describe "instance" do
    let(:mock_executor) do
      instance_double(AgentHarness::CommandExecutor)
    end

    subject(:provider) { described_class.new(executor: mock_executor) }

    describe "#name" do
      it "returns opencode" do
        expect(provider.name).to eq("opencode")
      end
    end

    describe "#display_name" do
      it "returns OpenCode CLI" do
        expect(provider.display_name).to eq("OpenCode CLI")
      end
    end

    describe "#configuration_schema" do
      it "has no configurable fields" do
        schema = provider.configuration_schema
        expect(schema[:fields]).to eq([])
      end

      it "reports openai_compatible as true" do
        expect(provider.configuration_schema[:openai_compatible]).to be true
      end

      it "uses api_key auth mode" do
        expect(provider.configuration_schema[:auth_modes]).to eq([:api_key])
      end
    end

    describe "#capabilities" do
      it "returns minimal capabilities" do
        caps = provider.capabilities
        expect(caps[:streaming]).to be false
        expect(caps[:mcp]).to be false
      end
    end

    describe "#send_message" do
      it "executes opencode run with the prompt" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        expect(mock_executor).to receive(:execute).with(
          ["opencode", "run", "Hello"],
          anything
        )

        provider.send_message(prompt: "Hello")
      end

      it "uses the install contract binary in the runtime command" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        binary = "opencode-custom"
        contract = described_class.installation_contract.merge(binary_name: binary).freeze
        allow(described_class).to receive(:installation_contract).and_return(contract)

        expect(mock_executor).to receive(:execute).with(
          [binary, "run", "Hello"],
          anything
        )

        provider.send_message(prompt: "Hello")
      end

      it "builds runtime config bootstrap from normalized runtime fields and metadata extras" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        expect(mock_executor).to receive(:execute).with(
          ["opencode", "run", "Hello"],
          hash_including(
            preparation: have_attributes(
              file_writes: [
                have_attributes(
                  path: "~/.config/opencode/opencode.json",
                  content: include(
                    "\"model\": \"gpt-5.4\"",
                    "\"provider\": \"openrouter\"",
                    "\"baseURL\": \"https://openrouter.ai/api/v1\"",
                    "\"permission\": {",
                    "\"external_directory\": {",
                    "\"/tmp/**\": \"allow\"",
                    "\"/home/agent/**\": \"allow\"",
                    "\"theme\": \"system\""
                  ),
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
            api_provider: "openrouter",
            base_url: "https://openrouter.ai/api/v1",
            metadata: {
              config: {
                theme: "system"
              }
            }
          }
        )
      end

      it "preserves caller-supplied permission config" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        expect(mock_executor).to receive(:execute).with(
          ["opencode", "run", "Hello"],
          hash_including(
            preparation: have_attributes(
              file_writes: [
                have_attributes(
                  path: "~/.config/opencode/opencode.json",
                  content: satisfy do |content|
                    content.include?("\"permission\": {") &&
                      content.include?("\"external_directory\": {") &&
                      content.include?("\"/var/tmp/**\": \"allow\"") &&
                      !content.include?("\"/tmp/**\": \"allow\"")
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
                    "/var/tmp/**" => "allow"
                  }
                }
              }
            }
          }
        )
      end

      it "keeps the bootstrap destination fixed even when metadata includes a config path" do
        allow(mock_executor).to receive(:execute).and_return(
          AgentHarness::CommandExecutor::Result.new(
            stdout: "response",
            stderr: "",
            exit_code: 0,
            duration: 1.0
          )
        )

        expect(mock_executor).to receive(:execute).with(
          ["opencode", "run", "Hello"],
          hash_including(
            preparation: have_attributes(
              file_writes: [
                have_attributes(path: "~/.config/opencode/opencode.json")
              ]
            )
          )
        )

        provider.send_message(
          prompt: "Hello",
          provider_runtime: {
            metadata: {
              config_path: "~/.ssh/authorized_keys",
              config: {theme: "system"}
            }
          }
        )
      end

      context "with the default external_directory permission rule" do
        it "default-merges a permissive /tmp and home-directory external_directory permission into the config" do
          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: "response",
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          expect(mock_executor).to receive(:execute).with(
            ["opencode", "run", "Hello"],
            hash_including(
              preparation: have_attributes(
                file_writes: [
                  have_attributes(
                    path: "~/.config/opencode/opencode.json",
                    content: include(
                      "\"permission\":",
                      "\"external_directory\":",
                      "\"/tmp/**\": \"allow\"",
                      "\"/home/agent/**\": \"allow\""
                    )
                  )
                ]
              )
            )
          )

          provider.send_message(
            prompt: "Hello",
            provider_runtime: {
              model: "gpt-5.4"
            }
          )
        end

        it "writes a config file even when no other config extras are supplied" do
          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: "response",
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          expect(mock_executor).to receive(:execute).with(
            ["opencode", "run", "Hello"],
            hash_including(
              preparation: have_attributes(
                file_writes: [
                  have_attributes(
                    path: "~/.config/opencode/opencode.json",
                    content: include("\"external_directory\":")
                  )
                ]
              )
            )
          )

          provider.send_message(
            prompt: "Hello",
            provider_runtime: {
              model: "gpt-5.4"
            }
          )
        end

        it "does not mutate the shared DEFAULT_PERMISSION_RULE constant across invocations" do
          frozen_rule = described_class::DEFAULT_PERMISSION_RULE
          expect(frozen_rule).to be_frozen

          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: "response",
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          2.times do
            provider.send_message(prompt: "Hello", provider_runtime: {model: "gpt-5.4"})
          end

          expect(frozen_rule["external_directory"]).to eq("/tmp/**" => "allow", "/home/agent/**" => "allow")
        end

        it "leaves a caller-supplied permission block untouched" do
          allow(mock_executor).to receive(:execute).and_return(
            AgentHarness::CommandExecutor::Result.new(
              stdout: "response",
              stderr: "",
              exit_code: 0,
              duration: 1.0
            )
          )

          expect(mock_executor).to receive(:execute).with(
            ["opencode", "run", "Hello"],
            hash_including(
              preparation: have_attributes(
                file_writes: [
                  have_attributes(
                    path: "~/.config/opencode/opencode.json",
                    content: satisfy do |content|
                      content.include?("\"bash\": \"ask\"") &&
                        content.include?("\"edit\": \"deny\"") &&
                        !content.include?("/tmp/**")
                    end
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

    describe "#supports_activity_heartbeat?" do
      it "returns true" do
        expect(provider.supports_activity_heartbeat?).to be true
      end
    end

    describe "#heartbeat_integration" do
      let(:heartbeat_path) { "/paid-heartbeat/.paid-heartbeat" }
      let(:hooks_config_path) { File.expand_path("~/.config/opencode/hooks.json") }

      subject(:integration) { provider.heartbeat_integration(heartbeat_file_path: heartbeat_path) }

      before do
        # Keep the merge hermetic: a developer machine (or agent container) may
        # carry a real ~/.config/opencode/hooks.json written by a heartbeat
        # integration, and merging it would change the expectations below.
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with(hooks_config_path).and_return(false)
      end

      it "returns a supported integration" do
        expect(integration[:supported]).to be true
      end

      it "sets the OPENCODE_HEARTBEAT_FILE env var" do
        expect(integration[:env]).to eq("OPENCODE_HEARTBEAT_FILE" => heartbeat_path)
      end

      it "returns an ExecutionPreparation with hook config" do
        preparation = integration[:preparation]
        expect(preparation).to be_a(AgentHarness::ExecutionPreparation)
        expect(preparation.file_writes).not_to be_empty

        hook_write = preparation.file_writes.first
        expect(hook_write.path).to eq("~/.config/opencode/hooks.json")
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
end
