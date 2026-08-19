## [Unreleased]

### Features

* add runner model compatibility contract (`AgentHarness.model_compatibility`) with structured `ModelCompatibility::Result` outcomes. Codex exposes static facts for CLI-gated models (e.g. `gpt-5.5` requires Codex CLI `>= 0.116.0`), a baseline supported-model list, supported auth modes, and a `DEFAULT_COMPATIBLE_MODEL_ID` fallback so downstream orchestrators can validate tier/model assignments before scheduling agent runs ([#259](https://github.com/viamin/agent-harness/issues/259)).
* **auth:** add provider-owned PKCE code-exchange API for Claude OAuth (`AgentHarness::Authentication.exchange_code`). Takes an authorization code plus PKCE verifier (and `redirect_uri`/`client_id`), posts an `authorization_code` grant to the Claude token endpoint, and persists the resulting access/refresh tokens in the native `claudeAiOauth` shape. Adds `exchange_code_supported?` and a `code_exchange` key to `auth_capabilities` ([#266](https://github.com/viamin/agent-harness/issues/266)).

## [0.36.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.35.5...agent-harness/v0.36.0) (2026-08-19)


### Features

* Scheduled job to fill the Dependabot gaps: Cursor artifact pin refresh + Claude oracle parity check (step 3) ([#353](https://github.com/viamin/agent-harness/issues/353)) ([79a91d3](https://github.com/viamin/agent-harness/commit/79a91d323f70459be04f619c18bd83f370a9ecf3))

## [0.35.5](https://github.com/viamin/agent-harness/compare/agent-harness/v0.35.4...agent-harness/v0.35.5) (2026-08-19)


### Bug Fixes

* **deps-dev:** bump @anthropic-ai/claude-code from 2.1.92 to 2.1.233 in /vendor/pins/claude ([#342](https://github.com/viamin/agent-harness/issues/342)) ([ce0129a](https://github.com/viamin/agent-harness/commit/ce0129a5b4c1f61b853f7203fdd56665e232a5cf))

## [0.35.4](https://github.com/viamin/agent-harness/compare/agent-harness/v0.35.3...agent-harness/v0.35.4) (2026-08-19)


### Bug Fixes

* **deps-dev:** bump @mariozechner/pi-coding-agent from 0.73.0 to 0.73.1 in /vendor/pins/pi ([#343](https://github.com/viamin/agent-harness/issues/343)) ([8a92d1e](https://github.com/viamin/agent-harness/commit/8a92d1e5a30eafc1b3c0b1790243923b40e6ae4e))

## [0.35.3](https://github.com/viamin/agent-harness/compare/agent-harness/v0.35.2...agent-harness/v0.35.3) (2026-08-19)


### Bug Fixes

* **deps-dev:** bump @oh-my-pi/pi-coding-agent from 17.0.1 to 17.3.5 in /vendor/pins/omp ([#346](https://github.com/viamin/agent-harness/issues/346)) ([a8c22c9](https://github.com/viamin/agent-harness/commit/a8c22c9635e6c84a8406a4115de3bd23c9596591))

## [0.35.2](https://github.com/viamin/agent-harness/compare/agent-harness/v0.35.1...agent-harness/v0.35.2) (2026-08-19)


### Bug Fixes

* **deps-dev:** bump @kilocode/cli from 7.4.16 to 7.4.22 in /vendor/pins/kilocode ([#345](https://github.com/viamin/agent-harness/issues/345)) ([8c2570e](https://github.com/viamin/agent-harness/commit/8c2570e486fc0440016014920a256fd663afde3a))

## [0.35.1](https://github.com/viamin/agent-harness/compare/agent-harness/v0.35.0...agent-harness/v0.35.1) (2026-08-19)


### Bug Fixes

* **deps-dev:** bump opencode-ai from 1.18.9 to 1.18.18 in /vendor/pins/opencode ([#344](https://github.com/viamin/agent-harness/issues/344)) ([e8081ef](https://github.com/viamin/agent-harness/commit/e8081ef377b6ef3d801371104506f41e509607a4))

## [0.35.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.34.1...agent-harness/v0.35.0) (2026-08-19)


### Features

* Add Dependabot-visible pin manifests for provider CLI versions (step 1 of automated version bumps) ([#339](https://github.com/viamin/agent-harness/issues/339)) ([826f41a](https://github.com/viamin/agent-harness/commit/826f41a2e3e3cc64c417bb172709ea1e833ae8c8))

## [0.34.1](https://github.com/viamin/agent-harness/compare/agent-harness/v0.34.0...agent-harness/v0.34.1) (2026-08-16)


### Dependencies

* **deps-dev:** bump simplecov in the minor-updates group ([#334](https://github.com/viamin/agent-harness/issues/334)) ([955addf](https://github.com/viamin/agent-harness/commit/955addf8603f860bab923eca310c034061e3c284))

## [0.34.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.33.1...agent-harness/v0.34.0) (2026-08-14)


### Features

* reject gpt-5.6 codex subscription models ([#331](https://github.com/viamin/agent-harness/issues/331)) ([4c1e6f9](https://github.com/viamin/agent-harness/commit/4c1e6f94cfb919bf166a7b4842669b817b863b97))

## [0.33.1](https://github.com/viamin/agent-harness/compare/agent-harness/v0.33.0...agent-harness/v0.33.1) (2026-08-14)


### Bug Fixes

* reject gpt-5.6 codex subscription models ([#330](https://github.com/viamin/agent-harness/issues/330)) ([736e88d](https://github.com/viamin/agent-harness/commit/736e88d27e57c7d28c883968353967ad62f64122))

## [0.33.0](https://github.com/viamin/agent-harness/compare/agent-harness-v0.32.0...agent-harness/v0.33.0) (2026-08-04)


### Features

* add conversation manager for multi-turn chat ([#159](https://github.com/viamin/agent-harness/issues/159)) ([14f1d55](https://github.com/viamin/agent-harness/commit/14f1d551008c2d52a0aee7c2a7e2e0273f254578))
* add MCP HTTP transport support for servers ([#153](https://github.com/viamin/agent-harness/issues/153)) ([#155](https://github.com/viamin/agent-harness/issues/155)) ([8ea631a](https://github.com/viamin/agent-harness/commit/8ea631a3274ca4331ce42e8d63fc972cd48fbb12))
* Add Oh My Pi provider metadata and install contract ([#298](https://github.com/viamin/agent-harness/issues/298)) ([3be62a8](https://github.com/viamin/agent-harness/commit/3be62a884f50ceeb903e199f4a9906cf3fecf014))
* add OpenAI-compatible chat transport ([#154](https://github.com/viamin/agent-harness/issues/154)) ([6005702](https://github.com/viamin/agent-harness/commit/60057029ba6eaaf81f65d42e487e6f0ca8cd159f))
* Add plan-only / dry-run API returning command+env without execution ([#192](https://github.com/viamin/agent-harness/issues/192)) ([0e6a105](https://github.com/viamin/agent-harness/commit/0e6a1053515e0495900b67c5845a2f95c571f055))
* add provider chat capability with GitHub Models and Anthropic support ([#158](https://github.com/viamin/agent-harness/issues/158)) ([4188fa5](https://github.com/viamin/agent-harness/commit/4188fa542e6c4d330e5b230e54b1c1a5a55f4e8a))
* add provider quota/usage checking interface for proactive weight balancing ([#309](https://github.com/viamin/agent-harness/issues/309)) ([b082222](https://github.com/viamin/agent-harness/commit/b082222087f202442b20750cad5fb0127342c9ef))
* Add runner model compatibility contracts for Codex and CLI-gated models ([#260](https://github.com/viamin/agent-harness/issues/260)) ([4c192a7](https://github.com/viamin/agent-harness/commit/4c192a72f323ecaaea96e87e8ead6634e33669c0))
* add structured streaming response observer for chat ([#157](https://github.com/viamin/agent-harness/issues/157)) ([225f4d9](https://github.com/viamin/agent-harness/commit/225f4d99b2b89d8eb030018236050672d3e47ba2))
* allow OpenCode tmp scratch access ([#278](https://github.com/viamin/agent-harness/issues/278)) ([886437f](https://github.com/viamin/agent-harness/commit/886437f6d8429a487d043eb2242cb3f60ab604f6))
* Anthropic#build_command ignores provider_runtime.model for CLI execution plans ([025ff6e](https://github.com/viamin/agent-harness/commit/025ff6e0a0a1ae8bea3a607873460af7d9838d54))
* Anthropic#build_command ignores provider_runtime.model for CLI execution plans ([52cd76e](https://github.com/viamin/agent-harness/commit/52cd76e6cfd1ea9816153be7a0bed2e7e2668945))
* **auth:** add PKCE code-exchange API for Claude OAuth ([#272](https://github.com/viamin/agent-harness/issues/272)) ([22f873b](https://github.com/viamin/agent-harness/commit/22f873bb5fe58c67ab94c2a7b0c57b3bcbfe38b9)), closes [#266](https://github.com/viamin/agent-harness/issues/266)
* **auth:** add refresh-token exchange API for Claude OAuth ([#269](https://github.com/viamin/agent-harness/issues/269)) ([076b1aa](https://github.com/viamin/agent-harness/commit/076b1aa91a3dcb58280d1c550bdc4329ce162a92)), closes [#265](https://github.com/viamin/agent-harness/issues/265)
* Authentication: Claude OAuth PKCE code-exchange API ([#267](https://github.com/viamin/agent-harness/issues/267)) ([7cabc73](https://github.com/viamin/agent-harness/commit/7cabc73f2a660e292533175e9db3a94d18326031))
* **auth:** parse native Claude claudeAiOauth credentials shape ([#268](https://github.com/viamin/agent-harness/issues/268)) ([178edae](https://github.com/viamin/agent-harness/commit/178edae21e175c4744b75a151acfc6df3b4b3c5d)), closes [#264](https://github.com/viamin/agent-harness/issues/264)
* automated dependency updates for installable agents with cooldown period ([#239](https://github.com/viamin/agent-harness/issues/239)) ([0682cc0](https://github.com/viamin/agent-harness/commit/0682cc0d40264f5b5431fc0a7ab0c0d76416ec64))
* bump opencode install contract ([#317](https://github.com/viamin/agent-harness/issues/317)) ([fcde8b3](https://github.com/viamin/agent-harness/commit/fcde8b321efcec4aa7f1e76f2a710f38540babaa))
* Codex install contract pins CLI too old for gpt-5.5 ([#247](https://github.com/viamin/agent-harness/issues/247)) ([abc0a1a](https://github.com/viamin/agent-harness/commit/abc0a1afa1f9bff9f075621e25e3d2ed934301a7))
* **codex:** expose JSONL transcript parser ([#148](https://github.com/viamin/agent-harness/issues/148)) ([05312ea](https://github.com/viamin/agent-harness/commit/05312eaf9c11fff50931e511ee6e534838eb8746))
* **copilot:** add GitHub Copilot CLI (`copilot`) support with --autopilot mode ([#210](https://github.com/viamin/agent-harness/issues/210)) ([0138f3c](https://github.com/viamin/agent-harness/commit/0138f3c9f91e5e871383b771c287495217f084d8))
* **copilot:** add JSON output parsing and token extraction ([4f5fc5a](https://github.com/viamin/agent-harness/commit/4f5fc5acd8d45ac8563998a132a0c4878f3b9e0a))
* Expose public parse_container_output method on provider interface ([#187](https://github.com/viamin/agent-harness/issues/187)) ([ecdb7ba](https://github.com/viamin/agent-harness/commit/ecdb7bac56e47cf75e1379508cca64a9c7a0ffff))
* expose public provider registry and config factory methods ([#193](https://github.com/viamin/agent-harness/issues/193)) ([11158ef](https://github.com/viamin/agent-harness/commit/11158efde6d77c885e7be1a03465d915efa0ee40)), closes [#175](https://github.com/viamin/agent-harness/issues/175)
* **extensions:** add activity heartbeat support for OpenCode/KiloCode-compatible providers ([#201](https://github.com/viamin/agent-harness/issues/201)) ([4914f6d](https://github.com/viamin/agent-harness/commit/4914f6d7971c55600f268b6886b967b753b25c96))
* Implement Oh My Pi execution, auth, and smoke-test contract ([#300](https://github.com/viamin/agent-harness/issues/300)) ([dc3f5ec](https://github.com/viamin/agent-harness/commit/dc3f5ecce4508f103a8b769727e31aaa3d694c7e))
* **installers:** make Github Copilot CLI installation/version support a first-class provider contract ([#135](https://github.com/viamin/agent-harness/issues/135)) ([5120d44](https://github.com/viamin/agent-harness/commit/5120d44cf8405d0f7ef5fbb036f6d44ffdb701f6))
* **kilocode:** extract token usage from Kilo CLI structured JSON output ([b5384f8](https://github.com/viamin/agent-harness/commit/b5384f8be52431f95d8aa3524a33ceed6bf094eb)), closes [#97](https://github.com/viamin/agent-harness/issues/97)
* opencode-ai install contract should support postinstall (native binary download) ([b3eed97](https://github.com/viamin/agent-harness/commit/b3eed971b9bc46ce2bb2976b70dfd65b15ae5e9b))
* **opencode:** add requires_postinstall and postinstall_command to install contract ([d6808fd](https://github.com/viamin/agent-harness/commit/d6808fd62476289b199202b0c20c65fc4966bfcc)), closes [#223](https://github.com/viamin/agent-harness/issues/223)
* pre-flight connectivity check API for provider health verification ([#185](https://github.com/viamin/agent-harness/issues/185)) ([3ad6a2f](https://github.com/viamin/agent-harness/commit/3ad6a2ffbfe84b2271e4de968fa096276724e63c))
* **providers:** add config_file_content, notify_hook_content, and auth_lock_config ([#131](https://github.com/viamin/agent-harness/issues/131)) ([e95117e](https://github.com/viamin/agent-harness/commit/e95117e8000002972ca0fb31cb90dec035aa88fd))
* **providers:** add env var name mappings to provider classes ([#122](https://github.com/viamin/agent-harness/issues/122)) ([#133](https://github.com/viamin/agent-harness/issues/133)) ([6be9015](https://github.com/viamin/agent-harness/commit/6be901592afb02337eb2a5269f08e3025c7511c1))
* **providers:** add error_classification_patterns, noisy_error_patterns, and translate_error to provider classes ([#128](https://github.com/viamin/agent-harness/issues/128)) ([e2dfbed](https://github.com/viamin/agent-harness/commit/e2dfbed064fa26b2cae5691e6586e79900d19d28))
* **providers:** add parse_rate_limit_reset to provider base class ([#134](https://github.com/viamin/agent-harness/issues/134)) ([c16a6f8](https://github.com/viamin/agent-harness/commit/c16a6f8de312e137e5c3431f32d42b8c65126e0e))
* **providers:** add test_command_overrides and parse_test_error methods ([#129](https://github.com/viamin/agent-harness/issues/129)) ([a18102d](https://github.com/viamin/agent-harness/commit/a18102d1ee333a1db37f711c65e16dc20d4a0a11)), closes [#125](https://github.com/viamin/agent-harness/issues/125)
* **providers:** add token_usage_from_api_response to provider classes ([#130](https://github.com/viamin/agent-harness/issues/130)) ([f2c095d](https://github.com/viamin/agent-harness/commit/f2c095dcc0ae0d7822da90f98704597f08e4ed04)), closes [#126](https://github.com/viamin/agent-harness/issues/126)
* release agent-harness 0.31.0 with omp support ([#302](https://github.com/viamin/agent-harness/issues/302)) ([7a82fbc](https://github.com/viamin/agent-harness/commit/7a82fbc5cc627eaa10c678e3e2b998fc0ce100f2))
* streaming JSONL event parser for real-time Codex progress tracking ([#184](https://github.com/viamin/agent-harness/issues/184)) ([4905539](https://github.com/viamin/agent-harness/commit/490553992904f39e52028b2140ab99755aad1fb1))
* structured stderr output parsing for provider error classification ([#186](https://github.com/viamin/agent-harness/issues/186)) ([1f47113](https://github.com/viamin/agent-harness/commit/1f47113c155ef4d4b11e5e4e921efa7dd23007b0))
* suppress Claude CLI .mcp.json auto-discovery when no MCP servers configured ([e07a25e](https://github.com/viamin/agent-harness/commit/e07a25e463becfd77da97058cb0a760eaec0920b))
* suppress Claude CLI .mcp.json auto-discovery when no MCP servers configured ([1d47980](https://github.com/viamin/agent-harness/commit/1d47980854b36916bf154008274f141ed55b92cf))


### Bug Fixes

* --disallowedTools varargs consumes prompt argument on Claude CLI v2.1.92+ ([e64bd62](https://github.com/viamin/agent-harness/commit/e64bd626ebdd19944920cbe43bcf8135069d0aec))
* 113: [P1] feat: support disabling tools for text-only send_message calls ([#115](https://github.com/viamin/agent-harness/issues/115)) ([62bc66a](https://github.com/viamin/agent-harness/commit/62bc66a3d34a889de65ba7c4951b8bdb1f388fa9))
* 114: feat: add text-only transport that bypasses the CLI ([a6be68a](https://github.com/viamin/agent-harness/commit/a6be68aa03b0202492caeb24233104cd1b814d88))
* 119: Claude provider leaks raw --output-format json envelope as response.output ([#120](https://github.com/viamin/agent-harness/issues/120)) ([602a5f9](https://github.com/viamin/agent-harness/commit/602a5f97e009ac59c798c7b1d7342cd43e2e8d4f))
* 160: Add support for the pi agent CLI ([#203](https://github.com/viamin/agent-harness/issues/203)) ([0aeb607](https://github.com/viamin/agent-harness/commit/0aeb607ea98b52ba8202726dc946b8c1db09a3cd))
* 161: Support provider-agnostic skills system ([#204](https://github.com/viamin/agent-harness/issues/204)) ([20a6ed5](https://github.com/viamin/agent-harness/commit/20a6ed5a8e6701ad7730d88b8037145d86b39c37))
* 162: Support provider-agnostic MCP configuration ([#165](https://github.com/viamin/agent-harness/issues/165)) ([27f4814](https://github.com/viamin/agent-harness/commit/27f48146e99d8fdba0346235a3e5f19138266652))
* 163: Support provider-agnostic sub-agent definitions ([#166](https://github.com/viamin/agent-harness/issues/166)) ([1a00c35](https://github.com/viamin/agent-harness/commit/1a00c35f61c624b23f8d37b0d1b41e007d007ad3))
* 164: Support provider-agnostic extensions across compatible providers ([#168](https://github.com/viamin/agent-harness/issues/168)) ([2880ae4](https://github.com/viamin/agent-harness/commit/2880ae4f150d1d5574f259b931bbee14ebe0ed04))
* 173: Smoke test contract timeout (30s) overrides caller timeout, breaking slow models ([#205](https://github.com/viamin/agent-harness/issues/205)) ([3a1e301](https://github.com/viamin/agent-harness/commit/3a1e301e36ef8957fd440f2782b3b8e4687b473c))
* 98: feat: add token usage extraction for remaining providers (cursor, gemini, aider, opencode, copilot, mistral_vibe) ([#105](https://github.com/viamin/agent-harness/issues/105)) ([b090748](https://github.com/viamin/agent-harness/commit/b090748b5d528ab864e94754c0992bc060669540))
* address review feedback on rate-limit reset parsing ([3f3ef60](https://github.com/viamin/agent-harness/commit/3f3ef60aa83ebf66eeba7cdb1934283a0f78fe43))
* **anthropic:** --mcp-config space-form swallows the positional prompt (variadic flag) ([e52d38f](https://github.com/viamin/agent-harness/commit/e52d38fe97cdcc093860f4fda1de9e10c08f54c7))
* **anthropic:** use equals form for mcp config ([481d734](https://github.com/viamin/agent-harness/commit/481d734e389e66056bfc82d4dfeb31ba76ba1128))
* **anthropic:** use provider_runtime.model in build_command when config.model is nil ([0c001e7](https://github.com/viamin/agent-harness/commit/0c001e707e1497005db47bb29c7689cdc2151fd6)), closes [#233](https://github.com/viamin/agent-harness/issues/233)
* apply test_command_overrides in Codex build_command for smoke tests ([#243](https://github.com/viamin/agent-harness/issues/243)) ([7810fad](https://github.com/viamin/agent-harness/commit/7810fadd2e81db442294999fce3f504f16239dab))
* bump kilocode cli to 7.4.16 ([#318](https://github.com/viamin/agent-harness/issues/318)) ([35b68d0](https://github.com/viamin/agent-harness/commit/35b68d02c511becc4163f884adc3b177b255a02f))
* Codex model_compatibility returns 'unknown' for models definitively unsupported with subscription auth (e.g. gpt-5.5-pro) ([#287](https://github.com/viamin/agent-harness/issues/287)) ([a6f87ce](https://github.com/viamin/agent-harness/commit/a6f87ce07a2514e069559d57d8496dd323bd0891))
* **codex:** accept assistant_message item completions ([ba41f17](https://github.com/viamin/agent-harness/commit/ba41f171e9a31153d7761d1658502a8b3a125562))
* **codex:** accept response_item assistant_message payloads ([4eedf06](https://github.com/viamin/agent-harness/commit/4eedf06dd8162525be714aea5502d3a7aabb6903))
* **codex:** accept typed response_item assistant payloads ([19b5e46](https://github.com/viamin/agent-harness/commit/19b5e464c3f3df204066f2bfcf64ed3df6caaf9b))
* **codex:** address remaining json output review feedback ([505e068](https://github.com/viamin/agent-harness/commit/505e068d63fbc5590112ba00faee0d1c62d997e3))
* **codex:** address review feedback for token usage extraction ([398940e](https://github.com/viamin/agent-harness/commit/398940ecb356ec9e6978d42244ae26295823bb89))
* **codex:** avoid double-counting json token usage ([4996cb6](https://github.com/viamin/agent-harness/commit/4996cb6b68a97052b6d279e78b2716e0b7cced5a))
* **codex:** avoid splitting wrapped agent updates ([aeaa7a2](https://github.com/viamin/agent-harness/commit/aeaa7a2ea69316c9f0aa893920fa8bbed99d44e0))
* **codex:** clear stale output on failed turns ([2c0efda](https://github.com/viamin/agent-harness/commit/2c0efda0b841fe2a08e4ca6e5fdfc835aba509ee))
* **codex:** commit consecutive completed turn usage ([055182d](https://github.com/viamin/agent-harness/commit/055182d124e943f1258deffab1e756a47ee4efe3))
* **codex:** dedupe failed top-level agent messages ([4a7956e](https://github.com/viamin/agent-harness/commit/4a7956ed43a3fcd36804b7a9b3a56857159dca68))
* **codex:** dedupe failed-turn wrapped usage ([f27d7d2](https://github.com/viamin/agent-harness/commit/f27d7d2e0dfad85242380c788908c8825857957e))
* **codex:** dedupe full-auto sandbox flags ([566c536](https://github.com/viamin/agent-harness/commit/566c53699fcbd3920dcae03236b0bcfe9dcbb0f0))
* **codex:** dedupe mixed turn token totals ([56a2f63](https://github.com/viamin/agent-harness/commit/56a2f635f1b49bb8d336b12fb9e12c43212d1287))
* **codex:** dedupe sandbox flags across runtime sources ([998f1bb](https://github.com/viamin/agent-harness/commit/998f1bb455b52b2b9efd5fc7c4022c62710063de))
* **codex:** dedupe wrapped usage on failed turns ([a92cba2](https://github.com/viamin/agent-harness/commit/a92cba294ef697ff7d5d6dc730d71e460d93fb8a))
* **codex:** defer wrapped usage across finalized events ([35d134b](https://github.com/viamin/agent-harness/commit/35d134b600cbb680b15678047df200328cdb6d4c))
* **codex:** delay wrapped turn finalization ([0dcc965](https://github.com/viamin/agent-harness/commit/0dcc965516770070db5dc8127d7d6f0c5063e2a1))
* **codex:** distinguish wrapped turn replacements ([7f10df9](https://github.com/viamin/agent-harness/commit/7f10df9a3bb0dd8f70e2acd2653a9e12f669c02b))
* **codex:** fallback completed json content blocks ([23146ec](https://github.com/viamin/agent-harness/commit/23146ec6588f9f83e6218c13d7d48b3004dfa56f))
* **codex:** fallback to wrapped token snapshots ([672caaf](https://github.com/viamin/agent-harness/commit/672caaf7c942043f64fc1f1e59eef084f0bd7593))
* **codex:** filter malformed assistant json events ([373ba7b](https://github.com/viamin/agent-harness/commit/373ba7bb96dd26cf09fb9e0fb2471f68eb685863))
* **codex:** filter malformed wrapped completion payloads ([64b684d](https://github.com/viamin/agent-harness/commit/64b684d25b742a872cbbf1e0dc53b58ed165628b))
* **codex:** filter non-output content blocks ([740f71c](https://github.com/viamin/agent-harness/commit/740f71c1dcfa6edd9b23792860516ec943f442a1))
* **codex:** filter roleless non-assistant item completions ([092544c](https://github.com/viamin/agent-harness/commit/092544caa4fde77118e38a8a0550fd9cad63b7d0))
* **codex:** filter roleless non-assistant json events ([f6e2683](https://github.com/viamin/agent-harness/commit/f6e2683699f60ed049b447ef31e4d9f084b761ad))
* **codex:** finalize empty json turns correctly ([3c08e56](https://github.com/viamin/agent-harness/commit/3c08e56a34277679d366f6fc65e9fa13ad07c715))
* **codex:** handle attached short sandbox flag values ([fe6a3f2](https://github.com/viamin/agent-harness/commit/fe6a3f2662e4cc8e031ac4a0b61625770ba1c071))
* **codex:** handle wrapped completion events ([980eca8](https://github.com/viamin/agent-harness/commit/980eca86c29731b064f172b294bb1266491d0c3a))
* **codex:** honor explicit turn token totals ([7faf5b7](https://github.com/viamin/agent-harness/commit/7faf5b7588c6808751d049ace252aad8372ca830))
* **codex:** ignore empty json delta output ([3fcae27](https://github.com/viamin/agent-harness/commit/3fcae27faa2c1d964933b8d08d1e7cdd6fea6aa9))
* **codex:** ignore malformed json token counts ([d477b18](https://github.com/viamin/agent-harness/commit/d477b186e06fa5e32bf12a9fb4c12033fae6c51e))
* **codex:** ignore negative json token counts ([510f9e8](https://github.com/viamin/agent-harness/commit/510f9e8e9ba321614ecfd6533d745018d4079d9d))
* **codex:** ignore non-message assistant item completions ([b1892d5](https://github.com/viamin/agent-harness/commit/b1892d5dd9fd072896f6e41942457bd80ebae506))
* **codex:** ignore scalar jsonl output ([b0d9651](https://github.com/viamin/agent-harness/commit/b0d965149123789dc8a6253814d58277d421c9cb))
* **codex:** merge late wrapped token usage ([e459b77](https://github.com/viamin/agent-harness/commit/e459b77ea7e9d0a716239178592000403543dcb1))
* **codex:** merge mixed same-turn token usage ([1a1f759](https://github.com/viamin/agent-harness/commit/1a1f7597a461acdde09ec69f2220faa84d651b6c))
* **codex:** normalize conflicting sandbox flags ([30525f8](https://github.com/viamin/agent-harness/commit/30525f8c2d7f43d0eb5e728e9f75ceb7f3587874))
* **codex:** normalize sandbox flags across sources ([f16bd75](https://github.com/viamin/agent-harness/commit/f16bd75216c3770ec069a1b1040114e36af231aa))
* **codex:** parse structured message delta content ([c9adac0](https://github.com/viamin/agent-harness/commit/c9adac07f4861f8c868f929f1d9c2be743c8ba46))
* **codex:** parse structured wrapped completion messages ([1c44f36](https://github.com/viamin/agent-harness/commit/1c44f36777a911f93d2b443fe11c1e7e272c6d07))
* **codex:** parse structured wrapped delta content ([d96b87a](https://github.com/viamin/agent-harness/commit/d96b87afc5bf2c3e888d7af83aea79ca0034684e))
* **codex:** parse top-level completion events ([5abc497](https://github.com/viamin/agent-harness/commit/5abc4979c6cb502cb189030116c9bd42d4cfa608))
* **codex:** parse top-level json assistant events ([a4b705f](https://github.com/viamin/agent-harness/commit/a4b705fd9996f86cc68f8777cb8a5af59b3e82cd))
* **codex:** prefer message over empty text ([db62c8e](https://github.com/viamin/agent-harness/commit/db62c8e499356cc8643381e24c6d838f204190db))
* **codex:** prefer per-turn wrapped token usage ([853584a](https://github.com/viamin/agent-harness/commit/853584a3f6818c8cd297931140c5998cb2ae0208))
* **codex:** preserve empty finalized json output ([75a17cc](https://github.com/viamin/agent-harness/commit/75a17ccd1ebabfc98413511cdeddfdd157a36398))
* **codex:** preserve finalized turns after wrapped usage ([32e6f4e](https://github.com/viamin/agent-harness/commit/32e6f4ee13beee90afbc554e9fb5473702ce6104))
* **codex:** preserve finalized turns without turn data ([d959b41](https://github.com/viamin/agent-harness/commit/d959b41da9f6f05b2d9996358f86efe23dc33081))
* **codex:** preserve flags after malformed sandbox mode ([fd68764](https://github.com/viamin/agent-harness/commit/fd687647b8cfbfed41882497c8d6caf1ba265364))
* **codex:** preserve inline sandbox-like flag values ([7c98e90](https://github.com/viamin/agent-harness/commit/7c98e9009f6dc48cd6058599cdacac262c40d5da))
* **codex:** preserve managed flag lookalikes in values ([84724b5](https://github.com/viamin/agent-harness/commit/84724b5659a5480b3dff3d9b8a0f4af025975140))
* **codex:** preserve output-last-message flag values ([7480778](https://github.com/viamin/agent-harness/commit/7480778d6a5d7b9227eec20889bc642eb399d1b5))
* **codex:** preserve raw jsonl output without text ([fd599a8](https://github.com/viamin/agent-harness/commit/fd599a8b81234b03fad292687cfdc3ea861f2d7a))
* **codex:** preserve repeated wrapped failed-turn usage ([b657168](https://github.com/viamin/agent-harness/commit/b657168b58117e776bb74e58c47bee68b46365d5))
* **codex:** preserve sandbox flag lookalikes for codex value flags ([71ea88b](https://github.com/viamin/agent-harness/commit/71ea88b74231207fb1f8c2c78097f9ae11d004ca))
* **codex:** preserve sandbox flag lookalikes in flag values ([3d51df6](https://github.com/viamin/agent-harness/commit/3d51df65075b38c1cea2caf9df6e5c42da0d74c7))
* **codex:** preserve structured delta content fallback ([cd2f356](https://github.com/viamin/agent-harness/commit/cd2f356ea7e0f98092ce05c92a8372d6ee17b97b))
* **codex:** preserve top-level finalized turns after wrapped usage ([8a3332d](https://github.com/viamin/agent-harness/commit/8a3332d22461ade9ea4d8cf67da2af279f4d1261))
* **codex:** preserve wrapped output across empty turn completion ([84b0e8d](https://github.com/viamin/agent-harness/commit/84b0e8d33cfc14562c201848729d3cad70c170cd))
* **codex:** respect empty completed turn output ([4c37397](https://github.com/viamin/agent-harness/commit/4c373971dccfe83e61506455fdc3be4075d6a70b))
* **codex:** restrict assistant_message fallback types ([80e3a80](https://github.com/viamin/agent-harness/commit/80e3a8017b274625b6419b23951b04c229ddd7ef))
* **codex:** return only final assistant turn text ([246a7ea](https://github.com/viamin/agent-harness/commit/246a7ea005896925246156e388fd69c5ddd1f3cd))
* **codex:** separate late wrapped usage across turns ([b759afd](https://github.com/viamin/agent-harness/commit/b759afd22d290d8897fb5b37c9438e5ed1cb126c))
* **codex:** split failed turns after wrapped usage ([7373b49](https://github.com/viamin/agent-harness/commit/7373b49479e9be072eaecb4823950ec5a807a67d))
* **codex:** split new streaming turns after wrapped usage ([06aa569](https://github.com/viamin/agent-harness/commit/06aa5693bb67120275f435e8d4b8a841f00f288e))
* **codex:** split wrapped usage after total-only turns ([e657b5b](https://github.com/viamin/agent-harness/commit/e657b5b0a5fababf5910119a496efc4ead2cea05))
* **codex:** strip conflicting explicit sandbox flags ([ceae818](https://github.com/viamin/agent-harness/commit/ceae818144ca50eb92716dcfe6231bc5324dfe9e))
* **codex:** strip conflicting sandbox mode flags ([ea1a5e1](https://github.com/viamin/agent-harness/commit/ea1a5e194b128f1d7b74fe8f8b5ab4c78f1181e7))
* **codex:** strip cross-source sandbox mode conflicts ([9939326](https://github.com/viamin/agent-harness/commit/993932661239d309d946ff291d64dd91825910d6))
* **codex:** strip explicit bypass sandbox conflicts ([1cb51ab](https://github.com/viamin/agent-harness/commit/1cb51ab27f282866f1edb666fcf2b969984a4f9e))
* **codex:** treat nil runtime flags as empty ([8ddcd0f](https://github.com/viamin/agent-harness/commit/8ddcd0fd39fd437219db49b6be0ddfcb3333ec6c))
* **codex:** validate default flag values before normalization ([e58975a](https://github.com/viamin/agent-harness/commit/e58975a8df6dfdc324f166bc5ed6a4f6a6c6ef4d))
* **codex:** validate false default flag configs ([dd3b9b2](https://github.com/viamin/agent-harness/commit/dd3b9b2b93dda96e09f6d9e91e6ce45a26677568))
* **codex:** validate runtime flags before normalization ([f411b1c](https://github.com/viamin/agent-harness/commit/f411b1c11a27bf5c062b4a7d6f8adc445292ede7))
* Configure RELEASE_PLEASE_TOKEN secret for Release Please workflow ([#324](https://github.com/viamin/agent-harness/issues/324)) ([0480f8b](https://github.com/viamin/agent-harness/commit/0480f8b8d43ab8536985f5b3055b5706b15a1541))
* **copilot:** add nil guard for stdout and improve error string construction ([6a30ce3](https://github.com/viamin/agent-harness/commit/6a30ce342100b27c0b16fc8c2abdce48bbf10ef7))
* **copilot:** align error ordering with base parser ([0a02d34](https://github.com/viamin/agent-harness/commit/0a02d34cbf07e4f4ecb4d3efc6d69b5b072c6114))
* **copilot:** align metadata and reply parsing ([e5c3387](https://github.com/viamin/agent-harness/commit/e5c338743dbb5ec8eea5b1a8de5a515f1df7e141))
* **copilot:** avoid double-counting token aliases ([40e78f3](https://github.com/viamin/agent-harness/commit/40e78f34a6304a5ae21e26c6c291eed773618bea))
* **copilot:** avoid mixing shutdown token totals ([c4bdfb8](https://github.com/viamin/agent-harness/commit/c4bdfb8fd4c20781ef4621cf421947b14514cb45))
* **copilot:** drop superseded delta chunks ([769acd6](https://github.com/viamin/agent-harness/commit/769acd6a45f1037f11fc83ea23f5ddeda9aadd17))
* **copilot:** fall back across malformed token aliases ([9c9f5f8](https://github.com/viamin/agent-harness/commit/9c9f5f8048f63407b6ffc14fb339c26158f74dab))
* **copilot:** fall back from empty nested message content ([ecd9f49](https://github.com/viamin/agent-harness/commit/ecd9f497e0ef9812f2df363b02679b5842cf668c))
* **copilot:** fall back from empty shutdown metrics ([0397f1e](https://github.com/viamin/agent-harness/commit/0397f1e5f9442d0d6489c9fe7744d31a0ff48965))
* **copilot:** fall back from malformed nested message content ([a313487](https://github.com/viamin/agent-harness/commit/a313487f2c1bb9fbf5e7a60e5dc08e7a7079447c))
* **copilot:** fall back from malformed usage payloads ([733599c](https://github.com/viamin/agent-harness/commit/733599c599cda90873cec823c245b13c81f74ee6))
* **copilot:** gate json output by cli version ([528d03b](https://github.com/viamin/agent-harness/commit/528d03bed7506996cf9cfd6c4cf54807da254260))
* **copilot:** github-copilot-cli does not support the -p flag used by build_command ([#141](https://github.com/viamin/agent-harness/issues/141)) ([d06fbc4](https://github.com/viamin/agent-harness/commit/d06fbc414489d6c3bc93a122d0eb2a5771ddbb26))
* **copilot:** guard scalar json events ([13a4131](https://github.com/viamin/agent-harness/commit/13a413157cc159cfc4fd6b7e7ab7fdbb948d07b6))
* **copilot:** handle JSON event envelopes and camelCase token fields ([e0ee83e](https://github.com/viamin/agent-harness/commit/e0ee83ed73d715d9c67806b5253abab33cce9e19))
* **copilot:** hash unresolved probe path keys ([ea9aca2](https://github.com/viamin/agent-harness/commit/ea9aca215b000833be18bf035cba6c0bf029615d))
* **copilot:** hide structured control events from output ([81c108d](https://github.com/viamin/agent-harness/commit/81c108d521e8f72522dc1dc604cccdf46f0d01d4))
* **copilot:** ignore delta chunks after final reply ([6aef1ca](https://github.com/viamin/agent-harness/commit/6aef1ca4459a5588fc53b70692f95c6eff3b9d88))
* **copilot:** ignore empty delta chunks ([dca6395](https://github.com/viamin/agent-harness/commit/dca63951866a4dc65b2adca3b834d05a6716f298))
* **copilot:** ignore failed version probes ([fa6ba35](https://github.com/viamin/agent-harness/commit/fa6ba35e1e36f153f47bccf9c423cea7927176e7))
* **copilot:** ignore malformed delta content fallback ([0c9211b](https://github.com/viamin/agent-harness/commit/0c9211bb16e713f4b7185c1b9ccda5d065b9d405))
* **copilot:** ignore malformed token payloads ([0f2f06b](https://github.com/viamin/agent-harness/commit/0f2f06b9a8c0b4244c7b8040e5590cc6e4710143))
* **copilot:** ignore malformed typed json fallbacks ([0cd5535](https://github.com/viamin/agent-harness/commit/0cd553594aff277ce07abd3d151028ad22b3f597))
* **copilot:** ignore nested non-assistant fallback text ([799f976](https://github.com/viamin/agent-harness/commit/799f976ef19618acaae1a6e0ecf7faa76b9ff37f))
* **copilot:** ignore non-assistant top-level messages ([119c854](https://github.com/viamin/agent-harness/commit/119c8540e7db9f1827eac75e73403b638cf8db23))
* **copilot:** ignore non-assistant top-level token payloads ([23c05b9](https://github.com/viamin/agent-harness/commit/23c05b9dbc6231755783f4a8eefd5099067f9389))
* **copilot:** ignore partial invalid token aliases ([3344c07](https://github.com/viamin/agent-harness/commit/3344c078d291277b8831ab69fa5d2a40ca95135b))
* **copilot:** isolate probe cache for PATH overrides ([5fa79a9](https://github.com/viamin/agent-harness/commit/5fa79a91fd90dd33a15d5c6a0c25c2619b8f0ac3))
* **copilot:** keep delta output on empty final reply ([64fbf68](https://github.com/viamin/agent-harness/commit/64fbf68ffb66b58d7546bc1841c78fec86201acb))
* **copilot:** keep preflight errors inside base handler ([49c9075](https://github.com/viamin/agent-harness/commit/49c9075d4a1fb9ff42d633723cb5f375e8c2721c))
* **copilot:** merge partial shutdown token totals ([49d6b2b](https://github.com/viamin/agent-harness/commit/49d6b2b6727297a58e9aa265347c781405012aa0))
* **copilot:** merge top-level token fallbacks ([826c1f9](https://github.com/viamin/agent-harness/commit/826c1f9fd427b10c40fb34c5b47f4c9fb06f1e64))
* **copilot:** parse session shutdown token totals ([0148afd](https://github.com/viamin/agent-harness/commit/0148afd2f95312eae687799541545dd8ece185f3))
* **copilot:** parse streamed delta reply events ([55f553f](https://github.com/viamin/agent-harness/commit/55f553f39dbe729588641b86168f8c36500ec872))
* **copilot:** prefer final replies and trim probe cache keys ([38dc20e](https://github.com/viamin/agent-harness/commit/38dc20edac2326265c8f9d149394650b70c43e90))
* **copilot:** prefer final reply over delta chunks ([955654d](https://github.com/viamin/agent-harness/commit/955654db325cc47c8cf0ac992de55e574a45c641))
* **copilot:** prefer nested assistant message fallback ([15aa6db](https://github.com/viamin/agent-harness/commit/15aa6dbf4bb171eaaa5b85c552008953141ba622))
* **copilot:** prefer per-turn usage over shutdown totals ([38bd47c](https://github.com/viamin/agent-harness/commit/38bd47c00e5d74ef365a74dc61df9e2fdc5b9c04))
* **copilot:** prefer populated top-level usage payloads ([8b3aac0](https://github.com/viamin/agent-harness/commit/8b3aac029004f65efe26e8b3fc27f62ac2008dca))
* **copilot:** preserve blank mixed output lines ([e9830fc](https://github.com/viamin/agent-harness/commit/e9830fcfcceeb7fc67caac658ed16867e1f303d0))
* **copilot:** preserve empty nested message payloads ([edf27bc](https://github.com/viamin/agent-harness/commit/edf27bcafbfb29dc0f5baf54fcedb8e959e20bba))
* **copilot:** preserve empty top-level fallback payloads ([1863854](https://github.com/viamin/agent-harness/commit/1863854af8545573a6c9a80cc47297487ee6d2ac))
* **copilot:** preserve legitimate exit codes in responses ([d1a3cc0](https://github.com/viamin/agent-harness/commit/d1a3cc0f21ea1a45fee0dbf181462efc8b414fc8))
* **copilot:** preserve literal json stdout ([7d7862c](https://github.com/viamin/agent-harness/commit/7d7862c4da83ccf9bafbbca19b595911923edeed))
* **copilot:** preserve malformed top-level json output ([f7c5bec](https://github.com/viamin/agent-harness/commit/f7c5becaa01584c53f1327be0afbd2fcebe7f3e8))
* **copilot:** preserve malformed usage hashes ([0eef69b](https://github.com/viamin/agent-harness/commit/0eef69b470927412c405a774125ca0aa9a58e302))
* **copilot:** preserve mixed json and text output ([95de0f7](https://github.com/viamin/agent-harness/commit/95de0f72a2bd8a86d33ab0806fb1baf481e52d03))
* **copilot:** preserve mixed output line boundaries ([b285526](https://github.com/viamin/agent-harness/commit/b28552627192aa613c73c7bf2c8c8afed6811c36))
* **copilot:** preserve mixed plain-text output ([d277f3a](https://github.com/viamin/agent-harness/commit/d277f3a4ed2799182a2083989a0bdaf9960df16b))
* **copilot:** preserve non-event typed json output ([27d01c6](https://github.com/viamin/agent-harness/commit/27d01c649cab65ba2da206636f45170af5abbcc9))
* **copilot:** preserve scalar json stdout ([7c5e74c](https://github.com/viamin/agent-harness/commit/7c5e74cd9aed9de17f572b98faac9c09b8cd9707))
* **copilot:** preserve unknown typed json output ([942edac](https://github.com/viamin/agent-harness/commit/942edac7bc36d9e26a7c02945f15503ce7faeb73))
* **copilot:** preserve zero token aliases ([853d251](https://github.com/viamin/agent-harness/commit/853d251869adb3cc36bebc5b6d750a58c70843f7))
* **copilot:** probe json support per request env ([da94082](https://github.com/viamin/agent-harness/commit/da94082a79a044eb89b470b26eeda29196e7ac95))
* **copilot:** reject invalid token counts ([106c386](https://github.com/viamin/agent-harness/commit/106c3867d024751e77aa0fc215c651de87230a13))
* **copilot:** restore reply token fallback ([c9d7182](https://github.com/viamin/agent-harness/commit/c9d71820b0becc80e44a77169c2990be20469be2))
* **copilot:** restrict token accumulation to usage event types only ([80c979b](https://github.com/viamin/agent-harness/commit/80c979b9952defa05923920a737bb74e1c8885e4))
* **copilot:** skip blank assistant boundaries ([b9dec9a](https://github.com/viamin/agent-harness/commit/b9dec9af0c6084e1809dc1fb1c50535b987037a1))
* **copilot:** skip json parsing in legacy mode ([af9ac12](https://github.com/viamin/agent-harness/commit/af9ac1253aa4246c92727bc04f23d6704ec8926e))
* **copilot:** store probe env per thread ([301f2aa](https://github.com/viamin/agent-harness/commit/301f2aa4c43b183dea8450d21eb7fec799e92ec6))
* **copilot:** stub json support in parser specs ([96a945e](https://github.com/viamin/agent-harness/commit/96a945ec1572e10231b696008c7514d1acb92c11))
* **copilot:** sum reply token fallback ([82c5097](https://github.com/viamin/agent-harness/commit/82c5097b73f17e64cd3015c34aa92bfd713c0428))
* **copilot:** support snake_case delta chunks ([d33ecbc](https://github.com/viamin/agent-harness/commit/d33ecbcc446d895d35f03a7513ad7b16f0f57b1d))
* **copilot:** support snake_case shutdown metrics ([8c6e93e](https://github.com/viamin/agent-harness/commit/8c6e93e70e0927c95c63811b247291faaceacab0))
* **copilot:** suppress additional control events ([b14b8bb](https://github.com/viamin/agent-harness/commit/b14b8bbebb2fcc0c975788c1168965bee3281a79))
* **copilot:** suppress control event namespaces ([7b31bb2](https://github.com/viamin/agent-harness/commit/7b31bb293fb858808e493a23e268d89a590741a0))
* **copilot:** suppress root control events ([5d4d3ec](https://github.com/viamin/agent-harness/commit/5d4d3ecb80864ad4d20e0da1083ac02d90773fbf))
* **copilot:** update output_format metadata and add missing parse_response tests ([7fdedde](https://github.com/viamin/agent-harness/commit/7fdeddee3bbe5eca96f29f5613a5c36189695ec4))
* Fix stuck release-please publishing after 0.31.1 ([#322](https://github.com/viamin/agent-harness/issues/322)) ([652a41a](https://github.com/viamin/agent-harness/commit/652a41a52eed306a432495a2d600bff6e7337432))
* Gem name (agent-harness) and require file (agent_harness) naming mismatch ([#189](https://github.com/viamin/agent-harness/issues/189)) ([4f19ba6](https://github.com/viamin/agent-harness/commit/4f19ba61d31a7815100fc602b73230b369770961))
* Kilocode: default external_directory permission blocks /tmp scratch files, silently killing non-interactive runs ([#283](https://github.com/viamin/agent-harness/issues/283)) ([1ad518f](https://github.com/viamin/agent-harness/commit/1ad518f5c135c5c95d161b9d41a799692f470f76))
* Kilocode: default external_directory permission blocks /tmp scratch files, silently killing non-interactive runs ([#285](https://github.com/viamin/agent-harness/issues/285)) ([d703c0a](https://github.com/viamin/agent-harness/commit/d703c0abb7b91fb7a5ba8081e612486edff5e8f5))
* Kilocode/OpenCode: external_directory permission also blocks ~/.config and ~/.local/share paths, not just /tmp ([#290](https://github.com/viamin/agent-harness/issues/290)) ([7042f57](https://github.com/viamin/agent-harness/commit/7042f572e5723120159c96b735906edeede6ef76))
* **kilocode:** aggregate token counts across multiple step_finish events ([23c8c55](https://github.com/viamin/agent-harness/commit/23c8c55def0452de1e0b25765c4f6d1fcd3474d4))
* **kilocode:** avoid raw ndjson in structured failures ([932e56e](https://github.com/viamin/agent-harness/commit/932e56e06567095750a7bcf15bf5adea065eab44))
* **kilocode:** bump Kilocode CLI from 7.1.3 to 7.4.16 — missing glm-5.x model catalog ([#319](https://github.com/viamin/agent-harness/issues/319)) ([f12bce7](https://github.com/viamin/agent-harness/commit/f12bce7e127b9df92c30c63b3ae27468d62248fc))
* **kilocode:** clear stale extra usage categories ([2ff7079](https://github.com/viamin/agent-harness/commit/2ff70795a9e3397d5844de92c47a59b49a599426))
* **kilocode:** config_file_content generates invalid JSON for kilo CLI v7.1.3 ([#190](https://github.com/viamin/agent-harness/issues/190)) ([0f7e24a](https://github.com/viamin/agent-harness/commit/0f7e24a8c342045d16a9332385e93f0607d0845e))
* **kilocode:** count extra result usage tokens ([f65dd3d](https://github.com/viamin/agent-harness/commit/f65dd3d8e4f54174b18233ddd55dba2d3c3fd1f3))
* **kilocode:** count reasoning and cache step tokens ([c46d089](https://github.com/viamin/agent-harness/commit/c46d089d4d0492534d98736dcdcb1ff82a67d0c1))
* **kilocode:** fail on structured error events ([48f5378](https://github.com/viamin/agent-harness/commit/48f5378f37cf64af28238c67314a01a3758aab05))
* **kilocode:** fall back to result text after blank chunks ([7508c58](https://github.com/viamin/agent-harness/commit/7508c58a84f365a680578891dd582a6f13484f1e))
* **kilocode:** fall back to step token totals when usage is incomplete ([8534691](https://github.com/viamin/agent-harness/commit/8534691ff74ba4efa1ae5d50de329bc53e863bcf))
* **kilocode:** fall through blank part message aliases ([85db058](https://github.com/viamin/agent-harness/commit/85db05824684cde93755c4d87323bce79e0a1dd7))
* **kilocode:** fall through blank part text chunks ([417a4c8](https://github.com/viamin/agent-harness/commit/417a4c8005f23c28f5a68a834890614ca49c5dca))
* **kilocode:** fall through blank text aliases ([63ed6a1](https://github.com/viamin/agent-harness/commit/63ed6a1bb002329ab823a8844e0ac81ef065938b))
* **kilocode:** guard malformed structured output payloads ([30a59a2](https://github.com/viamin/agent-harness/commit/30a59a21d3b4012cec4dbfa27b5471b9dee329bd))
* **kilocode:** guard scalar structured error payloads ([26843a9](https://github.com/viamin/agent-harness/commit/26843a90019d3f29f15eb363d098f0bba0f00582))
* **kilocode:** guard step_finish part.tokens against non-Hash values ([ff2d841](https://github.com/viamin/agent-harness/commit/ff2d8414eb928bd679d9754a71d0849963298a4b))
* **kilocode:** honor explicit usage totals ([d1e5275](https://github.com/viamin/agent-harness/commit/d1e5275f3515ae40db4b523e0efe2ce8a3d169a1))
* **kilocode:** honor later explicit total alias updates ([496df42](https://github.com/viamin/agent-harness/commit/496df425a8a5e76e97134dea8b1f74a0067aad1b))
* **kilocode:** honor synthesized result usage totals ([b0779a7](https://github.com/viamin/agent-harness/commit/b0779a78400c1a3b6aa38610582c5cf96446b28e))
* **kilocode:** honor valid total fallback aliases ([d0ae122](https://github.com/viamin/agent-harness/commit/d0ae12245be3e606d0919bf78dcc858525c64036))
* **kilocode:** ignore blank terminal result strings ([ebb34b6](https://github.com/viamin/agent-harness/commit/ebb34b663c7c0a933aedc17efba444263a891b80))
* **kilocode:** ignore negative token counts ([aee8d1e](https://github.com/viamin/agent-harness/commit/aee8d1e35e438ae25bf3a37571d273d891b89b24))
* **kilocode:** ignore non-string text payloads ([4a35a6f](https://github.com/viamin/agent-harness/commit/4a35a6fb1555923b3d1555bc895051bbaa7db26c))
* **kilocode:** ignore scalar json fallback noise ([1f62463](https://github.com/viamin/agent-harness/commit/1f624631477557ae533d605ecf37a5fb40c39544))
* **kilocode:** ignore usage on non-usage events ([b23ac10](https://github.com/viamin/agent-harness/commit/b23ac10c0d4107e05a50a2dc83204c0088bddbbb))
* **kilocode:** ignore whitespace-only text alias placeholders ([62bb641](https://github.com/viamin/agent-harness/commit/62bb641a7b7ac5434b2e905c6b297b2abf989020))
* **kilocode:** ignore whitespace-only text chunks ([699cccc](https://github.com/viamin/agent-harness/commit/699cccc1025b83a3850b7ed2670ff60de39e6adf))
* **kilocode:** keep last usable structured usage payload ([1b9d9bd](https://github.com/viamin/agent-harness/commit/1b9d9bd7ebbaa0ae9ed6dd7379f9b8c67de19025))
* **kilocode:** keep stdout diagnostics with structured errors ([76446fc](https://github.com/viamin/agent-harness/commit/76446fc8a95c89c9944b47db794ddb776e29686f))
* **kilocode:** merge partial structured usage events ([2de37e2](https://github.com/viamin/agent-harness/commit/2de37e246317650f60a0399c2f731f03ecf28ec9))
* **kilocode:** normalize malformed token counts ([ef4c3dc](https://github.com/viamin/agent-harness/commit/ef4c3dce783e71aae1b60c543da59f64b4efdb6c))
* **kilocode:** parse hash-shaped structured error aliases ([431f8c4](https://github.com/viamin/agent-harness/commit/431f8c438d7b13bf45d3416e947d3ad34b8b4eca))
* **kilocode:** parse NDJSON event stream instead of single JSON object ([4e1252f](https://github.com/viamin/agent-harness/commit/4e1252fc384c51d118b43647a7026281927b6794))
* **kilocode:** parse nested part error messages ([8d49794](https://github.com/viamin/agent-harness/commit/8d49794f79bbe553cfe8f569867508bb80a86805))
* **kilocode:** parse nested structured error messages ([b9fee6a](https://github.com/viamin/agent-harness/commit/b9fee6a8814045f0c5329bac23b0f0b424b17566))
* **kilocode:** parse token usage from step_finish.part.tokens ([bbf5a58](https://github.com/viamin/agent-harness/commit/bbf5a58fc6bc631a483a3e71bc0d8b99744e9f7b))
* **kilocode:** pass legitimate_exit_codes in Response metadata ([dac77c2](https://github.com/viamin/agent-harness/commit/dac77c24711bf717b7d98d847a21d3922889026b))
* **kilocode:** preserve base error stream ordering ([5281d78](https://github.com/viamin/agent-harness/commit/5281d7875c54cd010364b251069d921c4c5e4838))
* **kilocode:** preserve extra usage totals without io counts ([b4fb265](https://github.com/viamin/agent-harness/commit/b4fb2657aa56ad42e514a42dd0176742a48fdbc4))
* **kilocode:** preserve json array fallback output ([16cb566](https://github.com/viamin/agent-harness/commit/16cb5668e1442a9232ca5fcc38d0b196eb673956))
* **kilocode:** preserve mixed structured failure diagnostics ([5ec3be7](https://github.com/viamin/agent-harness/commit/5ec3be7ff143803c8e9602a1d76b6c7c4c0beb12))
* **kilocode:** preserve mixed structured success output ([ea64e2e](https://github.com/viamin/agent-harness/commit/ea64e2ea7154c15193ce35c115874bb898dcdc84))
* **kilocode:** preserve provider token totals ([b62d749](https://github.com/viamin/agent-harness/commit/b62d7499070aa5233c56b7207b6a2aede97a7dfc))
* **kilocode:** preserve raw mixed stdout spacing ([881c51e](https://github.com/viamin/agent-harness/commit/881c51e9a88705e0d8e28e06cb7fd7381f55feed))
* **kilocode:** preserve raw output for non-event json ([ce9be0f](https://github.com/viamin/agent-harness/commit/ce9be0f5f8d807dda995202fbe2dc26cddee32b2))
* **kilocode:** preserve step extras with partial usage ([14eeddb](https://github.com/viamin/agent-harness/commit/14eeddb6ec9e056c8b20ee9251e42a26de260079))
* **kilocode:** preserve step token totals for partial usage ([5efe2f4](https://github.com/viamin/agent-harness/commit/5efe2f4d3804f52cfae1b6ee63da87d3459a8c0f))
* **kilocode:** preserve terminal result payload spacing ([977faa7](https://github.com/viamin/agent-harness/commit/977faa7eed454c6070503589cc995f3021d19476))
* **kilocode:** preserve terminal result text ([282ae35](https://github.com/viamin/agent-harness/commit/282ae35051b715f0210534f31adb87152c75b6b7))
* **kilocode:** preserve terminal result text across result events ([5652453](https://github.com/viamin/agent-harness/commit/56524531434d9d7c71f7af3acd17d25dbf9656ca))
* **kilocode:** preserve unreconstructable step totals ([a906ee9](https://github.com/viamin/agent-harness/commit/a906ee951d6dfa5aa74e149f2e41fa214ffad2cf))
* **kilocode:** preserve unreconstructable totals with result extras ([7585e29](https://github.com/viamin/agent-harness/commit/7585e29d0eb6668f48b6db3ab033272b74d4831f))
* **kilocode:** preserve whitespace in text alias chunks ([a6592c1](https://github.com/viamin/agent-harness/commit/a6592c12e753a91cdd8f6c0041100c2a0c01d89a))
* **kilocode:** read terminal result text from hash payloads ([2ac7012](https://github.com/viamin/agent-harness/commit/2ac701278133e2f0fee64a7cb33f854ecff0754b))
* **kilocode:** recompute totals from updated usage ([aafabfd](https://github.com/viamin/agent-harness/commit/aafabfd972c56e35bcaa36eb92b1658cb6579a6c))
* **kilocode:** reject fractional token counts ([935a41d](https://github.com/viamin/agent-harness/commit/935a41d327f7d9433368db40da93ab1983e14cbc))
* **kilocode:** reject non-decimal string token counts ([0be6ddf](https://github.com/viamin/agent-harness/commit/0be6ddf31a306face9b61498d1a77d08a94a02a5))
* **kilocode:** remove stray binstubs and add missing test coverage ([25287f7](https://github.com/viamin/agent-harness/commit/25287f736c8bd81820553fc5ca2517e1c64f261c))
* **kilocode:** replace stale partial extra usage fields ([4b89027](https://github.com/viamin/agent-harness/commit/4b8902768620ffb5787e194753b14f6eb7c496d7))
* **kilocode:** skip scalar JSON lines before reading event fields ([b8fce27](https://github.com/viamin/agent-harness/commit/b8fce27bceb998a6a4b2a3de7ed95f96a2794c3d))
* **kilocode:** support hash-shaped part text aliases ([778e25c](https://github.com/viamin/agent-harness/commit/778e25c62cf32bafd1c0fb4bae32b2ea13cf1df9))
* **kilocode:** support nested result message aliases ([e8a5988](https://github.com/viamin/agent-harness/commit/e8a5988e34dfb1afd70eccb551985fa7e273192e))
* **kilocode:** support result text aliases ([63ccff9](https://github.com/viamin/agent-harness/commit/63ccff9be0c32ffcfd04e3745a441d6d2370eeac))
* **kilocode:** support scalar part structured errors ([2dd4740](https://github.com/viamin/agent-harness/commit/2dd47408f39340b075815ce64ac02c588fc445de))
* **kilocode:** support scalar text part payloads ([b9e9013](https://github.com/viamin/agent-harness/commit/b9e90137e6b43fb2eb789857da319221203a7f76))
* **kilocode:** support text event alias payloads ([4c425ff](https://github.com/viamin/agent-harness/commit/4c425fff93dcd872e2640743cb21da9668f952b7))
* **kilocode:** support top-level result text aliases ([9ce7c02](https://github.com/viamin/agent-harness/commit/9ce7c0249acaf3b44731271fc8b50d8fbb14cedc))
* **kilocode:** support top-level structured error text ([cad1d31](https://github.com/viamin/agent-harness/commit/cad1d31007d79b75daecb61b4f1ed8573f9e70a0))
* **kilocode:** suppress raw ndjson output for structured events ([d7a07d7](https://github.com/viamin/agent-harness/commit/d7a07d70812b40a75f6a09924d1fd609e99a61df))
* **kilocode:** test_command_overrides never wired into smoke test — kilo hangs without --auto ([#191](https://github.com/viamin/agent-harness/issues/191)) ([7c01d49](https://github.com/viamin/agent-harness/commit/7c01d49713cbedb6fb93758be95b7d92aa4599d3))
* **kilocode:** treat missing usage tokens as unknown ([5e6335f](https://github.com/viamin/agent-harness/commit/5e6335f901e8f197de9c8f4df5727f90fc06ee43))
* **kilocode:** whitelist structured event types ([d6d8a7d](https://github.com/viamin/agent-harness/commit/d6d8a7d5bf6268050bf2083494360debeec80fab))
* Merge default KiloCode external_directory permissions with caller config ([#311](https://github.com/viamin/agent-harness/issues/311)) ([3a9563a](https://github.com/viamin/agent-harness/commit/3a9563adc7127aa7adb73bab85ef5a515b7ee790))
* **opencode:** default-merge permissive external_directory permission for non-interactive runs ([#280](https://github.com/viamin/agent-harness/issues/280)) ([1a282aa](https://github.com/viamin/agent-harness/commit/1a282aad6de0e696a9fcd02ebc0be32f1ef6e0e9)), closes [#277](https://github.com/viamin/agent-harness/issues/277)
* prevent far-future rate-limit resets in parse_resets_date_time ([4fbbbb8](https://github.com/viamin/agent-harness/commit/4fbbbb8feffd1e959a0ac8a7cdc17d2ea9cc81bd))
* Rate-limit reset parser fabricates far-future resets (year over-bump in parse_resets_date_time) ([6c7a34e](https://github.com/viamin/agent-harness/commit/6c7a34e7fb6b7b3080707e752e778423d6c26238))
* **release:** prevent release-please cancellation race ([#327](https://github.com/viamin/agent-harness/issues/327)) ([ae2d964](https://github.com/viamin/agent-harness/commit/ae2d9646a096881fa2a91cbd7b193186f784a4ea))
* **release:** require conventional PR titles for release-please ([4f0054f](https://github.com/viamin/agent-harness/commit/4f0054f4c9f35251c3185fa8bbf645fcace130b5))
* **release:** require conventional PR titles for release-please ([fd6633d](https://github.com/viamin/agent-harness/commit/fd6633dff3710ad1575af9bd172f047a93a8f647))
* remove hardcoded o4-mini model from codex smoke test ([#254](https://github.com/viamin/agent-harness/issues/254)) ([f088cf1](https://github.com/viamin/agent-harness/commit/f088cf1d10b15867c6ee39976658e3e0fe5e6ab3))
* revert unrelated BUNDLED WITH version bump in Gemfile.lock ([5a03f03](https://github.com/viamin/agent-harness/commit/5a03f039c99e74801b6eddfa48829d95e8ccb61b))
* specify explicit model in codex smoke test overrides ([#251](https://github.com/viamin/agent-harness/issues/251)) ([0dcaf42](https://github.com/viamin/agent-harness/commit/0dcaf42c82b7b559f6bb38e7f6ee346f52fb5900))
* supply tempfile path for --output-last-message in codex test_command_overrides ([#248](https://github.com/viamin/agent-harness/issues/248)) ([86c5621](https://github.com/viamin/agent-harness/commit/86c562183d5ff00ff8b14d93942ec752e543bb59)), closes [#246](https://github.com/viamin/agent-harness/issues/246)
* use comma-separated --disallowedTools= syntax to prevent varargs consuming prompt ([9a97717](https://github.com/viamin/agent-harness/commit/9a97717fd002616465ff0e0b7733aa5391ceb1cb)), closes [#212](https://github.com/viamin/agent-harness/issues/212)


### Improvements

* **kilocode:** remove unreachable structured error branch ([3d7ec3d](https://github.com/viamin/agent-harness/commit/3d7ec3d94e7be6b6f2c2c92d0daf0ce0590c4067))


### Dependencies

* **deps-dev:** bump simplecov from 0.22.0 to 1.0.0 ([#293](https://github.com/viamin/agent-harness/issues/293)) ([4bd832f](https://github.com/viamin/agent-harness/commit/4bd832f2eb81c7aebb7fb37772617770adc14fcd))
* **deps-dev:** bump simplecov in the minor-updates group ([#313](https://github.com/viamin/agent-harness/issues/313)) ([41a52b6](https://github.com/viamin/agent-harness/commit/41a52b68eec46293dc0dff7235c6302b5f11bfdc))
* **deps:** bump rake from 13.3.1 to 13.4.2 in the minor-updates group ([f9189f1](https://github.com/viamin/agent-harness/commit/f9189f1d78cd2348fb792d22156ecce6cefdd3a8))
* **deps:** bump standard from 1.54.0 to 1.55.0 in the minor-updates group across 1 directory ([#258](https://github.com/viamin/agent-harness/issues/258)) ([541c2da](https://github.com/viamin/agent-harness/commit/541c2da27dc291402d989edf7a1d81396bc1dc66))
* **deps:** bump the minor-updates group with 2 updates ([#306](https://github.com/viamin/agent-harness/issues/306)) ([c7f985f](https://github.com/viamin/agent-harness/commit/c7f985f0a550b953c7783bf1d737a24be5dc1ab0))

## [0.32.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.31.1...agent-harness/v0.32.0) (2026-07-29)

### Features

* bump the OpenCode install contract to `opencode-ai@1.18.9` and widen the supported CLI requirement to `>= 1.18.9, < 2.0.0` so downstream runner images can consume GLM-capable OpenCode releases ([#316](https://github.com/viamin/agent-harness/issues/316)).

## [0.31.1](https://github.com/viamin/agent-harness/compare/agent-harness/v0.31.0...agent-harness/v0.31.1) (2026-07-20)


### Dependencies

* **deps:** bump the minor-updates group with 2 updates ([#306](https://github.com/viamin/agent-harness/issues/306)) ([c7f985f](https://github.com/viamin/agent-harness/commit/c7f985f0a550b953c7783bf1d737a24be5dc1ab0))

## [0.31.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.30.0...agent-harness/v0.31.0) (2026-07-16)


### Features

* release agent-harness 0.31.0 with omp support ([#302](https://github.com/viamin/agent-harness/issues/302)) ([7a82fbc](https://github.com/viamin/agent-harness/commit/7a82fbc5cc627eaa10c678e3e2b998fc0ce100f2))

## [0.31.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.30.0...agent-harness/v0.31.0) (2026-07-16)


### Features

* release a single `agent-harness` gem version that consolidates the full `:omp` provider contract for downstream consumers: distinct `:omp` provider metadata separate from `:pi`, the install/runtime contract for `@oh-my-pi/pi-coding-agent` `17.0.1`, the Bun runtime floor `>= 1.3.14` (pinned install target `1.3.14`), the smoke-test contract, and regression coverage for the public `AgentHarness` APIs ([#297](https://github.com/viamin/agent-harness/issues/297))


## [0.30.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.29.0...agent-harness/v0.30.0) (2026-07-16)


### Features

* Implement Oh My Pi execution, auth, and smoke-test contract ([#300](https://github.com/viamin/agent-harness/issues/300)) ([dc3f5ec](https://github.com/viamin/agent-harness/commit/dc3f5ecce4508f103a8b769727e31aaa3d694c7e))

## [0.29.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.28.6...agent-harness/v0.29.0) (2026-07-16)


### Features

* Add Oh My Pi provider metadata and install contract ([#298](https://github.com/viamin/agent-harness/issues/298)) ([3be62a8](https://github.com/viamin/agent-harness/commit/3be62a884f50ceeb903e199f4a9906cf3fecf014))

## [0.28.6](https://github.com/viamin/agent-harness/compare/agent-harness/v0.28.5...agent-harness/v0.28.6) (2026-07-12)


### Dependencies

* **deps-dev:** bump simplecov from 0.22.0 to 1.0.0 ([#293](https://github.com/viamin/agent-harness/issues/293)) ([4bd832f](https://github.com/viamin/agent-harness/commit/4bd832f2eb81c7aebb7fb37772617770adc14fcd))

## [0.28.5](https://github.com/viamin/agent-harness/compare/agent-harness/v0.28.4...agent-harness/v0.28.5) (2026-07-10)


### Bug Fixes

* Kilocode/OpenCode: external_directory permission also blocks ~/.config and ~/.local/share paths, not just /tmp ([#290](https://github.com/viamin/agent-harness/issues/290)) ([7042f57](https://github.com/viamin/agent-harness/commit/7042f572e5723120159c96b735906edeede6ef76))

## [0.28.4](https://github.com/viamin/agent-harness/compare/agent-harness/v0.28.3...agent-harness/v0.28.4) (2026-07-10)


### Bug Fixes

* Codex model_compatibility returns 'unknown' for models definitively unsupported with subscription auth (e.g. gpt-5.5-pro) ([#287](https://github.com/viamin/agent-harness/issues/287)) ([a6f87ce](https://github.com/viamin/agent-harness/commit/a6f87ce07a2514e069559d57d8496dd323bd0891))

## [0.28.3](https://github.com/viamin/agent-harness/compare/agent-harness/v0.28.2...agent-harness/v0.28.3) (2026-07-10)


### Bug Fixes

* Kilocode: default external_directory permission blocks /tmp scratch files, silently killing non-interactive runs ([#285](https://github.com/viamin/agent-harness/issues/285)) ([d703c0a](https://github.com/viamin/agent-harness/commit/d703c0abb7b91fb7a5ba8081e612486edff5e8f5))

## [0.28.2](https://github.com/viamin/agent-harness/compare/agent-harness/v0.28.1...agent-harness/v0.28.2) (2026-07-10)


### Bug Fixes

* Kilocode: default external_directory permission blocks /tmp scratch files, silently killing non-interactive runs ([#283](https://github.com/viamin/agent-harness/issues/283)) ([1ad518f](https://github.com/viamin/agent-harness/commit/1ad518f5c135c5c95d161b9d41a799692f470f76))

## [0.28.1](https://github.com/viamin/agent-harness/compare/agent-harness/v0.28.0...agent-harness/v0.28.1) (2026-07-08)


### Bug Fixes

* **opencode:** default-merge permissive external_directory permission for non-interactive runs ([#280](https://github.com/viamin/agent-harness/issues/280)) ([1a282aa](https://github.com/viamin/agent-harness/commit/1a282aad6de0e696a9fcd02ebc0be32f1ef6e0e9)), closes [#277](https://github.com/viamin/agent-harness/issues/277)

## [0.28.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.27.1...agent-harness/v0.28.0) (2026-07-08)


### Features

* allow OpenCode tmp scratch access ([#278](https://github.com/viamin/agent-harness/issues/278)) ([886437f](https://github.com/viamin/agent-harness/commit/886437f6d8429a487d043eb2242cb3f60ab604f6))

## [0.27.1](https://github.com/viamin/agent-harness/compare/agent-harness/v0.27.0...agent-harness/v0.27.1) (2026-07-07)


### Dependencies

* **deps:** bump standard from 1.54.0 to 1.55.0 in the minor-updates group across 1 directory ([#258](https://github.com/viamin/agent-harness/issues/258)) ([541c2da](https://github.com/viamin/agent-harness/commit/541c2da27dc291402d989edf7a1d81396bc1dc66))

## [0.27.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.26.0...agent-harness/v0.27.0) (2026-06-27)


### Features

* Authentication: Claude OAuth PKCE code-exchange API ([#267](https://github.com/viamin/agent-harness/issues/267)) ([7cabc73](https://github.com/viamin/agent-harness/commit/7cabc73f2a660e292533175e9db3a94d18326031))

## [0.26.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.25.0...agent-harness/v0.26.0) (2026-06-26)


### Features

* **auth:** add PKCE code-exchange API for Claude OAuth ([#272](https://github.com/viamin/agent-harness/issues/272)) ([22f873b](https://github.com/viamin/agent-harness/commit/22f873bb5fe58c67ab94c2a7b0c57b3bcbfe38b9)), closes [#266](https://github.com/viamin/agent-harness/issues/266)

## [0.25.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.24.0...agent-harness/v0.25.0) (2026-06-26)


### Features

* **auth:** add refresh-token exchange API for Claude OAuth ([#269](https://github.com/viamin/agent-harness/issues/269)) ([076b1aa](https://github.com/viamin/agent-harness/commit/076b1aa91a3dcb58280d1c550bdc4329ce162a92)), closes [#265](https://github.com/viamin/agent-harness/issues/265)

## [0.24.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.23.0...agent-harness/v0.24.0) (2026-06-26)


### Features

* **auth:** parse native Claude claudeAiOauth credentials shape ([#268](https://github.com/viamin/agent-harness/issues/268)) ([178edae](https://github.com/viamin/agent-harness/commit/178edae21e175c4744b75a151acfc6df3b4b3c5d)), closes [#264](https://github.com/viamin/agent-harness/issues/264)

## [0.23.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.22.5...agent-harness/v0.23.0) (2026-06-15)


### Features

* Add runner model compatibility contracts for Codex and CLI-gated models ([#260](https://github.com/viamin/agent-harness/issues/260)) ([4c192a7](https://github.com/viamin/agent-harness/commit/4c192a72f323ecaaea96e87e8ead6634e33669c0))

## [0.22.5](https://github.com/viamin/agent-harness/compare/agent-harness/v0.22.4...agent-harness/v0.22.5) (2026-06-12)


### Bug Fixes

* remove hardcoded o4-mini model from codex smoke test ([#254](https://github.com/viamin/agent-harness/issues/254)) ([f088cf1](https://github.com/viamin/agent-harness/commit/f088cf1d10b15867c6ee39976658e3e0fe5e6ab3))

## [0.22.4](https://github.com/viamin/agent-harness/compare/agent-harness/v0.22.3...agent-harness/v0.22.4) (2026-06-12)


### Bug Fixes

* specify explicit model in codex smoke test overrides ([#251](https://github.com/viamin/agent-harness/issues/251)) ([0dcaf42](https://github.com/viamin/agent-harness/commit/0dcaf42c82b7b559f6bb38e7f6ee346f52fb5900))

## [0.22.3](https://github.com/viamin/agent-harness/compare/agent-harness/v0.22.2...agent-harness/v0.22.3) (2026-06-11)


### Bug Fixes

* supply tempfile path for --output-last-message in codex test_command_overrides ([#248](https://github.com/viamin/agent-harness/issues/248)) ([86c5621](https://github.com/viamin/agent-harness/commit/86c562183d5ff00ff8b14d93942ec752e543bb59)), closes [#246](https://github.com/viamin/agent-harness/issues/246)

## [0.22.2](https://github.com/viamin/agent-harness/compare/agent-harness/v0.22.1...agent-harness/v0.22.2) (2026-06-11)


### Bug Fixes

* apply test_command_overrides in Codex build_command for smoke tests ([#243](https://github.com/viamin/agent-harness/issues/243)) ([7810fad](https://github.com/viamin/agent-harness/commit/7810fadd2e81db442294999fce3f504f16239dab))

## [0.22.1](https://github.com/viamin/agent-harness/compare/agent-harness/v0.22.0...agent-harness/v0.22.1) (2026-06-10)


### Bug Fixes

* Rate-limit reset parser fabricates far-future resets (year over-bump in parse_resets_date_time) ([6c7a34e](https://github.com/viamin/agent-harness/commit/6c7a34e7fb6b7b3080707e752e778423d6c26238))

## [0.22.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.21.0...agent-harness/v0.22.0) (2026-06-10)


### Features

* automated dependency updates for installable agents with cooldown period ([#239](https://github.com/viamin/agent-harness/issues/239)) ([0682cc0](https://github.com/viamin/agent-harness/commit/0682cc0d40264f5b5431fc0a7ab0c0d76416ec64))

## [0.21.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.20.1...agent-harness/v0.21.0) (2026-06-09)


### Features

* Anthropic#build_command ignores provider_runtime.model for CLI execution plans ([025ff6e](https://github.com/viamin/agent-harness/commit/025ff6e0a0a1ae8bea3a607873460af7d9838d54))

## [0.20.1](https://github.com/viamin/agent-harness/compare/agent-harness/v0.20.0...agent-harness/v0.20.1) (2026-06-09)


### Bug Fixes

* **anthropic:** --mcp-config space-form swallows the positional prompt (variadic flag) ([e52d38f](https://github.com/viamin/agent-harness/commit/e52d38fe97cdcc093860f4fda1de9e10c08f54c7))
* **anthropic:** use equals form for mcp config ([481d734](https://github.com/viamin/agent-harness/commit/481d734e389e66056bfc82d4dfeb31ba76ba1128))

## [0.20.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.19.0...agent-harness/v0.20.0) (2026-05-30)


### Features

* suppress Claude CLI .mcp.json auto-discovery when no MCP servers configured ([e07a25e](https://github.com/viamin/agent-harness/commit/e07a25e463becfd77da97058cb0a760eaec0920b))

## [0.19.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.18.2...agent-harness/v0.19.0) (2026-05-29)


### Features

* opencode-ai install contract should support postinstall (native binary download) ([b3eed97](https://github.com/viamin/agent-harness/commit/b3eed971b9bc46ce2bb2976b70dfd65b15ae5e9b))
* **opencode:** add requires_postinstall and postinstall_command to install contract ([d6808fd](https://github.com/viamin/agent-harness/commit/d6808fd62476289b199202b0c20c65fc4966bfcc)), closes [#223](https://github.com/viamin/agent-harness/issues/223)

## [0.18.2](https://github.com/viamin/agent-harness/compare/agent-harness/v0.18.1...agent-harness/v0.18.2) (2026-05-17)


### Bug Fixes

* **release:** require conventional PR titles for release-please ([4f0054f](https://github.com/viamin/agent-harness/commit/4f0054f4c9f35251c3185fa8bbf645fcace130b5))
* **release:** require conventional PR titles for release-please ([fd6633d](https://github.com/viamin/agent-harness/commit/fd6633dff3710ad1575af9bd172f047a93a8f647))

## [0.18.1](https://github.com/viamin/agent-harness/compare/agent-harness/v0.18.0...agent-harness/v0.18.1) (2026-05-12)


### Bug Fixes

* --disallowedTools varargs consumes prompt argument on Claude CLI v2.1.92+ ([e64bd62](https://github.com/viamin/agent-harness/commit/e64bd626ebdd19944920cbe43bcf8135069d0aec))
* use comma-separated --disallowedTools= syntax to prevent varargs consuming prompt ([9a97717](https://github.com/viamin/agent-harness/commit/9a97717fd002616465ff0e0b7733aa5391ceb1cb)), closes [#212](https://github.com/viamin/agent-harness/issues/212)

## [0.18.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.17.3...agent-harness/v0.18.0) (2026-05-06)


### Features

* **copilot:** add GitHub Copilot CLI (`copilot`) support with --autopilot mode ([#210](https://github.com/viamin/agent-harness/issues/210)) ([0138f3c](https://github.com/viamin/agent-harness/commit/0138f3c9f91e5e871383b771c287495217f084d8))

## [0.17.3](https://github.com/viamin/agent-harness/compare/agent-harness/v0.17.2...agent-harness/v0.17.3) (2026-05-06)


### Bug Fixes

* 161: Support provider-agnostic skills system ([#204](https://github.com/viamin/agent-harness/issues/204)) ([20a6ed5](https://github.com/viamin/agent-harness/commit/20a6ed5a8e6701ad7730d88b8037145d86b39c37))

## [0.17.2](https://github.com/viamin/agent-harness/compare/agent-harness/v0.17.1...agent-harness/v0.17.2) (2026-05-05)


### Bug Fixes

* 160: Add support for the pi agent CLI ([#203](https://github.com/viamin/agent-harness/issues/203)) ([0aeb607](https://github.com/viamin/agent-harness/commit/0aeb607ea98b52ba8202726dc946b8c1db09a3cd))

## [0.17.1](https://github.com/viamin/agent-harness/compare/agent-harness/v0.17.0...agent-harness/v0.17.1) (2026-05-05)


### Bug Fixes

* 173: Smoke test contract timeout (30s) overrides caller timeout, breaking slow models ([#205](https://github.com/viamin/agent-harness/issues/205)) ([3a1e301](https://github.com/viamin/agent-harness/commit/3a1e301e36ef8957fd440f2782b3b8e4687b473c))

## [0.17.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.16.1...agent-harness/v0.17.0) (2026-05-03)


### Features

* **extensions:** add activity heartbeat support for OpenCode/KiloCode-compatible providers ([#201](https://github.com/viamin/agent-harness/issues/201)) ([4914f6d](https://github.com/viamin/agent-harness/commit/4914f6d7971c55600f268b6886b967b753b25c96))

## [0.16.1](https://github.com/viamin/agent-harness/compare/agent-harness/v0.16.0...agent-harness/v0.16.1) (2026-05-03)


### Bug Fixes

* **kilocode:** config_file_content generates invalid JSON for kilo CLI v7.1.3 ([#190](https://github.com/viamin/agent-harness/issues/190)) ([0f7e24a](https://github.com/viamin/agent-harness/commit/0f7e24a8c342045d16a9332385e93f0607d0845e))

## [0.16.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.15.0...agent-harness/v0.16.0) (2026-05-03)


### Features

* Add plan-only / dry-run API returning command+env without execution ([#192](https://github.com/viamin/agent-harness/issues/192)) ([0e6a105](https://github.com/viamin/agent-harness/commit/0e6a1053515e0495900b67c5845a2f95c571f055))

## [0.15.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.14.1...agent-harness/v0.15.0) (2026-05-03)


### Features

* pre-flight connectivity check API for provider health verification ([#185](https://github.com/viamin/agent-harness/issues/185)) ([3ad6a2f](https://github.com/viamin/agent-harness/commit/3ad6a2ffbfe84b2271e4de968fa096276724e63c))

## [0.14.1](https://github.com/viamin/agent-harness/compare/agent-harness/v0.14.0...agent-harness/v0.14.1) (2026-05-03)


### Bug Fixes

* **kilocode:** test_command_overrides never wired into smoke test — kilo hangs without --auto ([#191](https://github.com/viamin/agent-harness/issues/191)) ([7c01d49](https://github.com/viamin/agent-harness/commit/7c01d49713cbedb6fb93758be95b7d92aa4599d3))

## [0.14.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.13.1...agent-harness/v0.14.0) (2026-05-03)


### Features

* expose public provider registry and config factory methods ([#193](https://github.com/viamin/agent-harness/issues/193)) ([11158ef](https://github.com/viamin/agent-harness/commit/11158efde6d77c885e7be1a03465d915efa0ee40)), closes [#175](https://github.com/viamin/agent-harness/issues/175)

## [0.13.1](https://github.com/viamin/agent-harness/compare/agent-harness/v0.13.0...agent-harness/v0.13.1) (2026-05-03)


### Bug Fixes

* Gem name (agent-harness) and require file (agent_harness) naming mismatch ([#189](https://github.com/viamin/agent-harness/issues/189)) ([4f19ba6](https://github.com/viamin/agent-harness/commit/4f19ba61d31a7815100fc602b73230b369770961))

## [0.13.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.12.0...agent-harness/v0.13.0) (2026-05-03)


### Features

* Expose public parse_container_output method on provider interface ([#187](https://github.com/viamin/agent-harness/issues/187)) ([ecdb7ba](https://github.com/viamin/agent-harness/commit/ecdb7bac56e47cf75e1379508cca64a9c7a0ffff))

## [0.12.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.11.3...agent-harness/v0.12.0) (2026-05-01)


### Features

* streaming JSONL event parser for real-time Codex progress tracking ([#184](https://github.com/viamin/agent-harness/issues/184)) ([4905539](https://github.com/viamin/agent-harness/commit/490553992904f39e52028b2140ab99755aad1fb1))

## [0.11.3](https://github.com/viamin/agent-harness/compare/agent-harness/v0.11.2...agent-harness/v0.11.3) (2026-04-28)


### Bug Fixes

* 164: Support provider-agnostic extensions across compatible providers ([#168](https://github.com/viamin/agent-harness/issues/168)) ([2880ae4](https://github.com/viamin/agent-harness/commit/2880ae4f150d1d5574f259b931bbee14ebe0ed04))

## [0.11.2](https://github.com/viamin/agent-harness/compare/agent-harness/v0.11.1...agent-harness/v0.11.2) (2026-04-27)


### Bug Fixes

* 162: Support provider-agnostic MCP configuration ([#165](https://github.com/viamin/agent-harness/issues/165)) ([27f4814](https://github.com/viamin/agent-harness/commit/27f48146e99d8fdba0346235a3e5f19138266652))

## [0.11.1](https://github.com/viamin/agent-harness/compare/agent-harness/v0.11.0...agent-harness/v0.11.1) (2026-04-26)


### Bug Fixes

* 163: Support provider-agnostic sub-agent definitions ([#166](https://github.com/viamin/agent-harness/issues/166)) ([1a00c35](https://github.com/viamin/agent-harness/commit/1a00c35f61c624b23f8d37b0d1b41e007d007ad3))

## [0.11.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.10.0...agent-harness/v0.11.0) (2026-04-25)


### Features

* add conversation manager for multi-turn chat ([#159](https://github.com/viamin/agent-harness/issues/159)) ([14f1d55](https://github.com/viamin/agent-harness/commit/14f1d551008c2d52a0aee7c2a7e2e0273f254578))
* add MCP HTTP transport support for servers ([#153](https://github.com/viamin/agent-harness/issues/153)) ([#155](https://github.com/viamin/agent-harness/issues/155)) ([8ea631a](https://github.com/viamin/agent-harness/commit/8ea631a3274ca4331ce42e8d63fc972cd48fbb12))
* add OpenAI-compatible chat transport ([#154](https://github.com/viamin/agent-harness/issues/154)) ([6005702](https://github.com/viamin/agent-harness/commit/60057029ba6eaaf81f65d42e487e6f0ca8cd159f))
* add provider chat capability with GitHub Models and Anthropic support ([#158](https://github.com/viamin/agent-harness/issues/158)) ([4188fa5](https://github.com/viamin/agent-harness/commit/4188fa542e6c4d330e5b230e54b1c1a5a55f4e8a))
* add structured streaming response observer for chat ([#157](https://github.com/viamin/agent-harness/issues/157)) ([225f4d9](https://github.com/viamin/agent-harness/commit/225f4d99b2b89d8eb030018236050672d3e47ba2))

## [0.10.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.9.0...agent-harness/v0.10.0) (2026-04-21)


### Features

* **codex:** expose JSONL transcript parser ([#148](https://github.com/viamin/agent-harness/issues/148)) ([05312ea](https://github.com/viamin/agent-harness/commit/05312eaf9c11fff50931e511ee6e534838eb8746))


### Bug Fixes

* **copilot:** github-copilot-cli does not support the -p flag used by build_command ([#141](https://github.com/viamin/agent-harness/issues/141)) ([d06fbc4](https://github.com/viamin/agent-harness/commit/d06fbc414489d6c3bc93a122d0eb2a5771ddbb26))

## [0.9.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.8.0...agent-harness/v0.9.0) (2026-04-19)


### Features

* **installers:** make Github Copilot CLI installation/version support a first-class provider contract ([#135](https://github.com/viamin/agent-harness/issues/135)) ([5120d44](https://github.com/viamin/agent-harness/commit/5120d44cf8405d0f7ef5fbb036f6d44ffdb701f6))


### Dependencies

* **deps:** bump rake from 13.3.1 to 13.4.2 in the minor-updates group ([f9189f1](https://github.com/viamin/agent-harness/commit/f9189f1d78cd2348fb792d22156ecce6cefdd3a8))

## [0.8.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.7.4...agent-harness/v0.8.0) (2026-04-19)


### Features

* **providers:** add config_file_content, notify_hook_content, and auth_lock_config ([#131](https://github.com/viamin/agent-harness/issues/131)) ([e95117e](https://github.com/viamin/agent-harness/commit/e95117e8000002972ca0fb31cb90dec035aa88fd))
* **providers:** add env var name mappings to provider classes ([#122](https://github.com/viamin/agent-harness/issues/122)) ([#133](https://github.com/viamin/agent-harness/issues/133)) ([6be9015](https://github.com/viamin/agent-harness/commit/6be901592afb02337eb2a5269f08e3025c7511c1))
* **providers:** add error_classification_patterns, noisy_error_patterns, and translate_error to provider classes ([#128](https://github.com/viamin/agent-harness/issues/128)) ([e2dfbed](https://github.com/viamin/agent-harness/commit/e2dfbed064fa26b2cae5691e6586e79900d19d28))
* **providers:** add parse_rate_limit_reset to provider base class ([#134](https://github.com/viamin/agent-harness/issues/134)) ([c16a6f8](https://github.com/viamin/agent-harness/commit/c16a6f8de312e137e5c3431f32d42b8c65126e0e))
* **providers:** add test_command_overrides and parse_test_error methods ([#129](https://github.com/viamin/agent-harness/issues/129)) ([a18102d](https://github.com/viamin/agent-harness/commit/a18102d1ee333a1db37f711c65e16dc20d4a0a11)), closes [#125](https://github.com/viamin/agent-harness/issues/125)
* **providers:** add token_usage_from_api_response to provider classes ([#130](https://github.com/viamin/agent-harness/issues/130)) ([f2c095d](https://github.com/viamin/agent-harness/commit/f2c095dcc0ae0d7822da90f98704597f08e4ed04)), closes [#126](https://github.com/viamin/agent-harness/issues/126)

## [0.7.4](https://github.com/viamin/agent-harness/compare/agent-harness/v0.7.3...agent-harness/v0.7.4) (2026-04-18)


### Bug Fixes

* 119: Claude provider leaks raw --output-format json envelope as response.output ([#120](https://github.com/viamin/agent-harness/issues/120)) ([602a5f9](https://github.com/viamin/agent-harness/commit/602a5f97e009ac59c798c7b1d7342cd43e2e8d4f))

## [0.7.3](https://github.com/viamin/agent-harness/compare/agent-harness/v0.7.2...agent-harness/v0.7.3) (2026-04-15)


### Bug Fixes

* 114: feat: add text-only transport that bypasses the CLI ([a6be68a](https://github.com/viamin/agent-harness/commit/a6be68aa03b0202492caeb24233104cd1b814d88))
* 98: feat: add token usage extraction for remaining providers (cursor, gemini, aider, opencode, copilot, mistral_vibe) ([#105](https://github.com/viamin/agent-harness/issues/105)) ([b090748](https://github.com/viamin/agent-harness/commit/b090748b5d528ab864e94754c0992bc060669540))

## [0.7.2](https://github.com/viamin/agent-harness/compare/agent-harness/v0.7.1...agent-harness/v0.7.2) (2026-04-15)


### Bug Fixes

* 113: [P1] feat: support disabling tools for text-only send_message calls ([#115](https://github.com/viamin/agent-harness/issues/115)) ([62bc66a](https://github.com/viamin/agent-harness/commit/62bc66a3d34a889de65ba7c4951b8bdb1f388fa9))

## [0.7.1](https://github.com/viamin/agent-harness/compare/agent-harness/v0.7.0...agent-harness/v0.7.1) (2026-04-15)


### Bug Fixes

* **codex:** address remaining json output review feedback ([505e068](https://github.com/viamin/agent-harness/commit/505e068d63fbc5590112ba00faee0d1c62d997e3))
* **codex:** address review feedback for token usage extraction ([398940e](https://github.com/viamin/agent-harness/commit/398940ecb356ec9e6978d42244ae26295823bb89))
* **codex:** preserve output-last-message flag values ([7480778](https://github.com/viamin/agent-harness/commit/7480778d6a5d7b9227eec20889bc642eb399d1b5))

## [0.7.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.6.0...agent-harness/v0.7.0) (2026-04-13)


### Features

* **copilot:** add JSON output parsing and token extraction ([4f5fc5a](https://github.com/viamin/agent-harness/commit/4f5fc5acd8d45ac8563998a132a0c4878f3b9e0a))
* **kilocode:** extract token usage from Kilo CLI structured JSON output ([b5384f8](https://github.com/viamin/agent-harness/commit/b5384f8be52431f95d8aa3524a33ceed6bf094eb)), closes [#97](https://github.com/viamin/agent-harness/issues/97)


### Bug Fixes

* **copilot:** add nil guard for stdout and improve error string construction ([6a30ce3](https://github.com/viamin/agent-harness/commit/6a30ce342100b27c0b16fc8c2abdce48bbf10ef7))
* **copilot:** align error ordering with base parser ([0a02d34](https://github.com/viamin/agent-harness/commit/0a02d34cbf07e4f4ecb4d3efc6d69b5b072c6114))
* **copilot:** align metadata and reply parsing ([e5c3387](https://github.com/viamin/agent-harness/commit/e5c338743dbb5ec8eea5b1a8de5a515f1df7e141))
* **copilot:** avoid double-counting token aliases ([40e78f3](https://github.com/viamin/agent-harness/commit/40e78f34a6304a5ae21e26c6c291eed773618bea))
* **copilot:** avoid mixing shutdown token totals ([c4bdfb8](https://github.com/viamin/agent-harness/commit/c4bdfb8fd4c20781ef4621cf421947b14514cb45))
* **copilot:** drop superseded delta chunks ([769acd6](https://github.com/viamin/agent-harness/commit/769acd6a45f1037f11fc83ea23f5ddeda9aadd17))
* **copilot:** fall back across malformed token aliases ([9c9f5f8](https://github.com/viamin/agent-harness/commit/9c9f5f8048f63407b6ffc14fb339c26158f74dab))
* **copilot:** fall back from empty nested message content ([ecd9f49](https://github.com/viamin/agent-harness/commit/ecd9f497e0ef9812f2df363b02679b5842cf668c))
* **copilot:** fall back from empty shutdown metrics ([0397f1e](https://github.com/viamin/agent-harness/commit/0397f1e5f9442d0d6489c9fe7744d31a0ff48965))
* **copilot:** fall back from malformed nested message content ([a313487](https://github.com/viamin/agent-harness/commit/a313487f2c1bb9fbf5e7a60e5dc08e7a7079447c))
* **copilot:** fall back from malformed usage payloads ([733599c](https://github.com/viamin/agent-harness/commit/733599c599cda90873cec823c245b13c81f74ee6))
* **copilot:** gate json output by cli version ([528d03b](https://github.com/viamin/agent-harness/commit/528d03bed7506996cf9cfd6c4cf54807da254260))
* **copilot:** guard scalar json events ([13a4131](https://github.com/viamin/agent-harness/commit/13a413157cc159cfc4fd6b7e7ab7fdbb948d07b6))
* **copilot:** handle JSON event envelopes and camelCase token fields ([e0ee83e](https://github.com/viamin/agent-harness/commit/e0ee83ed73d715d9c67806b5253abab33cce9e19))
* **copilot:** hash unresolved probe path keys ([ea9aca2](https://github.com/viamin/agent-harness/commit/ea9aca215b000833be18bf035cba6c0bf029615d))
* **copilot:** hide structured control events from output ([81c108d](https://github.com/viamin/agent-harness/commit/81c108d521e8f72522dc1dc604cccdf46f0d01d4))
* **copilot:** ignore delta chunks after final reply ([6aef1ca](https://github.com/viamin/agent-harness/commit/6aef1ca4459a5588fc53b70692f95c6eff3b9d88))
* **copilot:** ignore empty delta chunks ([dca6395](https://github.com/viamin/agent-harness/commit/dca63951866a4dc65b2adca3b834d05a6716f298))
* **copilot:** ignore failed version probes ([fa6ba35](https://github.com/viamin/agent-harness/commit/fa6ba35e1e36f153f47bccf9c423cea7927176e7))
* **copilot:** ignore malformed delta content fallback ([0c9211b](https://github.com/viamin/agent-harness/commit/0c9211bb16e713f4b7185c1b9ccda5d065b9d405))
* **copilot:** ignore malformed token payloads ([0f2f06b](https://github.com/viamin/agent-harness/commit/0f2f06b9a8c0b4244c7b8040e5590cc6e4710143))
* **copilot:** ignore malformed typed json fallbacks ([0cd5535](https://github.com/viamin/agent-harness/commit/0cd553594aff277ce07abd3d151028ad22b3f597))
* **copilot:** ignore nested non-assistant fallback text ([799f976](https://github.com/viamin/agent-harness/commit/799f976ef19618acaae1a6e0ecf7faa76b9ff37f))
* **copilot:** ignore non-assistant top-level messages ([119c854](https://github.com/viamin/agent-harness/commit/119c8540e7db9f1827eac75e73403b638cf8db23))
* **copilot:** ignore non-assistant top-level token payloads ([23c05b9](https://github.com/viamin/agent-harness/commit/23c05b9dbc6231755783f4a8eefd5099067f9389))
* **copilot:** ignore partial invalid token aliases ([3344c07](https://github.com/viamin/agent-harness/commit/3344c078d291277b8831ab69fa5d2a40ca95135b))
* **copilot:** isolate probe cache for PATH overrides ([5fa79a9](https://github.com/viamin/agent-harness/commit/5fa79a91fd90dd33a15d5c6a0c25c2619b8f0ac3))
* **copilot:** keep delta output on empty final reply ([64fbf68](https://github.com/viamin/agent-harness/commit/64fbf68ffb66b58d7546bc1841c78fec86201acb))
* **copilot:** keep preflight errors inside base handler ([49c9075](https://github.com/viamin/agent-harness/commit/49c9075d4a1fb9ff42d633723cb5f375e8c2721c))
* **copilot:** merge partial shutdown token totals ([49d6b2b](https://github.com/viamin/agent-harness/commit/49d6b2b6727297a58e9aa265347c781405012aa0))
* **copilot:** merge top-level token fallbacks ([826c1f9](https://github.com/viamin/agent-harness/commit/826c1f9fd427b10c40fb34c5b47f4c9fb06f1e64))
* **copilot:** parse session shutdown token totals ([0148afd](https://github.com/viamin/agent-harness/commit/0148afd2f95312eae687799541545dd8ece185f3))
* **copilot:** parse streamed delta reply events ([55f553f](https://github.com/viamin/agent-harness/commit/55f553f39dbe729588641b86168f8c36500ec872))
* **copilot:** prefer final replies and trim probe cache keys ([38dc20e](https://github.com/viamin/agent-harness/commit/38dc20edac2326265c8f9d149394650b70c43e90))
* **copilot:** prefer final reply over delta chunks ([955654d](https://github.com/viamin/agent-harness/commit/955654db325cc47c8cf0ac992de55e574a45c641))
* **copilot:** prefer nested assistant message fallback ([15aa6db](https://github.com/viamin/agent-harness/commit/15aa6dbf4bb171eaaa5b85c552008953141ba622))
* **copilot:** prefer per-turn usage over shutdown totals ([38bd47c](https://github.com/viamin/agent-harness/commit/38bd47c00e5d74ef365a74dc61df9e2fdc5b9c04))
* **copilot:** prefer populated top-level usage payloads ([8b3aac0](https://github.com/viamin/agent-harness/commit/8b3aac029004f65efe26e8b3fc27f62ac2008dca))
* **copilot:** preserve blank mixed output lines ([e9830fc](https://github.com/viamin/agent-harness/commit/e9830fcfcceeb7fc67caac658ed16867e1f303d0))
* **copilot:** preserve empty nested message payloads ([edf27bc](https://github.com/viamin/agent-harness/commit/edf27bcafbfb29dc0f5baf54fcedb8e959e20bba))
* **copilot:** preserve empty top-level fallback payloads ([1863854](https://github.com/viamin/agent-harness/commit/1863854af8545573a6c9a80cc47297487ee6d2ac))
* **copilot:** preserve legitimate exit codes in responses ([d1a3cc0](https://github.com/viamin/agent-harness/commit/d1a3cc0f21ea1a45fee0dbf181462efc8b414fc8))
* **copilot:** preserve literal json stdout ([7d7862c](https://github.com/viamin/agent-harness/commit/7d7862c4da83ccf9bafbbca19b595911923edeed))
* **copilot:** preserve malformed top-level json output ([f7c5bec](https://github.com/viamin/agent-harness/commit/f7c5becaa01584c53f1327be0afbd2fcebe7f3e8))
* **copilot:** preserve malformed usage hashes ([0eef69b](https://github.com/viamin/agent-harness/commit/0eef69b470927412c405a774125ca0aa9a58e302))
* **copilot:** preserve mixed json and text output ([95de0f7](https://github.com/viamin/agent-harness/commit/95de0f72a2bd8a86d33ab0806fb1baf481e52d03))
* **copilot:** preserve mixed output line boundaries ([b285526](https://github.com/viamin/agent-harness/commit/b28552627192aa613c73c7bf2c8c8afed6811c36))
* **copilot:** preserve mixed plain-text output ([d277f3a](https://github.com/viamin/agent-harness/commit/d277f3a4ed2799182a2083989a0bdaf9960df16b))
* **copilot:** preserve non-event typed json output ([27d01c6](https://github.com/viamin/agent-harness/commit/27d01c649cab65ba2da206636f45170af5abbcc9))
* **copilot:** preserve scalar json stdout ([7c5e74c](https://github.com/viamin/agent-harness/commit/7c5e74cd9aed9de17f572b98faac9c09b8cd9707))
* **copilot:** preserve unknown typed json output ([942edac](https://github.com/viamin/agent-harness/commit/942edac7bc36d9e26a7c02945f15503ce7faeb73))
* **copilot:** preserve zero token aliases ([853d251](https://github.com/viamin/agent-harness/commit/853d251869adb3cc36bebc5b6d750a58c70843f7))
* **copilot:** probe json support per request env ([da94082](https://github.com/viamin/agent-harness/commit/da94082a79a044eb89b470b26eeda29196e7ac95))
* **copilot:** reject invalid token counts ([106c386](https://github.com/viamin/agent-harness/commit/106c3867d024751e77aa0fc215c651de87230a13))
* **copilot:** restore reply token fallback ([c9d7182](https://github.com/viamin/agent-harness/commit/c9d71820b0becc80e44a77169c2990be20469be2))
* **copilot:** restrict token accumulation to usage event types only ([80c979b](https://github.com/viamin/agent-harness/commit/80c979b9952defa05923920a737bb74e1c8885e4))
* **copilot:** skip blank assistant boundaries ([b9dec9a](https://github.com/viamin/agent-harness/commit/b9dec9af0c6084e1809dc1fb1c50535b987037a1))
* **copilot:** skip json parsing in legacy mode ([af9ac12](https://github.com/viamin/agent-harness/commit/af9ac1253aa4246c92727bc04f23d6704ec8926e))
* **copilot:** store probe env per thread ([301f2aa](https://github.com/viamin/agent-harness/commit/301f2aa4c43b183dea8450d21eb7fec799e92ec6))
* **copilot:** stub json support in parser specs ([96a945e](https://github.com/viamin/agent-harness/commit/96a945ec1572e10231b696008c7514d1acb92c11))
* **copilot:** sum reply token fallback ([82c5097](https://github.com/viamin/agent-harness/commit/82c5097b73f17e64cd3015c34aa92bfd713c0428))
* **copilot:** support snake_case delta chunks ([d33ecbc](https://github.com/viamin/agent-harness/commit/d33ecbcc446d895d35f03a7513ad7b16f0f57b1d))
* **copilot:** support snake_case shutdown metrics ([8c6e93e](https://github.com/viamin/agent-harness/commit/8c6e93e70e0927c95c63811b247291faaceacab0))
* **copilot:** suppress additional control events ([b14b8bb](https://github.com/viamin/agent-harness/commit/b14b8bbebb2fcc0c975788c1168965bee3281a79))
* **copilot:** suppress control event namespaces ([7b31bb2](https://github.com/viamin/agent-harness/commit/7b31bb293fb858808e493a23e268d89a590741a0))
* **copilot:** suppress root control events ([5d4d3ec](https://github.com/viamin/agent-harness/commit/5d4d3ecb80864ad4d20e0da1083ac02d90773fbf))
* **copilot:** update output_format metadata and add missing parse_response tests ([7fdedde](https://github.com/viamin/agent-harness/commit/7fdeddee3bbe5eca96f29f5613a5c36189695ec4))
* **kilocode:** aggregate token counts across multiple step_finish events ([23c8c55](https://github.com/viamin/agent-harness/commit/23c8c55def0452de1e0b25765c4f6d1fcd3474d4))
* **kilocode:** avoid raw ndjson in structured failures ([932e56e](https://github.com/viamin/agent-harness/commit/932e56e06567095750a7bcf15bf5adea065eab44))
* **kilocode:** clear stale extra usage categories ([2ff7079](https://github.com/viamin/agent-harness/commit/2ff70795a9e3397d5844de92c47a59b49a599426))
* **kilocode:** count extra result usage tokens ([f65dd3d](https://github.com/viamin/agent-harness/commit/f65dd3d8e4f54174b18233ddd55dba2d3c3fd1f3))
* **kilocode:** count reasoning and cache step tokens ([c46d089](https://github.com/viamin/agent-harness/commit/c46d089d4d0492534d98736dcdcb1ff82a67d0c1))
* **kilocode:** fail on structured error events ([48f5378](https://github.com/viamin/agent-harness/commit/48f5378f37cf64af28238c67314a01a3758aab05))
* **kilocode:** fall back to result text after blank chunks ([7508c58](https://github.com/viamin/agent-harness/commit/7508c58a84f365a680578891dd582a6f13484f1e))
* **kilocode:** fall back to step token totals when usage is incomplete ([8534691](https://github.com/viamin/agent-harness/commit/8534691ff74ba4efa1ae5d50de329bc53e863bcf))
* **kilocode:** fall through blank part message aliases ([85db058](https://github.com/viamin/agent-harness/commit/85db05824684cde93755c4d87323bce79e0a1dd7))
* **kilocode:** fall through blank part text chunks ([417a4c8](https://github.com/viamin/agent-harness/commit/417a4c8005f23c28f5a68a834890614ca49c5dca))
* **kilocode:** fall through blank text aliases ([63ed6a1](https://github.com/viamin/agent-harness/commit/63ed6a1bb002329ab823a8844e0ac81ef065938b))
* **kilocode:** guard malformed structured output payloads ([30a59a2](https://github.com/viamin/agent-harness/commit/30a59a21d3b4012cec4dbfa27b5471b9dee329bd))
* **kilocode:** guard scalar structured error payloads ([26843a9](https://github.com/viamin/agent-harness/commit/26843a90019d3f29f15eb363d098f0bba0f00582))
* **kilocode:** guard step_finish part.tokens against non-Hash values ([ff2d841](https://github.com/viamin/agent-harness/commit/ff2d8414eb928bd679d9754a71d0849963298a4b))
* **kilocode:** honor explicit usage totals ([d1e5275](https://github.com/viamin/agent-harness/commit/d1e5275f3515ae40db4b523e0efe2ce8a3d169a1))
* **kilocode:** honor later explicit total alias updates ([496df42](https://github.com/viamin/agent-harness/commit/496df425a8a5e76e97134dea8b1f74a0067aad1b))
* **kilocode:** honor synthesized result usage totals ([b0779a7](https://github.com/viamin/agent-harness/commit/b0779a78400c1a3b6aa38610582c5cf96446b28e))
* **kilocode:** honor valid total fallback aliases ([d0ae122](https://github.com/viamin/agent-harness/commit/d0ae12245be3e606d0919bf78dcc858525c64036))
* **kilocode:** ignore blank terminal result strings ([ebb34b6](https://github.com/viamin/agent-harness/commit/ebb34b663c7c0a933aedc17efba444263a891b80))
* **kilocode:** ignore negative token counts ([aee8d1e](https://github.com/viamin/agent-harness/commit/aee8d1e35e438ae25bf3a37571d273d891b89b24))
* **kilocode:** ignore non-string text payloads ([4a35a6f](https://github.com/viamin/agent-harness/commit/4a35a6fb1555923b3d1555bc895051bbaa7db26c))
* **kilocode:** ignore scalar json fallback noise ([1f62463](https://github.com/viamin/agent-harness/commit/1f624631477557ae533d605ecf37a5fb40c39544))
* **kilocode:** ignore usage on non-usage events ([b23ac10](https://github.com/viamin/agent-harness/commit/b23ac10c0d4107e05a50a2dc83204c0088bddbbb))
* **kilocode:** ignore whitespace-only text alias placeholders ([62bb641](https://github.com/viamin/agent-harness/commit/62bb641a7b7ac5434b2e905c6b297b2abf989020))
* **kilocode:** ignore whitespace-only text chunks ([699cccc](https://github.com/viamin/agent-harness/commit/699cccc1025b83a3850b7ed2670ff60de39e6adf))
* **kilocode:** keep last usable structured usage payload ([1b9d9bd](https://github.com/viamin/agent-harness/commit/1b9d9bd7ebbaa0ae9ed6dd7379f9b8c67de19025))
* **kilocode:** keep stdout diagnostics with structured errors ([76446fc](https://github.com/viamin/agent-harness/commit/76446fc8a95c89c9944b47db794ddb776e29686f))
* **kilocode:** merge partial structured usage events ([2de37e2](https://github.com/viamin/agent-harness/commit/2de37e246317650f60a0399c2f731f03ecf28ec9))
* **kilocode:** normalize malformed token counts ([ef4c3dc](https://github.com/viamin/agent-harness/commit/ef4c3dce783e71aae1b60c543da59f64b4efdb6c))
* **kilocode:** parse hash-shaped structured error aliases ([431f8c4](https://github.com/viamin/agent-harness/commit/431f8c438d7b13bf45d3416e947d3ad34b8b4eca))
* **kilocode:** parse NDJSON event stream instead of single JSON object ([4e1252f](https://github.com/viamin/agent-harness/commit/4e1252fc384c51d118b43647a7026281927b6794))
* **kilocode:** parse nested part error messages ([8d49794](https://github.com/viamin/agent-harness/commit/8d49794f79bbe553cfe8f569867508bb80a86805))
* **kilocode:** parse nested structured error messages ([b9fee6a](https://github.com/viamin/agent-harness/commit/b9fee6a8814045f0c5329bac23b0f0b424b17566))
* **kilocode:** parse token usage from step_finish.part.tokens ([bbf5a58](https://github.com/viamin/agent-harness/commit/bbf5a58fc6bc631a483a3e71bc0d8b99744e9f7b))
* **kilocode:** pass legitimate_exit_codes in Response metadata ([dac77c2](https://github.com/viamin/agent-harness/commit/dac77c24711bf717b7d98d847a21d3922889026b))
* **kilocode:** preserve base error stream ordering ([5281d78](https://github.com/viamin/agent-harness/commit/5281d7875c54cd010364b251069d921c4c5e4838))
* **kilocode:** preserve extra usage totals without io counts ([b4fb265](https://github.com/viamin/agent-harness/commit/b4fb2657aa56ad42e514a42dd0176742a48fdbc4))
* **kilocode:** preserve json array fallback output ([16cb566](https://github.com/viamin/agent-harness/commit/16cb5668e1442a9232ca5fcc38d0b196eb673956))
* **kilocode:** preserve mixed structured failure diagnostics ([5ec3be7](https://github.com/viamin/agent-harness/commit/5ec3be7ff143803c8e9602a1d76b6c7c4c0beb12))
* **kilocode:** preserve mixed structured success output ([ea64e2e](https://github.com/viamin/agent-harness/commit/ea64e2ea7154c15193ce35c115874bb898dcdc84))
* **kilocode:** preserve provider token totals ([b62d749](https://github.com/viamin/agent-harness/commit/b62d7499070aa5233c56b7207b6a2aede97a7dfc))
* **kilocode:** preserve raw mixed stdout spacing ([881c51e](https://github.com/viamin/agent-harness/commit/881c51e9a88705e0d8e28e06cb7fd7381f55feed))
* **kilocode:** preserve raw output for non-event json ([ce9be0f](https://github.com/viamin/agent-harness/commit/ce9be0f5f8d807dda995202fbe2dc26cddee32b2))
* **kilocode:** preserve step extras with partial usage ([14eeddb](https://github.com/viamin/agent-harness/commit/14eeddb6ec9e056c8b20ee9251e42a26de260079))
* **kilocode:** preserve step token totals for partial usage ([5efe2f4](https://github.com/viamin/agent-harness/commit/5efe2f4d3804f52cfae1b6ee63da87d3459a8c0f))
* **kilocode:** preserve terminal result payload spacing ([977faa7](https://github.com/viamin/agent-harness/commit/977faa7eed454c6070503589cc995f3021d19476))
* **kilocode:** preserve terminal result text ([282ae35](https://github.com/viamin/agent-harness/commit/282ae35051b715f0210534f31adb87152c75b6b7))
* **kilocode:** preserve terminal result text across result events ([5652453](https://github.com/viamin/agent-harness/commit/56524531434d9d7c71f7af3acd17d25dbf9656ca))
* **kilocode:** preserve unreconstructable step totals ([a906ee9](https://github.com/viamin/agent-harness/commit/a906ee951d6dfa5aa74e149f2e41fa214ffad2cf))
* **kilocode:** preserve unreconstructable totals with result extras ([7585e29](https://github.com/viamin/agent-harness/commit/7585e29d0eb6668f48b6db3ab033272b74d4831f))
* **kilocode:** preserve whitespace in text alias chunks ([a6592c1](https://github.com/viamin/agent-harness/commit/a6592c12e753a91cdd8f6c0041100c2a0c01d89a))
* **kilocode:** read terminal result text from hash payloads ([2ac7012](https://github.com/viamin/agent-harness/commit/2ac701278133e2f0fee64a7cb33f854ecff0754b))
* **kilocode:** recompute totals from updated usage ([aafabfd](https://github.com/viamin/agent-harness/commit/aafabfd972c56e35bcaa36eb92b1658cb6579a6c))
* **kilocode:** reject fractional token counts ([935a41d](https://github.com/viamin/agent-harness/commit/935a41d327f7d9433368db40da93ab1983e14cbc))
* **kilocode:** reject non-decimal string token counts ([0be6ddf](https://github.com/viamin/agent-harness/commit/0be6ddf31a306face9b61498d1a77d08a94a02a5))
* **kilocode:** remove stray binstubs and add missing test coverage ([25287f7](https://github.com/viamin/agent-harness/commit/25287f736c8bd81820553fc5ca2517e1c64f261c))
* **kilocode:** replace stale partial extra usage fields ([4b89027](https://github.com/viamin/agent-harness/commit/4b8902768620ffb5787e194753b14f6eb7c496d7))
* **kilocode:** skip scalar JSON lines before reading event fields ([b8fce27](https://github.com/viamin/agent-harness/commit/b8fce27bceb998a6a4b2a3de7ed95f96a2794c3d))
* **kilocode:** support hash-shaped part text aliases ([778e25c](https://github.com/viamin/agent-harness/commit/778e25c62cf32bafd1c0fb4bae32b2ea13cf1df9))
* **kilocode:** support nested result message aliases ([e8a5988](https://github.com/viamin/agent-harness/commit/e8a5988e34dfb1afd70eccb551985fa7e273192e))
* **kilocode:** support result text aliases ([63ccff9](https://github.com/viamin/agent-harness/commit/63ccff9be0c32ffcfd04e3745a441d6d2370eeac))
* **kilocode:** support scalar part structured errors ([2dd4740](https://github.com/viamin/agent-harness/commit/2dd47408f39340b075815ce64ac02c588fc445de))
* **kilocode:** support scalar text part payloads ([b9e9013](https://github.com/viamin/agent-harness/commit/b9e90137e6b43fb2eb789857da319221203a7f76))
* **kilocode:** support text event alias payloads ([4c425ff](https://github.com/viamin/agent-harness/commit/4c425fff93dcd872e2640743cb21da9668f952b7))
* **kilocode:** support top-level result text aliases ([9ce7c02](https://github.com/viamin/agent-harness/commit/9ce7c0249acaf3b44731271fc8b50d8fbb14cedc))
* **kilocode:** support top-level structured error text ([cad1d31](https://github.com/viamin/agent-harness/commit/cad1d31007d79b75daecb61b4f1ed8573f9e70a0))
* **kilocode:** suppress raw ndjson output for structured events ([d7a07d7](https://github.com/viamin/agent-harness/commit/d7a07d70812b40a75f6a09924d1fd609e99a61df))
* **kilocode:** treat missing usage tokens as unknown ([5e6335f](https://github.com/viamin/agent-harness/commit/5e6335f901e8f197de9c8f4df5727f90fc06ee43))
* **kilocode:** whitelist structured event types ([d6d8a7d](https://github.com/viamin/agent-harness/commit/d6d8a7d5bf6268050bf2083494360debeec80fab))


### Improvements

* **kilocode:** remove unreachable structured error branch ([3d7ec3d](https://github.com/viamin/agent-harness/commit/3d7ec3d94e7be6b6f2c2c92d0daf0ce0590c4067))

## [0.6.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.5.9...agent-harness/v0.6.0) (2026-04-12)


### Features

* **aider:** extract token usage via --llm-history-file ([0fff343](https://github.com/viamin/agent-harness/commit/0fff343f943d93899d0222b16ffa9832611289ff)), closes [#100](https://github.com/viamin/agent-harness/issues/100)

## [0.5.9](https://github.com/viamin/agent-harness/compare/agent-harness/v0.5.8...agent-harness/v0.5.9) (2026-04-12)


### Bug Fixes

* 91: audit and fix-forward defects from PRs merged before review completion ([ec0af12](https://github.com/viamin/agent-harness/commit/ec0af12728f6524b651ebc9b552c477059a2adac))
* **providers:** close path traversal bypass in env-var-prefixed preparation paths ([493bf55](https://github.com/viamin/agent-harness/commit/493bf55be088a8bde39d143791f3f9b0c90d9c0c))
* **providers:** harden preparation path validation against env value traversal and command substitution ([ed4b92b](https://github.com/viamin/agent-harness/commit/ed4b92b8760ec4dfa1f50d69b0736563140905b4))
* **providers:** harden preparation path validation against injection and traversal ([9cb0faf](https://github.com/viamin/agent-harness/commit/9cb0fafbf63c908c7ef7b465bf541ceb5dbf58bb))
* **providers:** preserve docker idle timeouts ([adde6b4](https://github.com/viamin/agent-harness/commit/adde6b4491023c8baf37249147770cddeff1b0ee))

## [0.5.8](https://github.com/viamin/agent-harness/compare/agent-harness/v0.5.7...agent-harness/v0.5.8) (2026-04-07)


### Bug Fixes

* 64: feat(installers): make Claude CLI installation/version support a first-class provider contract ([#78](https://github.com/viamin/agent-harness/issues/78)) ([0d83590](https://github.com/viamin/agent-harness/commit/0d83590dc9bb9bc7c8d621660bcd73b8eb613d43))
* 70: feat(installers): make Cursor agent CLI installation/version support a first-class provider contract ([#82](https://github.com/viamin/agent-harness/issues/82)) ([483e9be](https://github.com/viamin/agent-harness/commit/483e9be752de9548020135a86170d978d2a23ae8))
* 71: feat(installers): make Aider CLI installation/version support a first-class provider contract ([#84](https://github.com/viamin/agent-harness/issues/84)) ([3cfcc1c](https://github.com/viamin/agent-harness/commit/3cfcc1cac831060c12fd8a39130ee7bb9b048aa5))
* 74: feat(providers): expose provider capability/installability/auth metadata for downstream apps ([#88](https://github.com/viamin/agent-harness/issues/88)) ([4f9b3ba](https://github.com/viamin/agent-harness/commit/4f9b3ba6a53c830eaf53e9233e8df38970c52c8c))

## [0.5.7](https://github.com/viamin/agent-harness/compare/agent-harness/v0.5.6...agent-harness/v0.5.7) (2026-04-07)


### Bug Fixes

* 59: fix(codex): replace invalid '--sandbox none' for externally sandboxed runs ([#89](https://github.com/viamin/agent-harness/issues/89)) ([6b0fac5](https://github.com/viamin/agent-harness/commit/6b0fac5e9b83c70c3a55004d9c5ad354a6d3dced))
* 60: feat: support per-request executor overrides for orchestrated send_message ([#87](https://github.com/viamin/agent-harness/issues/87)) ([7711770](https://github.com/viamin/agent-harness/commit/7711770ab3c9a6659171df1033038acf08b8d5a9))
* 61: feat: support idle-timeout and streaming execution hooks for long-running provider runs ([#90](https://github.com/viamin/agent-harness/issues/90)) ([adf7558](https://github.com/viamin/agent-harness/commit/adf75583994f78af9d6f5b44eba729b616b46f02))
* 62: feat: support per-request environment unsets for provider execution ([#76](https://github.com/viamin/agent-harness/issues/76)) ([2dfdb8e](https://github.com/viamin/agent-harness/commit/2dfdb8e6138f21ca0dd1a9e0b2d7cc17d1776612))
* 63: fix(copilot): align GithubCopilot provider with a real installable CLI contract ([#75](https://github.com/viamin/agent-harness/issues/75)) ([9e585e7](https://github.com/viamin/agent-harness/commit/9e585e79252ac8431fb99bc16bc9ebbecb83439e))
* 65: feat(installers): make Codex CLI installation/version support a first-class provider contract ([#79](https://github.com/viamin/agent-harness/issues/79)) ([a3f5849](https://github.com/viamin/agent-harness/commit/a3f5849db1bcfa162af98fa5339cf8b8f5314920))
* 66: feat(installers): make Gemini CLI installation/version support a first-class provider contract ([#80](https://github.com/viamin/agent-harness/issues/80)) ([e349ab6](https://github.com/viamin/agent-harness/commit/e349ab64601cb2fe9bafb488e6b4f96fbcbf012b))
* 67: feat(installers): make Kilocode CLI installation/version support a first-class provider contract ([#81](https://github.com/viamin/agent-harness/issues/81)) ([547baf5](https://github.com/viamin/agent-harness/commit/547baf5be93939a00cdac1e3d17824eb6dbfb324))
* 68: feat(installers): make OpenCode CLI installation/version support a first-class provider contract ([#83](https://github.com/viamin/agent-harness/issues/83)) ([21caaf4](https://github.com/viamin/agent-harness/commit/21caaf4e003c41a7fa127e7244c4a61abad7f1cb))
* 72: feat(providers): add first-class smoke-test/health-check execution contracts for CLI providers ([#85](https://github.com/viamin/agent-harness/issues/85)) ([7c0db3a](https://github.com/viamin/agent-harness/commit/7c0db3a5aa93e62e38240821dfb00b489ad3793b))

## [0.5.6](https://github.com/viamin/agent-harness/compare/agent-harness/v0.5.5...agent-harness/v0.5.6) (2026-03-30)


### Bug Fixes

* 53: Expose provider configuration capabilities for app-driven provider setup UIs ([#57](https://github.com/viamin/agent-harness/issues/57)) ([6aa6a02](https://github.com/viamin/agent-harness/commit/6aa6a02da14feefcad8761302d5fa8b5642a57fe))
* 54: Add per-request provider runtime overrides for CLI-backed providers ([#55](https://github.com/viamin/agent-harness/issues/55)) ([407467a](https://github.com/viamin/agent-harness/commit/407467a6965a01494e2c4590680b2bb9ddac6dce))

## [0.5.5](https://github.com/viamin/agent-harness/compare/agent-harness/v0.5.4...agent-harness/v0.5.5) (2026-03-29)


### Bug Fixes

* 47: Audit provider-specific execution semantics so downstream apps do not hardcode CLI quirks ([#50](https://github.com/viamin/agent-harness/issues/50)) ([2d9a972](https://github.com/viamin/agent-harness/commit/2d9a972a78273901535ae44998c32292899b82ec))
* 48: Handle Codex sandbox mode for externally sandboxed container execution ([#49](https://github.com/viamin/agent-harness/issues/49)) ([5b6ba3f](https://github.com/viamin/agent-harness/commit/5b6ba3f9f517bb027670ead384feddd2c0f99edb))

## [0.5.4](https://github.com/viamin/agent-harness/compare/agent-harness/v0.5.3...agent-harness/v0.5.4) (2026-03-27)


### Bug Fixes

* 44: feat(mcp): add first-class MCP server configuration to request execution ([#45](https://github.com/viamin/agent-harness/issues/45)) ([454cd9b](https://github.com/viamin/agent-harness/commit/454cd9be1c4bcd2eb92a4ca6f81cc012d4ce1f8c))

## [0.5.3](https://github.com/viamin/agent-harness/compare/agent-harness/v0.5.2...agent-harness/v0.5.3) (2026-03-27)


### Bug Fixes

* 41: Add provider-specific health/auth checks for Gemini and Codex ([#42](https://github.com/viamin/agent-harness/issues/42)) ([be95135](https://github.com/viamin/agent-harness/commit/be9513534e55aa3df9c0885b6e3580a3b146eb93))

## [0.5.2](https://github.com/viamin/agent-harness/compare/agent-harness/v0.5.1...agent-harness/v0.5.2) (2026-03-24)


### Bug Fixes

* **opencode:** use 'opencode run' subcommand instead of --prompt flag ([56fbc4f](https://github.com/viamin/agent-harness/commit/56fbc4f4b7ed312cba1d71d357561d44c93a55e1))

## [0.5.1](https://github.com/viamin/agent-harness/compare/agent-harness/v0.5.0...agent-harness/v0.5.1) (2026-03-24)


### Bug Fixes

* 30: fix(codex): use 'codex exec' subcommand instead of --prompt ([#35](https://github.com/viamin/agent-harness/issues/35)) ([1093a23](https://github.com/viamin/agent-harness/commit/1093a23dd001a7ea3caf13306d284fe3b5b976c5))
* **anthropic:** use positional argument instead of --prompt for Claude CLI ([4ba59bd](https://github.com/viamin/agent-harness/commit/4ba59bd55394cf9ff1d1994ce787e0e285725b93)), closes [#29](https://github.com/viamin/agent-harness/issues/29)
* **kilocode:** use 'kilo run' subcommand instead of --prompt flag ([f850f54](https://github.com/viamin/agent-harness/commit/f850f54cfac595fe910298303beb373c7bc68376))
* **test:** use correct RSpec matcher `end_with` instead of `ending_with` ([3a9d68b](https://github.com/viamin/agent-harness/commit/3a9d68b90a0e788683a382303108ebe28cc24e63))

## [0.5.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.4.0...agent-harness/v0.5.0) (2026-03-03)


### Features

* parse token usage from Claude CLI JSON output ([a0e6d7c](https://github.com/viamin/agent-harness/commit/a0e6d7cafb5f5b74806a44d3d4f487e87fdfa05e)), closes [#19](https://github.com/viamin/agent-harness/issues/19)
* support authentication error detection and token refresh for CLI agents ([83f2c71](https://github.com/viamin/agent-harness/commit/83f2c71c555483322c8a19d8a6ae195bd7720296)), closes [#20](https://github.com/viamin/agent-harness/issues/20)


### Bug Fixes

* add file lock to refresh_claude_auth to prevent lost-update races ([eb00e19](https://github.com/viamin/agent-harness/commit/eb00e1935dcd574f952ea37c263e9794de23f9a7))
* address code review feedback for authentication module ([6d11067](https://github.com/viamin/agent-harness/commit/6d1106743c79f5ae4c3a98f078e4c4d4c93db465))
* address code review feedback for resolve_provider and conductor docs ([5975b3b](https://github.com/viamin/agent-harness/commit/5975b3b8e087f681b57cc9935499e0691f865360))
* address PR review feedback for auth error handling ([70d7ea7](https://github.com/viamin/agent-harness/commit/70d7ea7eb4d13fd80d7c2724af57053a6dea9972))
* address PR review feedback for authentication module ([b098682](https://github.com/viamin/agent-harness/commit/b098682448104a833a3e50c89531bcb838910b52))
* address PR review feedback for token handling in authentication ([03398b9](https://github.com/viamin/agent-harness/commit/03398b9be4b43c12c31694d8c7864dfde891da29))
* address remaining PR review feedback for auth behavior ([893b549](https://github.com/viamin/agent-harness/commit/893b549bb080345bb1c0dfe718bb1840ff2a1f5e))
* align ErrorTaxonomy auth_expired action with Conductor behavior ([7697637](https://github.com/viamin/agent-harness/commit/76976375708f56c4fbcaf635bebafd8da9f35de1))
* clear expiry metadata on token refresh and align docs with API ([9bba06e](https://github.com/viamin/agent-harness/commit/9bba06e00c7b65722afef4b4492ec777e65578e0))
* correct method for checking module inclusion in provider validation ([4cf57fc](https://github.com/viamin/agent-harness/commit/4cf57fcebed92261e065aa6cf526f1f3851f57e7))
* differentiate credential read errors instead of returning generic nil ([cada3c5](https://github.com/viamin/agent-harness/commit/cada3c5404144b4eaf122d5dbe5f023eb30e5d95))
* guard against non-Hash JSON in refresh_claude_auth credentials ([74e1301](https://github.com/viamin/agent-harness/commit/74e1301ec7835f929bd43dc15f4a87e62bcf7237))
* remove accidentally committed bundler binstubs ([8207ef0](https://github.com/viamin/agent-harness/commit/8207ef0df67add5d1db8f3af9ef495c0b832d0b6))
* validate tokens are non-empty strings in authentication module ([55a12e4](https://github.com/viamin/agent-harness/commit/55a12e45616839079afe509e079c771a1a71a1a5))

## [0.4.0](https://github.com/viamin/agent-harness/compare/agent-harness/v0.3.0...agent-harness/v0.4.0) (2026-02-16)


### Features

* add DockerCommandExecutor for container-based command execution ([85826e5](https://github.com/viamin/agent-harness/commit/85826e5ece76d9f073329902769093f846cfd8b7))
* add DockerCommandExecutor for container-based command execution ([cb18f2e](https://github.com/viamin/agent-harness/commit/cb18f2e2f1d16ef52ea2ce54c51970d73fcae6c8))

## [0.3.0](https://github.com/viamin/agent-harness/compare/agent-harness-v0.2.2...agent-harness/v0.3.0) (2026-01-26)


### Features

* initial extraction of agent-harness code from aidp ([a87e4ec](https://github.com/viamin/agent-harness/commit/a87e4ecfd50415bb2f4dacb5946cdd84160617bf))
* initial extraction of agent-harness code from aidp ([8563466](https://github.com/viamin/agent-harness/commit/856346661e06962d5b2c05710a4928f484526931))


### Bug Fixes

* add Gemfile.lock to extra-files in release-please config ([11fa4d7](https://github.com/viamin/agent-harness/commit/11fa4d7edd29e5c30ed4d074687097bc2db5d6fa))
* add Gemfile.lock to extra-files in release-please config ([e94f431](https://github.com/viamin/agent-harness/commit/e94f431fbee36da72ce768a14ed927728e197551))
* add workflow to update release-please lockfile automatically ([0c01f92](https://github.com/viamin/agent-harness/commit/0c01f92b26eb7f1aa12c5a71776b889756240f1f))
* remove extra-files configuration from release-please config ([3fa12df](https://github.com/viamin/agent-harness/commit/3fa12df710b6b6e6e0ec8f1f8da2de86bc3e8503))
* remove update-release-please-lockfile workflow ([5482b8d](https://github.com/viamin/agent-harness/commit/5482b8d9a285de03bfc227f598ff917785baf5a1))
* remove update-release-please-lockfile workflow ([1ef7268](https://github.com/viamin/agent-harness/commit/1ef7268616bf1f56f466a0b4b36edc8a815f0ee8))
* update .gitignore to include /vendor/bundle/ and remove Gemfile.… ([beba6aa](https://github.com/viamin/agent-harness/commit/beba6aa197363a3375df4370e891010ac56bb6b0))
* update .gitignore to include /vendor/bundle/ and remove Gemfile.lock from release-please config ([cb15c77](https://github.com/viamin/agent-harness/commit/cb15c77b1fef400451be9542321e10f2f8d766af))
* update agent-harness version in Gemfile.lock to 0.2.1 ([32ff4e4](https://github.com/viamin/agent-harness/commit/32ff4e4f95173fafa196345c69dd0b38b113d928))
* update release-please config to include Gemfile.lock as extra file ([be91fff](https://github.com/viamin/agent-harness/commit/be91fff227cc56c0fd9850ac54a2bec09755f8d6))


### Improvements

* streamline command execution and error handling in various modules ([7f0e50c](https://github.com/viamin/agent-harness/commit/7f0e50c9dc00e8b2a81af8738f46fb894b629a2f))

## [0.2.2](https://github.com/viamin/agent-harness/compare/agent-harness/v0.2.1...agent-harness/v0.2.2) (2026-01-26)


### Bug Fixes

* add Gemfile.lock to extra-files in release-please config ([11fa4d7](https://github.com/viamin/agent-harness/commit/11fa4d7edd29e5c30ed4d074687097bc2db5d6fa))
* add Gemfile.lock to extra-files in release-please config ([e94f431](https://github.com/viamin/agent-harness/commit/e94f431fbee36da72ce768a14ed927728e197551))
* update .gitignore to include /vendor/bundle/ and remove Gemfile.… ([beba6aa](https://github.com/viamin/agent-harness/commit/beba6aa197363a3375df4370e891010ac56bb6b0))
* update .gitignore to include /vendor/bundle/ and remove Gemfile.lock from release-please config ([cb15c77](https://github.com/viamin/agent-harness/commit/cb15c77b1fef400451be9542321e10f2f8d766af))
* update agent-harness version in Gemfile.lock to 0.2.1 ([32ff4e4](https://github.com/viamin/agent-harness/commit/32ff4e4f95173fafa196345c69dd0b38b113d928))

## [0.2.1](https://github.com/viamin/agent-harness/compare/agent-harness/v0.2.0...agent-harness/v0.2.1) (2026-01-26)


### Bug Fixes

* add workflow to update release-please lockfile automatically ([0c01f92](https://github.com/viamin/agent-harness/commit/0c01f92b26eb7f1aa12c5a71776b889756240f1f))
* remove extra-files configuration from release-please config ([3fa12df](https://github.com/viamin/agent-harness/commit/3fa12df710b6b6e6e0ec8f1f8da2de86bc3e8503))
* update release-please config to include Gemfile.lock as extra file ([be91fff](https://github.com/viamin/agent-harness/commit/be91fff227cc56c0fd9850ac54a2bec09755f8d6))

## [0.2.0](https://github.com/viamin/agent-harness/compare/agent-harness-v0.1.0...agent-harness/v0.2.0) (2026-01-26)


### Features

* initial extraction of agent-harness code from aidp ([a87e4ec](https://github.com/viamin/agent-harness/commit/a87e4ecfd50415bb2f4dacb5946cdd84160617bf))
* initial extraction of agent-harness code from aidp ([8563466](https://github.com/viamin/agent-harness/commit/856346661e06962d5b2c05710a4928f484526931))


### Improvements

* streamline command execution and error handling in various modules ([7f0e50c](https://github.com/viamin/agent-harness/commit/7f0e50c9dc00e8b2a81af8738f46fb894b629a2f))

## [0.1.0] - 2026-01-24

- Initial release
