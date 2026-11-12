#!/usr/bin/python3
import os,json,base64,hmac,subprocess
from pathlib import Path
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
AUTH=Path("/etc/xray-gateway/web-auth"); GATEWAY="/usr/local/sbin/xray-gateway"
HTML="""<!doctype html><html lang=ru><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><title>Xray Gateway</title><style>body{font:15px system-ui;max-width:900px;margin:32px auto;padding:0 16px;background:#101722;color:#e7edf5}button{padding:9px 14px;margin:4px;border:0;border-radius:7px;cursor:pointer}section{background:#1b2736;padding:18px;border-radius:12px;margin:14px 0}.profile{display:flex;justify-content:space-between;align-items:center;border-bottom:1px solid #354357;padding:10px 0}.muted{color:#9caec3}#msg{white-space:pre-wrap}</style><h1>Xray Gateway</h1><section><b>Состояние:</b> <span id=status>Загрузка</span><p class=muted id=updated></p><button onclick=updateSub()>Обновить подписку</button></section><section><h2>Профили</h2><div id=profiles></div></section><section><h2>Результат</h2><pre id=msg></pre></section><script>
async function api(path,method='GET',body){let r=await fetch(path,{method,headers:{'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined,cache:'no-store'});let j=await r.json();if(!r.ok)throw Error(j.error||'HTTP '+r.status);return j}
async function refresh(){try{let [p,s]=await Promise.all([api('/api/profiles'),api('/api/status')]);status.textContent=s.service;updated.textContent='Активный профиль: '+(p.profiles[p.active_profile]?.name||'не определён')+' · Профилей: '+p.profile_count;profiles.replaceChildren();p.profiles.forEach(x=>{let d=document.createElement('div');d.className='profile';let n=document.createElement('span');n.textContent=(x.active?'● ':'')+x.name;let b=document.createElement('button');b.textContent=x.active?'Активен':'Применить';b.disabled=x.active;b.onclick=()=>selectProfile(x.index);d.append(n,b);profiles.append(d)})}catch(e){msg.textContent=e.message}}
async function action(path,body){try{msg.textContent='Выполняется…';let r=await api(path,'POST',body);msg.textContent=r.output||'Готово';await refresh()}catch(e){msg.textContent=e.message}}
async function selectProfile(index){if(confirm('Применить выбранный профиль?'))await action('/api/select',{index})}
async function updateSub(){if(confirm('Загрузить подписку Remnawave?'))await action('/api/update',{})}
refresh();setInterval(refresh,10000)
</script></html>"""
def run(a,timeout=300): return subprocess.run(a,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
class H(BaseHTTPRequestHandler):
 def reply(self,code,obj,ctype='application/json; charset=utf-8'):
  raw=obj if isinstance(obj,bytes) else json.dumps(obj,ensure_ascii=False).encode()
  self.send_response(code);self.send_header('Content-Type',ctype);self.send_header('Cache-Control','no-store');self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
 def auth(self):
  try:
   user,pw=AUTH.read_text().strip().split(':',1); v=self.headers.get('Authorization','')
   if not v.startswith('Basic '): return False
   u,p=base64.b64decode(v[6:]).decode().split(':',1)
   return hmac.compare_digest(u,user) and hmac.compare_digest(p,pw)
  except: return False
 def guard(self):
  if self.auth(): return True
  self.send_response(401);self.send_header('WWW-Authenticate','Basic realm="Xray Gateway"');self.send_header('Content-Length','0');self.end_headers();return False
 def do_GET(self):
  if not self.guard(): return
  try:
   if self.path=='/': self.reply(200,HTML.encode(),'text/html; charset=utf-8')
   elif self.path=='/api/profiles':
    r=run([GATEWAY,'profiles'])
    if r.returncode: raise RuntimeError(r.stdout)
    self.reply(200,json.loads(r.stdout))
   elif self.path=='/api/status':
    r=run(['supervisorctl','status','xray']); state=json.loads(Path('/etc/xray-gateway/state.json').read_text()) if Path('/etc/xray-gateway/state.json').exists() else {}
    self.reply(200,{'service':'running' if r.returncode==0 and 'RUNNING' in r.stdout else 'stopped','last_update':state.get('last_update'),'action':state.get('action')})
   elif self.path=='/api/logs':
    r=run(['tail','-n','100','/var/log/supervisor/xray.log','/var/log/supervisor/gateway.log'])
    self.reply(200,{'logs':r.stdout})
   else:self.reply(404,{'error':'Not found'})
  except Exception as e:self.reply(500,{'error':str(e)})
 def do_POST(self):
  if not self.guard():return
  try:
   n=int(self.headers.get('Content-Length','0'))
   if n>4096: raise ValueError('Request too large')
   body=json.loads(self.rfile.read(n) or b'{}')
   if self.path=='/api/select':
    i=body.get('index')
    if not isinstance(i,int) or isinstance(i,bool) or i<0: raise ValueError('Некорректный индекс')
    args=[GATEWAY,'select',str(i)]
   elif self.path=='/api/update': args=[GATEWAY,'update']; i=None
   else:self.reply(404,{'error':'Not found'});return
   r=run(args)
   if r.returncode: self.reply(500,{'error':r.stdout});return
   if i is not None:
    check=run([GATEWAY,'profiles'])
    if check.returncode or json.loads(check.stdout).get('active_profile')!=i: raise RuntimeError('Панель не подтвердила применение выбранного профиля')
   self.reply(200,{'output':r.stdout})
  except Exception as e:self.reply(500,{'error':str(e)})
 def log_message(self,fmt,*args): print('[web] '+fmt%args,flush=True)
ThreadingHTTPServer((os.getenv('XRAY_WEB_HOST','0.0.0.0'),int(os.getenv('XRAY_WEB_PORT','8080'))),H).serve_forever()
