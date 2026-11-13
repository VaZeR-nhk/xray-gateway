#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"
python3 - <<'PY'
from pathlib import Path
import os, re, secrets, tempfile

root = Path(".")
env = root / ".env"
values = {}

# .env is the only source of configuration values.
if env.exists():
    for line in env.read_text().splitlines():
        if line and not line.lstrip().startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()

defaults = {
    "XRAY_VERSION": "26.11.9",
    "USER_AGENT": "Happ",
    "ACTIVE_PROFILE": "0",
    "TPROXY_PORT": "12345",
    "GATEWAY_IP": "0.0.0.0",
    "LAN_IF": "",
    "LAN_CIDR": "",
    "ENABLE_TPROXY": "false",
    "SESSION_SECRET": secrets.token_hex(32),
}
for key, value in defaults.items():
    values.setdefault(key, value)

required = ("SUBSCRIPTION_URL", "WEB_USERNAME", "WEB_PASSWORD")
missing = [key for key in required if not values.get(key)]
if missing:
    raise SystemExit("Missing required .env values: " + ", ".join(missing))

checks = {
    "SUBSCRIPTION_URL": r"https://[A-Za-z0-9._~:/?%+=&-]+",
    "WEB_USERNAME": r"[A-Za-z0-9._-]+",
    "WEB_PASSWORD": r"[A-Za-z0-9._~!@%+=,-]{12,}",
    "SESSION_SECRET": r"[0-9a-fA-F]{64}",
}
for key, pattern in checks.items():
    if not re.fullmatch(pattern, values[key]):
        raise SystemExit("Invalid or unsupported characters in " + key)
if values["ENABLE_TPROXY"].lower() not in ("true", "false", "1", "0", "yes", "no", "on", "off"):
    raise SystemExit("Invalid ENABLE_TPROXY")
try:
    tproxy_port = int(values["TPROXY_PORT"], 10)
except ValueError:
    raise SystemExit("Invalid TPROXY_PORT: expected an integer from 1 to 65535")
if not 1 <= tproxy_port <= 65535:
    raise SystemExit("Invalid TPROXY_PORT: expected an integer from 1 to 65535")
values["TPROXY_PORT"] = str(tproxy_port)
for key in ("XRAY_VERSION", "USER_AGENT", "ACTIVE_PROFILE", "TPROXY_PORT", "GATEWAY_IP"):
    if not re.fullmatch(r"[A-Za-z0-9._:-]+", values[key]):
        raise SystemExit("Invalid or unsupported characters in " + key)
for key in ("LAN_IF", "LAN_CIDR"):
    if values[key] and not re.fullmatch(r"[A-Za-z0-9._:/-]+", values[key]):
        raise SystemExit("Invalid or unsupported characters in " + key)
if values["LAN_CIDR"]:
    import ipaddress
    if ipaddress.ip_network(values["LAN_CIDR"], strict=False).version != 4:
        raise SystemExit("LAN_CIDR must be IPv4")

order = ("XRAY_VERSION", "SUBSCRIPTION_URL", "USER_AGENT", "ACTIVE_PROFILE",
         "TPROXY_PORT", "GATEWAY_IP", "LAN_IF", "LAN_CIDR", "ENABLE_TPROXY", "WEB_USERNAME",
         "WEB_PASSWORD", "SESSION_SECRET")
tmp = env.with_name(".env.new")
tmp.write_text("".join(f"{key}={values[key]}\n" for key in order))
os.chmod(tmp, 0o600)
os.replace(tmp, env)
PY
chmod 600 .env
