# WF01 — Intake Deal Won

## 1. Purpose

WF01 receives an authenticated `Deal Won` event from the controlled Mock CRM and creates or reuses the corresponding onboarding case in PostgreSQL.

The workflow converts an untrusted external webhook request into a normalized and idempotent intake record. PostgreSQL remains the authoritative source of truth for the onboarding case and its current state.

WF01 may invoke WF02 only when the persisted database state confirms that the case still requires its initial client-data request.

## 2. Responsibilities

WF01 is responsible for:

* authenticating the incoming CRM webhook before performing any business database writes;
* validating the required source event, source deal, company, and contact fields;
* normalizing source identifiers and intake values deterministically;
* creating or reusing exactly one onboarding case for the source deal;
* resolving duplicate webhook deliveries through PostgreSQL uniqueness constraints;
* storing CRM company and contact values as non-authoritative intake data;
* preserving additional sanitized CRM fields in `onboarding_cases.intake_metadata`;
* recording the source intake event and case creation event idempotently;
* returning the authoritative onboarding case identifier, correlation identifier, state, and intake result;
* invoking WF02 only when the case is in state `created` and no client-data request has already been delivered successfully.

## 3. Explicit non-responsibilities

WF01 must not:

* create or update a canonical row in `clients`;
* treat CRM company or contact values as validated client data;
* create a client-data form token;
* send email through Gmail;
* create an `external_operations` record for client-data delivery;
* move the onboarding case from `created` to `awaiting_client_data`;
* perform validation of client-submitted company data;
* request manual approval;
* call the Mock Provisioning API;
* create Google Drive or Google Calendar resources;
* rely on n8n execution history as the authoritative business record.

## 4. Trigger and authentication

### 4.1 HTTP trigger

WF01 is started by an n8n Webhook trigger with the following contract:

- HTTP method: `POST`;
- webhook path: `b2b-onboarding/deal-won`;
- request content type: `application/json`;
- request body: one JSON object representing one CRM `Deal Won` event;
- authentication method: n8n `Header Auth`;
- n8n `Raw Body` option: enabled;
- response mode: `Using Respond to Webhook Node`.

The production webhook URL is the integration endpoint used by the controlled Mock CRM. The temporary n8n test webhook URL is not part of the external contract.

WF01 must parse the raw request body only after webhook authentication succeeds. This allows malformed JSON and contract-validation failures to use controlled HTTP responses without performing business database writes.

### 4.2 Shared-secret authentication

The Mock CRM must send this HTTP header:

```text
Authorization: Bearer <shared-secret>
```

The complete expected header value must be stored in an n8n Header Auth credential.

The secret must not be:

- stored directly in the workflow JSON;
- committed to Git;
- included in `onboarding_events`;
- included in `error_log`;
- returned in an HTTP response;
- written to normal execution logs.

Outside a local development environment, the webhook must be called through HTTPS.

### 4.3 Authentication failure

Authentication must be completed before payload validation and before any business database operation.

When the authentication header is missing or invalid:

- the request must be rejected with HTTP `401 Unauthorized`;
- no row may be inserted or updated in `onboarding_cases`;
- no row may be inserted in `onboarding_events`;
- WF02 must not be invoked;
- the response must not reveal the expected secret or detailed validation rules.

An authentication failure is a rejected inbound request, not an onboarding case state transition.

## 5. Input contract

### 5.1 Request body

The request body must contain exactly one JSON object representing one CRM event:

```json
{
  "event_type": "deal.won",
  "event_id": "evt_10001",
  "deal_id": "deal_10001",
  "company": {
    "name": "Example Industries Sp. z o.o."
  },
  "contact": {
    "first_name": "Anna",
    "last_name": "Kowalska",
    "email": "anna.kowalska@example.com",
    "phone": "+48500100200"
  },
  "metadata": {
    "pipeline_id": "b2b-sales",
    "owner_id": "user_17"
  }
}
```

The request body must not be an array and must not contain multiple events.

WF01 assigns the constant source-system value:

```text
mock_crm
```

The external request must not be allowed to override this value.

### 5.2 Required fields

The following request fields are required:

| Field | Expected type | Rule |
|---|---|---|
| `event_type` | string | Must equal `deal.won` |
| `event_id` | string | Must not be blank |
| `deal_id` | string | Must not be blank |
| `company` | object | Must be present |
| `company.name` | string | Must not be blank |
| `contact` | object | Must be present |
| `contact.email` | string | Must not be blank |

A required string is invalid when it:

- is missing;
- is `null`;
- is not a JSON string;
- becomes empty after trimming surrounding whitespace.

WF01 accepts only the `deal.won` event type. Any other event type must be rejected without creating or updating an onboarding case.

### 5.3 Optional fields

The following request fields are optional:

| Field | Expected type |
|---|---|
| `contact.first_name` | string or `null` |
| `contact.last_name` | string or `null` |
| `contact.phone` | string or `null` |
| `metadata` | object |

An optional contact field that is missing, `null`, or blank after trimming must be normalized to SQL `NULL`.

When `metadata` is missing, WF01 must use an empty JSON object.

When `metadata` is present, it must be a JSON object. The following values are invalid for `metadata`:

- `null`;
- an array;
- a string;
- a number;
- a boolean.

### 5.4 Database field mapping

The normalized request fields map to PostgreSQL as follows:

| Normalized value | PostgreSQL column |
|---|---|
| constant `mock_crm` | `onboarding_cases.source_system` |
| `event_id` | `onboarding_cases.source_event_id` |
| `deal_id` | `onboarding_cases.source_deal_id` |
| `company.name` | `onboarding_cases.intake_company_name` |
| `contact.first_name` | `onboarding_cases.intake_contact_first_name` |
| `contact.last_name` | `onboarding_cases.intake_contact_last_name` |
| `contact.email` | `onboarding_cases.intake_contact_email` |
| `contact.phone` | `onboarding_cases.intake_contact_phone` |
| sanitized `metadata` and `event_type` | `onboarding_cases.intake_metadata` |

These values remain non-authoritative intake data. They must not be written to `clients`.

### 5.5 Accepted field policy

The accepted top-level request fields are:

- `event_type`;
- `event_id`;
- `deal_id`;
- `company`;
- `contact`;
- `metadata`.

The request must be rejected with `invalid_payload` and field code `unsupported_field` when it contains another top-level field, including an externally supplied `source_system`.

The accepted `company` field is:

- `name`.

The accepted `contact` fields are:

- `first_name`;
- `last_name`;
- `email`;
- `phone`.

Unknown fields inside `company` or `contact` must be rejected with `unsupported_field`.

The accepted `metadata` fields for the initial Mock CRM contract are:

- `pipeline_id`;
- `owner_id`.

When present, each accepted metadata value must be a string or `null`. A blank metadata string after trimming must be normalized to JSON `null`.

Unknown metadata fields must be rejected with `unsupported_field`. Adding another CRM metadata field requires an explicit contract update.

## 6. Normalization contract

Normalization must be deterministic and must occur before any onboarding-case lookup or insert.

### 6.1 Source system

WF01 assigns:

```text
mock_crm
```

The value is already in the lowercase format required by `onboarding_cases.source_system`.

### 6.2 Event type

`event_type` must be normalized by removing surrounding whitespace.

The normalized value must equal:

```text
deal.won
```

The comparison is case-sensitive. Values such as `Deal.Won`, `DEAL.WON`, or `deal_won` are invalid.

### 6.3 Source identifiers

`event_id` and `deal_id` must be normalized by removing surrounding whitespace.

WF01 must preserve:

- letter case;
- internal whitespace;
- punctuation;
- prefixes and leading zeroes.

The normalized values are used directly as:

- `source_event_id`;
- `source_deal_id`.

WF01 must not generate replacement identifiers when either source identifier is missing or invalid.

### 6.4 Company name

`company.name` must be normalized by removing surrounding whitespace.

WF01 must preserve its original:

- letter case;
- punctuation;
- legal suffix;
- internal spacing.

WF01 must not attempt to determine the canonical legal company name.

### 6.5 Contact values

The following normalization rules apply:

| Field | Normalization |
|---|---|
| `contact.first_name` | Trim surrounding whitespace; convert blank result to SQL `NULL` |
| `contact.last_name` | Trim surrounding whitespace; convert blank result to SQL `NULL` |
| `contact.email` | Trim surrounding whitespace; preserve letter case |
| `contact.phone` | Trim surrounding whitespace; convert blank result to SQL `NULL` |

WF01 must not:

- infer missing names;
- convert the email address to lowercase;
- validate ownership of the email address;
- reformat the phone number;
- add a missing phone country code.

These values remain unvalidated intake data.

### 6.6 Intake metadata

WF01 must create `intake_metadata` as a JSON object containing:

```json
{
  "event_type": "deal.won",
  "crm": {}
}
```

The validated and normalized incoming `metadata` object must be stored inside the `crm` property. Only the metadata fields allowed by section 5.5 may be stored.

Example:

```json
{
  "event_type": "deal.won",
  "crm": {
    "pipeline_id": "b2b-sales",
    "owner_id": "user_17"
  }
}
```

WF01 must not place these values in `intake_metadata`:

- authentication headers;
- shared secrets;
- cookies;
- n8n credentials;
- complete HTTP headers;
- internal database connection information.

The resulting `intake_metadata` value must always be a JSON object.

## 7. Database resolution and idempotency

All onboarding-case resolution and intake-event writes must be performed inside one PostgreSQL transaction.

WF01 must not rely on a previous n8n execution result to decide whether the request is new or duplicated.

### 7.1 Resolution order

WF01 must first build the deterministic source-intake event key:

```text
crm:<source_system>:event:<source_event_id>:deal-won-received
```

WF01 must then resolve the request in this order:

1. search `onboarding_events` by the deterministic source-intake `event_key`;
2. when the event exists, resolve its related onboarding case and classify the request as `duplicate_event`;
3. when no source-intake event exists, search `onboarding_cases` by:

```text
(source_system, source_event_id)
```

4. when no case exists for the source event, search `onboarding_cases` by:

```text
(source_system, source_deal_id)
```

5. when neither case lookup returns a case, insert a new row in `onboarding_cases`.

The event-key lookup is required because `onboarding_cases.source_event_id` stores only the source event that originally created the case. Later distinct source events for the same deal are represented in `onboarding_events`.

The database uniqueness constraints remain the final authority when concurrent executions process the same event or deal.

### 7.2 New event and new deal

When neither the source-intake event, source event, nor source deal already exists, WF01 must:

- insert one `onboarding_cases` row;
- allow PostgreSQL to generate the case `id` and `correlation_id`;
- create the case in state `created`;
- store the normalized intake fields;
- allow the database trigger to create the seven required `onboarding_steps`;
- insert one source-intake business event;
- insert one case-created business event;
- return the newly created case.

The case state must remain `created`.

### 7.3 Duplicate source event

When the deterministic source-intake `event_key` already exists, WF01 must:

- resolve and return the case referenced by the existing event;
- classify the request as `duplicate_event`;
- verify that the stored source deal identifier equals the normalized incoming `deal_id`;
- not insert another onboarding case;
- not overwrite existing intake fields;
- not insert duplicate business events;
- not change the case state.

When the deterministic source-intake event does not exist but the defensive lookup by:

```text
(source_system, source_event_id)
```

returns an existing case, WF01 must first verify that the persisted `source_deal_id` equals the normalized incoming `deal_id`.

A different deal identifier is a source-identity conflict and must follow section 9.1.

A matching deal identifier together with a missing source-intake event is a persisted-data inconsistency. In that situation, WF01 must:

- resolve the authoritative case for error correlation;
- not classify the request as `duplicate_event`;
- not recreate the missing business event automatically;
- not invoke WF02;
- return HTTP `500 Internal Server Error`;
- route the sanitized technical failure to WF99.

### 7.4 Different source event for an existing deal

When the source event is new but a case already exists for:

```text
(source_system, source_deal_id)
```

WF01 must:

- return the existing case;
- classify the request as `existing_deal`;
- preserve the original `onboarding_cases.source_event_id`;
- not insert another onboarding case;
- not overwrite existing intake fields;
- record the newly received source event once in `onboarding_events`;
- not insert another case-created event;
- not change the case state.

The new source event identifier must be stored in the intake-event `event_key` and sanitized `event_data`, because the case row retains the identifier of the event that originally created it.

### 7.5 Deterministic business event keys

The source-intake event must use this deterministic key format:

```text
crm:<source_system>:event:<source_event_id>:deal-won-received
```

The case-created event must use this deterministic key format:

```text
onboarding:<case_id>:case-created
```

The unique constraint on `onboarding_events.event_key` must prevent duplicate event insertion.

### 7.6 Existing-case immutability during intake

A repeated WF01 request must not update the existing case’s:

- source identifiers;
- company name;
- contact values;
- intake metadata;
- correlation identifier;
- state.

Any future requirement to refresh intake data from CRM must use a separately defined workflow and audit contract. It is outside WF01.

## 8. WF02 dispatch contract

WF01 must decide whether to invoke WF02 only after the PostgreSQL transaction that resolves the onboarding case and writes the intake events has committed successfully.

The request classification (`created`, `duplicate_event`, or `existing_deal`) must not independently determine whether WF02 is invoked.

### 8.1 Dispatch condition

WF01 must invoke WF02 only when both conditions are true:

1. the authoritative onboarding case state is `created`;
2. no successful client-data-request operation exists for the case.

Conceptually, the decision is:

```sql
case.state = 'created'
AND NOT EXISTS (
    SELECT 1
    FROM external_operations
    WHERE case_id = case.id
      AND operation_type = 'send_client_data_request'
      AND status = 'succeeded'
)
```

PostgreSQL is the source of truth for this decision. WF01 must not use n8n execution history to determine whether WF02 was already invoked.

### 8.2 New case

When WF01 creates a new case and the dispatch condition is true, it must invoke WF02 after the intake transaction commits.

### 8.3 Duplicate request recovery

When WF01 resolves an existing case from a duplicate event or an existing deal, it must evaluate the same dispatch condition again.

If the case remains in state `created` and no successful client-data-request operation exists, WF01 must invoke WF02.

This allows a repeated CRM webhook to recover when:

- the onboarding case was committed successfully;
- WF01 stopped before invoking WF02;
- the previous WF02 invocation did not create a successful delivery operation.

### 8.4 Dispatch suppression

WF01 must not invoke WF02 when:

- the case state is not `created`;
- a `send_client_data_request` operation already has status `succeeded`;
- authentication failed;
- payload validation failed;
- the PostgreSQL intake transaction failed.

WF01 must not change the case state before invoking WF02.

### 8.5 WF02 input and invocation mode

WF01 must pass only this internal payload to WF02:

```json
{
  "case_id": "00000000-0000-0000-0000-000000000000",
  "correlation_id": "00000000-0000-0000-0000-000000000000",
  "trigger_source": "wf01",
  "request_cycle_key": "initial"
}
```

The values must be taken from the persisted onboarding case.

WF01 must invoke WF02 as an asynchronous n8n sub-workflow execution with `Wait for Sub-Workflow Completion` disabled.

The value:

```text
wf02_dispatch: invoked
```

means that n8n accepted creation or queueing of the WF02 sub-execution. It does not mean that WF02 completed or that the client-data email was delivered.

WF01 must not wait for WF02 to change the onboarding case state. The `case_state` returned by WF01 is the state selected from PostgreSQL after the intake transaction committed and before WF02 processing.

WF01 must not pass these values to WF02:

- the shared authentication secret;
- HTTP authorization headers;
- the complete incoming HTTP request;
- database credentials;
- unfiltered execution metadata.

WF02 must independently read the authoritative case and intake values from PostgreSQL using `case_id`.

## 9. State preconditions and source identity

WF01 does not require an existing onboarding case to be in a particular state before resolving the incoming source event.

A new onboarding case must always be created in state:

```text
created
```

WF01 must never transition an existing onboarding case to another state.

### 9.1 Existing event identity

When an existing source-intake event is found by its deterministic `event_key`, the `source_deal_id` stored in its sanitized `event_data` must equal the normalized incoming `deal_id`.

When the defensive case lookup by:

```text
(source_system, source_event_id)
```

returns an existing case, its persisted `source_deal_id` must also equal the normalized incoming `deal_id`.

When the event identifier already belongs to a different source deal, WF01 must:

- reject the request as a source-identity conflict;
- return HTTP `409 Conflict`;
- not update the existing case;
- not insert a business event;
- not invoke WF02.

A source event identifier must never be reassigned to another deal.

### 9.2 Existing deal identity

A new source event may refer to a source deal that already has an onboarding case.

In that situation, WF01 must resolve the existing case by:

```text
(source_system, source_deal_id)
```

The existing case remains authoritative. The new source event must not replace the original `source_event_id` stored in `onboarding_cases`.

### 9.3 Existing case state

When an existing case is resolved:

- WF01 must return its current persisted state;
- WF01 must not reset it to `created`;
- WF01 must not reopen `rejected`;
- WF01 must not reopen `completed`;
- WF01 must not change any approval, submission, client, provisioning, or completion fields.

The current case state affects only the WF02 dispatch decision described in section 8.

## 10. Transaction and concurrency contract

The onboarding-case resolution and business-event writes described in section 7 must execute as one atomic PostgreSQL operation.

### 10.1 Transaction boundary

The transaction must include:

- lookup or creation of the onboarding case;
- resolution of concurrent uniqueness conflicts;
- insertion of the source-intake event when required;
- insertion of the case-created event when required;
- selection of the authoritative case result returned to WF01.

The transaction must not include:

- invocation of WF02;
- Gmail operations;
- any other external API call;
- an HTTP response to the Mock CRM.

### 10.2 Concurrent case creation and final classification

When no case is found during the initial lookup, WF01 must attempt to insert the case using conflict-safe SQL.

Conceptually, the insert must behave as:

```sql
INSERT INTO onboarding_cases (...)
VALUES (...)
ON CONFLICT DO NOTHING
RETURNING id;
```

After the insert attempt, WF01 must select the authoritative case again by source event and source deal.

This second lookup is mandatory because another worker may have created the case concurrently.

The transaction must also determine whether the current execution inserted the source-intake event. It may use `RETURNING` or an equivalent PostgreSQL result.

The final `intake_result` must be determined only from the authoritative post-write result:

- `created` — the current transaction inserted both the onboarding case and its source-intake event;
- `existing_deal` — the case already existed, but the current transaction inserted the new source-intake event;
- `duplicate_event` — the source-intake event already existed, or the current transaction lost a concurrent conflict on its deterministic `event_key`.

Any classification calculated before the conflict-safe writes is provisional and must not be returned to the caller.

When insertion of the source-intake event loses a concurrent conflict, WF01 must re-read that event, verify its source-deal identity, and resolve its authoritative case before commit.

An execution that inserted a case but cannot insert or resolve the matching source-intake event must fail the transaction as a persisted-data inconsistency.

### 10.3 Concurrent duplicate event

When two workers process the same new source event concurrently:

- exactly one onboarding case may be created;
- exactly one source-intake business event may be inserted;
- exactly one case-created business event may be inserted;
- both executions must resolve the same authoritative case;
- the winning execution must return `created`;
- the execution that loses the event-key conflict must return `duplicate_event`;
- neither execution may overwrite the persisted intake fields.

### 10.4 Concurrent events for the same deal

When two different source events for the same new deal are processed concurrently:

- exactly one onboarding case may be created;
- the case must retain the source event identifier used by the winning case insert;
- each distinct source event may create its own source-intake event once;
- only one case-created event may exist;
- both executions must resolve the same authoritative case;
- the case-insert winner must return `created`;
- the other execution must return `existing_deal`.

### 10.5 Transaction rollback

When any required database statement fails before commit:

- the complete intake transaction must be rolled back;
- no partial case or business-event result may be treated as successful;
- WF02 must not be invoked;
- WF01 must return a technical failure response.

### 10.6 Commit before dispatch

WF01 may evaluate and perform the WF02 dispatch only after the intake transaction commits successfully.

A WF02 execution must never receive a `case_id` for an uncommitted or rolled-back onboarding case.

## 11. Business event contract

WF01 writes append-only records to `onboarding_events`.

Business-event payloads must be sanitized and must not contain authentication data or unnecessary personal data.

### 11.1 Source-intake event

A newly processed source event must use:

```text
event_type: crm_deal_won_received
actor_type: external_system
actor_identifier: mock_crm
```

Its deterministic `event_key` is defined in section 7:

```text
crm:<source_system>:event:<source_event_id>:deal-won-received
```

The event must contain:

- the resolved `case_id`;
- the case `correlation_id`;
- `previous_state` set to `NULL`;
- `new_state` set to `NULL`;
- sanitized `event_data`.

The `event_data` object must contain:

```json
{
  "source_system": "mock_crm",
  "source_event_id": "evt_10001",
  "source_deal_id": "deal_10001",
  "source_event_type": "deal.won",
  "intake_result": "created"
}
```

`intake_result` must be one of:

- `created`;
- `existing_deal`.

The source-intake event must not contain:

- contact email;
- contact phone;
- contact first or last name;
- complete incoming metadata;
- HTTP headers;
- authentication values.

A duplicate delivery of the same source event must not create another source-intake event.

### 11.2 Case-created event

A newly created onboarding case must use:

```text
event_type: onboarding_case_created
actor_type: workflow
actor_identifier: WF01
```

Its deterministic `event_key` is defined in section 7:

```text
onboarding:<case_id>:case-created
```

The event must contain:

- the new `case_id`;
- the generated `correlation_id`;
- `previous_state` set to `NULL`;
- `new_state` set to `created`;
- sanitized `event_data`.

The `event_data` object must contain:

```json
{
  "source_system": "mock_crm",
  "source_event_id": "evt_10001",
  "source_deal_id": "deal_10001"
}
```

The case-created event must be inserted only when WF01 actually creates the onboarding case.

### 11.3 Event insertion idempotency

Business events must use conflict-safe insertion based on the unique `event_key`.

Conceptually:

```sql
INSERT INTO onboarding_events (...)
VALUES (...)
ON CONFLICT (event_key) DO NOTHING;
```

A duplicate event key must not cause the complete intake transaction to fail.

## 12. Successful output contract

WF01 must return a JSON response only after:

- authentication succeeded;
- payload validation succeeded;
- the PostgreSQL intake transaction committed;
- any required WF02 invocation was accepted successfully.

### 12.1 Response body

A successful response must use this structure:

```json
{
  "status": "accepted",
  "intake_result": "created",
  "case_id": "00000000-0000-0000-0000-000000000000",
  "correlation_id": "00000000-0000-0000-0000-000000000000",
  "case_state": "created",
  "wf02_dispatch": "invoked"
}
```

`intake_result` must be one of:

- `created`;
- `duplicate_event`;
- `existing_deal`.

`wf02_dispatch` must be one of:

- `invoked`;
- `not_required`.

All identifiers and state values in the response must come from the authoritative PostgreSQL result.

`case_state` is the state selected by the committed intake transaction before asynchronous WF02 processing. A later state change performed by WF02 is outside the WF01 HTTP response.

### 12.2 New case response

When a new case is created, WF01 must return:

```text
HTTP 201 Created
```

The response must use:

```text
intake_result: created
```

### 12.3 Existing case response

When WF01 resolves an existing case, it must return:

```text
HTTP 200 OK
```

A repeated source event must use:

```text
intake_result: duplicate_event
```

A new event for an existing source deal must use:

```text
intake_result: existing_deal
```

### 12.4 Response data restrictions

The successful response must not include:

- company intake data;
- contact intake data;
- CRM metadata;
- authentication headers;
- the shared secret;
- database credentials;
- n8n credentials;
- complete internal execution data.

## 13. Rejection and error responses

Every response must use `application/json` unless the request is rejected directly by n8n authentication before workflow execution.

### 13.1 Unsupported content type

A request whose content type is not compatible with JSON must return:

```text
HTTP 415 Unsupported Media Type
```

Example body:

```json
{
  "status": "rejected",
  "error_code": "unsupported_media_type"
}
```

No onboarding business record may be created or updated.

### 13.2 Invalid JSON or payload

Malformed JSON or a request that violates the input contract must return:

```text
HTTP 400 Bad Request
```

Example body:

```json
{
  "status": "rejected",
  "error_code": "invalid_payload",
  "errors": [
    {
      "field": "contact.email",
      "code": "required"
    }
  ]
}
```

Validation errors may identify the invalid field and a stable error code.

Validation errors must not echo submitted field values.

No onboarding business record may be created or updated.

### 13.3 Authentication failure

Authentication failure behavior is defined in section 4.3 and must return:

```text
HTTP 401 Unauthorized
```

The response must not reveal whether the remaining payload would otherwise be valid.

### 13.4 Source-identity conflict

When the same source event identifier is received with a different source deal identifier, WF01 must return:

```text
HTTP 409 Conflict
```

Example body:

```json
{
  "status": "rejected",
  "error_code": "source_identity_conflict"
}
```

The response must not expose the identifiers or data of the existing conflicting case.

### 13.5 Technical failure

An unexpected database, n8n, or internal processing failure must return:

```text
HTTP 500 Internal Server Error
```

When no case was resolved, the response must use:

```json
{
  "status": "error",
  "error_code": "intake_processing_failed"
}
```

When a case was committed but WF02 dispatch failed, the response may include only the safe case references:

```json
{
  "status": "error",
  "error_code": "wf02_dispatch_failed",
  "case_id": "00000000-0000-0000-0000-000000000000",
  "correlation_id": "00000000-0000-0000-0000-000000000000"
}
```

The HTTP response must not expose:

- SQL error text;
- stack traces;
- hostnames;
- credentials;
- workflow internals;
- complete integration responses.

## 14. Failure handling contract

### 14.1 Contract rejections

The following outcomes are rejected inbound requests, not onboarding state transitions:

- authentication failure;
- unsupported content type;
- malformed JSON;
- missing or invalid required fields;
- unsupported event type;
- source-identity conflict.

These outcomes must not:

- create an onboarding case;
- change an onboarding case;
- create a canonical client;
- invoke WF02;
- create an external operation.

They must not be written to `error_log` as unexpected technical errors.

### 14.2 Database failure

When the intake transaction fails:

- PostgreSQL must roll back the transaction;
- WF01 must not return a successful response;
- WF01 must invoke WF99 or allow the configured n8n error workflow to process the failure;
- the error record must use workflow name `WF01 — Intake Deal Won`;
- error details must be sanitized;
- retryability must be classified when possible.

### 14.3 WF02 dispatch acceptance failure

When the onboarding case was committed but n8n cannot create or queue the required WF02 sub-execution:

- the committed case and events must remain unchanged;
- the case must remain in state `created`;
- WF01 must return HTTP `500`;
- the failure must be sent to WF99 with `case_id` and `correlation_id`;
- a later repeated CRM event must resolve the same case and reevaluate the WF02 dispatch condition.

The intake transaction must not be reversed because dispatch acceptance failed after commit.

A failure that occurs inside an already accepted WF02 sub-execution belongs to the WF02 and WF99 failure contracts. It cannot retroactively change an HTTP response already returned by WF01.

### 14.4 Unexpected workflow failure

An unexpected failure must not cause WF01 to:

- create a replacement case;
- generate a replacement source event identifier;
- update canonical client data;
- change the case state;
- perform an uncontrolled external retry.

Recovery must start from the state persisted in PostgreSQL.

## 15. Security and data minimization

WF01 processes external input that may contain company and contact information.

The workflow must apply these rules:

- authenticate before business validation;
- never store or log the shared secret;
- never copy complete HTTP headers into PostgreSQL;
- never copy the complete request body into `onboarding_events`;
- never copy contact values into `error_log`;
- never include personal contact data in the HTTP response;
- store only the intake fields required by `onboarding_cases`;
- store only sanitized CRM extension data in `intake_metadata`;
- use parameterized SQL values;
- never build SQL by concatenating untrusted request values;
- keep PostgreSQL as the authoritative source of case identity and state.

Production execution settings must minimize retention of complete webhook payloads in n8n execution history.

## 16. Observability contract

After a successful WF01 execution, PostgreSQL must make it possible to determine:

- whether the source event is represented by its deterministic `event_key`;
- whether the stored source-intake event originally created a case or resolved an existing deal;
- the authoritative case identifier;
- the correlation identifier;
- the current case state;
- which source events were received for the case;
- whether the case-created event exists;
- whether WF02 should have been dispatched.

PostgreSQL does not create a new business event for every repeated delivery of an already recorded source event. The `duplicate_event` result is derived during request processing from the existing deterministic event key; it is returned to the caller but is not persisted as a new business event.

After a technical failure, `error_log` must contain, when available:

- workflow name;
- n8n workflow identifier;
- n8n execution identifier;
- `case_id`;
- `correlation_id`;
- normalized error class;
- safe error code;
- sanitized error message;
- retryability classification;
- occurrence time.

Business-event records and technical-error records must remain separate.

## 17. Logical execution order

The implementation of WF01 must preserve this logical order:

```text
1. Receive POST webhook
2. Authenticate request
3. Verify JSON content type
4. Parse the raw request body
5. Validate body shape, accepted fields, and event type
6. Normalize intake values
7. Execute PostgreSQL intake transaction
8. Resolve authoritative case and final intake result
9. Evaluate WF02 dispatch condition from PostgreSQL
10. Queue WF02 asynchronously when required
11. Return sanitized HTTP response
```

WF01 must not invoke WF02, return success, or perform another business action before the PostgreSQL intake transaction commits.

This section defines required behavior, not the final n8n node layout.

## 18. Acceptance scenarios

### 18.1 Valid new event

Given an authenticated valid event for a new deal:

- HTTP response is `201`;
- exactly one onboarding case exists;
- case state is `created`;
- seven onboarding steps exist;
- one source-intake event exists;
- one case-created event exists;
- no canonical client exists;
- WF02 is invoked when the dispatch condition is true.

### 18.2 Duplicate delivery of the same event

Given the same authenticated event again:

- HTTP response is `200`;
- the same `case_id` is returned;
- `intake_result` is `duplicate_event`;
- no case field is overwritten;
- no duplicate business event is inserted;
- WF02 dispatch is reevaluated from PostgreSQL.

### 18.3 New event for an existing deal

Given a new event identifier for an existing source deal:

- HTTP response is `200`;
- the existing `case_id` is returned;
- `intake_result` is `existing_deal`;
- no second case is inserted;
- the original case `source_event_id` is preserved;
- one new source-intake event is inserted;
- no second case-created event is inserted.

### 18.4 Event identifier reused for another deal

Given an existing source event identifier with another deal identifier:

- HTTP response is `409`;
- no case is created or updated;
- no business event is inserted;
- WF02 is not invoked.

### 18.5 Invalid authentication

Given a missing or invalid authentication header:

- HTTP response is `401`;
- no business database write occurs;
- WF02 is not invoked.

### 18.6 Invalid payload

Given malformed JSON or an invalid required field:

- HTTP response is `400`;
- no onboarding case is created or updated;
- no business event is inserted;
- WF02 is not invoked.

### 18.7 Concurrent duplicate event

Given two concurrent executions for the same new event:

- exactly one case exists;
- exactly one source-intake event exists;
- exactly one case-created event exists;
- both executions resolve the same case;
- one response uses `created`;
- the other response uses `duplicate_event`.

### 18.8 Concurrent events for one deal

Given two concurrent events with different event identifiers for one new deal:

- exactly one case exists;
- both executions resolve the same case;
- each distinct source event is recorded at most once;
- exactly one case-created event exists;
- one response uses `created`;
- the other response uses `existing_deal`.

### 18.9 Existing case past `created`

Given a duplicate request for a case whose state is not `created`:

- the existing case is returned;
- no state change occurs;
- WF02 is not invoked.

### 18.10 Successful request operation already exists

Given a case in state `created` with a successful `send_client_data_request` operation:

- the existing case is returned;
- WF02 is not invoked;
- no new external operation is created by WF01.

### 18.11 Intake transaction failure

Given a PostgreSQL failure before commit:

- HTTP response is `500`;
- the transaction is rolled back;
- WF02 is not invoked;
- the technical failure is routed to WF99.

### 18.12 WF02 dispatch acceptance failure after commit

Given a successfully committed case when n8n cannot create or queue the required WF02 sub-execution:

- the case remains persisted in state `created`;
- HTTP response is `500`;
- the failure is routed to WF99;
- a later duplicate webhook can safely retry the dispatch path.

### 18.13 Responsibility boundary

For every WF01 scenario:

- WF01 does not insert or update `clients`;
- WF01 does not create a form token;
- WF01 does not send Gmail messages;
- WF01 does not provision a client;
- WF01 does not create Drive or Calendar resources;
- WF01 does not move the case out of `created`.

## 19. Contract completion criteria

The WF01 contract is complete when:

- the webhook authentication behavior is explicit;
- the request schema and field rules are explicit;
- normalization behavior is deterministic;
- PostgreSQL field mapping is explicit;
- new, duplicate, and existing-deal outcomes are distinguished;
- source identity conflicts are rejected;
- transaction and concurrency behavior are explicit;
- business-event keys and payloads are deterministic;
- WF02 dispatch conditions are explicit;
- success and failure responses are defined;
- technical errors and contract rejections are separated;
- security and data-minimization rules are explicit;
- every responsibility can be verified directly in PostgreSQL;
- no n8n workflow implementation is required to interpret the contract.