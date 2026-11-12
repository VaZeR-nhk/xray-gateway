#!/bin/sh
set -eu
mkdir -p /etc/xray-gateway /var/log/supervisor
chmod 700 /etc/xray-gateway
test -s /etc/xray-gateway/settings.conf || { echo "settings.conf missing; run ./install.sh" >&2; exit 1; }
test -s /etc/xray-gateway/web-auth || { echo "web-auth missing; run ./install.sh" >&2; exit 1; }
chmod 600 /etc/xray-gateway/settings.conf /etc/xray-gateway/web-auth
if [ ! -s /etc/xray-gateway/config.json ]; then
  /usr/local/sbin/xray-gateway update
fi
exec /usr/bin/supervisord -n -c /opt/xray-gateway/docker/supervisord.conf
