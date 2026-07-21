import fs from 'node:fs';
import path from 'node:path';

const ROOT = process.cwd();
const WF98_PATH = path.join(ROOT, 'n8n/workflows/WF98-retry-dispatcher.json');
const WF99_PATH = path.join(ROOT, 'n8n/workflows/WF99-central-error-handler.json');

const INTERNAL_HEADER_AUTH = {
  httpHeaderAuth: {
    name: 'Header Auth account',
  },
};

const DISPATCH_PATHS = new Map([
  ['Dispatch WF02', 'internal/wf02-retry-dispatch'],
  ['Dispatch WF03', 'internal/wf03-retry-dispatch'],
  ['Dispatch WF04', 'internal/wf04-retry-dispatch'],
  ['Dispatch WF05', 'internal/wf05-retry-dispatch'],
  ['Dispatch WF06', 'internal/wf06-retry-dispatch'],
  ['Dispatch WF99', 'internal/wf99-retry-dispatch'],
]);

function readWorkflow(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function writeWorkflow(filePath, workflow) {
  fs.writeFileSync(filePath, `${JSON.stringify(workflow, null, 2)}\n`);
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function renameNode(workflow, oldName, newName) {
  const node = workflow.nodes.find((entry) => entry.name === oldName);
  if (!node) return;

  assert(
    !workflow.nodes.some((entry) => entry.name === newName),
    `Cannot rename ${oldName}: ${newName} already exists`,
  );

  node.name = newName;

  if (workflow.connections[oldName]) {
    workflow.connections[newName] = workflow.connections[oldName];
    delete workflow.connections[oldName];
  }

  for (const connectionGroup of Object.values(workflow.connections)) {
    for (const outputs of Object.values(connectionGroup ?? {})) {
      for (const output of outputs ?? []) {
        for (const connection of output ?? []) {
          if (connection.node === oldName) {
            connection.node = newName;
          }
        }
      }
    }
  }
}

function migrateWf98(workflow) {
  renameNode(workflow, 'Dispatch WF', 'Dispatch WF06');

  for (const [nodeName, webhookPath] of DISPATCH_PATHS) {
    const node = workflow.nodes.find((entry) => entry.name === nodeName);
    assert(node, `WF98 is missing ${nodeName}`);

    node.parameters = {
      method: 'POST',
      url: `http://n8n-main:5678/webhook/${webhookPath}`,
      authentication: 'genericCredentialType',
      genericAuthType: 'httpHeaderAuth',
      sendBody: true,
      specifyBody: 'json',
      jsonBody: '={{ $json }}',
      options: {},
    };
    node.type = 'n8n-nodes-base.httpRequest';
    node.typeVersion = 4.3;
    node.credentials = structuredClone(INTERNAL_HEADER_AUTH);
    node.onError = 'continueErrorOutput';
  }

  const failedNode = workflow.nodes.find(
    (entry) => entry.name === 'Mark Dispatch Failed',
  );
  assert(failedNode, 'WF98 is missing Mark Dispatch Failed');

  const assignments =
    failedNode.parameters?.assignments?.assignments ?? [];
  const integrityAssignment = assignments.find(
    (entry) => entry.name === '=integrity_failure',
  );
  if (integrityAssignment) {
    integrityAssignment.name = 'integrity_failure';
  }

  for (const [nodeName, webhookPath] of DISPATCH_PATHS) {
    const node = workflow.nodes.find((entry) => entry.name === nodeName);
    assert(
      node?.type === 'n8n-nodes-base.httpRequest',
      `${nodeName} was not converted to HTTP Request`,
    );
    assert(
      node.parameters.url ===
        `http://n8n-main:5678/webhook/${webhookPath}`,
      `${nodeName} has an unexpected URL`,
    );
    assert(
      node.parameters.jsonBody === '={{ $json }}',
      `${nodeName} does not send the current item as JSON`,
    );
    assert(
      node.onError === 'continueErrorOutput',
      `${nodeName} does not preserve the error output`,
    );
  }

  assert(
    !assignments.some((entry) => entry.name === '=integrity_failure'),
    'WF98 still contains the invalid =integrity_failure field name',
  );

  return workflow;
}

function webhookNode() {
  return {
    parameters: {
      httpMethod: 'POST',
      path: 'internal/wf99-retry-dispatch',
      authentication: 'headerAuth',
      responseMode: 'onReceived',
      options: {
        responseCode: 200,
      },
    },
    type: 'n8n-nodes-base.webhook',
    typeVersion: 2.1,
    position: [-592, -400],
    id: '3d542d50-4efb-4d72-a717-93d30bbdebc8',
    name: 'Webhook',
    webhookId: '6fbc8908-f935-444d-a404-e2cf472450a7',
    credentials: structuredClone(INTERNAL_HEADER_AUTH),
  };
}

function migrateWf99(workflow) {
  const validator = workflow.nodes.find(
    (entry) => entry.name === 'Validate Internal Invocation',
  );
  assert(validator, 'WF99 is missing Validate Internal Invocation');
  assert(
    typeof validator.parameters?.jsCode === 'string',
    'WF99 validator does not contain JavaScript code',
  );

  const oldInputLine = 'const input = items[0].json ?? {};';
  const normalizedInput = `const rawInput = items[0].json ?? {};\n\nconst input =\n  rawInput.body &&\n  typeof rawInput.body === 'object' &&\n  !Array.isArray(rawInput.body)\n    ? rawInput.body\n    : rawInput;`;

  if (validator.parameters.jsCode.includes(oldInputLine)) {
    validator.parameters.jsCode = validator.parameters.jsCode.replace(
      oldInputLine,
      normalizedInput,
    );
  }

  assert(
    validator.parameters.jsCode.includes('rawInput.body'),
    'WF99 validator was not updated to normalize webhook body input',
  );

  let webhook = workflow.nodes.find((entry) => entry.name === 'Webhook');
  if (!webhook) {
    webhook = webhookNode();
    workflow.nodes.push(webhook);
  } else {
    Object.assign(webhook, webhookNode(), {
      id: webhook.id,
      webhookId: webhook.webhookId ?? webhookNode().webhookId,
    });
  }

  workflow.connections.Webhook = {
    main: [
      [
        {
          node: 'Validate Internal Invocation',
          type: 'main',
          index: 0,
        },
      ],
    ],
  };

  assert(
    workflow.nodes.some(
      (entry) => entry.name === 'Internal Invocation Trigger',
    ),
    'WF99 must retain Internal Invocation Trigger during migration',
  );
  assert(
    workflow.nodes.some((entry) => entry.name === 'Error Trigger'),
    'WF99 must retain Error Trigger',
  );
  assert(
    webhook.parameters.path === 'internal/wf99-retry-dispatch',
    'WF99 webhook path is incorrect',
  );
  assert(
    webhook.parameters.authentication === 'headerAuth',
    'WF99 webhook is not protected with Header Auth',
  );

  return workflow;
}

const wf98 = migrateWf98(readWorkflow(WF98_PATH));
const wf99 = migrateWf99(readWorkflow(WF99_PATH));

writeWorkflow(WF98_PATH, wf98);
writeWorkflow(WF99_PATH, wf99);

console.log('Updated WF98 and WF99 workflow exports.');
