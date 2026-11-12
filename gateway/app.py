#!/usr/bin/python3
import os, json, base64, hmac, subprocess
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from node_checks import get_checks, start_checks

AUTH = Path("/etc/xray-gateway/web-auth")
GATEWAY = "/usr/local/sbin/xray-gateway"
HTML = """<!doctype html><html lang=ru><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><title>Xray Gateway</title>
<style>
body{font:15px system-ui;max-width:1100px;margin:32px auto;padding:0 16px;background:#101722;color:#e7edf5}
button{padding:9px 14px;margin:4px;border:0;border-radius:7px;cursor:pointer}button:disabled{opacity:.5;cursor:default}
section{background:#1b2736;padding:18px;border-radius:12px;margin:14px 0}.profile{display:flex;justify-content:space-between;align-items:center;border-bottom:1px solid #354357;padding:10px 0}
.muted{color:#9caec3}#msg{white-space:pre-wrap}table{width:100%;border-collapse:collapse;font-size:13px}td,th{text-align:left;padding:8px;border-bottom:1px solid #354357;vertical-align:top}th{color:#9caec3}
.ok{color:#70d69a}.fail{color:#ff8585}.progress{color:#9caec3} .scroll{overflow-x:auto}
</style>
<h1>Xray Gateway</h1>
<section><b>Состояние:</b> <span id=status>Загрузка</span><p class=muted id=updated></p>
<button onclick=updateSub()>Обновить подписку</button></section>
<section><h2>Подписка Remnawave</h2><p class=muted>Можно заменить URL подписки. Новый адрес сохраняется только после успешной загрузки и проверки профиля.</p>
<input id=subscriptionUrl type=url placeholder='https://example.com/short-id' style='box-sizing:border-box;width:100%;padding:11px;border-radius:7px;border:1px solid #354357;background:#101722;color:#e7edf5'>
<button onclick=changeSubscription()>Сохранить и загрузить</button></section>
<section><h2>Профили</h2><div id=profiles></div></section>
<section><h2>Проверка узлов подписки</h2><p class=muted>Каждый узел проверяется отдельным временным процессом Xray через локальный SOCKS. Основной Xray, активный профиль и исходная подписка не изменяются.</p>
<button id=checkButton onclick=startChecks()>Проверить все узлы</button><span class=progress id=checkProgress></span>
<div class=scroll><table><thead><tr><th>Профиль</th><th>Узел</th><th>Протокол</th><th>Адрес</th><th>Результат</th><th>Время</th><th>HTTP</th><th>Ошибка</th></tr></thead><tbody id=checkRows></tbody></table></div>
</section><section><h2>Результат операции</h2><pre id=msg></pre></section>
<script>
const el=id=>document.getElementById(id);
async function api(path,method='GET',body){let r=await fetch(path,{method,headers:{'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined,cache:'no-store'});let j=await r.json();if(!r.ok)throw Error(j.error||'HTTP '+r.status);return j}
async function refresh(){try{let [p,s]=await Promise.all([api('/api/profiles'),api('/api/status')]);el('status').textContent=s.service;el('updated').textContent='Активный профиль: '+(p.profiles[p.active_profile]?.name||'не определён')+' · Профилей: '+p.profile_count;el('profiles').replaceChildren();p.profiles.forEach(x=>{let d=document.createElement('div');d.className='profile';let n=document.createElement('span');n.textContent=(x.active?'● ':'')+x.name;let b=document.createElement('button');b.textContent=x.active?'Активен':'Применить';b.disabled=x.active;b.onclick=()=>selectProfile(x.index);d.append(n,b);el('profiles').append(d)})}catch(e){el('msg').textContent=e.message}}
async function action(path,body){try{el('msg').textContent='Выполняется…';let r=await api(path,'POST',body);el('msg').textContent=r.output||'Готово';await refresh()}catch(e){el('msg').textContent=e.message}}
async function selectProfile(index){if(confirm('Применить выбранный профиль?'))await action('/api/select',{index})}
async function updateSub(){if(confirm('Загрузить подписку Remnawave?'))await action('/api/update',{})}
async function changeSubscription(){let url=el('subscriptionUrl').value.trim();if(!url)return alert('Укажите HTTPS URL подписки');if(!url.startsWith('https://'))return alert('Разрешён только HTTPS');if(confirm('Заменить URL подписки и загрузить профили?')){await action('/api/subscription',{url});el('subscriptionUrl').value=''}}
async function startChecks(){try{let r=await api('/api/checks','POST',{});renderChecks(r)}catch(e){el('checkProgress').textContent=e.message}}
function renderChecks(s){el('checkProgress').textContent=s.running?'Проверено '+s.completed+' из '+s.total+'…':(s.error?'Ошибка: '+s.error:(s.finished_at?'Завершено '+s.completed+' из '+s.total:''));el('checkButton').disabled=s.running;let body=el('checkRows');body.replaceChildren();for(const x of s.results||[]){let tr=document.createElement('tr');let vals=[x.profile,x.tag,x.protocol,x.address+':'+x.port,x.status,x.latency_ms==null?'—':x.latency_ms+' ms',x.http_code||'—',x.error||''];vals.forEach((v,i)=>{let td=document.createElement('td');td.textContent=v;if(i===4)td.className=x.status==='OK'?'ok':'fail';tr.append(td)});body.append(tr)}}
async function pollChecks(){try{renderChecks(await api('/api/checks'))}catch(e){el('checkProgress').textContent=e.message}}
refresh();pollChecks();setInterval(refresh,10000);setInterval(pollChecks,2000);
</script></html>"""

def run(args, timeout=300):
    return subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)

class H(BaseHTTPRequestHandler):
    def reply(self, code, obj, ctype='application/json; charset=utf-8'):
        raw = obj if isinstance(obj, bytes) else json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code); self.send_header('Content-Type', ctype)
        self.send_header('Cache-Control', 'no-store'); self.send_header('Content-Length', str(len(raw)))
        self.end_headers(); self.wfile.write(raw)

    def auth(self):
        try:
            user, pw = AUTH.read_text().strip().split(':', 1)
            value = self.headers.get('Authorization', '')
            if not value.startswith('Basic '): return False
            u, p = base64.b64decode(value[6:]).decode().split(':', 1)
            return hmac.compare_digest(u, user) and hmac.compare_digest(p, pw)
        except Exception:
            return False

    def guard(self):
        if self.auth(): return True
        self.send_response(401); self.send_header('WWW-Authenticate', 'Basic realm="Xray Gateway"')
        self.send_header('Content-Length', '0'); self.end_headers(); return False

    def do_GET(self):
        if not self.guard(): return
        try:
            if self.path == '/': self.reply(200, HTML.encode(), 'text/html; charset=utf-8')
            elif self.path == '/api/profiles':
                r = run([GATEWAY, 'profiles'])
                if r.returncode: raise RuntimeError(r.stdout)
                self.reply(200, json.loads(r.stdout))
            elif self.path == '/api/status':
                r = run(['supervisorctl', 'status', 'xray'])
                state = json.loads(Path('/etc/xray-gateway/state.json').read_text()) if Path('/etc/xray-gateway/state.json').exists() else {}
                self.reply(200, {'service': 'running' if r.returncode == 0 and 'RUNNING' in r.stdout else 'stopped',
                    'last_update': state.get('last_update'), 'action': state.get('action')})
            elif self.path == '/api/logs':
                r = run(['tail', '-n', '100', '/var/log/supervisor/xray.log', '/var/log/supervisor/gateway.log'])
                self.reply(200, {'logs': r.stdout})
            elif self.path == '/api/checks': self.reply(200, get_checks())
            else: self.reply(404, {'error': 'Not found'})
        except Exception as e: self.reply(500, {'error': str(e)})

    def do_POST(self):
        if not self.guard(): return
        try:
            n = int(self.headers.get('Content-Length', '0'))
            if n > 4096: raise ValueError('Request too large')
            body = json.loads(self.rfile.read(n) or b'{}')
            if self.path == '/api/select':
                i = body.get('index')
                if not isinstance(i, int) or isinstance(i, bool) or i < 0: raise ValueError('Некорректный индекс')
                args = [GATEWAY, 'select', str(i)]
            elif self.path == '/api/update': args = [GATEWAY, 'update']; i = None
            elif self.path == '/api/subscription':
                url=body.get('url')
                if not isinstance(url,str) or not url.startswith('https://') or len(url)>2048:
                    raise ValueError('Укажите корректный HTTPS URL подписки')
                args=[GATEWAY,'set-url',url]; i=None
            elif self.path == '/api/checks':
                self.reply(202, start_checks()); return
            else: self.reply(404, {'error': 'Not found'}); return
            r = run(args)
            if r.returncode: self.reply(500, {'error': r.stdout}); return
            if i is not None:
                check = run([GATEWAY, 'profiles'])
                if check.returncode or json.loads(check.stdout).get('active_profile') != i:
                    raise RuntimeError('Панель не подтвердила применение выбранного профиля')
            self.reply(200, {'output': r.stdout})
        except Exception as e: self.reply(500, {'error': str(e)})

    def log_message(self, fmt, *args): print('[web] ' + fmt % args, flush=True)

ThreadingHTTPServer((os.getenv('XRAY_WEB_HOST', '0.0.0.0'), int(os.getenv('XRAY_WEB_PORT', '8080'))), H).serve_forever()
