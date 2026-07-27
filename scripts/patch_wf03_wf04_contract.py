#!/usr/bin/env python3

import json
from pathlib import Path

WORKFLOW_PATH = Path(
    "n8n/workflows/WF03-receive-and-validate-client-data.json"
)

BUILD_REQUEST_CODE = r'''const input = $json ?? {};

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function requireUuid(value, fieldName) {
  if (typeof value !== 'string') {
    throw new Error(
      `${fieldName} must be a UUID string`,
    );
  }

  const normalized =
    value.trim().toLowerCase();

  if (!UUID_PATTERN.test(normalized)) {
    throw new Error(
      `${fieldName} must be a valid UUID`,
    );
  }

  return normalized;
}

function requireInvocationMode(value) {
  if (
    value !== 'form_submission' &&
    value !== 'recovery'
  ) {
    throw new Error(
      'invocation_mode must be form_submission or recovery',
    );
  }

  return value;
}

if (
  input.finalization_decision !==
  'validation_passed_finalized'
) {
  throw new Error(
    'WF04 approval request requires successful WF03 validation',
  );
}

if (
  input.final_case_state !==
  'awaiting_approval'
) {
  throw new Error(
    'WF04 approval request requires awaiting_approval case state',
  );
}

return {
  json: {
    workflow:
      'WF03',

    invocation_mode:
      requireInvocationMode(
        input.invocation_mode,
      ),

    continuation_kind:
      'approval_dispatch',

    case_id:
      requireUuid(
        input.case_id,
        'case_id',
      ),

    correlation_id:
      requireUuid(
        input.correlation_id,
        'correlation_id',
      ),

    accepted_submission_id:
      requireUuid(
        input.final_accepted_submission_id ??
        input.accepted_submission_id,
        'accepted_submission_id',
      ),

    client_id:
      requireUuid(
        input.final_client_id ??
        input.client_id,
        'client_id',
      ),

    trigger_source:
      'wf03',
  },
};'''

BUILD_DISPATCH_CODE = r'''const input = $json ?? {};

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function requireUuid(value, fieldName) {
  if (typeof value !== 'string') {
    throw new Error(
      `${fieldName} must be a UUID string`,
    );
  }

  const normalized =
    value.trim().toLowerCase();

  if (!UUID_PATTERN.test(normalized)) {
    throw new Error(
      `${fieldName} must be a valid UUID`,
    );
  }

  return normalized;
}

if (input.trigger_source !== 'wf03') {
  throw new Error(
    'trigger_source must equal wf03',
  );
}

return {
  json: {
    case_id:
      requireUuid(
        input.case_id,
        'case_id',
      ),

    correlation_id:
      requireUuid(
        input.correlation_id,
        'correlation_id',
      ),

    accepted_submission_id:
      requireUuid(
        input.accepted_submission_id,
        'accepted_submission_id',
      ),

    client_id:
      requireUuid(
        input.client_id,
        'client_id',
      ),

    trigger_source:
      'wf03',
  },
};'''


def main() -> None:
    workflow = json.loads(
        WORKFLOW_PATH.read_text(encoding="utf-8")
    )

    nodes = workflow.get("nodes")
    if not isinstance(nodes, list):
        raise SystemExit("WF03 nodes must be a list")

    targets = {
        "Build WF04 Approval Request": BUILD_REQUEST_CODE,
        "Build WF04 Approval Dispatch Input": BUILD_DISPATCH_CODE,
    }

    found = set()

    for node in nodes:
        name = node.get("name")
        if name not in targets:
            continue

        if node.get("type") != "n8n-nodes-base.code":
            raise SystemExit(
                f"{name} must remain a Code node"
            )

        node.setdefault("parameters", {})["mode"] = (
            "runOnceForEachItem"
        )
        node["parameters"]["jsCode"] = targets[name]
        found.add(name)

    missing = set(targets) - found
    if missing:
        raise SystemExit(
            "Missing WF03 nodes: "
            + ", ".join(sorted(missing))
        )

    WORKFLOW_PATH.write_text(
        json.dumps(
            workflow,
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    print(
        "PASS: WF03 -> WF04 authoritative identity contract patched"
    )


if __name__ == "__main__":
    main()
