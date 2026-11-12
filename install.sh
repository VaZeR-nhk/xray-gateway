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

mkdir -p data
chmod 700 data

# Запрашиваем URL при каждом запуске установщика. Enter оставляет текущий URL.
echo
if [[ -s data/settings.conf ]]; then
  read -r -p "Remnawave subscription URL (HTTPS; Enter — оставить текущую): " SUB_URL
  if [[ -z "$SUB_URL" ]]; then
    SUB_URL="$(sed -n 's/^SUBSCRIPTION_URL=//p' data/settings.conf | head -n1)"
  fi
else
  read -r -p "Remnawave subscription URL (HTTPS, ввод отображается): " SUB_URL
fi
[[ "$SUB_URL" == https://* ]] || die "Нужен HTTPS URL подписки"
[[ "$SUB_URL" != *[[:space:]]* ]] || die "URL не должен содержать пробелы или управляющие символы"

export XRAY_GATEWAY_SUBSCRIPTION_URL="$SUB_URL"
python3 - <<'PYSETTINGS'
import os, pathlib, tempfile
p=pathlib.Path("data/settings.conf")
value=os.environ["XRAY_GATEWAY_SUBSCRIPTION_URL"]
lines=p.read_text().splitlines() if p.exists() else []
out=[]; found=False
for line in lines:
    if line.startswith("SUBSCRIPTION_URL="):
        out.append("SUBSCRIPTION_URL="+value); found=True
    else:
        out.append(line)
if not found: out.insert(0,"SUBSCRIPTION_URL="+value)
for key, default in (("USER_AGENT","Happ"),("ACTIVE_PROFILE","0"),("TPROXY_PORT","12345"),("GATEWAY_IP","0.0.0.0")):
    if not any(x.startswith(key+"=") for x in out): out.append(key+"="+default)
fd,tmp=tempfile.mkstemp(dir="data",prefix="settings.")
with os.fdopen(fd,"w") as f:
    f.write("\n".join(out)+"\n")
os.chmod(tmp,0o600)
os.replace(tmp,p)
PYSETTINGS
unset SUB_URL XRAY_GATEWAY_SUBSCRIPTION_URL
if [[ ! -s data/web-auth ]]; then
  echo
  while true; do
    read -r -p "Web UI username [admin]: " WEB_USER
    WEB_USER="${WEB_USER:-admin}"
    if [[ "$WEB_USER" != *:* && -n "$WEB_USER" ]]; then
      break
    fi
    warn "Имя пользователя не должно быть пустым или содержать двоеточие. Повтори ввод."
  done

  read -r -p "Сгенерировать пароль автоматически? [y/N]: " GENERATE_PASSWORD
  case "${GENERATE_PASSWORD,,}" in
    y|yes|д|да)
      # 24 случайных байта в hex: 48 символов, безопасных для basic-auth.
      WEB_PASS="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
      [[ "${#WEB_PASS}" -eq 48 ]] || die "Не удалось сгенерировать пароль"
      log "Сгенерирован случайный пароль длиной 48 символов"
      ;;
    *)
      while true; do
        # Пароль отображается при вводе — ввод не скрывается.
        read -r -p "Web UI password (min 12 chars): " WEB_PASS
        if [[ "${#WEB_PASS}" -lt 12 ]]; then
          warn "Пароль должен содержать не менее 12 символов. Повтори ввод."
          continue
        fi

        read -r -p "Повтори пароль: " WEB_PASS_CONFIRM
        if [[ "$WEB_PASS" != "$WEB_PASS_CONFIRM" ]]; then
          warn "Пароли не совпадают. Начни ввод пароля заново."
          continue
        fi
        break
      done
      ;;
  esac

  printf '%s:%s\n' "$WEB_USER" "$WEB_PASS" > data/web-auth
  chmod 600 data/web-auth
  unset WEB_PASS_CONFIRM
else
  log "Найден data/web-auth — сохраняю существующую авторизацию панели"
fi

if [[ ! -f .env ]]; then
  printf 'XRAY_VERSION=26.11.9\n' > .env
fi

log "Переношу все секреты и параметры в единый .env"
bash configure-env.sh

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
warn "Сохраните пароль в менеджере паролей. Он также хранится в /opt/xray-gateway/data/web-auth с правами 600."
warn "Прозрачная маршрутизация (TPROXY) пока НЕ включена."
warn "Не направляй LAN-трафик через сервер, пока отдельно не проверим панель, подписку, профили и host-network.sh."
