#!/usr/bin/env bash
set -euo pipefail

WORKFLOW_ID="${WF02_WORKFLOW_ID:-l2oJE1KtPg4QuE89}"
RETURN_NODE_NAME="Return WF02 Result"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

EXPORT_IN_CONTAINER="/tmp/wf02-current.json"
PATCHED_IN_CONTAINER="/tmp/wf02-patched.json"
EXPORT_ON_HOST="$TMP_DIR/wf02-current.json"
PATCHED_ON_HOST="$TMP_DIR/wf02-patched.json"
BACKUP_DIR="tmp/n8n-workflow-backups"
BACKUP_PATH="$BACKUP_DIR/WF02-${WORKFLOW_ID}-$(date +%Y%m%d-%H%M%S).json"

mkdir -p "$BACKUP_DIR"

echo "[1/7] Exporting current WF02 from n8n..."
docker compose exec -T n8n-main \
  n8n export:workflow \
  --id="$WORKFLOW_ID" \
  --output="$EXPORT_IN_CONTAINER"

docker compose cp \
  "n8n-main:$EXPORT_IN_CONTAINER" \
  "$EXPORT_ON_HOST"

cp "$EXPORT_ON_HOST" "$BACKUP_PATH"
echo "Backup: $BACKUP_PATH"

echo "[2/7] Repairing the exported workflow..."
python3 - "$EXPORT_ON_HOST" "$PATCHED_ON_HOST" <<'PY'
from __future__ import annotations

import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])

RETURN_NODE_NAME = "Return WF02 Result"
RETURN_NODE_ID = "24e6f463-936c-4f0a-a6fe-8c3fddc4df70"

TERMINAL_RESULT_NODES = [
    "Build Not Required Result",
    "Build Already Delivered Result",
    "Build Non-Send Claim Result",
    "Build Lease Lost Result",
    "Build Existing Terminal Operation Result",
    "Build Retryable Delivery Result",
    "Return Terminal Delivery Result",
]

RETURN_CODE = """const input = $json ?? {};

if (input.workflow !== 'WF02') {
  throw new Error(
    'WF02 return boundary requires workflow equal to WF02',
  );
}

if (
  typeof input.result !== 'string' ||
  input.result.trim() === ''
) {
  throw new Error(
    'WF02 return boundary requires a non-empty result',
  );
}

return {
  json: {
    ...input,
    result: input.result.trim(),
  },
};
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
missing = [name for name in TERMINAL_RESULT_NODES if name not in node_by_name]

if missing:
    raise SystemExit("Missing terminal nodes: " + ", ".join(missing))

return_node = node_by_name.get(RETURN_NODE_NAME)

if return_node is None:
    positions = [
        node_by_name[name].get("position", [0, 0])
        for name in TERMINAL_RESULT_NODES
    ]
    return_x = max(position[0] for position in positions) + 400
    return_y = round(
        sum(position[1] for position in positions) / len(positions)
    )

    return_node = {
        "parameters": {},
        "type": "n8n-nodes-base.code",
        "typeVersion": 2,
        "position": [return_x, return_y],
        "id": RETURN_NODE_ID,
        "name": RETURN_NODE_NAME,
    }
    nodes.append(return_node)

return_node["parameters"] = {
    "mode": "runOnceForEachItem",
    "jsCode": RETURN_CODE,
}

for node_name in TERMINAL_RESULT_NODES:
    connections[node_name] = {
        "main": [
            [
                {
                    "node": RETURN_NODE_NAME,
                    "type": "main",
                    "index": 0,
                }
            ]
        ]
    }

output = wrapper if wrapper is not None else workflow
target.write_text(
    json.dumps(output, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)

print(f"workflow_id={workflow.get('id')}")
print(f"active_before_import={workflow.get('active')}")
print(f"nodes={len(nodes)}")
print(f"return_node={RETURN_NODE_NAME}")
print(f"connected_terminal_nodes={len(TERMINAL_RESULT_NODES)}")
PY

echo "[3/7] Copying the repaired workflow into n8n..."
docker compose cp \
  "$PATCHED_ON_HOST" \
  "n8n-main:$PATCHED_IN_CONTAINER"

echo "[4/7] Importing the repaired workflow..."
docker compose exec -T n8n-main \
  n8n import:workflow \
  --input="$PATCHED_IN_CONTAINER"

echo "[5/7] Publishing WF02..."
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
  --output=/tmp/wf02-verify.json

docker compose cp \
  n8n-main:/tmp/wf02-verify.json \
  "$TMP_DIR/wf02-verify.json" \
  >/dev/null

python3 - "$TMP_DIR/wf02-verify.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
workflow = payload[0] if isinstance(payload, list) else payload

nodes = workflow.get("nodes", [])
connections = workflow.get("connections", {})
return_nodes = [
    node
    for node in nodes
    if node.get("name") == "Return WF02 Result"
]

if len(return_nodes) != 1:
    raise SystemExit(
        f"FAIL: expected one Return WF02 Result node, found {len(return_nodes)}"
    )

return_node = return_nodes[0]
parameters = return_node.get("parameters", {})
js_code = parameters.get("jsCode", "")

if parameters.get("mode") != "runOnceForEachItem":
    raise SystemExit("FAIL: Return WF02 Result has the wrong execution mode")

if "$input.all()" in js_code:
    raise SystemExit("FAIL: Return WF02 Result still uses $input.all()")

if "const input = $json ?? {};" not in js_code:
    raise SystemExit("FAIL: Return WF02 Result does not use the per-item input")

expected_sources = {
    "Build Not Required Result",
    "Build Already Delivered Result",
    "Build Non-Send Claim Result",
    "Build Lease Lost Result",
    "Build Existing Terminal Operation Result",
    "Build Retryable Delivery Result",
    "Return Terminal Delivery Result",
}

for source in expected_sources:
    targets = connections.get(source, {}).get("main", [[]])
    flattened = [item for branch in targets for item in branch]
    if not any(item.get("node") == "Return WF02 Result" for item in flattened):
        raise SystemExit(f"FAIL: missing return connection from {source}")

if workflow.get("active") is not True:
    raise SystemExit("FAIL: WF02 is not active after deployment")

print("PASS: WF02 return boundary repaired and published")
print(f"workflow_id={workflow.get('id')}")
print(f"active={workflow.get('active')}")
print(f"nodes={len(nodes)}")
PY
