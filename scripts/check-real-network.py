#!/usr/bin/env python3
"""Explicit opt-in public endpoint check. No account, token, global proxy, DNS, or route changes."""
import argparse
import base64
import concurrent.futures
import contextlib
import hashlib
import json
import pathlib
import select
import socket
import ssl
import struct
import subprocess
import tempfile
import time
from datetime import datetime
from zoneinfo import ZoneInfo

ROOT = pathlib.Path(__file__).resolve().parents[1]
TARGETS = {
    'discord_gateway_api': 'https://discord.com/api/v10/gateway',
    'roblox_website': 'https://www.roblox.com/',
    'roblox_public_api': 'https://users.roblox.com/v1/users/1',
}


@contextlib.contextmanager
def proxy(binary, profile):
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    process = subprocess.Popen([str(binary), '--port', str(port), '--profile', profile,
                                '--dns', 'cloudflare', '--duration', '45'],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        assert select.select([process.stdout], [], [], 8)[0], 'Listener startup deadline'
        assert process.stdout.readline().startswith('READY'), 'Listener startup failed'
        yield port, process
    finally:
        if process.poll() is None:
            process.terminate()
        try:
            stdout, _ = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            stdout, _ = process.communicate()
        process.snapshot = json.loads(stdout.strip().splitlines()[-1]) if stdout.strip() else {}


def request(item, port=None):
    name, url = item
    with tempfile.TemporaryDirectory(prefix='public-check-', dir=ROOT / 'build') as directory:
        body = pathlib.Path(directory) / 'response'
        args = ['curl', '--proxy', f'http://127.0.0.1:{port}' if port else '', '--noproxy', '',
                '--http1.1', '--silent', '--show-error', '--connect-timeout', '8', '--max-time', '12',
                '--max-filesize', '1048576', '--output', str(body), '--write-out',
                '%{http_code} %{time_appconnect} %{time_total} %{ssl_verify_result}', url]
        result = subprocess.run(args, capture_output=True, text=True, timeout=15)
        metrics = result.stdout.split()
        status = int(metrics[0]) if metrics else 0
        valid_body = False
        if result.returncode == 0 and status == 200:
            data = body.read_bytes()
            if name == 'discord_gateway_api':
                valid_body = json.loads(data).get('url') == 'wss://gateway.discord.gg'
            elif name == 'roblox_public_api':
                valid_body = json.loads(data).get('id') == 1
            else:
                valid_body = b'<html' in data.lower() and b'roblox' in data.lower()
        # Aggregate results only; the body, remote address and error text are not persisted.
        return {'service': name, 'http_status': status, 'curl_exit': result.returncode,
                'tls_seconds': float(metrics[1]) if len(metrics) > 1 else None,
                'total_seconds': float(metrics[2]) if len(metrics) > 2 else None,
                'certificate_verified': result.returncode == 0 and metrics[-1] == '0',
                'expected_response': valid_body}


def websocket_hello(port):
    started = time.monotonic()
    try:
        with socket.create_connection(('127.0.0.1', port), timeout=8) as raw:
            raw.sendall(b'CONNECT gateway.discord.gg:443 HTTP/1.1\r\nHost: gateway.discord.gg:443\r\n\r\n')
            def header(stream):
                out = bytearray()
                while not out.endswith(b'\r\n\r\n'):
                    chunk = stream.recv(1)
                    if not chunk or len(out) >= 16_384:
                        raise ValueError('Incomplete header')
                    out.extend(chunk)
                return bytes(out)
            assert header(raw).startswith(b'HTTP/1.1 200 ')
            with ssl.create_default_context().wrap_socket(raw, server_hostname='gateway.discord.gg') as stream:
                key = base64.b64encode(b'MacDPI-check-001!').decode()
                stream.sendall(('GET /?v=10&encoding=json HTTP/1.1\r\nHost: gateway.discord.gg\r\n'
                                'Connection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\n'
                                f'Sec-WebSocket-Key: {key}\r\n\r\n').encode())
                reply = header(stream)
                assert reply.startswith(b'HTTP/1.1 101 ')
                expected = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
                assert expected in reply
                def exact(n):
                    out = bytearray()
                    while len(out) < n:
                        part = stream.recv(n-len(out))
                        if not part:
                            raise ValueError('Incomplete frame')
                        out.extend(part)
                    return bytes(out)
                first, second = exact(2)
                assert first == 0x81 and not second & 0x80
                length = second & 127
                assert length != 127
                if length == 126:
                    length = struct.unpack('!H', exact(2))[0]
                assert length <= 16_384
                payload = json.loads(exact(length))
                assert payload.get('op') == 10 and payload['d']['heartbeat_interval'] > 0
                return {'tls_verified': True, 'http_status': 101, 'gateway_hello': True,
                        'seconds': round(time.monotonic()-started, 4)}
    except (OSError, ValueError, AssertionError, KeyError):
        return {'gateway_hello': False, 'seconds': round(time.monotonic()-started, 4)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--acknowledge-external-requests', action='store_true',
                        help='Contact public Discord/Roblox endpoints and Cloudflare DNS, without logging in.')
    parser.add_argument('--binary', type=pathlib.Path, default=ROOT / 'build/swift/release/macdpi')
    parser.add_argument('--report', type=pathlib.Path, default=ROOT / 'build/reports/real-network.json')
    args = parser.parse_args()
    if not args.acknowledge_external_requests:
        parser.error('This is not a local/CI test. Explicit --acknowledge-external-requests is required.')
    report = {'date': datetime.now(ZoneInfo('Europe/Istanbul')).isoformat(timespec='seconds'),
              'scope': 'Public HTTPS APIs/site and unauthenticated Discord WebSocket Hello only; no native game, voice or account test.',
              'system_settings_changed': False, 'tests': {}}
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        report['tests']['direct_system_dns'] = list(pool.map(request, TARGETS.items()))
    for profile in ['compatibility', 'standard']:
        with proxy(args.binary.resolve(), profile) as (port, process):
            with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
                results = list(pool.map(lambda item: request(item, port), TARGETS.items()))
            report['tests'][profile + '_cloudflare_doh'] = results
            if profile == 'standard':
                report['discord_websocket'] = websocket_hello(port)
        report[profile + '_snapshot'] = process.snapshot
        print(profile, json.dumps(results), flush=True)
    verified = all(r['expected_response'] and r['certificate_verified']
                   for r in report['tests']['standard_cloudflare_doh']) and report['discord_websocket']['gateway_hello']
    report['limited_check_passed'] = verified
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    print('Limited public endpoint check:', 'PASS' if verified else 'FAIL')
    print('Discord WebSocket:', report['discord_websocket'])
    return 0 if verified else 1


if __name__ == '__main__':
    raise SystemExit(main())
