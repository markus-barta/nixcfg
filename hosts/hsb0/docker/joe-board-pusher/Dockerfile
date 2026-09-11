# Joe board pusher — paper Gateway read-only → csb0 inbox. Never places orders.
FROM python:3.13.15-alpine3.24@sha256:540c7d91f98ff6880174c40e99067bf5941eb54d818a7a5e094d188b196a934d AS ibapi-builder
WORKDIR /build
COPY official-sdk.lock.json install-official-sdk.py ./
RUN apk add --no-cache tzdata \
    && python install-official-sdk.py --lock official-sdk.lock.json --target /opt/ibapi

FROM node:22.23.2-alpine3.24@sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32
COPY --from=ibapi-builder /usr/local/ /usr/local/
COPY --from=ibapi-builder /usr/lib/ /usr/lib/
COPY --from=ibapi-builder /opt/ibapi/ /opt/ibapi/
COPY --from=ibapi-builder /usr/share/zoneinfo/ /usr/share/zoneinfo/
RUN /opt/ibapi/bin/python -I -c 'import ibapi, google.protobuf; from zoneinfo import ZoneInfo; assert ibapi.__version__ == "10.45.1"; assert ZoneInfo("America/New_York").key == "America/New_York"' \
    && /opt/ibapi/bin/python -m pip check
WORKDIR /app
ENV NODE_ENV=production \
    IB_GATEWAY_HOST=100.64.0.6 \
    IB_GATEWAY_PORT=4002 \
    IB_CLIENT_ID=92 \
    JOE_PUSH_INTERVAL_SEC=30 \
    JOE_INBOX_URL=https://cs0.barta.cm/joe/inbox
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY project.mjs positions-state.mjs pusher-state.mjs pusher-recovery.mjs family-ledger.mjs family-state.mjs execution-history.mjs execution-reconciliation.mjs family-history.mjs family-history-cli.mjs family-history-session.mjs official-window-reader.mjs official-window-reader.py pusher.mjs ./
USER node
CMD ["node", "pusher.mjs"]
