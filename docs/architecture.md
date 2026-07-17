# B2B Client Onboarding Platform — Architecture

## 1. Purpose

The platform automates B2B client onboarding after a CRM deal reaches `Won`.

The architecture is designed to preserve authoritative business state in PostgreSQL, prevent duplicate external side effects, support multiple n8n workers safely, recover from partial failures, and provide a complete audit trail.

## 2. Business outcome

A completed onboarding case means that:

- exactly one onboarding case exists for the source CRM deal;
- the B2B client identity and submitted data are stored;
- submitted data passed validation;
- an onboarding operator approved the case;
- the external client account exists;
- the Google Drive folder exists;
- the Google Calendar kickoff event exists;
- the internal team notification was sent;
- all business transitions and external operations are recorded;
- the case reached terminal state `completed`.

A rejected onboarding case reaches terminal state `rejected` and does not provision or finalize any external resources.

## 3. Initial scope

The initial implementation includes:

- an authenticated `Deal Won` webhook from a controlled mock CRM;
- deterministic source-event and source-deal idempotency;
- B2B client creation or reuse by normalized company identifier;
- secure client data collection through an n8n Form Trigger;
- expiring, single-use form access tokens;
- deterministic data normalization and validation;
- manual approval through Gmail using an n8n wait-for-response operation;
- client provisioning through a controlled Mock Provisioning API;
- Google Drive folder creation;
- Google Calendar kickoff event creation;
- internal team notification through Gmail to a configured distribution address;
- PostgreSQL persistence of states, steps, tokens, events, operations, and errors;
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

PostgreSQL stores the authoritative case state, step status, form-token lifecycle, audit events, external-operation status, and error records.

n8n coordinates work but must always read and conditionally update PostgreSQL before performing state-sensitive actions.

### 5.2 External side effects are idempotent

Every external create operation has a deterministic unique `idempotency_key`.

A retry or duplicate workflow execution must reuse a successful operation result instead of creating another resource.

### 5.3 Operation claims are concurrency-safe

Multiple workers may process jobs concurrently. An external operation must be claimed atomically before the API call.

The operation record includes a lease owner and lease expiry. A second worker cannot perform the same operation while a valid lease exists.

### 5.4 State transitions use compare-and-set updates

A workflow changes state only when the current state matches the expected previous state.

Conceptual rule:

```sql
UPDATE onboarding_cases
SET state = :new_state
WHERE id = :case_id
  AND state = :expected_state;
```

The workflow must verify that exactly one row was updated. Zero updated rows means the transition is stale, duplicated, or invalid.

### 5.5 Business failures and technical errors are different

Examples of business outcomes:

- validation failed;
- approval rejected;
- retry limit reached.

Examples of technical errors:

- database connection failed;
- unexpected workflow exception;
- credential configuration is invalid;
- response payload cannot be parsed.

Business outcomes are represented by case, step, event, and operation records. Unexpected technical failures are additionally stored in `error_log`.

### 5.6 Successful operations are not compensated automatically

When a later operation fails, previously successful external resources are preserved and reused.

The system resumes from persisted state and retries only incomplete work.

## 6. Systems and trust boundaries

### Controlled Mock CRM

Produces an authenticated `Deal Won` webhook containing a unique source event identifier and source deal identifier.

The webhook uses a configured shared secret or signature. Unauthenticated requests are rejected before any business record is created.

### Client

Receives a Gmail message containing a client-specific n8n form link and submits required company and contact data.

Possession of a valid, unexpired form token authorizes one form submission for the corresponding onboarding case.

### Onboarding operator

Receives the approval request in a configured Gmail mailbox and selects approve or reject.

The initial trust boundary is access to that mailbox. The system records the configured recipient, response, timestamp, and workflow metadata, but does not claim cryptographic proof of the physical person who clicked the link.

### n8n

Runs the business workflows, coordinates integrations, and persists every relevant result in PostgreSQL.

### Redis

Provides n8n queue-mode coordination between the main instance and workers. Redis is not a business data store.

### PostgreSQL

Stores all authoritative business and operational records.

### Mock Provisioning API

Creates the external client account. It accepts an idempotency key and returns the same client result for repeated requests with that key.

### Google Drive

Stores one onboarding folder per successful case.

### Google Calendar

Stores one kickoff event per successful case.

### Gmail

Is used for:

- client data requests and correction requests;
- operator approval requests;
- internal team completion or intervention notifications.

## 7. High-level flow

```text
Controlled Mock CRM
        │
        │ authenticated Deal Won webhook
        ▼
      WF01
        │
        ▼
PostgreSQL: create or reuse client and onboarding case
        │
        ▼
      WF02 ── Gmail client form link
        │
        ▼
Client submits n8n Form Trigger
        │
        ▼
      WF03
        ├── invalid data ──→ validation_failed ──→ WF02 with new token
        └── valid data ────→ awaiting_approval ─→ WF04
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
- `awaiting_client_data` — a valid form request is available and client data is expected;
- `data_received` — a valid token was consumed and submitted data was stored;
- `validation_failed` — stored data failed one or more business validation rules;
- `awaiting_approval` — stored data is valid and awaits operator decision;
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

### 9.2 Source event idempotency

Each CRM event identifier is processed once. Duplicate delivery of the same event returns the already-associated onboarding case.

### 9.3 Client identity

The initial implementation requires a company identifier and its country and type.

A client is created or reused by the normalized identity tuple:

```text
(company_identifier_country,
 company_identifier_type,
 company_identifier_value_normalized)
```

Email address alone is not used as the B2B client deduplication key.

### 9.4 Approval prerequisite

Provisioning is allowed only when the case state is `approved`.

### 9.5 Completion prerequisite

The case may enter `completed` only when all mandatory external operations have status `succeeded`:

- provision client account;
- create Drive folder;
- create kickoff event;
- send team notification.

### 9.6 Form token lifecycle

A form token belongs to exactly one case and has these properties:

- random plain value generated with a cryptographically secure generator;
- only a SHA-256 hash stored in PostgreSQL;
- configurable expiry, initially 72 hours;
- one successful atomic consumption;
- invalid after expiry, revocation, or consumption.

The submission process must claim and consume the token atomically before accepting its data.

## 10. Workflow boundaries

### WF01 — Intake Deal Won

Trigger: authenticated CRM webhook.

Responsibilities:

- authenticate the webhook;
- validate required source fields;
- normalize the source system, event, deal, company, and contact values;
- insert or reuse the client by normalized company identity;
- insert or reuse the onboarding case by source-deal uniqueness;
- record the source event and case-created business event once;
- invoke WF02 only when the case requires a data request.

WF01 does not send the form itself and does not provision external resources.

### WF02 — Request Client Data

Trigger: WF01 or validation-correction path from WF03.

Responsibilities:

- verify the case may enter or remain in `awaiting_client_data`;
- revoke any older unused form token for the case;
- generate a new random token;
- store its hash, expiry, and lifecycle metadata;
- build the n8n Form Trigger URL containing the plain token;
- send the Gmail request to the client;
- record the request event;
- conditionally move the case to `awaiting_client_data`.

WF02 never stores the plain token.

### WF03 — Receive and Validate Client Data

Trigger: n8n Form Trigger.

Responsibilities:

- hash the submitted plain token;
- atomically validate and consume the matching unexpired token;
- reject submissions with an invalid, expired, revoked, or consumed token;
- normalize submitted values;
- store the current client data;
- move the case from `awaiting_client_data` to `data_received`;
- execute deterministic validation rules;
- store validation details in the step and event records;
- move the case to `validation_failed` or `awaiting_approval`;
- invoke WF02 after validation failure;
- invoke WF04 after successful validation.

Validation failure is a business outcome, not an unexpected technical error.

### WF04 — Manual Approval

Trigger: WF03 after successful validation.

Responsibilities:

- verify the case is `awaiting_approval`;
- send a Gmail approval request to the configured operator mailbox;
- wait for approve or reject;
- store expected recipient, decision, decision time, and response metadata;
- conditionally move the case to terminal `rejected` or to `approved`;
- invoke WF05 only after a successful transition to `approved`.

A duplicate or late response must not change a terminal or already-advanced case.

### WF05 — Provision Client

Trigger: WF04 after approval or WF98 for a due retry.

Responsibilities:

- verify the case is `approved` or `provisioning_failed`;
- move the case conditionally to `provisioning`;
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
- store workflow identifier, execution identifier, case, step, operation, error class, message, and sanitized details;
- classify retryability when possible;
- avoid storing credentials, tokens, or full sensitive payloads;
- notify the configured operator mailbox when manual intervention is required.

WF99 does not independently advance business state without a validated state-specific recovery rule.

## 11. Data model responsibilities

### `clients`

Stores normalized B2B company identity, company data, and primary contact data.

Important rules:

- normalized company identifier tuple is unique;
- updates preserve audit events;
- the current record contains the latest accepted client data.

### `onboarding_cases`

Stores:

- source system, source event, and source deal identity;
- current authoritative state;
- linked client;
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

The table supports operational visibility for steps that are not external side effects as well as steps backed by `external_operations`.

### `onboarding_form_tokens`

Stores token hash, case, expiry, status, issued time, consumed time, revoked time, and request metadata.

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

Stores every external side effect.

Initial operation types:

- `provision_client`;
- `create_drive_folder`;
- `create_kickoff_event`;
- `notify_team`.

Required operational fields include:

- deterministic unique idempotency key;
- operation type;
- status;
- attempt count and maximum attempts;
- next retry time;
- lease owner and lease expiry;
- request and response summaries;
- external resource identifier;
- last error classification;
- created, started, completed, and updated timestamps.

### `error_log`

Stores normalized unexpected technical and integration errors. It may reference a case, step, and external operation when known.

## 12. External-operation protocol

### 12.1 Deterministic keys

```text
onboarding:<case_id>:provision-client
onboarding:<case_id>:create-drive-folder
onboarding:<case_id>:create-kickoff-event
onboarding:<case_id>:notify-team
```

### 12.2 Atomic claim

The database claim operation must perform one of these outcomes atomically:

- insert a new `in_progress` operation with a lease;
- claim a due retryable operation whose lease is absent or expired;
- return the existing `succeeded` result;
- refuse the claim when another valid lease exists;
- refuse the claim for a terminal failure or exhausted retry limit.

### 12.3 External call

The workflow sends the same deterministic idempotency key to integrations that support it.

For Google APIs, the stored operation and external identifiers provide application-level idempotency. The workflow must search or reconcile by the deterministic case reference when an API response may have been lost after resource creation.

### 12.4 Completion

Only the worker that owns the current lease may mark the operation result.

If the process stops after the external system created the resource but before PostgreSQL was updated, the retry path must reconcile before creating anything again.

## 13. Retry and failure handling

### Retryable examples

- HTTP 429;
- HTTP 502, 503, or 504;
- network timeout;
- temporary DNS or connection failure;
- expired worker lease after interruption.

### Terminal examples

- invalid request payload confirmed by validation;
- invalid permissions requiring configuration change;
- resource creation rejected by a permanent business rule;
- maximum retry attempts exhausted.

HTTP 401 or 403 is not retried automatically until credentials or permissions are corrected.

### Partial finalization example

```text
provision_client: succeeded
create_drive_folder: succeeded
create_kickoff_event: failed_retryable
notify_team: not_started
```

The retry path reuses the client and Drive folder, retries only the Calendar operation, and sends the notification only after Calendar succeeds.

## 14. Security

- secrets are stored in n8n credentials or environment variables;
- `.env` is excluded from Git;
- `.env.example` contains names and safe placeholders only;
- CRM webhook authentication is mandatory;
- form tokens are random, expiring, single-use, and stored only as hashes;
- sensitive request and response data is minimized in events and logs;
- credentials, plain tokens, and complete sensitive documents are never logged;
- PostgreSQL and Redis are not exposed publicly in the default deployment;
- the Mock Provisioning API is available only on the internal Docker network unless explicitly required for testing;
- Google credentials use the minimum permissions required for Gmail, Drive, and Calendar operations.

## 15. Observability

PostgreSQL queries must make it possible to determine:

- case count by state;
- cases waiting for client data or approval;
- terminal rejected and completed cases;
- failed and exhausted operations;
- retry attempts and next retry times;
- stale operation leases;
- average and maximum onboarding duration;
- current status of every required step;
- the business and technical history of one case by correlation identifier.

## 16. Deployment model

Docker Compose will provide:

- PostgreSQL;
- Redis;
- n8n main instance;
- at least two n8n workers;
- Mock Provisioning API.

n8n runs in queue mode. The main instance receives triggers and coordinates executions; workers execute queued jobs.

Persistent volumes are required for PostgreSQL and any n8n data that must survive container recreation.

Exact Docker files are created only after the PostgreSQL schema and tests pass the Stage 2 gate.

## 17. Repository structure

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

## 18. Architecture acceptance criteria

The architecture stage passes only when all of these statements are true:

- PostgreSQL ownership of business state is unambiguous;
- exactly one onboarding case is enforced per source deal;
- terminal states and all allowed transitions are explicit;
- validation failure cannot reach approval without corrected data;
- rejection cannot reach provisioning;
- form access has an expiring single-use token design;
- approval trust boundary is documented accurately;
- all external side effects use `external_operations`;
- operation claiming is safe with multiple workers;
- stale `in_progress` operations have a recovery rule;
- retryable and terminal failures are distinguished;
- partial failure recovery never repeats successful operations;
- workflow responsibilities do not overlap;
- database table responsibilities are sufficient for Stage 2 schema design;
- no unresolved architecture decision blocks PostgreSQL design.
