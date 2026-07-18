# WF04 — Manual Approval

## 1. Purpose

WF04 sends one controlled approval request to the configured onboarding-operator mailbox, waits for one approve-or-reject response, persists the decision, and advances the onboarding case only through an authoritative PostgreSQL state transition.

The workflow implements the approval trust boundary defined by the architecture: access to the configured operator mailbox authorizes the response for the initial implementation. The system records the expected recipient, waiting execution reference, decision, timestamp, and sanitized response metadata, but does not claim cryptographic proof of the physical person who selected the response.

PostgreSQL remains the source of truth for the case state, accepted submission, canonical client link, approval step, approval operation, decision, and audit events.

## 2. Responsibilities

WF04 is responsible for:

- accepting a trusted internal invocation from WF03 or WF98;
- validating the invocation shape;
- rereading the authoritative case, client, accepted submission, step, and operation from PostgreSQL;
- verifying that the case is ready for manual approval;
- verifying that the accepted submission is passed and belongs to the case;
- verifying that the canonical client is linked to the case;
- ensuring that only one active approval waiting execution exists per case;
- reserving the `manual_approval` step with the current n8n execution identifier;
- creating or reusing one deterministic `send_approval_request` external operation;
- atomically claiming the operation before Gmail activity;
- generating a minimized approval summary from authoritative validated data;
- sending the approval request to the configured operator mailbox;
- using the n8n send-and-wait-for-response operation;
- recording the expected recipient and waiting execution reference before the workflow enters the wait state;
- handling approve, reject, timeout, delivery failure, duplicate invocation, duplicate response, and stale response safely;
- storing sanitized Gmail and response metadata;
- conditionally moving the case from `awaiting_approval` to `approved` or terminal `rejected`;
- completing the `manual_approval` step with the persisted decision;
- invoking WF05 only after an approved transaction commits;
- recording deterministic append-only business events;
- sending unexpected or unreconcilable failures to WF99.

## 3. Explicit non-responsibilities

WF04 must not:

- accept a public business webhook;
- accept client-data submissions;
- create or validate onboarding submissions;
- create or update canonical client data;
- modify the accepted submission;
- decide automatically whether a case should be approved;
- use AI to recommend or make the approval decision;
- send approval requests to an address supplied by the caller;
- create more than one active approval wait for a case;
- treat possession of a response link as cryptographic identity proof beyond the configured mailbox trust boundary;
- provision the client account directly;
- create Drive or Calendar resources;
- reopen `rejected` or `completed` cases;
- repeat an approval message whose delivery or active wait cannot be reconciled safely;
- use n8n execution history as the authoritative approval record.

## 4. Trigger and invocation model

### 4.1 Initial invocation from WF03

WF03 invokes WF04 only after the validation-success transaction commits.

Input:

```json
{
  "case_id": "00000000-0000-0000-0000-000000000000",
  "correlation_id": "00000000-0000-0000-0000-000000000000",
  "accepted_submission_id": "00000000-0000-0000-0000-000000000000",
  "client_id": "00000000-0000-0000-0000-000000000000",
  "trigger_source": "wf03"
}
```

Rules:

- all identifiers are required UUID strings;
- `trigger_source` must equal `wf03`;
- `external_operation_id` must not be present;
- unknown top-level fields are rejected.

### 4.2 Retry invocation from WF98

WF98 may invoke WF04 for a due retryable approval-delivery operation.

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
- `accepted_submission_id` and `client_id` must not be supplied;
- WF04 must load submission and client references from the case;
- the referenced operation must belong to the case and have type `send_approval_request`;
- the operation must be eligible for claim according to PostgreSQL.

### 4.3 Trusted input remains non-authoritative

WF04 must independently load and verify:

- case `id`, `correlation_id`, and `state`;
- `accepted_submission_id`;
- `client_id`;
- accepted submission validation status and normalized data;
- canonical client identity and contact data;
- `manual_approval` step;
- existing `send_approval_request` operation.

A supplied identifier mismatch is a non-retryable data-integrity failure. Gmail must not be called.

## 5. Authoritative preconditions

WF04 may create or resume an approval request only when:

```text
case.state = awaiting_approval
case.accepted_submission_id IS NOT NULL
case.client_id IS NOT NULL
accepted_submission.validation_status = passed
accepted_submission.case_id = case.id
client.id = case.client_id
client.source_submission_id references a passed submission
```

The case must have no approval decision yet:

```text
approval_decision IS NULL
approval_decided_at IS NULL
```

The `manual_approval` step must exist for the case.

### 5.1 Advanced case

When the case is already `approved`, `provisioning`, `provisioning_failed`, `provisioned`, `finalizing`, `finalization_failed`, or `completed`, WF04 must not send or wait again.

It may return `already_approved` only when the persisted approval decision is `approved` and the completed approval step is consistent.

### 5.2 Rejected case

When the case is `rejected`, WF04 must not reopen it.

It may return `already_rejected` only when the case and completed step both contain a consistent rejected decision.

### 5.3 Invalid state

For any other state, WF04 returns `not_required` or `invalid_internal_invocation` according to whether the call is stale or contradictory.

No Gmail side effect or state change is allowed.

## 6. Configuration contract

WF04 requires protected runtime configuration equivalent to:

```text
APPROVAL_RECIPIENT_EMAIL
APPROVAL_SENDER_NAME
APPROVAL_RESPONSE_TIMEOUT_HOURS=168
WF04_OPERATION_LEASE_SECONDS=608400
WF04_OPERATION_MAX_ATTEMPTS=3
APPROVAL_SUPPORT_CONTACT
```

`WF04_OPERATION_LEASE_SECONDS` must exceed the configured response timeout by a safety margin.

Gmail authentication uses an n8n credential and must not be stored in workflow JSON, Git, events, or logs.

Configuration validation occurs before the approval step is reserved or Gmail is called.

The configured recipient must be normalized by trimming and lowercasing and must pass syntactic email validation.

The caller cannot override it.

## 7. Approval-step ownership

### 7.1 One step per case

PostgreSQL contains exactly one `manual_approval` step per case.

### 7.2 Active wait representation

An active approval wait is represented by:

```text
step_type = manual_approval
status = waiting
n8n_wait_execution_id IS NOT NULL
approval_recipient_email = configured operator email
approval_decision IS NULL
approval_decided_at IS NULL
completed_at IS NULL
```

### 7.3 Reservation before external activity

Before calling the send-and-wait node, WF04 must execute one PostgreSQL transaction that:

1. locks the case;
2. verifies all approval preconditions;
3. locks the `manual_approval` step;
4. resolves any existing active or completed approval state;
5. stores the current n8n execution identifier;
6. stores the configured recipient;
7. increments the step attempt count for a genuinely new delivery attempt;
8. sets `started_at` if required;
9. clears stale error metadata;
10. sets the step to `waiting`;
11. commits.

The execution identifier must be stable for the current waiting execution.

### 7.4 Duplicate invocation with active wait

When the step is already `waiting` with a non-blank execution identifier and expected recipient, a duplicate WF04 invocation must not send another message.

It returns:

```text
result: active_wait_exists
```

The duplicate execution must not replace the stored waiting execution reference.

### 7.5 Inconsistent active wait

Examples include:

- step is `waiting` without an execution identifier;
- recipient differs from protected configuration;
- step references an execution that cannot be reconciled;
- operation is terminal while the step claims an active wait;
- case already has a decision while the step is waiting.

WF04 must not repair these states blindly or send another request. It sends a sanitized inconsistency to WF99 and requires operator intervention.

## 8. External-operation identity

### 8.1 Operation type

```text
send_approval_request
```

### 8.2 Deterministic idempotency key

```text
onboarding:<case_id>:send-approval-request
```

The initial architecture permits one approval request operation per onboarding case.

### 8.3 Immutable request summary

The operation `request_summary` contains only recovery and audit data:

```json
{
  "recipient_email": "operator@example.com",
  "template_key": "manual_approval_v1",
  "case_id": "00000000-0000-0000-0000-000000000000",
  "accepted_submission_id": "00000000-0000-0000-0000-000000000000",
  "client_id": "00000000-0000-0000-0000-000000000000",
  "waiting_execution_id": "12345",
  "message_marker": "b2b-approval-0123456789abcdef01234567"
}
```

It must not contain:

- Gmail credentials;
- response link;
- complete email body;
- complete normalized submission;
- sensitive personal data not required for reconciliation;
- approval decision before the response exists.

### 8.4 Message marker

Derive:

```text
b2b-approval-<first 24 lowercase hexadecimal characters of SHA-256(idempotency_key UTF-8 bytes)>
```

The marker must be included in a reliably searchable part of the outbound approval message.

## 9. Atomic operation claim

WF04 uses `claim_external_operation` with:

- the deterministic idempotency key;
- operation type `send_approval_request`;
- case identifier;
- lease owner `WF04:<n8n_execution_id>`;
- lease duration longer than the approval wait timeout;
- maximum attempts;
- immutable request summary.

### 9.1 `claimed`

The current execution owns the operation and may call the send-and-wait node.

### 9.2 `reuse_succeeded`

WF04 must not send another message.

It must verify the completed approval step and case decision and return the authoritative result.

An operation marked succeeded without a consistent completed approval result is a persisted-data inconsistency.

### 9.3 `busy`

Another valid lease exists. WF04 must not send or replace the active wait.

Return `active_wait_exists` or `busy` after verifying the step.

### 9.4 `not_due`

A retry time has not arrived. No Gmail activity is allowed.

### 9.5 `refused_terminal` or `refused_exhausted`

No automatic resend is allowed. Operator intervention is required.

## 10. Approval message contract

### 10.1 Recipient

The only recipient is the protected `APPROVAL_RECIPIENT_EMAIL`.

The initial implementation sends no CC or BCC.

### 10.2 Validated data source

The message summary must be built from:

- the accepted passed submission;
- the linked canonical client;
- the authoritative case.

CRM intake values must not override validated canonical data.

### 10.3 Message content

The approval message may contain:

- legal company name;
- normalized company identity country and type;
- user-visible company identifier value;
- primary contact name;
- primary contact email and phone;
- case creation time;
- a concise onboarding reference;
- approve and reject response actions;
- the deterministic message marker;
- response deadline;
- support contact.

The message must not contain:

- database credentials;
- form tokens;
- source webhook secrets;
- complete submission JSON;
- SQL errors;
- internal stack traces;
- unrelated CRM metadata.

### 10.4 Response choices

The n8n send-and-wait operation must expose exactly two decisions:

```text
approve
reject
```

Free-form values must not be interpreted as decisions.

An optional operator comment may be accepted only as bounded text and stored in sanitized response metadata.

### 10.5 Response timeout

The initial timeout is 168 hours.

A timeout is not an approval or rejection decision.

The case remains `awaiting_approval` and requires operator intervention unless an explicit future reminder policy is defined.

## 11. Send-and-wait execution protocol

### 11.1 Required order

WF04 must:

1. persist the waiting execution reference and recipient;
2. claim the external operation with a lease covering the wait period;
3. call the Gmail send-and-wait-for-response node;
4. remain suspended in the same n8n execution;
5. resume only when a response or timeout/error occurs.

### 11.2 Operation status during wait

Because the send-and-wait node does not expose a separate durable workflow step between confirmed send and waiting, the operation remains:

```text
status = in_progress
```

for the active wait.

The long lease prevents WF98 or another worker from claiming the same approval request while the original execution is waiting.

The operation is marked `succeeded` only when the response is received and the approval-decision transaction commits.

### 11.3 Delivery failure before wait

When Gmail returns a clear failure before a message is accepted, WF04 classifies the failure and finalizes the operation while it still owns the lease.

### 11.4 Ambiguous send state

When the workflow cannot determine whether Gmail accepted the message, it must not send another message automatically.

It must attempt reconciliation by deterministic message marker when the selected Gmail integration permits reliable Sent-mail search.

If the send or waiting execution cannot be reconciled safely, the operation becomes terminal and WF99 requests operator intervention.

## 12. Approval response validation

After the waiting execution resumes, WF04 must verify:

- the current execution identifier equals the step's stored waiting execution identifier;
- the configured recipient equals the stored expected recipient;
- the case remains `awaiting_approval` with no decision;
- the accepted submission and client links remain unchanged;
- the operation remains `in_progress` and the current execution owns the unexpired lease;
- the response value is exactly `approve` or `reject`.

A response that fails any check must not change the case.

## 13. Approval trust boundary

The initial implementation treats access to the configured mailbox and response link as the authorization boundary.

WF04 records:

- expected recipient email;
- waiting execution identifier;
- response decision;
- response timestamp;
- sanitized response metadata;
- Gmail message identifier when available.

WF04 must not claim:

- cryptographic proof of the human operator's identity;
- proof that no other mailbox user accessed the link;
- non-repudiation.

The documentation and UI must describe the decision as a response through the configured operator mailbox.

## 14. Decision transaction

After a valid response, WF04 executes one PostgreSQL transaction.

The transaction must:

1. lock the case;
2. verify `state = 'awaiting_approval'`;
3. verify no case decision exists;
4. lock the `manual_approval` step;
5. verify the waiting execution identifier and recipient;
6. lock and verify the external operation and lease owner;
7. store the step decision and decision time;
8. store sanitized response metadata;
9. set the step to `completed` and set `completed_at`;
10. clear the active wait only as permitted by the final persisted record;
11. store case `approval_decision` and `approval_decided_at`;
12. transition the case to `approved` or `rejected`;
13. set `rejected_at` only for rejection;
14. complete the external operation as `succeeded` with sanitized Gmail/response summary;
15. insert deterministic business events;
16. commit.

### 14.1 Approval transition

```sql
UPDATE onboarding_cases
SET
  state = 'approved',
  approval_decision = 'approved',
  approval_decided_at = clock_timestamp()
WHERE id = :case_id
  AND state = 'awaiting_approval'
  AND approval_decision IS NULL;
```

Exactly one row must update.

### 14.2 Rejection transition

```sql
UPDATE onboarding_cases
SET
  state = 'rejected',
  approval_decision = 'rejected',
  approval_decided_at = clock_timestamp(),
  rejected_at = clock_timestamp()
WHERE id = :case_id
  AND state = 'awaiting_approval'
  AND approval_decision IS NULL;
```

Exactly one row must update.

### 14.3 First valid response wins

Concurrent or repeated responses must serialize through the case and step locks.

Only the first valid decision commits.

Later responses must not change the persisted decision or case state.

## 15. WF05 dispatch

After an approved decision transaction commits, WF04 invokes WF05 asynchronously with:

```json
{
  "case_id": "00000000-0000-0000-0000-000000000000",
  "correlation_id": "00000000-0000-0000-0000-000000000000",
  "client_id": "00000000-0000-0000-0000-000000000000",
  "accepted_submission_id": "00000000-0000-0000-0000-000000000000",
  "trigger_source": "wf04"
}
```

WF05 must reread authoritative data.

WF04 must use asynchronous invocation with `Wait for Sub-Workflow Completion` disabled.

WF04 must not invoke WF05 for rejection.

### 15.1 WF05 dispatch failure

When approval committed but n8n cannot accept the WF05 execution:

- keep the case `approved`;
- keep the approval decision and completed step;
- do not resend approval;
- send the technical failure to WF99;
- allow controlled recovery to invoke WF05 from persisted state.

## 16. Delivery failure handling

### 16.1 Retryable clear failure

A delivery failure is retryable only when the provider clearly confirms that no approval message was accepted and the failure is transient, such as:

- HTTP 429;
- HTTP 502, 503, or 504;
- temporary DNS or connection failure before acceptance;
- explicit temporary Gmail service error.

WF04 must:

- call `complete_external_operation_failure` with `retryable = true`;
- set a due `next_retry_at`;
- move the approval step to `failed_retryable`;
- clear the waiting execution reference because no active wait exists;
- keep the case `awaiting_approval`;
- preserve no false decision.

WF98 may later invoke the same operation.

### 16.2 Terminal or ambiguous failure

Terminal examples include:

- Gmail 401 or 403;
- invalid configured recipient;
- malformed response configuration;
- ambiguous send result that cannot be reconciled;
- active wait execution lost after the message may have been sent;
- timeout without an approved reminder/reissue policy;
- maximum attempts exhausted;
- response payload integrity failure;
- waiting execution mismatch.

WF04 must:

- mark the operation `failed_terminal` when it owns the lease;
- mark the step `failed_terminal` when no valid active wait remains;
- keep the case `awaiting_approval` with no decision;
- insert a terminal failure event;
- call WF99 for operator intervention;
- never send an uncontrolled replacement approval request.

## 17. Business-event contract

All events use deterministic keys and conflict-safe insertion.

### 17.1 Approval requested

```text
event_type: manual_approval_requested
actor_type: workflow
actor_identifier: WF04
event_key: onboarding:<case_id>:manual-approval-requested
previous_state: null
new_state: null
```

Sanitized event data may contain:

- external operation identifier;
- expected recipient domain or configured recipient identifier;
- waiting execution identifier;
- response deadline.

It must not contain the response URL or complete email body.

### 17.2 Approval granted

```text
event_type: manual_approval_approved
actor_type: external_user
actor_identifier: configured operator mailbox
event_key: onboarding:<case_id>:manual-approval-approved
previous_state: awaiting_approval
new_state: approved
```

### 17.3 Approval rejected

```text
event_type: manual_approval_rejected
actor_type: external_user
actor_identifier: configured operator mailbox
event_key: onboarding:<case_id>:manual-approval-rejected
previous_state: awaiting_approval
new_state: rejected
```

### 17.4 Approval request failure

```text
event_type: manual_approval_request_failed
event_key: onboarding:<case_id>:manual-approval-request-failed
```

The event contains only stable failure classification and operation identifiers.

## 18. Sanitized response metadata

The step `approval_response_metadata` may contain:

```json
{
  "response_source": "n8n_send_and_wait",
  "expected_recipient": "operator@example.com",
  "decision": "approved",
  "responded_at": "2026-07-18T20:00:00Z",
  "message_id": "gmail-message-id",
  "thread_id": "gmail-thread-id",
  "waiting_execution_id": "12345",
  "operator_comment": "Optional bounded comment"
}
```

The operator comment must be length-limited and control characters removed.

Metadata must not contain:

- Gmail credentials;
- response URL;
- OAuth tokens;
- complete provider headers;
- complete email body;
- unrelated mailbox content.

## 19. Output contract

WF04 returns one sanitized internal result.

### 19.1 Approved

```json
{
  "workflow": "WF04",
  "result": "approved",
  "case_id": "00000000-0000-0000-0000-000000000000",
  "correlation_id": "00000000-0000-0000-0000-000000000000",
  "case_state": "approved",
  "wf05_dispatch": "invoked"
}
```

### 19.2 Rejected

```json
{
  "workflow": "WF04",
  "result": "rejected",
  "case_id": "00000000-0000-0000-0000-000000000000",
  "correlation_id": "00000000-0000-0000-0000-000000000000",
  "case_state": "rejected",
  "wf05_dispatch": "not_required"
}
```

### 19.3 Other results

Allowed results include:

- `active_wait_exists`;
- `busy`;
- `not_due`;
- `not_required`;
- `already_approved`;
- `already_rejected`;
- `failed_retryable`;
- `failed_terminal`.

The output must not contain the response link, Gmail credentials, complete canonical client data, or operator mailbox contents.

## 20. Unexpected technical failure

Unexpected examples include:

- PostgreSQL connection failure;
- missing case, client, submission, or step referenced by authoritative state;
- correlation mismatch;
- operation identity mismatch;
- impossible case/step/operation combination;
- lost lease during decision transaction;
- invalid send-and-wait node output;
- WF05 dispatch acceptance failure.

WF04 invokes WF99 or allows the configured n8n error workflow to process the failure.

Safe context includes, when available:

- workflow name `WF04 — Manual Approval`;
- workflow and execution identifiers;
- case and correlation identifiers;
- step identifier;
- external operation identifier;
- waiting execution identifier;
- stable error class and code;
- retryability classification.

It must not include response URLs, credentials, mailbox contents, or full client data.

## 21. Transaction boundaries

### 21.1 Reservation transaction

Locks and validates the case and approval step, stores the waiting execution reference and expected recipient, and prepares the step.

### 21.2 Operation claim

Atomically creates or resolves and claims the deterministic external operation.

### 21.3 External wait

Gmail send and response waiting occur outside PostgreSQL transactions while the operation has a long valid lease.

### 21.4 Decision transaction

Atomically persists the response, completes the step and operation, updates the case, and inserts events.

### 21.5 Dispatch after commit

WF05 invocation occurs only after the approved transaction commits.

## 22. Concurrency and idempotency

### 22.1 Concurrent initial invocations

Expected:

- one waiting execution reference wins;
- one operation exists;
- one valid lease owner exists;
- at most one approval message is sent;
- other executions return `active_wait_exists` or `busy`.

### 22.2 Duplicate invocation during wait

No new Gmail message, wait execution, operation, or step attempt is created.

### 22.3 Duplicate response

The first valid response wins. Later responses do not alter the persisted decision.

### 22.4 Late response after recovery

A response from an execution that no longer matches the stored waiting execution reference is ignored and sent to WF99 as a stale-response incident when appropriate.

### 22.5 Retry after clear pre-send failure

The same operation key is reused. A new waiting execution identifier may be stored only after the prior attempt is confirmed to have no active wait and no accepted message.

## 23. Security and privacy

- approval links are bearer response links and must not be logged or persisted outside n8n's protected wait mechanism;
- the workflow must minimize retained execution data;
- complete email content must not be written to business events or errors;
- credentials and OAuth tokens remain in n8n credentials;
- response metadata is sanitized and bounded;
- the configured recipient is never accepted from caller input;
- no approval decision is inferred from email delivery, timeout, or missing response;
- the initial mailbox trust boundary must be stated accurately in documentation.

## 24. Logical execution order

```text
1. Receive internal invocation
2. Validate invocation shape
3. Validate protected configuration
4. Load authoritative case, submission, client, step, and operation
5. Verify awaiting_approval preconditions
6. Resolve completed or active duplicate state
7. Reserve the manual_approval step with current execution ID
8. Build deterministic operation identity and message marker
9. Claim the external operation with a long lease
10. Handle no-send claim outcomes
11. Build minimized approval summary
12. Call Gmail send-and-wait-for-response
13. On response, validate execution, recipient, lease, case, and decision
14. Execute atomic decision transaction
15A. For approval, dispatch WF05 after commit
15B. For rejection, stop processing
16. Return sanitized result
```

On failure:

```text
1. Determine whether Gmail clearly performed no side effect
2. Classify retryable, ambiguous, or terminal
3. Persist operation and step result while lease is owned
4. Keep case awaiting_approval with no decision
5. Invoke WF99 when intervention is required
6. Never resend when delivery or active wait is ambiguous
```

## 25. Acceptance scenarios

### 25.1 Approval happy path

Expected:

- one approval operation and one active wait;
- one Gmail approval message;
- response `approve` persists approved decision and timestamp;
- step becomes completed;
- operation becomes succeeded;
- case becomes approved;
- WF05 dispatch is accepted;
- deterministic events exist.

### 25.2 Rejection happy path

Expected:

- response `reject` persists rejected decision and timestamp;
- `rejected_at` is set;
- step and operation complete;
- case becomes terminal rejected;
- WF05 is not invoked.

### 25.3 Duplicate invocation during wait

Expected:

- no second message;
- no replacement execution reference;
- result `active_wait_exists`.

### 25.4 Concurrent initial invocation

Expected one step owner, one operation, one active wait, and at most one Gmail message.

### 25.5 Duplicate approve response

Expected one approved transition and no duplicate events or WF05 dispatch.

### 25.6 Approve and reject responses racing

Expected one decision only; the first transaction to lock and update the case wins.

### 25.7 Stale response

Expected no state change and a sanitized stale-response incident.

### 25.8 Clear transient Gmail failure

Expected operation `failed_retryable`, due retry time, step `failed_retryable`, no active wait, case still awaiting approval.

### 25.9 Ambiguous Gmail failure

Expected no automatic resend, terminal/intervention handling, and case still awaiting approval.

### 25.10 Timeout

Expected no implicit decision, no WF05 dispatch, intervention handling, and case still awaiting approval.

### 25.11 Invalid configured recipient

Expected no message, terminal configuration failure, and WF99 intervention.

### 25.12 Already approved case

Expected no message and result `already_approved` when persisted records are consistent.

### 25.13 Rejected case

Expected no message, no reopening, and result `already_rejected` when consistent.

### 25.14 WF05 dispatch failure

Expected approved state remains committed, approval is not resent, and WF99 receives safe context.

### 25.15 Sensitive-data persistence check

After success, rejection, duplicate invocation, timeout, delivery failure, and stale response:

- no response URL exists in PostgreSQL, events, errors, or output;
- no Gmail credential exists outside n8n credentials;
- no complete mailbox or email body data exists in errors;
- approval metadata contains only the defined sanitized fields.

## 26. Implementation gate for WF04

The WF04 contract is satisfied only when implementation tests prove:

- approval happy path;
- rejection happy path;
- one active wait per case;
- duplicate and concurrent invocation safety;
- first-response-wins behavior;
- stale and duplicate response handling;
- trusted-recipient enforcement;
- correct case and step transitions;
- external-operation claim and long-lease behavior;
- clear retryable delivery failure handling;
- ambiguous send and lost-wait intervention behavior;
- timeout behavior;
- WF05 dispatch after commit only;
- deterministic events;
- direct PostgreSQL verification;
- absence of response links, credentials, and unnecessary client data from persisted records and retained execution data.

No WF05 implementation may depend on WF04 until this contract and the final cross-workflow contract review are complete.
