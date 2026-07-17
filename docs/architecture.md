# B2B Client Onboarding Platform — Architecture

## 1. Purpose

The platform automates B2B client onboarding after a CRM deal reaches `Won`.

The architecture preserves authoritative business state in PostgreSQL, prevents duplicate external side effects, supports multiple n8n workers safely, recovers from partial failures, and provides a complete audit trail.

## 2. Business outcome

A completed onboarding case means that:

- exactly one onboarding case exists for the source CRM deal;
- at least one versioned client-data submission exists;
- the accepted submission passed validation;
- the canonical B2B client record was created or reused from validated data;
- an onboarding operator approved the case;
- the external client account exists;
- the Google Drive folder exists;
- the Google Calendar kickoff event exists;
- the internal team notification was sent;
- all business transitions and external operations are recorded;
- the case reached terminal state `completed`.

A rejected onboarding case reaches terminal state `rejected` and does not provision or finalize external resources.

## 3. Initial scope

The initial implementation includes:

- an authenticated `Deal Won` webhook from a controlled mock CRM;
- source-event and source-deal idempotency;
- secure client data collection through an n8n Form Trigger;
- versioned storage of every accepted form submission;
- expiring, single-use form access tokens;
- temporary encrypted token material for safe delivery retries;
- deterministic data normalization and validation;
- canonical B2B client creation or reuse only after validation;
- manual approval through Gmail using an n8n wait-for-response operation;
- client provisioning through a controlled Mock Provisioning API;
- Google Drive folder creation;
- Google Calendar kickoff event creation;
- internal team notification through Gmail to a configured distribution address;
- idempotent operator intervention notifications;
- PostgreSQL persistence of cases, steps, submissions, tokens, events, operations, and errors;
- bounded retries with exponential backoff;
- recovery from interrupted n8n executions and stale operation leases;
- Docker Compose deployment with PostgreSQL, Redis, n8n main, multiple workers, and the Mock Provisioning API.

## 4. Non-goals

The initial implementation does not include:

- a custom frontend application;
- production integration with a proprietary CRM;
- billing or payment processing;
- contract signing;
- AI-based validation or approval decisions;
- multi-tenant SaaS billing;
- a role-management user interface;
- automatic deletion of resources after a later failure;
- automatic reactivation of terminal `rejected` or `completed` cases;
- using n8n execution history as the business source of truth.

## 5. Architectural principles

### 5.1 PostgreSQL owns business state

PostgreSQL stores the authoritative case state, step status, submission history, form-token lifecycle, audit events, external-operation status, and error records.

n8n coordinates work but must always read and conditionally update PostgreSQL before performing state-sensitive actions.

### 5.2 Unvalidated data is not canonical client data

CRM intake metadata and form submissions are not authoritative client records.

Every valid token submission is stored in `onboarding_submissions`. Only a submission that passes validation may create or update a row in `clients` and link that client to the onboarding case.

### 5.3 External side effects are idempotent

Every outbound message and external create operation has a deterministic unique `idempotency_key`.

A retry or duplicate workflow execution must reuse a successful operation result instead of repeating the side effect.

### 5.4 Operation claims are concurrency-safe

Multiple workers may process jobs concurrently. An external operation must be claimed atomically before the external call.

The operation record includes a lease owner and lease expiry. A second worker cannot perform the same operation while a valid lease exists.

### 5.5 State transitions use compare-and-set updates

A workflow changes state only when the current state matches the expected previous state.

Conceptual rule:

```sql
UPDATE onboarding_cases
SET state = :new_state
WHERE id = :case_id
  AND state = :expected_state;
```

The workflow must verify that exactly one row was updated. Zero updated rows means the transition is stale, duplicated, or invalid.

### 5.6 Business failures and technical errors are different

Business outcomes include:

- validation failed;
- approval rejected;
- external operation reached a permanent failure;
- retry limit was exhausted.

Technical errors include:

- database connection failed;
- unexpected workflow exception;
- credential configuration is invalid;
- response payload cannot be parsed.

Business outcomes are represented by case, step, submission, event, and operation records. Unexpected technical failures are additionally stored in `error_log`.

### 5.7 Successful operations are not compensated automatically

When a later operation fails, previously successful external resources are preserved and reused.

The system resumes from persisted state and retries only incomplete work.

## 6. Systems and trust boundaries

### Controlled Mock CRM

Produces an authenticated `Deal Won` webhook containing a unique source event identifier and source deal identifier.

The webhook uses a configured shared secret or signature. Unauthenticated requests are rejected before any business record is created.

### Client

Receives a Gmail message containing a client-specific n8n form link and submits required company and contact data.

Possession of a valid, unexpired form token authorizes one submission for the corresponding onboarding case and request cycle.

### Onboarding operator

Receives the approval request in a configured Gmail mailbox and selects approve or reject.

The initial trust boundary is access to that mailbox. The system records the configured recipient, waiting execution reference, response, timestamp, and workflow metadata, but does not claim cryptographic proof of the physical person who clicked the link.

### n8n

Runs the business workflows, coordinates integrations, and persists every relevant result in PostgreSQL.

### Redis

Provides n8n queue-mode coordination between the main instance and workers. Redis is not a business data store.

### PostgreSQL

Stores all authoritative business and operational records.

### Mock Provisioning API

Creates the external client account. It accepts an idempotency key and returns the same client result for repeated requests with that key.

### Google Drive

Stores one onboarding folder per successfully provisioned case.

### Google Calendar

Stores one kickoff event per successfully provisioned case.

### Gmail

Is used for:

- client data requests and correction requests;
- operator approval requests;
- internal team completion notifications;
- operator intervention notifications.

## 7. High-level flow

```text
Controlled Mock CRM
        │
        │ authenticated Deal Won webhook
        ▼
      WF01
        │
        ▼
PostgreSQL: create or reuse onboarding case
        │
        ▼
      WF02 ── Gmail client form link
        │
        ▼
Client submits n8n Form Trigger
        │
        ▼
      WF03 ── store versioned submission
        ├── invalid data ──→ validation_failed ──→ WF02 with new request cycle
        └── valid data ────→ create or reuse canonical client
                                  │
                                  ▼
                           awaiting_approval ─→ WF04
                                                   ├── reject ─→ rejected
                                                   └── approve
                                                        │
                                                        ▼
                                                      WF05
                                                        │
                                                        ▼
                                              Mock Provisioning API
                                                        │
                                                        ▼
                                                      WF06
                                                        ├── Google Drive
                                                        ├── Google Calendar
                                                        └── Gmail team notification
                                                               │
                                                               ▼
                                                            completed
```

## 8. State machine

### 8.1 States

- `created` — the case was created from the source deal;
- `awaiting_client_data` — a client-data request was delivered successfully and a valid token is active;
- `data_received` — a valid token was consumed and a versioned submission was stored;
- `validation_failed` — the stored submission failed one or more business validation rules;
- `awaiting_approval` — the accepted submission is valid, the canonical client is linked, and operator decision is required;
- `rejected` — terminal state; the operator rejected the case;
- `approved` — the operator approved external provisioning;
- `provisioning` — the client-account operation is active;
- `provisioning_failed` — provisioning did not succeed and is retryable or requires intervention;
- `provisioned` — the external client account exists;
- `finalizing` — Drive, Calendar, or team notification work is active;
- `finalization_failed` — at least one required finalization operation did not succeed;
- `completed` — terminal state; all mandatory operations succeeded.

### 8.2 Allowed transitions

```text
created → awaiting_client_data
awaiting_client_data → data_received
data_received → validation_failed
data_received → awaiting_approval
validation_failed → awaiting_client_data
awaiting_approval → rejected
awaiting_approval → approved
approved → provisioning
provisioning → provisioning_failed
provisioning → provisioned
provisioning_failed → provisioning
provisioned → finalizing
finalizing → finalization_failed
finalizing → completed
finalization_failed → finalizing
```

No transition is allowed from terminal states `rejected` and `completed`.

## 9. Business invariants

### 9.1 Source deal uniqueness

Exactly one onboarding case exists for each source deal:

```text
UNIQUE (source_system, source_deal_id)
```

This rule applies regardless of case state.

### 9.2 Source event uniqueness

Each source event is processed once:

```text
UNIQUE (source_system, source_event_id)
```

Duplicate delivery of the same event returns the already-associated onboarding case. A different event for the same deal also resolves to the existing case through source-deal uniqueness.

### 9.3 Client identity

The accepted submission must include a company identifier and its country and type.

A canonical client is created or reused by the normalized identity tuple:

```text
(company_identifier_country,
 company_identifier_type,
 company_identifier_value_normalized)
```

Email address alone is not used as the B2B client deduplication key.

### 9.4 Submission ownership

Every successfully authorized form submission creates a new immutable submission version for one onboarding case.

A failed submission remains stored with validation errors but cannot update canonical client data.

Only the accepted valid submission identifier is referenced from the onboarding case.

### 9.5 Approval prerequisite

Provisioning is allowed only when:

- case state is `approved`;
- a valid accepted submission is linked;
- a canonical client is linked;
- the approval step is completed with decision `approved`.

### 9.6 Completion prerequisite

The case may enter `completed` only when these mandatory external operations have status `succeeded`:

- provision client account;
- create Drive folder;
- create kickoff event;
- send team notification.

### 9.7 Form token lifecycle

A form token belongs to exactly one case and request cycle.

It has these properties:

- random plain value generated with a cryptographically secure generator;
- SHA-256 hash stored for validation;
- configurable expiry, initially 72 hours;
- one successful atomic consumption;
- invalid after expiry, revocation, or consumption;
- temporary AES-GCM-encrypted token material may exist while delivery is pending;
- the encryption key is stored outside PostgreSQL;
- encrypted token material is cleared after confirmed Gmail delivery.

The submission process must claim and consume the token atomically before storing the submission.

### 9.8 One active approval request

Only one manual-approval step may be active for a case.

The active step stores the n8n waiting execution reference. Duplicate WF04 invocations return the existing active request instead of sending another approval email.

## 10. External operation types

The initial `external_operations` types are:

- `send_client_data_request`;
- `send_approval_request`;
- `provision_client`;
- `create_drive_folder`;
- `create_kickoff_event`;
- `notify_team`;
- `notify_operator_intervention`.

Operations that may legitimately occur multiple times use a key containing their request-cycle entity:

```text
onboarding:<case_id>:form-token:<token_id>:send-client-data-request
onboarding:<case_id>:send-approval-request
onboarding:<case_id>:provision-client
onboarding:<case_id>:create-drive-folder
onboarding:<case_id>:create-kickoff-event
onboarding:<case_id>:notify-team
error:<error_id>:notify-operator-intervention
```

A new correction token produces a new client-request operation. A retry of the same token reuses the same operation key.

## 11. Workflow boundaries

### WF01 — Intake Deal Won

Trigger: authenticated CRM webhook.

Responsibilities:

- authenticate the webhook;
- validate required source fields;
- normalize the source system, event, deal, company, and contact values;
- insert or reuse the onboarding case by source-deal and source-event uniqueness;
- store CRM company and contact values as non-authoritative intake metadata;
- record the source event and case-created business event once;
- invoke WF02 only when the case is `created` and has no successfully delivered data request.

WF01 does not create a canonical client, send the form directly, or provision external resources.

### WF02 — Request Client Data

Trigger: WF01 or the validation-correction path from WF03.

Responsibilities:

- verify the case is `created` or `validation_failed`;
- create a new request cycle when invoked for initial collection or a new failed submission;
- create or reuse the token row for that request cycle;
- generate random token material when the cycle is first created;
- store the token hash and temporary encrypted delivery material;
- create or atomically claim the `send_client_data_request` external operation;
- decrypt the token only in memory to build the n8n Form Trigger URL;
- send the Gmail request to the client;
- store the Gmail message identifier and response summary;
- mark the operation `succeeded` only after confirmed delivery;
- clear encrypted token material after confirmed delivery;
- conditionally move the case to `awaiting_client_data`;
- record the request event.

When Gmail delivery fails before confirmation, WF98 retries the same operation and reuses the encrypted token. WF02 does not create a different token for the same request cycle.

### WF03 — Receive and Validate Client Data

Trigger: n8n Form Trigger.

Responsibilities:

- hash the submitted plain token;
- atomically validate and consume the matching active, unexpired token;
- reject invalid, expired, revoked, or consumed tokens without changing case state;
- record an appropriate sanitized security event for unauthorized submissions;
- normalize submitted values;
- insert a new immutable `onboarding_submissions` version;
- move the case from `awaiting_client_data` to `data_received`;
- execute deterministic validation rules;
- store validation status and detailed errors with the submission;
- update the validation step and append business events;
- on validation failure, move the case to `validation_failed` and invoke WF02 with the failed submission identifier as the new request-cycle key;
- on validation success, atomically create or reuse the canonical client by normalized company identity;
- update canonical client fields from the accepted submission;
- link the accepted submission and canonical client to the case;
- move the case to `awaiting_approval`;
- invoke WF04.

Validation failure is a business outcome, not an unexpected technical error.

### WF04 — Manual Approval

Trigger: WF03 after successful validation.

Responsibilities:

- verify the case is `awaiting_approval` and has an accepted submission and canonical client;
- atomically claim the `manual_approval` step;
- return the existing active wait when the step already contains an active n8n waiting execution;
- create or claim the `send_approval_request` external operation;
- send a Gmail approval request to the configured operator mailbox using the n8n wait-for-response operation;
- store expected recipient, Gmail message identifier, waiting execution reference, and sanitized request metadata;
- wait for approve or reject;
- store the decision, decision time, and response metadata;
- conditionally move the case to terminal `rejected` or to `approved`;
- invoke WF05 only after a successful transition to `approved`.

A duplicate or late response must not change a terminal or already-advanced case.

An approval delivery or waiting-execution failure that cannot be reconciled requires operator intervention rather than automatically sending an uncontrolled duplicate approval request.

### WF05 — Provision Client

Trigger: WF04 after approval or WF98 for a due retry.

Responsibilities:

- verify the case is `approved` or `provisioning_failed`;
- verify the canonical client and accepted submission are linked;
- conditionally move the case to `provisioning`;
- create or atomically claim the `provision_client` external operation;
- call the Mock Provisioning API with the deterministic idempotency key;
- store the external client identifier and response summary;
- mark the operation `succeeded`, `failed_retryable`, or `failed_terminal`;
- move the case to `provisioned` or `provisioning_failed`;
- invoke WF06 only after provisioning succeeds.

### WF06 — Finalize Onboarding

Trigger: WF05 after provisioning or WF98 for a due retry.

Responsibilities:

- verify the case is `provisioned`, `finalizing`, or `finalization_failed`;
- conditionally move the case to `finalizing`;
- process mandatory operations in this order:
  1. create or reuse Drive folder;
  2. create or reuse kickoff Calendar event;
  3. send or reuse team notification;
- atomically claim each operation before its external call;
- skip every operation already marked `succeeded`;
- stop and persist failure when the next required operation cannot succeed;
- move the case to `completed` only when all mandatory operations succeeded;
- otherwise move it to `finalization_failed`.

### WF98 — Retry Dispatcher

Trigger: scheduled execution.

Responsibilities:

- query due `failed_retryable` operations;
- exclude operations that exceeded maximum attempts;
- recover expired `in_progress` leases;
- dispatch the owning workflow for the case and operation type;
- avoid performing the external operation directly.

Initial retry schedule:

```text
attempt 1: immediate
attempt 2: after 1 minute
attempt 3: after 5 minutes
attempt 4: after 15 minutes
attempt 5: after 1 hour
then: manual intervention
```

### WF99 — Central Error Handler

Trigger: n8n error workflow mechanism and explicit calls for unexpected technical failures.

Responsibilities:

- normalize workflow and integration errors;
- store workflow identifier, execution identifier, case, step, submission, operation, error class, message, and sanitized details;
- classify retryability when possible;
- avoid storing credentials, plain tokens, encryption material, or full sensitive payloads;
- create or claim `notify_operator_intervention` using an error-specific idempotency key when manual intervention is required.

WF99 does not independently advance business state without a validated state-specific recovery rule.

## 12. Data model responsibilities

### `clients`

Stores validated canonical B2B company identity, company data, and primary contact data.

Important rules:

- normalized company identifier tuple is unique;
- only validated submissions may create or update canonical fields;
- updates preserve submission and event audit history.

### `onboarding_cases`

Stores:

- source system, source event, and source deal identity;
- non-authoritative intake metadata;
- current authoritative state;
- linked canonical client when validation succeeded;
- accepted submission identifier when validation succeeded;
- correlation identifier;
- approval summary;
- external client identifier;
- created, updated, completed, and rejected timestamps.

### `onboarding_steps`

Stores one row per required business step and case.

Initial step types:

- `collect_client_data`;
- `validate_client_data`;
- `manual_approval`;
- `provision_client`;
- `create_drive_folder`;
- `create_kickoff_event`;
- `notify_team`.

Required properties include status, attempt count, started time, completed time, last error summary, and optional active n8n execution reference.

### `onboarding_submissions`

Stores one immutable version for every authorized form submission.

Required properties include:

- case identifier;
- submission sequence;
- submitted values;
- normalized values;
- validation status;
- validation error details;
- submitted and validated timestamps.

Sensitive values must be minimized and stored only where required by the business process.

### `onboarding_form_tokens`

Stores:

- case and request-cycle identity;
- token hash;
- temporary encrypted token material while delivery is pending;
- token status;
- expiry;
- issued, delivered, consumed, revoked, and updated timestamps.

The plain token is never persisted.

### `onboarding_events`

Append-only business audit trail.

Each event stores:

- event identifier;
- case identifier;
- event type;
- actor type and actor reference when available;
- previous state;
- new state;
- sanitized JSON payload;
- correlation identifier;
- creation timestamp.

### `external_operations`

Stores every recorded external side effect.

Required fields include:

- deterministic unique idempotency key;
- operation type;
- status;
- related case, token, submission, step, or error identifier when applicable;
- attempt count and maximum attempts;
- next retry time;
- lease owner and lease expiry;
- request and response summaries;
- external message or resource identifier;
- last error classification;
- created, started, completed, and updated timestamps.

### `error_log`

Stores normalized unexpected technical and integration errors. It may reference a case, step, submission, and external operation when known.

## 13. External-operation protocol

### 13.1 Statuses

Initial operation statuses:

- `pending`;
- `in_progress`;
- `succeeded`;
- `failed_retryable`;
- `failed_terminal`.

### 13.2 Atomic claim

The database claim operation must perform one of these outcomes atomically:

- insert a new `in_progress` operation with a lease;
- claim a due `pending` or `failed_retryable` operation whose lease is absent or expired;
- return the existing `succeeded` result;
- refuse the claim when another valid lease exists;
- refuse the claim for `failed_terminal` or exhausted retry limit.

### 13.3 External call

The workflow sends the same deterministic idempotency key to integrations that support it.

For Gmail and Google APIs, the stored operation, deterministic case reference, message marker, and external identifiers provide application-level idempotency and reconciliation.

### 13.4 Completion

Only the worker that owns the current lease may mark the operation result.

If the process stops after the external system performed the side effect but before PostgreSQL was updated, the retry path must reconcile by deterministic marker or external identifier before repeating the action.

## 14. Retry and failure handling

### Retryable examples

- HTTP 429;
- HTTP 502, 503, or 504;
- network timeout;
- temporary DNS or connection failure;
- expired worker lease after interruption;
- transient Gmail, Drive, or Calendar API failure.

### Terminal examples

- invalid request payload confirmed by validation;
- invalid permissions requiring configuration change;
- resource creation rejected by a permanent business rule;
- maximum retry attempts exhausted;
- approval waiting execution cannot be reconciled safely.

HTTP 401 or 403 is not retried automatically until credentials or permissions are corrected.

### Partial finalization example

```text
provision_client: succeeded
create_drive_folder: succeeded
create_kickoff_event: failed_retryable
notify_team: pending
```

The retry path reuses the client and Drive folder, retries only the Calendar operation, and sends the notification only after Calendar succeeds.

## 15. Security

- secrets are stored in n8n credentials or environment variables;
- `.env` is excluded from Git;
- `.env.example` contains names and safe placeholders only;
- CRM webhook authentication is mandatory;
- form tokens are random, expiring, and single-use;
- token hashes and temporary AES-GCM ciphertext are stored separately from the encryption key;
- encrypted token material is deleted after successful delivery;
- sensitive request and response data is minimized in submissions, events, and logs;
- credentials, plain tokens, encryption keys, and complete sensitive documents are never logged;
- PostgreSQL and Redis are not exposed publicly in the default deployment;
- the Mock Provisioning API is available only on the internal Docker network unless explicitly required for testing;
- Google credentials use the minimum permissions required for Gmail, Drive, and Calendar operations.

## 16. Observability

PostgreSQL queries must make it possible to determine:

- case count by state;
- cases waiting for client data or approval;
- terminal rejected and completed cases;
- submission count and latest validation result per case;
- failed and exhausted operations;
- retry attempts and next retry times;
- stale operation leases;
- active approval waiting executions;
- average and maximum onboarding duration;
- current status of every required step;
- the business and technical history of one case by correlation identifier.

## 17. Deployment model

Docker Compose will provide:

- PostgreSQL;
- Redis;
- n8n main instance;
- at least two n8n workers;
- Mock Provisioning API.

n8n runs in queue mode. The main instance receives triggers and coordinates executions; workers execute queued jobs.

Persistent volumes are required for PostgreSQL and any n8n data that must survive container recreation.

Exact Docker files are created only after the PostgreSQL schema and tests pass the Stage 2 gate.

## 18. Repository structure

```text
b2b-client-onboarding-platform/
├── README.md
├── .gitignore
├── .env.example
├── docker-compose.yml
├── docs/
│   ├── project-plan.md
│   ├── architecture.md
│   ├── workflow-contracts.md
│   └── test-scenarios.md
├── db/
│   ├── migrations/
│   │   └── 001_foundation.sql
│   └── tests/
│       └── 001_foundation_checks.sql
├── n8n/
│   └── workflows/
├── services/
│   └── mock-provisioning-api/
└── .github/
    └── workflows/
```

Files and directories are added only when their implementation stage starts.

## 19. Architecture acceptance criteria

The architecture stage passes only when all of these statements are true:

- PostgreSQL ownership of business state is unambiguous;
- unvalidated data cannot modify canonical client data;
- every authorized form submission is versioned;
- exactly one onboarding case is enforced per source deal;
- source event delivery is idempotent;
- terminal states and all allowed transitions are explicit;
- validation failure cannot reach approval without corrected data;
- rejection cannot reach provisioning;
- form access has an expiring single-use token design;
- token delivery can be retried without storing a plain token;
- only one approval wait may be active per case;
- approval trust boundary is documented accurately;
- all outbound messages and external resources use `external_operations`;
- operation claiming is safe with multiple workers;
- stale `in_progress` operations have a recovery rule;
- retryable and terminal failures are distinguished;
- partial failure recovery never repeats successful operations;
- workflow responsibilities do not overlap;
- database table responsibilities are sufficient for Stage 2 schema design;
- no unresolved architecture decision blocks PostgreSQL design.
