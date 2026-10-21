#!/usr/bin/env python3
"""Blade 23 LAN relay. Python 3.10+, standard library only."""
from __future__ import annotations
import argparse
import hmac
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import socket
import sqlite3
import ssl
import threading
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit
from urllib.error import HTTPError, URLError
from urllib.request import urlopen

ROOTS = (
    'sentinel/.cache/blade_workers',
    'sentinel/.cache/rot_receiver_queue',
    'sentinel/.cache/altlink/rotbot',
)
MAX_BODY = 256 * 1024
VERSION = 2

SETUP_HTML = r'''<!doctype html>
<html lang="pt-BR"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Blade 23 — conectar PCs</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#101018;color:#f0eff9;font:16px system-ui,sans-serif;padding:36px 20px}
main{max-width:760px;margin:auto}h1{font-size:34px;margin:8px 0 12px}h2{font-size:21px;margin:0 0 12px}
p{line-height:1.6;color:#c0bed4}small{color:#b8b3ce}.badge{color:#b8f1d8;background:#16362d;border-radius:20px;padding:7px 13px;display:inline-block}
section{background:#1c1a2b;border:1px solid #39334f;border-radius:16px;padding:24px;margin:18px 0}
button{background:#a492ff;color:#171226;border:0;border-radius:9px;padding:13px 18px;cursor:pointer;font-weight:700;font-size:15px}
button.secondary{background:#343046;color:#eee}button:disabled{opacity:.5;cursor:wait}button:focus-visible,input:focus,select:focus{outline:3px solid #c3b6ff}
input,select{width:100%;background:#11101b;color:#f2efff;border:1px solid #53486d;border-radius:8px;padding:12px;font:14px ui-monospace,monospace;margin:8px 0 14px}
.row{display:flex;gap:10px;flex-wrap:wrap}#status{min-height:25px;color:#b8f1d8}.error{color:#ffaaa7!important}label{display:block;color:#cdc8df;margin-top:8px}
code{background:#302a44;padding:3px 6px;border-radius:4px}footer{font-size:14px;color:#9690ae;margin:22px 0}
</style><main>
<span class="badge">Servidor ligado neste PC</span>
<h1>Conecte seus bots.</h1><p>Deixe a janela do servidor aberta. Faça a conexão antes de iniciar a progressão.</p>
<section><h2>1. Neste PC</h2><p>No Roblox, abra <strong>blade 23 → Conexao facil</strong> e clique em <strong>Conectar neste PC</strong>. Pronto: a chave é preenchida e salva automaticamente.</p></section>
<section><h2>2. No outro PC</h2><p>Copie o convite abaixo. No outro computador, cole em <strong>Convite do PC principal</strong> e clique em <strong>Conectar convite</strong>.</p>
<label for="address">Endereço do PC principal</label><select id="address"></select>
<label for="invite">Convite para colar no bot</label><input id="invite" readonly spellcheck="false">
<div class="row"><button id="copy" disabled>Copiar convite</button><button class="secondary" id="renew">Renovar convite</button></div>
<p id="status" role="status" aria-live="polite">Carregando convite...</p>
<small id="expires"></small></section>
<footer>As contas precisam estar no mesmo servidor do jogo. O convite vale por 10 minutos; quem já conectou continua usando a conexão salva. Se houver vários endereços, escolha o da rede usada pelos dois PCs.</footer>
</main><script>
'use strict';
const address=document.getElementById('address'),invite=document.getElementById('invite');
const status=document.getElementById('status'),copy=document.getElementById('copy'),renew=document.getElementById('renew');
let connections=[],expiresAt=0;
function message(text,error=false){status.textContent=text;status.className=error?'error':'';}
function choose(){const chosen=connections.find(item=>item.url===address.value);invite.value=chosen?chosen.invite:'';}
async function load(rotate=false){
 copy.disabled=true;renew.disabled=true;
 try{
  let response;
  try{response=await fetch('/v1/local-invitation',{method:rotate?'POST':'GET',cache:'no-store',headers:{'Content-Type':'application/json'}});}
  catch(error){throw Error('Servidor desligado ou sem resposta. Abra iniciar_servidor.bat novamente.');}
  const data=await response.json();if(!response.ok)throw Error(data.error||'Não foi possível obter o convite.');
  const previous=address.value;connections=data.invitations;
  if(!connections.length)throw Error('Não encontrei endereço de rede. Conecte os PCs à rede e reinicie o servidor.');
  address.replaceChildren();for(const item of connections){const option=document.createElement('option');option.value=item.url;option.textContent=item.url;address.appendChild(option);}
  if(connections.some(item=>item.url===previous))address.value=previous;
  expiresAt=Date.now()+data.expiresIn*1000;choose();copy.disabled=false;
  message(rotate?'Novo convite pronto. As conexões existentes foram mantidas.':'Convite pronto para o outro PC.');
 }catch(error){message(error.message,true)}finally{renew.disabled=false}
}
copy.addEventListener('click',async()=>{
 try{await navigator.clipboard.writeText(invite.value);message('Convite copiado! Cole no campo do bot no outro PC.');}
 catch(error){invite.focus();invite.select();message('Convite selecionado. Aperte Ctrl+C para copiar.');}
});
renew.addEventListener('click',()=>load(true));address.addEventListener('change',choose);
setInterval(()=>{if(!expiresAt)return;const seconds=Math.max(0,Math.ceil((expiresAt-Date.now())/1000));document.getElementById('expires').textContent=seconds?'Validade: '+Math.floor(seconds/60)+'min '+seconds%60+'s':'Convite expirado. Clique em Renovar convite.';copy.disabled=seconds===0;},1000);
load();
</script></html>'''


def lan_addresses():
    addresses = []
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.connect(('192.0.2.1', 9))
            addresses.append(probe.getsockname()[0])
    except OSError:
        pass
    try:
        addresses.extend(socket.gethostbyname_ex(socket.gethostname())[2])
    except OSError:
        pass
    return list(dict.fromkeys(address for address in addresses if not ipaddress.ip_address(address).is_loopback))


class Pairing:
    def __init__(self, lifetime=600):
        self.lock = threading.RLock()
        self.lifetime = lifetime
        self.failures = {}
        self.renew()

    def renew(self):
        with self.lock:
            self.code = ''.join(secrets.choice('ABCDEFGHJKLMNPQRSTUVWXYZ23456789') for _ in range(8))
            self.deadline = time.monotonic() + self.lifetime
            self.failures.clear()

    def verify(self, address, value):
        with self.lock:
            now = time.monotonic()
            self.failures = {ip: [at for at in attempts if now-at < 60]
                             for ip, attempts in self.failures.items() if attempts and now-attempts[-1] < 60}
            if len(self.failures.get(address, [])) >= 8 or sum(map(len, self.failures.values())) >= 100:
                return 429, 'Muitas tentativas. Aguarde um minuto ou renove o convite no PC principal.'
            if now >= self.deadline:
                return 410, 'Convite expirado. Clique em Renovar convite na pagina do PC principal.'
            code = re.sub(r'[\s-]', '', value.upper()) if isinstance(value, str) else ''
            if not code.isascii() or not hmac.compare_digest(code, self.code):
                self.failures.setdefault(address, []).append(now)
                return 401, 'Convite incorreto. Copie novamente na pagina do PC principal.'
            return 200, None

    def invitation(self, urls):
        with self.lock:
            code = self.code[:4]+'-'+self.code[4:]
            return {'service': 'blade23', 'version': VERSION,
                    'expiresIn': max(0, int(self.deadline-time.monotonic())),
                    'invitations': [{'url': url, 'invite': f'B23|{url}|{code}'} for url in urls]}


def valid_key(key):
    if not isinstance(key, str) or len(key) > 200:
        return False
    return any(re.fullmatch(re.escape(root) + r'/[A-Za-z0-9_-]+\.json', key) for root in ROOTS)


class Store:
    def __init__(self, filename):
        self.lock = threading.RLock()
        self.db = sqlite3.connect(filename, check_same_thread=False)
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.execute('CREATE TABLE IF NOT EXISTS records (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated REAL NOT NULL)')
        self.db.execute('CREATE TABLE IF NOT EXISTS counter (id INTEGER PRIMARY KEY CHECK(id=1), n INTEGER NOT NULL)')
        self.db.execute('INSERT OR IGNORE INTO counter VALUES (1,0)')
        self.db.commit()

    def put(self, key, value):
        with self.lock, self.db:
            row = self.db.execute('SELECT value,updated FROM records WHERE key=?', (key,)).fetchone()
            old = json.loads(row[0]) if row else None
            value = dict(value)
            now = time.time()
            # Authoritative server clock and queue ordering across both PCs.
            value['at'] = int(now)
            same_generation = bool(old and now-row[1] <= 12 and old.get('jobId') == value.get('jobId') and old.get('joined') == value.get('joined'))
            if 'joined' in value:
                if same_generation and '_order' in old:
                    value['_order'] = old['_order']
                else:
                    self.db.execute('UPDATE counter SET n=n+1 WHERE id=1')
                    value['_order'] = self.db.execute('SELECT n FROM counter WHERE id=1').fetchone()[0]
            payload = json.dumps(value, separators=(',', ':'), ensure_ascii=False)
            self.db.execute('INSERT INTO records VALUES (?,?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value,updated=excluded.updated', (key, payload, now))
            return value

    def get(self, key):
        with self.lock:
            row = self.db.execute('SELECT value FROM records WHERE key=?', (key,)).fetchone()
            return json.loads(row[0]) if row else None

    def list(self, prefix):
        with self.lock, self.db:
            self.db.execute('DELETE FROM records WHERE updated < ?', (time.time() - 86400,))
            # The approved prefixes are fixed strings; no wildcard interpolation.
            rows = self.db.execute('SELECT key,value FROM records WHERE substr(key,1,?)=? ORDER BY key', (len(prefix)+1, prefix+'/')).fetchall()
            return [{'key': key, 'value': json.loads(value)} for key, value in rows]

    def delete(self, key):
        with self.lock, self.db:
            self.db.execute('DELETE FROM records WHERE key=?', (key,))

    def close(self):
        with self.lock:
            self.db.close()


class Handler(BaseHTTPRequestHandler):
    server_version = 'Blade23/2.0'

    def log_message(self, fmt, *args):
        # Do not log tokens, queue payloads or every heartbeat.
        return

    def reply(self, status, **payload):
        payload['serverTime'] = time.time()
        body = json.dumps(payload, separators=(',', ':'), ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.end_headers()
        self.wfile.write(body)

    def local_allowed(self):
        try:
            local = ipaddress.ip_address(self.client_address[0]).is_loopback
        except ValueError:
            local = False
        port = self.server.server_port
        hosts = {f'127.0.0.1:{port}', f'localhost:{port}', f'[::1]:{port}'}
        if port in (80, 443):
            hosts.update(('127.0.0.1', 'localhost', '[::1]'))
        host = self.headers.get('Host', '').lower()
        origin = self.headers.get('Origin')
        same_origin = origin is None or (urlsplit(origin).scheme in ('http', 'https') and urlsplit(origin).netloc.lower() == host)
        return local and host in hosts and same_origin and self.headers.get('Sec-Fetch-Site') != 'cross-site'

    def invitations(self):
        urls = [f'{self.server.scheme}://{address}:{self.server.server_port}' for address in self.server.addresses]
        return self.server.pairing.invitation(urls)

    def show_setup(self):
        body = SETUP_HTML.encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('X-Frame-Options', 'DENY')
        self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'")
        self.end_headers()
        self.wfile.write(body)

    def dispatch(self):
        route = urlsplit(self.path)
        query = parse_qs(route.query)
        if self.command == 'GET' and route.path == '/v1/info':
            self.reply(200, service='blade23', version=VERSION)
            return
        local_route = (self.command == 'GET' and route.path in ('/', '/setup', '/v1/local-invitation')) or (
            self.command == 'POST' and route.path in ('/v1/local-connect', '/v1/local-invitation'))
        if local_route:
            if not self.local_allowed():
                self.reply(403, error='Abra esta pagina no PC principal usando 127.0.0.1 ou localhost.')
                return
            if route.path in ('/', '/setup'):
                self.show_setup()
            elif route.path == '/v1/local-connect':
                self.reply(200, service='blade23', version=VERSION, token=self.server.token)
            else:
                if self.command == 'POST':
                    self.server.pairing.renew()
                self.reply(200, **self.invitations())
            return
        if self.command == 'POST' and route.path == '/v1/pair':
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 < length <= 512 or not self.headers.get('Content-Type', '').startswith('application/json'):
                    raise ValueError('Invalid pairing request')
                data = json.loads(self.rfile.read(length))
                if not isinstance(data, dict):
                    raise ValueError('Invalid pairing JSON')
            except (ValueError, UnicodeError):
                self.reply(400, error='Convite invalido. Copie o convite inteiro no PC principal.')
                return
            status, error = self.server.pairing.verify(self.client_address[0], data.get('code'))
            if status != 200:
                self.reply(status, error=error)
            else:
                self.reply(200, service='blade23', version=VERSION, token=self.server.token)
            return
        expected = 'Bearer ' + self.server.token
        actual = self.headers.get('Authorization', '')
        if not hmac.compare_digest(actual.encode(), expected.encode()):
            self.reply(401, error='Invalid access key')
            return
        if self.command == 'GET' and route.path == '/v1/health':
            self.reply(200, ok=True, service='blade23', version=VERSION)
            return
        if self.command == 'GET' and route.path == '/v1/list':
            prefix = query.get('prefix', [''])[0].rstrip('/')
            if prefix not in ROOTS:
                self.reply(400, error='Unsupported prefix')
                return
            self.reply(200, entries=self.server.store.list(prefix))
            return
        if self.command in ('GET', 'DELETE') and route.path == '/v1/item':
            key = query.get('key', [''])[0]
            if not valid_key(key):
                self.reply(400, error='Unsupported key')
                return
            if self.command == 'GET':
                self.reply(200, value=self.server.store.get(key))
            else:
                self.server.store.delete(key)
                self.reply(200, ok=True)
            return
        if self.command == 'POST' and route.path == '/v1/item':
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if length <= 0 or length > MAX_BODY:
                    self.reply(413, error='Invalid payload size')
                    return
                data = json.loads(self.rfile.read(length))
            except (ValueError, UnicodeError):
                self.reply(400, error='Invalid JSON')
                return
            if not isinstance(data, dict) or not valid_key(data.get('key')) or not isinstance(data.get('value'), dict):
                self.reply(400, error='Invalid record')
                return
            self.reply(200, ok=True, value=self.server.store.put(data['key'], data['value']))
            return
        self.reply(404, error='Unknown endpoint')

    def handle_request(self):
        try:
            self.connection.settimeout(10)
            self.dispatch()
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass
        except Exception as exc:
            print('Request failed:', type(exc).__name__, flush=True)
            try:
                self.reply(500, error='Server error')
            except OSError:
                pass

    do_GET = handle_request
    do_POST = handle_request
    do_DELETE = handle_request


def make_server(host, port, token, database, *, pairing_lifetime=600):
    server = ThreadingHTTPServer((host, port), Handler)
    server.daemon_threads = True
    server.token = token
    server.store = Store(database)
    server.pairing = Pairing(pairing_lifetime)
    server.addresses = lan_addresses()
    server.scheme = 'http'
    return server


def main():
    parser = argparse.ArgumentParser(description='Servidor de comunicacao Blade 23')
    parser.add_argument('--host', default='0.0.0.0')
    parser.add_argument('--port', default=8787, type=int)
    parser.add_argument('--database', default=str(Path(__file__).with_name('blade23_state.sqlite3')))
    parser.add_argument('--token-file', default=str(Path(__file__).with_name('blade23_access_key.txt')))
    parser.add_argument('--cert', help='Optional TLS certificate PEM')
    parser.add_argument('--key', help='Optional TLS private key PEM')
    parser.add_argument('--open-browser', action='store_true', help='Abrir a pagina de conexao neste PC')
    args = parser.parse_args()
    token_path = Path(args.token_file)
    token = os.environ.get('BLADE23_TOKEN', '').strip()
    if not token:
        if token_path.exists():
            token = token_path.read_text(encoding='utf-8').strip()
        else:
            token = secrets.token_urlsafe(32)
            token_path.write_text(token+'\n', encoding='utf-8')
            try:
                token_path.chmod(0o600)
            except OSError:
                pass
    if len(token) < 16:
        raise SystemExit('A chave de acesso precisa ter pelo menos 16 caracteres.')
    try:
        server = make_server(args.host, args.port, token, args.database)
    except OSError as exc:
        try:
            with urlopen(f'http://127.0.0.1:{args.port}/v1/info', timeout=2) as response:
                info = json.load(response)
            if info.get('service') == 'blade23' and info.get('version', 0) >= 2:
                print('O Blade 23 ja esta ligado. Reabrindo a pagina de conexao.', flush=True)
                if args.open_browser:
                    webbrowser.open(f'http://127.0.0.1:{args.port}/')
                return
        except (OSError, ValueError, HTTPError, URLError):
            pass
        raise SystemExit('Nao consegui usar a porta. Feche a janela do servidor antigo e abra este iniciador novamente.') from exc
    scheme = 'http'
    if bool(args.cert) != bool(args.key):
        raise SystemExit('Use --cert e --key juntos.')
    if args.cert:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(args.cert, args.key)
        server.socket = ctx.wrap_socket(server.socket, server_side=True)
        scheme = 'https'
    server.scheme = scheme
    print('\nBLADE 23 - servidor ativo', flush=True)
    print('Neste PC:', f'{scheme}://127.0.0.1:{args.port}', flush=True)
    urls = [f'{scheme}://{address}:{args.port}' for address in server.addresses]
    for entry in server.pairing.invitation(urls)['invitations']:
        print('Convite para outro PC:', entry['invite'], flush=True)
    print('Neste PC, clique Conectar neste PC no bot. No outro PC, cole o convite.', flush=True)
    print('Pagina com botao Copiar convite:', f'{scheme}://127.0.0.1:{args.port}/', flush=True)
    print('Deixe esta janela aberta. O convite vale por 10 minutos e pode ser renovado na pagina.\n', flush=True)
    if args.open_browser:
        threading.Timer(0.4, lambda: webbrowser.open(f'{scheme}://127.0.0.1:{args.port}/')).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        server.store.close()


if __name__ == '__main__':
    main()
