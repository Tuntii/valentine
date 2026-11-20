"""Self-check for relay.py: python -I relay/test_relay.py"""
import base64
import json
import os
import sys
import threading
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import relay  # noqa: E402

TOKEN = 'x' * 32
SECRET = 's' * 32
server = ThreadingHTTPServer(('127.0.0.1', 0), relay.make_handler(relay.open_db(':memory:'), TOKEN, SECRET))
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f'http://127.0.0.1:{server.server_port}'


def call(path, method='GET', body=None, headers=None):
    req = urllib.request.Request(base + path, data=body, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


auth = {'Authorization': 'Bearer ' + TOKEN}
assert call('/h/stripe?x=1', 'POST', b'{"a":1}', {'Content-Type': 'application/json', 'Stripe-Signature': 't=1'})[0] == 200
assert call('/h/github', 'PUT', b'\x00\xffbin')[0] == 200
assert call('/h/bad%20name')[0] == 404
assert call('/h/')[0] == 404
assert call('/api/events')[0] == 401
assert call('/api/events', headers={'Authorization': 'Bearer wrong'})[0] == 401

code, events = call('/api/events', headers=auth)
assert code == 200 and len(events) == 2, events
first = events[0]
assert first['name'] == 'stripe' and first['method'] == 'POST' and first['query'] == 'x=1'
assert base64.b64decode(first['body']) == b'{"a":1}'
assert ['Stripe-Signature', 't=1'] in first['headers']
assert base64.b64decode(events[1]['body']) == b'\x00\xffbin'

code, newer = call(f'/api/events?after={first["id"]}', headers=auth)
assert [e['name'] for e in newer] == ['github']
assert call('/api/events?after=nope', headers=auth)[0] == 400

for _ in range(relay.KEEP + 5):
    call('/h/flood', 'POST', b'.')
code, latest = call('/api/events', headers=auth)
assert len(latest) == relay.FIRST_POLL and latest[-1]['name'] == 'flood'

# MCP bridge: a client POSTs JSON-RPC, a fake Valentine polls and answers.
rpc = json.dumps({'jsonrpc': '2.0', 'id': 7, 'method': 'tools/list'}).encode()
assert call('/mcp/' + 'w' * 32, 'POST', rpc)[0] == 404
assert call('/api/mcp/next')[0] == 401
assert call('/api/mcp/reply?id=1', 'POST', b'{}')[0] == 401
code, offline = call('/mcp/' + SECRET, 'POST', rpc)
assert code == 200 and offline['id'] == 7 and 'not running' in offline['error']['message'], offline
relay.POLL_WAIT = 0.2
assert call('/api/mcp/next', headers=auth) == (200, {})  # nothing queued; marks the PC online


def fake_valentine():
    code, job = call('/api/mcp/next', headers=auth)
    while not job:
        code, job = call('/api/mcp/next', headers=auth)
    req = json.loads(job['body'])
    answer = json.dumps({'jsonrpc': '2.0', 'id': req['id'], 'result': {'tools': []}}).encode()
    assert call(f'/api/mcp/reply?id={job["id"]}', 'POST', answer, auth)[0] == 200


threading.Thread(target=fake_valentine, daemon=True).start()
assert call('/mcp/' + SECRET, 'POST', rpc) == (200, {'jsonrpc': '2.0', 'id': 7, 'result': {'tools': []}})
note = urllib.request.Request(base + '/mcp/' + SECRET, data=b'{"jsonrpc":"2.0","method":"notifications/initialized"}', method='POST')
with urllib.request.urlopen(note) as r:
    assert r.status == 202 and r.read() == b''
try:
    urllib.request.urlopen(base + '/mcp/' + SECRET)
    raise AssertionError('GET /mcp/ must be refused')
except urllib.error.HTTPError as e:
    assert e.code == 405
assert call('/api/mcp/reply?id=999', 'POST', b'{}', auth)[0] == 200  # unknown id: dropped
server.shutdown()
print('relay ok')
