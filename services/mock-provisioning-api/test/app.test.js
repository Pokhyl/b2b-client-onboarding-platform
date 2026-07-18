import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';

import { createApp } from '../src/app.js';

let server;
let baseUrl;

before(async () => {
  server = createApp({
    logger: {
      error() {},
    },
  });

  await new Promise((resolve, reject) => {
    server.once('error', reject);

    server.listen(0, '127.0.0.1', () => {
      server.removeListener('error', reject);
      resolve();
    });
  });

  const address = server.address();

  if (address === null || typeof address === 'string') {
    throw new Error('Mock Provisioning API did not expose a TCP address');
  }

  baseUrl = `http://127.0.0.1:${address.port}`;
});

after(async () => {
  if (server === undefined) {
    return;
  }

  await new Promise((resolve, reject) => {
    server.close((error) => {
      if (error) {
        reject(error);
        return;
      }

      resolve();
    });
  });
});

async function provision({
  idempotencyKey,
  payload,
}) {
  const response = await fetch(`${baseUrl}/v1/clients`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'idempotency-key': idempotencyKey,
    },
    body: JSON.stringify(payload),
  });

  const body = await response.json();

  return {
    response,
    body,
  };
}

test('health endpoint reports that the service is available', async () => {
  const response = await fetch(`${baseUrl}/healthz`);
  const body = await response.json();

  assert.equal(response.status, 200);
  assert.deepEqual(body, {
    status: 'ok',
    service: 'mock-provisioning-api',
  });
});

test('repeated request with the same key returns the same client', async () => {
  const request = {
    idempotencyKey: 'onboarding:case-001:provision-client',
    payload: {
      caseId: 'case-001',
      companyName: 'Example Company',
      companyIdentifier: 'PL1234567890',
      scenario: 'success',
    },
  };

  const first = await provision(request);
  const second = await provision(request);

  assert.equal(first.response.status, 201);
  assert.equal(first.body.replayed, false);

  assert.equal(second.response.status, 200);
  assert.equal(second.body.replayed, true);

  assert.equal(
    second.body.externalClientId,
    first.body.externalClientId,
  );

  assert.equal(second.body.attemptNumber, 1);
});

test('reusing a key with different data returns a conflict', async () => {
  const idempotencyKey = 'onboarding:case-002:provision-client';

  const first = await provision({
    idempotencyKey,
    payload: {
      caseId: 'case-002',
      companyName: 'Original Company',
      companyIdentifier: 'PL1111111111',
    },
  });

  const second = await provision({
    idempotencyKey,
    payload: {
      caseId: 'case-002',
      companyName: 'Different Company',
      companyIdentifier: 'PL2222222222',
    },
  });

  assert.equal(first.response.status, 201);
  assert.equal(second.response.status, 409);
  assert.equal(
    second.body.error.code,
    'IDEMPOTENCY_KEY_CONFLICT',
  );
});

test('retryable_once fails once and succeeds on the next attempt', async () => {
  const request = {
    idempotencyKey: 'onboarding:case-003:provision-client',
    payload: {
      caseId: 'case-003',
      companyName: 'Retry Company',
      companyIdentifier: 'PL3333333333',
      scenario: 'retryable_once',
    },
  };

  const first = await provision(request);
  const second = await provision(request);
  const third = await provision(request);

  assert.equal(first.response.status, 503);
  assert.equal(first.body.error.retryable, true);
  assert.equal(first.body.attemptNumber, 1);

  assert.equal(second.response.status, 201);
  assert.equal(second.body.attemptNumber, 2);
  assert.equal(second.body.replayed, false);

  assert.equal(third.response.status, 200);
  assert.equal(third.body.replayed, true);
  assert.equal(
    third.body.externalClientId,
    second.body.externalClientId,
  );
});

test('retryable_always consistently returns a retryable failure', async () => {
  const request = {
    idempotencyKey: 'onboarding:case-004:provision-client',
    payload: {
      caseId: 'case-004',
      companyName: 'Unavailable Company',
      companyIdentifier: 'PL4444444444',
      scenario: 'retryable_always',
    },
  };

  const first = await provision(request);
  const second = await provision(request);

  assert.equal(first.response.status, 503);
  assert.equal(first.body.error.retryable, true);
  assert.equal(first.body.attemptNumber, 1);

  assert.equal(second.response.status, 503);
  assert.equal(second.body.error.retryable, true);
  assert.equal(second.body.attemptNumber, 2);
});

test('terminal scenario returns a non-retryable failure', async () => {
  const result = await provision({
    idempotencyKey: 'onboarding:case-005:provision-client',
    payload: {
      caseId: 'case-005',
      companyName: 'Rejected Company',
      companyIdentifier: 'PL5555555555',
      scenario: 'terminal',
    },
  });

  assert.equal(result.response.status, 422);
  assert.equal(result.body.error.code, 'PROVISIONING_REJECTED');
  assert.equal(result.body.error.retryable, false);
  assert.equal(result.body.attemptNumber, 1);
});
