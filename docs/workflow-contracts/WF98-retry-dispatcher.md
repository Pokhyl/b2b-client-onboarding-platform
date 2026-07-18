# WF98 — Retry Dispatcher

## 1. Purpose

WF98 is the scheduled dispatcher for persisted retryable external operations and expired operation leases.

It reads retry eligibility from PostgreSQL and invokes only the workflow that owns the selected operation. It does not perform Gmail, provisioning, Drive, Calendar, or notification side effects itself.

WF98 provides at-least-once workflow dispatch. Exactly-once external-side-effect safety remains the responsibility of the destination workflow through deterministic operation identity, atomic claims, leases, and reconciliation.

## 2. Responsibilities

WF98 is responsible for:

- running on a fixed schedule;
- using PostgreSQL database time for all due and stale decisions;
- finding `failed_retryable` operations whose `next_retry_at` has arrived;
- finding `in_progress` operations whose lease has expired;
- excluding terminal and succeeded operations;
- detecting impossible retry records and routing them to WF99;
- processing candidates in deterministic bounded batches;
- mapping every supported operation type to exactly one owning workflow;
- passing only safe persisted identifiers to that workflow;
- invoking destination workflows asynchronously;
- continuing with other candidates when one dispatch fails;
- never calling the external service represented by the operation;
- never marking an external operation succeeded;
- never changing onboarding case state directly;
- reporting unexpected dispatcher failures to WF99;
- returning a sanitized run summary.

## 3. Explicit non-responsibilities

WF98 must not:

- create onboarding cases;
- generate form tokens;
- send Gmail messages;
- wait for approval responses;
- call the Mock Provisioning API;
- create Drive folders or Calendar events;
- send team notifications;
- create a replacement external operation;
- change an operation idempotency key or immutable request summary;
- claim an operation on behalf of a destination workflow;
- own a destination operation lease;
- calculate retry eligibility from n8n execution history;
- reset attempt counts;
- retry `failed_terminal` or `succeeded` operations;
- reopen completed or rejected cases;
- block the complete batch because one candidate is malformed.

## 4. Trigger and execution mode

### 4.1 Schedule Trigger

WF98 uses an n8n Schedule Trigger.

Initial cadence:

```text
every 1 minute
```

Equivalent cron expression:

```text
* * * * *
```

The configured workflow timezone is `Europe/Warsaw`, but due comparisons use PostgreSQL `clock_timestamp()` and stored `timestamptz` values.

### 4.2 Workflow concurrency

The production workflow must use an execution-concurrency limit of one active WF98 execution when supported by the deployed n8n version.

This reduces duplicate dispatches but is not the correctness boundary.

Destination workflow claims remain mandatory because:

- manual execution may overlap scheduled execution;
- execution recovery may repeat a batch;
- multiple n8n instances may observe the same due row;
- asynchronous dispatch creates an unavoidable gap before the destination claims the operation.

### 4.3 No public trigger

WF98 must not expose a public Webhook Trigger or Form Trigger.

## 5. Protected configuration

WF98 requires protected configuration equivalent to:

```text
WF98_BATCH_SIZE=50
WF98_MAX_DISPATCHES_PER_RUN=50
WF98_DESTINATION_WAIT_FOR_COMPLETION=false
```

Rules:

- batch size must be an integer from 1 to 200;
- maximum dispatches must be an integer from 1 to 200;
- destination invocation remains asynchronous;
- callers cannot override the mapping or batch limits;
- configuration names may appear in `.env.example`, but secret values do not belong in Git.

## 6. Candidate classes

WF98 processes two candidate classes.

### 6.1 Due retryable operation

A due retry candidate satisfies:

```text
status = failed_retryable
next_retry_at IS NOT NULL
next_retry_at <= clock_timestamp()
attempt_count < max_attempts
```

### 6.2 Expired in-progress lease

A stale lease candidate satisfies:

```text
status = in_progress
lease_owner IS NOT NULL
lease_expires_at IS NOT NULL
lease_expires_at <= clock_timestamp()
```

An expired lease is not itself proof that the external side effect did not happen.

The destination workflow must reclaim the operation and run its operation-specific reconciliation protocol before repeating the side effect.

### 6.3 Excluded rows

WF98 does not dispatch:

- `pending` operations whose owning workflow was never started;
- `succeeded` operations;
- `failed_terminal` operations;
- `failed_retryable` operations whose retry time is in the future;
- `in_progress` operations with a valid unexpired lease.

Recovery for a pending operation whose original workflow dispatch was never accepted belongs to the source-workflow recovery contract or an explicit future pending-operation dispatcher, not to the initial WF98 scope.

## 7. Candidate query contract

WF98 uses one bounded PostgreSQL query or equivalent transaction-safe queries.

Conceptual query:

```sql
SELECT
  operation.id,
  operation.case_id,
  operation.operation_type,
  operation.status,
  operation.attempt_count,
  operation.max_attempts,
  operation.next_retry_at,
  operation.lease_owner,
  operation.lease_expires_at,
  operation.request_summary,
  onboarding_case.correlation_id,
  onboarding_case.state
FROM external_operations AS operation
LEFT JOIN onboarding_cases AS onboarding_case
  ON onboarding_case.id = operation.case_id
WHERE (
  operation.status = 'failed_retryable'
  AND operation.next_retry_at <= clock_timestamp()
  AND operation.attempt_count < operation.max_attempts
)
OR (
  operation.status = 'in_progress'
  AND operation.lease_expires_at <= clock_timestamp()
)
ORDER BY
  CASE
    WHEN operation.status = 'failed_retryable'
      THEN operation.next_retry_at
    ELSE operation.lease_expires_at
  END ASC,
  operation.created_at ASC,
  operation.id ASC
LIMIT :batch_size;
```

The implementation must apply correct parentheses so the ordering and limit operate on the complete candidate union.

### 7.1 Database time

WF98 must not compare due timestamps using the n8n host clock.

### 7.2 Read-only discovery

Candidate discovery does not change operation status or lease ownership.

The destination workflow is the only component allowed to claim the operation through `claim_external_operation`.

### 7.3 At-least-once dispatch

Because discovery does not reserve a separate dispatch record, the same candidate may be dispatched more than once before one destination execution claims it.

This is acceptable only because every destination workflow:

- validates the referenced operation;
- uses the same deterministic idempotency key;
- atomically claims the operation;
- returns `busy`, `not_due`, terminal, or succeeded-reuse outcomes without duplicate side effects.

## 8. Candidate integrity checks

Before dispatch, WF98 validates each row.

### 8.1 Common checks

- operation identifier is a UUID;
- operation type is supported;
- status is `failed_retryable` or stale `in_progress`;
- attempt count is non-negative and does not exceed maximum attempts;
- required due or lease timestamps exist;
- request summary is a JSON object;
- case and correlation data exist when required by the operation type.

### 8.2 Retryable operation at maximum attempts

A normal operation cannot remain `failed_retryable` at or above `max_attempts`, because the failure-completion function should make the last failed attempt terminal.

Such a row is a persisted-data inconsistency.

WF98 must not dispatch it as a normal retry. It sends safe context to WF99.

### 8.3 Stale lease at maximum attempts

A stale `in_progress` operation may already be on its maximum attempt.

WF98 dispatches it to the owner workflow only for operation-specific reconciliation and exhausted-attempt handling.

The destination must not perform another external call if `claim_external_operation` returns `refused_exhausted`.

### 8.4 Missing case

Operations `send_client_data_request`, `send_approval_request`, `provision_client`, `create_drive_folder`, `create_kickoff_event`, and `notify_team` require a non-null existing case.

A missing case is a critical data-integrity failure and is sent to WF99 without normal dispatch.

`notify_operator_intervention` may legitimately have a null case when its source error is not case-specific.

## 9. Operation-to-workflow mapping

The mapping is fixed:

| Operation type | Owning workflow |
|---|---|
| `send_client_data_request` | WF02 — Request Client Data |
| `send_approval_request` | WF04 — Manual Approval |
| `provision_client` | WF05 — Provision Client |
| `create_drive_folder` | WF06 — Finalize Onboarding |
| `create_kickoff_event` | WF06 — Finalize Onboarding |
| `notify_team` | WF06 — Finalize Onboarding |
| `notify_operator_intervention` | WF99 — Central Error Handler |

An unknown operation type is never ignored or guessed. It is sent to WF99 as a non-retryable dispatcher-contract failure.

## 10. Destination payloads

### 10.1 Case-bound operations

WF98 passes:

```json
{
  "case_id": "00000000-0000-0000-0000-000000000000",
  "correlation_id": "00000000-0000-0000-0000-000000000000",
  "external_operation_id": "00000000-0000-0000-0000-000000000000",
  "trigger_source": "wf98"
}
```

Values come from PostgreSQL.

WF98 must not pass:

- credentials;
- complete request or response summaries;
- client form tokens;
- email bodies;
- approval response links;
- provider payloads;
- lease-owner values as authority.

### 10.2 Intervention notification operation

For `notify_operator_intervention`, WF98 passes to WF99:

```json
{
  "external_operation_id": "00000000-0000-0000-0000-000000000000",
  "trigger_source": "wf98"
}
```

WF99 must load the related error identifier and notification data from the operation's immutable request summary.

Case and correlation identifiers may be included only when present in persisted data.

## 11. Dispatch protocol

### 11.1 Asynchronous invocation

WF98 invokes the owning n8n workflow with:

```text
Wait for Sub-Workflow Completion: disabled
```

WF98 considers dispatch accepted when n8n accepts creation or queueing of the destination execution.

It does not wait for the external operation result.

### 11.2 One candidate per invocation

Each destination invocation contains exactly one external operation identifier.

WF98 must not send a batch of unrelated operations to one workflow execution.

### 11.3 Candidate isolation

A dispatch failure for one candidate must not stop later candidates in the same run.

Each item is processed through an isolated error-handling branch.

### 11.4 Dispatch acceptance failure

When n8n cannot accept a destination execution:

- the operation remains unchanged and due;
- WF98 records or sends the technical failure to WF99;
- the next schedule run may try dispatch again;
- WF98 does not change `next_retry_at` to hide the candidate;
- WF98 does not claim the operation itself.

### 11.5 Duplicate dispatch

A duplicate accepted destination execution is not a duplicate external operation. The destination's claim protocol decides which execution may act.

## 12. Retry schedule ownership

WF98 does not calculate or modify normal retry timestamps.

The owning workflow sets `next_retry_at` when it persists a retryable failure.

Initial platform policy:

```text
attempt 1 failure → retry after 1 minute
attempt 2 failure → retry after 5 minutes
attempt 3 failure → retry after 15 minutes
attempt 4 failure → retry after 1 hour
attempt 5 failure → terminal failure
```

WF98 only checks whether the stored timestamp has arrived.

## 13. Stale-lease recovery rules

### 13.1 Destination ownership

WF98 does not clear stale lease columns.

The destination calls `claim_external_operation`, which may replace the expired lease with its own lease and increment the attempt count when allowed.

### 13.2 Reconciliation requirement

After reclaiming a stale lease:

- WF02 reconciles Gmail by message marker;
- WF04 reconciles the approval message and waiting execution and may require intervention;
- WF05 repeats the same API request with the same provider idempotency key;
- WF06 reconciles Drive, Calendar, or Gmail by its deterministic marker;
- WF99 reconciles the intervention message marker.

WF98 never decides whether the previous external side effect occurred.

### 13.3 Long approval lease

A WF04 approval operation has a lease longer than the approval response timeout.

WF98 must not dispatch it while that lease is valid.

After expiry, WF04 determines whether the waiting execution or sent approval request can be reconciled safely.

## 14. Run summary

WF98 returns one sanitized summary item:

```json
{
  "workflow": "WF98",
  "result": "completed",
  "selected_count": 5,
  "dispatch_accepted_count": 4,
  "dispatch_failed_count": 1,
  "integrity_failure_count": 0,
  "batch_limit": 50,
  "started_at": "2026-07-18T20:00:00Z",
  "finished_at": "2026-07-18T20:00:02Z"
}
```

The summary must not contain request summaries, credentials, client data, tokens, email bodies, or complete error stacks.

Per-candidate internal results may contain only:

- operation identifier;
- operation type;
- destination workflow name;
- dispatch result code;
- case identifier when present;
- safe error class.

## 15. Business events and technical logging

WF98 does not create a new business event merely because it dispatched a retry.

The external operation row already records:

- attempt count;
- current status;
- retry time;
- lease;
- failure classification.

The destination workflow records the next business outcome event.

WF98 technical execution logs may contain safe operation and destination identifiers, but not immutable request summaries or personal data.

## 16. Unexpected technical failures

Unexpected examples include:

- PostgreSQL connection failure;
- candidate query failure;
- malformed operation row;
- unknown operation type;
- missing required case or correlation data;
- destination workflow identifier missing from protected mapping;
- n8n dispatch acceptance failure;
- batch-processing exception.

WF98 invokes WF99 or allows the configured n8n error workflow to process the failure.

Safe context includes, when available:

- workflow name `WF98 — Retry Dispatcher`;
- execution identifier;
- operation identifier and type;
- case and correlation identifiers;
- destination workflow name;
- safe error class and code;
- occurrence time.

It must not include operation request summaries, response summaries, credentials, tokens, or full client data.

## 17. Transaction boundaries

### 17.1 Candidate discovery

Read-only bounded query using database time.

### 17.2 Destination dispatch

Occurs outside PostgreSQL transactions.

WF98 must not hold database row locks while waiting for n8n to accept a sub-workflow execution.

### 17.3 No dispatcher state mutation

The initial design does not introduce a separate retry-dispatch table or dispatch status.

Operation state changes are performed only by the owning workflow after claim.

## 18. Concurrency contract

### 18.1 Overlapping WF98 runs

Overlapping runs may select the same candidate.

The destination operation claim prevents two workers from executing the same side effect concurrently.

### 18.2 Multiple candidates for one case

WF98 may select multiple due operations for the same case, but workflow-specific prerequisites and mandatory ordering remain authoritative.

For WF06, an out-of-order operation reference is rejected until earlier mandatory operations succeed.

### 18.3 Dispatch storm protection

The batch and maximum-dispatch limits bound each run.

Workflow concurrency one and one-minute cadence reduce repeated dispatch.

Destination workflows must return quickly for `busy`, `not_due`, and already-succeeded outcomes.

## 19. Security and data minimization

- WF98 has database read access required for candidate selection;
- it does not require Gmail, Drive, Calendar, or provisioning credentials;
- destination mapping is protected configuration or fixed workflow configuration;
- public callers cannot trigger arbitrary internal workflows through WF98;
- operation request summaries are not copied into invocation payloads;
- tokens, response links, credentials, and complete client data are excluded from logs and output;
- all destination identifiers are loaded from persisted operations, not caller input.

## 20. Logical execution order

```text
1. Start scheduled execution
2. Validate batch and destination configuration
3. Query due retryable and stale-lease candidates using database time
4. Sort and limit candidates deterministically
5. For each candidate:
   a. validate operation integrity
   b. map operation type to owner workflow
   c. build minimal persisted-identifier payload
   d. invoke owner asynchronously
   e. record safe dispatch result
   f. continue regardless of another candidate's failure
6. Return sanitized run summary
```

WF98 never performs the external operation.

## 21. Acceptance scenarios

### 21.1 No due operations

Expected zero selected and zero dispatches; successful run summary.

### 21.2 Due WF02 operation

Expected one asynchronous WF02 invocation with case, correlation, and operation identifiers only.

### 21.3 Due WF04 operation

Expected one asynchronous WF04 invocation; WF98 does not send approval email.

### 21.4 Due WF05 operation

Expected one asynchronous WF05 invocation; WF98 does not call the Mock API.

### 21.5 Due WF06 operation

Expected one asynchronous WF06 invocation for Drive, Calendar, or team notification.

### 21.6 Due WF99 notification

Expected one asynchronous WF99 invocation using the persisted intervention operation.

### 21.7 Retry time in future

Operation is not selected.

### 21.8 Valid active lease

Operation is not selected.

### 21.9 Expired lease

Operation is selected and sent to its owner for claim and reconciliation.

### 21.10 Retryable row at maximum attempts

No normal retry dispatch; safe integrity failure sent to WF99.

### 21.11 Unknown operation type

No guessed destination; WF99 receives safe dispatcher-contract failure.

### 21.12 Missing case for case-bound operation

No normal dispatch; critical integrity failure.

### 21.13 Destination dispatch acceptance failure

Operation remains unchanged and due; later candidates continue; next schedule may retry dispatch.

### 21.14 Overlapping WF98 executions

Duplicate destination executions may be accepted, but only one destination obtains the operation lease and performs reconciliation or side effect.

### 21.15 Batch limit

When more candidates are due than the limit, only the deterministic first batch is dispatched; remaining rows stay due for the next run.

### 21.16 Data minimization

No operation request summary, provider response, token, email body, or credential appears in destination payloads, run summary, or normal logs.

## 22. Implementation gate for WF98

The WF98 contract is satisfied only when implementation tests prove:

- scheduled one-minute execution;
- database-time due selection;
- stale-lease selection;
- future retry and active lease exclusion;
- fixed operation-to-workflow mapping;
- minimal safe destination payloads;
- asynchronous dispatch;
- one-candidate failure isolation;
- batch and dispatch limits;
- duplicate-dispatch safety through destination claims;
- no external integrations called directly;
- no direct case or operation status mutation;
- malformed and unknown operation handling through WF99;
- direct PostgreSQL verification;
- absence of secrets, personal data, and operation payloads from logs and output.

WF99 and the final cross-workflow contract review must be complete before Stage 6 begins.
