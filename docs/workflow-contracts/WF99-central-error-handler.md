# WF99 — Central Error Handler

## 1. Purpose

WF99 normalizes unexpected technical and integration failures, stores one authoritative sanitized error record in PostgreSQL, and sends or retries an idempotent operator-intervention notification when manual action is required.

WF99 keeps technical failures separate from business events. It does not decide normal onboarding outcomes and does not advance business state without an explicit state-specific recovery rule owned by another workflow.

PostgreSQL remains the source of truth for persisted technical errors and intervention-notification operations.

## 2. Responsibilities

WF99 is responsible for:

- accepting failures from the n8n Error Trigger;
- accepting explicit normalized internal calls from WF01, WF02, WF03, WF04, WF05, WF06, and WF98;
- accepting due retry invocations for `notify_operator_intervention` from WF98;
- validating and sanitizing every input before persistence;
- resolving safe case, step, submission, and operation references from PostgreSQL when supplied;
- classifying error class, code, retryability, severity, and intervention requirement;
- deduplicating repeated handling of the same n8n execution failure when a stable execution identity exists;
- inserting or reusing one `error_log` row for the handled occurrence;
- creating or reusing one deterministic `notify_operator_intervention` operation per error record;
- atomically claiming the notification operation before Gmail activity;
- reconciling an ambiguous previous notification by a deterministic Gmail marker;
- sending a minimized intervention message to the configured operator mailbox;
- storing the Gmail message identifier and sanitized result;
- persisting retryable or terminal notification failure;
- preventing recursive error-handler loops;
- returning only sanitized internal results.

## 3. Explicit non-responsibilities

WF99 must not:

- create onboarding cases;
- generate or consume client form tokens;
- create or validate client submissions;
- create or update canonical client data;
- approve or reject cases;
- provision clients;
- create Drive folders or Calendar events;
- retry external business operations directly;
- infer a business-state transition from an exception;
- mark a case completed, rejected, approved, provisioned, or failed without a state-specific workflow contract;
- store complete input items, request bodies, response bodies, headers, credentials, tokens, encryption material, response links, or mailbox content;
- create an intervention notification for routine successful, rejected, duplicated, or retry-scheduled business outcomes;
- recursively invoke itself without a strict termination rule;
- treat n8n execution history as the authoritative error record.

## 4. Trigger and invocation variants

WF99 accepts exactly one of three invocation variants:

- n8n Error Trigger input;
- explicit normalized internal error input;
- WF98 retry input for an intervention-notification operation.

Unknown top-level fields must be ignored or rejected according to the variant. They must never be copied wholesale into `error_details`.

## 5. n8n Error Trigger input

### 5.1 Trigger

WF99 is configured as the n8n error workflow for business workflows that require central error handling.

The Error Trigger payload is treated as untrusted technical input because it may contain:

- complete workflow items;
- request bodies;
- headers;
- credentials or credential references;
- plain form tokens;
- token-bearing URLs;
- provider responses;
- stack traces containing sensitive values.

WF99 must never persist the complete Error Trigger payload.

### 5.2 Allowed extracted fields

WF99 may extract only safe values equivalent to:

```json
{
  "source_variant": "n8n_error_trigger",
  "workflow_name": "WF05 — Provision Client",
  "workflow_id": "workflow-id",
  "execution_id": "execution-id",
  "execution_url_present": true,
  "error_name": "NodeApiError",
  "error_message": "Sanitized technical summary",
  "node_name": "Call Mock Provisioning API",
  "occurred_at": "2026-07-18T20:00:00Z"
}
```

The execution URL itself is not stored when it may contain deployment details. A boolean indicating availability is sufficient for the initial contract.

### 5.3 Context references

Case, correlation, step, submission, and external-operation identifiers may be extracted only when they are already present as explicit safe scalar workflow context.

WF99 must validate them against PostgreSQL before using them as foreign-key references.

WF99 must not search arbitrary input data for UUID-looking strings and assume their meaning.

## 6. Explicit normalized internal input

A business workflow may explicitly invoke WF99 with:

```json
{
  "source_variant": "explicit_internal",
  "source_workflow_name": "WF05 — Provision Client",
  "source_workflow_id": "workflow-id",
  "source_execution_id": "execution-id",
  "case_id": "00000000-0000-0000-0000-000000000000",
  "correlation_id": "00000000-0000-0000-0000-000000000000",
  "step_id": "00000000-0000-0000-0000-000000000000",
  "submission_id": null,
  "external_operation_id": "00000000-0000-0000-0000-000000000000",
  "error_class": "integration_failure",
  "error_code": "PROVISIONING_REJECTED",
  "error_message": "Provisioning request was rejected permanently",
  "retryable": false,
  "severity": "error",
  "requires_intervention": true,
  "error_details": {
    "provider": "mock-provisioning-api",
    "http_status": 422,
    "attempt_count": 1
  }
}
```

Rules:

- `source_variant` must equal `explicit_internal`;
- `source_workflow_name` is required and non-blank;
- `error_class` and `error_message` are required and non-blank;
- `retryable`, `severity`, and `requires_intervention` are required;
- identifier fields are optional UUID strings or `null`;
- `error_details` is an optional JSON object;
- unknown top-level fields are rejected;
- no plain tokens, URLs containing bearer tokens, credentials, or complete provider payloads are accepted.

The source workflow must sanitize before calling WF99. WF99 performs a second independent sanitization pass.

## 7. WF98 retry input

WF98 invokes WF99 for a due or stale `notify_operator_intervention` operation using:

```json
{
  "source_variant": "notification_retry",
  "trigger_source": "wf98",
  "external_operation_id": "00000000-0000-0000-0000-000000000000"
}
```

WF99 must load the operation and verify:

- it exists;
- `operation_type = 'notify_operator_intervention'`;
- its immutable `request_summary` contains a valid `error_id`;
- the referenced error record exists;
- the operation is due, stale, succeeded, terminal, exhausted, or busy according to `claim_external_operation`.

WF98 input must not supply error text, recipient, case data, or message content.

## 8. Reference validation

Before inserting an error row, WF99 validates supplied references.

### 8.1 Case reference

When `case_id` is supplied:

- the case must exist;
- the persisted `correlation_id` must equal the supplied correlation identifier when both are present;
- the authoritative correlation identifier is loaded from the case.

A missing case or correlation mismatch is itself a data-integrity failure. WF99 must avoid inserting an invalid foreign key.

### 8.2 Step reference

A supplied `step_id` must exist and belong to the supplied case when a case is present.

### 8.3 Submission reference

A supplied `submission_id` must exist and belong to the supplied case when a case is present.

### 8.4 External-operation reference

A supplied `external_operation_id` must exist and belong to the supplied case when the operation is case-bound.

For an intervention-notification retry, the external operation is the notification operation itself and may have a null case when the source error is not case-specific.

### 8.5 Invalid optional reference

WF99 must not fail the complete error-record insertion merely because an optional context reference cannot be verified.

It must:

- omit the invalid foreign-key reference;
- record a safe detail code such as `context_reference_invalid`;
- increase severity to `critical` when the mismatch indicates persisted-data corruption;
- avoid storing the unverified identifier as an authoritative foreign key.

## 9. Sanitization contract

### 9.1 Error message

The stored `error_message` is a concise operational summary.

Initial maximum length:

```text
1000 characters
```

WF99 removes or replaces:

- control characters;
- authorization header values;
- bearer tokens;
- OAuth tokens;
- API keys;
- passwords;
- database connection strings;
- URLs containing `token`, `code`, `secret`, `signature`, or authorization query parameters;
- unbounded SQL text;
- complete stack traces;
- complete JSON payloads.

### 9.2 Error code and class

`error_class` and `error_code` use stable lowercase or provider-defined safe identifiers.

They must not contain personal data or credentials.

Initial `error_class` values include:

- `database_failure`;
- `integration_failure`;
- `configuration_failure`;
- `authentication_failure`;
- `authorization_failure`;
- `rate_limit_failure`;
- `timeout_failure`;
- `network_failure`;
- `data_integrity_failure`;
- `idempotency_conflict`;
- `security_failure`;
- `workflow_failure`;
- `dispatch_failure`;
- `reconciliation_failure`;
- `unknown_failure`.

### 9.3 Error details

`error_details` is an allowlisted JSON object.

Allowed value types are:

- string;
- number;
- boolean;
- `null`;
- bounded arrays of safe scalar values;
- bounded nested objects with an initial maximum depth of two.

Allowed detail keys may include:

- `node_name`;
- `provider`;
- `http_status`;
- `provider_error_code`;
- `attempt_count`;
- `max_attempts`;
- `next_retry_at`;
- `operation_type`;
- `lease_state`;
- `dispatch_destination`;
- `context_reference_invalid`;
- `requires_intervention`;
- `source_variant`.

Disallowed values include:

- complete request or response bodies;
- complete headers;
- submitted client data;
- form tokens and token hashes;
- token ciphertext, nonce, authentication tag, or encryption key identifier;
- approval response URLs;
- Gmail, Drive, Calendar, CRM, or database credentials;
- email bodies;
- complete stack traces;
- arbitrary workflow input items.

### 9.4 Personal data minimization

WF99 stores identifiers needed for diagnosis, not duplicate client data.

Company name, contact name, email, phone, and company identifier are not copied into `error_details` unless a future documented incident-response requirement explicitly permits a minimized subset.

## 10. Classification contract

### 10.1 Source classification

An explicit internal call may propose classification, but WF99 validates it against the safe input.

The n8n Error Trigger path derives classification from:

- error type;
- source workflow and node;
- safe provider status and code;
- linked operation state;
- known contract rules.

### 10.2 Retryable classification

Typical retryable classes:

- temporary network failure;
- timeout;
- HTTP 429;
- HTTP 502, 503, or 504;
- transient provider unavailability;
- dispatch acceptance failure whose source state remains recoverable.

A technical error may be retryable while the associated operation has already persisted its own `failed_retryable` schedule. WF99 does not schedule that business-operation retry again.

### 10.3 Non-retryable classification

Typical non-retryable classes:

- invalid configuration;
- HTTP 401 or 403 requiring credential or permission correction;
- data-integrity mismatch;
- idempotency-key conflict;
- token decryption or authentication failure;
- unknown operation type;
- maximum attempts exhausted;
- unreconcilable ambiguous side effect;
- security-policy violation;
- malformed workflow contract.

### 10.4 Unknown errors

An error that cannot be classified safely uses:

```text
error_class = unknown_failure
retryable = false
severity = error
requires_intervention = true
```

WF99 must not perform an uncontrolled retry based on optimism.

## 11. Severity contract

Allowed values match the database constraint:

- `warning`;
- `error`;
- `critical`.

### 11.1 Warning

Use for recoverable technical conditions that are already scheduled safely and do not require immediate human action.

### 11.2 Error

Use for a failed workflow execution or integration operation requiring investigation but not indicating platform-wide corruption or secret exposure.

### 11.3 Critical

Use for:

- credential or permission failure blocking processing;
- data-integrity mismatch;
- idempotency conflict;
- duplicate or ambiguous external side effect;
- maximum attempts exhausted;
- lost approval waiting execution;
- security or potential secret-exposure incident;
- central persistence failure detected outside the normal insertion path.

## 12. Intervention requirement

WF99 creates an operator notification only when at least one condition is true:

- `requires_intervention = true` from a validated explicit call;
- severity is `critical`;
- retryability is false and the workflow cannot complete safely without configuration or operator action;
- the associated external operation is terminal or exhausted;
- an external side effect is ambiguous or duplicated;
- a security or data-integrity failure occurred;
- a workflow dispatch failure left persisted business state requiring manual recovery.

WF99 does not notify for:

- normal validation failure;
- approval rejection;
- unauthorized form-token use handled as a security outcome without technical failure;
- duplicate input handled successfully;
- busy or not-due operation claim;
- a routine retryable failure already scheduled and not requiring immediate intervention;
- successful recovery or reconciliation.

## 13. Error occurrence identity and deduplication

### 13.1 Stable occurrence fingerprint

When a stable source execution identifier exists, WF99 builds:

```text
<source_workflow_name>|<source_execution_id>|<error_class>|<error_code>|<external_operation_id-or-empty>
```

It calculates SHA-256 of the UTF-8 value and derives a signed 64-bit advisory-lock key from the first eight bytes.

### 13.2 Transaction-level advisory lock

WF99 obtains a PostgreSQL transaction advisory lock for the occurrence fingerprint before checking and inserting `error_log`.

This serializes concurrent duplicate handling without changing the current schema.

### 13.3 Existing occurrence lookup

Under the advisory lock, WF99 searches for an existing row with the same:

- workflow name;
- execution identifier;
- error class;
- error code using null-safe comparison;
- external operation identifier using null-safe comparison.

When found, WF99 reuses the existing `error_id` and does not insert a duplicate row.

### 13.4 No stable execution identity

When no stable execution identifier exists, WF99 treats the call as a new error occurrence.

It must not deduplicate unrelated failures solely by message text.

### 13.5 Error immutability

After insertion, the initial contract does not update or delete `error_log` rows.

Later recovery is represented by operation state and future error occurrences, not by rewriting history.

## 14. Error persistence transaction

WF99 executes one transaction that:

1. validates safe references;
2. determines the authoritative correlation identifier;
3. acquires the occurrence advisory lock when possible;
4. reuses an existing matching error row when found;
5. otherwise inserts one `error_log` row;
6. commits;
7. returns the authoritative `error_id`.

The inserted fields are:

- verified foreign-key references when available;
- source workflow name, ID, and execution ID;
- normalized error class, code, and message;
- retryability;
- severity;
- sanitized details;
- authoritative correlation identifier when available;
- database occurrence time.

A notification must never be attempted before the error record commits.

## 15. Error persistence failure and recursion guard

### 15.1 No recursive WF99 invocation

WF99 must not configure itself to invoke itself as its own error workflow.

A failure inside WF99 must not recursively create another normal WF99 execution.

### 15.2 Database unavailable

When WF99 cannot write `error_log`:

- do not attempt to create an intervention operation in the same database;
- write one minimal sanitized message to n8n process logging or platform stderr;
- include only workflow name, execution identifier, safe error class, and timestamp;
- return or fail without recursion;
- never log original payloads, tokens, credentials, or complete stack traces.

This is the last-resort path and is verified operationally outside PostgreSQL.

### 15.3 Notification-path error

A failure while processing `notify_operator_intervention` is persisted in that operation when possible.

WF99 must not create a new intervention error whose only purpose is to notify about the same notification failure repeatedly.

The existing operation reaches `failed_retryable` or `failed_terminal` according to its bounded attempt policy.

## 16. Intervention-notification operation

### 16.1 Operation type

```text
notify_operator_intervention
```

### 16.2 Deterministic idempotency key

```text
error:<error_id>:notify-operator-intervention
```

Each error record has at most one logical intervention notification.

### 16.3 Case association

The operation `case_id` equals the verified error case identifier when present.

It may be null for infrastructure or dispatcher errors that are not case-specific.

### 16.4 Immutable request summary

```json
{
  "error_id": "00000000-0000-0000-0000-000000000000",
  "recipient_email": "operator@example.com",
  "template_key": "operator_intervention_v1",
  "severity": "critical",
  "source_workflow_name": "WF05 — Provision Client",
  "case_id": "00000000-0000-0000-0000-000000000000",
  "correlation_id": "00000000-0000-0000-0000-000000000000",
  "message_marker": "b2b-error-0123456789abcdef01234567"
}
```

Nullable context values may be omitted.

The request summary must not contain:

- complete error details;
- original exception payload;
- credentials;
- form tokens;
- client data;
- provider request or response bodies;
- stack traces.

### 16.5 Message marker

WF99 derives:

```text
b2b-error-<first 24 lowercase hexadecimal characters of SHA-256(idempotency_key UTF-8 bytes)>
```

The marker appears in a reliably searchable part of the notification message.

## 17. Notification configuration

Protected configuration:

```text
OPERATOR_INTERVENTION_RECIPIENT_EMAIL
OPERATOR_INTERVENTION_SENDER_NAME
OPERATOR_INTERVENTION_TEMPLATE_KEY=operator_intervention_v1
WF99_NOTIFICATION_LEASE_SECONDS=300
WF99_NOTIFICATION_MAX_ATTEMPTS=5
```

The recipient is not accepted from caller input.

Gmail authentication remains in an n8n credential.

Configuration is validated before creating or claiming the notification operation.

An invalid recipient or missing credential is terminal and uses the recursion-safe last-resort logging path after persisting the original error when possible.

## 18. Atomic notification claim

WF99 calls `claim_external_operation` with:

- deterministic notification idempotency key;
- operation type `notify_operator_intervention`;
- verified optional case identifier;
- lease owner `WF99:<n8n_execution_id>`;
- lease duration 300 seconds;
- maximum attempts 5;
- immutable request summary.

### 18.1 `claimed`

The current execution owns the lease and may reconcile or send the Gmail notification.

### 18.2 `reuse_succeeded`

No new email is sent. WF99 verifies the stored message result and returns `notification_already_sent`.

### 18.3 `busy`

Another worker owns a valid lease. Return `notification_busy`.

### 18.4 `not_due`

The retry time has not arrived. Return `notification_not_due`.

### 18.5 `refused_terminal` or `refused_exhausted`

No automatic send is allowed. Return `notification_failed_terminal` and use minimal recursion-safe platform logging when required.

## 19. Notification message contract

The message may contain:

- error identifier;
- severity;
- source workflow name;
- safe error class and code;
- concise sanitized message;
- case and correlation identifiers when available;
- external operation identifier and type when available;
- attempt count and terminal status when available;
- occurrence time;
- a concise recommended operator action;
- deterministic message marker.

It must not contain:

- plain form tokens or token hashes;
- token ciphertext or encryption material;
- approval response links;
- credentials or authorization headers;
- complete client submission or canonical client data;
- complete provider payloads;
- complete stack traces;
- raw n8n input items.

The subject includes severity and error identifier, for example:

```text
[B2B Onboarding][CRITICAL] Intervention required — <error_id>
```

## 20. Gmail reconciliation

Before sending after an expired lease or ambiguous previous execution, WF99 searches Sent mail by the deterministic message marker.

Outcomes:

- exactly one match: reuse the existing Gmail message identifier and persist success;
- no match: send while owning the valid lease;
- more than one match: terminal ambiguity; do not send another message;
- Gmail search unavailable: retryable notification failure; do not assume absence.

A new first attempt may also reconcile before send when practical.

## 21. Notification success transaction

After Gmail acceptance or successful reconciliation, WF99:

1. verifies the operation is `in_progress`;
2. verifies the current execution owns a non-expired lease;
3. validates a non-blank Gmail message identifier;
4. calls `complete_external_operation_success`;
5. stores the Gmail identifier as `external_id`;
6. stores a sanitized response summary;
7. commits.

Sanitized response summary:

```json
{
  "provider": "gmail",
  "message_id": "gmail-message-id",
  "thread_id": "gmail-thread-id",
  "message_marker": "b2b-error-0123456789abcdef01234567",
  "accepted_at": "2026-07-18T20:00:00Z",
  "template_key": "operator_intervention_v1"
}
```

## 22. Notification failure contract

### 22.1 Retryable failures

Examples:

- HTTP 429;
- HTTP 502, 503, or 504;
- network timeout;
- temporary DNS failure;
- temporary Gmail unavailability;
- temporary reconciliation-search failure.

WF99 calls `complete_external_operation_failure` with `retryable = true` and sets `next_retry_at`.

Initial retry policy:

```text
attempt 1 failure → retry after 1 minute
attempt 2 failure → retry after 5 minutes
attempt 3 failure → retry after 15 minutes
attempt 4 failure → retry after 1 hour
attempt 5 failure → terminal failure
```

WF98 later dispatches due notification retries.

### 22.2 Terminal failures

Examples:

- Gmail 401 or 403;
- invalid configured recipient;
- multiple reconciliation matches;
- operation request-summary mismatch;
- maximum attempts exhausted;
- permanent provider rejection.

WF99 marks the notification operation terminal while owning the lease.

It does not create another notification operation for the same error.

## 23. Technical errors versus business events

WF99 writes technical failures to `error_log`.

It does not insert an `onboarding_events` row merely because an error occurred or an intervention email was sent.

Business events remain owned by WF01–WF06.

This preserves the architecture rule that business events and technical errors remain separate.

## 24. Output contract

### 24.1 Error recorded without notification

```json
{
  "workflow": "WF99",
  "result": "error_recorded",
  "error_id": "00000000-0000-0000-0000-000000000000",
  "notification": "not_required"
}
```

### 24.2 Notification sent

```json
{
  "workflow": "WF99",
  "result": "error_recorded",
  "error_id": "00000000-0000-0000-0000-000000000000",
  "notification": "sent",
  "external_operation_id": "00000000-0000-0000-0000-000000000000"
}
```

### 24.3 Reused error occurrence

```json
{
  "workflow": "WF99",
  "result": "error_reused",
  "error_id": "00000000-0000-0000-0000-000000000000",
  "notification": "already_sent"
}
```

### 24.4 Other notification results

Allowed notification results include:

- `not_required`;
- `sent`;
- `already_sent`;
- `busy`;
- `not_due`;
- `failed_retryable`;
- `failed_terminal`;
- `persistence_unavailable`.

Output must not contain credentials, tokens, error stack traces, complete error details, client data, email body, or full provider responses.

## 25. Transaction boundaries

### 25.1 Error persistence transaction

Validates references, deduplicates by advisory lock when possible, and inserts or reuses the error row.

### 25.2 Notification claim transaction

Atomically creates or reuses and claims the notification operation.

### 25.3 Gmail activity

Reconciliation and send occur outside PostgreSQL transactions while the worker owns a valid lease.

### 25.4 Notification result transaction

Atomically persists success or bounded failure.

No database transaction is held while calling Gmail.

## 26. Concurrency contract

### 26.1 Duplicate Error Trigger delivery

When the same workflow execution error reaches WF99 concurrently:

- both executions derive the same occurrence fingerprint;
- the advisory lock serializes persistence;
- one error row is inserted;
- both resolve the same error identifier;
- one notification operation exists;
- only one valid notification lease owner may send.

### 26.2 Concurrent explicit and Error Trigger calls

They deduplicate only when they share the same stable workflow execution identity, classification, code, and operation context.

Otherwise they remain separate error occurrences.

### 26.3 Concurrent notification retries

Only one WF99 execution claims the operation. Others return `busy` or authoritative success.

### 26.4 Crash after Gmail send

After lease expiry, the next execution searches Sent mail by marker and persists the existing message without sending again.

## 27. Security and privacy

- WF99 is not a general log sink for raw workflow data;
- input sanitization uses an allowlist, not a denylist alone;
- plain tokens, encryption material, credentials, response links, and complete payloads are never persisted;
- operator notifications contain only minimized diagnostic context;
- recipient configuration is protected and cannot be overridden by callers;
- database and Gmail credentials remain outside Git;
- recursion protection prevents notification failures from generating infinite error workflows;
- normal logs contain safe identifiers and classifications only;
- retained n8n execution data must not contain original sensitive Error Trigger payloads after the sanitization node.

## 28. Logical execution order

For a new error occurrence:

```text
1. Receive Error Trigger or explicit internal input
2. Detect and reject recursive self-error handling
3. Extract allowlisted scalar context
4. Sanitize message and details
5. Validate optional PostgreSQL references
6. Classify error, severity, retryability, and intervention requirement
7. Deduplicate and persist error under advisory lock
8. If intervention not required, return sanitized result
9. Build deterministic notification operation identity
10. Claim notification operation atomically
11. Handle no-send claim outcomes
12. Reconcile Sent mail when required
13. Send minimized Gmail notification only when no prior message exists
14. Persist notification success or bounded failure
15. Return sanitized result
```

For a WF98 notification retry:

```text
1. Receive external operation identifier
2. Load and verify notification operation and source error
3. Claim operation atomically
4. Reconcile Sent mail
5. Send only if no prior message exists
6. Persist success or bounded failure
7. Never create a new source error solely for the same notification failure
```

## 29. Acceptance scenarios

### 29.1 Retryable workflow error without intervention

Expected one sanitized error row, no notification operation, and no business-state change.

### 29.2 Terminal integration failure

Expected one error row, one notification operation, one Gmail notification, and no direct case transition by WF99.

### 29.3 Critical data-integrity mismatch

Expected critical non-retryable error, intervention notification, and no blind repair.

### 29.4 Duplicate Error Trigger delivery

Expected one error row and at most one notification email.

### 29.5 Explicit call plus Error Trigger for same execution

Expected one row only when the stable occurrence identity matches exactly.

### 29.6 Error without execution identifier

Expected a new error occurrence; no unsafe deduplication by message text.

### 29.7 Invalid optional step reference

Expected error row without invalid foreign key, safe context-reference warning, and critical severity when integrity is affected.

### 29.8 Routine validation failure

Expected no WF99 invocation under normal contracts and no operator notification.

### 29.9 Approval rejection

Expected no technical error record or intervention notification.

### 29.10 Gmail notification transient failure

Expected notification operation `failed_retryable`, due retry time, and source error preserved.

### 29.11 Gmail notification credential failure

Expected notification operation terminal, no recursive WF99 loop, and minimal safe platform log.

### 29.12 Crash after notification send

Expected retry reconciliation finds one sent message and does not send another.

### 29.13 Multiple Gmail marker matches

Expected terminal ambiguity and no additional message.

### 29.14 PostgreSQL unavailable during WF99

Expected no recursion, no attempt to create a database-backed notification, and one minimal sanitized platform log.

### 29.15 Sensitive Error Trigger payload

Given input containing authorization headers, form tokens, client data, and stack traces, expected persisted record contains none of those values.

### 29.16 Notification retry from WF98

Expected WF99 loads the source error from operation summary and never trusts error text from WF98.

### 29.17 Business-state isolation

Across all scenarios, WF99 does not independently change onboarding case state or business steps.

## 30. Implementation gate for WF99

The WF99 contract is satisfied only when implementation tests prove:

- n8n Error Trigger handling;
- explicit normalized invocation handling;
- WF98 notification-retry handling;
- strict allowlist sanitization;
- verified optional foreign-key references;
- stable classification, severity, and intervention rules;
- advisory-lock occurrence deduplication;
- one error row for duplicate delivery with stable identity;
- deterministic notification operation identity;
- atomic notification claims and bounded retries;
- Gmail marker reconciliation;
- no duplicate notification after interrupted execution;
- no operator notification for normal business outcomes;
- recursion-safe behavior when WF99 or PostgreSQL fails;
- no independent case-state transitions;
- direct PostgreSQL verification;
- absence of credentials, tokens, encryption material, response links, complete client data, complete provider payloads, and stack traces from error rows, operations, messages, logs, output, and retained execution data.

The final cross-workflow contract review must pass before Stage 6 begins.
