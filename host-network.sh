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

valid_rp_filter(){
  [[ "${1:-}" =~ ^[012]$ ]]
}

read_rp_filter(){
  local key="$1" value
  value="$(sysctl -n "$key" 2>/dev/null)" || die "Не удалось прочитать $key"
  valid_rp_filter "$value" || die "Неожиданное значение $key=$value (ожидалось 0, 1 или 2)"
  printf '%s\n' "$value"
}

save_rp_filter_state(){
  local all_rpf default_rpf if_rpf tmp path iface value index=0
  all_rpf="$(read_rp_filter net.ipv4.conf.all.rp_filter)"
  default_rpf="$(read_rp_filter net.ipv4.conf.default.rp_filter)"
  if_rpf="$(read_rp_filter "net.ipv4.conf.$LAN_IF.rp_filter")"
  tmp="$STATE.tmp"
  umask 077
  {
    printf 'STATE_VERSION=1\nALL_RPF=%q\nDEFAULT_RPF=%q\nIF_RPF=%q\nLAN_IF=%q\n' \
      "$all_rpf" "$default_rpf" "$if_rpf" "$LAN_IF"
    for path in /proc/sys/net/ipv4/conf/*/rp_filter; do
      [[ -r "$path" ]] || continue
      iface="${path%/rp_filter}"; iface="${iface##*/}"
      [[ "$iface" != "all" && "$iface" != "default" ]] || continue
      value="$(cat "$path")"
      valid_rp_filter "$value" || die "Неожиданное значение rp_filter для интерфейса $iface: $value"
      printf 'IFACE_%d=%q\nIFACE_RPF_%d=%q\n' "$index" "$iface" "$index" "$value"
      index=$((index+1))
    done
    printf 'IFACE_COUNT=%q\n' "$index"
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$STATE"
  log "Сохранён rp_filter: all=$all_rpf, default=$default_rpf, $LAN_IF=$if_rpf; интерфейсов=$index"
  log "default не изменяется. Эффективный режим остальных интерфейсов будет сохранён."
}

restore_rp_filter_state(){
  [[ -r "$STATE" ]] || return 0
  # shellcheck disable=SC1090
  source "$STATE"
  [[ "${STATE_VERSION:-}" == "1" ]] || { log "Неизвестная версия состояния sysctl"; return 1; }
  valid_rp_filter "${ALL_RPF:-}" || { log "Повреждено ALL_RPF"; return 1; }
  valid_rp_filter "${DEFAULT_RPF:-}" || { log "Повреждено DEFAULT_RPF"; return 1; }
  valid_rp_filter "${IF_RPF:-}" || { log "Повреждено IF_RPF"; return 1; }
  [[ "${LAN_IF:-}" =~ ^[a-zA-Z0-9_.:-]+$ ]] || { log "Повреждено LAN_IF"; return 1; }
  [[ "${IFACE_COUNT:-}" =~ ^[0-9]+$ ]] || { log "Поврежден IFACE_COUNT"; return 1; }
  local i name_var value_var iface value
  # Restore per-interface values first, then the global all value.
  for ((i=0; i<IFACE_COUNT; i++)); do
    name_var="IFACE_$i"; value_var="IFACE_RPF_$i"
    iface="${!name_var:-}"; value="${!value_var:-}"
    [[ "$iface" =~ ^[a-zA-Z0-9_.:-]+$ ]] || { log "Повреждено имя интерфейса в state"; return 1; }
    valid_rp_filter "$value" || { log "Поврежден rp_filter в state для $iface"; return 1; }
    if [[ -e "/proc/sys/net/ipv4/conf/$iface/rp_filter" ]]; then
      sysctl -q -w "net.ipv4.conf.$iface.rp_filter=$value" || { log "Не удалось восстановить rp_filter для $iface"; return 1; }
    else
      log "Интерфейс $iface исчез; его sysctl пропущен."
    fi
  done
  sysctl -q -w "net.ipv4.conf.all.rp_filter=$ALL_RPF" || { log "Не удалось восстановить net.ipv4.conf.all.rp_filter"; return 1; }
  rm -f "$STATE"
  log "Исходные значения rp_filter восстановлены; default не изменялся."
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
    if ss -H -lnutp 2>/dev/null | grep -Eq "(^|[[:space:]])(${GATEWAY_IP}|0\\.0\\.0\\.0|\\*):${TPROXY_PORT}([[:space:]]|$)"; then ready=yes; break; fi
    sleep 2
  done
  [[ "$ready" == yes ]] || die "На порту $TPROXY_PORT нет listener Xray. Правила не установлены."

  [[ ! -e "$STATE" ]] || die "Найден файл состояния $STATE; сначала проверьте предыдущую установку/откат."
  save_rp_filter_state

  rollback_on_error(){
    local rc="${1:-1}"
    trap - ERR INT TERM HUP
    log "Ошибка/прерывание; выполняю откат host-network."
    nft delete table inet "$TABLE" >/dev/null 2>&1 || true
    ip -4 rule del priority "$RULE_PREF" fwmark "$MARK"/"$MARK_MASK" lookup "$ROUTE_TABLE" >/dev/null 2>&1 || true
    ip -4 route del local 0.0.0.0/0 dev lo table "$ROUTE_TABLE" >/dev/null 2>&1 || true
    restore_rp_filter_state || log "ВНИМАНИЕ: не удалось восстановить rp_filter; состояние оставлено в $STATE"
    return 0
  }
  trap 'rc=$?; rollback_on_error "$rc"; exit "$rc"' ERR
  trap 'rollback_on_error 130; exit 130' INT
  trap 'rollback_on_error 143; exit 143' TERM
  trap 'rollback_on_error 129; exit 129' HUP

  # Preserve the effective rp_filter mode on every non-LAN interface:
  # lowering conf.all changes the max(conf/all, conf/interface) calculation.
  local i name_var value_var iface value
  for ((i=0; i<IFACE_COUNT; i++)); do
    name_var="IFACE_$i"; value_var="IFACE_RPF_$i"
    iface="${!name_var}"; value="${!value_var}"
    if [[ "$iface" != "$LAN_IF" && "$iface" != "all" && "$iface" != "default" ]] && (( value < ALL_RPF )); then
      sysctl -q -w "net.ipv4.conf.$iface.rp_filter=$ALL_RPF"
    fi
  done
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
    restore_rp_filter_state || die "Не удалось восстановить rp_filter; состояние сохранено в $STATE"
    log "Правила проекта удалены; исходный rp_filter восстановлен."
  else
    log "Состояние не найдено; удалять нечего."
  fi
}

install_service(){
  need_root
  have ip; have ss; have nft; have sysctl; have systemctl; have python3
  local lan_if="${1:-}" lan_cidr="${2:-}" listen_ip="${3:-}"
  local project_env="$(cd -- "$(dirname -- "$0")" && pwd)/.env"
  if [[ -f "$project_env" ]]; then
    local env_lan_if env_lan_cidr env_gateway_ip
    env_lan_if="$(awk -F= '$1=="LAN_IF"{print $2}' "$project_env" | tail -n1)"
    env_lan_cidr="$(awk -F= '$1=="LAN_CIDR"{print $2}' "$project_env" | tail -n1)"
    env_gateway_ip="$(awk -F= '$1=="GATEWAY_IP"{print $2}' "$project_env" | tail -n1)"
    lan_if="${lan_if:-$env_lan_if}"
    lan_cidr="${lan_cidr:-$env_lan_cidr}"
    listen_ip="${listen_ip:-$env_gateway_ip}"
  fi
  if [[ -z "$lan_if" ]]; then
    echo "Доступные IPv4-интерфейсы:"
    ip -o -4 addr show scope global | awk '{printf "  %-16s %s\\n", $2, $4}'
    read -r -p "LAN interface: " lan_if
  fi
  [[ "$lan_if" =~ ^[a-zA-Z0-9_.:-]+$ ]] || die "Некорректное имя интерфейса"
  ip link show dev "$lan_if" >/dev/null 2>&1 || die "Интерфейс $lan_if не существует"
  local lan_addrs
  lan_addrs="$(ip -4 -o addr show scope global dev "$lan_if" | awk '{print $4}')"
  [[ -n "$lan_addrs" ]] || die "На интерфейсе $lan_if нет глобального IPv4-адреса"
  if [[ -z "$lan_cidr" ]]; then
    local default_cidr
    default_cidr="$(awk '{print $1; exit}' <<<"$lan_addrs")"
    read -r -p "LAN CIDR [$default_cidr]: " input_cidr
    lan_cidr="${input_cidr:-$default_cidr}"
  fi
  if [[ -z "$listen_ip" || "$listen_ip" == "0.0.0.0" ]]; then
    local default_ip
    default_ip="${lan_addrs%% *}"; default_ip="${default_ip%%/*}"
    read -r -p "Xray listen IPv4 [$default_ip]: " input_ip
    listen_ip="${input_ip:-$default_ip}"
  fi
  python3 - "$lan_cidr" "$lan_addrs" "$listen_ip" <<'PY'
import ipaddress,sys
network=ipaddress.ip_network(sys.argv[1], strict=False)
if network.version != 4: raise SystemExit("Поддерживается только IPv4 LAN CIDR")
addresses=[ipaddress.ip_interface(x).ip for x in sys.argv[2].split() if x]
listen=ipaddress.ip_address(sys.argv[3])
if not any(address in network for address in addresses): raise SystemExit("LAN CIDR не совпадает ни с одним IPv4-адресом выбранного интерфейса")
if listen not in addresses: raise SystemExit("Xray listen IP должен быть назначен выбранному LAN-интерфейсу")
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

  printf 'LAN_IF=%q\nLAN_CIDR=%q\nGATEWAY_IP=%q\nTPROXY_PORT=%q\n' "$lan_if" "$lan_cidr" "$listen_ip" "$tproxy_port" > "$CONFIG"
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
  log "Параметры: LAN=$lan_if, CIDR=$lan_cidr, Xray listen=$listen_ip:$tproxy_port."
  log "Проверка: nft list table inet $TABLE; ip rule show; ip route show table $ROUTE_TABLE"
}

diagnose(){
  need_root
  have ip; have ss; have nft; have sysctl
  local project_env="$(cd -- "$(dirname -- "$0")" && pwd)/.env"
  local lan_if="${1:-}" lan_cidr="${2:-}" gateway_ip="${3:-}" tproxy_port="${4:-}"
  if [[ -z "$lan_if" && -f "$project_env" ]]; then
    lan_if="$(awk -F= '$1=="LAN_IF"{print $2}' "$project_env" | tail -n1)"
    lan_cidr="$(awk -F= '$1=="LAN_CIDR"{print $2}' "$project_env" | tail -n1)"
    gateway_ip="$(awk -F= '$1=="GATEWAY_IP"{print $2}' "$project_env" | tail -n1)"
    tproxy_port="$(awk -F= '$1=="TPROXY_PORT"{print $2}' "$project_env" | tail -n1)"
  fi
  tproxy_port="$(normalize_port "${tproxy_port:-$DEFAULT_TPROXY_PORT}")" || die "Некорректный TPROXY_PORT"
  [[ -n "$lan_if" ]] || die "LAN_IF не задан; укажите интерфейс или заполните .env"
  ip link show dev "$lan_if" >/dev/null 2>&1 || die "Интерфейс $lan_if не существует"
  echo "===== Xray Gateway host-network preflight (read-only) ====="
  echo "LAN_IF=$lan_if LAN_CIDR=${lan_cidr:-unset} GATEWAY_IP=${gateway_ip:-unset} TPROXY_PORT=$tproxy_port"
  echo
  echo "[rp_filter] (0=off, 1=strict, 2=loose; effective=max(all, interface)]"
  local key value path iface
  for key in all default "$lan_if"; do
    value="$(sysctl -n "net.ipv4.conf.$key.rp_filter" 2>/dev/null || echo unavailable)"
    printf '  %-8s %s\n' "$key" "$value"
    [[ "$value" =~ ^[012]$ ]] || log "WARN: не удалось прочитать/проверить rp_filter для $key"
  done
  echo "  Все текущие интерфейсы:"
  for path in /proc/sys/net/ipv4/conf/*/rp_filter; do
    [[ -r "$path" ]] || continue
    iface="${path%/rp_filter}"; iface="${iface##*/}"
    printf '    %-16s %s\n' "$iface" "$(cat "$path")"
  done
  echo
  echo "[Forwarding — только аудит, скрипт не меняет эти значения]"
  for key in net.ipv4.ip_forward net.ipv6.conf.all.forwarding net.ipv6.conf.default.forwarding net.ipv6.conf.all.disable_ipv6; do
    value="$(sysctl -n "$key" 2>/dev/null || echo unavailable)"
    printf '  %-42s %s\n' "$key" "$value"
  done
  echo "  IPv4 forwarding для локального TPROXY-пути не требуется."
  echo
  echo "[Policy routing / nftables conflicts]"
  if ip -4 rule show | grep -Eq "^[[:space:]]*$RULE_PREF:"; then
    echo "  CONFLICT: priority $RULE_PREF уже занят"
  else
    echo "  OK: priority $RULE_PREF свободен"
  fi
  if route_table_rule_exists "$(ip -4 rule show)"; then
    echo "  CONFLICT: таблица $ROUTE_TABLE уже используется ip rule"
  elif ip -4 route show table "$ROUTE_TABLE" | grep -q .; then
    echo "  CONFLICT: таблица $ROUTE_TABLE уже содержит маршруты"
  else
    echo "  OK: таблица $ROUTE_TABLE свободна"
  fi
  if nft list table inet "$TABLE" >/dev/null 2>&1; then
    echo "  CONFLICT: nft table inet $TABLE уже существует"
  else
    echo "  OK: nft table inet $TABLE отсутствует"
  fi
  echo
  echo "[Xray listener]"
  if ss -H -lnutp 2>/dev/null | grep -Eq "(^|[[:space:]])(${gateway_ip:-0\\.0\\.0\\.0}|0\\.0\\.0\\.0|\\*):${tproxy_port}([[:space:]]|$)"; then
    ss -H -lnutp 2>/dev/null | grep -E ":${tproxy_port}([[:space:]]|$)" || true
  else
    echo "  WARN: listener на ожидаемом адресе/порту не обнаружен"
  fi
  echo
  echo "[IPv6]"
  echo "  IPv6 на самом шлюзе не отключается."
  echo "  После установки IPv6-транзит с LAN будет блокироваться правилом nftables (fail-closed)."
  echo "  IPv4/IPv6 forwarding sysctl не меняются."
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
    install) shift; install_service "${1:-}" "${2:-}" "${3:-}" ;;
    check) shift; diagnose "${1:-}" "${2:-}" "${3:-}" "${4:-}" ;;
    apply) apply_rules ;;
    remove) remove_rules ;;
    uninstall) remove_installation ;;
    *) echo "Usage: bash host-network.sh check [LAN_IF] [LAN_CIDR] [GATEWAY_IP] [TPROXY_PORT] | install [LAN_IF] [LAN_CIDR] [GATEWAY_IP] | apply | remove | uninstall"; exit 2 ;;
  esac
fi
