# B2B Client Onboarding Platform — Architecture

## 1. Purpose

The platform automates the operational onboarding of a new B2B client after a deal is marked as `Won` in a CRM.

The system coordinates data collection, validation, human approval, external account provisioning, document creation, kickoff scheduling, team notification, and final completion tracking.

The project is designed as a production-oriented reference implementation. Its purpose is to demonstrate reliable workflow orchestration, persistent state management, external API integration, idempotency, retry handling, auditability, and safe recovery from partial failures. It applies production-oriented engineering practices but does not claim to be a production deployment for real customers.

## 2. Business objective

The platform must reduce manual work during client onboarding while keeping a human approval step before irreversible provisioning actions.

A successful onboarding case must produce the following business outcome:

- the client record exists in the platform;
- required client data has been collected and validated;
- a responsible employee has approved the onboarding;
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
- collecting client data through an n8n Form Trigger workflow;
- validating required fields and business rules;
- requesting manual approval through Gmail using an n8n wait-for-response approval step;
- provisioning a client account through a mock REST API;
- creating a Google Drive folder;
- creating a Google Calendar kickoff event;
- notifying the internal team;
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

Before performing an external action, the workflow checks whether that operation already completed successfully.

If the operation was completed, the workflow reuses the stored external identifier and continues with the next step.

### 5.4 Human approval is mandatory before provisioning

Validation may be automatic, but account provisioning starts only after an authorized employee approves the onboarding case through the Gmail approval step. The approval or rejection response, approver identity, and decision timestamp must be stored in PostgreSQL.

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

Provides the client-facing data collection form and starts processing when the client submits it.

### Gmail

Delivers the approval request and returns the operator's approve or reject response to n8n.

### n8n

Coordinates the process, calls external systems, and persists results.

### PostgreSQL

Stores the authoritative state, operation history, audit events, and errors.

### Redis

Supports n8n queue mode and distributes workflow executions to workers.

### Mock Provisioning API

Represents an external business system where the client account is created.

### Google Drive

Stores the client onboarding folder and generated documents.

### Google Calendar

Stores the kickoff meeting.

### Team notification channel

Receives internal status notifications. The concrete channel will be selected during integration design.

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
    ↓
Request Gmail Approval
    ↓
Receive Approve or Reject Response
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
      │                      │ operations, errors
      │
Client ── n8n Form submission
      │
      ├──────────────► Gmail approval request ──► Onboarding operator
      ├──────────────► Mock Provisioning API
      ├──────────────► Google Drive
      ├──────────────► Google Calendar
      └──────────────► Team Notification Channel

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
  ↓
validation_failed ─────► awaiting_client_data
  ↓
awaiting_approval
  ├────────► rejected
  ↓
approved
  ↓
provisioning
  ↓
provisioning_failed ───► provisioning
  ↓
provisioned
  ↓
finalizing
  ↓
finalization_failed ───► finalizing
  ↓
completed
```

### State meanings

- `created`: the case exists but the data collection request has not been completed;
- `awaiting_client_data`: the client must provide required information;
- `data_received`: submitted data has been stored;
- `validation_failed`: one or more validation rules failed;
- `awaiting_approval`: data is valid and awaits human review;
- `rejected`: the operator rejected the onboarding case;
- `approved`: the operator approved provisioning;
- `provisioning`: external account creation is in progress;
- `provisioning_failed`: provisioning failed and requires retry or intervention;
- `provisioned`: the external client account exists;
- `finalizing`: Drive, Calendar, and notification operations are in progress;
- `finalization_failed`: one or more finalization operations failed;
- `completed`: all required operations completed successfully.

State transitions must be validated in PostgreSQL-backed application logic. A workflow must not arbitrarily jump from one unrelated state to another.

## 10. Workflow boundaries

The initial architecture contains the following workflow responsibilities.

### WF01 — Intake Deal Won

Responsibilities:

- receive the CRM webhook;
- validate the webhook payload;
- calculate the source event idempotency key;
- create or reuse the client record;
- create exactly one onboarding case;
- record the intake event;
- trigger the data collection process.

### WF02 — Collect Client Data

Responsibilities:

- generate or reuse the client-specific n8n form access data;
- send the client data request with the n8n form link;
- receive the n8n Form Trigger submission;
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

- send the validated case to the onboarding operator through Gmail;
- wait for an approve or reject response;
- validate that the response belongs to the expected onboarding case;
- record who made the decision and when;
- move the case to `approved` or `rejected`;
- invoke provisioning after approval.

### WF05 — Provision Client

Responsibilities:

- verify that the case is approved;
- create or reuse the provisioning operation;
- call the Mock Provisioning API;
- store the external client identifier;
- safely retry recoverable failures;
- move the case to `provisioned` or `provisioning_failed`.

### WF06 — Finalize Onboarding

Responsibilities:

- create or reuse the Google Drive folder;
- create or reuse the kickoff calendar event;
- send or reuse the internal notification;
- verify that all required operations succeeded;
- move the case to `completed` or `finalization_failed`.

### WF99 — Central Error Handler

Responsibilities:

- receive technical failure information from n8n workflows;
- normalize the error payload;
- store the failure in `error_log`;
- link the error to an onboarding case and operation when possible;
- classify the error as retryable or non-retryable;
- notify an operator when manual intervention is required.

## 11. Core data model

The initial database design will include the following tables.

### `clients`

Stores the normalized B2B client identity and contact data.

### `onboarding_cases`

Stores the current authoritative onboarding state and links the case to its source CRM deal.

### `onboarding_steps`

Stores the status of each required business step for a case.

### `onboarding_events`

Stores the immutable business audit trail.

Examples:

- case created;
- client data received;
- validation failed;
- approval granted;
- provisioning completed;
- onboarding completed.

### `provisioning_operations`

Stores every external side-effect operation.

Examples:

- provision external account;
- create Drive folder;
- create kickoff meeting;
- send team notification.

The table stores the idempotency key, status, attempt count, external identifier, request summary, response summary, and timestamps.

### `error_log`

Stores normalized technical and integration errors.

## 12. Idempotency strategy

### Intake idempotency

The source CRM deal identifier is unique within the source system.

A unique database constraint will prevent more than one active onboarding case for the same source system and deal identifier.

Example logical key:

```text
crm:<source_system>:deal:<deal_id>
```

### External operation idempotency

Each external operation receives a deterministic key.

Examples:

```text
onboarding:<case_id>:provision-client
onboarding:<case_id>:create-drive-folder
onboarding:<case_id>:create-kickoff-meeting
onboarding:<case_id>:notify-team
```

Before performing an external action, n8n checks `provisioning_operations` by idempotency key.

- if status is `succeeded`, reuse the stored result;
- if status is `in_progress`, do not start a duplicate operation;
- if status is `failed` and retryable, increment the attempt and retry;
- if status is `failed` and non-retryable, require manual intervention.

## 13. Retry policy

Retries are used only for failures that may succeed later.

Retryable examples:

- HTTP 429 rate limit;
- HTTP 502, 503, or 504;
- network timeout;
- temporary DNS or connection failure.

Non-retryable examples:

- HTTP 400 caused by invalid payload;
- HTTP 401 or 403 caused by invalid credentials or permissions;
- validation rule failure;
- rejected onboarding approval.

The initial retry schedule will use bounded exponential backoff.

Example:

```text
attempt 1: immediate
attempt 2: after 1 minute
attempt 3: after 5 minutes
attempt 4: after 15 minutes
attempt 5: manual intervention
```

The exact implementation will be defined during workflow design.

## 14. Partial failure handling

A case may complete some external operations before another operation fails.

Example:

- client account provisioned successfully;
- Drive folder created successfully;
- Calendar API fails.

The system must not delete or repeat the successful operations automatically.

On retry, the workflow:

1. reads the current case state;
2. reads all operation records;
3. skips successful operations;
4. retries only the failed Calendar operation;
5. completes the remaining notification step;
6. moves the case to `completed` only after all mandatory operations succeed.

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

Existing events are not edited to hide earlier decisions or failures.

## 16. Security principles

- credentials are stored in n8n credentials or environment secrets, never committed to Git;
- `.env` files are excluded from Git;
- `.env.example` contains names of required variables without secret values;
- webhook endpoints must validate a shared secret or signature where supported;
- logs must not contain credentials, tokens, or complete sensitive documents;
- manual approval actions must identify the approving user;
- Gmail approval responses must be linked to the expected onboarding case;
- external API permissions should follow the least-privilege principle.

## 17. Observability

The first version must make it possible to answer:

- how many onboarding cases exist in each state;
- which cases are blocked;
- which operations failed;
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
4. External side effects are recorded before and after execution.
5. All external create operations require idempotency.
6. Manual approval is required before provisioning.
7. Completed operations are not repeated during retry.
8. Business events are stored separately from technical errors.
9. The first external account integration is a controlled Mock Provisioning API.
10. Client data collection uses an n8n Form Trigger workflow.
11. Manual approval uses Gmail and an n8n wait-for-response approval step.
12. Architecture and database schema are completed before building n8n workflows.

## 21. Known risks

### Duplicate source events

CRM systems may deliver the same webhook more than once.

Mitigation: unique source event and source deal constraints.

### External API timeout after successful creation

An API may create a resource but the response may time out.

Mitigation: use external idempotency support where available and implement reconciliation by deterministic reference.

### Workflow interruption

An n8n execution may stop after some operations succeeded.

Mitigation: persist each operation result and resume from PostgreSQL state.

### Invalid state transition

A workflow may attempt to process a case that is not ready for that step.

Mitigation: verify the current state before each transition and use conditional database updates.

### Scope expansion

The project may grow into a CRM, billing platform, or custom SaaS frontend.

Mitigation: preserve the non-goals and require an explicit architecture decision before expanding scope.

## 22. Acceptance criteria for the architecture stage

The architecture stage is complete when:

- the process scope is approved;
- the state machine is approved;
- workflow responsibilities are approved;
- idempotency rules are approved;
- failure and retry behavior are approved;
- core tables and their responsibilities are approved;
- no implementation begins with unresolved ownership of business state.

The next stage after architecture approval is the PostgreSQL schema design.