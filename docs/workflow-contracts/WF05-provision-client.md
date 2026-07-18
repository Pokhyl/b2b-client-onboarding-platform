# WF05 — Provision Client

## 1. Purpose

WF05 provisions the approved canonical client through the deterministic Mock Provisioning API and persists the authoritative external client identifier.

The workflow transitions an onboarding case from `approved` or retryable `provisioning_failed` into `provisioning`, performs exactly one logical external provisioning operation through a deterministic idempotency key, and moves the case to `provisioned` or `provisioning_failed` according to the persisted result.

PostgreSQL remains the source of truth for the case state, approval prerequisite, canonical client link, provisioning step, external operation, retry eligibility, external client identifier, and audit events.

## 2. Responsibilities

WF05 is responsible for:

- accepting a trusted internal invocation from WF04 or WF98;
- validating the internal invocation shape;
- rereading the authoritative case, accepted submission, canonical client, approval step, provisioning step, and external operation;
- verifying that approval was completed with decision `approved`;
- verifying that the case and client links are internally consistent;
- creating or reusing one deterministic `provision_client` operation;
- atomically claiming the operation before the external request;
- conditionally moving the case from `approved` or `provisioning_failed` to `provisioning`;
- maintaining the `provision_client` step;
- building one deterministic Mock Provisioning API payload from validated canonical data;
- sending the operation idempotency key in the required `Idempotency-Key` header;
- validating every HTTP response before persisting success;
- safely repeating the same idempotent API request after an interrupted execution;
- storing a sanitized response summary and external client identifier;
- moving the case from `provisioning` to `provisioned` only after confirmed success;
- moving the case from `provisioning` to `provisioning_failed` after retryable or terminal failure;
- scheduling retryable failures for WF98;
- invoking WF06 only after provisioning success commits;
- recording deterministic append-only business events;
- sending unexpected and intervention-requiring failures to WF99.

## 3. Explicit non-responsibilities

WF05 must not:

- accept a public webhook;
- create or validate client submissions;
- create or modify canonical client identity or contact data;
- approve or reject an onboarding case;
- send approval messages;
- call the provisioning API before the persisted approval prerequisite is satisfied;
- generate a different idempotency key during retry;
- change the provisioning payload for an existing operation;
- treat n8n execution history as proof of provisioning;
- create Drive folders, Calendar events, or internal notifications;
- mark a case completed;
- automatically compensate or delete a successfully created external client;
- reopen terminal `rejected` or `completed` cases;
- expose complete external API responses, credentials, or client data in events or errors.

## 4. Trigger and invocation model

### 4.1 Initial invocation from WF04

WF04 invokes WF05 only after the approved-decision transaction commits.

Input:

```json
{
  "case_id": "00000000-0000-0000-0000-000000000000",
  "correlation_id": "00000000-0000-0000-0000-000000000000",
  "client_id": "00000000-0000-0000-0000-000000000000",
  "accepted_submission_id": "00000000-0000-0000-0000-000000000000",
  "trigger_source": "wf04"
}
```

Rules:

- every identifier is a required UUID string;
- `trigger_source` must equal `wf04`;
- `external_operation_id` must not be present;
- unknown top-level fields are rejected.

### 4.2 Retry invocation from WF98

WF98 invokes WF05 for a due retryable provisioning operation.

Input:

```json
{
  "case_id": "00000000-0000-0000-0000-000000000000",
  "correlation_id": "00000000-0000-0000-0000-000000000000",
  "external_operation_id": "00000000-0000-0000-0000-000000000000",
  "trigger_source": "wf98"
}
```

Rules:

- `external_operation_id` is required;
- `client_id` and `accepted_submission_id` must not be supplied;
- WF05 loads the client and submission references from PostgreSQL;
- the operation must belong to the case and have type `provision_client`;
- the operation must be due and claimable.

### 4.3 Internal input is non-authoritative

WF05 must independently load and verify:

- case `id`, `correlation_id`, `state`, `client_id`, `accepted_submission_id`, `approval_decision`, and `external_client_id`;
- accepted submission ownership and `validation_status = 'passed'`;
- canonical client ownership and source submission;
- completed manual approval step with decision `approved`;
- provisioning step;
- existing external operation.

A supplied identifier mismatch is a non-retryable data-integrity failure. The API must not be called.

## 5. Authoritative preconditions

### 5.1 Initial provisioning

Initial provisioning may start only when:

```text
case.state = approved
case.approval_decision = approved
case.approval_decided_at IS NOT NULL
case.client_id IS NOT NULL
case.accepted_submission_id IS NOT NULL
case.external_client_id IS NULL
manual_approval.status = completed
manual_approval.approval_decision = approved
```

The accepted submission must belong to the case and have status `passed`.

The linked canonical client must exist.

### 5.2 Retry provisioning

A retry may start only when:

```text
case.state = provisioning_failed
case.approval_decision = approved
case.external_client_id IS NULL
operation.status = failed_retryable
operation.next_retry_at <= database time
```

An expired `in_progress` operation lease may be recovered according to `claim_external_operation`.

### 5.3 Already provisioned

When the case is `provisioned`, `finalizing`, `finalization_failed`, or `completed`, WF05 must not call the API again.

It may return `already_provisioned` only when:

- `external_client_id` is non-blank;
- the provisioning operation is `succeeded`;
- operation `external_id` equals the case external client identifier;
- the provisioning step is completed.

A contradiction is sent to WF99 and must not be repaired blindly.

### 5.4 Invalid states

WF05 must not provision cases in:

- `created`;
- `awaiting_client_data`;
- `data_received`;
- `validation_failed`;
- `awaiting_approval`;
- `rejected`;
- `provisioning` while another valid lease exists.

It returns `not_required`, `busy`, or `invalid_internal_invocation` without an API call.

## 6. Mock Provisioning API contract

### 6.1 Base URL

The protected runtime configuration is:

```text
MOCK_PROVISIONING_API_BASE_URL=http://mock-provisioning-api:3001
```

The exact endpoint is:

```text
POST <MOCK_PROVISIONING_API_BASE_URL>/v1/clients
```

The URL is configured outside caller input.

### 6.2 Required header

WF05 must send:

```text
Idempotency-Key: onboarding:<case_id>:provision-client
```

The API rejects a missing or blank key and keys longer than 200 characters.

### 6.3 Content type

```text
Content-Type: application/json
Accept: application/json
```

### 6.4 Request body

The exact initial request body is:

```json
{
  "caseId": "00000000-0000-0000-0000-000000000000",
  "companyName": "Example Industries Sp. z o.o.",
  "companyIdentifier": "PL:nip:1234567890",
  "scenario": "success"
}
```

Required API fields are:

- `caseId`;
- `companyName`;
- `companyIdentifier`.

The Mock API defaults `scenario` to `success`, but WF05 sends it explicitly so the immutable request fingerprint is unambiguous.

### 6.5 Deterministic company identifier

WF05 builds:

```text
<country>:<type>:<normalized_value>
```

from the canonical client fields:

- `company_identifier_country`;
- `company_identifier_type`;
- `company_identifier_value_normalized`.

No CRM intake field may override this value.

### 6.6 Controlled scenario

Allowed Mock API scenarios are:

- `success`;
- `retryable_once`;
- `retryable_always`;
- `terminal`.

The initial non-test environment must use:

```text
MOCK_PROVISIONING_SCENARIO=success
```

A non-success scenario is a protected test configuration. It must not be accepted from WF04, WF98, the client, or CRM metadata.

The selected scenario is stored in the immutable operation request summary. Retries use the stored scenario, not a later environment change.

### 6.7 Size and timeout

The request body is far below the API's 64 KiB limit.

Initial HTTP configuration:

```text
connection timeout: 5 seconds
request timeout: 30 seconds
```

Timeouts are protected configuration.

## 7. External-operation identity

### 7.1 Operation type

```text
provision_client
```

### 7.2 Deterministic idempotency key

```text
onboarding:<case_id>:provision-client
```

The same case always uses the same key.

### 7.3 Immutable request summary

The operation `request_summary` contains the exact logical API request:

```json
{
  "endpoint_path": "/v1/clients",
  "case_id": "00000000-0000-0000-0000-000000000000",
  "client_id": "00000000-0000-0000-0000-000000000000",
  "accepted_submission_id": "00000000-0000-0000-0000-000000000000",
  "company_name": "Example Industries Sp. z o.o.",
  "company_identifier": "PL:nip:1234567890",
  "scenario": "success"
}
```

The idempotency key itself is already stored in its dedicated column.

The summary must not contain:

- database credentials;
- full submission JSON;
- contact email or phone;
- approval response metadata;
- API host credentials;
- transport headers unrelated to idempotency.

### 7.4 Payload immutability

A retry must reconstruct the request from the stored immutable request summary.

It must not use changed canonical client fields or changed environment scenario values for an existing operation.

A payload mismatch for the same key is a terminal data-integrity error.

## 8. Preparation and atomic claim transaction

Before the external call, WF05 executes one PostgreSQL transaction that:

1. locks the onboarding case;
2. verifies the authoritative preconditions;
3. locks the `provision_client` step;
4. creates the deterministic request summary for a new operation or verifies the existing summary;
5. calls `claim_external_operation`;
6. handles every claim outcome;
7. when claimed, conditionally moves the case to `provisioning`;
8. sets the provisioning step to `in_progress`;
9. increments the step attempt count for the claimed provisioning attempt;
10. sets `started_at` if required;
11. clears `completed_at` and stale error summary;
12. commits.

The state transition is:

```text
approved → provisioning
```

or:

```text
provisioning_failed → provisioning
```

If the case compare-and-set fails, the transaction must roll back the operation claim.

## 9. Operation claim outcomes

WF05 uses:

```text
lease owner: WF05:<n8n_execution_id>
lease duration: 300 seconds
maximum attempts: 5
```

### 9.1 `claimed`

The current execution owns the valid lease and may call the API.

### 9.2 `reuse_succeeded`

WF05 must not call the API.

It verifies that the case, operation, step, and external client identifier are consistently provisioned.

When consistent, return `already_provisioned`.

When inconsistent, call WF99 and stop.

### 9.3 `busy`

Another worker owns a valid lease. No API call or state overwrite is allowed.

Return `busy`.

### 9.4 `not_due`

The retry time has not arrived. Return `not_due` without changing state or calling the API.

### 9.5 `refused_terminal`

Return `failed_terminal` and require intervention.

### 9.6 `refused_exhausted`

Reconcile the operation and provisioning step to terminal failure and request operator intervention.

## 10. HTTP success responses

### 10.1 New successful provisioning

The API returns HTTP `201` with:

```json
{
  "externalClientId": "mock_client_0123456789abcdef01234567",
  "caseId": "00000000-0000-0000-0000-000000000000",
  "companyName": "Example Industries Sp. z o.o.",
  "companyIdentifier": "PL:nip:1234567890",
  "status": "provisioned",
  "attemptNumber": 1,
  "replayed": false
}
```

### 10.2 Idempotent replay

The same successful key and identical payload return HTTP `200` with the same provisioning result and:

```text
replayed: true
```

Both `200` replay and `201` creation are successful outcomes.

### 10.3 Required validation

Before persisting success, WF05 must verify:

- HTTP status is `200` or `201`;
- response content type is JSON-compatible;
- `externalClientId` is a non-blank string;
- `caseId` equals the authoritative case identifier;
- `companyName` equals the trimmed stored request value;
- `companyIdentifier` equals the stored request value;
- `status` equals `provisioned`;
- `attemptNumber` is a positive integer;
- `replayed` is boolean;
- `201` normally uses `replayed = false`;
- `200` replay uses `replayed = true`.

A malformed successful response must not be persisted as success.

Because the API is idempotent, a retry may safely repeat the same request to recover a valid response.

## 11. Success-finalization transaction

After a validated successful response, WF05 executes one PostgreSQL transaction that:

1. locks and verifies the operation;
2. verifies the current lease owner and unexpired lease;
3. locks the case and provisioning step;
4. verifies `case.state = 'provisioning'`;
5. verifies `external_client_id IS NULL` or equals the same returned identifier;
6. completes the external operation as `succeeded`;
7. stores `externalClientId` as operation `external_id`;
8. stores a sanitized response summary;
9. updates the case `external_client_id`;
10. moves the case from `provisioning` to `provisioned` in the same update;
11. marks the provisioning step `completed`;
12. sets step `completed_at` using database time;
13. clears step error summary;
14. inserts deterministic business events;
15. commits.

The case update must set the identifier and state together because the schema requires a non-blank external client identifier in `provisioned`.

Conceptually:

```sql
UPDATE onboarding_cases
SET
  external_client_id = :external_client_id,
  state = 'provisioned'
WHERE id = :case_id
  AND state = 'provisioning'
  AND external_client_id IS NULL;
```

Exactly one row must update unless another execution already committed the identical authoritative result.

## 12. Sanitized success summary

The operation response summary may contain:

```json
{
  "provider": "mock-provisioning-api",
  "http_status": 201,
  "external_client_id": "mock_client_0123456789abcdef01234567",
  "provider_status": "provisioned",
  "provider_attempt_number": 1,
  "replayed": false,
  "completed_at": "2026-07-18T20:00:00Z"
}
```

It must not contain complete response headers, internal service logs, stack traces, or unrelated client data.

## 13. Retryable failure contract

### 13.1 Retryable API response

The Mock API returns HTTP `503` for `retryable_once` and `retryable_always` with:

```json
{
  "error": {
    "code": "PROVISIONING_TEMPORARILY_UNAVAILABLE",
    "message": "The provisioning service is temporarily unavailable",
    "retryable": true
  },
  "attemptNumber": 1
}
```

The API may return `Retry-After: 1`.

### 13.2 Other retryable failures

Retryable failures include:

- network timeout;
- temporary DNS or connection failure;
- HTTP 429;
- HTTP 502, 503, or 504;
- HTTP 500 with no evidence of a permanent contract error;
- malformed successful response that can be recovered safely by replaying the same idempotent request;
- execution interruption after the API call but before the PostgreSQL success transaction.

### 13.3 Failure-finalization transaction

While owning the lease, WF05 must:

- call `complete_external_operation_failure` with `retryable = true`;
- store a stable error class and sanitized summary;
- set `next_retry_at`;
- move the case from `provisioning` to `provisioning_failed`;
- set the provisioning step to `failed_retryable`;
- leave `completed_at` null;
- store a sanitized step error summary;
- insert a retryable failure event;
- commit.

The external client identifier remains null.

### 13.4 Retry schedule

Initial schedule:

```text
attempt 1 failure → retry after 1 minute
attempt 2 failure → retry after 5 minutes
attempt 3 failure → retry after 15 minutes
attempt 4 failure → retry after 1 hour
attempt 5 failure → terminal failure
```

The platform policy is the minimum delay. A longer valid provider `Retry-After` value may extend it.

WF05 never waits inside the workflow for the retry time.

WF98 dispatches due retries.

## 14. Terminal failure contract

### 14.1 Mock API terminal response

The Mock API returns HTTP `422` with:

```json
{
  "error": {
    "code": "PROVISIONING_REJECTED",
    "message": "The provisioning request was permanently rejected",
    "retryable": false
  },
  "attemptNumber": 1
}
```

This is terminal.

### 14.2 Idempotency conflict

HTTP `409` with code `IDEMPOTENCY_KEY_CONFLICT` means the same key was used with a different payload.

This is a critical terminal data-integrity failure.

WF05 must not create a replacement key.

### 14.3 Other terminal failures

Terminal examples include:

- HTTP 400 `INVALID_REQUEST`;
- HTTP 400 idempotency-key validation error;
- HTTP 413 body-too-large;
- explicit `retryable = false` provider error;
- request-summary mismatch;
- invalid authoritative client identity;
- maximum attempts exhausted;
- non-retryable configuration error;
- repeated response validation failure after attempt exhaustion.

### 14.4 Terminal finalization

While owning the lease, WF05 must:

- mark the operation `failed_terminal`;
- move the case from `provisioning` to `provisioning_failed`;
- mark the provisioning step `failed_terminal`;
- set step `completed_at`;
- keep `external_client_id` null;
- insert a terminal failure event;
- call WF99 for operator intervention;
- never invoke WF06.

## 15. Interrupted execution recovery

### 15.1 Before external call

If execution stops after the preparation transaction but before the API call, the lease eventually expires.

A later WF98 execution reclaims the same operation and sends the same request.

### 15.2 After external success before database commit

The Mock API may already have created the external client.

After lease expiry, WF05 must reclaim the same operation and repeat the exact request with the same idempotency key.

The API returns the same deterministic external client and `replayed = true` when its successful idempotency record is present.

Even after a mock service restart, the external identifier remains deterministically derived from the idempotency key, so the same logical client identifier is returned.

WF05 then executes the normal success-finalization transaction.

### 15.3 No uncontrolled replacement

Recovery must never:

- generate a different key;
- create a new operation;
- change the request payload;
- clear an existing successful external identifier;
- create a compensating deletion.

## 16. WF06 dispatch

After the success-finalization transaction commits, WF05 invokes WF06 asynchronously with:

```json
{
  "case_id": "00000000-0000-0000-0000-000000000000",
  "correlation_id": "00000000-0000-0000-0000-000000000000",
  "client_id": "00000000-0000-0000-0000-000000000000",
  "accepted_submission_id": "00000000-0000-0000-0000-000000000000",
  "external_client_id": "mock_client_0123456789abcdef01234567",
  "trigger_source": "wf05"
}
```

WF06 must reread authoritative data.

Use `Wait for Sub-Workflow Completion` disabled.

### 16.1 Dispatch failure

When provisioning committed but n8n cannot accept WF06:

- keep the case `provisioned`;
- keep the successful operation and external identifier;
- do not call provisioning again;
- send the technical failure to WF99;
- allow controlled later recovery to invoke WF06 from persisted state.

## 17. Business-event contract

All events use deterministic keys and conflict-safe insertion.

### 17.1 Provisioning started

```text
event_type: client_provisioning_started
actor_type: workflow
actor_identifier: WF05
event_key: onboarding:<case_id>:provision-client:started
previous_state: approved or provisioning_failed
new_state: provisioning
```

Event data contains only operation, client, attempt, and provider identifiers required for audit.

### 17.2 Provisioning succeeded

```text
event_type: client_provisioning_succeeded
event_key: onboarding:<case_id>:provision-client:succeeded
previous_state: provisioning
new_state: provisioned
```

Event data may contain the external client identifier and replay flag.

### 17.3 Retryable failure

```text
event_type: client_provisioning_failed_retryable
event_key: onboarding:<case_id>:provision-client:attempt:<attempt_count>:failed-retryable
previous_state: provisioning
new_state: provisioning_failed
```

### 17.4 Terminal failure

```text
event_type: client_provisioning_failed_terminal
event_key: onboarding:<case_id>:provision-client:failed-terminal
previous_state: provisioning
new_state: provisioning_failed
```

Failure events contain stable codes, attempt counts, and operation identifiers, not complete API bodies.

## 18. Output contract

### 18.1 Provisioned

```json
{
  "workflow": "WF05",
  "result": "provisioned",
  "case_id": "00000000-0000-0000-0000-000000000000",
  "correlation_id": "00000000-0000-0000-0000-000000000000",
  "external_operation_id": "00000000-0000-0000-0000-000000000000",
  "external_client_id": "mock_client_0123456789abcdef01234567",
  "case_state": "provisioned",
  "wf06_dispatch": "invoked"
}
```

### 18.2 Other results

Allowed results include:

- `already_provisioned`;
- `busy`;
- `not_due`;
- `not_required`;
- `failed_retryable`;
- `failed_terminal`.

The output must not contain the full request, full response, database credentials, or canonical contact data.

## 19. Unexpected technical failures

Unexpected examples include:

- PostgreSQL connection failure;
- missing approved client or passed submission;
- correlation mismatch;
- operation request-summary mismatch;
- impossible operation/case/step combination;
- lost operation lease;
- API response cannot be parsed;
- success transaction compare-and-set failure;
- WF06 dispatch acceptance failure.

WF05 invokes WF99 or allows the configured n8n error workflow to process the failure.

Safe context includes, when available:

- workflow name `WF05 — Provision Client`;
- workflow and execution identifiers;
- case, correlation, client, submission, step, and operation identifiers;
- provider HTTP status;
- stable provider error code;
- attempt count;
- retryability classification.

It must not include full canonical client data or complete provider bodies.

## 20. Transaction boundaries

### 20.1 Preparation transaction

Atomically validates prerequisites, claims the operation, transitions the case to `provisioning`, and updates the step.

### 20.2 External API call

Occurs outside PostgreSQL transactions while the worker owns a valid lease.

### 20.3 Success transaction

Atomically completes the operation, stores the external identifier, transitions the case to `provisioned`, completes the step, and inserts events.

### 20.4 Failure transaction

Atomically finalizes operation failure, transitions the case to `provisioning_failed`, updates the step, and inserts events.

### 20.5 Dispatch after commit

WF06 is invoked only after success commits.

## 21. Concurrency and idempotency

### 21.1 Concurrent initial invocations

Expected:

- one external operation;
- one valid lease owner;
- one case transition to `provisioning`;
- at most one active HTTP request;
- other executions return `busy` or authoritative existing result.

### 21.2 Concurrent due retries

Only one worker reclaims the operation. Others receive `busy`.

### 21.3 Duplicate API request

The same key and payload return the same logical external client. WF05 accepts `200` replay as success.

### 21.4 Different payload with same key

WF05 treats provider `409` as terminal and never creates a replacement key.

### 21.5 Concurrent success finalization

Only the valid lease owner may complete the operation. Other executions reread and return the authoritative result.

## 22. Security and data minimization

- the Mock API URL and scenario are protected configuration;
- non-success scenarios are test-only outside explicit controlled environments;
- only validated canonical company name and identifier are sent;
- contact data is not sent because the API does not require it;
- operation and event summaries exclude complete submissions and approval responses;
- database credentials remain outside workflow JSON;
- provider error messages are sanitized before storage;
- no full HTTP request or response is logged;
- no successful external resource is automatically deleted after a later failure.

## 23. Logical execution order

```text
1. Receive internal invocation
2. Validate invocation shape
3. Validate protected configuration
4. Load authoritative case, approval, submission, client, step, and operation
5. Resolve already-completed or invalid-state outcomes
6. Build or verify immutable operation request summary
7. Atomically claim operation and move case to provisioning
8. Build exact HTTP request from stored summary
9. POST /v1/clients with Idempotency-Key
10. Validate HTTP status and response schema
11A. On success, atomically persist external ID and move to provisioned
12A. Dispatch WF06 after commit
13A. Return sanitized provisioned result
11B. On retryable failure, atomically persist retry and provisioning_failed
12B. Return failed_retryable
11C. On terminal failure, atomically persist terminal result and provisioning_failed
12C. Invoke WF99 for intervention
13C. Return failed_terminal
```

## 24. Acceptance scenarios

### 24.1 Success scenario

Expected HTTP 201, operation succeeded, external ID stored, case provisioned, step completed, WF06 dispatched.

### 24.2 Idempotent replay

Given API success before local commit, retry returns HTTP 200 with `replayed = true`; no duplicate external client and normal local success finalization.

### 24.3 `retryable_once`

First request returns 503 and persists retryable failure. Due retry uses the same operation and payload and succeeds.

### 24.4 `retryable_always`

Each due attempt returns 503. After maximum attempts, operation and step become terminal and intervention is requested.

### 24.5 `terminal`

HTTP 422 produces terminal operation and step failure, case `provisioning_failed`, no WF06 dispatch.

### 24.6 Idempotency-key conflict

HTTP 409 produces critical terminal failure. No replacement key is generated.

### 24.7 Invalid API request

HTTP 400 is terminal and indicates a workflow contract or configuration defect.

### 24.8 Network timeout

Retryable failure is persisted. The due retry repeats the exact idempotent request.

### 24.9 Crash after API success

After lease expiry, retry with the same key recovers the same external client and completes PostgreSQL state.

### 24.10 Concurrent initial invocation

One operation, one lease, one active API request, one success transition.

### 24.11 Invalid approval prerequisite

No API call, no state transition, and sanitized integrity failure.

### 24.12 Already provisioned

No API call and result `already_provisioned` when persisted records are consistent.

### 24.13 WF06 dispatch failure

Provisioned state remains committed, API is not called again, and WF99 receives safe context.

### 24.14 Data minimization

API receives only case ID, canonical company name, canonical company identifier, and controlled scenario. Logs and events contain no complete client submission.

## 25. Implementation gate for WF05

The WF05 contract is satisfied only when implementation tests prove:

- exact Mock API endpoint, header, and body behavior;
- success and idempotent replay handling;
- controlled `retryable_once`, `retryable_always`, and `terminal` scenarios;
- operation payload immutability;
- atomic operation claim and lease behavior;
- approved and retry state preconditions;
- correct case and step transitions;
- external identifier persistence;
- concurrent invocation safety;
- crash-after-side-effect recovery;
- retry scheduling and attempt exhaustion;
- terminal idempotency conflict behavior;
- WF06 dispatch after commit only;
- deterministic events;
- direct PostgreSQL verification;
- absence of unnecessary client data and complete API payloads from logs, events, errors, and output.

No WF06 implementation may depend on WF05 until this contract and the final cross-workflow contract review are complete.
