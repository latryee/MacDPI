#!/usr/bin/env python3
"""Bounded loopback-only integration and benchmark suite; no network configuration changes."""
import argparse, concurrent.futures, contextlib, json, os, pathlib, platform, select
import socket, socketserver, ssl, statistics, struct, subprocess, tempfile, threading, time

ROOT = pathlib.Path(__file__).resolve().parents[1]

def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]

class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    def handle_error(self, *args): pass

class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        try:
            while True:
                data = self.request.recv(16384)
                if not data:
                    self.request.sendall(b'END')
                    return
                self.request.sendall(data)
        except (OSError, TimeoutError): pass

class TLSHandler(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            with self.server.context.wrap_socket(self.request, server_side=True) as s:
                s.settimeout(5)
                data = s.recv(8192)
                if data.startswith(b'GET '):
                    s.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\nMacDPI!')
        except (OSError, ssl.SSLError): pass

@contextlib.contextmanager
def server(handler):
    instance = Server(('127.0.0.1', 0), handler)
    t = threading.Thread(target=instance.serve_forever, daemon=True)
    t.start()
    try: yield instance
    finally: instance.shutdown(); instance.server_close(); t.join(2)

@contextlib.contextmanager
def proxy(binary, target, profile='standard', extra=(), allow=True, listen_port=None):
    port = listen_port or free_port()
    command = [str(binary), '--port', str(port), '--profile', profile, '--destination-port', str(target)]
    if allow: command.append('--allow-loopback-testing')
    process = subprocess.Popen(command + list(extra), cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        ready, _, _ = select.select([process.stdout], [], [], 15)
        assert ready, 'Proxy startup deadline exceeded'
        line = process.stdout.readline().strip()
        assert line.startswith('READY'), (line, process.poll())
        yield port, process
    finally:
        if process.poll() is None: process.terminate()
        stdout, stderr = process.communicate(timeout=10)
        process.final_output = stdout
        assert process.returncode == 0, (process.returncode, stderr)


def connect(port, target, prefix=b'', host='127.0.0.1'):
    s = socket.create_connection(('127.0.0.1', port), timeout=5)
    s.sendall(f'CONNECT {host}:{target} HTTP/1.1\r\nHost: localhost\r\n\r\n'.encode() + prefix)
    response = b''
    while not response.endswith(b'\r\n\r\n'):
        chunk = s.recv(1)
        assert chunk, response
        response += chunk
    assert response.startswith(b'HTTP/1.1 200'), response
    return s

def exact(s, n):
    data = bytearray()
    while len(data) < n:
        chunk = s.recv(n-len(data))
        assert chunk, (len(data), n)
        data.extend(chunk)
    return bytes(data)

def sample(process):
    result = subprocess.check_output(['/bin/ps', '-p', str(process.pid), '-o', 'rss=', '-o', 'time='], text=True).strip().split()
    rss = int(result[0])
    parts = result[1].split(':')
    cpu = sum(float(n) * 60**i for i, n in enumerate(reversed(parts)))
    return {'rss_kib': rss, 'cpu_seconds': cpu}

def run(binary):
    report = {'date': time.strftime('%Y-%m-%d'), 'os': platform.platform(), 'architecture': platform.machine(), 'tests': [], 'benchmarks': {}}
    def passed(name):
        report['tests'].append(name)
        print('PASS', name, flush=True)
    with server(Echo) as echo:
        target = echo.server_address[1]
        with proxy(binary, target) as (port, process):
            with connect(port, target, b'pipelined-data') as s:
                assert exact(s, 14) == b'pipelined-data'
            passed('CONNECT with pipelined tunnel data')
            with connect(port, target, host='localhost') as s:
                s.sendall(b'resolved'); assert exact(s, 8) == b'resolved'
            passed('system resolver localhost and numeric-address forwarding')
            payload = bytes(range(256)) * 1024
            def transfer(_):
                with connect(port, target) as s:
                    for start in range(0, len(payload), 16384):
                        chunk = payload[start:start+16384]
                        s.sendall(chunk); assert exact(s, len(chunk)) == chunk
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                list(pool.map(transfer, range(16)))
            passed('16 concurrent streams, 8 workers, 4 MiB integrity')
            with connect(port, target) as s:
                s.sendall(b'half-close'); s.shutdown(socket.SHUT_WR)
                received = b''
                while True:
                    chunk = s.recv(1024)
                    if not chunk: break
                    received += chunk
                assert received == b'half-closeEND', received
            passed('client half-close preserves final server bytes')
            with socket.create_connection(('127.0.0.1', port), timeout=3) as s:
                s.sendall(b'GET / HTTP/1.1\r\n\r\n'); assert b'400' in s.recv(1024)
            passed('malformed CONNECT rejected')
            with socket.create_connection(('127.0.0.1', port), timeout=3) as s:
                s.sendall(b'CONNECT 127.0.0.1:1 HTTP/1.1\r\n\r\n'); assert b'403' in s.recv(1024)
            passed('disallowed destination port rejected')
            for _ in range(20):
                with connect(port, target) as s:
                    s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
            transfer(0)
            passed('connection reset and recovery')
            time.sleep(.3)
            before = sample(process); start = time.monotonic(); time.sleep(5); after = sample(process)
            report['benchmarks']['engine_idle'] = {'interval_seconds': time.monotonic()-start, 'cpu_percent': round((after['cpu_seconds']-before['cpu_seconds'])/(time.monotonic()-start)*100, 3), 'rss_mib': round(after['rss_kib']/1024, 2)}
            baseline, proxied = [], []
            for proxied_mode, times in [(False, baseline), (True, proxied)]:
                for _ in range(20):
                    start = time.perf_counter()
                    with (connect(port, target) if proxied_mode else socket.create_connection(('127.0.0.1', target), timeout=5)) as s:
                        s.sendall(b'x'); assert exact(s, 1) == b'x'
                    times.append((time.perf_counter()-start)*1000)
            report['benchmarks']['connect_echo_ms'] = {'baseline_median': statistics.median(baseline), 'proxy_median': statistics.median(proxied), 'samples_each': 20}
            for proxied_mode in [False, True]:
                with (connect(port, target) if proxied_mode else socket.create_connection(('127.0.0.1', target), timeout=5)) as s:
                    chunk = bytes(range(256))*256
                    start = time.perf_counter()
                    for _ in range(64): s.sendall(chunk); assert exact(s, len(chunk)) == chunk
                    elapsed = time.perf_counter()-start
                report['benchmarks']['proxy' if proxied_mode else 'baseline'] = {'roundtrip_mib_per_second': 8/elapsed, 'payload_mib_each_direction': 4, 'seconds': elapsed}
            with connect(port, target) as s:
                s.sendall(b'x'); assert exact(s, 1) == b'x'
                before_active = sample(process)
                started = time.monotonic()
                chunk = bytes(range(256))*256
                for index in range(300):
                    s.sendall(chunk); assert exact(s, len(chunk)) == chunk
                    time.sleep(max(0, started + (index+1)*.01 - time.monotonic()))
                active_elapsed = time.monotonic()-started
                after_active = sample(process)
                report['benchmarks']['paced_active'] = {
                    'interval_seconds': active_elapsed,
                    'payload_mib_each_direction': 300*len(chunk)/(1024*1024),
                    'engine_cpu_percent': round((after_active['cpu_seconds']-before_active['cpu_seconds'])/active_elapsed*100, 3),
                    'engine_rss_mib': after_active['rss_kib']/1024}
            before = sample(process)
            for _ in range(150):
                with connect(port, target) as s: s.sendall(b'x'); assert exact(s, 1) == b'x'
            time.sleep(.5)
            after = sample(process)
            report['benchmarks']['memory_stability'] = {'connections': 150, 'before_rss_mib': before['rss_kib']/1024, 'after_rss_mib': after['rss_kib']/1024}
            passed('150 sequential connections and memory sample')
        stats = json.loads(process.final_output.strip().splitlines()[-1])
        assert stats['state'] == 'disabled' and stats['activeConnections'] == 0, stats
        report['engine_final_snapshot'] = stats
        try:
            socket.create_connection(('127.0.0.1', port), timeout=.5)
            raise AssertionError('Listener still active')
        except ConnectionRefusedError: pass
        passed('stop releases listener and all sessions')
        with proxy(binary, target, allow=False) as (port, _):
            with socket.create_connection(('127.0.0.1', port), timeout=3) as s:
                s.sendall(f'CONNECT 127.0.0.1:{target} HTTP/1.1\r\n\r\n'.encode())
                assert b'403' in s.recv(1024)
        passed('private address blocked by production policy')
        with proxy(binary, target, extra=['--handshake-timeout','1', '--max-connections','2']) as (port, _):
            clients = [socket.create_connection(('127.0.0.1', port), timeout=3) for _ in range(2)]
            try:
                time.sleep(.1)
                with socket.create_connection(('127.0.0.1', port), timeout=3) as excess:
                    try: assert excess.recv(1) == b''
                    except ConnectionResetError: pass
                time.sleep(1.2)
                for s in clients: assert s.recv(1) == b''
            finally:
                for s in clients: s.close()
            with connect(port, target) as s: s.sendall(b'x'); assert exact(s, 1) == b'x'
        passed('capacity, handshake timeout, and capacity recovery')
        with proxy(binary, target, extra=['--idle-timeout','5']) as (port, _):
            with connect(port, target) as s:
                s.settimeout(8); s.sendall(b'x'); assert exact(s, 1) == b'x'
                started = time.monotonic(); assert s.recv(1) == b''
                assert 4.5 <= time.monotonic()-started <= 7.5
        passed('idle tunnel deadline')
        with proxy(binary, target) as (port, process):
            active = connect(port, target)
            active.sendall(b'active'); assert exact(active, 6) == b'active'
        try: assert active.recv(1) == b''
        finally: active.close()
        assert json.loads(process.final_output.strip().splitlines()[-1])['activeConnections'] == 0
        passed('disable cancels an active tunnel')
        with proxy(binary, target, listen_port=port) as (restarted_port, _):
            with connect(restarted_port, target) as s:
                s.sendall(b'restart'); assert exact(s, 7) == b'restart'
        passed('same-port restart after active tunnel shutdown')
        dead = free_port()
        with proxy(binary, dead) as (port, _):
            with socket.create_connection(('127.0.0.1', port), timeout=3) as s:
                s.sendall(f'CONNECT 127.0.0.1:{dead} HTTP/1.1\r\n\r\n'.encode())
                assert s.recv(1024) == b''
        passed('failed upstream connection closes safely')
        with proxy(binary, target, extra=['--handshake-timeout','1']) as (port, _):
            with connect(port, target) as s:
                s.sendall(b'\x16\x03\x01\x00\x80\x01')
                assert s.recv(1) == b''
        passed('incomplete TLS handshake deadline')
    fixture_dir = ROOT / 'build' / 'tls-fixtures'
    fixture_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=fixture_dir) as tmp:
        key, cert = pathlib.Path(tmp)/'key.pem', pathlib.Path(tmp)/'cert.pem'
        subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=localhost','-keyout',str(key),'-out',str(cert)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        with server(TLSHandler) as tls:
            tls.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); tls.context.load_cert_chain(cert, key)
            target = tls.server_address[1]
            for profile in ['standard','compatibility','advanced']:
                with proxy(binary, target, profile) as (port, process):
                    for version in [ssl.TLSVersion.TLSv1_2]:
                        context = ssl.create_default_context(cafile=str(cert)); context.check_hostname = False
                        context.minimum_version = version; context.maximum_version = version
                        with context.wrap_socket(connect(port, target), server_hostname='localhost') as s:
                            s.sendall(b'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n')
                            response = b''
                            while True:
                                chunk = s.recv(4096)
                                if not chunk: break
                                response += chunk
                            assert response.endswith(b'MacDPI!'), response
                    passed(f'{profile}: TLS 1.2 verified fixture handshake')
                stats = json.loads(process.final_output.strip().splitlines()[-1])
                assert stats['transformed'] == (0 if profile == 'compatibility' else 1), stats
            with proxy(binary, target) as (port, _):
                context = ssl.create_default_context()
                try:
                    with context.wrap_socket(connect(port, target), server_hostname='localhost'): pass
                    raise AssertionError('Untrusted fixture certificate was accepted')
                except ssl.SSLCertVerificationError: pass
            passed('end-to-end certificate rejection remains enforced')
        # TLS 1.3 uses a native loopback fixture with a strictly memory-only identity (macOS 15+).
        target = free_port()
        identity = pathlib.Path(tmp)/'identity.p12'
        subprocess.run(['openssl','pkcs12','-export','-inkey',str(key),'-in',str(cert),'-out',str(identity),'-passout','pass:macdpi-fixture'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        tls13 = subprocess.Popen([str(ROOT/'build/tls-fixture'), str(target), str(identity)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            ready, _, _ = select.select([tls13.stdout], [], [], 8)
            assert ready and tls13.stdout.readline().strip() == b'READY', 'Native TLS 1.3 fixture failed'
            for profile in ['standard','compatibility','advanced']:
                with proxy(binary, target, profile) as (port, process):
                    client = subprocess.run(['openssl','s_client','-proxy',f'127.0.0.1:{port}','-connect',f'127.0.0.1:{target}','-servername','localhost','-CAfile',str(cert),'-verify_return_error','-tls1_3','-quiet'], input=b'GET / HTTP/1.0\r\nHost: localhost\r\n\r\n', stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=8)
                    assert client.returncode == 0 and b'HTTP/1.0 200' in client.stdout, (client.returncode, client.stderr)
                stats = json.loads(process.final_output.strip().splitlines()[-1])
                assert stats['transformed'] == (0 if profile == 'compatibility' else 1), stats
                passed(f'{profile}: TLS 1.3 verified fixture handshake (system openssl)')
        finally:
            tls13.terminate(); tls13.wait(timeout=5)
    return report

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=pathlib.Path, default=ROOT/'build/swift/release/macdpi')
    parser.add_argument('--report', type=pathlib.Path, default=ROOT/'build/reports/integration.json')
    args = parser.parse_args()
    result = run(args.binary.resolve())
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result['benchmarks'], indent=2))
