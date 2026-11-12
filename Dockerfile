FROM debian:bookworm-slim
ARG XRAY_VERSION=26.11.9
ENV DEBIAN_FRONTEND=noninteractive PYTHONUNBUFFERED=1 XRAY_WEB_HOST=0.0.0.0 XRAY_WEB_PORT=8080
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl unzip python3 supervisor iproute2 iptables nftables procps && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-64.zip" -o /tmp/xray.zip && unzip -q /tmp/xray.zip -d /tmp/xray && install -m 0755 /tmp/xray/xray /usr/local/bin/xray && rm -rf /tmp/xray /tmp/xray.zip
COPY gateway/ /opt/xray-gateway/
COPY docker/ /opt/xray-gateway/docker/
RUN chmod 0755 /opt/xray-gateway/docker/entrypoint.sh /opt/xray-gateway/docker/update-loop.sh /opt/xray-gateway/xray-gateway && ln -s /opt/xray-gateway/xray-gateway /usr/local/sbin/xray-gateway && mkdir -p /etc/xray-gateway /var/log/supervisor
VOLUME ["/etc/xray-gateway"]
EXPOSE 8080 10808 10809 12345
ENTRYPOINT ["/opt/xray-gateway/docker/entrypoint.sh"]
