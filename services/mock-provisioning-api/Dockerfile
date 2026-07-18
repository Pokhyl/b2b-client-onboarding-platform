FROM node:24-alpine3.24

WORKDIR /app

COPY --chown=node:node package.json ./
COPY --chown=node:node src ./src
COPY --chown=node:node test ./test

ENV NODE_ENV=production
ENV MOCK_PROVISIONING_API_PORT=3001

USER node

EXPOSE 3001

CMD ["node", "src/server.js"]
