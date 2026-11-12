#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"
python3 - <<'PY'
from pathlib import Path
import secrets, re, os, tempfile
root=Path('.')
env=root/'.env'
values={}
if env.exists():
    for line in env.read_text().splitlines():
        line=line.strip()
        if line and not line.startswith('#') and '=' in line:
            k,v=line.split('=',1); values[k.strip()]=v.strip().strip(chr(34)).strip(chr(39))
for source in (root/'data/settings.conf',):
    if source.exists():
        for line in source.read_text().splitlines():
            if line.strip() and not line.lstrip().startswith('#') and '=' in line:
                k,v=line.split('=',1); values.setdefault(k.strip(),v.strip())
auth=root/'data/web-auth'
if auth.exists():
    user,sep,password=auth.read_text().strip().partition(':')
    if sep:
        values.setdefault('WEB_USERNAME',user)
        values.setdefault('WEB_PASSWORD',password)
values.setdefault('XRAY_VERSION','26.11.9')
values.setdefault('USER_AGENT','Happ')
values.setdefault('ACTIVE_PROFILE','0')
values.setdefault('TPROXY_PORT','12345')
values.setdefault('GATEWAY_IP','0.0.0.0')
values.setdefault('SESSION_SECRET',secrets.token_hex(32))
required=('SUBSCRIPTION_URL','WEB_USERNAME','WEB_PASSWORD')
missing=[k for k in required if not values.get(k)]
if missing: raise SystemExit('Missing required .env values: '+', '.join(missing))
for key in ('WEB_USERNAME','WEB_PASSWORD','SESSION_SECRET','SUBSCRIPTION_URL'):
    if any(ch in values[key] for ch in chr(10)+chr(13)+chr(0)): raise SystemExit('Invalid newline/NUL in '+key)
if not re.fullmatch(r'[0-9a-fA-F]{64}',values['SESSION_SECRET']): raise SystemExit('SESSION_SECRET must be 64 hex characters')
if not values['SUBSCRIPTION_URL'].startswith('https://'): raise SystemExit('SUBSCRIPTION_URL must use HTTPS')
fd,tmp=tempfile.mkstemp(prefix='.env.',dir='.')
with os.fdopen(fd,'w') as f:
    for k,v in values.items(): f.write(f'{k}={v}'+chr(10))
os.chmod(tmp,0o600); os.replace(tmp,env)
if auth.exists(): auth.unlink()
settings=root/'data/settings.conf'
if settings.exists(): settings.unlink()
PY
chmod 600 .env