#!/usr/bin/python3
import os, json, base64, hmac, subprocess, secrets, hashlib, time, http.cookies
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from node_checks import get_checks, start_checks

GATEWAY = "/usr/local/sbin/xray-gateway"
STATIC = Path("/opt/xray-gateway/static")
SESSION_TTL = 43200
FAILURES = {}

def credentials():
    user = os.environ.get("WEB_USERNAME", "")
    password = os.environ.get("WEB_PASSWORD", "")
    if not user or not password:
        raise RuntimeError("WEB_USERNAME/WEB_PASSWORD не заданы в .env")
    return user, password

def session_key():
    value = os.environ.get("SESSION_SECRET", "")
    if len(value) < 64:
        raise RuntimeError("SESSION_SECRET должен содержать не менее 64 hex-символов")
    return bytes.fromhex(value)

def make_session(user):
    exp = int(time.time()) + SESSION_TTL
    payload = f"{user}|{exp}"
    sig = hmac.new(session_key(), payload.encode(), hashlib.sha256).hexdigest()
    return base64.urlsafe_b64encode(f"{payload}|{sig}".encode()).decode().rstrip("=")

def valid_session(value):
    try:
        raw = base64.urlsafe_b64decode(value + "=" * (-len(value) % 4)).decode()
        user, exp, sig = raw.split("|", 2)
        expected = hmac.new(session_key(), f"{user}|{exp}".encode(), hashlib.sha256).hexdigest()
        saved_user, _ = credentials()
        return user == saved_user and int(exp) > int(time.time()) and hmac.compare_digest(sig, expected)
    except Exception:
        return False

def run(args, timeout=300):
    return subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)

class H(BaseHTTPRequestHandler):
    def reply(self, code, obj, ctype='application/json; charset=utf-8', headers=None):
        raw = obj if isinstance(obj, bytes) else json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code); self.send_header('Content-Type', ctype)
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'")
        if headers:
            for key, value in headers.items(): self.send_header(key, value)
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers(); self.wfile.write(raw)

    def guard(self):
        jar = http.cookies.SimpleCookie(self.headers.get("Cookie", ""))
        token = jar.get("xray_session")
        if token and valid_session(token.value):
            return True
        self.reply(401, {"error": "Требуется авторизация"})
        return False

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/api/auth/status":
            jar = http.cookies.SimpleCookie(self.headers.get("Cookie", ""))
            token = jar.get("xray_session")
            self.reply(200, {"authenticated": bool(token and valid_session(token.value))})
            return
        if path == "/":
            self.reply(200, (STATIC / "index.html").read_bytes(), "text/html; charset=utf-8")
            return
        if path in ("/app.js", "/style.css", "/TwemojiCountryFlags.woff2"):
            f = STATIC / path.lstrip("/")
            if not f.is_file(): self.reply(404, {"error":"Not found"}); return
            if path.endswith(".woff2"):
                ctype = "font/woff2"
            elif path.endswith(".js"):
                ctype = "application/javascript; charset=utf-8"
            else:
                ctype = "text/css; charset=utf-8"
            self.reply(200, f.read_bytes(), ctype)
            return
        if not self.guard(): return
        try:
            if path == "/api/profiles":
                r = run([GATEWAY, "profiles"])
                if r.returncode: raise RuntimeError(r.stdout)
                data = json.loads(r.stdout)
                checks = get_checks()
                successful = {}
                for item in checks.get("results", []):
                    if item.get("status") != "OK" or item.get("latency_ms") is None:
                        continue
                    index = item.get("profile_index")
                    if not isinstance(index, int) or index < 0:
                        continue
                    current = successful.get(index)
                    if current is None or item["latency_ms"] < current["latency_ms"]:
                        successful[index] = {
                            "tag": item.get("tag"),
                            "protocol": item.get("protocol"),
                            "address": item.get("address"),
                            "port": item.get("port"),
                            "latency_ms": item["latency_ms"],
                        }
                for index, profile in enumerate(data.get("profiles", [])):
                    best = successful.get(index)
                    profile["ping_ms"] = best["latency_ms"] if best else None
                    profile["best_node"] = best
                self.reply(200, data)
            elif path == "/api/status":
                r = run(["supervisorctl", "status", "xray"])
                state = json.loads(Path("/var/lib/xray-gateway/state.json").read_text()) if Path("/var/lib/xray-gateway/state.json").exists() else {}
                sub = json.loads(Path("/var/lib/xray-gateway/subscription.json").read_text()) if Path("/var/lib/xray-gateway/subscription.json").exists() else []
                self.reply(200, {"service":"running" if r.returncode == 0 and "RUNNING" in r.stdout else "stopped", "last_update":state.get("last_update"), "action":state.get("action"), "profile_count":len(sub) if isinstance(sub,list) else 0, "active_profile":state.get("active_profile")})
            elif path == "/api/logs":
                r = run(["tail","-n","150","/var/log/supervisor/xray.log","/var/log/supervisor/gateway.log"])
                self.reply(200, {"logs":r.stdout})
            elif path == "/api/checks": self.reply(200, get_checks())
            else: self.reply(404, {"error":"Not found"})
        except Exception as e: self.reply(500, {"error":str(e)})

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        try:
            n = int(self.headers.get("Content-Length", "0"))
            if n > 8192: raise ValueError("Request too large")
            body = json.loads(self.rfile.read(n) or b"{}")
        except Exception as e:
            self.reply(400, {"error":str(e)}); return
        if path == "/api/auth/login":
            ip = self.client_address[0]; now = time.time()
            count, until = FAILURES.get(ip, (0, 0))
            if count >= 5 and until > now:
                self.reply(429, {"error":"Слишком много попыток. Подождите минуту."}); return
            try: username, password = credentials()
            except Exception as e: self.reply(503, {"error":str(e)}); return
            if hmac.compare_digest(str(body.get("username","")), username) and hmac.compare_digest(str(body.get("password","")), password):
                FAILURES.pop(ip, None)
                value = f"xray_session={make_session(username)}; Path=/; HttpOnly; SameSite=Strict; Max-Age={SESSION_TTL}"
                if self.headers.get("X-Forwarded-Proto","").lower() == "https": value += "; Secure"
                self.reply(200, {"authenticated":True}, headers={"Set-Cookie":value})
            else:
                FAILURES[ip] = (count + 1, now + 60)
                self.reply(401, {"error":"Неверный логин или пароль"})
            return
        if path == "/api/auth/logout":
            value = "xray_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0"
            if self.headers.get("X-Forwarded-Proto","").lower() == "https": value += "; Secure"
            self.reply(200, {"authenticated":False}, headers={"Set-Cookie":value}); return
        if not self.guard(): return
        try:
            if path == "/api/select":
                i = body.get("index")
                if not isinstance(i,int) or isinstance(i,bool) or i < 0: raise ValueError("Некорректный индекс")
                args = [GATEWAY,"select",str(i)]
            elif path == "/api/update": args = [GATEWAY,"update"]; i = None
            elif path == "/api/subscription":
                url = body.get("url")
                if not isinstance(url,str) or not url.startswith("https://") or len(url)>2048 or any(c.isspace() for c in url): raise ValueError("Укажите корректный HTTPS URL без пробелов")
                args = [GATEWAY,"set-url",url]; i = None
            elif path == "/api/checks":
                self.reply(202, start_checks()); return
            else: self.reply(404, {"error":"Not found"}); return
            r = run(args)
            if r.returncode: self.reply(500, {"error":r.stdout}); return
            if path in ("/api/update", "/api/subscription"):
                start_checks()
            if i is not None:
                check = run([GATEWAY,"profiles"])
                if check.returncode or json.loads(check.stdout).get("active_profile") != i: raise RuntimeError("Не удалось подтвердить применение профиля")
            self.reply(200, {"output":r.stdout or "Готово"})
        except Exception as e: self.reply(500, {"error":str(e)})

    def log_message(self, fmt, *args): print('[web] ' + fmt % args, flush=True)

# The entrypoint has already completed the initial subscription update before Supervisor starts.
# Start node checks in the background so the UI has latency data after the first page load.
try:
    start_checks()
except Exception as e:
    print('[checks] Не удалось запустить стартовую проверку: ' + str(e), flush=True)

ThreadingHTTPServer((os.getenv('XRAY_WEB_HOST', '0.0.0.0'), int(os.getenv('XRAY_WEB_PORT', '8080'))), H).serve_forever()
