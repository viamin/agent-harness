## [Unreleased]

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
