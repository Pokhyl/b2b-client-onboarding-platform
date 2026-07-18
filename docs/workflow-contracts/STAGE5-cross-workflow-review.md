# Stage 5 — Cross-Workflow Contract Review

## 1. Purpose

This document performs the final Stage 5 consistency review for:

- WF01 — Intake Deal Won;
- WF02 — Request Client Data;
- WF03 — Receive and Validate Client Data;
- WF04 — Manual Approval;
- WF05 — Provision Client;
- WF06 — Finalize Onboarding;
- WF98 — Retry Dispatcher;
- WF99 — Central Error Handler.

It verifies workflow ownership, input and output compatibility, PostgreSQL state transitions, external-operation identity, retry and recovery behavior, security boundaries, and end-to-end interruption recovery before n8n implementation begins.

## 2. Normative precedence

This review is a normative part of the workflow contract set.

When a rule in this document explicitly resolves or amends an earlier workflow contract, this document takes precedence for Stage 6 implementation.

The original workflow contract remains authoritative for every subject not amended here.

No implementation may use this precedence rule to ignore an unrelated workflow requirement.

## 3. Review result

Stage 5 passes after applying the normative resolutions in this document.

The review found no required change to the fixed business flow, PostgreSQL-owned state model, state-machine transition list, table ownership, external-operation types, or separation between business events and technical errors.

The review found and resolves these cross-workflow issues:

1. WF04 included a mutable waiting execution identifier in an immutable external-operation request summary;
2. WF04 did not define an exact bounded delivery retry schedule;
3. WF98 and WF99 used different payload shapes for intervention-notification retries;
4. committed PostgreSQL state could remain without the next workflow when asynchronous dispatch acceptance failed;
5. WF03 needed an internal recovery path for a pending submission after token consumption;
6. the finalization-cycle event key needed one exact deterministic derivation;
7. the completed manual-approval step must retain fields required by the current PostgreSQL constraints.

All seven issues are resolved below without changing the approved architecture or current foundation schema.

## 4. End-to-end workflow chain

The authoritative chain is:

```text
WF01
  created
  → WF02

WF02
  awaiting_client_data
  → public WF03 form submission

WF03 invalid
  validation_failed
  → WF02 correction cycle

WF03 valid
  awaiting_approval
  → WF04

WF04 rejected
  rejected [terminal]

WF04 approved
  approved
  → WF05

WF05 success
  provisioned
  → WF06

WF06 success
  completed [terminal]
```

WF98 provides persisted retry and state-gap dispatch.

WF99 records unexpected technical failures and performs bounded intervention notification.

## 5. Workflow ownership matrix

| Responsibility | Owner |
|---|---|
| Authenticate CRM Deal Won webhook | WF01 |
| Create or reuse onboarding case | WF01 |
| Create and deliver client form token | WF02 |
| Consume token and store submission | WF03 |
| Validate submission | WF03 |
| Create or update canonical client | WF03 |
| Request and persist manual decision | WF04 |
| Provision external client | WF05 |
| Create Drive folder | WF06 |
| Create Calendar kickoff event | WF06 |
| Notify internal team | WF06 |
| Select due operations and state gaps | WF98 |
| Normalize technical errors | WF99 |
| Notify operator about intervention | WF99 |

No responsibility is assigned to two workflows as an external-side-effect owner.

## 6. State-transition ownership

| Transition | Owner |
|---|---|
| new case → `created` | WF01 through case insert |
| `created` → `awaiting_client_data` | WF02 |
| `awaiting_client_data` → `data_received` | WF03 token-consumption function |
| `data_received` → `validation_failed` | WF03 |
| `validation_failed` → `awaiting_client_data` | WF02 |
| `data_received` → `awaiting_approval` | WF03 |
| `awaiting_approval` → `rejected` | WF04 |
| `awaiting_approval` → `approved` | WF04 |
| `approved` → `provisioning` | WF05 |
| `provisioning` → `provisioning_failed` | WF05 |
| `provisioning_failed` → `provisioning` | WF05 |
| `provisioning` → `provisioned` | WF05 |
| `provisioned` → `finalizing` | WF06 |
| `finalizing` → `finalization_failed` | WF06 |
| `finalization_failed` → `finalizing` | WF06 |
| `finalizing` → `completed` | WF06 |

WF98 and WF99 never perform these transitions directly.

Every transition uses PostgreSQL compare-and-set behavior and verifies exactly one updated row or an already-consistent authoritative result.

## 7. Direct workflow payload compatibility

### 7.1 WF01 → WF02

The payload is compatible:

```json
{
  "case_id": "uuid",
  "correlation_id": "uuid",
  "trigger_source": "wf01",
  "request_cycle_key": "initial"
}
```

### 7.2 WF03 invalid → WF02

The payload is compatible:

```json
{
  "case_id": "uuid",
  "correlation_id": "uuid",
  "trigger_source": "wf03",
  "request_cycle_key": "validation_failed:<submission_id>",
  "failed_submission_id": "uuid"
}
```

### 7.3 WF03 valid → WF04

The payload is compatible:

```json
{
  "case_id": "uuid",
  "correlation_id": "uuid",
  "accepted_submission_id": "uuid",
  "client_id": "uuid",
  "trigger_source": "wf03"
}
```

### 7.4 WF04 approved → WF05

The payload is compatible:

```json
{
  "case_id": "uuid",
  "correlation_id": "uuid",
  "client_id": "uuid",
  "accepted_submission_id": "uuid",
  "trigger_source": "wf04"
}
```

### 7.5 WF05 provisioned → WF06

The payload is compatible:

```json
{
  "case_id": "uuid",
  "correlation_id": "uuid",
  "client_id": "uuid",
  "accepted_submission_id": "uuid",
  "external_client_id": "non-blank string",
  "trigger_source": "wf05"
}
```

Every destination rereads authoritative PostgreSQL data and treats input identifiers only as routing and integrity-check context.

## 8. External-operation ownership and keys

| Operation type | Owner | Deterministic key |
|---|---|---|
| `send_client_data_request` | WF02 | `onboarding:<case_id>:form-token:<token_id>:send-client-data-request` |
| `send_approval_request` | WF04 | `onboarding:<case_id>:send-approval-request` |
| `provision_client` | WF05 | `onboarding:<case_id>:provision-client` |
| `create_drive_folder` | WF06 | `onboarding:<case_id>:create-drive-folder` |
| `create_kickoff_event` | WF06 | `onboarding:<case_id>:create-kickoff-event` |
| `notify_team` | WF06 | `onboarding:<case_id>:notify-team` |
| `notify_operator_intervention` | WF99 | `error:<error_id>:notify-operator-intervention` |

The operation owner alone:

- creates or reuses its operation;
- claims it;
- performs reconciliation;
- performs the external side effect;
- completes success or failure.

WF98 dispatches but never claims or performs the side effect.

## 9. Normative resolution: WF04 immutable request summary

The WF04 `send_approval_request` operation request summary must not contain:

```text
waiting_execution_id
```

The waiting execution identifier changes between a clearly failed pre-send attempt and a later retry, while `external_operations.request_summary` is immutable.

The authoritative waiting execution identifier is stored only in:

```text
onboarding_steps.n8n_wait_execution_id
```

The immutable WF04 operation request summary contains only stable values:

```json
{
  "recipient_email": "operator@example.com",
  "template_key": "manual_approval_v1",
  "case_id": "uuid",
  "accepted_submission_id": "uuid",
  "client_id": "uuid",
  "message_marker": "b2b-approval-..."
}
```

Every retry verifies the current step execution reference separately from the immutable operation summary.

This resolution supersedes the WF04 example that included `waiting_execution_id` in `request_summary`.

## 10. Normative resolution: WF04 retry schedule

WF04 uses:

```text
maximum attempts: 3
```

The exact clear pre-send failure schedule is:

```text
attempt 1 failure → retry after 1 minute
attempt 2 failure → retry after 5 minutes
attempt 3 failure → terminal failure
```

A delivery state that is ambiguous, a lost waiting execution, a timeout, HTTP 401 or 403, or another unreconcilable failure is terminal immediately and is not placed on this schedule.

WF98 dispatches only a stored due `failed_retryable` approval operation.

## 11. Normative resolution: WF98 → WF99 retry payload

For `notify_operator_intervention`, WF98 passes exactly:

```json
{
  "source_variant": "notification_retry",
  "trigger_source": "wf98",
  "external_operation_id": "uuid"
}
```

WF99 loads the source error and notification data from PostgreSQL.

This resolution supersedes the shorter WF98 example that omitted `source_variant`.

## 12. Dispatch acceptance and business completion

An asynchronous workflow dispatch result means only that n8n accepted creation or queueing of the destination execution.

It does not mean that the destination completed.

Source workflows must distinguish:

```text
dispatch accepted
```

from:

```text
destination business result completed
```

A source workflow never waits for the destination business result unless its specific contract explicitly defines a synchronous call. The initial chain uses asynchronous sub-workflow dispatches.

## 13. Post-commit dispatch-gap problem

These transactions commit before the next workflow is invoked:

- WF01 commits `created` before WF02 dispatch;
- WF03 commits `validation_failed` before correction WF02 dispatch;
- WF03 commits `awaiting_approval` before WF04 dispatch;
- WF04 commits `approved` before WF05 dispatch;
- WF05 commits `provisioned` before WF06 dispatch.

WF03 may also commit token consumption and `data_received` before validation processing completes.

If n8n stops or rejects the next sub-workflow dispatch after commit, authoritative PostgreSQL state remains correct but processing can stall.

The initial WF98 operation-only query cannot recover a state for which the destination workflow never created an external operation.

The following state-gap recovery contract resolves this issue.

## 14. Normative extension: WF98 state-gap recovery

WF98 processes two categories:

1. external-operation candidates already defined in the WF98 contract;
2. state-gap candidates defined here.

WF98 remains a dispatcher. It does not execute business logic or external side effects.

### 14.1 Candidate priority

Each scheduled run processes candidates in this priority:

```text
1. expired in-progress operation leases
2. due failed_retryable operations
3. data_received pending validation
4. committed state gaps with no owning operation or active execution
```

The combined run remains bounded by protected batch and dispatch limits.

### 14.2 State-gap locking

Discovery is read-only and may select the same state gap more than once.

The destination workflow must lock the case and related rows and revalidate the gap before doing any work.

At-least-once dispatch is allowed. Duplicate external effects remain prohibited by destination claims and deterministic identities.

## 15. Recovery candidate: `created`

WF98 may dispatch WF02 when:

```text
case.state = created
```

and no `send_client_data_request` operation for the case is:

- `in_progress` with a valid lease;
- `failed_retryable` with a future retry time;
- `succeeded`;
- `failed_terminal`.

An existing `issued` token without an operation does not block recovery. WF02 must reuse that token and create or claim its deterministic operation.

Payload:

```json
{
  "case_id": "uuid",
  "correlation_id": "uuid",
  "trigger_source": "wf98",
  "recovery_reason": "missing_initial_dispatch",
  "request_cycle_key": "initial"
}
```

WF02 accepts this as an initial-cycle recovery variant only under the authoritative `created` precondition.

## 16. Recovery candidate: `data_received`

WF98 may dispatch WF03 when:

```text
case.state = data_received
```

and exactly one submission for the case has:

```text
validation_status = pending
```

The submission must be the latest sequence for the case and its token must be `consumed`.

Payload:

```json
{
  "case_id": "uuid",
  "correlation_id": "uuid",
  "submission_id": "uuid",
  "trigger_source": "wf98",
  "recovery_reason": "pending_submission_validation"
}
```

WF03 accepts this internal recovery variant without a public form token.

WF03 must:

- lock and reread the pending immutable submission;
- verify the case is still `data_received`;
- verify the token is already consumed;
- skip token decoding and submission creation;
- resume from collection-step completion and deterministic validation;
- use the existing submission identifier and sequence;
- never create a replacement submission.

Zero or more than one pending submission is a data-integrity failure sent to WF99.

## 17. Recovery candidate: `validation_failed`

WF98 may dispatch WF02 when:

```text
case.state = validation_failed
```

and the latest failed submission has no active or terminal correction delivery operation for its deterministic request cycle.

The cycle is:

```text
validation_failed:<failed_submission_id>
```

Payload:

```json
{
  "case_id": "uuid",
  "correlation_id": "uuid",
  "trigger_source": "wf98",
  "recovery_reason": "missing_correction_dispatch",
  "request_cycle_key": "validation_failed:<submission_id>",
  "failed_submission_id": "uuid"
}
```

WF02 accepts this correction-recovery variant only when the submission belongs to the case and remains `failed`.

An existing `issued` token for the same cycle is reused.

## 18. Recovery candidate: `awaiting_approval`

WF98 may dispatch WF04 when:

```text
case.state = awaiting_approval
```

and all of these are true:

- accepted submission and canonical client are linked;
- no approval decision exists;
- the manual-approval step is not `waiting` with a valid execution reference;
- no `send_approval_request` operation is succeeded, terminal, actively leased, or scheduled for future retry;
- no completed approval step exists.

Payload:

```json
{
  "case_id": "uuid",
  "correlation_id": "uuid",
  "trigger_source": "wf98",
  "recovery_reason": "missing_initial_dispatch"
}
```

WF04 loads `client_id` and `accepted_submission_id` from the case and starts only after repeating all approval precondition checks.

## 19. Recovery candidate: `approved`

WF98 may dispatch WF05 when:

```text
case.state = approved
```

and:

- approval records are consistent and completed;
- `external_client_id` is null;
- no `provision_client` operation is succeeded, terminal, actively leased, or scheduled for future retry.

Payload:

```json
{
  "case_id": "uuid",
  "correlation_id": "uuid",
  "trigger_source": "wf98",
  "recovery_reason": "missing_initial_dispatch"
}
```

WF05 loads client and submission references from the case and creates or claims the deterministic provisioning operation only after authoritative verification.

## 20. Recovery candidate: `provisioned`

WF98 may dispatch WF06 when:

```text
case.state = provisioned
```

and:

- the successful provisioning result and external client identifier are consistent;
- no finalization operation is succeeded, terminal, actively leased, or scheduled for future retry;
- Drive, Calendar, and notification steps remain pending.

Payload:

```json
{
  "case_id": "uuid",
  "correlation_id": "uuid",
  "trigger_source": "wf98",
  "recovery_reason": "missing_initial_dispatch"
}
```

WF06 loads every authoritative identifier and begins with the deterministic Drive operation.

## 21. Destination recovery-input rules

WF02, WF03, WF04, WF05, and WF06 accept the WF98 recovery variants defined in sections 15–20 as normative additions to their trigger contracts.

Common rules:

- `trigger_source` must equal `wf98`;
- `recovery_reason` must equal an exact allowed value;
- no external operation identifier is present for a missing-dispatch recovery;
- callers cannot supply business data, recipients, external resource identifiers, or credentials;
- every destination locks and rereads PostgreSQL before action;
- a no-longer-valid gap returns `not_required`, `busy`, or an authoritative completed result;
- a terminal operation or inconsistent state is not bypassed;
- recovery never generates a replacement idempotency key.

## 22. State-gap exclusions

WF98 must not dispatch a missing-initial-workflow recovery when the deterministic owning operation is:

- `succeeded`;
- `failed_terminal`;
- `in_progress` with a valid lease;
- `failed_retryable` with `next_retry_at` in the future.

Due and stale operations use the original operation-retry path, not the state-gap path.

A terminal operation requires WF99 intervention and cannot be bypassed through a missing-dispatch payload.

## 23. Client-data token expiry

The fixed initial state machine and WF02 boundary do not define automatic replacement of a delivered token that expires while the case remains `awaiting_client_data`.

Therefore the initial implementation uses this explicit policy:

- an expired token cannot be reused;
- WF03 returns the generic unavailable-link response;
- the case remains `awaiting_client_data`;
- automatic generation of a replacement cycle is not allowed;
- operator-controlled intervention is required;
- an automatic expiry-reissue feature requires a future documented state and request-cycle policy.

This is a known initial-scope operational limitation, not an implicit retry.

## 24. Normative resolution: manual-approval completed fields

The current PostgreSQL constraints require a completed manual-approval step to retain:

- `n8n_wait_execution_id`;
- `approval_recipient_email`;
- `approval_decision`;
- `approval_decided_at`.

WF04 must not clear the waiting execution identifier or expected recipient when completing the step.

The fields become immutable audit context after the decision.

The term “clear active wait” in WF04 means that no execution is treated as active operationally; it does not mean setting these required audit columns to null.

## 25. Normative resolution: finalization cycle number

WF06 derives the next finalization cycle number inside the case-lock transaction as:

```text
1 + count of existing onboarding_finalization_started events for the case
```

The event key is:

```text
onboarding:<case_id>:finalization:started:<cycle_number>
```

The count and insertion occur while the case row is locked.

A conflict on the deterministic event key causes authoritative rereading, not generation from n8n execution memory.

## 26. Retry ownership consistency

The owning workflow calculates and persists `next_retry_at` when an external operation fails retryably.

WF98 only checks due time.

Retry policies are:

| Workflow | Maximum attempts | Delays before subsequent attempts |
|---|---:|---|
| WF02 client request | 5 | 1m, 5m, 15m, 1h |
| WF04 approval delivery | 3 | 1m, 5m |
| WF05 provisioning | 5 | 1m, 5m, 15m, 1h |
| WF06 each finalization operation | 5 | 1m, 5m, 15m, 1h |
| WF99 intervention notification | 5 | 1m, 5m, 15m, 1h |

An expired lease is dispatched for claim and reconciliation, not treated as proof of a failed external side effect.

## 27. External-side-effect interruption recovery

| Interruption | Recovery |
|---|---|
| Gmail client request sent before DB success commit | WF02 searches Sent mail by deterministic marker |
| Approval message may have been sent before wait state is reconciled | WF04 reconciles or requires intervention; no uncontrolled resend |
| Mock provisioning succeeded before DB commit | WF05 repeats same payload with same provider idempotency key |
| Drive folder created before DB commit | WF06 searches Drive app properties |
| Calendar event created before DB commit | WF06 searches private extended properties |
| Team email sent before DB commit | WF06 searches Sent mail by deterministic marker |
| Intervention email sent before DB commit | WF99 searches Sent mail by deterministic marker |

Successful external resources are reused and never automatically compensated.

## 28. PostgreSQL schema compatibility

The complete contract set uses the current tables:

- `clients`;
- `onboarding_cases`;
- `onboarding_steps`;
- `onboarding_form_tokens`;
- `onboarding_submissions`;
- `onboarding_events`;
- `external_operations`;
- `error_log`.

No additional table or operation type is required by the Stage 5 resolutions.

State-gap discovery is derived from authoritative current state, steps, submissions, tokens, events, and operations.

WF99 occurrence deduplication uses PostgreSQL advisory locks and the existing `error_log` columns, so it does not require a new unique constraint for the initial implementation.

## 29. Step-status consistency

### 29.1 Collect client data

- WF02 sets `in_progress` after successful request delivery or while the cycle is active;
- retryable delivery failure uses `failed_retryable`;
- terminal delivery failure uses `failed_terminal`;
- WF03 sets `completed` after authorized token consumption and submission storage;
- a new correction cycle may move the same step back to `in_progress` and clear `completed_at`.

### 29.2 Validate client data

- WF03 uses `in_progress` while validating a pending submission;
- invalid result uses `failed_retryable` because a corrected submission may be requested;
- valid result uses `completed`;
- the next submission attempt may move the step back to `in_progress`.

### 29.3 Manual approval

- active response wait uses `waiting`;
- clear pre-send retryable failure uses `failed_retryable`;
- unreconcilable failure uses `failed_terminal`;
- approve or reject uses `completed` with retained audit fields.

### 29.4 Provision and finalization steps

- active attempt uses `in_progress`;
- due retry uses `failed_retryable` before reclaim;
- terminal failure uses `failed_terminal`;
- success uses `completed`.

Every `failed_terminal` or `completed` step has `completed_at`; every `in_progress`, `waiting`, or `failed_retryable` step has `completed_at = NULL`.

## 30. Data-ownership consistency

### 30.1 CRM intake data

WF01 stores non-authoritative intake values only in the onboarding case.

WF02 may use intake email solely to request the initial or corrected client submission.

### 30.2 Submitted data

WF03 stores every authorized submission version.

Invalid submitted data never updates `clients`.

### 30.3 Canonical client data

Only WF03 writes canonical client fields from a passed submission.

WF04–WF06 read canonical data and do not change it.

### 30.4 Technical errors

WF99 writes sanitized technical errors to `error_log`.

Technical errors are not duplicated into `onboarding_events` as business outcomes.

## 31. Security-boundary consistency

- CRM webhook authentication belongs to WF01;
- form-token possession authorizes one WF03 submission, not data correctness;
- plain form token never persists;
- temporary token ciphertext exists only before successful WF02 delivery;
- mailbox access is the initial WF04 approval trust boundary;
- operator recipient addresses come from protected configuration;
- external-operation request summaries contain recovery data, not secrets;
- WF99 sanitizes through an allowlist and prevents recursive error loops;
- n8n execution history is not an authoritative business record;
- token-bearing execution data and query logs must be disabled, minimized, or redacted.

## 32. Business-outcome and technical-error separation

These are business outcomes and do not create unexpected error records by themselves:

- invalid submitted client data;
- approval rejection;
- duplicate CRM webhook;
- duplicate workflow invocation handled idempotently;
- invalid, expired, revoked, consumed, or undelivered form token response;
- busy or not-due operation claim;
- retryable failure already persisted correctly.

These are technical or intervention conditions handled by WF99:

- database or n8n failure;
- dispatch acceptance failure;
- data-integrity mismatch;
- idempotency conflict;
- credential or permission failure;
- maximum attempts exhausted;
- ambiguous external side effect;
- unknown workflow or operation type;
- lost approval waiting execution;
- security-policy violation.

## 33. Concurrency consistency

The correctness boundaries are:

- PostgreSQL unique constraints for source identity, request cycles, tokens, submissions, events, clients, and operations;
- row locks for state-sensitive work;
- compare-and-set case transitions;
- atomic external-operation claims;
- valid leases;
- deterministic reconciliation markers;
- advisory lock for stable WF99 error-occurrence deduplication.

n8n workflow concurrency limits reduce load but are never the sole correctness mechanism.

## 34. Terminal-state consistency

`rejected` and `completed` are terminal.

No workflow, WF98 recovery path, or WF99 handler may reopen either state.

WF04 alone creates `rejected`.

WF06 alone creates `completed`.

## 35. Recovery matrix by persisted case state

| Case state | Normal owner | Automatic recovery source |
|---|---|---|
| `created` | WF02 | WF98 missing-dispatch recovery or repeated WF01 event |
| `awaiting_client_data` | client/WF03 | no automatic token-expiry reissue in initial scope |
| `data_received` | WF03 | WF98 pending-validation recovery |
| `validation_failed` | WF02 | WF98 missing-correction recovery or due operation retry |
| `awaiting_approval` | WF04 | WF98 missing-dispatch or due operation retry; ambiguous wait requires intervention |
| `approved` | WF05 | WF98 missing-dispatch recovery |
| `provisioning` | WF05 | WF98 stale-lease recovery |
| `provisioning_failed` | WF05 | WF98 due operation retry |
| `provisioned` | WF06 | WF98 missing-dispatch recovery |
| `finalizing` | WF06 | WF98 stale-lease recovery |
| `finalization_failed` | WF06 | WF98 due operation retry |
| `rejected` | none | terminal |
| `completed` | none | terminal |

## 36. Stage 6 implementation order

Stage 6 proceeds one workflow at a time in this order:

```text
1. WF99 — Central Error Handler
2. WF98 — Retry Dispatcher discovery and dispatch shell
3. WF01 — Intake Deal Won
4. WF02 — Request Client Data
5. WF03 — Receive and Validate Client Data
6. WF04 — Manual Approval
7. WF05 — Provision Client
8. WF06 — Finalize Onboarding
9. Complete WF98 state-gap and operation retry mappings against implemented workflow IDs
10. End-to-end recovery verification
```

WF99 is implemented first because every later workflow depends on safe technical-error handling.

WF98 may be scaffolded early, but mappings are activated only after each destination workflow exists and has passed its own gate.

## 37. Per-workflow implementation gate

Every workflow implementation must prove:

- happy path;
- duplicate invocation;
- invalid state;
- relevant concurrent invocation;
- direct PostgreSQL state verification;
- deterministic event or error persistence;
- no duplicate external side effect;
- retryable failure where applicable;
- terminal failure where applicable;
- interrupted-execution recovery where applicable;
- sensitive-data persistence checks.

A workflow is not complete merely because its n8n execution is green.

## 38. Stage 5 gate checklist

The Stage 5 gate is satisfied:

- [x] every workflow has one primary responsibility;
- [x] all direct workflow inputs and outputs are compatible;
- [x] every case transition has one owner;
- [x] every external operation has one owner and deterministic key;
- [x] operation claim, lease, retry, and reconciliation behavior is defined;
- [x] post-commit dispatch gaps have deterministic recovery paths;
- [x] pending submission validation has a deterministic recovery path;
- [x] terminal operation states cannot be bypassed;
- [x] canonical client data comes only from passed submissions;
- [x] approval trust boundary is explicit;
- [x] business events and technical errors remain separate;
- [x] secrets and bearer tokens are excluded from persisted diagnostic data;
- [x] no approved architecture or foundation-schema change is required;
- [x] terminal cases cannot be reopened;
- [x] implementation and acceptance gates are testable.

## 39. Final Stage 5 decision

```text
STAGE 5: PASSED
```

Stage 6 may begin only from a clean `main` containing this review and all eight workflow contracts.

The first implementation target is WF99 — Central Error Handler, followed by the WF98 dispatch shell and then the business workflows in dependency order.
