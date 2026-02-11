FROM node:22-bookworm-slim
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*
RUN npm install -g openclaw@latest
RUN mkdir -p /home/node/.openclaw/workspace && chown -R node:node /home/node/.openclaw
USER node
EXPOSE 18789
CMD ["openclaw", "gateway", "--port", "18789"]
