# Internal asynchronous dispatch amendment

## Status

This document is a normative amendment to the Stage 6 workflow contracts for WF98, WF99, and the destination workflows invoked by WF98.

It records the transport change introduced after testing n8n `2.30.8` in queue mode.

Until the affected workflow exports are re-exported from n8n and committed, this document describes the intended runtime contract but does not claim that every checked-in JSON export already matches it.

## 1. Problem

WF98 originally used `Execute Sub-workflow` with `Wait for Sub-Workflow Completion` disabled.

During testing in queue mode, the parent execution passed one item into the dispatch node and n8n created a successful child execution, but the child `Internal Invocation Trigger` received zero items. The child execution therefore completed without processing the intended payload.

Synchronous execution with waiting enabled transferred the item, but that mode does not satisfy the asynchronous Retry Dispatcher contract.

The affected transport must not be used as the production asynchronous boundary for WF98.

## 2. Decision

WF98 dispatches destination workflows through authenticated internal HTTP POST requests to production Webhook triggers.

Conceptual flow:

```text
WF98
  -> HTTP Request
  -> authenticated internal production Webhook
  -> destination input normalization and validation
  -> destination claim/recovery logic
```

The Webhook responds immediately. WF98 treats an HTTP `2xx` response as dispatch acceptance only; it does not treat it as proof that the destination business operation succeeded.

## 3. Internal endpoints

The internal routes are:

```text
WF02  POST /webhook/internal/wf02-retry-dispatch
WF03  POST /webhook/internal/wf03-retry-dispatch
WF04  POST /webhook/internal/wf04-retry-dispatch
WF05  POST /webhook/internal/wf05-retry-dispatch
WF06  POST /webhook/internal/wf06-retry-dispatch
WF99  POST /webhook/internal/wf99-retry-dispatch
```

Within the Docker Compose network, WF98 calls the n8n main service rather than `localhost`:

```text
http://n8n-main:5678/webhook/internal/<workflow>-retry-dispatch
```

`localhost` is invalid from a worker container because it resolves to that worker container itself.

## 4. Authentication

Every internal Webhook uses n8n Header Auth.

The credential value is stored only in n8n credentials and must not be committed to Git.

The current logical header name is:

```text
X-WF98-Internal-Token
```

The same credential is selected by the destination Webhook and the corresponding WF98 HTTP Request node.

The credential secret must not appear in workflow documentation, screenshots committed to the repository, execution fixtures, logs, or exported test payloads.

## 5. Request body

Each WF98 dispatch sends exactly one JSON object.

The HTTP Request node uses the complete input item as the JSON body:

```javascript
{{ $json }}
```

Payloads continue to follow the destination-specific contract defined by WF98. WF98 must not copy credentials, token material, full request summaries, provider responses, or client form data into the dispatch body.

## 6. Destination input normalization

A destination workflow may temporarily retain two entry points during migration:

```text
Internal Invocation Trigger -> payload in $json
Webhook Trigger             -> payload in $json.body
```

The first validation or normalization node must select the payload as follows:

```javascript
const rawInput = $json ?? {};
const input =
  rawInput.body &&
  typeof rawInput.body === 'object' &&
  !Array.isArray(rawInput.body)
    ? rawInput.body
    : rawInput;
```

After normalization, the existing destination-specific allowlists, UUID checks, state checks, operation checks, and claim logic remain mandatory.

The presence of Header Auth does not replace payload validation.

## 7. WF99 input variants

WF99 accepts two explicit internal variants through the internal Webhook:

```text
explicit_internal
notification_retry
```

`Validate Internal Invocation` must normalize `$json.body` before applying its strict top-level field allowlists and sanitization rules.

The n8n Error Trigger remains a separate entry point and is not connected through the internal Webhook branch.

## 8. WF03 recovery route

WF03 remains a valid WF98 destination for the persisted state-gap recovery class:

```text
pending_submission_validation
```

The normal WF03 client entry point remains the n8n Form Trigger. The internal Webhook is an additional recovery-only entry point and must not bypass token-consumption or submission ownership rules.

The recovery branch must load the already persisted pending submission by identifier and continue deterministic validation. It must not reinterpret an internal retry payload as a new client form submission.

## 9. WF98 error routing

Each HTTP Request dispatch node must use an error output.

Required connections:

```text
HTTP success output -> Mark Dispatch Accepted
HTTP error output   -> Mark Dispatch Failed
```

A network error, authentication error, non-`2xx` response, or unavailable destination must not stop the complete WF98 batch.

A successful immediate Webhook response proves only that n8n accepted the request. Destination execution and business completion are verified separately through persisted state and destination execution tests.

## 10. Retained triggers during migration

Existing `Internal Invocation Trigger` nodes are not removed merely because the Webhook path exists.

They may still be used by non-WF98 callers. Removal requires a separate caller inventory proving that no supported workflow depends on the internal sub-workflow entry point.

The temporary dual-trigger state is intentional.

## 11. Verification status as of 2026-07-21

Verified:

- WF98 HTTP Request passed one JSON item to the WF02 production Webhook;
- the WF02 Webhook received one item;
- WF99 received a complete `explicit_internal` payload through its production Webhook;
- WF99 `Validate Internal Invocation` returned one normalized item;
- WF99 routed that item through the `explicit_internal` branch;
- WF98 success and error outputs are connected to `Mark Dispatch Accepted` and `Mark Dispatch Failed` for the inspected dispatch nodes.

Not yet fully verified:

- WF99 `notification_retry` through the Webhook path;
- complete destination execution for WF03, WF04, WF05, and WF06 through their Webhook paths;
- complete business implementation of WF02 after payload validation;
- replacement of the checked-in WF98 and WF99 workflow JSON exports with fresh exports from the edited n8n instance;
- removal of any obsolete trigger after a complete caller inventory.

Unverified items must not be described as passed.

## 12. Repository synchronization rule

The checked-in workflow JSON must be generated by exporting the actual edited workflow from n8n.

Do not hand-reconstruct production workflow exports from screenshots because node IDs, credential references, positions, settings, and connection metadata may be incomplete.

Required repository follow-up:

```text
1. Export the current WF98 JSON from n8n.
2. Export the current WF99 JSON from n8n.
3. Replace:
   n8n/workflows/WF98-retry-dispatcher.json
   n8n/workflows/WF99-central-error-handler.json
4. Validate both JSON files.
5. Review the diff for secrets and credential values.
6. Commit the exports separately from unverified WF02-WF06 business implementation work.
```

## 13. Superseded contract language

Where existing WF98 documentation states that asynchronous dispatch is implemented by disabling `Wait for Sub-Workflow Completion`, that implementation detail is superseded by this amendment.

The invariant remains unchanged: WF98 dispatch is asynchronous and does not wait for destination business completion.

The new transport that satisfies that invariant is authenticated internal HTTP POST to an immediate-response production Webhook.
