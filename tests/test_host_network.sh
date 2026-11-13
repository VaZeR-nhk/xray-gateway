#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
# Sourcing exposes pure helpers only; the host script's command dispatcher is guarded.
source "$ROOT/host-network.sh"

assert_port(){
  local input="$1" expected="$2" actual
  actual="$(normalize_port "$input")"
  [[ "$actual" == "$expected" ]] || { echo "normalize_port $input: expected $expected, got $actual" >&2; exit 1; }
}
assert_invalid(){
  local input="$1"
  if normalize_port "$input" >/dev/null 2>&1; then
    echo "normalize_port unexpectedly accepted: $input" >&2
    exit 1
  fi
}
assert_port 12345 12345
assert_port 00080 80
assert_port 65535 65535
for value in 0 65536 -1 abc "" 1.5; do assert_invalid "$value"; done

# The project must reject an already-used policy-routing table.
if route_table_rule_exists $'0: from all lookup local\n32766: from all lookup main'; then
  echo "route_table_rule_exists falsely matched an unrelated table" >&2
  exit 1
fi
if ! route_table_rule_exists $'100: from all fwmark 0x2 lookup 100'; then
  echo "route_table_rule_exists missed a rule using table 100" >&2
  exit 1
fi

# Keep the local-gateway exemption ahead of the IPv6 fail-closed rule.
local_line="$(grep -nF 'fib daddr type local return' "$ROOT/host-network.sh" | cut -d: -f1)"
ipv6_line="$(grep -nF 'meta nfproto ipv6 drop' "$ROOT/host-network.sh" | cut -d: -f1)"
[[ -n "$local_line" && -n "$ipv6_line" && "$local_line" -lt "$ipv6_line" ]]
grep -Fq 'tproxy to :$TPROXY_PORT' "$ROOT/host-network.sh"
# Existing packet-mark bits must survive; only the reserved project bit is ORed in.
grep -Fq 'meta mark set meta mark | $MARK' "$ROOT/host-network.sh"
grep -Fq 'fwmark "$MARK"/"$MARK_MASK"' "$ROOT/host-network.sh"
# Interrupted setup must have explicit rollback handlers.
grep -Fq "trap 'rollback_on_error 130; exit 130' INT" "$ROOT/host-network.sh"
grep -Fq "trap 'rollback_on_error 143; exit 143' TERM" "$ROOT/host-network.sh"
echo "Host TPROXY helper tests passed."
