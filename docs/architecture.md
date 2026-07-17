# B2B Client Onboarding Platform — Architecture

## 1. Purpose

The platform automates the operational onboarding of a new B2B client after a deal is marked as `Won` in a CRM.

The system coordinates data collection, validation, human approval, external account provisioning, Drive folder creation, kickoff scheduling, team notification, and final completion tracking.

The project is designed as a production-oriented reference implementation. Its purpose is to demonstrate reliable workflow orchestration, persistent state management, external API integration, idempotency, retry handling, auditability, and safe recovery from partial failures. It applies production-oriented engineering practices but does not claim to be a production deployment for real customers.

## 2. Business objective

The platform must reduce manual work during client onboarding while keeping a human approval step before irreversible provisioning actions.

A successful onboarding case must produce the following business outcome:

- the client record exists in the platform;
- required client data has been collected and validated;
- an approval response has been recorded through the configured approval process;
- the client has been provisioned in the target service;
- a Google Drive folder has been created;
- a kickoff meeting has been created;
- the internal team has been notified;
- all completed operations and failures are recorded;
- the onboarding case has reached the `completed` state.

## 3. Scope

The first implementation includes:

- receiving a `Deal Won` webhook from a CRM or controlled mock CRM;
- creating exactly one onboarding case for a source deal;
- sending the client data request through Gmail and collecting the response through an n8n Form Trigger workflow;
- validating required fields and business rules;
- requesting manual approval through Gmail using an n8n wait-for-response approval step;
- provisioning a client account through a mock REST API;
- creating a Google Drive folder;
- creating a Google Calendar kickoff event;
- notifying the internal team through Gmail;
- recording workflow state, operations, events, and errors in PostgreSQL;
- retrying recoverable failures without repeating successful operations;
- exposing enough data for operational monitoring and testing.

## 4. Non-goals for the first version

The following are intentionally excluded from the initial implementation:

- a custom frontend application;
- real billing or payment processing;
- AI-based decision making;
- automatic contract signing;
- production integration with a proprietary CRM;
- multi-tenant SaaS billing;
- advanced role-based access control UI;
- replacing PostgreSQL with n8n execution history as the source of truth.

These exclusions prevent the project from expanding into an unrelated full SaaS product.

## 5. Architectural principles

### 5.1 PostgreSQL is the source of truth

The authoritative onboarding state is stored in PostgreSQL.

n8n orchestrates actions but does not own the final business state. An n8n execution may stop, restart, or expire without losing the onboarding case state.

### 5.2 External operations must be idempotent

Every operation that creates or changes data in an external system must have an idempotency strategy.

Examples:

- the same CRM webhook must not create two onboarding cases;
- a retry must not create a second Drive folder;
- a retry must not create a second kickoff meeting;
- a retry must not provision the same client twice.

### 5.3 Completed steps are not repeated

Before performing an external action, the workflow atomically reserves an external operation in PostgreSQL by a unique idempotency key.

If the operation already succeeded, the workflow reuses the stored external identifier and continues with the next step. If another worker owns an active operation lease, the workflow must not execute the same side effect.

### 5.4 Human approval is mandatory before provisioning

Validation may be automatic, but account provisioning starts only after an approval response is received through the Gmail approval step addressed to the configured approval recipient.

The configured approval recipient email, approval or rejection response, and decision timestamp must be stored in PostgreSQL. The response link identifies the approval request and onboarding case, but it does not independently prove the identity of the person who opened the link.

### 5.5 Failures are explicit business states

A failed API request is not only an n8n execution error. The failure must be stored as an operation result and an onboarding event in PostgreSQL.

### 5.6 Workflows remain small and responsibility-focused

The project is divided into several workflows. One very large workflow is avoided because it is harder to test, retry, document, and maintain.

## 6. Main actors and systems

### CRM

Produces the initial `Deal Won` event.

### Client

Provides the required company and contact data through the n8n form.

### Onboarding operator

Receives a Gmail approval request, reviews validated data, and approves or rejects the case.

### n8n Form Trigger

Provides the client-facing data collection form and starts processing when the client submits it. The form is generic; a submission is accepted only when it contains a cryptographically random, single-use token with a limited lifetime.

### Gmail

Sends client data requests, approval requests, and internal team notifications. For approval requests, Gmail returns the approve or reject response to n8n.

### n8n

Coordinates the process, calls external systems, and persists results.

### PostgreSQL

Stores the authoritative state, operation history, audit events, form access tokens, and errors.

### Redis

Supports n8n queue mode and distributes workflow executions to workers.

### Mock Provisioning API

Represents an external business system where the client account is created.

### Google Drive

Stores the client onboarding folder.

### Google Calendar

Stores the kickoff meeting.

### Internal team email

Receives completion and intervention notifications through Gmail at a configured internal distribution address.

## 7. High-level process

```text
CRM Deal Won
    ↓
Create Onboarding Case
    ↓
Request Client Data through n8n Form
    ↓
Receive n8n Form Submission
    ↓
Validate Data
    ├── Invalid → Request Corrected Client Data
    └── Valid
          ↓
Request Gmail Approval
    ↓
Receive Approve or Reject Response
    ├── Reject → Mark Rejected → Stop
    └── Approve
          ↓
Provision Client Account
    ↓
Create Google Drive Folder
    ↓
Create Kickoff Meeting
    ↓
Notify Internal Team
    ↓
Complete Onboarding
```

## 8. System context

```text
CRM / Mock CRM
      │
      │ Deal Won webhook
      ▼
     n8n ───────────────► PostgreSQL
      ▲                      ▲
      │                      │ state, events,
      │                      │ operations, tokens, errors
      │
Client ── protected n8n Form submission
      │
      ├──────────────► Gmail approval request ──► Onboarding operator
      ├──────────────► Mock Provisioning API
      ├──────────────► Google Drive
      ├──────────────► Google Calendar
      └──────────────► Internal Team Email

Redis supports n8n queue mode and worker execution.
```

## 9. Onboarding state machine

The onboarding case uses explicit states.

```text
created
  ↓
awaiting_client_data
  ↓
data_received
  ├────────► validation_failed ─────► awaiting_client_data
  └────────► awaiting_approval
                ├────────► rejected (terminal)
                ↓
              approved
                ↓
           provisioning
                ├────────► provisioning_failed ─────► provisioning
                ↓
            provisioned
                ↓
             finalizing
                ├────────► finalization_failed ─────► finalizing
                ↓
             completed (terminal)
```

### State meanings

- `created`: the case exists but the data collection request has not been completed;
- `awaiting_client_data`: the client must provide required information;
- `data_received`: submitted data has been stored;
- `validation_failed`: one or more validation rules failed and the case must return to `awaiting_client_data` for corrected data;
- `awaiting_approval`: data is valid and awaits human review;
- `rejected`: the operator rejected the onboarding case; this is a terminal state and provisioning must not start;
- `approved`: the operator approved provisioning;
- `provisioning`: external account creation is in progress;
- `provisioning_failed`: provisioning failed and requires retry or intervention;
- `provisioned`: the external client account exists;
- `finalizing`: Drive, Calendar, and notification operations are in progress;
- `finalization_failed`: one or more finalization operations failed;
- `completed`: all required operations completed successfully; this is a terminal state.

### Allowed state transitions

- `created` → `awaiting_client_data`;
- `awaiting_client_data` → `data_received`;
- `data_received` → `validation_failed` or `awaiting_approval`;
- `validation_failed` → `awaiting_client_data`;
- `awaiting_approval` → `approved` or `rejected`;
- `approved` → `provisioning`;
- `provisioning` → `provisioned` or `provisioning_failed`;
- `provisioning_failed` → `provisioning`;
- `provisioned` → `finalizing`;
- `finalizing` → `completed` or `finalization_failed`;
- `finalization_failed` → `finalizing`;
- `rejected` and `completed` have no outgoing transitions.

State transitions must be validated using conditional PostgreSQL updates that include the expected current state. A workflow must not arbitrarily jump from one unrelated state to another.

## 10. Workflow boundaries

The initial architecture contains the following workflow responsibilities.

### WF01 — Intake Deal Won

Responsibilities:

- receive the CRM webhook;
- validate the webhook payload and source authentication;
- calculate the source event idempotency key;
- create or reuse the client record;
- atomically create or reuse exactly one onboarding case for the source system and deal identifier;
- record the intake event;
- trigger the data collection process.

### WF02 — Collect Client Data

Responsibilities:

- generate a cryptographically random client form token;
- store only the token hash together with its onboarding case, expiry, and lifecycle timestamps;
- send the client data request through Gmail with the token-bearing n8n form link;
- receive the n8n Form Trigger submission;
- reject a missing, invalid, expired, revoked, or already-used token;
- atomically consume a valid token so concurrent submissions cannot reuse it;
- normalize submitted values;
- store the submitted data;
- move the case to `data_received`;
- invoke validation.

### WF03 — Validate Client Data

Responsibilities:

- check required fields;
- validate email, phone, company identifier, and address format;
- detect duplicate company records;
- store validation results;
- move the case to `validation_failed` or `awaiting_approval`.

### WF04 — Manual Approval

Responsibilities:

- send the validated case to the configured onboarding approval recipient through Gmail;
- store the approval request reference, configured recipient email, and expiry;
- wait for an approve or reject response;
- validate that the response belongs to the expected onboarding case and active approval request;
- reject duplicate or expired responses;
- record the configured recipient email, decision, and decision timestamp;
- move the case to `approved` or terminal `rejected`;
- invoke provisioning only after an approved response.

### WF05 — Provision Client

Responsibilities:

- verify that the case is approved;
- atomically create or reuse the external operation by idempotency key;
- call the Mock Provisioning API only when this execution owns the operation lease;
- store the external client identifier;
- reconcile an uncertain result before any retry;
- safely retry recoverable failures;
- move the case to `provisioned` or `provisioning_failed`.

### WF06 — Finalize Onboarding

Responsibilities:

- atomically create or reuse each required external operation;
- create or reuse the Google Drive folder;
- create or reuse the kickoff calendar event;
- send or reuse the internal Gmail notification to the configured team address;
- reconcile uncertain external results before retrying;
- verify that all required operations succeeded;
- move the case to `completed` or `finalization_failed`.

### WF99 — Central Error Handler

Responsibilities:

- receive technical failure information from n8n workflows;
- normalize the error payload;
- store the failure in `error_log`;
- link the error to an onboarding case and external operation when possible;
- classify the error as retryable, non-retryable, or requiring reconciliation;
- notify an operator when manual intervention is required.

## 11. Core data model

The initial database design will include the following tables.

### `clients`

Stores the normalized B2B client identity and contact data.

### `onboarding_cases`

Stores the current authoritative onboarding state, source CRM identity, approval decision fields, and links the case to its source deal.

A database unique constraint on `(source_system, source_deal_id)` permits exactly one onboarding case for a source deal regardless of whether the case is active, rejected, or completed.

### `onboarding_steps`

Stores the status of each required business step for a case.

### `onboarding_events`

Stores the immutable business audit trail.

Examples:

- case created;
- client data received;
- validation failed;
- approval granted;
- approval rejected;
- provisioning completed;
- onboarding completed.

### `form_access_tokens`

Stores client form access token hashes and lifecycle data.

The raw token is never stored. Each record links to one onboarding case and includes expiry, consumption, revocation, and creation timestamps.

### `external_operations`

Stores every external side-effect operation.

Examples:

- send client data request;
- send approval request;
- provision external account;
- create Drive folder;
- create kickoff meeting;
- send team notification.

The table stores a globally unique idempotency key, operation type, status, attempt count, lease ownership and expiry, external identifier, request summary, response summary, reconciliation data, and timestamps.

Supported logical statuses are:

- `pending`;
- `in_progress`;
- `succeeded`;
- `failed`;
- `unknown`, when the external outcome cannot be determined safely.

### `error_log`

Stores normalized technical and integration errors.

## 12. Idempotency and concurrency strategy

### Intake idempotency

The source CRM deal identifier is unique within the source system.

A unique database constraint on `(source_system, source_deal_id)` prevents more than one onboarding case for the same source deal in every state, including `rejected` and `completed`.

The source event identifier is also stored with a unique constraint when the source supplies a stable event id.

Example logical key:

```text
crm:<source_system>:deal:<deal_id>
```

### External operation idempotency

Each external operation receives a deterministic key.

Examples:

```text
onboarding:<case_id>:send-client-data-request
onboarding:<case_id>:send-approval-request
onboarding:<case_id>:provision-client
onboarding:<case_id>:create-drive-folder
onboarding:<case_id>:create-kickoff-meeting
onboarding:<case_id>:notify-team
```

`external_operations.idempotency_key` has a unique database constraint.

Before performing an external action, a workflow must atomically reserve the operation in PostgreSQL. The reservation and ownership decision must be made in one database transaction or one atomic `INSERT ... ON CONFLICT` statement.

- if status is `succeeded`, reuse the stored result;
- if status is `in_progress` with an active lease owned by another execution, do not start a duplicate operation;
- if an `in_progress` lease expired, recover or reconcile the operation before assigning a new lease;
- if status is `failed` and retryable, increment the attempt and acquire a new lease atomically;
- if status is `failed` and non-retryable, require manual intervention;
- if status is `unknown`, reconcile the external system by deterministic reference before deciding whether a retry is safe.

## 13. Retry policy

Retries are used only for failures that may succeed later and only after operation ownership has been acquired atomically.

Retryable examples:

- HTTP 429 rate limit;
- HTTP 502, 503, or 504;
- network failure before the request was sent;
- temporary DNS or connection failure with a known unsuccessful outcome.

Non-retryable examples:

- HTTP 400 caused by invalid payload;
- HTTP 401 or 403 caused by invalid credentials or permissions;
- validation rule failure;
- rejected onboarding approval.

An ambiguous timeout or connection loss after a request may have reached the external system is not retried blindly. The operation moves to `unknown` and requires reconciliation.

The initial retry schedule will use bounded exponential backoff.

Example:

```text
attempt 1: immediate
attempt 2: after 1 minute
attempt 3: after 5 minutes
attempt 4: after 15 minutes
attempt 5: manual intervention
```

The exact scheduling mechanism will be defined during workflow design, but retry eligibility and attempt state remain stored in PostgreSQL.

## 14. Partial failure handling

A case may complete some external operations before another operation fails.

Example:

- client account provisioned successfully;
- Drive folder created successfully;
- Calendar API fails.

The system must not delete or repeat successful operations automatically.

On retry, the workflow:

1. reads the current case state;
2. reads all `external_operations` records;
3. skips successful operations;
4. reconciles operations with an `unknown` result;
5. atomically acquires a lease only for the operation that is safe to retry;
6. completes the remaining notification step;
7. moves the case to `completed` only after all mandatory operations succeed.

## 15. Audit trail

`onboarding_events` is append-only from the workflow perspective.

Each event should include:

- event identifier;
- onboarding case identifier;
- event type;
- actor type;
- actor identifier when available;
- previous state;
- new state;
- event payload;
- creation timestamp;
- correlation identifier.

For Gmail approval, the configured recipient email is recorded as the intended approver. It must not be represented as cryptographic proof of the identity of the person who opened the response link.

Existing events are not edited to hide earlier decisions or failures.

## 16. Security principles

- credentials are stored in n8n credentials or environment secrets, never committed to Git;
- `.env` files are excluded from Git;
- `.env.example` contains names of required variables without secret values;
- webhook endpoints must validate a shared secret or signature where supported;
- client form access uses high-entropy, single-use tokens with a limited lifetime;
- only form token hashes are stored in PostgreSQL;
- form token validation and consumption are atomic;
- application logs must not contain credentials, raw form tokens, approval links, or complete sensitive documents;
- WF02 execution-data retention must be configured so the raw form token is not retained after processing;
- Gmail approval requests are sent only to the configured approval recipient;
- the configured recipient, response, request reference, and decision time are recorded;
- Gmail approval links identify the request but do not independently authenticate the person opening the link;
- external API permissions should follow the least-privilege principle.

## 17. Observability

The first version must make it possible to answer:

- how many onboarding cases exist in each state;
- which cases are blocked;
- which operations failed;
- which operations are `unknown` and require reconciliation;
- which `in_progress` operations have an expired lease;
- how many retry attempts were made;
- how long onboarding takes from creation to completion;
- which workflow or integration produced an error.

The initial source for these metrics is PostgreSQL. A dedicated visualization layer may be added later, but it is not required before the core process works.

## 18. Deployment model

The planned local deployment uses Docker Compose.

Initial services:

- PostgreSQL;
- Redis;
- n8n main instance;
- one or more n8n workers;
- Mock Provisioning API.

Queue mode is used so orchestration and execution can be separated and scaled.

The exact Docker configuration will be created only after the database schema and workflow contracts are approved.

## 19. Repository structure

```text
b2b-client-onboarding-platform/
├── README.md
├── docker-compose.yml
├── .env.example
├── docs/
│   ├── architecture.md
│   ├── workflows.md
│   └── test-scenarios.md
├── db/
│   ├── migrations/
│   └── tests/
├── n8n/
│   └── workflows/
└── services/
    └── mock-provisioning-api/
```

Folders and files will be added incrementally. Empty folders are not committed because Git does not track empty directories.

## 20. Initial technical decisions

The following decisions are fixed for the initial implementation:

1. PostgreSQL is the business source of truth.
2. n8n is the orchestration layer.
3. Redis supports n8n queue mode.
4. Every external side effect is atomically reserved in `external_operations` before execution.
5. Every external operation has a unique idempotency key and an execution lease.
6. Uncertain external outcomes are reconciled before any retry.
7. Manual approval is required before provisioning.
8. `rejected` and `completed` are terminal onboarding states.
9. Completed operations are not repeated during retry.
10. Business events are stored separately from technical errors.
11. The first external account integration is a controlled Mock Provisioning API.
12. Client data collection uses a generic n8n Form Trigger; submissions are authorized by an expiring, single-use token whose hash is stored in PostgreSQL.
13. Gmail sends the client form link, the approval request, and the internal team notification.
14. Manual approval uses an n8n Gmail wait-for-response step addressed to a configured recipient; it records the intended recipient and response but is not treated as independent identity verification.
15. Architecture and database schema are completed before building n8n workflows.

## 21. Known risks

### Duplicate source events

CRM systems may deliver the same webhook more than once.

Mitigation: unique source event and source deal constraints, plus atomic case creation.

### Concurrent workers

Two n8n workers may attempt the same external operation at the same time.

Mitigation: unique idempotency keys, atomic reservation, and time-limited operation leases in PostgreSQL.

### External API timeout after successful creation

An API may create a resource but the response may time out.

Mitigation: mark the operation as `unknown`, use external idempotency support where available, and reconcile by deterministic reference before retrying.

### Workflow interruption

An n8n execution may stop after some operations succeeded or while it owns an operation.

Mitigation: persist each operation result, use expiring leases, and resume from PostgreSQL state.

### Client form link leakage or reuse

A form link may be forwarded, logged, reused, or opened after its intended lifetime.

Mitigation: high-entropy single-use tokens, hash-only PostgreSQL storage, short expiry, atomic consumption, log redaction, and restricted WF02 execution-data retention.

### Approval link forwarding

A Gmail approval link may be opened by someone other than the configured recipient.

Mitigation: send only to the configured recipient, record the intended recipient and decision, expire the request, reject duplicate responses, and do not claim that the link independently verifies identity.

### Invalid state transition

A workflow may attempt to process a case that is not ready for that step.

Mitigation: verify and update the expected current state in one conditional PostgreSQL statement.

### Scope expansion

The project may grow into a CRM, billing platform, or custom SaaS frontend.

Mitigation: preserve the non-goals and require an explicit architecture decision before expanding scope.

## 22. Acceptance criteria for the architecture stage

The architecture stage is complete when:

- the process scope is approved;
- the full allowed state-transition set is approved;
- terminal states are explicit;
- workflow responsibilities are approved;
- source-deal uniqueness is approved;
- form-token lifecycle, approval-request behavior, and Gmail notification recipients are approved;
- idempotency, concurrency, lease, reconciliation, and retry rules are approved;
- failure and partial-recovery behavior are approved;
- core tables and their responsibilities are approved;
- no implementation begins with unresolved ownership of business state.

The next stage after architecture approval is the PostgreSQL schema design.
