# Provider-Neutral API Execution Contract

This document records the design investigation for
[RDR-072](https://github.com/viamin/paid/blob/01672a9992853e89bcbd272b720ac9f1da73cba0/docs/rdrs/RDR-072-api-conversation-delegation.md).
It is the upstream contract for incremental embedding, chat, structured-output,
usage, and optional conversation-persistence work.

## Status and rollout boundary

RDR-072's rollout guard was **docs-only** for the design phase. The normalized
chat and schema capabilities described below are now implemented. Other
capabilities remain design contracts and each still needs
its own failing-first contract tests, implementation, release evidence, and
downstream adoption evidence before a caller enables it.

Existing CLI and subscription behavior remains the default. Existing
`TextTransport`, `OpenAICompatibleTransport`, `Conversation`, and `Response`
interfaces remain available and unchanged; they are not aliases for the
normalized API. A caller must not infer support for another capability from a
gem version or issue closure.

Normative words such as MUST and MUST NOT describe the future public boundary.

## Shipped normalized chat surface

`AgentHarness::Api::ChatTransport#call` implements one normalized assistant
response while leaving the conversation loop and all application tool
execution with the caller:

```ruby
transport = AgentHarness::Api::ChatTransport.new
result = transport.call(request.merge(
  operation: :chat,
  messages: [
    {id: "system-1", role: :system,
     content: [{type: :text, text: "Be concise"}]},
    {id: "user-1", role: :user,
     content: [{type: :text, text: "Summarize this"}]}
  ],
  tools: [{
    name: "lookup",
    description: "Looks up a record",
    input_schema: {type: "object", properties: {id: {type: "string"}}}
  }],
  max_output_tokens: 1_000,
  stream: true
), observer: ->(event) { events << event })
```

The returned value is the normalized result hash in this document. The
observer is either callable or responds to `on_chat_event`. It receives ordered
events with request/attempt identity and sequence numbers. This transport never
invokes a supplied tool; callers append completed tool results to a later
request. A failed partial stream is terminal, so its content cannot be appended
to a fallback response and its tool calls cannot be replayed automatically.

Streamed tool-call arguments are emitted as raw, appendable JSON fragments
correlated to one `tool_call_started` event per provider call, and cumulative
provider token counts are emitted as deduplicated `usage_updated` events. An
observer that raises aborts the in-flight request and surfaces as
`AgentHarness::Api::ChatTransport::ObserverError` with the original failure as
its `cause`; it is never classified as a provider error, never retried, and the
failed observer is not invoked again.

The verified scopes are Anthropic with `protocol: :messages`, OpenAI with
`protocol: :responses` or `:chat_completions`, and OpenAI-compatible endpoints
with `provider: :openai`, an explicit `endpoint`, and
`protocol: :chat_completions`. Compatible endpoints that do not implement the
Responses API must select `:chat_completions`; the transport never probes and
silently switches protocols. Only `authentication_mode: :api_key` is currently
supported.

Credentials, endpoint, custom headers, timeout, and RubyLLM configuration are
isolated with a request-local `RubyLLM::Context`. RubyLLM middleware retries
are disabled; `retry.max_attempts` is the total physical-attempt limit owned by
the harness. Authentication headers cannot be overridden by custom headers.
`max_output_tokens` is forwarded without changing it.

Unknown model IDs are allowed only because a complete provider and protocol
are explicit in every candidate (`assume_model_exists: true` in the RubyLLM
adapter). This skips registry validation; it does not assert that the endpoint
supports the model. Provider rejection returns a classified failure. Custom
endpoints retain the selected provider's wire protocol and authentication
shape. Custom provider types, authentication modes, media content, and
automatic protocol discovery are not supported by this capability.

## Shipped schema-constrained response surface

The same transport accepts `operation: :schema` with a JSON Schema and an
optional name:

```ruby
result = transport.call(request.merge(
  operation: :schema,
  schema_name: "person",
  schema: {
    type: "object",
    properties: {
      name: {type: "string"},
      age: {type: "integer"}
    },
    required: %w[name age],
    additionalProperties: false
  }
))

result[:content] # => '{"name":"Ada","age":37}'
result[:parsed]  # => {"name" => "Ada", "age" => 37}
```

Schema operations use strict JSON Schema output and the same verified
Anthropic Messages, OpenAI Responses, and OpenAI Chat Completions scopes as
normalized chat. `schema_mode: :json_schema` is the only supported mode.
JSON-only mode returns `unsupported/structured_output_not_supported`; it is
not silently treated as schema enforcement.

The harness parses the exact provider text and validates it locally against
the requested schema. It does not remove Markdown fences or repair malformed
JSON. Invalid JSON, schema mismatch (including a missing required field),
refusal, and output-limit truncation return non-retryable `invalid_response`
outcomes with codes `invalid_json`, `invalid_schema`, `refusal`, and
`truncated_output`, respectively. These results retain the original text in
`content`, leave `parsed` as `nil`, and are never successful empty objects.

This API surface does not alter existing CLI or subscription execution.
Schema requests use request-local API-key credentials and explicit protocols;
`AgentHarness.send_message`, CLI providers, and subscription authentication
continue through their existing paths. Custom endpoints and headers have the
same isolation and reserved-auth-header rules as normalized chat.

## Ownership boundary

AgentHarness owns protocol translation and one bounded provider request:

- capability discovery and explicit unsupported outcomes;
- provider-specific request and response translation;
- request retries within caller-supplied limits;
- normalized stream events, results, errors, and attempt reports; and
- stable attempt and tool-call identities at its public boundary.

The caller owns application authority and durable policy:

- tenant and actor identity, authorization, and visible tools;
- candidate order, credentials, allowed models, and fallback notices;
- budgets, cancellation initiation, runner changes, and workflow recovery;
- durable usage attribution and idempotent ingestion of attempt reports;
- tool confirmation and side-effect reconciliation; and
- application conversation/message identity and audit records.

The harness MUST NOT select an unlisted fallback, borrow global credentials,
change authentication mode, execute a tool, or replay a completed tool result.
Keeping the caller's chat loop over this normalized transport is an acceptable
final architecture.

## Common execution request

All operations use an immutable, request-local configuration. The eventual
Ruby API MAY use value objects rather than hashes, but it MUST expose these
semantics:

```ruby
request = {
  request_id: "paid-generation-018f...", # caller-generated, stable on redelivery
  operation: :chat,                       # :chat, :embedding, or :schema
  candidates: [                           # ordered; first entry is initial
    {
      provider: :anthropic,
      model: "claude-sonnet-4-5",
      protocol: :messages,                # optional verified protocol
      authentication_mode: :api_key,
      endpoint: "https://llm-proxy.example/v1",
      headers: {"X-Tenant-Route" => "tenant-123"},
      credentials: {api_key: anthropic_secret}
    },
    {
      provider: :openai,
      model: "gpt-5",
      protocol: :responses,
      authentication_mode: :api_key,
      endpoint: "https://api.openai.com/v1",
      headers: {},
      credentials: {api_key: openai_secret}
    }
  ],
  fallback: {on_error_categories: [:transient]},
  timeout: {connect_seconds: 5, read_seconds: 60},
  retry: {max_attempts: 3, base_delay_seconds: 0.25, max_delay_seconds: 2},
  cancellation: cancellation_token,
  metadata: {tenant_id: "tenant-123", workflow_id: "workflow-456"}
}
```

`candidates` MUST contain at least one complete candidate record. Its first
entry is the initial candidate; later entries are the only authorized fallback
order. A request that does not authorize fallback supplies a one-entry array.
`fallback.on_error_categories` is the caller-selected allowlist of error
categories that permit advancing to the next entry; an absent or empty
allowlist disables fallback. Candidate records, their order, and the allowlist
are immutable for the lifetime of the request. The observer described below is
a request-local callback or equivalent API argument because callbacks are not
part of a serializable request document.

`request_id` identifies one logical operation. Every physical outbound request
gets a distinct `attempt_id`. Redelivering an already reported attempt retains
its `attempt_id`; initiating another outbound request does not.

Credentials, endpoint, headers, timeouts, retry limits, and cancellation are
request-local. Implementations MUST prevent concurrent requests from observing
one another's credentials or headers. They MUST reject reserved header
overrides that would conflict with the selected protocol's authentication.
Logs and errors MUST NOT contain credentials, authorization headers, message
bodies, tool arguments, or full provider responses.

The selected candidate's provider, model, protocol, endpoint, and authentication
mode MUST be the values actually used. The harness MUST return a configuration
or unsupported outcome instead of silently substituting any of them.

## Capability discovery and unsupported outcomes

Support is declared per operation, provider, protocol, model when known, and
authentication mode. It is not a single provider-wide Boolean. The discovery
result has one of three states:

- `supported`: the requested combination is verified;
- `unsupported`: it is known not to work, with a stable reason; or
- `unknown`: it has not been verified and MUST NOT be routed as supported.

Stable unsupported reasons initially include:

- `operation_not_supported`;
- `protocol_not_supported`;
- `authentication_mode_not_supported`;
- `custom_endpoint_not_supported`;
- `custom_headers_not_supported`;
- `streaming_not_supported`;
- `tools_not_supported`;
- `structured_output_not_supported`; and
- `state_restoration_not_supported`.

An unsupported result is a normal, non-retryable outcome carrying the requested
scope and reason. It is not a generic provider failure. Callers MAY choose
another candidate only from their own ordered list.

## Normalized chat contract

### Messages

The input is an ordered array. Each message has a stable caller-owned `id`, one
of `system`, `user`, `assistant`, or `tool` as its `role`, and an ordered
`content` array. Content parts initially support `text`; unimplemented media
parts produce an explicit unsupported outcome. Assistant messages MAY contain
tool calls. Tool messages MUST reference exactly one `tool_call_id`.

Provider-specific wire roles, system-message placement, and content block
shapes stay behind the harness boundary. The harness MUST preserve ordering,
empty assistant text accompanying tool calls, and unknown versus absent data.

### Tools

Tool definitions contain a caller-owned name, description, and JSON Schema
input definition. A normalized tool call contains:

```ruby
{
  id: "toolcall_018f...",       # stable harness ID
  provider_id: "call_abc",      # optional provider correlation only
  name: "search_documents",
  arguments_json: "{\"query\":\"Ruby\"}"
}
```

The stable `id` is generated before the call is exposed or persisted and MUST
survive export/import. `provider_id` is not a durable application identifier.
Arguments remain JSON text until parsing succeeds; malformed arguments produce
a classified parse failure and are never executed by the harness. Tool results
reference the stable ID. Redelivery or restoration MUST skip a tool call when a
completed result for that ID exists.

The transport never decides approval and never executes application tools.

### Streaming

The stream is ordered and contains these normalized event types:

- `response_started` with request and attempt identity;
- `text_delta` with appended text;
- `tool_call_started`, `tool_call_delta`, and `tool_call_completed`;
- `usage_updated` when defensible cumulative or delta usage is available;
- `response_completed` with the final normalized result; and
- `response_failed` or `response_cancelled` with the partial result.

Every event carries `request_id`, `attempt_id`, and a monotonically increasing
`sequence`. A terminal event occurs exactly once per attempt. Callback failure
requests cancellation and surfaces as a caller error; it MUST NOT be converted
to provider success.

If a stream ends after emitting content, the terminal result has
`status: :partial`, retains received text and completed tool calls, and carries
the classified error. Incomplete tool calls are marked incomplete and MUST NOT
be executed. A partial attempt is never transparently retried: already emitted
content cannot be withdrawn. The caller must explicitly decide whether a new
attempt is safe and how to represent the abandoned partial message.

### Result

A completed chat or schema result contains:

```ruby
{
  request_id: "paid-generation-018f...",
  status: :succeeded, # :succeeded, :partial, :failed, or :cancelled
  provider: :anthropic,
  model: "claude-sonnet-4-5",
  authentication_mode: :api_key,
  content: "...",
  parsed: nil,
  tool_calls: [],
  finish_reason: :stop,
  attempts: [],
  usage: {input_tokens: 12, output_tokens: 8, total_tokens: 20},
  provider_request_id: nil,
  error: nil
}
```

`usage` aggregates only the attached attempt reports. Missing provider values
remain `nil`; they are not coerced to zero. `provider_request_id` is optional
diagnostic correlation and is not the accounting identity.

## Structured-output contract

A schema operation adds a JSON Schema and optional schema name to the chat
request. The capability check MUST cover the selected provider/model/protocol
and requested schema mode. JSON-only mode is not equivalent to schema-enforced
output and MUST be reported separately.

On success, `content` preserves provider JSON text and `parsed` contains the
parsed Ruby value. Invalid JSON or schema mismatch is a classified,
non-transient result with the original text retained. The harness MUST NOT
silently strip fences, repair content, issue a second model call, or switch to
a different credential to make parsing succeed.

## Embedding contract

An embedding request supplies one string or an ordered array of strings,
provider/model candidate, and optional dimensions. Its result preserves input
order and contains dense vectors, the model actually used, per-attempt usage,
and optional provider request correlation. One input returns one vector;
multiple inputs return an equal-length vector array.

Empty batches, unsupported dimensions, unsupported input media, and batch-size
limits are explicit configuration or unsupported outcomes. The first release
need not cover multimodal or provider-side batch APIs. Vector persistence and
similarity search remain caller responsibilities.

## Attempts, usage, retries, and cancellation

Each physical provider request produces an attempt report, including failed and
cancelled attempts:

```ruby
{
  attempt_id: "attempt_018f...",
  request_id: "paid-generation-018f...",
  number: 2,
  provider: :anthropic,
  model: "claude-sonnet-4-5",
  status: :failed,
  started_at: "2026-09-25T12:00:00Z",
  finished_at: "2026-09-25T12:00:01Z",
  usage: {input_tokens: nil, output_tokens: nil, total_tokens: nil},
  cost: nil,
  provider_reported: false,
  error: {category: :transient, code: :service_unavailable}
}
```

Attempt reports are delivered both with the final result and through an
observer so durable accounting can persist an attempt even when no message is
created. Callers deduplicate on `attempt_id`. Cost identifies its source as
provider-reported or harness-estimated; unknown cost remains `nil`.

Only errors classified `transient` are eligible for bounded request retry:
connection failure, timeout before a partial stream, rate limit, server error,
service unavailable, and overload. Authentication, authorization, billing,
invalid request, unsupported capability, invalid schema, context length,
configuration, and cancellation are non-retryable.

The supplied `max_attempts` includes the first outbound request and is the total
physical-attempt budget across all candidates; changing candidates does not
reset it. It MUST be a positive integer; the harness rejects zero, negative, or
non-integer values as configuration errors before making an outbound request.
Delay and provider `retry-after` handling remain within the supplied bounds.
Cancellation is checked before an attempt, during backoff, while reading a
stream, and before returning success. It stops further attempts and returns a
cancelled terminal outcome with any partial usage. Cancellation does not prove
that the provider stopped processing or billing the request.

The harness owns the complete attempt sequence; there is exactly one retry
owner. RubyLLM's Faraday retry middleware resends the current candidate inside
the transport before a classified error can return to the harness, so
middleware-driven retries cannot honor the fallback-first order below and would
spend the shared budget on one candidate invisibly to the observer. An adapter
backed by RubyLLM MUST therefore disable its retry middleware with
`max_retries: 0`, overriding the default three retries, so that one adapter
call performs exactly one physical outbound request. The harness then issues
one adapter call per attempt — initial, retry, or fallback — and applies the
shared `max_attempts` budget, cancellation checks, backoff, and provider
`retry-after` between calls. No component may retry beneath the harness, and
the harness MUST NOT delegate this sequencing to middleware or another nested
loop. Existing conductor retry/provider switching is not part of an API
request's internal retry budget and MUST be disabled or bypassed for a
migrated scope.

## Caller-controlled fallback

Fallback candidates are the entries after the first entry in the request's
ordered `candidates` array. Each is a complete request-local candidate record,
including credentials and endpoint/header overrides. A candidate change is a
new caller-authorized selection, not a hidden retry. Before advancing, the
harness invokes the request-local observer with the current and next candidate
identities and the classified error, so the caller can cancel the change or
issue a notice. The harness reports every candidate attempt.

Fallback is allowed only for caller-selected error categories. It never occurs
after a partial stream without a new explicit caller decision, never crosses
authentication modes implicitly, and never replays completed tools. The
harness MUST NOT use RubyLLM global fallback or global credential configuration
where it could exceed this list or leak request-local configuration.

Fallback takes precedence over retry when both are eligible. After a failed
attempt, the harness MUST apply this order:

1. Stop if cancellation was requested or any partial stream was exposed.
2. If the budget has capacity, the error category is in
   `fallback.on_error_categories`, and another candidate remains, notify the
   observer and advance to that candidate.
3. Otherwise, retry the current candidate only when the error is retryable and
   the shared `max_attempts` budget has capacity.
4. Otherwise, return the terminal error.

The outbound request after either advancing or retrying consumes one physical
attempt from the same budget. Candidates are never revisited, and a failed
observer notification or observer cancellation stops before that request.
Consequently, the example request attempts Anthropic once and then OpenAI after
an eligible `transient` failure; only OpenAI can consume the remaining
same-candidate retry budget.

## Error contract

Every terminal error exposes a stable category and code, retry eligibility,
provider/model identity, optional sanitized status and request ID, and partial
result/usage where available. Categories are:

| Category | Examples | Request retry |
| --- | --- | --- |
| `transient` | timeout, connection failure, 429, 5xx, overload | bounded |
| `authentication` | missing or rejected credential | never |
| `authorization` | credential lacks access | never |
| `billing` | inactive billing account or payment required | never |
| `configuration` | invalid endpoint/header/model or local configuration | never |
| `invalid_request` | malformed or semantically invalid provider request | never |
| `context_length` | request exceeds the model context window | never |
| `unsupported` | operation or option not implemented | never |
| `invalid_response` | malformed JSON, schema/tool parse failure | never |
| `cancelled` | caller cancellation | never |
| `caller` | callback or local input failure | never |
| `unknown` | provider failure that cannot be classified confidently | never |

Adapters MUST use the following category and code mappings. A provider-specific
status or error name may be retained as sanitized metadata, but MUST NOT replace
these values or change fallback eligibility.

| Failure | Category | Code |
| --- | --- | --- |
| Connection failure | `transient` | `connection_failed` |
| Timeout before a partial stream | `transient` | `timeout` |
| Rate limit | `transient` | `rate_limited` |
| Provider server error | `transient` | `server_error` |
| Service unavailable | `transient` | `service_unavailable` |
| Provider overload | `transient` | `overloaded` |
| Missing or rejected credential | `authentication` | `invalid_credential` |
| Credential lacks access | `authorization` | `permission_denied` |
| Billing account inactive or payment required | `billing` | `billing_unavailable` |
| Invalid provider request | `invalid_request` | `invalid_request` |
| Unsupported capability or option | `unsupported` | `unsupported_capability` |
| Structured output violates its schema | `invalid_response` | `invalid_schema` |
| Request exceeds the model context window | `context_length` | `context_length_exceeded` |
| Invalid endpoint, header, model, or local request configuration | `configuration` | `invalid_configuration` |
| Caller cancellation | `cancelled` | `cancelled` |

If a failure cannot be mapped confidently, the adapter MUST return `unknown` /
`unclassified_provider_error`, which is non-retryable, rather than guessing a
retryable category. A timeout or other error after a partial stream retains its
mapped category and code, but its per-error retry eligibility is `false` and the
fallback rule above prohibits automatic replay.

Provider error classes stay internal. Existing `ProviderError` is too broad to
drive this policy and existing `ErrorTaxonomy` was designed for CLI provider
switching, so neither is the future API retry contract without an explicit
mapping and contract tests.

## State export, import, and restart safety

Plain Ruby state export is a versioned data document, not a serialized Ruby
object. It contains normalized messages, stable message/tool-call IDs, completed
tool results, pending tool calls and decisions, request IDs, and attempt reports.
It never contains credentials, callbacks, open streams, tool implementations,
authorization decisions, or mutable provider client objects.

Import validates the version and structure and reconstructs the normalized
conversation. The caller must re-supply tools, authorization, candidates,
credentials, observers, retry limits, and cancellation. Unknown versions fail
explicitly. Export/import round-trip tests must prove that completed tool IDs
are not re-executed and unknown usage remains unknown.

The restart guarantee is limited to checkpoints. A saved provider response or
tool result is skipped after restoration. A process crash after an external
tool side effect but before its result is durably saved can execute the tool
again. No transcript format can close that window. Tools therefore need a
caller-owned idempotency key derived from the stable tool-call ID, or explicit
reconciliation before replay. Provider requests have the same ambiguity when a
response is lost after the provider accepted it.

## RubyLLM 2.0 mapping and alternatives

The investigation used RubyLLM 2.0.0. RubyLLM remains an implementation detail;
the harness public API MUST NOT expose its classes or private persistence
records.

| Contract area | RubyLLM 2.0 mapping | Decision or gap |
| --- | --- | --- |
| Chat/protocols | `RubyLLM.chat`, messages, tools, stream callbacks | Candidate adapter; normalize all values and errors |
| Schema | `with_schema`; harness JSON parsing and validation | Implemented for the verified chat scopes; JSON-only mode stays distinct |
| Embeddings | `RubyLLM.embed` and normalized vectors/usage | Candidate first capability; persistence remains in Paid |
| Custom headers | `with_headers` | Candidate; contract-test merging and secret redaction |
| Endpoint/credentials | provider configuration | Global mutable configuration is unsuitable; require request-local isolation or an upstream-supported client boundary |
| Retries | Faraday retry middleware, default three retries | Disable with `max_retries: 0` so one call is one physical attempt; the harness sequences bounded retry and fallback itself; never nest |
| Fallback | `with_fallbacks` and callbacks | Harness sequences candidates per call; `with_fallbacks` usable only if exact candidates, credentials, and per-advance observer control are preserved |
| Cancellation | chat cancellation and `CancelledError` | Adapt to the common token and retain partial stream state |
| Attempt usage | `usage.ruby_llm` per physical attempt | Useful facts, but the public payload has no stable attempt ID; harness must add one |
| Plain Ruby resume | transcript can be reconstructed manually | No documented state export/import API; implement normalized export/import outside RubyLLM |
| Rails resume | `acts_as_chat` transcript plus supporting records | Technically restart-safe at checkpoints; at-least-once side effects remain |

### Optional Rails supporting tables

RubyLLM 2.0 owns `ruby_llm_models`, `ruby_llm_tool_calls`,
`ruby_llm_usages`, and `ruby_llm_batches`. Only the middle two are candidates
for early chat adoption; batches are out of scope, while the model registry is
needed only if capability/pricing lookup uses it.

`ruby_llm_tool_calls.tool_call_id` is unique and can preserve the provider tool
request/result link. It is acceptable only after tests prove that the harness's
stable tool ID maps without collision and Paid tenant scoping is enforced
through the owning application message/chat. The supporting table has no
standalone tenant column, so every read/write path must join through a
tenant-owned record and cross-tenant tests are mandatory.

`ruby_llm_usages` records one physical attempt and links polymorphically to the
application chat and optionally a message. It preserves failed/cancelled usage,
but its row ID and record class are private and its public instrumentation has
no stable attempt ID. Paid cannot use that row ID as the cross-system accounting
key. The harness-generated `attempt_id` must be persisted alongside Paid's
ledger, with an upstream-supported metadata column or mapping required before
adopting this table as the authoritative delivery source.

RubyLLM has no application-owned `Model`, `ToolCall`, `Usage`, or `Batch` model;
its record classes are explicitly implementation details. Paid keeps its chat
and message domain records, tenant ownership, message links, audit actor, and
authorization. A Rails adoption requires generated-migration review, backup,
production-snapshot rehearsal, backfill verification, rollback rehearsal, and
historical/pending-conversation tests. Reverting the gem is not a data rollback.

### Persistence alternatives

1. **Retain Paid persistence and loop over normalized transport.** Lowest
   migration risk and the current recommendation. Implement plain Ruby
   export/import and stable IDs in the harness.
2. **Use RubyLLM tool-call and usage tables selectively.** Potentially removes
   bookkeeping, but only after stable-attempt mapping, tenant-scoped access,
   audit, and migration tests are complete.
3. **Delegate the full loop and all supporting tables.** Not recommended now.
   It does not yet demonstrate reduced maintenance across both repositories and
   increases migration and recovery coupling.

The state investigation is therefore positive for checkpoint-based Rails
restoration and normalized plain Ruby reconstruction, and negative for
exactly-once recovery or an off-the-shelf plain Ruby export/import mechanism.

## Current harness gaps and incremental delivery

The normalized API transport now provides request-local custom headers,
per-request timeout/retry/cancellation, schema-constrained output, stable
attempt IDs, per-attempt usage, partial terminal results, and classified
outcomes for its verified scopes. Embeddings, state export/import, and broader
provider/authentication scopes remain outstanding. `Conversation` stores
in-memory history and provider formatters but has no serialization contract.

Ship capabilities independently in this order:

1. common values, capability discovery, classified errors, and attempt reports;
2. embeddings for verified operation/provider/custom-endpoint scopes;
3. normalized non-streaming and streaming chat transport;
4. structured output for verified model/protocol combinations;
5. plain Ruby state round trips; and
6. optional Rails persistence evaluation, then loop evaluation.

Each implementation issue starts with failing contract tests for request-local
credential isolation, custom endpoints/headers, unsupported outcomes,
classified errors, bounded non-nested retries, cancellation, partial streams,
stable IDs, and unknown usage where applicable. Provider-specific fixtures and
types stay behind the harness boundary.

## Compatibility and release evidence

AgentHarness currently supports Ruby 3.2 and later and remains usable as a
plain Ruby gem. RubyLLM 2.0.0 supports Ruby 3.1.3 and later and adds Faraday,
event-stream parsing, Schematist, Marcel, and Zeitwerk runtime dependencies.
Local response validation adds `json_schemer` and its bounded dependency set.
A capability release must test the harness minimum Ruby version before
downstream adoption.

Rails and Active Record remain optional. Requiring `agent_harness` in a process
without Rails MUST NOT load Active Record, connect to a database, or require
supporting tables. Rails integration belongs behind an optional require and
adapter.

For every capability, release evidence must name:

- the first published, installable agent-harness version containing it;
- supported operation/provider/protocol/authentication combinations;
- upstream contract and integration test runs on the minimum Ruby version;
- verification of request-local secrets and absence of secret-bearing logs;
- retry/cancellation and attempt-accounting test evidence;
- the exact Paid and agent-image versions that consume the release; and
- retained paths and follow-up issues for combinations not migrated.

Paid issue `viamin/paid#4014` should receive this compatibility result, the
state-restoration conclusion, the stable-ID gap, and the per-capability release
evidence. Downstream adoption cannot proceed from this design issue closing or
from a Git tag alone.

### Schema capability release evidence

- Publication: unreleased; the first installable version must be recorded here
  before downstream adoption.
- Verified scopes: `:schema` with Anthropic Messages, OpenAI Responses, and
  OpenAI Chat Completions, API-key authentication, plus compatible endpoints
  that explicitly select OpenAI Chat Completions.
- Contract coverage: valid and required-field schemas, request-local endpoint,
  header and credential isolation, classified failures, bounded retries,
  cancellation, attempt accounting, refusal, truncation, malformed JSON, and
  schema mismatch. The full upstream suite passes without Rails or a database.
- Retained paths: all CLI and subscription execution remains on the existing
  provider interfaces. JSON-only mode, other provider/authentication scopes,
  and model-specific capability discovery are not migrated.
- Downstream: no Paid or agent-image version consumes this capability yet.
  Minimum-Ruby CI and exact consumer versions remain release gates.
