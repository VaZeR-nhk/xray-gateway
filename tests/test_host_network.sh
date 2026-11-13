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

# Guard against accidentally moving the IPv6 drop before the local-gateway exemption.
local_line="$(grep -nF 'fib daddr type local return' "$ROOT/host-network.sh" | cut -d: -f1)"
ipv6_line="$(grep -nF 'meta nfproto ipv6 drop' "$ROOT/host-network.sh" | cut -d: -f1)"
[[ -n "$local_line" && -n "$ipv6_line" && "$local_line" -lt "$ipv6_line" ]]
grep -Fq 'tproxy to :$TPROXY_PORT' "$ROOT/host-network.sh"
echo "Host TPROXY helper tests passed."
