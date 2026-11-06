#!/usr/bin/env python3
"""Owner-run Personal TUN smoke test. Requires a real terminal and explicit consent."""

import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import time
import uuid


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'build/personal/release/MacDPI.app'
HELPERS = APP / 'Contents/Helpers'
SNAPSHOT = ROOT / 'scripts/test-tun-route-snapshot.sh'
URL = 'https://example.com/'
CURL = ['/usr/bin/curl', '--disable', '--silent', '--show-error', '--noproxy', '*']
DISCORD = 'discord.com'
GATEWAY_API = f'https://{DISCORD}/api/v10/gateway'
POLICY_FIELDS = {'primary-service', 'physical-defaults', 'interfaces', 'protected-prefixes',
                 'dns', 'proxies', 'service-order', 'network-policy'}


def run(argv, timeout, *, capture=False):
    return subprocess.run(argv, cwd=ROOT, check=True, text=True, timeout=timeout,
                          capture_output=capture)


def fingerprint():
    output = run([SNAPSHOT, '--fingerprint'], 20, capture=True).stdout
    fields = re.findall(r'^([a-z-]+) ([0-9a-f]{64})$', output, re.MULTILINE)
    if len(fields) != len(POLICY_FIELDS) or dict(fields).keys() != POLICY_FIELDS:
        raise RuntimeError('The read-only check did not return all eight policy fingerprints.')
    return dict(fields)


def probe(stage):
    run(CURL + ['--fail', '--max-time', '8', '--output', '/dev/null', URL], 10)
    print(f'{stage}: certificate-verified HTTPS passed.', flush=True)


def discord_doh_address():
    url = f'https://cloudflare-dns.com/dns-query?name={DISCORD}&type=A'
    try:
        output = run(CURL + ['--fail', '--max-time', '6', '--max-filesize', '16384',
                             '--resolve', 'cloudflare-dns.com:443:1.1.1.1',
                             '--header', 'Accept: application/dns-json', url], 8, capture=True)
        message = json.loads(output.stdout)
        if message['Status'] == 0:
            for answer in message.get('Answer', []):
                if answer['type'] == 1:
                    address = ipaddress.IPv4Address(answer['data'])
                    if address.is_global and not address.is_multicast and not address.is_reserved:
                        return str(address)
    except (ValueError, KeyError, TypeError, subprocess.SubprocessError):
        pass
    raise RuntimeError('The Discord probe could not obtain a public IPv4 address from Cloudflare DoH.')


def route_interface(address):
    output = run(['/sbin/route', '-n', 'get', '-inet', address], 3, capture=True).stdout
    match = re.search(r'^\s*interface:\s+(\w+)\s*$', output, re.MULTILINE)
    if not match:
        raise RuntimeError('Could not identify the selected route for the Discord probe.')
    return match.group(1)


def discord_gateway(stage, address=None):
    pinned = ['--resolve', f'{DISCORD}:443:{address}'] if address else []
    result = subprocess.run(CURL + ['--ipv4', '--fail', '--max-time', '6', '--max-filesize', '16384']
                            + pinned + [GATEWAY_API], cwd=ROOT, text=True, capture_output=True, timeout=8)
    valid = False
    if result.returncode == 0:
        try:
            valid = json.loads(result.stdout).get('url') == 'wss://gateway.discord.gg'
        except (ValueError, AttributeError):
            pass
    path = 'same pinned DoH address' if address else 'system DNS'
    detail = 'verified gateway response' if valid else f'no verified gateway response (curl {result.returncode})'
    print(f'{stage}: Discord via {path}: {detail}.', flush=True)
    return valid


class StatusReader:
    def __init__(self, stream):
        self.stream = stream
        self.buffer = bytearray()

    def wait(self, wanted, timeout):
        deadline = time.monotonic() + timeout
        with selectors.DefaultSelector() as selector:
            selector.register(self.stream, selectors.EVENT_READ)
            while time.monotonic() < deadline:
                while b'\n' in self.buffer:
                    line, _, rest = self.buffer.partition(b'\n')
                    self.buffer = bytearray(rest)
                    name = line.decode('ascii')
                    print(f'Engine: {name}', flush=True)
                    if name in wanted:
                        return name
                if not selector.select(max(0, deadline - time.monotonic())):
                    break
                chunk = os.read(self.stream.fileno(), 1024)
                if not chunk:
                    raise RuntimeError('The engine closed before reporting the expected state.')
                self.buffer.extend(chunk)
                if len(self.buffer) > 4096:
                    raise RuntimeError('Unexpected engine output.')
        raise TimeoutError('The engine did not report its state in time.')


def trial(check_discord, repair_origin):
    if os.geteuid() == 0 or not os.isatty(0):
        raise RuntimeError('Run this script as your normal user in Terminal.')
    run([ROOT / 'scripts/verify-release.sh', APP], 20)
    run([SNAPSHOT], 20)
    before = fingerprint()
    probe('Before Enable')
    discord_address = discord_doh_address() if check_discord else None
    if discord_address:
        discord_interface = route_interface(discord_address)
        existing_interfaces = set(run(['/sbin/ifconfig', '-l'], 3, capture=True).stdout.split())
        if discord_interface.startswith('utun'):
            raise RuntimeError('The baseline Discord route already uses a tunnel.')
        if discord_gateway('Before Enable') and repair_origin:
            raise RuntimeError('System DNS already reaches the Discord API. There is no failing baseline for origin repair.')
        discord_gateway('Before Enable', discord_address)
    print('One temporary TUN interface and its public routes will be created. System DNS settings will stay as found.', flush=True)
    if repair_origin:
        print('The engine will also test eligible TLS names using Cloudflare DoH.', flush=True)
    print('If macOS asks for a password, type it only in Terminal. Ctrl-C requests shutdown.', flush=True)
    run(['/usr/bin/sudo', '-v'], 120)

    session = str(uuid.uuid4())
    engine_args = [HELPERS / 'MacDPITUNEngine', session, '1', '32', '1' if repair_origin else '0', '']
    if repair_origin:
        engine_args.append('1')
    engine = subprocess.Popen(engine_args, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    status = StatusReader(engine.stdout)
    broker = None
    clean = False
    clean_states = {'DISABLED', 'FAILED_CLEAN', 'CANCELLED', 'AUTHORIZATION_TIMEOUT', 'HELPER_CONNECTION_FAILED'}
    terminal = clean_states | {'FAILED', 'RECOVERY_REQUIRED'}
    phase = None
    try:
        broker = subprocess.Popen(['/usr/bin/sudo', '-n', '--', HELPERS / 'MacDPITUNHelper', 'run', session])
        phase = status.wait(terminal | {'ACTIVE'}, 35)
        if phase != 'ACTIVE':
            raise RuntimeError('Activation was not verified.')
        probe('While Active')
        if discord_address:
            capture = route_interface(discord_address)
            if capture in existing_interfaces or not re.fullmatch(r'utun[0-9]+', capture):
                raise RuntimeError('The Discord probe address was not routed into the active tunnel.')
            system_discord_verified = discord_gateway('While Active')
            discord_verified = discord_gateway('While Active', discord_address)
    finally:
        engine.stdin.close()
        try:
            if phase not in terminal:
                phase = status.wait(terminal, 28)
            clean = phase in clean_states
        except (RuntimeError, TimeoutError) as error:
            print(error, flush=True)
        finally:
            try:
                engine.wait(timeout=3)
            except subprocess.TimeoutExpired:
                # Closing the worker's process also closes its descriptor and broker lease.
                engine.kill()
                engine.wait(timeout=3)
            if broker is not None:
                try:
                    broker.wait(timeout=12)
                except subprocess.TimeoutExpired:
                    clean = False
                    print('The route helper has not exited. Inspect its status before retrying.', flush=True)
            after = fingerprint()
            changed = sorted(key for key in before.keys() | after.keys() if before.get(key) != after.get(key))
            if changed:
                print('Policy fingerprints changed: ' + ', '.join(changed), flush=True)
            else:
                print('All eight policy fingerprints match the baseline.', flush=True)
            probe('After Disable')
            if discord_address and route_interface(discord_address) != discord_interface:
                clean = False
                print('The Discord probe route differs from its baseline.', flush=True)
            if not clean or changed:
                print('Cleanup requires review. Use the recovery procedure in docs/PERSONAL_TUN.md.', flush=True)
    if not clean or changed:
        raise RuntimeError('The full Enable/Disable trial was not verified.')
    print('PASS: real TUN activation, HTTPS and route restoration.', flush=True)
    if discord_address:
        discord_gateway('After Disable')
        discord_gateway('After Disable', discord_address)
        if not discord_verified:
            raise RuntimeError('The pinned Discord gateway request did not pass over the active tunnel.')
        print('PASS: the pinned public Discord gateway API responded over TUN. Desktop login and voice were outside this test.', flush=True)
        if repair_origin:
            if not system_discord_verified:
                raise RuntimeError('The Discord gateway still failed with the system DNS address and origin repair enabled.')
            print('PASS: Discord gateway API responded over TUN using the system DNS result with origin repair enabled.', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--approved', action='store_true', help='Authorize the temporary interface and route trial.')
    parser.add_argument('--discord', action='store_true', help='Also contact Cloudflare DoH and the public Discord gateway API. No login or DNS setting changes.')
    parser.add_argument('--repair-origin', action='store_true', help='Enable TLS origin repair for the Discord comparison.')
    args = parser.parse_args()
    if not args.approved:
        parser.error('Run with --approved only after reviewing the first trial in docs/PERSONAL_TUN.md.')
    if args.repair_origin and not args.discord:
        parser.error('--repair-origin requires --discord.')
    try:
        trial(args.discord, args.repair_origin)
    except (RuntimeError, OSError, TimeoutError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        raise SystemExit(f'Trial ended without a pass: {error}')
