#!/bin/bash
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
command -v docker >/dev/null || { echo "Docker не установлен"; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "Нужен Docker Compose v2"; exit 1; }
mkdir -p data; chmod 700 data
if [[ ! -s data/settings.conf ]]; then
  read -r -p "Remnawave subscription URL (HTTPS): " SUB_URL
  [[ "$SUB_URL" == https://* ]] || { echo "Нужен HTTPS URL"; exit 1; }
  printf 'SUBSCRIPTION_URL=%s\nUSER_AGENT=Happ\nACTIVE_PROFILE=0\nTPROXY_PORT=12345\nGATEWAY_IP=0.0.0.0\n' "$SUB_URL" > data/settings.conf
  chmod 600 data/settings.conf
fi
if [[ ! -s data/web-auth ]]; then
  read -r -p "Web UI username [admin]: " WEB_USER; WEB_USER=${WEB_USER:-admin}
  read -r -s -p "Web UI password (min 12 chars): " WEB_PASS; echo
  [[ ${#WEB_PASS} -ge 12 ]] || { echo "Пароль слишком короткий"; exit 1; }
  printf '%s:%s\n' "$WEB_USER" "$WEB_PASS" > data/web-auth; chmod 600 data/web-auth
fi
[[ -f .env ]] || printf 'XRAY_VERSION=26.11.9\n' > .env
docker compose up -d --build
echo "Web UI: http://SERVER-IP:8080"
echo "ВНИМАНИЕ: TPROXY host firewall ещё не настроен. Пока не направляйте LAN-трафик через сервер."
