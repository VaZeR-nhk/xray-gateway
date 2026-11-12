#!/usr/bin/env bash
set -Eeuo pipefail

NAME=xray-gateway
TABLE=xray_gateway
ROUTE_TABLE=100
MARK=0x1
RULE_PREF=10000
INSTALL_PATH=/usr/local/sbin/xray-gateway-host-network
CONFIG=/etc/xray-gateway-host-network.conf
STATE=/var/lib/xray-gateway-host-network.state
UNIT=/etc/systemd/system/xray-gateway-host-network.service

log(){ echo "[xray-gateway-host-network] $*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
need_root(){ [[ $(id -u) -eq 0 ]] || die "Запустите от root"; }
have(){ command -v "$1" >/dev/null 2>&1 || die "Не найдена команда: $1"; }

apply_rules(){
  [[ -r "$CONFIG" ]] || die "Нет конфигурации $CONFIG"
  # shellcheck disable=SC1090
  source "$CONFIG"
  ip link show dev "$LAN_IF" >/dev/null 2>&1 || die "Интерфейс $LAN_IF не существует"
  if nft list table inet "$TABLE" >/dev/null 2>&1; then
    die "Таблица nftables inet $TABLE уже существует. Не трогаю существующие правила."
  fi
  if ip rule show | grep -Eq "^[[:space:]]*$RULE_PREF:.*fwmark $MARK(/0x1)?.*lookup $ROUTE_TABLE"; then
    die "Правило ip rule с priority $RULE_PREF уже существует. Не трогаю его."
  fi
  if ip route show table "$ROUTE_TABLE" | grep -q .; then
    die "Таблица маршрутизации $ROUTE_TABLE уже содержит маршруты. Выберите другую таблицу или разберите конфликт вручную."
  fi

  ALL_RPF=$(sysctl -n net.ipv4.conf.all.rp_filter)
  IF_RPF=$(sysctl -n "net.ipv4.conf.$LAN_IF.rp_filter")
  printf 'ALL_RPF=%q\nIF_RPF=%q\nLAN_IF=%q\n' "$ALL_RPF" "$IF_RPF" "$LAN_IF" > "$STATE"
  chmod 600 "$STATE"

  rollback_on_error(){
    nft delete table inet "$TABLE" >/dev/null 2>&1 || true
    ip rule del priority "$RULE_PREF" fwmark "$MARK"/0x1 lookup "$ROUTE_TABLE" >/dev/null 2>&1 || true
    ip route flush table "$ROUTE_TABLE" >/dev/null 2>&1 || true
    sysctl -q -w "net.ipv4.conf.all.rp_filter=$ALL_RPF" || true
    sysctl -q -w "net.ipv4.conf.$LAN_IF.rp_filter=$IF_RPF" || true
    rm -f "$STATE"
  }
  trap rollback_on_error ERR

  sysctl -q -w net.ipv4.conf.all.rp_filter=0
  sysctl -q -w "net.ipv4.conf.$LAN_IF.rp_filter=0"
  ip route add local 0.0.0.0/0 dev lo table "$ROUTE_TABLE"
  ip rule add priority "$RULE_PREF" fwmark "$MARK"/0x1 lookup "$ROUTE_TABLE"

  nft -f - <<NFT
table inet $TABLE {
  chain prerouting {
    type filter hook prerouting priority mangle; policy accept;
    iifname "$LAN_IF" ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 } return
    iifname "$LAN_IF" meta l4proto { tcp, udp } tproxy to :12345 meta mark set $MARK accept
  }
}
NFT
  trap - ERR
  log "TPROXY включён: LAN=$LAN_IF, CIDR=$LAN_CIDR, порт=12345, mark=$MARK, table=$ROUTE_TABLE"
  log "Локальные/RFC1918/служебные IPv4 назначения исключены из перехвата."
}

remove_rules(){
  if [[ -f "$STATE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE"
    nft delete table inet "$TABLE" >/dev/null 2>&1 || true
    ip rule del priority "$RULE_PREF" fwmark "$MARK"/0x1 lookup "$ROUTE_TABLE" >/dev/null 2>&1 || true
    ip route flush table "$ROUTE_TABLE" >/dev/null 2>&1 || true
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
  have ip; have nft; have sysctl; have systemctl; have python3
  local lan_if="${1:-}" lan_cidr="${2:-}"
  if [[ -z "$lan_if" ]]; then read -r -p "LAN interface (например br0): " lan_if; fi
  if [[ -z "$lan_cidr" ]]; then read -r -p "LAN CIDR (например 192.168.12.0/24): " lan_cidr; fi
  [[ "$lan_if" =~ ^[a-zA-Z0-9_.:-]+$ ]] || die "Некорректное имя интерфейса"
  ip link show dev "$lan_if" >/dev/null 2>&1 || die "Интерфейс $lan_if не существует"
  python3 - "$lan_cidr" <<'PY'
import ipaddress,sys
n=ipaddress.ip_network(sys.argv[1], strict=False)
if n.version != 4: raise SystemExit("Поддерживается только IPv4 LAN CIDR")
PY
  if [[ -e "$CONFIG" ]]; then die "$CONFIG уже существует; сначала проверьте текущую конфигурацию"; fi
  printf 'LAN_IF=%q\nLAN_CIDR=%q\n' "$lan_if" "$lan_cidr" > "$CONFIG"
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
TimeoutStartSec=30
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$NAME-host-network.service"
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
  if [[ "$0" == "$INSTALL_PATH" ]]; then
    rm -f "$INSTALL_PATH"
  fi
  log "Автозапуск TPROXY удалён."
}

need_root
case "${1:-}" in
  install) shift; install_service "${1:-}" "${2:-}" ;;
  apply) apply_rules ;;
  remove) remove_rules ;;
  uninstall) remove_installation ;;
  *) echo "Usage: bash host-network.sh install [LAN_IF] [LAN_CIDR] | apply | remove | uninstall"; exit 2 ;;
esac
