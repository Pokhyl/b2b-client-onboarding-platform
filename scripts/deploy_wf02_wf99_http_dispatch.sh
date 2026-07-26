#!/usr/bin/env bash
set -euo pipefail

WF02_ID="${WF02_WORKFLOW_ID:-l2oJE1KtPg4QuE89}"
WF98_ID="${WF98_WORKFLOW_ID:-o5coDcd0qjFSgjA5}"
WF99_ID="${WF99_WORKFLOW_ID:-WykBM7mvCOqph91a}"
WORKFLOW_REPO_PATH="n8n/workflows/WF02-request-client-data.json"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

WF02_CONTAINER="/tmp/wf02-wf99-current.json"
WF98_CONTAINER="/tmp/wf98-wf99-template.json"
WF99_CONTAINER="/tmp/wf99-webhook-contract.json"
PATCHED_CONTAINER="/tmp/wf02-wf99-patched.json"

WF02_HOST="$TMP_DIR/wf02-current.json"
WF98_HOST="$TMP_DIR/wf98-template.json"
WF99_HOST="$TMP_DIR/wf99-contract.json"
PATCHED_HOST="$TMP_DIR/wf02-patched.json"
VERIFY_HOST="$TMP_DIR/wf02-verify.json"

BACKUP_DIR="tmp/n8n-workflow-backups"
BACKUP_PATH="$BACKUP_DIR/WF02-${WF02_ID}-$(date +%Y%m%d-%H%M%S).json"
mkdir -p "$BACKUP_DIR"

echo "[1/7] Exporting live WF02, WF98, and WF99..."
docker compose exec -T n8n-main \
  n8n export:workflow \
  --id="$WF02_ID" \
  --output="$WF02_CONTAINER"

docker compose exec -T n8n-main \
  n8n export:workflow \
  --id="$WF98_ID" \
  --output="$WF98_CONTAINER"

docker compose exec -T n8n-main \
  n8n export:workflow \
  --id="$WF99_ID" \
  --output="$WF99_CONTAINER"

docker compose cp \
  "n8n-main:$WF02_CONTAINER" \
  "$WF02_HOST" \
  >/dev/null

docker compose cp \
  "n8n-main:$WF98_CONTAINER" \
  "$WF98_HOST" \
  >/dev/null

docker compose cp \
  "n8n-main:$WF99_CONTAINER" \
  "$WF99_HOST" \
  >/dev/null

cp "$WF02_HOST" "$BACKUP_PATH"
echo "Backup: $BACKUP_PATH"

echo "[2/7] Applying the verified WF99 HTTP dispatch contract..."
python3 - \
  "$WF02_HOST" \
  "$WF98_HOST" \
  "$WF99_HOST" \
  "$PATCHED_HOST" \
  "$WORKFLOW_REPO_PATH" <<'PY'
from __future__ import annotations

import json
import sys
from copy import deepcopy
from pathlib import Path

wf02_source = Path(sys.argv[1])
wf98_source = Path(sys.argv[2])
wf99_source = Path(sys.argv[3])
patched_target = Path(sys.argv[4])
repo_target = Path(sys.argv[5])

WF99_PATH = "internal/wf99-retry-dispatch"
WF99_URL = "http://n8n-main:5678/webhook/internal/wf99-retry-dispatch"
TEMPLATE_NODE = "Dispatch WF99"
INTERVENTION_NODES = (
    "Handle WF02 Failure in WF99",
    "Notify WF99 Terminal Delivery Failure",
)
TERMINAL_NOTIFY_NODE = "Notify WF99 Terminal Delivery Failure"
TERMINAL_MERGE_NODE = "Merge Terminal Failure Notification"
AMBIGUITY_SWITCH_NODE = "Route Reconciliation Ambiguity Finalization"
AMBIGUITY_ERROR_NODE = "Build Reconciliation Ambiguity Error"


def load_export(path: Path) -> tuple[dict, list | None]:
    payload = json.loads(path.read_text(encoding="utf-8"))

    if isinstance(payload, list):
        if len(payload) != 1:
            raise SystemExit(
                f"Expected one workflow in {path}, received {len(payload)}"
            )
        return payload[0], payload

    if isinstance(payload, dict):
        return payload, None

    raise SystemExit(f"Unsupported n8n export structure in {path}")


def connection(node: str, index: int) -> dict:
    return {
        "node": node,
        "type": "main",
        "index": index,
    }


wf02, wf02_wrapper = load_export(wf02_source)
wf98, _ = load_export(wf98_source)
wf99, _ = load_export(wf99_source)

wf02_nodes = wf02.get("nodes")
wf02_connections = wf02.get("connections")
wf98_nodes = wf98.get("nodes")
wf99_nodes = wf99.get("nodes")

if not isinstance(wf02_nodes, list) or not isinstance(wf02_connections, dict):
    raise SystemExit("WF02 export does not contain valid nodes/connections")

if not isinstance(wf98_nodes, list) or not isinstance(wf99_nodes, list):
    raise SystemExit("WF98 or WF99 export does not contain a valid node list")

wf02_by_name = {node.get("name"): node for node in wf02_nodes}
wf98_by_name = {node.get("name"): node for node in wf98_nodes}

missing = [name for name in INTERVENTION_NODES if name not in wf02_by_name]
if missing:
    raise SystemExit("Missing WF02 intervention nodes: " + ", ".join(missing))

for required_name in (
    TERMINAL_MERGE_NODE,
    AMBIGUITY_SWITCH_NODE,
    AMBIGUITY_ERROR_NODE,
):
    if required_name not in wf02_by_name:
        raise SystemExit(f"Missing required WF02 node: {required_name}")

template = wf98_by_name.get(TEMPLATE_NODE)
if template is None:
    raise SystemExit(f"WF98 template node not found: {TEMPLATE_NODE}")

template_parameters = template.get("parameters", {})
template_credentials = template.get("credentials", {})

expected_template_parameters = {
    "method": "POST",
    "url": WF99_URL,
    "authentication": "genericCredentialType",
    "genericAuthType": "httpHeaderAuth",
    "sendBody": True,
    "specifyBody": "json",
    "jsonBody": "={{ $json }}",
    "options": {},
}

if template.get("type") != "n8n-nodes-base.httpRequest":
    raise SystemExit("WF98 Dispatch WF99 is not an HTTP Request node")

if template_parameters != expected_template_parameters:
    raise SystemExit("WF98 Dispatch WF99 parameters do not match the verified contract")

header_credential = template_credentials.get("httpHeaderAuth")
if not isinstance(header_credential, dict):
    raise SystemExit("WF98 Dispatch WF99 is missing the Header Auth credential")

webhooks = [
    node
    for node in wf99_nodes
    if node.get("type") == "n8n-nodes-base.webhook"
    and node.get("parameters", {}).get("path") == WF99_PATH
]

if len(webhooks) != 1:
    raise SystemExit(
        f"Expected one WF99 webhook at {WF99_PATH}, received {len(webhooks)}"
    )

webhook = webhooks[0]
webhook_parameters = webhook.get("parameters", {})
webhook_credentials = webhook.get("credentials", {}).get("httpHeaderAuth")

if webhook_parameters.get("httpMethod") != "POST":
    raise SystemExit("WF99 internal webhook must use POST")

if webhook_parameters.get("authentication") != "headerAuth":
    raise SystemExit("WF99 internal webhook must use Header Auth")

if webhook_credentials != header_credential:
    raise SystemExit("WF98 dispatch and WF99 webhook use different credentials")

for node_name in INTERVENTION_NODES:
    node = wf02_by_name[node_name]

    node["parameters"] = deepcopy(template_parameters)
    node["type"] = template["type"]
    node["typeVersion"] = template.get("typeVersion", 4.2)
    node["credentials"] = deepcopy(template_credentials)
    node["alwaysOutputData"] = True
    node["onError"] = "continueErrorOutput"

    for incompatible_key in (
        "webhookId",
        "retryOnFail",
        "maxTries",
        "waitBetweenTries",
    ):
        node.pop(incompatible_key, None)

# The terminal result must be returned whether WF99 accepted the notification
# or the HTTP dispatch itself failed. Both HTTP Request outputs therefore join
# the same merge input.
terminal_target = connection(TERMINAL_MERGE_NODE, 1)
wf02_connections[TERMINAL_NOTIFY_NODE] = {
    "main": [
        [deepcopy(terminal_target)],
        [deepcopy(terminal_target)],
    ]
}

# Preserve a visible terminal shape for the generic intervention dispatcher.
# It intentionally has no downstream business continuation, but both success
# and error outputs are explicit so a rejected WF99 request does not throw.
generic_connections = wf02_connections.get(INTERVENTION_NODES[0], {})
generic_main = generic_connections.get("main")

if not isinstance(generic_main, list):
    generic_main = []

while len(generic_main) < 2:
    generic_main.append([])

wf02_connections[INTERVENTION_NODES[0]] = {
    "main": generic_main[:2],
}

# The Switch has four named rules and one fallback output. Unknown values must
# enter the sanitized WF99 error builder instead of disappearing silently.
ambiguity_routes = wf02_connections.setdefault(
    AMBIGUITY_SWITCH_NODE,
    {},
).setdefault("main", [])

while len(ambiguity_routes) < 5:
    ambiguity_routes.append([])

ambiguity_routes[4] = [connection(AMBIGUITY_ERROR_NODE, 0)]

output = wf02_wrapper if wf02_wrapper is not None else wf02
patched_target.write_text(
    json.dumps(output, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
repo_target.write_text(
    json.dumps(wf02, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)

print(f"workflow_id={wf02.get('id')}")
print(f"active_before_import={wf02.get('active')}")
print("patched_nodes=" + ", ".join(INTERVENTION_NODES))
print(f"credential_id={header_credential.get('id')}")
print(f"credential_name={header_credential.get('name')}")
print(f"repo_file={repo_target}")
PY

echo "[3/7] Copying patched WF02 into n8n..."
docker compose cp \
  "$PATCHED_HOST" \
  "n8n-main:$PATCHED_CONTAINER" \
  >/dev/null

echo "[4/7] Importing patched WF02..."
docker compose exec -T n8n-main \
  n8n import:workflow \
  --input="$PATCHED_CONTAINER"

echo "[5/7] Publishing WF02..."
docker compose exec -T n8n-main \
  n8n publish:workflow \
  --id="$WF02_ID"

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

echo "[7/7] Verifying deployed WF02..."
docker compose exec -T n8n-main \
  n8n export:workflow \
  --id="$WF02_ID" \
  --output=/tmp/wf02-wf99-verify.json

docker compose cp \
  n8n-main:/tmp/wf02-wf99-verify.json \
  "$VERIFY_HOST" \
  >/dev/null

python3 - "$VERIFY_HOST" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
workflow = payload[0] if isinstance(payload, list) else payload
nodes = workflow.get("nodes", [])
connections = workflow.get("connections", {})
node_by_name = {node.get("name"): node for node in nodes}

expected_url = "http://n8n-main:5678/webhook/internal/wf99-retry-dispatch"
expected_nodes = (
    "Handle WF02 Failure in WF99",
    "Notify WF99 Terminal Delivery Failure",
)

for node_name in expected_nodes:
    node = node_by_name.get(node_name)
    if node is None:
        raise SystemExit(f"FAIL: missing {node_name}")

    parameters = node.get("parameters", {})
    credential = node.get("credentials", {}).get("httpHeaderAuth", {})

    if node.get("type") != "n8n-nodes-base.httpRequest":
        raise SystemExit(f"FAIL: {node_name} is not HTTP Request")

    if parameters.get("method") != "POST":
        raise SystemExit(f"FAIL: {node_name} does not use POST")

    if parameters.get("url") != expected_url:
        raise SystemExit(f"FAIL: {node_name} has an unexpected URL")

    if parameters.get("authentication") != "genericCredentialType":
        raise SystemExit(f"FAIL: {node_name} authentication is invalid")

    if parameters.get("genericAuthType") != "httpHeaderAuth":
        raise SystemExit(f"FAIL: {node_name} generic auth type is invalid")

    if parameters.get("jsonBody") != "={{ $json }}":
        raise SystemExit(f"FAIL: {node_name} JSON body is invalid")

    if credential.get("id") != "vRGUhlaMi4SARvdN":
        raise SystemExit(f"FAIL: {node_name} credential ID is invalid")

    if node.get("onError") != "continueErrorOutput":
        raise SystemExit(f"FAIL: {node_name} does not continue through error output")

terminal_routes = connections.get(
    "Notify WF99 Terminal Delivery Failure",
    {},
).get("main", [])

if len(terminal_routes) < 2:
    raise SystemExit("FAIL: terminal WF99 dispatch does not expose two outputs")

for branch_index in (0, 1):
    branch = terminal_routes[branch_index]
    if not any(
        item.get("node") == "Merge Terminal Failure Notification"
        and item.get("index") == 1
        for item in branch
    ):
        raise SystemExit(
            f"FAIL: terminal WF99 output {branch_index} does not return to the result merge"
        )

ambiguity_routes = connections.get(
    "Route Reconciliation Ambiguity Finalization",
    {},
).get("main", [])

if len(ambiguity_routes) < 5 or not any(
    item.get("node") == "Build Reconciliation Ambiguity Error"
    for item in ambiguity_routes[4]
):
    raise SystemExit("FAIL: reconciliation ambiguity fallback is not connected")

if workflow.get("active") is not True:
    raise SystemExit("FAIL: WF02 is not active after deployment")

print("PASS: WF02 intervention dispatches use the protected WF99 webhook")
print(f"workflow_id={workflow.get('id')}")
print(f"active={workflow.get('active')}")
print(f"nodes={len(nodes)}")
PY

git diff --check -- "$WORKFLOW_REPO_PATH"
