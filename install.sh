#!/usr/bin/env bash
set -Eeuo pipefail

# Xray Gateway: one-shot host preparation + Docker deployment.
# Run as root on a clean Debian 12/13 server.

SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]$NC $*"; }
warn() { echo -e "${YELLOW}[!]$NC $*" >&2; }
die()  { echo -e "${RED}[ERROR]$NC $*" >&2; exit 1; }

trap 'rc=$?; echo -e "\n\033[0;31m[ERROR]\033[0m Ошибка на строке ${LINENO} (код ${rc})." >&2; exit "$rc"' ERR

[[ "$(id -u)" -eq 0 ]] || die "Запусти скрипт от root: bash install.sh"

[[ -r /etc/os-release ]] || die "Не найден /etc/os-release"
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "debian" ]] || die "Поддерживается Debian 12/13. Обнаружено: ${PRETTY_NAME:-unknown}"
case "${VERSION_ID:-}" in
  12|13) ;;
  *) die "Поддерживается Debian 12 или 13. Обнаружено: ${VERSION_ID:-unknown}" ;;
esac

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64|arm64) ;;
  *) die "Неподдерживаемая архитектура: $ARCH (нужна amd64 или arm64)" ;;
esac

command -v apt-get >/dev/null 2>&1 || die "apt-get не найден"
command -v systemctl >/dev/null 2>&1 || die "systemd не обнаружен; автоматический запуск Docker невозможен"

log "Система: ${PRETTY_NAME}; архитектура: $ARCH"
log "Обновляю индексы APT и устанавливаю системные зависимости"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg git jq iproute2 nftables

command -v curl >/dev/null 2>&1 || die "Не удалось установить curl"
curl --version | head -n 1

log "Подключаю официальный репозиторий Docker"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: $ARCH
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt-get update
log "Устанавливаю Docker Engine, Buildx и Compose v2"
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

log "Запускаю Docker и включаю автозапуск"
systemctl enable --now docker
systemctl is-active --quiet docker || die "Служба Docker не запустилась"
docker info >/dev/null 2>&1 || die "Docker Engine не отвечает"
docker compose version

# Проверяем доступное место до сборки образа.
AVAIL_KB="$(df -Pk "$SCRIPT_DIR" | awk 'NR==2 {print $4}')"
[[ "$AVAIL_KB" =~ ^[0-9]+$ ]] || die "Не удалось определить свободное место на диске"
(( AVAIL_KB >= 2097152 )) || die "Недостаточно места: нужно не менее 2 GiB свободного места для сборки образа"

mkdir -p data
chmod 700 data

if [[ ! -s data/settings.conf ]]; then
  echo
  read -r -s -p "Remnawave subscription URL (HTTPS, ввод скрыт): " SUB_URL
  echo
  [[ "$SUB_URL" == https://* ]] || die "Нужен HTTPS URL подписки"
  [[ "$SUB_URL" != *$'\n'* && "$SUB_URL" != *$'\r'* ]] || die "Некорректный URL"
  printf 'SUBSCRIPTION_URL=%s\nUSER_AGENT=Happ\nACTIVE_PROFILE=0\nTPROXY_PORT=12345\nGATEWAY_IP=0.0.0.0\n' "$SUB_URL" > data/settings.conf
  chmod 600 data/settings.conf
  unset SUB_URL
else
  log "Найден data/settings.conf — сохраняю существующие настройки подписки"
fi

if [[ ! -s data/web-auth ]]; then
  echo
  read -r -p "Web UI username [admin]: " WEB_USER
  WEB_USER="${WEB_USER:-admin}"
  [[ "$WEB_USER" != *:* && -n "$WEB_USER" ]] || die "Имя пользователя не должно быть пустым или содержать двоеточие"

  read -r -s -p "Web UI password (min 12 chars): " WEB_PASS
  echo
  read -r -s -p "Повтори пароль: " WEB_PASS_CONFIRM
  echo
  [[ "${#WEB_PASS}" -ge 12 ]] || die "Пароль должен содержать не менее 12 символов"
  [[ "$WEB_PASS" == "$WEB_PASS_CONFIRM" ]] || die "Пароли не совпадают"
  printf '%s:%s\n' "$WEB_USER" "$WEB_PASS" > data/web-auth
  chmod 600 data/web-auth
  unset WEB_PASS WEB_PASS_CONFIRM
else
  log "Найден data/web-auth — сохраняю существующую авторизацию панели"
fi

if [[ ! -f .env ]]; then
  printf 'XRAY_VERSION=26.11.9\n' > .env
fi

log "Проверяю конфигурацию Docker Compose"
docker compose config --quiet

log "Собираю образ и запускаю Xray Gateway"
docker compose up -d --build

log "Проверяю состояние контейнера"
sleep 3
docker compose ps
if ! docker compose ps --status running --services | grep -qx 'xray-gateway'; then
  docker compose logs --tail=100 xray-gateway || true
  die "Контейнер xray-gateway не перешёл в состояние running"
fi

SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
SERVER_IP="${SERVER_IP:-SERVER-IP}"

echo
log "Установка завершена"
echo "Web UI: http://$SERVER_IP:8080"
warn "Прозрачная маршрутизация (TPROXY) пока НЕ включена."
warn "Не направляй LAN-трафик через сервер, пока отдельно не проверим панель, подписку, профили и host-network.sh."
