#!/bin/sh
set -eu
mkdir -p /etc/xray-gateway /var/lib/xray-gateway /var/log/supervisor
chmod 700 /var/lib/xray-gateway
test -s /etc/xray-gateway/.env || { echo ".env missing" >&2; exit 1; }
test -n "\${WEB_USERNAME:-}" && test -n "\${WEB_PASSWORD:-}" && test -n "\${SESSION_SECRET:-}" || { echo "WEB_USERNAME, WEB_PASSWORD and SESSION_SECRET must be set in .env" >&2; exit 1; }
chmod 600 /etc/xray-gateway/.env
if [ ! -s /var/lib/xray-gateway/config.json ]; then /usr/local/sbin/xray-gateway update; fi
exec /usr/bin/supervisord -n -c /opt/xray-gateway/docker/supervisord.conf
