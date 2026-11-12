#!/bin/sh
set -eu
mkdir -p /etc/xray-gateway /var/log/supervisor
chmod 700 /etc/xray-gateway
test -s /etc/xray-gateway/.env || { echo ".env missing; create it from .env.example" >&2; exit 1; }
test -n "${WEB_USERNAME:-}" && test -n "${WEB_PASSWORD:-}" && test -n "${SESSION_SECRET:-}" || { echo "WEB_USERNAME, WEB_PASSWORD and SESSION_SECRET must be set in .env" >&2; exit 1; }
chmod 600 /etc/xray-gateway/.env
[ ! -f /etc/xray-gateway/settings.conf ] || chmod 600 /etc/xray-gateway/settings.conf
if [ ! -s /etc/xray-gateway/config.json ]; then
  /usr/local/sbin/xray-gateway update
fi
exec /usr/bin/supervisord -n -c /opt/xray-gateway/docker/supervisord.conf
