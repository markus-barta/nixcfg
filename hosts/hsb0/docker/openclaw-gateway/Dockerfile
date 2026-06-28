# openclaw-gateway: multi-agent container (Merlin + Nimue)
# Node 24: required by node-llama-cpp (optional dep of openclaw) for local
# memory-search embeddings. OpenClaw itself runs on >=22.14.0; the bump exists
# only to satisfy the embedder's prebuilt-binary matrix.
FROM node:24-bookworm-slim
RUN apt-get update && apt-get install -y git curl jq vdirsyncer khal mosquitto-clients python3 build-essential openssh-client cron sudo && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/bin/python3 /usr/bin/python
# node-llama-cpp is the native runtime for local memory-search embeddings.
# As of OpenClaw 6.10 the embedder is a PLUGIN (@openclaw/llama-cpp-provider,
# installed at boot by entrypoint.sh §7.5 into the data volume); that plugin
# depends on node-llama-cpp@3.18.1, the same global we force here. Keeping the
# global guarantees the prebuilt native binary is present at image-build time
# (npm skips optional native builds silently on failure). NIX-70 → NIX-203.
RUN npm install -g openclaw@latest sharp node-llama-cpp@^3

# Install gogcli (Google Suite CLI for Gmail, Calendar, Drive, etc.)
# https://github.com/steipete/gogcli
RUN curl -sL https://github.com/steipete/gogcli/releases/download/v0.11.0/gogcli_0.11.0_linux_amd64.tar.gz \
    | tar xz -C /tmp && mv /tmp/gog /usr/local/bin/gog && chmod +x /usr/local/bin/gog

# Install CLI for Microsoft 365 (company calendar read-only via Graph API)
# https://github.com/pnp/cli-microsoft365
RUN npm install -g @pnp/cli-microsoft365

COPY entrypoint.sh /home/node/entrypoint.sh
COPY shared-sync.sh /home/node/shared-sync.sh
COPY workspace-push.sh /home/node/workspace-push.sh
# Wrapper: sources .env then runs openclaw (use: docker exec <container> oc <cmd>)
RUN printf '#!/bin/sh\n. /home/node/.env 2>/dev/null\nexec openclaw "$@"\n' > /usr/local/bin/oc \
    && chmod +x /usr/local/bin/oc /home/node/entrypoint.sh \
    && mkdir -p \
        /home/node/.openclaw/workspace-merlin \
        /home/node/.openclaw/workspace-nimue \
        /home/node/.openclaw/workspace-shared \
        /home/node/.openclaw/agents/merlin/agent \
        /home/node/.openclaw/agents/merlin/sessions \
        /home/node/.openclaw/agents/nimue/agent \
        /home/node/.openclaw/agents/nimue/sessions \
        /home/node/.config/merlin/vdirsyncer \
        /home/node/.config/merlin/khal \
        /home/node/.config/merlin/gogcli \
        /home/node/.config/nimue/vdirsyncer \
        /home/node/.config/nimue/khal \
        /home/node/.config/nimue/gogcli \
        /home/node/.ssh \
    && chown -R node:node /home/node/.openclaw /home/node/.config /home/node/.ssh /home/node/entrypoint.sh /home/node/shared-sync.sh /home/node/workspace-push.sh \
    && chmod +x /home/node/shared-sync.sh /home/node/workspace-push.sh \
    && echo "node ALL=(root) NOPASSWD: /usr/sbin/cron" >> /etc/sudoers
USER node
EXPOSE 18789
ENTRYPOINT ["/home/node/entrypoint.sh"]
