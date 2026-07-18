# Stage 5 — Audit Corrections

## 1. Purpose

This document records the corrections found during the post-merge audit of the Stage 5 workflow contracts.

It closes three interruption-recovery gaps before Stage 6 implementation begins:

1. WF04 could persist a `waiting` approval step before the approval external operation was claimed;
2. WF06 could remain in `finalizing` after one successful mandatory operation committed but before the next operation was created or claimed;
3. WF99 could persist an intervention-requiring error before the deterministic intervention-notification operation was created or claimed.

These corrections do not change the approved business flow, PostgreSQL-owned state model, state transitions, table ownership, external-operation types, or workflow responsibility boundaries.

## 2. Normative precedence

This document is a normative addition to the Stage 5 contract set.

Where this document explicitly corrects WF04, WF06, WF98, WF99, or `STAGE5-cross-workflow-review.md`, this document takes precedence for Stage 6 implementation.

All requirements not explicitly corrected here remain unchanged.

## 3. Audit result before corrections

The original Stage 5 review correctly defined:

- workflow responsibility ownership;
- case-state transition ownership;
- deterministic external-operation keys;
- operation claims and leases;
- external-side-effect reconciliation;
- state-gap recovery for `created`, `data_received`, `validation_failed`, `awaiting_approval`, `approved`, and `provisioned`;
- terminal-state protection;
- PostgreSQL as the source of truth.

The audit found that three boundaries still contained a commit gap with no guaranteed automatic recovery path.

Stage 6 must not begin until the corrections below are merged.

## 4. Correction A — WF04 atomic approval reservation and operation claim

### 4.1 Problem

WF04 previously described two logically separate steps:

1. commit the `manual_approval` step as `waiting` with `n8n_wait_execution_id`;
2. create or claim the `send_approval_request` external operation.

An interruption after step reservation but before operation claim could leave:

```text
case.state = awaiting_approval
manual_approval.status = waiting
manual_approval.n8n_wait_execution_id IS NOT NULL
send_approval_request operation does not exist
```

This state cannot safely prove that an approval message was sent or that a valid waiting execution exists.

### 4.2 Corrected transaction boundary

WF04 must reserve the approval step and claim the deterministic approval operation inside one PostgreSQL transaction.

The transaction must:

1. validate protected configuration before database mutation;
2. lock the onboarding case;
3. verify `state = 'awaiting_approval'` and all approval prerequisites;
4. lock the `manual_approval` step;
5. resolve any already-completed or already-active approval state;
6. build or verify the immutable request summary without `waiting_execution_id`;
7. call `claim_external_operation` for:

```text
operation_type: send_approval_request
idempotency_key: onboarding:<case_id>:send-approval-request
lease_owner: WF04:<n8n_execution_id>
```

8. handle the claim outcome inside the same transaction;
9. only for `claimed`, set the step to `waiting`, store the current n8n execution identifier and configured recipient, increment the delivery attempt count, set timestamps, and clear stale errors;
10. commit.

The Gmail send-and-wait node runs only after this transaction commits.

### 4.3 Claim-outcome behavior

#### `claimed`

The transaction commits both:

- an `in_progress` approval operation owned by the current execution;
- a `waiting` approval step referencing the same current execution.

The current execution may call the Gmail send-and-wait node.

#### `busy`

WF04 must not replace the stored waiting execution identifier or recipient.

If the existing step and operation are consistent, return `active_wait_exists` or `busy`.

If they are inconsistent, roll back and send sanitized context to WF99.

#### `not_due`

WF04 must not create a new waiting execution. Return `not_due`.

#### `reuse_succeeded`

WF04 must not send another approval message. It verifies the persisted completed decision and returns the authoritative result.

#### `refused_terminal` or `refused_exhausted`

WF04 must not create a new waiting execution. Operator intervention is required.

### 4.4 Retry preparation

A retryable, clearly pre-send failure may move the approval step from `failed_retryable` to `waiting` only in the same transaction that successfully reclaims the operation.

A new n8n execution identifier may replace the previous identifier only for this proven retry path.

The immutable operation request summary continues to exclude `waiting_execution_id`.

### 4.5 WF04 recovery invariant

After every committed WF04 preparation transaction, one of these must be true:

- no active approval wait and no claimed operation;
- one active approval wait and one matching valid claimed operation;
- one completed approval decision and one consistent succeeded operation;
- one persisted retryable or terminal failure with no falsely active waiting execution.

A committed `waiting` step without a matching operation is prohibited.

## 5. Correction B — WF06 recovery while case state is `finalizing`

### 5.1 Problem

WF06 processes mandatory operations in order:

```text
create_drive_folder
→ create_kickoff_event
→ notify_team
→ completed
```

Each successful operation is committed before WF06 proceeds to the next one.

An execution interruption can therefore leave one of these states:

- Drive succeeded, Calendar operation absent or pending, case still `finalizing`;
- Drive and Calendar succeeded, team-notification operation absent or pending, case still `finalizing`;
- all three operations succeeded, but the case-completion transaction did not run, case still `finalizing`.

No expired lease or due retryable operation necessarily exists in these states.

### 5.2 WF98 finalizing-state gap discovery

WF98 must inspect cases in:

```text
state = finalizing
```

after processing expired leases and due retryable operations.

For each candidate, WF98 reads the three deterministic operation identities in mandatory order.

WF98 must not perform any external action or state transition.

### 5.3 Earliest incomplete operation rules

For each mandatory operation in order:

#### Succeeded and consistent

Continue to inspect the next operation.

#### `in_progress` with a valid lease

Do not dispatch a state-gap recovery. Another execution owns the operation.

#### `in_progress` with an expired lease

Use the existing stale-lease operation retry path.

#### `failed_retryable` with future `next_retry_at`

Do not dispatch yet.

#### `failed_retryable` and due

Use the existing due-operation retry path.

#### `failed_terminal`

Do not bypass it. Send or reuse WF99 intervention handling.

#### Missing or `pending`

Dispatch WF06 using the missing-next-operation recovery payload.

### 5.4 Missing-next-operation payload

WF98 dispatches:

```json
{
  "case_id": "uuid",
  "correlation_id": "uuid",
  "trigger_source": "wf98",
  "recovery_reason": "resume_finalization"
}
```

WF06 must:

1. lock the case;
2. verify the case remains `finalizing`;
3. reread all provisioning and finalization operations;
4. verify every earlier succeeded operation and external identifier;
5. identify the earliest missing or pending mandatory operation;
6. create or claim only that deterministic operation;
7. never repeat a succeeded external side effect.

### 5.5 Completion-gap payload

When all three mandatory operations and steps are consistently succeeded or completed while the case remains `finalizing`, WF98 dispatches:

```json
{
  "case_id": "uuid",
  "correlation_id": "uuid",
  "trigger_source": "wf98",
  "recovery_reason": "complete_finalization"
}
```

WF06 must:

1. lock the case;
2. verify all completion prerequisites again;
3. perform only the completion transaction;
4. move `finalizing → completed` exactly once;
5. insert the deterministic completion event conflict-safely;
6. make no external API call.

### 5.6 WF98 candidate ordering

The corrected WF98 priority is:

```text
1. expired in-progress external-operation leases
2. due failed_retryable external operations
3. data_received pending validation
4. committed pre-finalization state gaps
5. finalizing missing-next-operation gaps
6. finalizing completion gaps
```

The complete run remains bounded by configured batch and dispatch limits.

### 5.7 WF06 recovery invariant

Every non-terminal `finalizing` case must have one of these:

- an active valid lease for the earliest incomplete mandatory operation;
- a due or future retryable operation;
- a deterministic WF98 state-gap candidate;
- all operations succeeded and a deterministic WF98 completion-gap candidate.

A `finalizing` case may not depend on n8n execution memory for continuation.

## 6. Correction C — WF99 atomic error persistence and notification-operation claim

### 6.1 Problem

WF99 previously committed the `error_log` row before creating or claiming the deterministic `notify_operator_intervention` operation.

An interruption in that gap could leave an intervention-requiring error with no notification operation. WF98 cannot retry an operation that does not exist.

### 6.2 Configuration validation

When classification determines that intervention is required, WF99 must validate the protected notification configuration before starting the combined transaction.

This includes:

- operator recipient syntax;
- template configuration;
- lease and maximum-attempt values;
- availability of the configured Gmail credential reference where n8n can validate it before execution.

Secrets remain outside PostgreSQL and Git.

### 6.3 Corrected combined transaction

For an intervention-requiring error, WF99 executes one PostgreSQL transaction that:

1. validates and resolves safe optional references;
2. derives the authoritative correlation identifier;
3. acquires the occurrence advisory lock when a stable occurrence identity exists;
4. reuses the existing matching `error_log` row or inserts one new row;
5. obtains the authoritative `error_id`;
6. builds the deterministic operation identity:

```text
operation_type: notify_operator_intervention
idempotency_key: error:<error_id>:notify-operator-intervention
```

7. builds or verifies the immutable sanitized request summary;
8. calls `claim_external_operation` with lease owner `WF99:<n8n_execution_id>`;
9. handles the claim outcome;
10. commits.

Gmail reconciliation and send occur only after the transaction commits and only for `claimed`.

### 6.4 Non-intervention errors

When intervention is not required, WF99 persists or reuses only the error row. No notification operation is created.

### 6.5 Claim-outcome behavior

#### `claimed`

The error row and recoverable `in_progress` notification operation commit together. WF99 may reconcile or send Gmail.

#### `reuse_succeeded`

No Gmail message is sent. Return `notification_already_sent` after consistency verification.

#### `busy`

Return `notification_busy`. The existing lease owner continues.

#### `not_due`

Return `notification_not_due`.

#### `refused_terminal` or `refused_exhausted`

No send is attempted. Use recursion-safe platform logging for the terminal notification failure.

### 6.6 Crash recovery

If WF99 stops after the combined transaction commits but before Gmail result persistence:

- the notification operation remains `in_progress` with a lease;
- after lease expiry, WF98 dispatches the same operation back to WF99;
- WF99 reclaims it when allowed;
- WF99 searches Sent mail by the deterministic marker before sending;
- an existing message is reused;
- no second notification is sent.

### 6.7 Invalid notification configuration

When the original error is valid but notification configuration cannot be used safely:

- persist the original error row when PostgreSQL is available;
- do not create an invalid external operation;
- emit one minimal recursion-safe platform log entry;
- do not recursively create another WF99 error;
- require configuration repair.

This remains a known last-resort operational path because the same unavailable notification channel cannot report its own configuration failure.

### 6.8 WF99 recovery invariant

For every persisted error that requires intervention and has valid notification configuration, the same committed transaction must also leave one deterministic notification operation in an authoritative claimable, active, successful, retryable, or terminal state.

A valid intervention-requiring error with no notification operation is prohibited.

## 7. Updated recovery matrix

| Persisted condition | Recovery owner |
|---|---|
| WF04 approval preparation interrupted before commit | no partial state; transaction rolls back |
| WF04 approval preparation committed | matching waiting step and claimed operation exist |
| WF06 `finalizing` with missing next operation | WF98 `resume_finalization` dispatch to WF06 |
| WF06 `finalizing` with all mandatory operations succeeded | WF98 `complete_finalization` dispatch to WF06 |
| WF99 intervention error committed before Gmail | matching claimed notification operation exists and later uses stale-lease recovery |
| WF99 notification Gmail side effect ambiguous | WF99 reconciliation by deterministic Sent-mail marker |

## 8. Required Stage 6 tests

### 8.1 WF04

Tests must prove:

- forced failure before the combined preparation transaction commits leaves neither `waiting` step nor claimed operation;
- forced failure after commit leaves both a matching `waiting` step and claimed operation;
- duplicate invocation cannot replace the valid waiting execution;
- retryable pre-send failure can atomically establish one new waiting execution;
- no Gmail message is sent without a committed valid operation lease.

### 8.2 WF06 and WF98

Tests must interrupt execution:

- after Drive success commits and before Calendar claim;
- after Calendar success commits and before notification claim;
- after notification success commits and before case completion.

Each test must prove that WF98 rediscovers the gap, WF06 resumes from PostgreSQL, succeeded resources are reused, and no duplicate folder, event, or email is created.

### 8.3 WF99 and WF98

Tests must interrupt execution:

- after the combined error-and-operation transaction commits but before Gmail send;
- after Gmail accepts the message but before operation success commits.

Each test must prove stale-lease recovery, Gmail marker reconciliation, one error occurrence, one logical notification operation, and at most one operator email.

## 9. Schema compatibility

The corrections use only the existing:

- `onboarding_cases`;
- `onboarding_steps`;
- `onboarding_events`;
- `external_operations`;
- `error_log`;
- advisory locks;
- `claim_external_operation`;
- operation completion functions.

No new table, operation type, case state, or approved state transition is required.

## 10. Corrected Stage 5 decision

After this document is merged and verified:

```text
STAGE 5: PASSED WITH AUDIT CORRECTIONS
```

Stage 6 implementation order remains:

```text
1. WF99 — Central Error Handler
2. WF98 — Retry Dispatcher discovery and dispatch shell
3. WF01 — Intake Deal Won
4. WF02 — Request Client Data
5. WF03 — Receive and Validate Client Data
6. WF04 — Manual Approval
7. WF05 — Provision Client
8. WF06 — Finalize Onboarding
9. Complete WF98 mappings against implemented workflow IDs
10. End-to-end recovery verification
```

Stage 6 may begin only from a clean `main` containing this audit-correction document and the complete original Stage 5 contract set.
