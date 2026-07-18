# WF03 — Receive and Validate Client Data

## 1. Purpose

WF03 receives a client submission through the n8n Form Trigger, authorizes it with the single-use form token created by WF02, stores one immutable submission version, validates it deterministically, and advances the onboarding case according to the persisted validation result.

A valid token authorizes one submission attempt for one onboarding case and one request cycle. It does not prove that the submitted business data is correct.

PostgreSQL remains the source of truth for token consumption, submission history, validation status, canonical client data, step status, case state, business events, and recovery decisions.

## 2. Responsibilities

WF03 is responsible for:

- exposing the production n8n Form Trigger used by the client-data link;
- accepting one opaque form token and one client-data payload;
- applying transport-level limits before database work;
- removing the plain token from working data as early as possible;
- normalizing accepted form fields deterministically;
- hashing the original token bytes with SHA-256;
- atomically validating and consuming the token;
- creating exactly one immutable `onboarding_submissions` version for an authorized submission;
- moving the case from `awaiting_client_data` to `data_received` in the same atomic database operation;
- maintaining the `collect_client_data` and `validate_client_data` steps;
- executing deterministic business validation;
- storing validation errors with the submission without storing submitted values in error messages;
- moving an invalid submission to `validation_failed`;
- invoking WF02 with a deterministic correction request cycle after validation failure;
- marking a valid submission `passed`;
- creating or reusing the canonical client by normalized company identity;
- updating canonical client fields only from the passed submission;
- linking the canonical client and accepted submission to the onboarding case;
- moving the case from `data_received` to `awaiting_approval` atomically;
- invoking WF04 only after the valid-data transaction commits;
- recording deterministic append-only business events;
- returning a safe client-facing completion result;
- sending unexpected technical failures to WF99.

## 3. Explicit non-responsibilities

WF03 must not:

- authenticate the CRM webhook;
- create or replace an onboarding case;
- generate or deliver form tokens;
- send client-data request emails directly;
- reuse a consumed, expired, revoked, or undelivered token;
- accept an arbitrary `case_id`, `correlation_id`, or submission sequence from the client;
- trust client-supplied normalized values;
- validate company identity through an external registry in the initial implementation;
- request manual approval directly through Gmail;
- provision the external client account;
- create Drive or Calendar resources;
- update canonical client data from an invalid submission;
- delete or overwrite a previous submission;
- reopen `rejected` or `completed` cases;
- expose internal identifiers, SQL errors, token status, or case state to an unauthorized caller;
- retain the plain token or complete token-bearing URL in normal execution history.

## 4. Trigger and public endpoint

### 4.1 n8n Form Trigger

WF03 is started by the production n8n Form Trigger referenced by `CLIENT_DATA_FORM_BASE_URL` in WF02.

The public form endpoint must use HTTPS outside local development.

The temporary n8n test URL is not part of the external contract and must not be sent to clients.

### 4.2 Token transport

The opaque token is supplied only through the query parameter:

```text
token=<unpadded Base64URL value>
```

The form must not request or expose:

- case identifier;
- correlation identifier;
- source deal identifier;
- token identifier;
- submission sequence;
- request-cycle key.

The token query parameter must not be copied into submitted business data.

### 4.3 Accepted form fields

The initial form accepts exactly these business fields:

```text
company_identifier_country
company_identifier_type
company_identifier_value
legal_name
primary_contact_first_name
primary_contact_last_name
primary_contact_email
primary_contact_phone
```

Unknown business fields must be rejected before token consumption with a generic invalid-form response.

Transport metadata created by n8n is not part of `submitted_data` and must not be persisted as business data.

### 4.4 Request shape

The request must contain one form submission, not an array or batch.

Each accepted business field must be a string when present. Missing values and blank strings are allowed at the transport layer so that an authorized but incomplete submission can be stored and classified as a business validation failure.

The token itself is mandatory. A missing or malformed token is an unauthorized request and must not create a submission.

## 5. Transport-level protection

Before hashing or database access, WF03 must enforce:

- HTTPS in non-local environments;
- configured request-body size limit, initially 64 KiB;
- maximum token text length, initially 128 characters;
- maximum field counts;
- maximum raw field lengths;
- an ingress rate limit appropriate for a public form;
- rejection of arrays, nested objects, uploaded files, and unsupported content types.

Initial maximum raw lengths:

| Field | Maximum characters |
|---|---:|
| `company_identifier_country` | 8 |
| `company_identifier_type` | 64 |
| `company_identifier_value` | 128 |
| `legal_name` | 256 |
| `primary_contact_first_name` | 128 |
| `primary_contact_last_name` | 128 |
| `primary_contact_email` | 320 |
| `primary_contact_phone` | 64 |

A transport rejection must not consume the token or write business data.

The response must not reveal whether a supplied token would otherwise be valid.

## 6. Submitted and normalized data

### 6.1 `submitted_data`

For an authorized submission, `submitted_data` contains exactly the accepted business fields as received from the form.

It must not contain:

- plain token;
- token hash;
- query parameters;
- HTTP headers;
- cookies;
- IP address;
- user agent;
- n8n credentials;
- database identifiers;
- complete transport metadata.

Security and transport metadata needed for an audit may be stored only in separately sanitized event metadata, not in the submitted business object.

### 6.2 `normalized_data`

WF03 creates one deterministic JSON object with the same logical fields plus the normalized company identifier:

```json
{
  "company_identifier_country": "PL",
  "company_identifier_type": "nip",
  "company_identifier_value": "123-456-78-90",
  "company_identifier_value_normalized": "1234567890",
  "legal_name": "Example Industries Sp. z o.o.",
  "primary_contact_first_name": "Anna",
  "primary_contact_last_name": "Kowalska",
  "primary_contact_email": "anna.kowalska@example.com",
  "primary_contact_phone": "+48500100200"
}
```

Missing or blank values are represented as JSON `null` until business validation is completed.

The client must never be allowed to supply `normalized_data` directly.

## 7. Deterministic normalization

Normalization must not depend on locale-specific UI behavior, external APIs, or AI.

### 7.1 Common string rule

For every business string:

- apply Unicode NFKC normalization;
- remove surrounding Unicode whitespace;
- replace internal runs of Unicode whitespace with one ASCII space where the field allows spaces;
- convert an empty result to JSON `null`.

### 7.2 Company identifier country

Normalize by:

- trimming;
- converting ASCII letters to uppercase.

A valid result must contain exactly two ASCII letters:

```text
^[A-Z]{2}$
```

### 7.3 Company identifier type

Normalize by:

- trimming;
- converting ASCII letters to lowercase.

A valid result must match:

```text
^[a-z0-9][a-z0-9_-]{0,63}$
```

The initial implementation supports alphanumeric business identifiers whose type-specific rules do not contradict the generic normalization below. A type requiring different semantics must be added through an explicit contract update.

### 7.4 Company identifier value

`company_identifier_value` preserves the trimmed, user-visible value.

`company_identifier_value_normalized` is created by:

1. applying Unicode NFKC;
2. converting ASCII letters to uppercase;
3. removing Unicode whitespace;
4. removing the separators `-`, `.`, and `/`;
5. requiring the remaining value to contain only ASCII letters and digits.

A valid normalized result must match:

```text
^[A-Z0-9]{2,64}$
```

WF03 does not invent a missing country prefix and does not perform external registry verification.

### 7.5 Legal name and contact names

Normalize by the common string rule while preserving letter case and punctuation.

No name may be inferred from the CRM intake fields.

### 7.6 Email

Normalize by:

- trimming;
- applying Unicode NFKC;
- converting the complete address to lowercase.

The initial validation is syntactic. It does not prove mailbox ownership or deliverability.

### 7.7 Phone

Normalize by:

- trimming;
- removing spaces, hyphens, and parentheses;
- preserving one leading `+`;
- requiring an E.164-compatible result.

A valid result must match:

```text
^\+[1-9][0-9]{7,14}$
```

WF03 must not guess a country code.

## 8. Token decoding and hashing

### 8.1 Base64URL decoding

The submitted token text must be decoded as unpadded Base64URL.

A valid decoded token must contain exactly:

```text
32 bytes
```

Invalid encoding or any other byte length is treated as an unauthorized request.

### 8.2 Token hash

WF03 calculates:

```text
SHA-256(original decoded token bytes)
```

The resulting 32 bytes are passed to PostgreSQL.

WF03 must not hash the URL text as a substitute for the decoded random bytes.

### 8.3 Token-data lifetime

After the hash is calculated, the workflow must replace the token-bearing item with a sanitized item containing only the hash and normalized business data required for the database call.

The plain token and complete request URL must not be:

- pinned;
- logged;
- returned;
- inserted into events;
- inserted into `error_log`;
- retained in successful or failed n8n execution data.

## 9. Atomic token consumption and submission creation

### 9.1 Required database function

WF03 must call:

```text
consume_form_token_and_create_submission(
  p_token_hash,
  p_submitted_data,
  p_normalized_data
)
```

This function is the authoritative authorization and submission-creation boundary.

WF03 must not reproduce token-consumption logic with separate non-atomic queries.

### 9.2 Successful atomic outcome

For outcome `created`, PostgreSQL has atomically:

- locked the token;
- verified that the token exists;
- verified that it is `delivered` and unexpired;
- verified that the case is `awaiting_client_data`;
- transitioned the token to `consumed`;
- set `consumed_at` using database time;
- created one immutable submission with the next sequence number;
- moved the case to `data_received`.

WF03 must use the returned:

- `created_submission_id`;
- `onboarding_case_id`;
- `created_submission_sequence`.

It must then reread the authoritative case, token, submission, and steps.

### 9.3 Unauthorized outcomes

The database function may return:

- `invalid_token`;
- `already_consumed`;
- `revoked`;
- `expired`;
- `not_delivered`;
- `invalid_case_state`.

No unauthorized outcome may create another submission or change case state.

The public response must use one generic message equivalent to:

```text
This form link is invalid or no longer available.
```

The response must not reveal the exact token status, case state, token identifier, or whether the token ever existed.

### 9.4 Repeated submission

A repeated request using the same consumed token must not create a second submission.

WF03 must not return the existing submission identifier to the public caller.

### 9.5 Unauthorized security event

When the token resolves to a known case and token row, WF03 may insert one conflict-safe event for the rejection reason using the case correlation identifier.

The event must not include the token text or token hash.

For an unknown token, the initial implementation relies on rate-limited ingress security logs and does not create an unbounded business-event row for every arbitrary token guess.

Unauthorized requests are security outcomes, not unexpected technical errors, and are not inserted into `error_log` unless the workflow itself fails unexpectedly.

## 10. Step transitions after authorized submission

After outcome `created`, WF03 must update the steps inside the same explicit validation-processing transaction where applicable.

### 10.1 `collect_client_data`

The step must transition to:

```text
status = completed
```

It must:

- set `completed_at` using database time;
- clear `last_error_summary`;
- preserve its request-cycle attempt count.

### 10.2 `validate_client_data`

Before deterministic validation result is finalized, the step must be prepared as:

```text
status = in_progress
```

For a new submission validation attempt:

- increment `attempt_count` by one;
- set `started_at` when appropriate;
- clear `completed_at`;
- clear `last_error_summary`.

The validation step attempt count represents submission validation attempts.

## 11. Business validation rules

Business validation occurs only after the authorized submission row exists.

Every failure is stored with the immutable submission version.

### 11.1 Required fields

All normalized fields are required:

- `company_identifier_country`;
- `company_identifier_type`;
- `company_identifier_value`;
- `company_identifier_value_normalized`;
- `legal_name`;
- `primary_contact_first_name`;
- `primary_contact_last_name`;
- `primary_contact_email`;
- `primary_contact_phone`.

### 11.2 Country

Must match:

```text
^[A-Z]{2}$
```

### 11.3 Identifier type

Must match:

```text
^[a-z0-9][a-z0-9_-]{0,63}$
```

### 11.4 Identifier value

The original value must be non-blank.

The normalized value must match:

```text
^[A-Z0-9]{2,64}$
```

### 11.5 Legal and contact names

Each must be non-blank after normalization and must remain within its configured maximum length.

WF03 does not attempt to determine whether a person or company name is legally accurate.

### 11.6 Email

The normalized email must:

- contain one `@` separator;
- have non-empty local and domain parts;
- contain no whitespace or control characters;
- remain within 320 characters;
- have a domain containing at least one dot;
- use labels that do not begin or end with a hyphen.

This is syntax validation only.

### 11.7 Phone

The normalized phone must match the E.164-compatible rule defined in section 7.7.

### 11.8 Validation error object

Each validation error uses:

```json
{
  "field": "primary_contact_email",
  "code": "invalid_format",
  "message_key": "primary_contact_email.invalid_format"
}
```

Allowed stable codes include:

- `required`;
- `invalid_format`;
- `unsupported_identifier`;
- `too_long`;
- `invalid_characters`.

Validation errors must not contain submitted field values.

The complete `validation_errors` value must be a JSON array.

## 12. Validation failure transaction

When one or more validation errors exist, WF03 must execute one PostgreSQL transaction that:

1. locks the pending submission;
2. verifies that it belongs to the case and remains `pending`;
3. updates it to `validation_status = 'failed'`;
4. sets `validation_errors` and `validated_at` using database time;
5. conditionally moves the case from `data_received` to `validation_failed`;
6. keeps the `validate_client_data` step at `failed_retryable`;
7. stores a sanitized step error summary containing error codes and field names only;
8. inserts deterministic business events;
9. commits.

Exactly one case row must transition.

A validation failure is a business outcome, not an unexpected technical error.

The invalid submission must remain stored and must never modify `clients`.

## 13. Correction-cycle dispatch

### 13.1 WF02 input

After the validation-failure transaction commits, WF03 must invoke WF02 asynchronously with:

```json
{
  "case_id": "00000000-0000-0000-0000-000000000000",
  "correlation_id": "00000000-0000-0000-0000-000000000000",
  "trigger_source": "wf03",
  "request_cycle_key": "validation_failed:00000000-0000-0000-0000-000000000000",
  "failed_submission_id": "00000000-0000-0000-0000-000000000000"
}
```

The UUID suffix must be the failed submission identifier.

### 13.2 Dispatch mode

Use an asynchronous n8n sub-workflow execution with `Wait for Sub-Workflow Completion` disabled.

The form response must not wait for Gmail correction delivery.

### 13.3 Dispatch failure

If PostgreSQL committed `validation_failed` but n8n cannot accept the WF02 sub-execution:

- do not roll back the validation result;
- do not create a replacement submission;
- keep the case in `validation_failed`;
- send the technical failure to WF99 with case and submission identifiers;
- require later recovery to invoke WF02 for the same deterministic request cycle.

## 14. Validation success transaction

When no validation errors exist, WF03 must execute one PostgreSQL transaction that:

1. locks the pending submission;
2. verifies that it belongs to the case and remains `pending`;
3. updates it to `validation_status = 'passed'`;
4. sets `validated_at` using database time;
5. creates or locks the canonical client identified by the normalized tuple;
6. creates or updates canonical client fields from the passed submission;
7. sets the canonical client's `source_submission_id` to the current passed submission;
8. links `client_id` and `accepted_submission_id` to the onboarding case;
9. conditionally moves the case from `data_received` to `awaiting_approval`;
10. marks `validate_client_data` as `completed`;
11. clears the validation step error summary;
12. inserts deterministic business events;
13. commits.

Exactly one case row must transition.

## 15. Canonical client identity and concurrency

### 15.1 Identity tuple

A canonical client is created or reused by:

```text
(company_identifier_country,
 company_identifier_type,
 company_identifier_value_normalized)
```

Email is not a client deduplication key.

### 15.2 Conflict-safe creation

Canonical client creation must use the database unique constraint as the final authority.

Conceptually:

```sql
INSERT INTO clients (...)
VALUES (...)
ON CONFLICT (
  company_identifier_country,
  company_identifier_type,
  company_identifier_value_normalized
)
DO UPDATE SET
  legal_name = EXCLUDED.legal_name,
  primary_contact_first_name = EXCLUDED.primary_contact_first_name,
  primary_contact_last_name = EXCLUDED.primary_contact_last_name,
  primary_contact_email = EXCLUDED.primary_contact_email,
  primary_contact_phone = EXCLUDED.primary_contact_phone,
  source_submission_id = EXCLUDED.source_submission_id
RETURNING id;
```

The current passed submission must be used as `source_submission_id` so the database trigger can verify that canonical changes originate from a passed submission.

### 15.3 Concurrent valid submissions

Concurrent transactions resolving the same normalized client identity must serialize through the unique constraint and row lock.

They must:

- resolve one canonical client row;
- preserve each immutable submission;
- link each onboarding case to the same client where appropriate;
- never create duplicate canonical identities;
- never use a failed submission as canonical source data.

The last committed passed submission may become the current canonical source after serialization. Historical source submissions remain preserved.

## 16. WF04 dispatch

### 16.1 Input

After the validation-success transaction commits, WF03 must invoke WF04 asynchronously with only persisted identifiers required by the WF04 contract, including at least:

```json
{
  "case_id": "00000000-0000-0000-0000-000000000000",
  "correlation_id": "00000000-0000-0000-0000-000000000000",
  "accepted_submission_id": "00000000-0000-0000-0000-000000000000",
  "client_id": "00000000-0000-0000-0000-000000000000",
  "trigger_source": "wf03"
}
```

WF04 must reread all authoritative data from PostgreSQL.

### 16.2 Commit before dispatch

WF04 must never receive identifiers for an uncommitted validation result or client link.

### 16.3 Dispatch failure

If PostgreSQL committed `awaiting_approval` but n8n cannot accept the WF04 sub-execution:

- do not roll back the passed submission or client link;
- keep the case in `awaiting_approval`;
- send the technical failure to WF99;
- allow controlled later recovery to invoke WF04 from persisted state.

## 17. Business-event contract

All events are append-only and use conflict-safe insertion by deterministic `event_key`.

### 17.1 Submission received

```text
event_type: client_data_submission_received
actor_type: external_user
actor_identifier: null
event_key: onboarding:<case_id>:submission:<submission_id>:received
previous_state: awaiting_client_data
new_state: data_received
```

Sanitized `event_data`:

```json
{
  "submission_id": "00000000-0000-0000-0000-000000000000",
  "submission_sequence": 1,
  "form_token_id": "00000000-0000-0000-0000-000000000000"
}
```

The event must not include submitted values, token material, IP address, or complete request metadata.

### 17.2 Validation failed

```text
event_type: client_data_validation_failed
event_key: onboarding:<case_id>:submission:<submission_id>:validation-failed
actor_type: workflow
actor_identifier: WF03
previous_state: data_received
new_state: validation_failed
```

The event data may include field names and stable error codes, but not field values.

### 17.3 Validation passed

```text
event_type: client_data_validation_passed
event_key: onboarding:<case_id>:submission:<submission_id>:validation-passed
actor_type: workflow
actor_identifier: WF03
previous_state: data_received
new_state: awaiting_approval
```

The event data contains only submission and canonical client identifiers plus a client outcome of `created` or `reused`.

### 17.4 Canonical client linked

WF03 may insert a separate event:

```text
event_type: canonical_client_linked
event_key: onboarding:<case_id>:submission:<submission_id>:canonical-client-linked
```

It must not duplicate canonical contact or identifier values in the event payload.

## 18. Client-facing response contract

### 18.1 Authorized valid submission

Return a completion result equivalent to:

```json
{
  "status": "accepted",
  "result": "validation_passed",
  "message": "Your onboarding data was received successfully."
}
```

The response must not include internal identifiers or approval details.

### 18.2 Authorized invalid submission

After the validation-failure transaction and successful acceptance of the WF02 correction dispatch, return a result equivalent to:

```json
{
  "status": "accepted",
  "result": "validation_failed",
  "errors": [
    {
      "field": "primary_contact_email",
      "code": "invalid_format"
    }
  ],
  "message": "Your data was received, but corrections are required. A new secure link will be sent."
}
```

The response may identify fields and stable codes but must not echo submitted values.

When correction dispatch acceptance fails, the submission remains failed and the response must not claim that a new email was sent.

### 18.3 Unauthorized link

Use one generic client-facing response for missing, invalid, expired, revoked, consumed, undelivered, or wrong-state tokens.

No internal reason is disclosed.

### 18.4 Technical failure

A safe technical response must not expose:

- SQL messages;
- stack traces;
- token status;
- case state;
- database or workflow identifiers;
- submitted values;
- credentials.

## 19. Unexpected technical failures

Unexpected examples include:

- PostgreSQL connection failure;
- malformed database function result;
- submission or case missing after an outcome of `created`;
- state compare-and-set updating zero rows unexpectedly;
- canonical client conflict that cannot be reconciled;
- required step row missing;
- n8n sub-workflow dispatch acceptance failure;
- runtime normalization exception;
- retained token-bearing execution data detected.

WF03 must invoke WF99 or allow the configured n8n error workflow to process the failure.

The sanitized context should include, when available:

- workflow name `WF03 — Receive and Validate Client Data`;
- workflow and execution identifiers;
- case identifier;
- correlation identifier;
- form token identifier, never token material;
- submission identifier;
- collection and validation step identifiers;
- stable error class and code;
- retryability classification.

## 20. Transaction boundaries

### 20.1 Authorization transaction

The `consume_form_token_and_create_submission` database call atomically consumes the token, creates the pending submission, and moves the case to `data_received`.

### 20.2 Validation-failure transaction

Atomically finalizes the submission as failed, updates steps, moves the case to `validation_failed`, and inserts events.

### 20.3 Validation-success transaction

Atomically finalizes the submission as passed, creates or updates the canonical client, links the case, updates steps, moves the case to `awaiting_approval`, and inserts events.

### 20.4 Workflow dispatches

WF02 or WF04 invocation occurs only after the corresponding PostgreSQL transaction commits.

No external workflow dispatch belongs inside a PostgreSQL transaction.

## 21. Concurrency and idempotency

### 21.1 Same token submitted concurrently

Expected:

- one execution consumes the token;
- one submission is created;
- one case transition to `data_received` occurs;
- the other execution receives an unauthorized no-write outcome;
- no duplicate submission sequence exists.

### 21.2 Repeated execution after submission creation

WF03 must use the returned submission identifier and persisted state.

It must not create another submission to recover a later processing failure.

Recovery must resume from the pending submission and current case state through a controlled invocation mechanism defined before implementation.

### 21.3 Validation finalization concurrency

Only a submission with `validation_status = 'pending'` may be finalized.

A repeated finalization must reread and return the authoritative existing result without changing canonical data twice or duplicating events.

### 21.4 Canonical client concurrency

The normalized identity unique constraint is the final authority. Conflict-safe SQL and row locking must be used.

## 22. Security and privacy

### 22.1 Token secrecy

The plain token is a bearer credential until consumed.

It must not appear in:

- PostgreSQL;
- Git;
- normal logs;
- events;
- error records;
- response bodies;
- screenshots;
- analytics;
- retained execution data;
- reverse-proxy query logs.

Reverse-proxy and access-log configuration must redact or omit the token query parameter.

### 22.2 Form data

Submitted business values are stored only in `onboarding_submissions` and, after validation, in the canonical `clients` row where required.

They must not be duplicated into events, operation summaries, or technical errors.

### 22.3 n8n execution persistence

Production workflow settings must prevent persistence of token-bearing execution data.

The token-bearing item must be sanitized before any node that can throw an error containing input data.

### 22.4 Browser behavior

The form and completion response should send headers or equivalent platform settings that prevent caching of token-bearing pages where supported.

The form must not load third-party analytics or resources that could receive the complete token URL through a referrer.

## 23. Logical execution order

WF03 must preserve this logical order:

```text
1. Receive Form Trigger request
2. Enforce transport and size limits
3. Validate accepted field names and scalar types
4. Decode the Base64URL token
5. Hash the original token bytes
6. Build submitted_data without token or transport metadata
7. Build deterministic normalized_data
8. Remove plain token and complete URL from working data
9. Call consume_form_token_and_create_submission atomically
10. Handle unauthorized outcomes with one generic response
11. Reread authoritative case, token, submission, and steps
12. Mark collection complete and validation in progress
13. Execute deterministic business validation
14A. On failure, atomically persist failed result and validation_failed state
15A. Dispatch WF02 for the deterministic correction cycle
16A. Return sanitized validation-failed response
14B. On success, atomically persist passed result, canonical client, and awaiting_approval state
15B. Dispatch WF04
16B. Return sanitized success response
```

## 24. Acceptance scenarios

### 24.1 Valid new submission

Given a delivered, unexpired token for a case in `awaiting_client_data` and valid form data.

Expected:

- token becomes `consumed`;
- one pending submission is created and then marked `passed`;
- case transitions through `data_received` to `awaiting_approval`;
- collection and validation steps become `completed`;
- canonical client is created or reused;
- case links the client and accepted submission;
- deterministic events exist;
- WF04 dispatch is accepted;
- no token material is persisted.

### 24.2 Missing required business field

Expected:

- valid token is consumed;
- one immutable submission is stored;
- submission becomes `failed` with a `required` error;
- canonical client is not created or updated;
- case becomes `validation_failed`;
- WF02 receives the failed submission identifier for a new correction cycle.

### 24.3 Invalid email and phone

Expected:

- errors contain field names and stable codes only;
- submitted values remain only in the submission row;
- no canonical update occurs.

### 24.4 Unknown token

Expected:

- generic unavailable-link response;
- no submission;
- no case change;
- no `error_log` row for the business security outcome.

### 24.5 Expired token

Expected:

- generic unavailable-link response;
- no submission;
- token lifecycle is consistent with PostgreSQL;
- no state change.

### 24.6 Consumed token replay

Expected:

- no second submission;
- no duplicate event;
- no disclosure that the token was previously valid.

### 24.7 Token not delivered

Expected:

- no submission;
- no state change;
- generic response.

### 24.8 Wrong case state

Expected:

- no submission;
- no state reset;
- generic response.

### 24.9 Concurrent same-token submission

Expected:

- one submission only;
- one sequence number only;
- one successful case transition;
- one caller receives the generic unavailable-link result.

### 24.10 Existing canonical client

Given a passed submission whose normalized identity already exists.

Expected:

- no duplicate client row;
- existing client is locked and updated from the new passed submission;
- the onboarding case links the existing client;
- audit history preserves both submissions.

### 24.11 Concurrent canonical identity creation

Expected:

- one canonical client row;
- both transactions resolve the same client identifier;
- no uniqueness error escapes as an uncontrolled workflow failure.

### 24.12 Correction dispatch failure

Expected:

- failed submission and `validation_failed` state remain committed;
- response does not claim correction email delivery;
- WF99 receives safe context;
- recovery reuses `validation_failed:<submission_id>`.

### 24.13 Approval dispatch failure

Expected:

- passed submission, canonical client, and `awaiting_approval` state remain committed;
- WF99 receives safe context;
- no duplicate client or submission is created.

### 24.14 Plain-token persistence check

After success, validation failure, unauthorized requests, concurrent submission, and unexpected failures:

- PostgreSQL contains no plain token;
- events and errors contain no plain token;
- workflow output contains no plain token;
- retained n8n data contains no token or complete form URL;
- proxy logs do not contain the token query value.

## 25. Implementation gate for WF03

The WF03 contract is satisfied only when implementation tests prove:

- valid-token happy path;
- deterministic normalization;
- every business validation rule;
- immutable failed submission storage;
- canonical client creation and reuse;
- canonical identity concurrency safety;
- single-use token behavior;
- unknown, expired, revoked, consumed, undelivered, and wrong-state token handling;
- same-token concurrency safety;
- correct step transitions;
- correct case transitions;
- deterministic events;
- correction-cycle WF02 dispatch;
- WF04 dispatch after commit;
- recovery from dispatch acceptance failures;
- direct PostgreSQL verification;
- absence of token and unnecessary personal data from logs, events, errors, outputs, and retained execution data.

No WF04 implementation may depend on WF03 until this contract and the final cross-workflow contract review are complete.
