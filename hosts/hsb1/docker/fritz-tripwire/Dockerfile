FROM alpine:3.20

RUN apk add --no-cache \
      webhook \
      curl \
      bash \
      jq \
      coreutils \
      tzdata

ENV TZ=Europe/Vienna

COPY hooks.yaml /etc/webhook/hooks.yaml
COPY run.sh /usr/local/bin/run.sh
RUN chmod +x /usr/local/bin/run.sh

EXPOSE 9000

CMD ["webhook", "-hooks", "/etc/webhook/hooks.yaml", "-verbose", "-port", "9000"]
