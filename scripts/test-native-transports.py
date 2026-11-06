#!/usr/bin/env python3
"""Compile the real provider transport paths and test only explicit loopback fixtures.

No system extension is registered, NE flow is constructed, system setting is changed,
or external network endpoint is contacted. All servers and subprocesses have deadlines.
"""
import importlib.util
import json
import os
import pathlib
import platform
import socket
import subprocess
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('release_metadata', ROOT / 'scripts/release-metadata.py')
METADATA = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(METADATA)
TCP_TRAILER = bytes([0, 255, 17, 42, 0, 98, 121, 101])
UDP_LENGTHS = [0, 5, 0, 4096, 65_507, 0, 2]


def compile_fixture(output):
    output.mkdir(parents=True, exist_ok=True)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    architecture = platform.machine()
    if architecture not in {'arm64', 'x86_64'}:
        raise ValueError('The native fixture requires a supported Mac architecture.')
    objects = []
    for source in ['IntegrationSupport/ControlChannel.m', 'Extension/NetworkTransportBridge.m']:
        obj = output / (pathlib.Path(source).stem + '.o')
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-O2', '-isysroot', sdk,
                        '-target', architecture + '-apple-macos12.0', '-c', source, '-o', str(obj)], cwd=ROOT, check=True, timeout=60)
        objects.append(str(obj))
    binary = output / 'native-transport-fixture'
    command = ['xcrun', 'swiftc', '-swift-version', '5', '-O', '-sdk', sdk,
               '-target', architecture + '-apple-macos12.0', '-module-name', 'MacDPINativeTransportFixture',
               '-import-objc-header', 'Extension/NetworkTransportBridge.h']
    command += [str(path.relative_to(ROOT)) for path in sorted((ROOT / 'MacDPI/Core').glob('*.swift'))]
    command += ['Extension/NativeFlowAdapters.swift', 'Tools/NativeTransportFixture/main.swift', *objects,
                '-framework', 'Security', '-o', str(binary)]
    subprocess.run(command, cwd=ROOT, check=True, timeout=120)
    return binary


def round_trip(binary, transport, ipv6):
    host = '::1' if ipv6 else '127.0.0.1'
    listener = socket.socket(socket.AF_INET6 if ipv6 else socket.AF_INET,
                             socket.SOCK_STREAM if transport == 'tcp' else socket.SOCK_DGRAM)
    listener.settimeout(15)
    # Deliberately constrain the TCP receiver and delay reading to exercise send backpressure.
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16_384 if transport == 'tcp' else 262_144)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 262_144)
    listener.bind((host, 0))
    if transport == 'tcp':
        listener.listen(1)
    errors, lengths = [], []

    def serve():
        try:
            if transport == 'udp':
                for expected in UDP_LENGTHS:
                    payload, sender = listener.recvfrom(65_536)
                    lengths.append(len(payload))
                    if len(payload) != expected:
                        raise AssertionError('Unexpected datagram boundary: ' + str(lengths))
                    if listener.sendto(payload, sender) != len(payload):
                        raise AssertionError('Incomplete UDP echo')
            else:
                connection, _ = listener.accept()
                with connection:
                    connection.settimeout(15)
                    time.sleep(0.25)
                    total = 0
                    while True:
                        payload = connection.recv(4096)
                        if not payload:
                            break
                        total += len(payload)
                        if total > 8 * 1024 * 1024:
                            raise AssertionError('TCP fixture byte bound exceeded')
                        connection.sendall(payload)
                    if total != 8 * 1024 * 1024:
                        raise AssertionError('TCP write half-close arrived before all payload bytes')
                    connection.sendall(TCP_TRAILER)
                    connection.shutdown(socket.SHUT_WR)
        except Exception as error:
            errors.append(str(error))

    worker = threading.Thread(target=serve, name='macdpi-' + transport + '-loopback', daemon=True)
    worker.start()
    try:
        result = subprocess.run([str(binary), transport, host, str(listener.getsockname()[1])],
                                capture_output=True, text=True, timeout=18)
        if result.stdout.strip():
            print(result.stdout.strip(), flush=True)
        if result.stderr.strip():
            print(result.stderr.strip(), flush=True)
        if result.returncode:
            raise AssertionError('Native ' + transport + ' fixture failed for ' + host)
        report = json.loads(result.stdout)
        if report.get('passed') is not True:
            raise AssertionError('Native bridge did not report success')
        worker.join(timeout=2)
        if worker.is_alive() or errors:
            raise AssertionError('Loopback server failed: ' + str(errors))
        if transport == 'udp' and lengths != UDP_LENGTHS:
            raise AssertionError('UDP server did not receive the expected complete datagrams')
    finally:
        listener.close()
        worker.join(timeout=1)


def main():
    build = METADATA.validate_build_root(os.environ.get('MACDPI_BUILD_ROOT', ROOT / 'build/packaging-scratch'))
    binary = compile_fixture(build / 'native-transport-fixture')
    for transport in ['tcp', 'udp']:
        for ipv6 in [False, True]:
            round_trip(binary, transport, ipv6)
    print('PASS: provider C-Network TCP and interface-bound BSD UDP on IPv4/IPv6 loopback; no provider activation or system settings changed.')


if __name__ == '__main__':
    main()
