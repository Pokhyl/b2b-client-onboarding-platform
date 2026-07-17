# B2B Client Onboarding Platform — Project Plan

## 1. Objective

Build a production-oriented reference implementation that automates B2B client onboarding after a CRM deal reaches `Won`.

The platform must preserve business state outside n8n, prevent duplicate side effects, recover safely from partial failures, and provide a complete audit trail.

## 2. Fixed business flow

```text
CRM Deal Won
→ Create or reuse onboarding case
→ Request client data
→ Receive client data
→ Validate client data
→ Manual approval
→ Provision client account
→ Create Google Drive folder
→ Create kickoff meeting
→ Notify internal team
→ Complete onboarding
```

Decision branches:

```text
Validation failed
→ return case to awaiting_client_data
→ issue a new form token
→ request corrected data

Approval rejected
→ move case to rejected
→ stop processing

Recoverable external failure
→ record failure and retry only the failed operation

Non-recoverable external failure
→ record failure and require manual intervention
```

## 3. Fixed architecture

- PostgreSQL is the source of truth for business state.
- n8n is the orchestration layer.
- Redis supports n8n queue mode and multiple workers.
- External integrations use REST APIs, webhooks, OAuth2, or native n8n credentials.
- JavaScript is used only for deterministic normalization and validation where SQL or node configuration is insufficient.
- n8n execution history is not the authoritative business record.
- Successful external operations are never repeated automatically.
- Business events and technical errors are stored separately.

## 4. Corrected domain decisions

### 4.1 One onboarding case per source deal

The database must enforce:

```text
UNIQUE (source_system, source_deal_id)
```

The rule applies to all states, including `rejected` and `completed`.

### 4.2 Rejection is terminal

`rejected` is a terminal state for the current onboarding case.

A rejected case is not automatically returned to data collection. A new business attempt requires a new source deal or an explicit future reactivation feature outside the initial scope.

### 4.3 Secure client form access

Each client data request uses a cryptographically random, expiring, single-use token.

- only a token hash is stored in PostgreSQL;
- the plain token is included in the client form link;
- the token is checked before accepting submitted data;
- a consumed or expired token cannot be reused;
- validation failure causes a new token to be generated for the correction request.

### 4.4 Approval trust boundary

The approval request is sent to a configured operator mailbox through Gmail using an n8n wait-for-response operation.

The system stores:

- expected approval recipient email;
- decision;
- decision timestamp;
- workflow response metadata.

The initial implementation treats access to the configured mailbox as the approval trust boundary. It does not claim cryptographic proof of the physical person who clicked the response link.

### 4.5 External operation naming

The table is named `external_operations`, not `provisioning_operations`, because it stores all side effects:

- provision client account;
- create Drive folder;
- create kickoff meeting;
- send team notification.

### 4.6 Concurrency-safe idempotency

Every external operation has a unique deterministic `idempotency_key`.

Workers must claim operations atomically. The design must prevent two workers from performing the same external operation concurrently.

An `in_progress` operation must include a lease or timeout so an interrupted worker can be recovered safely.

## 5. State machine

```text
created
  ↓
awaiting_client_data
  ↓
data_received
  ├── validation_failed ──→ awaiting_client_data
  └── awaiting_approval
          ├── rejected [terminal]
          └── approved
                ↓
           provisioning
                ├── provisioning_failed ──→ provisioning
                └── provisioned
                       ↓
                  finalizing
                       ├── finalization_failed ──→ finalizing
                       └── completed [terminal]
```

Only defined transitions are allowed. PostgreSQL-backed conditional updates must reject stale or invalid transitions.

## 6. Workflow boundaries

### WF01 — Intake Deal Won

- receive and authenticate the CRM webhook;
- validate and normalize the payload;
- create or reuse the client;
- create exactly one onboarding case per source deal;
- record the intake event;
- invoke WF02.

### WF02 — Request Client Data

- create a single-use form token;
- store only its hash and expiry;
- generate the n8n form link;
- send the request to the client;
- move the case to `awaiting_client_data`.

### WF03 — Receive and Validate Client Data

- receive the n8n Form Trigger submission;
- validate and consume the form token atomically;
- normalize and persist submitted data;
- record validation results;
- move the case to `validation_failed` or `awaiting_approval`;
- on failure, invoke WF02 with a new token;
- on success, invoke WF04.

### WF04 — Manual Approval

- verify the case is `awaiting_approval`;
- send the approval request to the configured mailbox;
- wait for approve or reject;
- record recipient, decision, timestamp, and response metadata;
- move the case to `approved` or terminal `rejected`;
- invoke WF05 only after approval.

### WF05 — Provision Client

- verify the case is `approved` or retryable `provisioning_failed`;
- atomically claim the provisioning operation;
- call the Mock Provisioning API using an idempotency key;
- store the external client identifier;
- move the case to `provisioned` or `provisioning_failed`;
- invoke WF06 after success.

### WF06 — Finalize Onboarding

- create or reuse the Drive folder operation;
- create or reuse the Calendar event operation;
- send or reuse the team notification operation;
- retry only incomplete operations;
- move the case to `completed` only after all mandatory operations succeed;
- otherwise move it to `finalization_failed`.

### WF98 — Retry Dispatcher

- find retryable failed operations whose `next_retry_at` has arrived;
- invoke only the workflow responsible for the failed operation;
- respect maximum attempts and operation leases.

### WF99 — Central Error Handler

- normalize technical errors;
- link them to workflow, case, step, and operation when available;
- classify retryability;
- write to `error_log`;
- notify an operator only when intervention is required.

## 7. Database scope

The initial schema will contain:

- `clients` — normalized client identity and contact data;
- `onboarding_cases` — authoritative state and source deal identity;
- `onboarding_steps` — current status of required business steps;
- `onboarding_form_tokens` — hashed, expiring, single-use form tokens;
- `onboarding_events` — append-only business audit trail;
- `external_operations` — concurrency-safe external side effects and retries;
- `error_log` — normalized technical and integration errors.

The schema must include foreign keys, check constraints, unique constraints, indexes, timestamps, and conditional state updates required for safe worker concurrency.

## 8. Implementation stages

### Stage 1 — Architecture

Create and approve `docs/architecture.md` based on this plan.

Gate:

- scope, state machine, workflow ownership, trust boundaries, idempotency, retry behavior, and table responsibilities are internally consistent.

### Stage 2 — PostgreSQL foundation

Create:

- `db/migrations/001_foundation.sql`;
- `db/tests/001_foundation_checks.sql`.

Gate:

- migration applies cleanly to an empty PostgreSQL database;
- constraints reject duplicates and invalid states;
- test SQL passes;
- migration can be reapplied only through a clean database reset, not by silently ignoring errors.

### Stage 3 — Runtime infrastructure

Create Docker Compose configuration for:

- PostgreSQL;
- Redis;
- n8n main;
- multiple n8n workers;
- Mock Provisioning API.

Gate:

- all services become healthy;
- n8n runs in queue mode;
- workers execute jobs;
- PostgreSQL migration and tests run successfully in the environment.

### Stage 4 — Mock Provisioning API

Implement a deterministic REST service that supports external idempotency keys and controlled failure scenarios.

Gate:

- repeated requests with the same key return the same client;
- retryable and non-retryable failures can be reproduced by tests.

### Stage 5 — Workflow contracts

Define input, output, state preconditions, database writes, idempotency behavior, and failure handling for every workflow before importing n8n JSON.

Gate:

- each workflow has one responsibility and a testable contract.

### Stage 6 — n8n workflows

Implement WF01, WF02, WF03, WF04, WF05, WF06, WF98, and WF99 one workflow at a time.

Gate for each workflow:

- happy path tested;
- duplicate input tested;
- invalid state tested;
- retryable failure tested where applicable;
- persisted state verified directly in PostgreSQL.

### Stage 7 — End-to-end recovery tests

Test the full process and controlled interruptions after every external side effect.

Gate:

- no duplicate account, folder, meeting, or notification is created;
- interrupted cases resume from PostgreSQL state;
- completed operations are reused;
- rejected cases never provision a client.

### Stage 8 — CI and documentation

Add GitHub Actions and final documentation.

Gate:

- SQL tests and service tests run automatically;
- repository setup is reproducible from documented commands;
- architecture, workflow contracts, test scenarios, and recovery behavior are documented.

## 9. Working rules

- Work on one stage at a time.
- Do not start a later stage before the current gate passes.
- Do not change fixed architecture during implementation without documenting the reason and impact first.
- Do not replace the chosen approach at the first failure; diagnose and complete the current stage unless a technical limitation is proven.
- Every repository change must belong to a named branch and a focused commit.
- Before a PR is merged, verify the actual diff and all available tests.
- Each work session ends with one concrete next step.
