#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
cd "$(dirname "$(readlink -f "$0")")"

XRAY_UNIT=xray-gateway.service
WEB_UNIT=xray-gateway-web.service
DATA_DIR="$PWD/data"
BACKUP_ROOT=/root
MIGRATING=0
XRAY_ACTIVE=no
WEB_ACTIVE=no
XRAY_ENABLED=no
WEB_ENABLED=no

die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "[migration] $*"; }
active(){ systemctl is-active --quiet "$1"; }
enabled(){ systemctl is-enabled "$1" 2>/dev/null | grep -qx enabled; }

rollback(){
  rc=$?
  if [[ "$MIGRATING" == 1 ]]; then
    log "Ошибка миграции. Останавливаю Docker-стек и возвращаю native-службы."
    if docker compose down >/dev/null 2>&1; then
      find "$DATA_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    else
      log "Не удалось остановить Docker-стек; каталог data сохранён для безопасности."
    fi
    if [[ "$XRAY_ENABLED" == yes ]]; then systemctl enable "$XRAY_UNIT" >/dev/null 2>&1 || true; else systemctl disable "$XRAY_UNIT" >/dev/null 2>&1 || true; fi
    if [[ "$WEB_ENABLED" == yes ]]; then systemctl enable "$WEB_UNIT" >/dev/null 2>&1 || true; else systemctl disable "$WEB_UNIT" >/dev/null 2>&1 || true; fi
    if [[ "$XRAY_ACTIVE" == yes ]]; then systemctl start "$XRAY_UNIT" || log "Не удалось автоматически запустить $XRAY_UNIT"; fi
    if [[ "$WEB_ACTIVE" == yes ]]; then systemctl start "$WEB_UNIT" || log "Не удалось автоматически запустить $WEB_UNIT"; fi
  fi
  exit "$rc"
}
trap rollback ERR INT TERM

[[ $(id -u) -eq 0 ]] || die "Запустите от root"
command -v docker >/dev/null || die "Docker не установлен"
docker compose version >/dev/null 2>&1 || die "Нужен Docker Compose v2"
command -v systemctl >/dev/null || die "systemd не найден"

for f in settings.conf hwid subscription.json config.json web-auth; do
  [[ -s "/etc/xray-gateway/$f" ]] || die "Не найден обязательный файл /etc/xray-gateway/$f"
done
systemctl cat "$XRAY_UNIT" >/dev/null 2>&1 || die "Не найдена native-служба $XRAY_UNIT"
systemctl cat "$WEB_UNIT" >/dev/null 2>&1 || die "Не найдена native-служба $WEB_UNIT"

if [[ -d "$DATA_DIR" ]] && find "$DATA_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
  die "$DATA_DIR не пустой. Миграция не будет перезаписывать существующие данные."
fi
mkdir -p "$DATA_DIR"
chmod 700 "$DATA_DIR"

STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="$BACKUP_ROOT/xray-gateway-native-$STAMP"
mkdir -m 700 "$BACKUP"
cp -a /etc/xray-gateway "$BACKUP/"
[[ ! -d /opt/xray-gateway-web ]] || cp -a /opt/xray-gateway-web "$BACKUP/"
mkdir -p "$BACKUP/systemd"
cp -a "/etc/systemd/system/$XRAY_UNIT" "$BACKUP/systemd/" 2>/dev/null || true
cp -a "/etc/systemd/system/$WEB_UNIT" "$BACKUP/systemd/" 2>/dev/null || true
log "Резервная копия native-установки: $BACKUP"

cp -a /etc/xray-gateway/. "$DATA_DIR/"
chmod 700 "$DATA_DIR"
chmod 600 "$DATA_DIR"/* 2>/dev/null || true
[[ -s "$DATA_DIR/hwid" ]] || die "HWID не перенесён"
cmp -s /etc/xray-gateway/hwid "$DATA_DIR/hwid" || die "HWID после копирования отличается"
cmp -s /etc/xray-gateway/subscription.json "$DATA_DIR/subscription.json" || die "Подписка после копирования отличается"
log "Данные перенесены без изменения HWID, подписки и активного состояния."

docker compose config --quiet
docker compose build

XRAY_ACTIVE=no; WEB_ACTIVE=no; XRAY_ENABLED=no; WEB_ENABLED=no
active "$XRAY_UNIT" && XRAY_ACTIVE=yes || true
active "$WEB_UNIT" && WEB_ACTIVE=yes || true
enabled "$XRAY_UNIT" && XRAY_ENABLED=yes || true
enabled "$WEB_UNIT" && WEB_ENABLED=yes || true

MIGRATING=1
systemctl stop "$WEB_UNIT" "$XRAY_UNIT"
docker compose up -d

for _ in $(seq 1 20); do
  XSTATUS=$(docker compose exec -T xray-gateway supervisorctl status xray 2>/dev/null || true)
  WSTATUS=$(docker compose exec -T xray-gateway supervisorctl status web 2>/dev/null || true)
  if [[ "$XSTATUS" == *RUNNING* && "$WSTATUS" == *RUNNING* ]]; then break; fi
  sleep 2
done
[[ "$XSTATUS" == *RUNNING* ]] || die "Xray в Docker не перешёл в RUNNING: $XSTATUS"
[[ "$WSTATUS" == *RUNNING* ]] || die "Web UI в Docker не перешёл в RUNNING: $WSTATUS"

docker compose exec -T xray-gateway /usr/local/bin/xray run -test -config /etc/xray-gateway/config.json
docker compose exec -T xray-gateway /usr/local/sbin/xray-gateway profiles >/dev/null
curl -fsS --max-time 5 -u "$(cat "$DATA_DIR/web-auth")" http://127.0.0.1:8080/api/status >/dev/null

systemctl disable "$XRAY_UNIT" "$WEB_UNIT" >/dev/null 2>&1 || true
MIGRATING=0
trap - ERR INT TERM
log "Миграция завершена. Docker Xray и Web UI работают."
log "Native-службы остановлены и отключены, но их файлы и резервная копия сохранены."
log "Backup: $BACKUP"
log "Проверка: docker compose exec xray-gateway supervisorctl status"
log "Для отката: docker compose down; systemctl enable $XRAY_UNIT $WEB_UNIT; systemctl start $XRAY_UNIT $WEB_UNIT"
log "Host TPROXY не включался. Его настраивают отдельно после проверки Docker-шлюза."
