"""Valentine webhook relay.

Runs on a public server and catches webhooks at https://<host>/h/<name> (any method,
any name), keeping the last KEEP of them. Valentine pulls them with a bearer token
(GET /api/events?after=<id>) and can forward each one to a local dev server, so a
service on the internet can reach code running on a PC behind NAT.

It also bridges Valentine's MCP server to remote clients (a claude.ai connector): JSON-RPC
POSTed to /mcp/<MCP_SECRET> is queued, Valentine long-polls GET /api/mcp/next, answers each
with POST /api/mcp/reply?id=<n>, and the relay returns that answer to the client.

Python standard library only. Settings come from the environment:
  RELAY_TOKEN  required; Valentine sends it as "Authorization: Bearer <token>"
  MCP_SECRET   optional (24+ characters); without it /mcp/ is off. Whoever has the URL can
               run commands on the PC, so treat it like the token.
  RELAY_DB     SQLite file (default /data/relay.db)
  RELAY_PORT   listen port (default 8000)
"""
import base64
import hmac
import json
import os
import sqlite3
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

KEEP = 500
MAX_BODY = 1 << 20  # nginx caps bodies at 1 MB too
FIRST_POLL = 50  # a client that has seen nothing gets the latest few, not the oldest
MAX_REPLY = 4 << 20  # read_pane can return 2000 lines
MCP_WAIT = 630  # ask_agent may wait 600 s on the PC
POLL_WAIT = 20  # Valentine reads /api/mcp/next with a 30 s timeout
ONLINE = 40  # seconds since the last poll before the PC counts as gone

NAME_CHARS = set('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.')


def open_db(path):
    db = sqlite3.connect(path, check_same_thread=False)
    db.execute('''CREATE TABLE IF NOT EXISTS events (
        id INTEGER PRIMARY KEY, at REAL, name TEXT, method TEXT, path TEXT,
        query TEXT, headers TEXT, body BLOB, ip TEXT)''')
    return db


def make_handler(db, token, mcp_secret=''):
    lock = threading.Lock()  # one connection, many request threads
    cond = threading.Condition()  # guards mcp: requests queued for the PC, answers by id
    mcp = {'queue': [], 'waiting': set(), 'answers': {}, 'next': 0, 'seen': 0.0}

    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def reply(self, code, obj):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def reply_raw(self, code, body=b''):
            self.send_response(code)
            if body:
                self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def authorized(self):
            return hmac.compare_digest(self.headers.get('Authorization', ''), 'Bearer ' + token)

        def read_body(self, limit):
            try:
                size = int(self.headers.get('Content-Length') or 0)
            except ValueError:
                return None
            if size < 0 or size > limit:
                return None
            return self.rfile.read(size) if size else b''

        def handle_any(self):
            url = urlsplit(self.path)
            if url.path.startswith('/h/'):
                return self.catch(url)
            if url.path == '/api/events' and self.command == 'GET':
                return self.events(url)
            if url.path.startswith('/mcp/') and mcp_secret and hmac.compare_digest(url.path[5:].rstrip('/'), mcp_secret):
                return self.mcp_request()
            if url.path == '/api/mcp/next' and self.command == 'GET':
                return self.mcp_next()
            if url.path == '/api/mcp/reply' and self.command == 'POST':
                return self.mcp_reply(url)
            self.reply(404, {'error': 'not found'})

        def mcp_request(self):
            if self.command != 'POST':
                return self.reply_raw(405)  # no server-to-client SSE stream
            body = self.read_body(MAX_BODY)
            try:
                msg = json.loads(body)
            except (TypeError, ValueError):
                return self.reply(400, {'jsonrpc': '2.0', 'id': None, 'error': {'code': -32700, 'message': 'parse error'}})
            if not isinstance(msg, dict) or 'id' not in msg or 'method' not in msg:
                return self.reply_raw(202)  # a notification or a response: nothing to answer
            with cond:
                if time.time() - mcp['seen'] > ONLINE:
                    return self.reply(200, {'jsonrpc': '2.0', 'id': msg['id'], 'error': {
                        'code': -32000, 'message': 'Valentine is not running or has no relay token set'}})
                mcp['next'] += 1
                n = mcp['next']
                mcp['queue'].append((n, body))
                mcp['waiting'].add(n)
                cond.notify_all()
                cond.wait_for(lambda: n in mcp['answers'], timeout=MCP_WAIT)
                mcp['waiting'].discard(n)
                answer = mcp['answers'].pop(n, None)
                mcp['queue'] = [q for q in mcp['queue'] if q[0] != n]
            if answer is None:
                return self.reply(200, {'jsonrpc': '2.0', 'id': msg['id'], 'error': {'code': -32000, 'message': 'Valentine did not answer in time'}})
            self.reply_raw(200, answer)

        def mcp_next(self):
            if not self.authorized():
                return self.reply(401, {'error': 'bad token'})
            with cond:
                mcp['seen'] = time.time()
                cond.wait_for(lambda: mcp['queue'], timeout=POLL_WAIT)
                mcp['seen'] = time.time()
                job = mcp['queue'].pop(0) if mcp['queue'] else None
            if job is None:
                return self.reply(200, {})
            self.reply(200, {'id': job[0], 'body': job[1].decode('utf-8', 'replace')})

        def mcp_reply(self, url):
            if not self.authorized():
                return self.reply(401, {'error': 'bad token'})
            try:
                n = int((parse_qs(url.query).get('id') or ['0'])[0])
            except ValueError:
                return self.reply(400, {'error': 'bad id'})
            body = self.read_body(MAX_REPLY)
            if body is None:
                return self.reply(413, {'error': 'body too large'})
            with cond:
                if n in mcp['waiting']:  # a late answer to a timed-out request is dropped
                    mcp['answers'][n] = body
                cond.notify_all()
            self.reply(200, {'ok': True})

        def catch(self, url):
            name = url.path[3:].split('/')[0]
            if not name or len(name) > 64 or not set(name) <= NAME_CHARS:
                return self.reply(404, {'error': 'bad hook name'})
            try:
                size = int(self.headers.get('Content-Length') or 0)
            except ValueError:
                return self.reply(400, {'error': 'bad Content-Length'})
            if size < 0 or size > MAX_BODY:
                return self.reply(413, {'error': 'body too large'})
            body = self.rfile.read(size) if size else b''
            ip = self.headers.get('X-Real-IP') or self.client_address[0]
            with lock:
                db.execute('INSERT INTO events (at, name, method, path, query, headers, body, ip) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
                           (time.time(), name, self.command, url.path, url.query, json.dumps(list(self.headers.items())), body, ip))
                db.execute('DELETE FROM events WHERE id <= (SELECT MAX(id) FROM events) - ?', (KEEP,))
                db.commit()
            self.reply(200, {'ok': True})

        def events(self, url):
            if not self.authorized():
                return self.reply(401, {'error': 'bad token'})
            try:
                after = int((parse_qs(url.query).get('after') or ['0'])[0])
            except ValueError:
                return self.reply(400, {'error': 'bad after'})
            cols = 'id, at, name, method, path, query, headers, body, ip'
            with lock:
                if after > 0:
                    rows = db.execute(f'SELECT {cols} FROM events WHERE id > ? ORDER BY id LIMIT 200', (after,)).fetchall()
                else:
                    rows = db.execute(f'SELECT {cols} FROM events ORDER BY id DESC LIMIT ?', (FIRST_POLL,)).fetchall()[::-1]
            self.reply(200, [{
                'id': r[0], 'at': r[1], 'name': r[2], 'method': r[3], 'path': r[4], 'query': r[5],
                'headers': json.loads(r[6]), 'body': base64.b64encode(r[7]).decode(), 'ip': r[8],
            } for r in rows])

        do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = handle_any

        def log_message(self, *args):
            pass  # bodies may hold secrets; nginx keeps the access log

    return Handler


def main():
    token = os.environ.get('RELAY_TOKEN', '')
    if len(token) < 24:
        raise SystemExit('RELAY_TOKEN must be set (24+ characters)')
    mcp_secret = os.environ.get('MCP_SECRET', '')
    if mcp_secret and len(mcp_secret) < 24:
        raise SystemExit('MCP_SECRET must be 24+ characters')
    db = open_db(os.environ.get('RELAY_DB', '/data/relay.db'))
    server = ThreadingHTTPServer(('0.0.0.0', int(os.environ.get('RELAY_PORT', '8000'))), make_handler(db, token, mcp_secret))
    server.serve_forever()


if __name__ == '__main__':
    main()
