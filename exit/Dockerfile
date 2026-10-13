FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends iptables ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY universal-bypass-tool /app/universal-bypass-tool
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/universal-bypass-tool /app/entrypoint.sh
ENTRYPOINT ["/app/entrypoint.sh"]
