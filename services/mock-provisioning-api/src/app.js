import { createHash } from 'node:crypto';
import { createServer } from 'node:http';

const MAX_BODY_SIZE_BYTES = 64 * 1024;

const SUPPORTED_SCENARIOS = new Set([
  'success',
  'retryable_once',
  'retryable_always',
  'terminal',
]);

function sendJson(response, statusCode, payload, headers = {}) {
  const body = JSON.stringify(payload);

  response.writeHead(statusCode, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body),
    ...headers,
  });

  response.end(body);
}

function canonicalize(value) {
  if (Array.isArray(value)) {
    return value.map(canonicalize);
  }

  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, canonicalize(value[key])]),
    );
  }

  return value;
}

function createPayloadFingerprint(payload) {
  return createHash('sha256')
    .update(JSON.stringify(canonicalize(payload)))
    .digest('hex');
}

function createExternalClientId(idempotencyKey) {
  const digest = createHash('sha256')
    .update(idempotencyKey)
    .digest('hex')
    .slice(0, 24);

  return `mock_client_${digest}`;
}

async function readJsonBody(request) {
  const chunks = [];
  let totalBytes = 0;

  for await (const chunk of request) {
    totalBytes += chunk.length;

    if (totalBytes > MAX_BODY_SIZE_BYTES) {
      const error = new Error('Request body is too large');
      error.code = 'BODY_TOO_LARGE';
      throw error;
    }

    chunks.push(chunk);
  }

  if (chunks.length === 0) {
    const error = new Error('Request body is required');
    error.code = 'INVALID_JSON';
    throw error;
  }

  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    const error = new Error('Request body must contain valid JSON');
    error.code = 'INVALID_JSON';
    throw error;
  }
}

function validateProvisioningRequest(payload) {
  if (payload === null || typeof payload !== 'object' || Array.isArray(payload)) {
    return 'Request body must be a JSON object';
  }

  const requiredStringFields = [
    'caseId',
    'companyName',
    'companyIdentifier',
  ];

  for (const field of requiredStringFields) {
    if (
      typeof payload[field] !== 'string' ||
      payload[field].trim().length === 0
    ) {
      return `${field} must be a non-empty string`;
    }
  }

  const scenario = payload.scenario ?? 'success';

  if (!SUPPORTED_SCENARIOS.has(scenario)) {
    return `scenario must be one of: ${[...SUPPORTED_SCENARIOS].join(', ')}`;
  }

  return null;
}

export function createApp({ logger = console } = {}) {
  const successfulRequests = new Map();
  const attemptCounts = new Map();

  return createServer(async (request, response) => {
    try {
      const requestUrl = new URL(
        request.url ?? '/',
        `http://${request.headers.host ?? 'localhost'}`,
      );

      if (request.method === 'GET' && requestUrl.pathname === '/healthz') {
        sendJson(response, 200, {
          status: 'ok',
          service: 'mock-provisioning-api',
        });
        return;
      }

      if (request.method !== 'POST' || requestUrl.pathname !== '/v1/clients') {
        sendJson(response, 404, {
          error: {
            code: 'NOT_FOUND',
            message: 'Route not found',
          },
        });
        return;
      }

      const idempotencyKeyHeader = request.headers['idempotency-key'];

      if (
        typeof idempotencyKeyHeader !== 'string' ||
        idempotencyKeyHeader.trim().length === 0
      ) {
        sendJson(response, 400, {
          error: {
            code: 'IDEMPOTENCY_KEY_REQUIRED',
            message: 'Idempotency-Key header is required',
          },
        });
        return;
      }

      const idempotencyKey = idempotencyKeyHeader.trim();

      if (idempotencyKey.length > 200) {
        sendJson(response, 400, {
          error: {
            code: 'INVALID_IDEMPOTENCY_KEY',
            message: 'Idempotency-Key must not exceed 200 characters',
          },
        });
        return;
      }

      const payload = await readJsonBody(request);
      const validationError = validateProvisioningRequest(payload);

      if (validationError !== null) {
        sendJson(response, 400, {
          error: {
            code: 'INVALID_REQUEST',
            message: validationError,
          },
        });
        return;
      }

      const fingerprint = createPayloadFingerprint(payload);
      const existingRequest = successfulRequests.get(idempotencyKey);

      if (existingRequest !== undefined) {
        if (existingRequest.fingerprint !== fingerprint) {
          sendJson(response, 409, {
            error: {
              code: 'IDEMPOTENCY_KEY_CONFLICT',
              message:
                'The idempotency key was already used with a different request',
            },
          });
          return;
        }

        sendJson(response, 200, {
          ...existingRequest.response,
          replayed: true,
        });
        return;
      }

      const attemptNumber = (attemptCounts.get(idempotencyKey) ?? 0) + 1;
      attemptCounts.set(idempotencyKey, attemptNumber);

      const scenario = payload.scenario ?? 'success';

      if (scenario === 'terminal') {
        sendJson(response, 422, {
          error: {
            code: 'PROVISIONING_REJECTED',
            message: 'The provisioning request was permanently rejected',
            retryable: false,
          },
          attemptNumber,
        });
        return;
      }

      if (
        scenario === 'retryable_always' ||
        (scenario === 'retryable_once' && attemptNumber === 1)
      ) {
        sendJson(
          response,
          503,
          {
            error: {
              code: 'PROVISIONING_TEMPORARILY_UNAVAILABLE',
              message: 'The provisioning service is temporarily unavailable',
              retryable: true,
            },
            attemptNumber,
          },
          {
            'retry-after': '1',
          },
        );
        return;
      }

      const provisioningResponse = {
        externalClientId: createExternalClientId(idempotencyKey),
        caseId: payload.caseId,
        companyName: payload.companyName.trim(),
        companyIdentifier: payload.companyIdentifier.trim(),
        status: 'provisioned',
        attemptNumber,
      };

      successfulRequests.set(idempotencyKey, {
        fingerprint,
        response: provisioningResponse,
      });

      sendJson(response, 201, {
        ...provisioningResponse,
        replayed: false,
      });
    } catch (error) {
      if (error?.code === 'BODY_TOO_LARGE') {
        sendJson(response, 413, {
          error: {
            code: 'BODY_TOO_LARGE',
            message: error.message,
          },
        });
        return;
      }

      if (error?.code === 'INVALID_JSON') {
        sendJson(response, 400, {
          error: {
            code: 'INVALID_JSON',
            message: error.message,
          },
        });
        return;
      }

      logger.error('Unexpected mock provisioning API error', error);

      sendJson(response, 500, {
        error: {
          code: 'INTERNAL_ERROR',
          message: 'Unexpected internal error',
        },
      });
    }
  });
}
