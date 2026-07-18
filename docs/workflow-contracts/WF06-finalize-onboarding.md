# WF06 — Finalize Onboarding

## 1. Purpose

WF06 completes the external finalization work for a successfully provisioned client.

It creates or reuses the Google Drive onboarding folder, creates or reuses the Google Calendar kickoff event, sends or reuses the internal team notification, and moves the onboarding case to terminal state `completed` only after every mandatory operation is persisted as `succeeded`.

PostgreSQL remains the source of truth for case state, required step status, operation status, retry eligibility, external resource identifiers, and audit events.

## 2. Responsibilities

WF06 is responsible for:

- accepting a trusted invocation from WF05 or WF98;
- validating the invocation shape;
- rereading the authoritative case, accepted submission, canonical client, provisioning result, steps, and external operations;
- verifying that the external client account exists;
- conditionally moving the case from `provisioned` or `finalization_failed` to `finalizing`;
- resuming a consistent case already in `finalizing`;
- processing mandatory operations in this exact order:
  1. create or reuse the Google Drive folder;
  2. create or reuse the Google Calendar kickoff event;
  3. send or reuse the internal team notification;
- creating one deterministic external operation per side effect;
- atomically claiming each operation before external activity;
- skipping every operation already persisted as `succeeded`;
- reconciling an ambiguous interrupted execution before creating or sending again;
- storing external resource or message identifiers and sanitized response summaries;
- updating the corresponding onboarding step after each operation;
- stopping after the first operation that cannot succeed;
- moving the case to `finalization_failed` after retryable or terminal failure;
- moving the case to `completed` only after all three mandatory finalization operations succeed;
- setting `completed_at` only with the terminal completion transition;
- scheduling retryable failures for WF98;
- recording deterministic append-only business events;
- sending unexpected and intervention-requiring failures to WF99.

## 3. Explicit non-responsibilities

WF06 must not:

- accept a public webhook;
- create or validate client submissions;
- approve or reject a case;
- provision the external client account;
- call the Mock Provisioning API;
- recreate a Drive folder, Calendar event, or Gmail notification already persisted as succeeded;
- delete successful external resources after a later failure;
- process later operations after an earlier mandatory operation fails;
- mark the case completed from `provisioned` or `finalization_failed` without entering `finalizing`;
- trust external identifiers supplied by WF05 or WF98 without rereading PostgreSQL;
- use n8n execution history as the authoritative record;
- reopen terminal `rejected` or `completed` cases.

## 4. Trigger and invocation model

### 4.1 Initial invocation from WF05

WF05 invokes WF06 only after the provisioning-success transaction commits.

Input:

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

Rules:

- all identifiers are required and non-blank;
- UUID fields must contain valid UUID strings;
- `trigger_source` must equal `wf05`;
- `external_operation_id` must not be present;
- unknown top-level fields are rejected.

### 4.2 Retry invocation from WF98

WF98 invokes WF06 for a due retryable finalization operation.

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
- the operation must belong to the case;
- its type must be `create_drive_folder`, `create_kickoff_event`, or `notify_team`;
- it must be due and claimable;
- resource identifiers and request parameters come from PostgreSQL, not from caller input.

### 4.3 Internal input remains non-authoritative

WF06 must independently load and verify:

- case `id`, `correlation_id`, `state`, `client_id`, `accepted_submission_id`, `external_client_id`, and `completed_at`;
- accepted submission ownership and passed status;
- canonical client;
- successful `provision_client` operation and matching external client identifier;
- completed provisioning step;
- Drive, Calendar, and notification steps;
- all existing finalization operations.

A mismatch is a non-retryable data-integrity failure. No new external side effect is allowed.

## 5. Authoritative preconditions

### 5.1 Initial finalization

Initial finalization may start only when:

```text
case.state = provisioned
case.external_client_id IS NOT NULL
provision_client operation.status = succeeded
provision_client operation.external_id = case.external_client_id
provision_client step.status = completed
```

The case must have an accepted passed submission and linked canonical client.

### 5.2 Retry finalization

A due retry may start when:

```text
case.state = finalization_failed
```

and the referenced operation is `failed_retryable` and due, or an expired `in_progress` lease is recoverable.

### 5.3 Resume from `finalizing`

A controlled duplicate or recovery invocation may inspect a case already in `finalizing`.

It may continue only when:

- no different worker owns a valid lease for the next required operation;
- all persisted successful operations are internally consistent;
- the next incomplete operation can be identified deterministically.

Otherwise it returns `busy` or sends an inconsistency to WF99.

### 5.4 Completed case

When the case is `completed`, WF06 returns `already_completed` only when:

- `completed_at` is non-null;
- Drive, Calendar, and notification operations are all `succeeded`;
- their three steps are completed;
- stored external identifiers are non-blank where required.

It must not call an external service again.

### 5.5 Invalid state

No finalization operation is allowed for cases in any state before `provisioned` or in terminal `rejected`.

## 6. Mandatory order and dependency rules

The order is fixed:

```text
create_drive_folder
→ create_kickoff_event
→ notify_team
→ completed
```

Rules:

- Calendar creation requires a succeeded Drive operation;
- team notification requires succeeded Drive and Calendar operations;
- case completion requires all three operation statuses `succeeded`;
- a succeeded earlier operation is reused and never repeated;
- a pending later operation remains untouched when an earlier operation fails;
- retry resumes at the earliest incomplete mandatory operation.

## 7. Case-state preparation transaction

Before processing an operation, WF06 executes a PostgreSQL transaction that:

1. locks the case;
2. verifies finalization prerequisites;
3. reads all mandatory operation statuses in order;
4. identifies the earliest incomplete operation;
5. verifies the retry invocation references that operation when invoked by WF98;
6. moves the case from `provisioned` or `finalization_failed` to `finalizing` when required;
7. leaves an already consistent `finalizing` case unchanged;
8. locks the corresponding onboarding step;
9. prepares or verifies the immutable operation request summary;
10. calls `claim_external_operation`;
11. when claimed, sets the step to `in_progress` and increments its attempt count;
12. clears stale step error data;
13. commits.

If operation claim or state comparison fails, the complete preparation transaction rolls back.

## 8. Common external-operation protocol

Initial values for all three finalization operations:

```text
lease owner: WF06:<n8n_execution_id>
lease duration: 300 seconds
maximum attempts: 5
```

### 8.1 `claimed`

The current execution may reconcile and perform the specific operation.

### 8.2 `reuse_succeeded`

No external call is allowed. WF06 validates the stored result and proceeds to the next mandatory operation.

### 8.3 `busy`

Another worker owns a valid lease. WF06 returns `busy` and stops.

### 8.4 `not_due`

The retry time has not arrived. WF06 returns `not_due` and stops.

### 8.5 `refused_terminal` or `refused_exhausted`

WF06 stops, keeps the case in `finalization_failed` where applicable, and requires operator intervention.

### 8.6 Lease ownership

Only the current valid lease owner may mark operation success or failure.

## 9. Google Drive folder operation

### 9.1 Operation identity

```text
operation_type: create_drive_folder
idempotency_key: onboarding:<case_id>:create-drive-folder
```

### 9.2 Configuration

Protected configuration:

```text
GOOGLE_DRIVE_PARENT_FOLDER_ID
GOOGLE_DRIVE_USE_SHARED_DRIVE=false
WF06_DRIVE_FOLDER_NAME_TEMPLATE
```

Google authentication uses an n8n credential or OAuth2 credential outside workflow JSON.

### 9.3 Deterministic folder metadata

Initial folder name:

```text
<legal_name> — B2B Onboarding
```

The exact name is stored in the immutable operation request summary.

The folder is created with MIME type:

```text
application/vnd.google-apps.folder
```

The Drive file must include private application properties equivalent to:

```json
{
  "onboardingCaseId": "00000000-0000-0000-0000-000000000000",
  "operationKeyHash": "0123456789abcdef0123456789abcdef"
}
```

`operationKeyHash` is the first 32 lowercase hexadecimal characters of SHA-256 of the operation idempotency key.

### 9.4 Immutable request summary

```json
{
  "parent_folder_id": "configured-parent-id",
  "folder_name": "Example Industries Sp. z o.o. — B2B Onboarding",
  "mime_type": "application/vnd.google-apps.folder",
  "onboarding_case_id": "00000000-0000-0000-0000-000000000000",
  "operation_key_hash": "0123456789abcdef0123456789abcdef"
}
```

The summary must not contain Drive OAuth tokens or complete client data.

### 9.5 Reconciliation before creation

Before creating a folder, WF06 searches within the configured parent for a non-trashed folder with matching `appProperties`.

Outcomes:

- exactly one match: reuse it and do not create another folder;
- no match: create the folder while owning the lease;
- more than one match: terminal ambiguity; do not create another folder.

Folder name alone is not the idempotency key.

### 9.6 Success validation

A successful Drive result must provide:

- non-blank file identifier;
- folder MIME type;
- expected parent relationship where returned;
- matching app properties;
- non-trashed status;
- optional web view link.

The operation `external_id` stores the Drive folder identifier.

### 9.7 Step behavior

The `create_drive_folder` step becomes `completed` only after operation success is persisted.

## 10. Google Calendar kickoff operation

### 10.1 Operation identity

```text
operation_type: create_kickoff_event
idempotency_key: onboarding:<case_id>:create-kickoff-event
```

### 10.2 Dependency

The Drive folder operation must already be `succeeded` with a non-blank folder identifier.

### 10.3 Configuration

Protected configuration:

```text
GOOGLE_CALENDAR_ID
KICKOFF_TIMEZONE=Europe/Warsaw
KICKOFF_DELAY_DAYS=7
KICKOFF_START_LOCAL_TIME=10:00
KICKOFF_DURATION_MINUTES=60
KICKOFF_INTERNAL_ATTENDEE_EMAIL
```

The initial schedule is deterministic:

1. take the successful provisioning operation `completed_at`;
2. convert it to `KICKOFF_TIMEZONE`;
3. add `KICKOFF_DELAY_DAYS` calendar days;
4. set local time to `KICKOFF_START_LOCAL_TIME`;
5. set the end time using `KICKOFF_DURATION_MINUTES`.

No holiday or availability optimization is included in the initial scope.

### 10.4 Event data

Initial summary:

```text
B2B Kickoff — <legal_name>
```

Attendees:

- canonical primary contact email;
- configured internal attendee email.

The description may include:

- external client identifier;
- Drive folder link;
- a safe onboarding reference;
- support contact.

It must not contain form tokens, approval response links, credentials, or full submission JSON.

### 10.5 Private extended properties

The event must contain private extended properties equivalent to:

```json
{
  "onboardingCaseId": "00000000-0000-0000-0000-000000000000",
  "operationKeyHash": "0123456789abcdef0123456789abcdef"
}
```

### 10.6 Immutable request summary

The stored summary includes:

- calendar identifier;
- event summary;
- start and end date-time with time zone;
- attendee addresses;
- Drive folder identifier;
- external client identifier;
- private property values;
- notification behavior.

Retries reconstruct the event from this stored summary.

### 10.7 Reconciliation before creation

WF06 lists events using the private extended property marker.

Outcomes:

- exactly one matching non-cancelled event: reuse it;
- no match: create the event;
- more than one match: terminal ambiguity;
- matching cancelled event: terminal/intervention outcome; do not silently create a replacement.

### 10.8 Creation behavior

The event is created with attendee updates enabled according to protected configuration, initially equivalent to sending updates to all attendees.

The operation `external_id` stores the Calendar event identifier.

The response summary may include `htmlLink`, start, end, attendee count, and status.

### 10.9 Step behavior

The `create_kickoff_event` step becomes `completed` only after operation success is persisted.

## 11. Internal team notification operation

### 11.1 Operation identity

```text
operation_type: notify_team
idempotency_key: onboarding:<case_id>:notify-team
```

### 11.2 Dependencies

Both Drive and Calendar operations must be `succeeded` with non-blank external identifiers.

### 11.3 Configuration

Protected configuration:

```text
TEAM_NOTIFICATION_RECIPIENTS
TEAM_NOTIFICATION_SENDER_NAME
TEAM_NOTIFICATION_TEMPLATE_KEY=onboarding_completed_v1
```

Recipients are configured outside caller input.

### 11.4 Message content

The notification may contain:

- legal company name;
- external client identifier;
- Drive folder link;
- Calendar event link and kickoff time;
- canonical primary contact summary when operationally required;
- deterministic message marker.

It must not contain:

- form tokens;
- approval response links;
- complete submission JSON;
- credentials;
- complete provider responses.

### 11.5 Message marker

```text
b2b-team-notification-<first 24 lowercase hexadecimal characters of SHA-256(idempotency_key UTF-8 bytes)>
```

The marker is included in a reliably searchable part of the sent message.

### 11.6 Immutable request summary

The operation summary includes:

- configured recipients;
- template key;
- Drive folder identifier and safe link;
- Calendar event identifier and safe link;
- kickoff time;
- external client identifier;
- deterministic message marker.

It excludes the complete email body and credentials.

### 11.7 Gmail reconciliation

Before sending after an expired lease or ambiguous previous attempt, WF06 searches Sent mail using the deterministic marker.

Outcomes:

- exactly one match: reuse the existing message identifier;
- no match: send while owning the lease;
- more than one match: terminal ambiguity;
- search unavailable: retryable failure; do not assume no message exists.

The operation `external_id` stores the Gmail message identifier.

### 11.8 Step behavior

The `notify_team` step becomes `completed` only after Gmail acceptance or successful reconciliation is persisted.

## 12. Common success-finalization transaction

After a validated external success or reconciliation, WF06 executes one transaction that:

1. verifies operation identity and lease ownership;
2. completes the operation as `succeeded`;
3. stores the external identifier and sanitized response summary;
4. marks the corresponding step `completed`;
5. sets step `completed_at` using database time;
6. clears step error summary;
7. inserts the deterministic success event;
8. commits.

After commit, WF06 rereads all mandatory operation statuses and proceeds to the next incomplete operation.

## 13. Retryable failure contract

Retryable examples include:

- HTTP 429;
- HTTP 500, 502, 503, or 504 where no permanent contract error is established;
- network timeout;
- temporary DNS or connection failure;
- temporary Google API unavailability;
- temporary Gmail reconciliation-search failure;
- malformed response that can be safely reconciled by marker;
- execution interruption after side effect but before local success persistence.

While owning the lease, WF06 must:

- call `complete_external_operation_failure` with `retryable = true`;
- store a stable error class and sanitized summary;
- set `next_retry_at`;
- mark the corresponding step `failed_retryable`;
- move the case from `finalizing` to `finalization_failed`;
- insert a retryable failure event;
- stop without processing later operations.

Earlier succeeded operations remain unchanged.

## 14. Terminal failure contract

Terminal examples include:

- HTTP 400 caused by an invalid workflow request;
- HTTP 401 or 403 requiring credential or permission correction;
- invalid configured parent folder, calendar, or recipient;
- multiple Drive folders matching the marker;
- multiple Calendar events matching the marker;
- multiple Gmail messages matching the marker;
- cancelled matching Calendar event;
- operation request-summary mismatch;
- maximum attempts exhausted;
- persisted-data inconsistency;
- permanent provider business rejection.

While owning the lease, WF06 must:

- mark the operation `failed_terminal`;
- mark the corresponding step `failed_terminal` and set `completed_at`;
- move the case from `finalizing` to `finalization_failed`;
- insert a terminal failure event;
- call WF99 for operator intervention;
- stop without processing later operations.

No successful resource is deleted automatically.

## 15. Retry schedule

Initial schedule for each operation independently:

```text
attempt 1 failure → retry after 1 minute
attempt 2 failure → retry after 5 minutes
attempt 3 failure → retry after 15 minutes
attempt 4 failure → retry after 1 hour
attempt 5 failure → terminal failure
```

A provider-supplied longer retry delay may extend the platform delay.

WF06 never waits inside the workflow for a retry time.

## 16. Completion transaction

After all mandatory operations are persisted as `succeeded`, WF06 executes one PostgreSQL transaction that:

1. locks the case;
2. verifies `state = 'finalizing'`;
3. verifies the successful provisioning operation and external client identifier;
4. verifies Drive, Calendar, and notification operation statuses are `succeeded`;
5. verifies all corresponding steps are `completed`;
6. conditionally moves the case to `completed`;
7. sets `completed_at` using database time;
8. inserts the deterministic onboarding-completed event;
9. commits.

Conceptually:

```sql
UPDATE onboarding_cases
SET
  state = 'completed',
  completed_at = clock_timestamp()
WHERE id = :case_id
  AND state = 'finalizing';
```

Exactly one row must update unless another execution already committed the same consistent result.

## 17. Business-event contract

All events use deterministic keys and conflict-safe insertion.

### 17.1 Finalization started

```text
event_type: onboarding_finalization_started
event_key: onboarding:<case_id>:finalization:started:<cycle_number>
actor_type: workflow
actor_identifier: WF06
previous_state: provisioned or finalization_failed
new_state: finalizing
```

The cycle number must be derived deterministically from persisted finalization attempts, not from n8n memory.

### 17.2 Drive folder created or reused

```text
event_type: drive_folder_ready
event_key: onboarding:<case_id>:create-drive-folder:succeeded
```

Event data may contain the Drive folder identifier and whether it was reconciled.

### 17.3 Kickoff event created or reused

```text
event_type: kickoff_event_ready
event_key: onboarding:<case_id>:create-kickoff-event:succeeded
```

### 17.4 Team notified

```text
event_type: team_notification_sent
event_key: onboarding:<case_id>:notify-team:succeeded
```

### 17.5 Retryable operation failure

```text
event_type: finalization_operation_failed_retryable
event_key: onboarding:<case_id>:<operation_type>:attempt:<attempt_count>:failed-retryable
previous_state: finalizing
new_state: finalization_failed
```

### 17.6 Terminal operation failure

```text
event_type: finalization_operation_failed_terminal
event_key: onboarding:<case_id>:<operation_type>:failed-terminal
previous_state: finalizing
new_state: finalization_failed
```

### 17.7 Onboarding completed

```text
event_type: onboarding_completed
event_key: onboarding:<case_id>:completed
previous_state: finalizing
new_state: completed
```

Event data contains external identifiers and completion references only where required. Complete client data and message bodies are excluded.

## 18. Interrupted execution recovery

### 18.1 Crash after Drive creation

After lease expiry, WF06 searches by Drive app properties, finds the existing folder, and persists success without creating another folder.

### 18.2 Crash after Calendar creation

After lease expiry, WF06 searches by private extended property, finds the existing event, and persists success without creating another event.

### 18.3 Crash after team email send

After lease expiry, WF06 searches Sent mail by message marker, finds the existing message, and persists success without sending another email.

### 18.4 Crash between successful operations

WF06 rereads operation statuses and starts at the earliest incomplete mandatory operation.

### 18.5 No compensation

A later failure never deletes or recreates earlier successful resources automatically.

## 19. Output contract

### 19.1 Completed

```json
{
  "workflow": "WF06",
  "result": "completed",
  "case_id": "00000000-0000-0000-0000-000000000000",
  "correlation_id": "00000000-0000-0000-0000-000000000000",
  "case_state": "completed",
  "external_client_id": "mock_client_0123456789abcdef01234567",
  "drive_folder_id": "drive-folder-id",
  "kickoff_event_id": "calendar-event-id",
  "team_message_id": "gmail-message-id"
}
```

### 19.2 Other results

Allowed results include:

- `already_completed`;
- `busy`;
- `not_due`;
- `not_required`;
- `failed_retryable`;
- `failed_terminal`.

Output excludes complete client data, email body, credentials, and full provider responses.

## 20. Unexpected technical failures

Unexpected examples include:

- PostgreSQL connection failure;
- missing successful provisioning prerequisite;
- correlation mismatch;
- impossible operation order;
- operation request-summary mismatch;
- lost lease;
- provider response cannot be parsed;
- completion compare-and-set failure;
- inconsistent external identifiers.

WF06 invokes WF99 or allows the configured n8n error workflow to process the failure.

Safe context includes, when available:

- workflow name `WF06 — Finalize Onboarding`;
- workflow and execution identifiers;
- case, correlation, client, submission, step, and operation identifiers;
- current mandatory operation type;
- provider name and HTTP status;
- stable error class and code;
- retryability classification.

It must not include credentials, complete client data, complete messages, or unrelated provider responses.

## 21. Transaction boundaries

- case preparation and operation claim are atomic;
- each external API call occurs outside PostgreSQL transactions;
- each operation success or failure is finalized atomically;
- the next operation starts only after prior success commits;
- terminal case completion is a separate final atomic transaction.

## 22. Concurrency and idempotency

### 22.1 Concurrent initial invocation

One execution moves the case to `finalizing` and claims the earliest incomplete operation. Others return `busy` or reuse persisted success.

### 22.2 Concurrent retries

Only one worker claims the due operation. Later operations cannot be claimed out of order.

### 22.3 Duplicate external resources

Marker reconciliation prevents duplicate creation or send. Multiple marker matches are terminal ambiguity, not a reason to create another resource.

### 22.4 Concurrent completion

Only one transaction moves the case to `completed`. Repeated executions return `already_completed` after consistency verification.

## 23. Security and data minimization

- Google and Gmail credentials remain in protected n8n credentials;
- parent folder, calendar, internal attendees, and team recipients are protected configuration;
- external resource markers contain case and operation identity but no secrets;
- Drive and Calendar descriptions contain only operationally required data;
- complete submissions and approval responses are not copied into operations or events;
- Gmail messages exclude secrets and form links;
- provider errors are sanitized before persistence;
- access permissions for the Drive parent and Calendar are configured outside WF06;
- successful resources are not automatically deleted after later failure.

## 24. Logical execution order

```text
1. Receive and validate internal invocation
2. Load authoritative case, client, submission, provisioning, steps, and operations
3. Resolve completed, invalid, busy, and retry-not-due outcomes
4. Identify earliest incomplete mandatory operation
5. Transition case to finalizing and claim that operation atomically
6A. For Drive: reconcile by appProperties, then create only if absent
6B. For Calendar: verify Drive success, reconcile by private properties, then create only if absent
6C. For team email: verify Drive and Calendar success, reconcile Sent marker, then send only if absent
7. Persist operation success and complete its step
8. Repeat from earliest incomplete operation
9. When all operations succeeded, atomically move case to completed
10. Return sanitized completion output
```

On failure:

```text
1. Classify retryable, terminal, or ambiguous
2. Persist operation and step failure while lease is owned
3. Move case to finalization_failed
4. Stop later operations
5. Invoke WF99 when intervention is required
6. Preserve all earlier successful resources
```

## 25. Acceptance scenarios

### 25.1 Full happy path

Expected one Drive folder, one Calendar event, one team message, all operations succeeded, all steps completed, and case completed.

### 25.2 Duplicate WF06 after completion

No external calls; result `already_completed` after consistency verification.

### 25.3 Drive transient failure

Drive operation and step become retryable, case becomes finalization_failed, Calendar and notification remain pending.

### 25.4 Drive crash after creation

Retry finds exactly one marked folder and persists success without duplication.

### 25.5 Calendar transient failure after Drive success

Drive remains succeeded and is reused; Calendar retry resumes without recreating Drive.

### 25.6 Calendar crash after creation

Retry finds the marked event and persists success without duplication.

### 25.7 Team Gmail transient failure

Drive and Calendar remain succeeded; only notification is retried.

### 25.8 Crash after team email send

Retry finds the marked Sent message and does not send again.

### 25.9 Multiple Drive matches

Terminal ambiguity, no new folder, case finalization_failed, WF99 intervention.

### 25.10 Multiple Calendar matches

Terminal ambiguity, no new event, no notification.

### 25.11 Multiple Gmail matches

Terminal ambiguity and no additional message.

### 25.12 Permission failure

HTTP 401 or 403 is terminal until configuration is corrected; no uncontrolled retry.

### 25.13 Concurrent initial invocation

One operation claim and at most one external side effect.

### 25.14 Out-of-order retry request

WF98 references a later operation while an earlier mandatory operation is incomplete; WF06 rejects the dispatch without side effects.

### 25.15 Completion prerequisite failure

Case cannot become completed unless every mandatory operation and step is succeeded/completed.

### 25.16 Data minimization

No secrets, complete submissions, approval links, or complete provider responses exist in events, errors, operation summaries, or output.

## 26. Implementation gate for WF06

The WF06 contract is satisfied only when implementation tests prove:

- fixed Drive → Calendar → notification order;
- happy path and terminal completion;
- operation claim and lease concurrency safety;
- Drive marker creation and reconciliation;
- Calendar private-property creation and reconciliation;
- Gmail marker send and reconciliation;
- reuse of every persisted successful operation;
- partial-failure recovery without compensation;
- retry scheduling per operation;
- terminal and ambiguity handling;
- out-of-order retry suppression;
- correct case and step transitions;
- deterministic events;
- direct PostgreSQL verification;
- no duplicate folder, event, or notification after interrupted execution;
- absence of secrets and unnecessary client data from persisted records and retained execution data.

No Stage 6 implementation may begin until WF98, WF99, and the final cross-workflow contract review are also complete.
