#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/VaZeR-nhk/xray-gateway.git"
PROJECT_DIR="/opt/xray-gateway"
BRANCH="main"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log(){ echo -e "${GREEN}[+]$NC $*"; }
warn(){ echo -e "${YELLOW}[!]$NC $*" >&2; }
die(){ echo -e "${RED}[ERROR]$NC $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "Запусти команду от root."
[[ -r /etc/os-release ]] || die "Не найден /etc/os-release"
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "debian" ]] || die "Поддерживается Debian 12/13. Обнаружено: ${PRETTY_NAME:-unknown}"
case "${VERSION_ID:-}" in 12|13) ;; *) die "Поддерживается Debian 12 или 13." ;; esac

export DEBIAN_FRONTEND=noninteractive
if ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  log "Устанавливаю Git, curl и сертификаты"
  apt-get update
  apt-get install -y --no-install-recommends git curl ca-certificates
fi

mkdir -p /opt
if [[ -d "$PROJECT_DIR/.git" ]]; then
  cd "$PROJECT_DIR"
  ORIGIN="$(git remote get-url origin 2>/dev/null || true)"
  case "$ORIGIN" in
    "$REPO_URL"|"https://github.com/VaZeR-nhk/xray-gateway") ;;
    *) die "В $PROJECT_DIR найден Git-репозиторий с другим origin: $ORIGIN. Ничего не изменено." ;;
  esac
  if ! git diff --quiet || ! git diff --cached --quiet; then
    die "В репозитории есть локальные изменения. Сначала сохраните их или отмените; автоматический reset запрещён."
  fi
  log "Обновляю проект из origin/$BRANCH (файлы .env и data сохраняются)"
  git fetch origin "$BRANCH"
  git pull --ff-only origin "$BRANCH"
elif [[ -e "$PROJECT_DIR" ]]; then
  die "$PROJECT_DIR уже существует, но это не Git-клон проекта. Ничего не удаляю. Переименуй каталог вручную после резервного копирования."
else
  log "Клонирую проект в $PROJECT_DIR"
  git clone --branch "$BRANCH" --single-branch "$REPO_URL" "$PROJECT_DIR"
fi

cd "$PROJECT_DIR"
[[ -f install.sh && -f docker-compose.yml && -f Dockerfile ]] || die "В каталоге проекта отсутствуют обязательные файлы."
chmod +x install.sh bootstrap.sh tests/smoke.sh
exec bash ./install.sh
