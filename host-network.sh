#!/usr/bin/env bash
set -Eeuo pipefail

NAME=xray-gateway
TABLE=xray_gateway
ROUTE_TABLE=100
# Reserve only bit 0; preserve every other packet mark bit.
MARK=0x1
MARK_MASK=0x1
RULE_PREF=10000
INSTALL_PATH=/usr/local/sbin/xray-gateway-host-network
CONFIG=/etc/xray-gateway-host-network.conf
STATE=/var/lib/xray-gateway-host-network.state
UNIT=/etc/systemd/system/xray-gateway-host-network.service
DEFAULT_TPROXY_PORT=12345

log(){ echo "[xray-gateway-host-network] $*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
need_root(){ [[ $(id -u) -eq 0 ]] || die "Запустите от root"; }
have(){ command -v "$1" >/dev/null 2>&1 || die "Не найдена команда: $1"; }

normalize_port(){
  local raw="${1:-}" value
  [[ "$raw" =~ ^[0-9]+$ ]] || return 1
  value=$((10#$raw))
  (( value >= 1 && value <= 65535 )) || return 1
  printf '%s\n' "$value"
}

route_table_rule_exists(){
  local rules="${1:-}"
  grep -Eq "(lookup|table)[[:space:]]+${ROUTE_TABLE}([[:space:]]|$)" <<<"$rules"
}

apply_rules(){
  [[ -r "$CONFIG" ]] || die "Нет конфигурации $CONFIG"
  # shellcheck disable=SC1090
  source "$CONFIG"
  local normalized_port
  normalized_port="$(normalize_port "${TPROXY_PORT:-}")" || die "Некорректный TPROXY_PORT в $CONFIG"
  TPROXY_PORT="$normalized_port"
  ip link show dev "$LAN_IF" >/dev/null 2>&1 || die "Интерфейс $LAN_IF не существует"

  if nft list table inet "$TABLE" >/dev/null 2>&1; then
    die "Таблица nftables inet $TABLE уже существует. Не трогаю существующие правила."
  fi
  if ip -4 rule show | grep -Eq "^[[:space:]]*$RULE_PREF:"; then
    die "Priority $RULE_PREF уже занят в ip rule. Не трогаю существующую маршрутизацию."
  fi
  if route_table_rule_exists "$(ip -4 rule show)"; then
    die "Таблица маршрутизации $ROUTE_TABLE уже используется существующим ip rule."
  fi
  if ip -4 route show table "$ROUTE_TABLE" | grep -q .; then
    die "Таблица маршрутизации $ROUTE_TABLE уже содержит маршруты. Не трогаю существующую маршрутизацию."
  fi

  log "Ожидаю Xray TPROXY listener на порту $TPROXY_PORT..."
  local ready=no
  for _ in $(seq 1 30); do
    if ss -H -lnutp 2>/dev/null | grep -Eq ":${TPROXY_PORT}[[:space:]]"; then ready=yes; break; fi
    sleep 2
  done
  [[ "$ready" == yes ]] || die "На порту $TPROXY_PORT нет listener Xray. Правила не установлены."

  local ALL_RPF IF_RPF
  ALL_RPF="$(sysctl -n net.ipv4.conf.all.rp_filter)"
  IF_RPF="$(sysctl -n "net.ipv4.conf.$LAN_IF.rp_filter")"
  printf 'ALL_RPF=%q\nIF_RPF=%q\nLAN_IF=%q\n' "$ALL_RPF" "$IF_RPF" "$LAN_IF" > "$STATE"
  chmod 600 "$STATE"

  rollback_on_error(){
    local rc="${1:-1}"
    trap - ERR INT TERM HUP
    log "Ошибка/прерывание; выполняю откат host-network."
    nft delete table inet "$TABLE" >/dev/null 2>&1 || true
    ip -4 rule del priority "$RULE_PREF" fwmark "$MARK"/"$MARK_MASK" lookup "$ROUTE_TABLE" >/dev/null 2>&1 || true
    ip -4 route del local 0.0.0.0/0 dev lo table "$ROUTE_TABLE" >/dev/null 2>&1 || true
    sysctl -q -w "net.ipv4.conf.all.rp_filter=$ALL_RPF" || true
    sysctl -q -w "net.ipv4.conf.$LAN_IF.rp_filter=$IF_RPF" || true
    rm -f "$STATE"
    return 0
  }
  trap 'rc=$?; rollback_on_error "$rc"; exit "$rc"' ERR
  trap 'rollback_on_error 130; exit 130' INT
  trap 'rollback_on_error 143; exit 143' TERM
  trap 'rollback_on_error 129; exit 129' HUP

  sysctl -q -w net.ipv4.conf.all.rp_filter=0
  sysctl -q -w "net.ipv4.conf.$LAN_IF.rp_filter=0"
  ip -4 route add local 0.0.0.0/0 dev lo table "$ROUTE_TABLE"
  ip -4 rule add priority "$RULE_PREF" fwmark "$MARK"/"$MARK_MASK" lookup "$ROUTE_TABLE"

  nft -f - <<NFT
table inet $TABLE {
  chain prerouting {
    type filter hook prerouting priority mangle; policy accept;
    iifname "$LAN_IF" fib daddr type local return
    # IPv6 is deliberately fail-closed until a native IPv6 TPROXY path is implemented.
    iifname "$LAN_IF" meta nfproto ipv6 drop
    iifname "$LAN_IF" ip daddr $LAN_CIDR return
    iifname "$LAN_IF" ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 } return
    iifname "$LAN_IF" ip saddr $LAN_CIDR meta nfproto ipv4 meta l4proto { tcp, udp } tproxy to :$TPROXY_PORT meta mark set meta mark | $MARK accept
  }
}
NFT
  trap - ERR INT TERM HUP
  log "TPROXY включён: LAN=$LAN_IF, CIDR=$LAN_CIDR, порт=$TPROXY_PORT, mark=$MARK/$MARK_MASK, table=$ROUTE_TABLE"
  log "Локальные/RFC1918/служебные IPv4 назначения исключены из перехвата."
  log "IPv6 с LAN блокируется, кроме трафика к локальным адресам самого шлюза."
}

remove_rules(){
  if [[ -f "$STATE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE"
    nft delete table inet "$TABLE" >/dev/null 2>&1 || true
    ip -4 rule del priority "$RULE_PREF" fwmark "$MARK"/"$MARK_MASK" lookup "$ROUTE_TABLE" >/dev/null 2>&1 || true
    ip -4 route del local 0.0.0.0/0 dev lo table "$ROUTE_TABLE" >/dev/null 2>&1 || true
    sysctl -q -w "net.ipv4.conf.all.rp_filter=$ALL_RPF" || true
    sysctl -q -w "net.ipv4.conf.$LAN_IF.rp_filter=$IF_RPF" || true
    rm -f "$STATE"
    log "Правила проекта удалены, rp_filter восстановлен."
  else
    log "Состояние не найдено; удалять нечего."
  fi
}

install_service(){
  need_root
  have ip; have ss; have nft; have sysctl; have systemctl; have python3
  local lan_if="${1:-}" lan_cidr="${2:-}"
  if [[ -z "$lan_if" ]]; then read -r -p "LAN interface (например br0): " lan_if; fi
  if [[ -z "$lan_cidr" ]]; then read -r -p "LAN CIDR (например 192.168.12.0/24): " lan_cidr; fi
  [[ "$lan_if" =~ ^[a-zA-Z0-9_.:-]+$ ]] || die "Некорректное имя интерфейса"
  ip link show dev "$lan_if" >/dev/null 2>&1 || die "Интерфейс $lan_if не существует"
  local lan_addrs
  lan_addrs="$(ip -4 -o addr show dev "$lan_if" | awk '{print $4}')"
  python3 - "$lan_cidr" "$lan_addrs" <<'PY'
import ipaddress,sys
network=ipaddress.ip_network(sys.argv[1], strict=False)
if network.version != 4:
    raise SystemExit("Поддерживается только IPv4 LAN CIDR")
addresses=[ipaddress.ip_interface(x).ip for x in sys.argv[2].split() if x]
if not addresses:
    raise SystemExit("На выбранном интерфейсе нет IPv4-адреса")
if not any(address in network for address in addresses):
    raise SystemExit("LAN CIDR не совпадает ни с одним IPv4-адресом выбранного интерфейса")
PY
  local tproxy_port="$DEFAULT_TPROXY_PORT"
  local project_env="$(cd -- "$(dirname -- "$0")" && pwd)/.env"
  if [[ -f "$project_env" ]]; then
    tproxy_port="$(awk -F= '/^[[:space:]]*TPROXY_PORT[[:space:]]*=/ {sub(/^[^=]*=/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); value=$0} END {if (value != "") print value}' "$project_env")"
    tproxy_port="${tproxy_port:-$DEFAULT_TPROXY_PORT}"
  fi
  tproxy_port="$(normalize_port "$tproxy_port")" || die "Некорректный TPROXY_PORT в .env"
  [[ ! -e "$CONFIG" ]] || die "$CONFIG уже существует; сначала проверьте текущую конфигурацию"
  [[ ! -e "$UNIT" && ! -e "$INSTALL_PATH" ]] || die "Установка host-network уже существует; сначала проверьте её состояние"

  printf 'LAN_IF=%q\nLAN_CIDR=%q\nTPROXY_PORT=%q\n' "$lan_if" "$lan_cidr" "$tproxy_port" > "$CONFIG"
  chmod 600 "$CONFIG"
  install -m 0755 "$0" "$INSTALL_PATH"
  cat > "$UNIT" <<EOF
[Unit]
Description=Xray Gateway host TPROXY policy routing
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$INSTALL_PATH apply
ExecStop=$INSTALL_PATH remove
TimeoutStartSec=75
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  if ! systemctl enable --now "$NAME-host-network.service"; then
    log "Установка systemd-службы не удалась; удаляю созданные файлы."
    systemctl disable --now "$NAME-host-network.service" >/dev/null 2>&1 || true
    remove_rules
    rm -f "$UNIT" "$CONFIG" "$STATE" "$INSTALL_PATH"
    systemctl daemon-reload
    die "Не удалось включить $NAME-host-network.service; установка отменена."
  fi
  log "Установлено и включено автоприменение после перезагрузки."
  log "Проверка: nft list table inet $TABLE; ip rule show; ip route show table $ROUTE_TABLE"
}

remove_installation(){
  need_root
  if systemctl is-active --quiet "$NAME-host-network.service"; then
    systemctl stop "$NAME-host-network.service" || true
  else
    remove_rules
  fi
  systemctl disable "$NAME-host-network.service" >/dev/null 2>&1 || true
  rm -f "$UNIT" "$CONFIG" "$STATE"
  systemctl daemon-reload
  rm -f "$INSTALL_PATH"
  log "Автозапуск TPROXY удалён."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  need_root
  case "${1:-}" in
    install) shift; install_service "${1:-}" "${2:-}" ;;
    apply) apply_rules ;;
    remove) remove_rules ;;
    uninstall) remove_installation ;;
    *) echo "Usage: bash host-network.sh install [LAN_IF] [LAN_CIDR] | apply | remove | uninstall"; exit 2 ;;
  esac
fi
