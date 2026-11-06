#!/usr/bin/env python3
"""Owner-run Personal TUN smoke test. Requires a real terminal and explicit consent."""

import argparse
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
    run(['/usr/bin/curl', '--disable', '--silent', '--show-error', '--fail', '--noproxy', '*',
         '--max-time', '8', '--output', '/dev/null', URL], 10)
    print(f'{stage}: certificate-verified HTTPS passed.', flush=True)


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


def trial():
    if os.geteuid() == 0 or not os.isatty(0):
        raise RuntimeError('Run this script as your normal user in Terminal.')
    run([ROOT / 'scripts/verify-release.sh', APP], 20)
    run([SNAPSHOT], 20)
    before = fingerprint()
    probe('Before Enable')
    print('One temporary TUN interface and its public routes will be created. System DNS is selected.', flush=True)
    print('If macOS asks for a password, type it only in Terminal. Ctrl-C requests shutdown.', flush=True)
    run(['/usr/bin/sudo', '-v'], 120)

    session = str(uuid.uuid4())
    engine = subprocess.Popen([HELPERS / 'MacDPITUNEngine', session, '1', '32', '0', ''],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    status = StatusReader(engine.stdout)
    broker = None
    clean = False
    terminal = {'FAILED', 'FAILED_CLEAN', 'RECOVERY_REQUIRED', 'DISABLED', 'CANCELLED'}
    phase = None
    try:
        broker = subprocess.Popen(['/usr/bin/sudo', '-n', '--', HELPERS / 'MacDPITUNHelper', 'run', session])
        phase = status.wait(terminal | {'ACTIVE'}, 35)
        if phase != 'ACTIVE':
            raise RuntimeError('Activation was not verified.')
        probe('While Active')
    finally:
        engine.stdin.close()
        try:
            if phase not in terminal:
                phase = status.wait(terminal, 28)
            clean = phase in {'DISABLED', 'FAILED_CLEAN'}
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
            if not clean or changed:
                print('Cleanup requires review. Use the recovery procedure in docs/PERSONAL_TUN.md.', flush=True)
    if not clean or changed:
        raise RuntimeError('The full Enable/Disable trial was not verified.')
    print('PASS: real TUN activation, HTTPS and route restoration. Discord and Roblox were outside this test.', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--approved', action='store_true', help='Authorize the temporary interface and route trial.')
    args = parser.parse_args()
    if not args.approved:
        parser.error('Run with --approved only after reviewing the first trial in docs/PERSONAL_TUN.md.')
    try:
        trial()
    except (RuntimeError, OSError, TimeoutError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        raise SystemExit(f'Trial ended without a pass: {error}')
