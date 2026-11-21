# Codex managed credential recovery LLD/EARS

## Scope and ownership

`AgentHarness.exchange_refresh_token(:codex, ...)` is the public, provider-owned
boundary for recovering one explicitly selected native Codex OAuth store. It
does not discover host credentials, run a chat turn, invoke tools, convert the
store to an API key, or change the caller's billing mode. Claude's existing
zero-keyword exchange remains unchanged.

The caller owns selection and its outer lease. Agent Harness owns native JSON
parsing, the OAuth exchange, identity checks, adjacent-file locking, generation
comparison, rotation preservation, and atomic serialization. The selected
store must be an absolute path. Recovery performs exactly one HTTP attempt with
a caller-selected timeout of at most 45 seconds.

## Contract

On success the call returns the refreshed full native credential object and
`expires_at`, `account_id`, `generation`, and `auth_mode: :subscription`.
Unknown root and token fields are preserved. A missing rotated refresh token in
a valid response preserves the prior reusable refresh token. The refreshed JWT
must carry a reliable expiry and must match the selected credential's account.

Failures raise `AuthenticationError` with a safe `error_code`:

- `api_key_credential`, `missing_refresh_material`, or
  `invalid_credential_shape` for an unusable selected store;
- `refresh_token_expired`, `refresh_token_reused`,
  `refresh_token_revoked`, or `invalid_refresh_token` for rejected material;
- `deadline_exceeded`, `transport_failure`, `provider_failure`, or
  `malformed_response` for external failures; and
- `credential_store_busy`, `credential_generation_changed`, or
  `identity_mismatch` for serialization and identity guards.

Errors and logs do not include tokens, credential bodies, or raw provider
responses. Any failure before atomic rename leaves the prior selected material
intact.

## EARS requirements

- When a caller inspects Codex auth capabilities, the harness shall advertise
  refresh-token exchange and the required `credentials_path`, while continuing
  to report the normal Codex `auth_type` as `api_key` and `refresh` as false.
- When a caller supplies valid expired native OAuth material, the harness shall
  make one bounded refresh attempt and return/persist rotated native material
  with verified identity and expiry metadata.
- While another actor holds the adjacent native-store lock, the harness shall
  reject recovery without reading or changing credential material.
- If the selected store changes after it is read, the harness shall reject the
  stale result and shall not overwrite the newer generation.
- If refreshed tokens identify a different account or lack reliable identity
  or expiry claims, the harness shall reject them and leave the store intact.
- If the store is an API-key route, lacks refresh material, is malformed, or
  the provider rejects or cannot complete exchange, the harness shall return a
  safe actionable category without secret or raw-response disclosure.
- When Codex recovery is requested, the harness shall not import a default host
  store, mutate shared configuration, replay a coding request, or substitute an
  API-key/provider policy.

## Verification and release boundary

Permanent service tests use synthetic JWTs and HTTP doubles to cover capability,
native shape, expiry, identity, rotation, one-attempt deadlines, error
classification, atomic writes, and stale-generation rejection. Existing Claude
tests remain the compatibility evidence. These tests do not prove live OpenAI
acceptance. A live refresh requires separately authorized downstream material,
an exact released gem pin, and recorded isolated cleanup; it must not be inferred
from mocked tests.
