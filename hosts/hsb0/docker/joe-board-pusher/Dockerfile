# Joe board pusher — paper Gateway read-only → csb0 inbox. Never places orders.
FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production \
    IB_GATEWAY_HOST=100.64.0.6 \
    IB_GATEWAY_PORT=4002 \
    IB_CLIENT_ID=50 \
    JOE_PUSH_INTERVAL_SEC=30 \
    JOE_INBOX_URL=https://cs0.barta.cm/joe/inbox
COPY package.json ./
RUN npm install --omit=dev
COPY project.mjs positions-state.mjs pusher-state.mjs pusher.mjs ./
USER node
CMD ["node", "pusher.mjs"]
