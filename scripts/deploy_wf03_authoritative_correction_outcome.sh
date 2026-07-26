#!/usr/bin/env bash
set -euo pipefail

WORKFLOW_ID="${WF03_WORKFLOW_ID:-CVHTFKM97aBHhmXf}"
WORKFLOW_REPO_PATH="n8n/workflows/WF03-receive-and-validate-client-data.json"
AUTHORITATIVE_NODE_NAME="Load Authoritative WF02 Correction Outcome"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

EXPORT_IN_CONTAINER="/tmp/wf03-current.json"
PATCHED_IN_CONTAINER="/tmp/wf03-patched.json"
EXPORT_ON_HOST="$TMP_DIR/wf03-current.json"
PATCHED_ON_HOST="$TMP_DIR/wf03-patched.json"
BACKUP_DIR="tmp/n8n-workflow-backups"
BACKUP_PATH="$BACKUP_DIR/WF03-${WORKFLOW_ID}-$(date +%Y%m%d-%H%M%S).json"

mkdir -p "$BACKUP_DIR"

echo "[1/7] Exporting current WF03 from n8n..."
docker compose exec -T n8n-main \
  n8n export:workflow \
  --id="$WORKFLOW_ID" \
  --output="$EXPORT_IN_CONTAINER"

docker compose cp \
  "n8n-main:$EXPORT_IN_CONTAINER" \
  "$EXPORT_ON_HOST"

cp "$EXPORT_ON_HOST" "$BACKUP_PATH"
echo "Backup: $BACKUP_PATH"

echo "[2/7] Adding authoritative correction-outcome reconciliation..."
python3 - \
  "$EXPORT_ON_HOST" \
  "$PATCHED_ON_HOST" \
  "$WORKFLOW_REPO_PATH" <<'PY'
from __future__ import annotations

import json
import sys
from copy import deepcopy
from pathlib import Path

source = Path(sys.argv[1])
patched_target = Path(sys.argv[2])
repo_target = Path(sys.argv[3])

AUTHORITATIVE_NODE_NAME = "Load Authoritative WF02 Correction Outcome"
AUTHORITATIVE_NODE_ID = "f0b37dd6-f2e9-44f0-b91c-a978cf1e8d33"
MERGE_NODE_NAME = "Merge WF02 Correction Context"
NORMALIZE_NODE_NAME = "Normalize WF02 Correction Result"
POSTGRES_TEMPLATE_NODE_NAME = "Load Authoritative Submission Context"

QUERY = """SELECT
    $3::jsonb AS input_context,

    onboarding_case.id AS case_id,
    onboarding_case.correlation_id,
    onboarding_case.state AS case_state,

    correction_token.id AS token_id,
    correction_token.request_cycle_key,
    correction_token.status AS token_status,
    correction_token.expires_at AS token_expires_at,

    correction_operation.id AS external_operation_id,
    correction_operation.status AS operation_status,
    correction_operation.attempt_count,
    correction_operation.max_attempts,
    correction_operation.next_retry_at,
    correction_operation.external_id,
    correction_operation.last_error_class,
    correction_operation.last_error_summary

FROM onboarding_cases AS onboarding_case

LEFT JOIN LATERAL (
    SELECT token.*
    FROM onboarding_form_tokens AS token
    WHERE token.case_id = onboarding_case.id
      AND token.request_cycle_key = $2::text
    ORDER BY token.issued_at DESC
    LIMIT 1
) AS correction_token ON true

LEFT JOIN LATERAL (
    SELECT operation.*
    FROM external_operations AS operation
    WHERE operation.case_id = onboarding_case.id
      AND operation.operation_type = 'send_client_data_request'
      AND operation.request_summary ->> 'request_cycle_key' = $2::text
    ORDER BY operation.created_at DESC
    LIMIT 1
) AS correction_operation ON true

WHERE onboarding_case.id = $1::uuid;
"""

QUERY_REPLACEMENT = """={{
[
  $json.case_id,
  $json.request_cycle_key,
  JSON.stringify($json)
]
}}"""

NORMALIZE_CODE = """const row = $json ?? {};

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function isUuid(value) {
  return (
    typeof value === 'string' &&
    UUID_PATTERN.test(value.trim())
  );
}

function isPlainObject(value) {
  return (
    value !== null &&
    typeof value === 'object' &&
    !Array.isArray(value)
  );
}

function normalizeInvocationMode(value) {
  if (
    value === 'form_submission' ||
    value === 'recovery'
  ) {
    return value;
  }

  return null;
}

const context =
  isPlainObject(row.input_context)
    ? row.input_context
    : {};

const invocationMode =
  normalizeInvocationMode(
    context.invocation_mode,
  );

function invalidResult(errorCode) {
  return {
    json: {
      source_workflow:
        'WF03',

      invocation_mode:
        invocationMode,

      continuation_kind:
        'correction_dispatch',

      correction_decision:
        'invalid_result',

      error_code:
        errorCode,

      case_id:
        isUuid(context.case_id)
          ? context.case_id
          : null,

      correlation_id:
        isUuid(context.correlation_id)
          ? context.correlation_id
          : null,

      submission_id:
        isUuid(
          context.failed_submission_id,
        )
          ? context.failed_submission_id
          : null,

      wf02_result:
        typeof context.result === 'string'
          ? context.result
          : null,

      external_operation_id:
        isUuid(row.external_operation_id)
          ? row.external_operation_id
          : null,

      client_response_key:
        'technical_failure',
    },
  };
}

if (invocationMode === null) {
  return invalidResult(
    'correction_invocation_mode_invalid',
  );
}

const caseId =
  isUuid(context.case_id)
    ? context.case_id
        .trim()
        .toLowerCase()
    : null;

const correlationId =
  isUuid(context.correlation_id)
    ? context.correlation_id
        .trim()
        .toLowerCase()
    : null;

const submissionId =
  isUuid(context.failed_submission_id)
    ? context.failed_submission_id
        .trim()
        .toLowerCase()
    : null;

if (
  caseId === null ||
  correlationId === null ||
  submissionId === null
) {
  return invalidResult(
    'correction_identity_missing',
  );
}

const expectedCycle =
  `validation_failed:${submissionId}`;

if (
  context.request_cycle_key !==
  expectedCycle
) {
  return invalidResult(
    'correction_cycle_mismatch',
  );
}

if (
  !isUuid(row.case_id) ||
  row.case_id.toLowerCase() !== caseId ||
  !isUuid(row.correlation_id) ||
  row.correlation_id.toLowerCase() !==
    correlationId ||
  row.request_cycle_key !== expectedCycle
) {
  return invalidResult(
    'authoritative_correction_identity_mismatch',
  );
}

const operationStatus =
  typeof row.operation_status === 'string'
    ? row.operation_status.trim()
    : '';

const tokenStatus =
  typeof row.token_status === 'string'
    ? row.token_status.trim()
    : '';

const caseState =
  typeof row.case_state === 'string'
    ? row.case_state.trim()
    : '';

const childResult =
  typeof context.result === 'string'
    ? context.result.trim()
    : '';

if (
  operationStatus === 'succeeded' &&
  tokenStatus === 'delivered' &&
  caseState === 'awaiting_client_data'
) {
  const result =
    childResult === 'already_delivered'
      ? 'already_delivered'
      : 'delivered';

  return {
    json: {
      workflow:
        'WF03',

      invocation_mode:
        invocationMode,

      continuation_kind:
        'correction_dispatch',

      correction_decision:
        'correction_ready',

      case_id:
        caseId,

      correlation_id:
        correlationId,

      submission_id:
        submissionId,

      request_cycle_key:
        expectedCycle,

      wf02_result:
        result,

      external_operation_id:
        isUuid(row.external_operation_id)
          ? row.external_operation_id
          : null,
    },
  };
}

if (
  operationStatus === 'failed_retryable' ||
  operationStatus === 'leased' ||
  operationStatus === 'pending'
) {
  const result =
    operationStatus === 'failed_retryable'
      ? 'failed_retryable'
      : 'busy';

  return {
    json: {
      workflow:
        'WF03',

      invocation_mode:
        invocationMode,

      continuation_kind:
        'correction_dispatch',

      correction_decision:
        'correction_scheduled',

      case_id:
        caseId,

      correlation_id:
        correlationId,

      submission_id:
        submissionId,

      request_cycle_key:
        expectedCycle,

      wf02_result:
        result,

      external_operation_id:
        isUuid(row.external_operation_id)
          ? row.external_operation_id
          : null,

      next_retry_at:
        typeof row.next_retry_at === 'string'
          ? row.next_retry_at
          : null,
    },
  };
}

if (operationStatus === 'failed_terminal') {
  return {
    json: {
      source_workflow:
        'WF03',

      invocation_mode:
        invocationMode,

      continuation_kind:
        'correction_dispatch',

      correction_decision:
        'terminal_failure',

      error_code:
        'wf02_correction_terminal_failure',

      case_id:
        caseId,

      correlation_id:
        correlationId,

      submission_id:
        submissionId,

      wf02_result:
        'failed_terminal',

      external_operation_id:
        isUuid(row.external_operation_id)
          ? row.external_operation_id
          : null,

      client_response_key:
        'technical_failure',
    },
  };
}

return invalidResult(
  'authoritative_wf02_correction_outcome_invalid',
);
"""

payload = json.loads(source.read_text(encoding="utf-8"))

if isinstance(payload, list):
    if len(payload) != 1:
        raise SystemExit(
            f"Expected one exported workflow, received {len(payload)}"
        )
    workflow = payload[0]
    wrapper = payload
elif isinstance(payload, dict):
    workflow = payload
    wrapper = None
else:
    raise SystemExit("Unsupported n8n export structure")

nodes = workflow.get("nodes")
connections = workflow.get("connections")

if not isinstance(nodes, list) or not isinstance(connections, dict):
    raise SystemExit("Export does not contain valid nodes/connections")

node_by_name = {node.get("name"): node for node in nodes}
required = [
    MERGE_NODE_NAME,
    NORMALIZE_NODE_NAME,
    POSTGRES_TEMPLATE_NODE_NAME,
]
missing = [name for name in required if name not in node_by_name]

if missing:
    raise SystemExit("Missing required WF03 nodes: " + ", ".join(missing))

postgres_template = node_by_name[POSTGRES_TEMPLATE_NODE_NAME]
postgres_credentials = deepcopy(postgres_template.get("credentials", {}))

if "postgres" not in postgres_credentials:
    raise SystemExit("PostgreSQL credential is missing from WF03 template node")

merge_node = node_by_name[MERGE_NODE_NAME]
normalize_node = node_by_name[NORMALIZE_NODE_NAME]

authoritative_node = node_by_name.get(AUTHORITATIVE_NODE_NAME)

if authoritative_node is None:
    merge_position = merge_node.get("position", [2256, -640])
    normalize_position = normalize_node.get("position", [2496, -672])

    authoritative_node = {
        "parameters": {},
        "type": "n8n-nodes-base.postgres",
        "typeVersion": 2.6,
        "position": [
            round((merge_position[0] + normalize_position[0]) / 2),
            round((merge_position[1] + normalize_position[1]) / 2),
        ],
        "id": AUTHORITATIVE_NODE_ID,
        "name": AUTHORITATIVE_NODE_NAME,
        "alwaysOutputData": True,
        "credentials": postgres_credentials,
    }
    nodes.append(authoritative_node)

authoritative_node["parameters"] = {
    "operation": "executeQuery",
    "query": QUERY,
    "options": {
        "queryReplacement": QUERY_REPLACEMENT,
    },
}
authoritative_node["type"] = "n8n-nodes-base.postgres"
authoritative_node["typeVersion"] = 2.6
authoritative_node["alwaysOutputData"] = True
authoritative_node["credentials"] = postgres_credentials

normalize_node["parameters"] = {
    "mode": "runOnceForEachItem",
    "jsCode": NORMALIZE_CODE,
}

connections[MERGE_NODE_NAME] = {
    "main": [
        [
            {
                "node": AUTHORITATIVE_NODE_NAME,
                "type": "main",
                "index": 0,
            }
        ]
    ]
}

connections[AUTHORITATIVE_NODE_NAME] = {
    "main": [
        [
            {
                "node": NORMALIZE_NODE_NAME,
                "type": "main",
                "index": 0,
            }
        ]
    ]
}

output = wrapper if wrapper is not None else workflow
patched_target.write_text(
    json.dumps(output, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)

repo_target.write_text(
    json.dumps(workflow, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)

print(f"workflow_id={workflow.get('id')}")
print(f"active_before_import={workflow.get('active')}")
print(f"nodes={len(nodes)}")
print(f"authoritative_node={AUTHORITATIVE_NODE_NAME}")
print(f"repo_file={repo_target}")
PY

echo "[3/7] Copying the patched workflow into n8n..."
docker compose cp \
  "$PATCHED_ON_HOST" \
  "n8n-main:$PATCHED_IN_CONTAINER"

echo "[4/7] Importing the patched workflow..."
docker compose exec -T n8n-main \
  n8n import:workflow \
  --input="$PATCHED_IN_CONTAINER"

echo "[5/7] Publishing WF03..."
docker compose exec -T n8n-main \
  n8n publish:workflow \
  --id="$WORKFLOW_ID"

echo "[6/7] Restarting n8n processes..."
docker compose restart \
  n8n-main \
  n8n-worker-1 \
  n8n-worker-2

echo "Waiting for n8n readiness..."
for attempt in $(seq 1 30); do
  if docker compose exec -T n8n-main \
      node -e "fetch('http://127.0.0.1:5678/healthz/readiness').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" \
      >/dev/null 2>&1; then
    break
  fi

  if [[ "$attempt" -eq 30 ]]; then
    echo "FAIL: n8n did not become ready" >&2
    exit 20
  fi

  sleep 2
done

echo "[7/7] Verifying the deployed workflow..."
docker compose exec -T n8n-main \
  n8n export:workflow \
  --id="$WORKFLOW_ID" \
  --output=/tmp/wf03-verify.json

docker compose cp \
  n8n-main:/tmp/wf03-verify.json \
  "$TMP_DIR/wf03-verify.json" \
  >/dev/null

python3 - "$TMP_DIR/wf03-verify.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
workflow = payload[0] if isinstance(payload, list) else payload

nodes = workflow.get("nodes", [])
connections = workflow.get("connections", {})
node_by_name = {node.get("name"): node for node in nodes}

node_name = "Load Authoritative WF02 Correction Outcome"
merge_name = "Merge WF02 Correction Context"
normalize_name = "Normalize WF02 Correction Result"

if node_name not in node_by_name:
    raise SystemExit(f"FAIL: missing {node_name}")

node = node_by_name[node_name]
query = node.get("parameters", {}).get("query", "")

if "external_operations" not in query or "onboarding_form_tokens" not in query:
    raise SystemExit("FAIL: authoritative correction query is incomplete")

merge_targets = connections.get(merge_name, {}).get("main", [[]])
merge_flat = [item for branch in merge_targets for item in branch]

if not any(item.get("node") == node_name for item in merge_flat):
    raise SystemExit("FAIL: correction merge does not call authoritative query")

authoritative_targets = connections.get(node_name, {}).get("main", [[]])
authoritative_flat = [item for branch in authoritative_targets for item in branch]

if not any(item.get("node") == normalize_name for item in authoritative_flat):
    raise SystemExit("FAIL: authoritative query does not call correction normalizer")

normalize_code = (
    node_by_name[normalize_name]
    .get("parameters", {})
    .get("jsCode", "")
)

if "authoritative_wf02_correction_outcome_invalid" not in normalize_code:
    raise SystemExit("FAIL: correction normalizer was not replaced")

if workflow.get("active") is not True:
    raise SystemExit("FAIL: WF03 is not active after deployment")

print("PASS: WF03 authoritative correction reconciliation deployed")
print(f"workflow_id={workflow.get('id')}")
print(f"active={workflow.get('active')}")
print(f"nodes={len(nodes)}")
PY

git diff --check -- "$WORKFLOW_REPO_PATH"
