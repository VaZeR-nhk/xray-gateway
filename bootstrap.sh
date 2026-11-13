#!/usr/bin/env bash
set -Eeuo pipefail
REPO_URL="https://github.com/VaZeR-nhk/xray-gateway.git"
PROJECT_DIR="/opt/xray-gateway"
BRANCH="main"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
log(){ echo -e "$GREEN[+]$NC $*"; }
die(){ echo -e "$RED[ERROR]$NC $*" >&2; exit 1; }
[[ "$(id -u)" -eq 0 ]] || die "Запусти команду от root."
[[ -r /etc/os-release ]] || die "Не найден /etc/os-release"
. /etc/os-release
[[ "$ID" == "debian" ]] || die "Поддерживается Debian 12/13. Обнаружено: $PRETTY_NAME"
case "$VERSION_ID" in 12|13) ;; *) die "Поддерживается Debian 12 или 13." ;; esac
export DEBIAN_FRONTEND=noninteractive
if ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || ! dpkg -s ca-certificates >/dev/null 2>&1; then
  log "Устанавливаю Git, curl и сертификаты"
  apt-get update
  apt-get install -y --no-install-recommends git curl ca-certificates
fi
mkdir -p /opt
if [[ -d "$PROJECT_DIR/.git" ]]; then
  cd "$PROJECT_DIR"
  ORIGIN="$(git remote get-url origin 2>/dev/null || true)"
  case "$ORIGIN" in "$REPO_URL"|"https://github.com/VaZeR-nhk/xray-gateway") ;; *) die "Обнаружен другой origin: $ORIGIN. Ничего не изменено." ;; esac
  if ! git diff --quiet || ! git diff --cached --quiet; then die "Есть локальные изменения. Сначала сохраните или отмените их; reset не выполняется."; fi
  CURRENT_BRANCH="$(git branch --show-current)"
  [[ "$CURRENT_BRANCH" == "$BRANCH" ]] || die "Текущая ветка $CURRENT_BRANCH, ожидалась $BRANCH."
  log "Обновляю публичный проект"
  git fetch origin "$BRANCH"
  git pull --ff-only origin "$BRANCH"
elif [[ -e "$PROJECT_DIR" ]]; then
  die "$PROJECT_DIR существует, но не является Git-клоном проекта. Ничего не удаляю."
else
  log "Клонирую публичный проект"
  git clone --branch "$BRANCH" --single-branch "$REPO_URL" "$PROJECT_DIR"
fi
cd "$PROJECT_DIR"
[[ -f install.sh && -f docker-compose.yml && -f Dockerfile ]] || die "Отсутствуют обязательные файлы."
chmod +x install.sh bootstrap.sh tests/smoke.sh
bash ./install.sh
