# Joe household board — inbox + static UI (paper projection only).
FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production \
    JOE_DATA_DIR=/var/lib/joe-board \
    JOE_LISTEN=0.0.0.0:8080 \
    JOE_MAX_BODY_BYTES=262144
COPY package.json server.mjs validate.mjs ./
COPY public ./public
RUN mkdir -p /var/lib/joe-board && chown -R node:node /var/lib/joe-board /app
USER node
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/healthz >/dev/null || exit 1
CMD ["node", "server.mjs"]
