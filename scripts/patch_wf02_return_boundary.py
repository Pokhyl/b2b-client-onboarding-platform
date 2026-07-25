#!/usr/bin/env python3
"""Add a single explicit return boundary to WF02.

The script is idempotent and fails closed when the workflow shape differs from
what the current implementation expects.
"""

from __future__ import annotations

import json
from pathlib import Path

WORKFLOW_PATH = Path("n8n/workflows/WF02-request-client-data.json")
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

RETURN_CODE = """const items = $input.all();

if (items.length !== 1) {
  throw new Error(
    `WF02 return boundary expected exactly one item, received ${items.length}`,
  );
}

const input = items[0].json ?? {};

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


def main() -> None:
    workflow = json.loads(WORKFLOW_PATH.read_text(encoding="utf-8"))
    nodes = workflow.get("nodes", [])
    connections = workflow.setdefault("connections", {})

    node_by_name = {node.get("name"): node for node in nodes}

    if RETURN_NODE_NAME in node_by_name:
        print(f"Already present: {RETURN_NODE_NAME}")
        return

    missing = [name for name in TERMINAL_RESULT_NODES if name not in node_by_name]
    if missing:
        raise SystemExit("Missing terminal nodes: " + ", ".join(missing))

    for node_name in TERMINAL_RESULT_NODES:
        node_connections = connections.get(node_name, {})
        for connection_type, branches in node_connections.items():
            if any(branch for branch in branches):
                raise SystemExit(
                    f"{node_name} already has an outgoing {connection_type} connection"
                )

    positions = [node_by_name[name].get("position", [0, 0]) for name in TERMINAL_RESULT_NODES]
    return_x = max(position[0] for position in positions) + 400
    return_y = round(sum(position[1] for position in positions) / len(positions))

    nodes.append(
        {
            "parameters": {
                "mode": "runOnceForEachItem",
                "jsCode": RETURN_CODE,
            },
            "type": "n8n-nodes-base.code",
            "typeVersion": 2,
            "position": [return_x, return_y],
            "id": RETURN_NODE_ID,
            "name": RETURN_NODE_NAME,
        }
    )

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

    WORKFLOW_PATH.write_text(
        json.dumps(workflow, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    print(f"Updated: {WORKFLOW_PATH}")
    print(f"Added: {RETURN_NODE_NAME}")
    print(f"Connected terminal nodes: {len(TERMINAL_RESULT_NODES)}")


if __name__ == "__main__":
    main()
