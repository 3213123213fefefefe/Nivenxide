#!/usr/bin/env python3
"""Blade 23 LAN relay. Python 3.10+, standard library only."""
from __future__ import annotations
import argparse
import hmac
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
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

ROOTS = (
    'sentinel/.cache/blade_workers',
    'sentinel/.cache/rot_receiver_queue',
    'sentinel/.cache/altlink/rotbot',
)
MAX_BODY = 256 * 1024


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
    server_version = 'Blade23/1.0'

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
        self.end_headers()
        self.wfile.write(body)

    def dispatch(self):
        expected = 'Bearer ' + self.server.token
        actual = self.headers.get('Authorization', '')
        if not hmac.compare_digest(actual.encode(), expected.encode()):
            self.reply(401, error='Invalid access key')
            return
        route = urlsplit(self.path)
        query = parse_qs(route.query)
        if self.command == 'GET' and route.path == '/v1/health':
            self.reply(200, ok=True, service='blade23', version=1)
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


def make_server(host, port, token, database):
    server = ThreadingHTTPServer((host, port), Handler)
    server.daemon_threads = True
    server.token = token
    server.store = Store(database)
    return server


def main():
    parser = argparse.ArgumentParser(description='Servidor de comunicacao Blade 23')
    parser.add_argument('--host', default='0.0.0.0')
    parser.add_argument('--port', default=8787, type=int)
    parser.add_argument('--database', default=str(Path(__file__).with_name('blade23_state.sqlite3')))
    parser.add_argument('--token-file', default=str(Path(__file__).with_name('blade23_access_key.txt')))
    parser.add_argument('--cert', help='Optional TLS certificate PEM')
    parser.add_argument('--key', help='Optional TLS private key PEM')
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
    server = make_server(args.host, args.port, token, args.database)
    scheme = 'http'
    if bool(args.cert) != bool(args.key):
        raise SystemExit('Use --cert e --key juntos.')
    if args.cert:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(args.cert, args.key)
        server.socket = ctx.wrap_socket(server.socket, server_side=True)
        scheme = 'https'
    print('\nBLADE 23 - servidor ativo', flush=True)
    print('Neste PC:', f'{scheme}://127.0.0.1:{args.port}', flush=True)
    try:
        addresses = sorted(set(socket.gethostbyname_ex(socket.gethostname())[2]))
        for address in addresses:
            if not address.startswith('127.'):
                print('Outro PC na mesma rede:', f'{scheme}://{address}:{args.port}', flush=True)
    except OSError:
        pass
    print('Chave de acesso:', token, flush=True)
    print('Use a mesma chave nas contas dos dois PCs. Deixe esta janela aberta.\n', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        server.store.close()


if __name__ == '__main__':
    main()
