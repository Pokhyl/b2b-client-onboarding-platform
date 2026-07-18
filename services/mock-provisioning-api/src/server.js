import { createApp } from './app.js';

const port = Number.parseInt(
  process.env.MOCK_PROVISIONING_API_PORT ?? '3001',
  10,
);

if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw new Error('MOCK_PROVISIONING_API_PORT must be a valid TCP port');
}

const server = createApp();

server.listen(port, '0.0.0.0', () => {
  console.log(`Mock Provisioning API listening on port ${port}`);
});

function shutdown(signal) {
  console.log(`Received ${signal}, shutting down Mock Provisioning API`);

  server.close((error) => {
    if (error) {
      console.error('Failed to close Mock Provisioning API', error);
      process.exitCode = 1;
    }
  });
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
