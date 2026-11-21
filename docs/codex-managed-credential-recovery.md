# Codex Managed Credential Recovery

## Public contract

Agent Harness supports one bounded refresh-token exchange for caller-managed Codex
ChatGPT OAuth credentials. The caller must explicitly select the native `auth.json`
file, the authorized account, and the exact file generation it leased:

```ruby
path = "/isolated/run-123/codex/auth.json"
selected = AgentHarness.credential_metadata(:codex, credential_path: path)

result = AgentHarness.exchange_refresh_token(
  :codex,
  credential_path: path,
  expected_generation: selected.fetch(:generation),
  expected_account_id: selected.fetch(:account_id),
  timeout: 45
)
```

`credential_metadata` returns no token material. It reports `billing_mode`,
`account_id`, access-token `expires_at`, `expired`, `refreshable`, and the SHA-256
`generation`. A successful exchange returns `credentials` in Codex's native shape
and updated token-free `metadata`.

The call never searches `HOME` or `CODEX_HOME`, imports host credentials, changes
shared configuration, runs Codex, or replays a coding request. `auth_mode` must be
ChatGPT OAuth; API-key material is rejected as `unsupported_credential_type`.
OAuth provenance already recorded by Codex is retained and used only when it names
the approved `https://auth.openai.com` issuer. Legacy native material without
provenance uses Codex's public CLI authority and client ID.

The adjacent `auth.json.lock` serializes cooperating refreshers. The implementation
also compares the selected generation before exchange and snapshots the selected
inode at commit. An in-place write entering immediately before the atomic mode-`0600`
rename is detected and restored. Callers must keep their outer lease boundary, and
all supported writers must honor that lease or the adjacent lock; POSIX pathnames do
not provide compare-and-swap against arbitrary atomic renames by uncooperative
writers. Missing response tokens retain the prior native value, including a reusable
refresh token; returned rotated tokens are preserved.

The deadline must be positive and no more than 60 seconds. There is exactly one
provider request and no coding/tool request. `AuthenticationError#error_code`
provides these actionable, redacted outcomes:

| Code | Meaning |
| --- | --- |
| `missing_refresh_material` | The selected native store has no refresh token. |
| `unsupported_credential_type` | The selected route is API-key or another non-ChatGPT mode. |
| `identity_mismatch` | Stored or returned identity differs from the authorized account. |
| `concurrent_update` | The selected generation is stale or changed during exchange. |
| `refresh_token_expired` | The authority says the refresh token expired. |
| `refresh_token_reused` | The authority says a rotating token was already consumed. |
| `refresh_token_revoked` | The authority says the token was invalidated. |
| `invalid_refresh_token` | The authority rejected the grant. |
| `provider_rejected` | The authority returned another non-success response. |
| `malformed_response` | A success reply lacks valid native access/identity/expiry data. |
| `transport_failure` | Credential I/O or the authority transport failed. |
| `deadline_exceeded` | The finite deadline elapsed. |

Errors never contain tokens, credential bodies, or raw provider responses. Failure
before atomic commit leaves the selected credential bytes intact.

`auth_capabilities(:codex)` continues to report Codex's default `auth_type` as
`:api_key`, with interactive URL, code exchange, and token injection disabled. It
advertises `exchange: true` and `managed_oauth_recovery: true` only for this explicit
native-store contract. Claude and Anthropic retain their existing implicit exchange
API and capability shape.

## LLD and EARS requirements

The low-level design has three provider-owned stages: inspect native material and
derive token-free metadata; exchange once with the Codex OAuth authority under a
finite deadline; validate identity/expiry and compare-and-save through an atomic
native write. No stage invokes a coding transport.

- When a caller selects valid expired Codex ChatGPT OAuth material, the system shall
  attempt one bounded refresh and return refreshed native credentials and reliable
  identity/expiry metadata.
- When the selected route is an API key or an unsupported provider, the system shall
  keep it distinct from managed OAuth recovery and shall not contact the authority.
- While recovery is in progress, the system shall serialize on the selected native
  store and shall refuse to overwrite a different generation.
- If refresh material is rotated, the system shall atomically persist and return it;
  if the response omits rotation, the system shall retain the reusable prior token.
- If selection, identity, provider reply, transport, or deadline validation fails,
  the system shall return a safe category and leave prior material intact.

## Criterion-level verification plan

| Criterion | Smallest credible evidence |
| --- | --- |
| AC-1 capability, success, expiry, native shape | Permanent service specs with synthetic JWTs and a synthetic OAuth response. |
| AC-2 explicit store, identity, billing isolation | Permanent service specs asserting explicit arguments, API-key rejection, and identity mismatch without a provider call. |
| AC-3 serialization, generation, rotation | Permanent service specs asserting atomic mode, field preservation, rotation, and stale-generation refusal. |
| AC-4 bounds and safe errors | Permanent service specs for finite arguments, provider categories, malformed replies, transport/deadline behavior, redaction, and byte-for-byte failure atomicity. |
| AC-5 behavior preservation | Existing Claude authentication and Codex provider suites plus the focused public capability specs. |
| AC-6 release and real credential | External evidence: publish the containing gem release, pin it in Paid through its normal toolchain, and run the separately authorized check below. Mocks cannot satisfy this criterion. |

## Authorized downstream acceptance check

After a containing release is published, Paid must pin that exact version in its
normal toolchain. In an isolated directory, copy only the explicitly authorized
expired managed `auth.json`, acquire Paid's normal lease, record token-free metadata,
invoke the bounded call, verify the same account and billing mode plus a future
expiry, then perform deterministic cleanup of the isolated directory. Record the
release version, commit SHA, run ID, timestamps, metadata excluding generation if it
is considered sensitive, outcome category, and cleanup result. Do not record token
values, credential bodies, request bodies, or raw provider responses. This live
refresh is deliberately not inferred from unit tests.
