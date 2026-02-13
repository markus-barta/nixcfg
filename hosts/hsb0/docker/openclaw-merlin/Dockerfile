FROM node:22-bookworm-slim
RUN apt-get update && apt-get install -y git curl vdirsyncer khal && rm -rf /var/lib/apt/lists/*
RUN npm install -g openclaw@latest

# Install CLI for Microsoft 365 (company calendar read-only via Graph API)
# https://github.com/pnp/cli-microsoft365
RUN npm install -g @pnp/cli-microsoft365

RUN mkdir -p /home/node/.openclaw/workspace /home/node/.config/vdirsyncer /home/node/.config/khal \
    && chown -R node:node /home/node/.openclaw /home/node/.config/vdirsyncer /home/node/.config/khal
USER node
EXPOSE 18789
CMD ["openclaw", "gateway", "--port", "18789"]
