#!/usr/bin/env bash
set -Eeuo pipefail

# Xray Gateway: one-shot host preparation + Docker deployment.
# Run as root on a clean Debian 12/13 server.

SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
[[ "$SCRIPT_DIR" == "/opt/xray-gateway" ]] || { echo "[ERROR] Проект должен находиться строго в /opt/xray-gateway (сейчас: $SCRIPT_DIR)" >&2; exit 1; }
cd "$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]$NC $*"; }
warn() { echo -e "${YELLOW}[!]$NC $*" >&2; }
die()  { echo -e "${RED}[ERROR]$NC $*" >&2; exit 1; }

PREFLIGHT_STATE=""
cleanup_preflight() {
  if [[ -n "$PREFLIGHT_STATE" && -d "$PREFLIGHT_STATE" ]]; then
    rm -rf "$PREFLIGHT_STATE"
  fi
}
trap cleanup_preflight EXIT
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
apt-get install -y --no-install-recommends ca-certificates curl gnupg git jq iproute2 nftables python3

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

# Проверяем место и в каталоге проекта, и в хранилище Docker.
# Для этого образа достаточно 1 GiB запаса; сборка не компилирует Xray из исходников.
MIN_FREE_KB=1048576
DOCKER_ROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)"
[[ -n "$DOCKER_ROOT" && -d "$DOCKER_ROOT" ]] || die "Не удалось определить каталог данных Docker"

for CHECK_PATH in "$SCRIPT_DIR" "$DOCKER_ROOT"; do
  AVAIL_KB="$(df -Pk "$CHECK_PATH" | awk 'NR==2 {print $4}')"
  [[ "$AVAIL_KB" =~ ^[0-9]+$ ]] || die "Не удалось определить свободное место для $CHECK_PATH"
  (( AVAIL_KB >= MIN_FREE_KB )) || die "Недостаточно места на разделе $CHECK_PATH: нужно не менее 1 GiB свободного места"
done

mkdir -p state
chmod 700 state

# Load existing installer settings from .env only.
declare -A OLD=()
if [[ -f .env ]]; then
  while IFS='=' read -r key value; do
    [[ -n "${key:-}" && "$key" != \\#* ]] && OLD["$key"]="$value"
  done < .env
fi

# Select LAN interface and an exact IPv4 address for Xray's transparent inbound.
LAN_IF="${OLD[LAN_IF]:-}"
LAN_CIDR="${OLD[LAN_CIDR]:-}"
GATEWAY_IP="${OLD[GATEWAY_IP]:-}"
if [[ -z "$LAN_IF" || -z "$LAN_CIDR" || -z "$GATEWAY_IP" || "$GATEWAY_IP" == "0.0.0.0" ]]; then
  echo
  echo "Доступные IPv4-интерфейсы:"
  mapfile -t NETWORK_ROWS < <(ip -o -4 addr show scope global | awk '{print $2, $4}')
  (("${#NETWORK_ROWS[@]}" > 0)) || die "Не найден интерфейс с глобальным IPv4-адресом"
  for i in "${!NETWORK_ROWS[@]}"; do printf "  %d) %s\n" "$((i+1))" "${NETWORK_ROWS[$i]}"; done
  DEFAULT_IF="$(ip -4 route show default | awk 'NR==1 {print $5}')"
  DEFAULT_INDEX=1
  for i in "${!NETWORK_ROWS[@]}"; do
    [[ "${NETWORK_ROWS[$i]%% *}" == "$DEFAULT_IF" ]] && DEFAULT_INDEX=$((i+1))
  done
  read -r -p "Выбери LAN-интерфейс [$DEFAULT_INDEX]: " NETWORK_CHOICE
  NETWORK_CHOICE="${NETWORK_CHOICE:-$DEFAULT_INDEX}"
  [[ "$NETWORK_CHOICE" =~ ^[0-9]+$ ]] && (( NETWORK_CHOICE >= 1 && NETWORK_CHOICE <= ${#NETWORK_ROWS[@]} )) || die "Некорректный выбор интерфейса"
  SELECTED_ROW="${NETWORK_ROWS[$((NETWORK_CHOICE-1))]}"
  LAN_IF="${SELECTED_ROW%% *}"
  mapfile -t IF_ADDRESSES < <(ip -o -4 addr show scope global dev "$LAN_IF" | awk '{print $4}')
  (("${#IF_ADDRESSES[@]}" > 0)) || die "На $LAN_IF нет глобального IPv4"
  if (("${#IF_ADDRESSES[@]}" == 1)); then
    SELECTED_ADDRESS="${IF_ADDRESSES[0]}"
  else
    echo "IPv4-адреса интерфейса $LAN_IF:"
    for i in "${!IF_ADDRESSES[@]}"; do printf "  %d) %s\n" "$((i+1))" "${IF_ADDRESSES[$i]}"; done
    read -r -p "Выбери адрес [1]: " ADDRESS_CHOICE
    ADDRESS_CHOICE="${ADDRESS_CHOICE:-1}"
    [[ "$ADDRESS_CHOICE" =~ ^[0-9]+$ ]] && (( ADDRESS_CHOICE >= 1 && ADDRESS_CHOICE <= ${#IF_ADDRESSES[@]} )) || die "Некорректный выбор IPv4-адреса"
    SELECTED_ADDRESS="${IF_ADDRESSES[$((ADDRESS_CHOICE-1))]}"
  fi
  GATEWAY_IP="${SELECTED_ADDRESS%%/*}"
  LAN_CIDR="$(python3 - "$SELECTED_ADDRESS" <<'PYNET'
import ipaddress,sys
print(ipaddress.ip_interface(sys.argv[1]).network)
PYNET
)"
  echo "Выбрано: интерфейс=$LAN_IF, LAN=$LAN_CIDR, Xray listen=$GATEWAY_IP"
else
  echo "Сохранённая сеть: интерфейс=$LAN_IF, LAN=$LAN_CIDR, Xray listen=$GATEWAY_IP"
fi
ip link show dev "$LAN_IF" >/dev/null 2>&1 || die "Сохранённый LAN-интерфейс $LAN_IF не существует"
LAN_ADDRESSES="$(ip -o -4 addr show scope global dev "$LAN_IF" | awk '{print $4}')"
python3 - "$LAN_CIDR" "$GATEWAY_IP" "$LAN_ADDRESSES" <<'PYNETCHECK'
import ipaddress,sys
network=ipaddress.ip_network(sys.argv[1], strict=False)
listen=ipaddress.ip_address(sys.argv[2])
addresses=[ipaddress.ip_interface(x).ip for x in sys.argv[3].split() if x]
if network.version != 4: raise SystemExit("LAN_CIDR должен быть IPv4")
if not any(address in network for address in addresses): raise SystemExit("LAN_CIDR не соответствует интерфейсу")
if listen not in addresses: raise SystemExit("GATEWAY_IP не назначен выбранному LAN-интерфейсу")
PYNETCHECK

TPROXY_PORT="${OLD[TPROXY_PORT]:-12345}"
read -r -p "TPROXY listen port [$TPROXY_PORT]: " INPUT_TPROXY_PORT
TPROXY_PORT="${INPUT_TPROXY_PORT:-$TPROXY_PORT}"
python3 - "$TPROXY_PORT" <<'PYPORT'
import sys
raw=sys.argv[1]
if not raw.isascii() or not raw.isdecimal():
    raise SystemExit("TPROXY_PORT должен быть целым числом")
port=int(raw,10)
if not 1 <= port <= 65535:
    raise SystemExit("TPROXY_PORT должен находиться в диапазоне 1–65535")
print(f"Порт TPROXY: {port}")
PYPORT
TPROXY_PORT="$(python3 -c 'import sys; print(int(sys.argv[1], 10))' "$TPROXY_PORT")"

echo
if [[ -n "${OLD[SUBSCRIPTION_URL]:-}" ]]; then
  read -r -p "Remnawave subscription URL (Enter — оставить текущую): " SUB_URL
  SUB_URL="${SUB_URL:-${OLD[SUBSCRIPTION_URL]}}"
else
  read -r -p "Remnawave subscription URL (HTTPS): " SUB_URL
fi
[[ "$SUB_URL" == https://* && "$SUB_URL" != *[[:space:]]* ]] || die "Нужен HTTPS URL без пробелов"
[[ "$SUB_URL" =~ ^https://[A-Za-z0-9._~:/?%+=\&-]+$ ]] || die "URL содержит неподдерживаемые символы"

WEB_USER="${WEB_USERNAME:-${OLD[WEB_USERNAME]:-admin}}"
WEB_PASS="${WEB_PASSWORD:-${OLD[WEB_PASSWORD]:-}}"
if [[ -z "$WEB_PASS" ]]; then
  echo
  read -r -p "Web UI username [$WEB_USER]: " INPUT_USER
  WEB_USER="${INPUT_USER:-$WEB_USER}"
  [[ "$WEB_USER" =~ ^[A-Za-z0-9._-]+$ ]] || die "Недопустимый логин"
  read -r -p "Сгенерировать пароль автоматически? [Y/n]: " GENERATE_PASSWORD
  case "${GENERATE_PASSWORD,,}" in
    n|no|н|нет)
      while true; do
        read -r -s -p "Web UI password (min 12 chars): " WEB_PASS; echo
        read -r -s -p "Повтори пароль: " WEB_PASS_CONFIRM; echo
        [[ "$WEB_PASS" == "$WEB_PASS_CONFIRM" ]] || { warn "Пароли не совпадают"; continue; }
        break
      done
      ;;
    *)
      WEB_PASS="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
      ;;
  esac
fi
[[ "$WEB_USER" =~ ^[A-Za-z0-9._-]+$ ]] || die "Недопустимый логин"
[[ "${#WEB_PASS}" -ge 12 && "$WEB_PASS" =~ ^[A-Za-z0-9._~!@%+=,-]+$ ]] || die "Пароль должен быть не короче 12 символов и содержать только A-Z a-z 0-9 . _ ~ ! @ % + = , -"

export XRAY_GATEWAY_SUBSCRIPTION_URL="$SUB_URL" XRAY_GATEWAY_WEB_USERNAME="$WEB_USER" XRAY_GATEWAY_WEB_PASSWORD="$WEB_PASS"
export XRAY_GATEWAY_USER_AGENT="${OLD[USER_AGENT]:-Happ}"
export XRAY_GATEWAY_ACTIVE_PROFILE="${OLD[ACTIVE_PROFILE]:-0}"
export XRAY_GATEWAY_TPROXY_PORT="$TPROXY_PORT"
export XRAY_GATEWAY_GATEWAY_IP="$GATEWAY_IP"
export XRAY_GATEWAY_LAN_IF="$LAN_IF"
export XRAY_GATEWAY_LAN_CIDR="$LAN_CIDR"
export XRAY_GATEWAY_ENABLE_TPROXY="${OLD[ENABLE_TPROXY]:-false}"
export XRAY_GATEWAY_XRAY_VERSION="${OLD[XRAY_VERSION]:-26.11.9}"
export XRAY_GATEWAY_SESSION_SECRET="${OLD[SESSION_SECRET]:-}"

python3 - <<'PYENV'
import os, pathlib, secrets, re
p = pathlib.Path(".env")
values = {
    "XRAY_VERSION": os.environ["XRAY_GATEWAY_XRAY_VERSION"],
    "SUBSCRIPTION_URL": os.environ["XRAY_GATEWAY_SUBSCRIPTION_URL"],
    "USER_AGENT": os.environ["XRAY_GATEWAY_USER_AGENT"],
    "ACTIVE_PROFILE": os.environ["XRAY_GATEWAY_ACTIVE_PROFILE"],
    "TPROXY_PORT": os.environ["XRAY_GATEWAY_TPROXY_PORT"],
    "GATEWAY_IP": os.environ["XRAY_GATEWAY_GATEWAY_IP"],
    "LAN_IF": os.environ["XRAY_GATEWAY_LAN_IF"],
    "LAN_CIDR": os.environ["XRAY_GATEWAY_LAN_CIDR"],
    "ENABLE_TPROXY": os.environ["XRAY_GATEWAY_ENABLE_TPROXY"],
    "WEB_USERNAME": os.environ["XRAY_GATEWAY_WEB_USERNAME"],
    "WEB_PASSWORD": os.environ["XRAY_GATEWAY_WEB_PASSWORD"],
    "SESSION_SECRET": os.environ["XRAY_GATEWAY_SESSION_SECRET"] or secrets.token_hex(32),
}
if not re.fullmatch(r"[0-9a-fA-F]{64}", values["SESSION_SECRET"]):
    raise SystemExit("SESSION_SECRET должен содержать 64 hex-символа")
if values["ENABLE_TPROXY"].lower() not in ("true", "false", "1", "0", "yes", "no", "on", "off"):
    raise SystemExit("Некорректный ENABLE_TPROXY")
if not re.fullmatch(r"https://[A-Za-z0-9._~:/?%+=&-]+", values["SUBSCRIPTION_URL"]):
    raise SystemExit("SUBSCRIPTION_URL содержит неподдерживаемые символы")
if not re.fullmatch(r"[A-Za-z0-9._-]+", values["WEB_USERNAME"]):
    raise SystemExit("Недопустимый WEB_USERNAME")
if not re.fullmatch(r"[A-Za-z0-9._~!@%+=,-]{12,}", values["WEB_PASSWORD"]):
    raise SystemExit("Недопустимый WEB_PASSWORD")
tmp = p.with_name(".env.new")
tmp.write_text("".join(f"{k}={v}\n" for k, v in values.items()))
os.chmod(tmp, 0o600)
os.replace(tmp, p)
PYENV
chmod 600 .env
unset SUB_URL WEB_PASS WEB_PASS_CONFIRM XRAY_GATEWAY_SUBSCRIPTION_URL XRAY_GATEWAY_WEB_USERNAME XRAY_GATEWAY_WEB_PASSWORD XRAY_GATEWAY_GATEWAY_IP XRAY_GATEWAY_LAN_IF XRAY_GATEWAY_LAN_CIDR

log "Проверяю синтаксис Python"
python3 - <<'PYCHECK'
from pathlib import Path
files = [Path("gateway/app.py"), Path("gateway/node_checks.py"), Path("gateway/xray-gateway")]
for path in files:
    compile(path.read_text(encoding="utf-8"), str(path), "exec")
    print(f"  PASS {path}")
PYCHECK

log "Проверяю синтаксис shell-скриптов"
bash -n install.sh update.sh uninstall.sh host-network.sh tests/smoke.sh docker/entrypoint.sh docker/update-loop.sh

log "Проверяю Docker Compose"
docker compose config --quiet

log "Собираю Docker-образ"
docker compose build xray-gateway
IMAGE_REF="$(docker compose config --images | head -n1)"
[[ -n "$IMAGE_REF" ]] || die "Docker Compose не вернул имя собранного образа"
docker image inspect "$IMAGE_REF" >/dev/null 2>&1 || die "Собранный Docker-образ $IMAGE_REF не найден"

log "Запускаю container smoke test до замены рабочего контейнера"
bash tests/smoke.sh "$IMAGE_REF"

log "Проверяю реальную подписку и активный профиль до замены рабочего контейнера"
# Проверка выполняется во временной копии state: HWID и выбранный профиль
# сохраняются, но тестовая загрузка не меняет рабочие файлы state/.
if [[ ! -s state/hwid ]]; then
  python3 -c 'import uuid; print(uuid.uuid4())' > state/hwid
  chmod 600 state/hwid
fi
PREFLIGHT_STATE="$(mktemp -d)"
chmod 700 "$PREFLIGHT_STATE"
cp -a state/. "$PREFLIGHT_STATE/"
docker run --rm --network host \
  --env-file "$SCRIPT_DIR/.env" \
  -v "$PREFLIGHT_STATE:/var/lib/xray-gateway" \
  -v "$SCRIPT_DIR/.env:/etc/xray-gateway/.env:ro" \
  --entrypoint /usr/local/sbin/xray-gateway \
  "$IMAGE_REF" update

log "Реальная подписка и активный профиль прошли проверку"
log "Разворачиваю проверенный образ"
docker compose up -d --no-build

log "Проверяю запуск контейнера и служб"
CONTAINER_ID="$(docker compose ps -q xray-gateway)"
[[ -n "$CONTAINER_ID" ]] || die "Docker Compose не создал контейнер xray-gateway"
SERVICES_READY=0
for _ in $(seq 1 30); do
  CONTAINER_STATUS="$(docker inspect --format '{{.State.Status}}' "$CONTAINER_ID" 2>/dev/null || true)"
  if [[ "$CONTAINER_STATUS" == "running" ]]; then
    SERVICE_STATUS="$(docker exec "$CONTAINER_ID" supervisorctl status xray web 2>/dev/null || true)"
    if grep -qE '^xray[[:space:]]+RUNNING' <<<"$SERVICE_STATUS" && grep -qE '^web[[:space:]]+RUNNING' <<<"$SERVICE_STATUS"; then
      SERVICES_READY=1
      break
    fi
  elif [[ "$CONTAINER_STATUS" == "restarting" || "$CONTAINER_STATUS" == "exited" || "$CONTAINER_STATUS" == "dead" ]]; then
    break
  fi
  sleep 1
done
docker compose ps
if [[ "$SERVICES_READY" != "1" ]]; then
  docker compose logs --tail=150 xray-gateway || true
  die "Контейнер или службы Xray/Web UI не перешли в RUNNING. Установка не завершена."
fi

SERVER_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
SERVER_IP="${SERVER_IP:-SERVER-IP}"

# Читаем сохранённые реквизиты, в том числе при повторном запуске установщика.
WEB_USER="$(sed -n 's/^WEB_USERNAME=//p' .env | tail -n1)"
WEB_PASS="$(sed -n 's/^WEB_PASSWORD=//p' .env | tail -n1)"
[[ -n "$WEB_USER" && -n "$WEB_PASS" ]] || die "Не удалось прочитать реквизиты Web UI"

echo
log "Установка завершена"
echo "Web UI:  http://$SERVER_IP:8080"
echo "Логин:   $WEB_USER"
echo "Пароль:  $WEB_PASS"
warn "Сохраните пароль в менеджере паролей. Он также хранится в /opt/xray-gateway/.env с правами 600."
warn "Прозрачная маршрутизация (TPROXY) пока НЕ включена."
warn "Не направляй LAN-трафик через сервер, пока отдельно не проверим панель, подписку, профили и host-network.sh."
