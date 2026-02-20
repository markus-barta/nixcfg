FROM node:22-bookworm-slim
RUN apt-get update && apt-get install -y git curl jq vdirsyncer khal mosquitto-clients python3 && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/bin/python3 /usr/bin/python
RUN npm install -g openclaw@latest sharp

# Install gogcli (Google Suite CLI for Gmail, Calendar, Drive, etc.)
# https://github.com/steipete/gogcli
RUN curl -sL https://github.com/steipete/gogcli/releases/download/v0.11.0/gogcli_0.11.0_linux_amd64.tar.gz \
    | tar xz -C /tmp && mv /tmp/gog /usr/local/bin/gog && chmod +x /usr/local/bin/gog

# Install CLI for Microsoft 365 (company calendar read-only via Graph API)
# https://github.com/pnp/cli-microsoft365
RUN npm install -g @pnp/cli-microsoft365

COPY entrypoint.sh /home/node/entrypoint.sh
# Wrapper: sources .env then runs openclaw (use: docker exec <container> oc <cmd>)
RUN printf '#!/bin/sh\n. /home/node/.env 2>/dev/null\nexec openclaw "$@"\n' > /usr/local/bin/oc \
    && chmod +x /usr/local/bin/oc /home/node/entrypoint.sh \
    && mkdir -p /home/node/.openclaw/workspace /home/node/.config/vdirsyncer /home/node/.config/khal /home/node/.config/gogcli \
    && chown -R node:node /home/node/.openclaw /home/node/.config/vdirsyncer /home/node/.config/khal /home/node/.config/gogcli /home/node/entrypoint.sh
USER node
EXPOSE 18789
ENTRYPOINT ["/home/node/entrypoint.sh"]
