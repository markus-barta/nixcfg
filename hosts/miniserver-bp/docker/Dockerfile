FROM node:22-bookworm-slim
RUN apt-get update && apt-get install -y git curl && rm -rf /var/lib/apt/lists/*
RUN npm install -g openclaw@latest

# Install gogcli (Google Suite CLI for Gmail, Calendar, Drive, etc.)
# https://github.com/steipete/gogcli
RUN curl -sL https://github.com/steipete/gogcli/releases/download/v0.9.0/gogcli_0.9.0_linux_amd64.tar.gz \
    | tar xz -C /tmp && mv /tmp/gog /usr/local/bin/gog && chmod +x /usr/local/bin/gog

# Install himalaya (CLI email client for IMAP/SMTP)
# https://github.com/soywod/himalaya
RUN curl -sL https://github.com/soywod/himalaya/releases/download/v1.1.0/himalaya-linux-x86_64.tar.gz \
    | tar xz -C /tmp && mv /tmp/himalaya /usr/local/bin/himalaya && chmod +x /usr/local/bin/himalaya

RUN mkdir -p /home/node/.openclaw/workspace /home/node/.config/gogcli \
    && chown -R node:node /home/node/.openclaw /home/node/.config/gogcli
USER node
EXPOSE 18789
CMD ["openclaw", "gateway", "--port", "18789"]
