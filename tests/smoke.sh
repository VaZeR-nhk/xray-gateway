#!/usr/bin/env bash
set -Eeuo pipefail
IMAGE="${1:-xray-gateway:ci}"
STATE=$(mktemp -d)
ENVFILE=$(mktemp)
NAME=xray-gateway-smoke
OUT=$(mktemp)
COOKIE=$(mktemp)
cleanup(){
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  rm -rf "$STATE" "$ENVFILE" "$OUT" "$COOKIE"
}
trap cleanup EXIT

chmod 700 "$STATE"
cat > "$ENVFILE" <<'EOF'
SUBSCRIPTION_URL=https://example.invalid/subscription
USER_AGENT=Happ
ACTIVE_PROFILE=0
TPROXY_PORT=12345
GATEWAY_IP=0.0.0.0
WEB_USERNAME=ci
WEB_PASSWORD=ci-password-long
SESSION_SECRET=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
EOF
printf '11111111-1111-4111-8111-111111111111\n' > "$STATE/hwid"
cat > "$STATE/subscription.json" <<'EOF'
[{"remarks":"CI smoke profile","inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"}],"routing":{"rules":[]}}]
EOF
cat > "$STATE/state.json" <<'EOF'
{"active_profile":0,"profile_count":1,"status":"success","action":"fixture"}
EOF
cat > "$STATE/config.json" <<'EOF'
{
  "log":{"loglevel":"warning"},
  "inbounds":[{"listen":"127.0.0.1","port":18081,"protocol":"socks","settings":{"auth":"noauth","udp":false}}],
  "outbounds":[{"protocol":"freedom","tag":"direct"}]
}
EOF
chmod 600 "$STATE"/*

docker run -d --name "$NAME" --network host \
  --cap-add NET_ADMIN --cap-add NET_RAW --cap-add NET_BIND_SERVICE \
  -e XRAY_WEB_HOST=127.0.0.1 -e XRAY_WEB_PORT=18080 \
  -e WEB_USERNAME=ci -e WEB_PASSWORD=ci-password-long \
  -e SESSION_SECRET=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
  -v "$STATE:/var/lib/xray-gateway" -v "$ENVFILE:/etc/xray-gateway/.env" "$IMAGE" >/dev/null

docker exec "$NAME" test -s /usr/local/bin/geosite.dat
docker exec "$NAME" test -s /usr/local/bin/geoip.dat

ready=0
for _ in $(seq 1 30); do
  if curl -fsS --max-time 2 -c "$COOKIE" -H "Content-Type: application/json" -d '{"username":"ci","password":"ci-password-long"}' http://127.0.0.1:18080/api/auth/login >/dev/null && curl -fsS --max-time 2 -b "$COOKIE" http://127.0.0.1:18080/api/profiles > "$OUT"; then
    ready=1
    break
  fi
  sleep 2
done
if [[ "$ready" != 1 ]]; then
  docker logs "$NAME" || true
  docker exec "$NAME" supervisorctl status || true
  echo "Web API did not become ready" >&2
  exit 1
fi

python3 - "$OUT" <<'PY'
import json,sys
data=json.load(open(sys.argv[1]))
assert data["profile_count"] == 1, data
assert data["profiles"][0]["name"] == "CI smoke profile", data
assert data["active_profile"] == 0, data
PY

services_ready=0
for _ in $(seq 1 20); do
  XSTATUS=$(docker exec "$NAME" supervisorctl status xray 2>/dev/null || true)
  WSTATUS=$(docker exec "$NAME" supervisorctl status web 2>/dev/null || true)
  if [[ "$XSTATUS" == *RUNNING* && "$WSTATUS" == *RUNNING* ]]; then services_ready=1; break; fi
  sleep 1
done
if [[ "$services_ready" != 1 ]]; then
  docker exec "$NAME" supervisorctl status || true
  docker logs "$NAME" || true
  echo "Supervisor services did not become RUNNING" >&2
  exit 1
fi

STATUS=$(curl -fsS --max-time 5 -b "$COOKIE" http://127.0.0.1:18080/api/status)
python3 - "$STATUS" <<'PY'
import json,sys
data=json.loads(sys.argv[1])
assert data["service"] == "running", data
PY

curl -fsS --max-time 3 http://127.0.0.1:18080/ | grep -q "Xray Gateway"
curl -fsS --max-time 3 http://127.0.0.1:18080/app.js | grep -q "function boot"
docker exec "$NAME" test -s /etc/xray-gateway/.env
docker exec "$NAME" supervisorctl status xray | grep -q RUNNING
docker exec "$NAME" supervisorctl status web | grep -q RUNNING
echo "Container smoke test passed."
