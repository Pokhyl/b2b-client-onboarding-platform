# WF02 — Request Client Data

## 1. Purpose

WF02 creates or reuses one secure client-data request cycle for an onboarding case, sends the corresponding n8n form link through Gmail, and advances the authoritative onboarding state only after the outbound message is confirmed by the Gmail integration.

PostgreSQL remains the source of truth for the onboarding case, request cycle, token lifecycle, `collect_client_data` step, outbound operation, retries, events, and errors. n8n coordinates the work but must not use execution history as the authoritative record.

## 2. Responsibilities

WF02 is responsible for:

- accepting a trusted internal invocation from WF01, WF03, or WF98;
- validating the internal payload and rereading all authoritative data from PostgreSQL;
- verifying the case state, correlation identifier, request-cycle identity, and correction submission where applicable;
- creating or reusing exactly one form token for the request cycle;
- generating cryptographically secure token material only when a token row is first created;
- storing a SHA-256 token hash and temporary AES-GCM-encrypted delivery material;
- creating or reusing one deterministic `send_client_data_request` operation;
- claiming that operation atomically before Gmail activity;
- decrypting the token only in memory to build the production form URL;
- reconciling a possibly completed Gmail send before repeating an external side effect;
- storing a sanitized Gmail result and message identifier;
- marking the token `delivered` and clearing encrypted material only after confirmed Gmail success;
- conditionally moving the case from `created` or `validation_failed` to `awaiting_client_data`;
- maintaining the `collect_client_data` step;
- recording deterministic business events;
- classifying retryable and terminal failures;
- leaving retry discovery to WF98 and unexpected-error normalization to WF99.

## 3. Explicit non-responsibilities

WF02 must not:

- expose a public webhook or accept a client form submission;
- create or replace an onboarding case;
- create or update canonical `clients` data;
- consume a form token or create an `onboarding_submissions` row;
- validate submitted business data;
- move a case to `data_received`, `validation_failed`, or `awaiting_approval`;
- request manual approval, provision a client, or create finalization resources;
- repeat a successful Gmail side effect;
- store a plain form token in PostgreSQL, Git, events, operations, error records, normal logs, or workflow output;
- use n8n execution history as proof that an email was sent.

## 4. Trigger and invocation model

### 4.1 Internal trigger

WF02 is started only as an n8n sub-workflow from:

- WF01 after a committed initial intake;
- WF03 after a persisted submission fails validation;
- WF98 when a failed client-data-request operation becomes due.

WF02 must not expose a public Webhook Trigger.

### 4.2 Initial invocation from WF01

```json
{
  "case_id": "00000000-0000-0000-0000-000000000000",
  "correlation_id": "00000000-0000-0000-0000-000000000000",
  "trigger_source": "wf01",
  "request_cycle_key": "initial"
}
```

Rules:

- `case_id` and `correlation_id` are required UUID strings;
- `trigger_source` must equal `wf01`;
- `request_cycle_key` must equal `initial`;
- `failed_submission_id` and `external_operation_id` must not be present.

### 4.3 Correction invocation from WF03

```json
{
  "case_id": "00000000-0000-0000-0000-000000000000",
  "correlation_id": "00000000-0000-0000-0000-000000000000",
  "trigger_source": "wf03",
  "request_cycle_key": "validation_failed:00000000-0000-0000-0000-000000000000",
  "failed_submission_id": "00000000-0000-0000-0000-000000000000"
}
```

Rules:

- `trigger_source` must equal `wf03`;
- `failed_submission_id` is required and must be a UUID;
- `request_cycle_key` must equal `validation_failed:<failed_submission_id>`;
- `external_operation_id` must not be present.

WF02 must verify that the submission exists, belongs to the case, and has `validation_status = 'failed'`. Submitted field values must not be copied into the correction email, events, operation summaries, or output.

### 4.4 Retry invocation from WF98

```json
{
  "case_id": "00000000-0000-0000-0000-000000000000",
  "correlation_id": "00000000-0000-0000-0000-000000000000",
  "trigger_source": "wf98",
  "external_operation_id": "00000000-0000-0000-0000-000000000000"
}
```

Rules:

- `trigger_source` must equal `wf98`;
- `external_operation_id` is required;
- `request_cycle_key` and `failed_submission_id` must not be supplied.

WF02 must load the operation and verify that it belongs to the case, has `operation_type = 'send_client_data_request'`, and is eligible for claim. Token and request-cycle references must be taken from the immutable operation summary, not from caller input.

### 4.5 Internal input validation

Unknown fields are rejected. Supplied identifiers are non-authoritative. WF02 must independently read the case, persisted `correlation_id`, case state, intake email, step, token, operation, and failed submission where applicable.

A correlation mismatch is a non-retryable data-integrity failure. Gmail must not be called.

## 5. Authoritative state preconditions

### 5.1 Initial request

```text
case.state = created
trigger_source = wf01
request_cycle_key = initial
```

### 5.2 Correction request

```text
case.state = validation_failed
trigger_source = wf03
request_cycle_key = validation_failed:<failed_submission_id>
```

### 5.3 Retry

A retry may proceed only when `claim_external_operation` confirms that the stored operation is claimable. The case must still match the request cycle:

- `created` before successful initial delivery;
- `validation_failed` before successful correction delivery;
- `awaiting_client_data` only when the same operation is already `succeeded`.

### 5.4 Already delivered request

When the case is `awaiting_client_data`, WF02 may return `already_delivered` only when the same request cycle has:

- a token with status `delivered`;
- a `send_client_data_request` operation with status `succeeded`;
- consistent token, operation, and case references.

A partial or contradictory combination is a persisted-data inconsistency. WF02 must not send another email or repair it blindly.

### 5.5 Advanced or terminal case

For `data_received`, `awaiting_approval`, `rejected`, `approved`, `provisioning`, `provisioning_failed`, `provisioned`, `finalizing`, `finalization_failed`, or `completed`, WF02 must return `not_required` without creating a token, sending Gmail, or changing state.

### 5.6 Invalid invocation

Invalid source/state/cycle combinations must produce `invalid_internal_invocation`, make no business changes, and be sent to WF99 as a sanitized non-retryable technical or data-integrity failure.

## 6. Authoritative PostgreSQL data

WF02 must read at least:

- case `id`, `correlation_id`, `state`, `intake_contact_email`, `source_system`, and `source_deal_id`;
- the case's `collect_client_data` step;
- the failed submission for a correction request;
- the token and operation for the active request cycle.

The Gmail recipient must come from:

```text
onboarding_cases.intake_contact_email
```

The value is non-authoritative intake data used only before validated client data exists. It must be trimmed and non-blank. WF02 must not silently substitute another address.

## 7. Request-cycle identity

The initial cycle is:

```text
initial
```

Each failed submission creates one correction cycle:

```text
validation_failed:<failed_submission_id>
```

PostgreSQL enforces one token per `(case_id, request_cycle_key)`. Repeated invocation for the same cycle must reuse the same token row.

Before creating a new token, WF02 must lock the case and inspect active tokens. An active token for the same cycle is reused. A different non-expired active token blocks creation. Expired active tokens may be transitioned to `expired` and cleared. WF02 must not revoke an unrelated active token merely to make an insert succeed.

## 8. Token generation and cryptography

### 8.1 Plain token

For a new request cycle, generate 32 cryptographically secure random bytes and encode them as unpadded Base64URL.

The plain token must never be persisted or returned.

### 8.2 Hash

Store:

```text
SHA-256(original random bytes)
```

as exactly 32 bytes in `onboarding_form_tokens.token_hash`. The Base64URL text must not be hashed instead of the original bytes.

### 8.3 Temporary encryption

Encrypt the same token bytes with AES-256-GCM and store:

- `token_ciphertext`;
- `token_nonce`;
- `token_auth_tag`;
- `encryption_key_id`.

Requirements:

- a new secure 12-byte nonce per encryption;
- the 32-byte encryption key remains outside PostgreSQL;
- authenticated additional data binds `case_id`, `token_id`, and `request_cycle_key`;
- the same additional data is reconstructed during decryption.

### 8.4 Expiry

Initial lifetime:

```text
72 hours
```

`expires_at` is based on database time and is immutable.

### 8.5 Token preparation transaction

One PostgreSQL transaction must:

1. lock the case;
2. verify state and correlation;
3. lock the collection step;
4. expire eligible stale active tokens;
5. select by `(case_id, request_cycle_key)`;
6. insert a new `issued` token only when absent;
7. resolve unique conflicts by rereading;
8. return the authoritative token;
9. prepare the step for the cycle;
10. insert the token-issued event when a token was created.

The transaction must not include Gmail.

### 8.6 Reusing an issued token

An existing `issued` token must be decrypted from stored ciphertext. WF02 must not create replacement token material for the same cycle. Decryption or authentication failure is terminal and must not be bypassed by creating another token.

### 8.7 Allowed token transitions

WF02 may perform:

```text
issued → delivered
issued → expired
issued → revoked
```

Token consumption belongs to WF03.

## 9. `collect_client_data` step contract

The step represents the current collection cycle.

Because the schema reserves `waiting` for manual approval, WF02 uses:

- `in_progress` while delivery is active or the system is waiting for the client;
- `failed_retryable` after a retryable delivery failure;
- `failed_terminal` when the cycle cannot be delivered automatically;
- `completed` only after WF03 consumes a valid token and stores the submission.

For a genuinely new request cycle, WF02 must:

- set `status = 'in_progress'`;
- increment `attempt_count` by one;
- set or refresh `started_at` for the new cycle;
- clear `completed_at`;
- clear `last_error_summary`.

The step attempt count represents request cycles. Gmail attempts are counted in `external_operations.attempt_count`.

A retry of the same operation must not increment the step attempt count. After successful email delivery, the step remains `in_progress` until WF03 receives an authorized submission.

A retryable failure sets `failed_retryable` with a sanitized error summary and retry time. A terminal failure sets `failed_terminal` and `completed_at`.

## 10. External-operation identity

Operation type:

```text
send_client_data_request
```

Deterministic idempotency key:

```text
onboarding:<case_id>:form-token:<token_id>:send-client-data-request
```

A new correction token creates a new key. A retry of the same token reuses the same key.

The immutable `request_summary` contains only recovery data:

```json
{
  "token_id": "00000000-0000-0000-0000-000000000000",
  "request_cycle_key": "initial",
  "recipient_email": "anna.kowalska@example.com",
  "template_key": "client_data_request_v1",
  "message_marker": "b2b-onboarding-0123456789abcdef01234567"
}
```

Correction cycles use `client_data_correction_v1`.

The summary must not contain plain token material, encrypted fields, form URL, email body, submitted values, credentials, headers, or cookies.

### 10.1 Message marker

Derive a non-secret Gmail reconciliation marker:

```text
b2b-onboarding-<first 24 lowercase hex characters of SHA-256(idempotency_key UTF-8 bytes)>
```

The marker must be included in a reliably searchable part of the outbound message. It must not reveal the token.

## 11. Atomic operation claim

WF02 must call `claim_external_operation` with the deterministic key, operation type, case ID, lease owner, lease duration, maximum attempts, and immutable request summary.

Initial values:

```text
lease duration: 300 seconds
maximum attempts: 5
lease owner: WF02:<n8n_execution_id>
```

Handle all outcomes:

- `claimed` — current execution may reconcile or send;
- `reuse_succeeded` — do not send; verify persisted success and return `already_delivered`;
- `busy` — do not send or modify; return `busy`;
- `not_due` — do not send; return `not_due`;
- `refused_terminal` — return `failed_terminal`;
- `refused_exhausted` — reconcile to terminal failure and require intervention.

Only the valid lease owner may perform Gmail reconciliation, send Gmail, or mark the operation result. An execution whose lease expired must stop.

## 12. Form URL contract

Protected configuration:

```text
CLIENT_DATA_FORM_BASE_URL
```

It must point to the production WF03 n8n Form Trigger URL. A test URL must not be sent to clients.

Construct:

```text
<CLIENT_DATA_FORM_BASE_URL>?token=<URL-encoded Base64URL token>
```

Use a URL API or equivalent deterministic encoder so existing query parameters are handled correctly.

The URL must not include case ID, correlation ID, email, company name, source deal ID, failed-submission data, or other database identifiers. The opaque token is the authorization mechanism.

Immediately before reconciliation or send, verify from PostgreSQL:

```text
token.status = issued
token.expires_at > current database time
```

An issued token that expires before confirmed delivery becomes `expired`, encrypted material is cleared, Gmail is not sent, and the same cycle does not silently receive a replacement token.

## 13. Gmail contract

Gmail credentials remain in an n8n credential. Passwords, OAuth tokens, client secrets, and authorization headers must not appear in workflow JSON.

Recipient:

```text
onboarding_cases.intake_contact_email
```

The initial implementation sends to one recipient with no CC or BCC.

### 13.1 Initial template

Template key:

```text
client_data_request_v1
```

The message includes:

- a clear request for onboarding data;
- the secure form link;
- expiry information;
- a single-use notice;
- the deterministic reference marker;
- configured support contact where applicable.

It must not claim that CRM data has been validated.

### 13.2 Correction template

Template key:

```text
client_data_correction_v1
```

It may include sanitized field labels and stable validation descriptions. It must not include previously submitted values, stack traces, SQL errors, or complete validation JSON.

### 13.3 Success definition

Confirmed Gmail delivery means the Gmail node or API accepted the send and returned a non-blank message ID without an error. It does not mean the recipient opened the email or that inbox placement was guaranteed.

A successful sanitized response may contain:

```json
{
  "provider": "gmail",
  "message_id": "provider-message-id",
  "thread_id": "provider-thread-id",
  "message_marker": "b2b-onboarding-0123456789abcdef01234567",
  "accepted_at": "2026-07-18T20:00:00Z",
  "template_key": "client_data_request_v1"
}
```

It must not contain token material, form URL, complete email body, mailbox contents, OAuth data, or complete provider headers.

## 14. Gmail reconciliation before send

A worker may stop after Gmail accepted the message but before PostgreSQL committed success. Repeating the send without reconciliation can duplicate the email.

After reclaiming an expired lease or recovering an ambiguous execution, WF02 must search the configured Gmail Sent mailbox by message marker.

Outcomes:

- exactly one match — use its Gmail ID and finalize PostgreSQL without sending;
- no match — send while the lease is valid;
- multiple matches — do not send; persist/escalate an ambiguity and require operator review;
- search unavailable — classify as retryable and do not assume no message exists.

Reconciliation is mandatory after recovery of an expired lease or ambiguous previous execution.

## 15. Successful post-send transaction

After Gmail success or successful reconciliation, execute one PostgreSQL transaction that:

1. verifies the operation remains `in_progress`;
2. verifies the current worker owns a non-expired lease;
3. verifies token, case, and request-cycle identity;
4. verifies the token is `issued` and unexpired;
5. applies `complete_external_operation_success`;
6. stores Gmail message ID as `external_id`;
7. stores the sanitized response summary;
8. transitions the token to `delivered`;
9. sets `delivered_at` from database time;
10. clears ciphertext, nonce, authentication tag, and encryption key ID;
11. conditionally moves the case to `awaiting_client_data`;
12. keeps the collection step `in_progress`;
13. clears the step error summary;
14. inserts the deterministic delivered event;
15. commits.

Any required failure rolls back the complete transaction.

Initial compare-and-set:

```sql
UPDATE onboarding_cases
SET state = 'awaiting_client_data'
WHERE id = :case_id
  AND state = 'created';
```

Correction compare-and-set:

```sql
UPDATE onboarding_cases
SET state = 'awaiting_client_data'
WHERE id = :case_id
  AND state = 'validation_failed';
```

Exactly one row must be updated unless another worker already finalized the same operation consistently. Zero rows require authoritative rereading; WF02 must not overwrite state blindly.

Gmail remains outside the transaction. The operation record, marker, lease, encrypted token, and reconciliation protocol close the external-side-effect gap.

## 16. Business events

### 16.1 Token issued

```text
event_type: client_data_token_issued
actor_type: workflow
actor_identifier: WF02
event_key: onboarding:<case_id>:form-token:<token_id>:issued
previous_state: null
new_state: null
```

Sanitized data:

```json
{
  "token_id": "00000000-0000-0000-0000-000000000000",
  "request_cycle_key": "initial",
  "expires_at": "2026-07-21T20:00:00Z"
}
```

No token bytes, ciphertext, URL, or recipient email.

### 16.2 Request delivered

```text
event_type: client_data_request_delivered
actor_type: workflow
actor_identifier: WF02
event_key: onboarding:<case_id>:form-token:<token_id>:client-data-request-delivered
previous_state: created or validation_failed
new_state: awaiting_client_data
```

Sanitized data:

```json
{
  "token_id": "00000000-0000-0000-0000-000000000000",
  "external_operation_id": "00000000-0000-0000-0000-000000000000",
  "request_cycle_key": "initial",
  "template_key": "client_data_request_v1",
  "provider": "gmail"
}
```

### 16.3 Terminal delivery failure

```text
event_type: client_data_request_delivery_failed
actor_type: workflow
actor_identifier: WF02
event_key: onboarding:<case_id>:form-token:<token_id>:client-data-request-delivery-failed
previous_state: null
new_state: null
```

It may include token ID, operation ID, request-cycle key, stable failure class, and final attempt count. It must not include secrets, token material, URL, complete provider response, or submitted values.

All event inserts are conflict-safe on `event_key`.

## 17. Retryable Gmail failure

Retryable examples:

- HTTP 429;
- HTTP 502, 503, or 504;
- network timeout;
- temporary DNS or connection failure;
- transient Gmail API failure;
- temporary Sent-mail reconciliation failure.

The valid lease owner applies `complete_external_operation_failure` with `retryable = true`, a stable sanitized error class, a safe summary, and `next_retry_at`.

The token remains `issued` with encrypted material. The case remains `created` for the initial cycle or `validation_failed` for a correction cycle. The collection step becomes `failed_retryable`.

Initial schedule:

```text
attempt 1 failure → retry after 1 minute
attempt 2 failure → retry after 5 minutes
attempt 3 failure → retry after 15 minutes
attempt 4 failure → retry after 1 hour
attempt 5 failure → terminal failure
```

Retry time is based on database time. WF02 must not wait inside the workflow. WF98 dispatches due retries.

Sanitized retry output:

```json
{
  "workflow": "WF02",
  "result": "failed_retryable",
  "case_id": "00000000-0000-0000-0000-000000000000",
  "correlation_id": "00000000-0000-0000-0000-000000000000",
  "external_operation_id": "00000000-0000-0000-0000-000000000000",
  "operation_status": "failed_retryable",
  "next_retry_at": "2026-07-18T20:05:00Z"
}
```

No token or URL is returned.

## 18. Terminal failure

Terminal examples:

- missing or invalid Gmail credentials;
- HTTP 401 or 403 requiring configuration correction;
- permanently invalid recipient confirmed by the provider;
- permanent malformed-message rejection;
- token decryption/authentication failure;
- multiple Gmail reconciliation matches;
- token expiry before confirmed delivery;
- maximum attempts exhausted;
- operation identity mismatch;
- persisted-data inconsistency that prevents safe retry.

A terminal failure must, where possible, be finalized atomically:

- operation becomes `failed_terminal`;
- lease is cleared;
- sanitized failure classification is stored;
- collection step becomes `failed_terminal` and receives `completed_at`;
- an `issued` token is revoked and encrypted material is cleared when safe;
- terminal business event is inserted;
- case remains in its pre-delivery state;
- WF99 is invoked for operator intervention.

WF02 must not transition the case to `awaiting_client_data`.

HTTP 401 or 403 is not automatically retried. A later recovery requires an explicit operator decision and documented recovery behavior; the terminal operation must not be reset silently.

## 19. Unexpected technical failure

Examples:

- PostgreSQL connection failure;
- malformed database result;
- missing case referenced by a valid operation;
- correlation mismatch;
- token decryption failure;
- missing runtime configuration;
- n8n node exception;
- post-send transaction failure;
- lease result that cannot be reconciled.

WF02 must invoke WF99 or allow the configured n8n error workflow to handle it.

Safe error context may include:

- workflow name `WF02 — Request Client Data`;
- workflow and execution identifiers;
- case and correlation identifiers;
- collection step ID;
- token ID;
- operation ID;
- stable error class and code;
- retryability;
- occurrence time.

It must not include plain token, URL, ciphertext, nonce, authentication tag, encryption key, Gmail credentials, OAuth tokens, email body, complete Gmail response, or submitted values.

Before Gmail, a failure must not record success or advance the case. After Gmail may have acted, WF02 must not immediately send again; the operation remains recoverable by lease expiry and the next execution reconciles Gmail by marker.

## 20. Output contract

Newly delivered request:

```json
{
  "workflow": "WF02",
  "result": "delivered",
  "case_id": "00000000-0000-0000-0000-000000000000",
  "correlation_id": "00000000-0000-0000-0000-000000000000",
  "request_cycle_key": "initial",
  "token_id": "00000000-0000-0000-0000-000000000000",
  "external_operation_id": "00000000-0000-0000-0000-000000000000",
  "operation_status": "succeeded",
  "case_state": "awaiting_client_data"
}
```

Reused successful request:

```json
{
  "workflow": "WF02",
  "result": "already_delivered",
  "case_id": "00000000-0000-0000-0000-000000000000",
  "correlation_id": "00000000-0000-0000-0000-000000000000",
  "request_cycle_key": "initial",
  "token_id": "00000000-0000-0000-0000-000000000000",
  "external_operation_id": "00000000-0000-0000-0000-000000000000",
  "operation_status": "succeeded",
  "case_state": "awaiting_client_data"
}
```

Allowed `result` values:

- `delivered`;
- `already_delivered`;
- `busy`;
- `not_due`;
- `not_required`;
- `failed_retryable`;
- `failed_terminal`.

Output must not contain token hash, token bytes, encrypted fields, complete URL, recipient email, email content, credentials, full provider response, or submitted values.

## 21. Transaction boundaries

### Token preparation transaction

Includes case/step locking, state verification, stale-token expiry, token create/reuse, token-issued event, and new-cycle step preparation. Excludes Gmail.

### Operation claim

`claim_external_operation` atomically creates/resolves and claims the operation.

### External activity

Gmail reconciliation and send occur outside PostgreSQL transactions.

### Success finalization

Includes operation success, token delivery, crypto clearing, case compare-and-set, step reconciliation, and delivered event.

### Failure finalization

Includes operation failure, retry time or terminal completion, step failure, token revocation for terminal failure, and terminal event where applicable.

## 22. Concurrency contract

For concurrent invocations of the same cycle:

- exactly one token row exists;
- exactly one active token exists for the case;
- exactly one external operation exists;
- only one worker owns a valid lease;
- at most one Gmail message is sent;
- all executions resolve the same token and operation;
- non-owners return a no-send result such as `busy` or `already_delivered`.

A new correction cycle must not start while a different non-expired active token exists.

An expired lease may be reclaimed through the database function. The recovering worker must reconcile Gmail before sending.

Only the current valid lease owner may finalize success or failure. Another worker rereads and returns the authoritative result.

## 23. Security and execution-data handling

Secrets remain outside Git and workflow JSON:

- Gmail credentials;
- OAuth secrets;
- AES key;
- database password;
- runtime secret values.

The plain token and complete form URL must not be retained in n8n execution history. Production execution settings and node design must prevent token-bearing successful or failed execution data from being persisted.

Token-bearing item lifetime must be minimized:

1. generate or decrypt;
2. construct URL;
3. prepare and send Gmail;
4. immediately replace the item with sanitized identifiers;
5. never throw an error containing the token-bearing item.

Token data must not be pinned.

Logs may include workflow/execution, case, correlation, token ID, operation ID, and stable result code. Logs must not include plain token, URL, encrypted fields, email body, credentials, or complete provider responses.

## 24. Configuration contract

Protected runtime configuration equivalent to:

```text
CLIENT_DATA_FORM_BASE_URL
CLIENT_DATA_FORM_TOKEN_TTL_HOURS=72
CLIENT_DATA_TOKEN_ENCRYPTION_KEY
CLIENT_DATA_TOKEN_ENCRYPTION_KEY_ID
WF02_OPERATION_LEASE_SECONDS=300
WF02_OPERATION_MAX_ATTEMPTS=5
CLIENT_DATA_REQUEST_SENDER_NAME
CLIENT_DATA_SUPPORT_CONTACT
```

Gmail uses an n8n credential. The encryption key must decode to exactly 32 bytes.

Configuration validation occurs before token creation or Gmail activity. Missing or invalid required configuration is terminal for the execution and is sent to WF99.

## 25. Logical execution order

```text
1. Receive internal invocation
2. Validate invocation shape
3. Validate protected configuration
4. Load authoritative case and correlation_id
5. Validate trigger source and case state
6. Validate failed submission or retry operation
7. Lock case and create/reuse request-cycle token
8. Prepare collect_client_data step
9. Build operation identity and message marker
10. Claim operation atomically
11. Handle no-send claim outcomes
12. Verify token is issued and unexpired
13. Decrypt token only in memory
14. Build production form URL
15. Reconcile Gmail when required
16. Send Gmail only when no previous message is found
17. Atomically finalize operation, token, case, step, and event
18. Return sanitized result
```

Failure path:

```text
1. Classify retryability
2. Persist operation failure while lease is owned
3. Update collection step
4. Preserve or revoke token material according to retryability
5. Insert terminal event where applicable
6. Invoke WF99 when required
7. Return only sanitized output
```

## 26. Acceptance scenarios

### 26.1 Initial happy path

Given a case in `created`, cycle `initial`, no token, and successful Gmail send:

- one token is created as `issued` and becomes `delivered`;
- hash length is 32 bytes;
- encrypted material exists only while pending;
- one operation becomes `succeeded`;
- one Gmail message is sent;
- case becomes `awaiting_client_data`;
- collection step remains `in_progress`;
- deterministic events exist;
- output is `delivered`;
- no plain token is persisted.

### 26.2 Duplicate initial invocation after success

Given delivered token, succeeded operation, and case `awaiting_client_data`:

- no new token or operation;
- no second Gmail message;
- output is `already_delivered`.

### 26.3 Concurrent initial invocations

Two simultaneous executions must produce one token, one operation, one valid lease owner, at most one Gmail message, one case transition, and no duplicate events.

### 26.4 Correction happy path

Given case `validation_failed`, a failed submission belonging to the case, and a consumed previous token:

- a new token is created for `validation_failed:<submission_id>`;
- a new operation is created for that token;
- correction template is used;
- submitted values are not included;
- case becomes `awaiting_client_data`;
- duplicate invocation reuses the same cycle.

### 26.5 Invalid case state

An initial invocation for a case in `approved` creates no token, operation, Gmail message, or state change and returns `not_required`.

### 26.6 Correlation mismatch

No Gmail activity occurs. WF99 receives a sanitized data-integrity failure.

### 26.7 Retryable Gmail failure

A transient 503 produces:

- `failed_retryable` operation;
- non-null `next_retry_at`;
- issued token with encrypted material;
- unchanged case state;
- failed-retryable collection step;
- no immediate wait/retry loop.

### 26.8 Due retry

WF98 retry uses the same token and operation, increments only operation attempt count, reconciles when required, and does not create replacement token material.

### 26.9 Crash after Gmail send

On recovery:

- expired lease is reclaimed;
- Sent mail is searched by marker;
- existing message is found;
- no second email is sent;
- PostgreSQL success finalization completes.

### 26.10 Multiple reconciliation matches

No new Gmail message is sent. Ambiguity is persisted and escalated to WF99 for operator review.

### 26.11 Terminal credential failure

A Gmail 401 or 403 produces no automatic retry, terminal operation, revoked/cleared token when safe, terminal step, unchanged case state, and operator intervention.

### 26.12 Token expired before delivery

The token becomes `expired`, encrypted material is cleared, Gmail is not sent, and no silent replacement is created under the same cycle key.

### 26.13 Succeeded operation with inconsistent records

If operation is `succeeded` while token or case is inconsistent, WF02 sends no Gmail, performs no blind repair, and reports persisted-data inconsistency to WF99.

### 26.14 Plain-token persistence audit

After success, retry, terminal failure, and reconciliation tests:

- PostgreSQL contains no plain token;
- workflow output contains no token or full URL;
- events and operation summaries contain no token;
- error records contain no token;
- retained n8n execution data contains no token or full URL.

## 27. Implementation gate

WF02 is ready only when tests prove:

- initial and correction happy paths;
- duplicate initial and correction invocations;
- concurrent safety;
- invalid-state suppression;
- correlation, submission, token, and operation identity checks;
- retryable failure persistence;
- due retry using the same token;
- terminal behavior;
- Gmail reconciliation after interruption;
- no duplicate Gmail side effect;
- correct token lifecycle;
- correct case transition;
- correct step behavior;
- deterministic events;
- direct PostgreSQL verification;
- absence of plain token material from all persisted records and retained execution data.

No WF03 implementation may rely on WF02 until this contract and the final Stage 5 cross-workflow review are complete.
