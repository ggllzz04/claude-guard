#!/usr/bin/env python3
"""Isolated polling regression: synthetic API + loopback listener + disposable mock.
Does not connect to, edit, stop, or reconfigure the user's Clash or Claude.
"""
import copy
import http.server
import json
import pathlib
import re
import socket
import socketserver
import subprocess
import tempfile
import threading
import time
import os
import shutil

ROOT = pathlib.Path(__file__).resolve().parent.parent
BIN = pathlib.Path(subprocess.check_output(['swift', 'build', '-c', 'release', '--show-bin-path'], cwd=ROOT, text=True).strip())
results = []
state = {'fault': 'healthy', 'endpoint': '/configs'}


def check(condition, name, **details):
    row = {'name': name, 'passed': bool(condition), **details}
    results.append(row)
    print(json.dumps(row, ensure_ascii=False), flush=True)
    if not condition:
        raise AssertionError(name)


class Listener:
    def __init__(self):
        self.sock = socket.socket()
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(('127.0.0.1', 0))
        self.port = self.sock.getsockname()[1]
        self.sock.listen(16)
        self.sock.settimeout(.1)
        self.running = True
        threading.Thread(target=self.accept, daemon=True).start()

    def accept(self):
        while self.running:
            try:
                conn, _ = self.sock.accept()
                conn.close()
            except socket.timeout:
                pass
            except OSError:
                return

    def close(self):
        self.running = False
        self.sock.close()


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


with tempfile.TemporaryDirectory(prefix='cg-polling-', dir='/private/tmp') as temp:
    temp = pathlib.Path(temp)
    listener = Listener()
    # Only read local interface information. No request is made to the real Clash API.
    route = subprocess.check_output(['/sbin/route', '-n', 'get', '1.1.1.1'], text=True)
    device = re.search(r'interface:\s*(\S+)', route).group(1)
    interface = subprocess.check_output(['/sbin/ifconfig', device], text=True)
    address = re.search(r'\binet\s+(\S+)', interface).group(1)
    responses = {
        '/configs': {'mode': 'rule', 'mixed-port': listener.port, 'port': 7897, 'socks-port': 7897,
                     'tun': {'enable': True, 'device': device, 'auto-route': True, 'inet4-address': [address + '/30']},
                     'sniffer': {'enable': True}},
        '/proxies': {'proxies': {'🤖 AI': {'type': 'Selector', 'now': 'Approved', 'all': ['Approved']},
                                'Approved': {'type': 'AnyTLS'}, 'DIRECT': {'type': 'Direct'}}},
        '/rules': {'rules': [{'type': 'Match', 'payload': '', 'proxy': '🤖 AI'}]},
        '/version': {'version': 'fixture'},
        '/connections': {'connections': []},
    }

    class Handler(http.server.BaseHTTPRequestHandler):
        def handle(self):
            try:
                super().handle()
            except (BrokenPipeError, ConnectionResetError):
                # Expected when the injected stall exceeds the client's deadline.
                pass

        def log_message(self, *_):
            pass

        def do_GET(self):
            fault, endpoint = state['fault'], state['endpoint']
            value = copy.deepcopy(responses.get(self.path, {}))
            if fault == 'slow' and self.path == endpoint:
                time.sleep(.8)
            if fault == 'stall' and self.path in ['/configs', '/proxies', '/rules']:
                time.sleep(4)
            if fault == 'failed' and (endpoint == 'all' or self.path == endpoint):
                self.send_error(503)
                return
            if fault == 'malformed' and self.path == endpoint:
                value = {}
            if fault == 'tun-off' and self.path == '/configs':
                value['tun']['enable'] = False
            if fault == 'mode-global' and self.path == '/configs':
                value['mode'] = 'global'
            if fault == 'ai-direct' and self.path == '/proxies':
                value['proxies']['🤖 AI']['now'] = 'DIRECT'
            if fault == 'rules-direct' and self.path == '/rules':
                value['rules'][0]['proxy'] = 'DIRECT'
            body = json.dumps(value).encode()
            if fault == 'chunk-valid':
                self.send_response(200)
                self.send_header('Transfer-Encoding', 'chunked')
                self.end_headers()
                self.wfile.write(f'{len(body):x}\r\n'.encode() + body + b'\r\n0\r\n\r\n')
                return
            self.send_response(200)
            self.send_header('Content-Length', str(len(body) + (10 if fault == 'truncated' else 0)))
            self.end_headers()
            try:
                self.wfile.write(body)
                self.wfile.flush()
                if fault == 'late-close':
                    time.sleep(1)
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = Server(str(temp / 'api.sock'), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    for fault, endpoint, expected in [('late-close', '/configs', 0), ('chunk-valid', '/raw', 0),
                                      ('truncated', '/configs', 1), ('malformed', '/configs', 1),
                                      ('malformed', '/proxies', 1), ('malformed', '/rules', 1)]:
        state.update(fault=fault, endpoint=endpoint)
        started = time.monotonic()
        run = subprocess.run([str(BIN / 'GuardBench'), '--api-check', str(temp / 'api.sock'), endpoint, '.25'],
                             capture_output=True, text=True, timeout=4)
        check(run.returncode == expected, f'HTTP {fault} {endpoint}', ms=round((time.monotonic()-started)*1000, 1))
    state.update(fault='healthy')
    conf = temp / 'settings'
    conf.mkdir()
    settings = dict(enforce=True, manageDesktop=True, manageCode=False, canaryEnabled=False, pollInterval=.25,
                    approvedNodeName='Approved', approvedNodeType='AnyTLS', auditMode='standard')
    (conf / 'settings.json').write_text(json.dumps(settings))
    mock = temp / 'GuardMock'
    shutil.copy2(BIN / 'GuardMock', mock)
    env = {**os.environ, 'CLAUDE_GUARD_TEST_MOCK': str(mock), 'CLAUDE_GUARD_CLASH_SOCKET': str(temp / 'api.sock')}
    snapshots = []
    arrivals = []
    host = subprocess.Popen([str(BIN / 'GuardBench'), str(conf)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def collect():
        for line in host.stdout:
            try:
                snapshots.append(json.loads(line))
                arrivals.append(time.monotonic())
            except json.JSONDecodeError:
                pass
    threading.Thread(target=collect, daemon=True).start()

    def wait(predicate, timeout=9):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if snapshots and predicate(snapshots[-1]):
                return snapshots[-1]
            if host.poll() is not None:
                raise RuntimeError(host.stderr.read())
            time.sleep(.04)
        raise TimeoutError(json.dumps(snapshots[-1] if snapshots else {}, ensure_ascii=False))

    def healthy():
        state.update(fault='healthy')
        wait(lambda s: not s.get('lastError') and not any(c['severity'] == 'critical' for c in s['checks']) and
             any(c['id'] == 'rules' for c in s['checks']))

    children = []
    def child():
        process = subprocess.Popen([str(mock), '--hold'], stdout=subprocess.DEVNULL)
        children.append(process)
        time.sleep(.15)
        check(process.poll() is None, 'Mock alive before injection')
        return process

    try:
        healthy()
        managed = child()
        for endpoint in ['/configs', '/proxies', '/rules']:
            start = len(snapshots)
            state.update(fault='slow', endpoint=endpoint)
            time.sleep(5)
            check(managed.poll() is None and not any(s['state'] == 'blocked' for s in snapshots[start:]),
                  f'800 ms {endpoint} never closes mock', snapshots=len(snapshots)-start)
            healthy()
        state.update(fault='failed', endpoint='all')
        warning = wait(lambda s: s.get('lastError') and s['state'] == 'attention')
        time.sleep(3)
        check(managed.poll() is None, 'Short API outage is yellow without closing')
        healthy()
        started = time.monotonic()
        state.update(fault='stall')
        wait(lambda s: s.get('lastError') and s['state'] == 'attention', timeout=6)
        time.sleep(max(0, 8 - (time.monotonic() - started)))
        check(managed.poll() is None and snapshots[-1]['state'] == 'attention',
              'Eight seconds of real request timeouts never closes a healthy proxy')
        healthy()
        for endpoint in ['/configs', '/proxies', '/rules']:
            state.update(fault='malformed', endpoint=endpoint)
            wait(lambda s: endpoint in (s.get('lastError') or ''))
            time.sleep(.4)
            check(managed.poll() is None and snapshots[-1]['state'] != 'blocked', f'Malformed {endpoint} never synthesizes a confirmed fault')
            healthy()
        # A live proxy with a persistently unreadable monitoring endpoint is not trusted forever.
        state.update(fault='failed', endpoint='/configs')
        started = time.monotonic()
        managed.wait(timeout=20)
        elapsed = time.monotonic()-started
        check(elapsed >= 15, 'Persistent unreadable API only closes after grace', seconds=round(elapsed, 2))
        closed = wait(lambda s: any('关闭了' in e['title'] for e in s['events']))
        check(any('/configs' in e['detail'] for e in closed['events'] if '关闭了' in e['title']), 'Close log contains endpoint and exact failure')
        healthy()
        for fault, limit in [('tun-off', 3), ('mode-global', 3), ('ai-direct', 4), ('rules-direct', 6)]:
            managed = child()
            started = time.monotonic()
            state.update(fault=fault)
            managed.wait(timeout=limit)
            check(True, f'Confirmed {fault} still closes promptly', ms=round((time.monotonic()-started)*1000, 1))
            healthy()
        managed = child()
        state.update(fault='stall')
        wait(lambda s: s.get('lastError') and s['state'] == 'attention', timeout=6)
        started = time.monotonic()
        listener.close()
        managed.wait(timeout=3)
        wait(lambda s: any(c['id'] == 'proxyPort' and c['severity'] == 'critical' for c in s['checks']))
        check(True, 'Local port outage closes while all API readers stall', ms=round((time.monotonic()-started)*1000, 1))
        # Refreshes should keep arriving while remote reads are slow.
        gaps = [b-a for a,b in zip(arrivals, arrivals[1:])]
        check(max(gaps, default=0) < 1.5, 'Polling loop remains responsive', maxGap=round(max(gaps, default=0),3))
    finally:
        host.terminate()
        try:
            host.wait(timeout=3)
        except subprocess.TimeoutExpired:
            host.kill(); host.wait()
        for process in children:
            if process.poll() is None:
                process.terminate(); process.wait(timeout=3)
        listener.close()
        server.shutdown()
        (ROOT / 'build').mkdir(exist_ok=True)
        (ROOT / 'build/polling-regression.json').write_text(json.dumps({'results':results, 'snapshots':snapshots}, ensure_ascii=False, indent=2))
