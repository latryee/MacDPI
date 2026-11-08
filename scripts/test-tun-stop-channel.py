#!/usr/bin/env python3
"""Test the worker stop bridge as a normal user, with no app or privileged broker.

Compiles the production Swift stop channel and TUNSessionIPC.c in a temporary
directory. Only pipes, signals, poll, and absent random broker UUIDs are used.
"""
import os
import pathlib
import platform
import selectors
import signal
import subprocess
import tempfile
import time


ROOT = pathlib.Path(__file__).resolve().parents[1]


def compile_fixture(output):
    architecture = platform.machine()
    if architecture not in {"arm64", "x86_64"}:
        raise RuntimeError("The native stop fixture requires a supported Mac architecture")
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    target = architecture + "-apple-macos12.0"
    obj = output / "TUNSessionIPC.o"
    subprocess.run([
        "xcrun", "clang", "-std=gnu17", "-Wall", "-Wextra", "-Werror", "-O2",
        "-isysroot", sdk, "-target", target, "-c", "IntegrationSupport/TUNSessionIPC.c",
        "-o", str(obj),
    ], cwd=ROOT, check=True, timeout=60)
    binary = output / "stop-channel-fixture"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-warnings-as-errors", "-O",
        "-sdk", sdk, "-target", target,
        "-module-cache-path", str(output / "module-cache"),
        "-import-objc-header", "IntegrationSupport/TUNSessionIPC.h",
        "Tools/MacDPITUNEngine/StopChannel.swift", "Tools/TUNStopChannelFixture/main.swift",
        str(obj), "-framework", "Security", "-framework", "CoreFoundation", "-o", str(binary),
    ], cwd=ROOT, check=True, timeout=60)
    return binary


def run_case(binary, mode, trigger):
    process = subprocess.Popen([str(binary), mode], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True)
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            if not selector.select(timeout=5):
                raise AssertionError("fixture did not become ready")
            ready = process.stdout.readline().strip()
        if not ready.startswith("READY "):
            raise AssertionError("fixture failed before readiness: " + ready)
        # Keep stdin open for idle/signal cases so EOF cannot cause a false pass.
        started = time.monotonic()
        if trigger in {"SIGTERM", "SIGINT"}:
            process.send_signal(getattr(signal, trigger))
        elif trigger == "signal-burst":
            for number in [signal.SIGTERM, signal.SIGINT] * 16:
                process.send_signal(number)
        elif trigger == "parent-eof":
            process.stdin.close()
        elif trigger == "parent-input":
            process.stdin.write("S")
            process.stdin.flush()
        elif trigger != "none":
            raise AssertionError("unknown trigger")
        process.wait(timeout=6)
        elapsed = time.monotonic() - started
        output = process.stdout.read().strip()
        error = process.stderr.read().strip()
        if process.returncode != 0 or not output.startswith("PASS " + mode + " "):
            raise AssertionError(f"{mode}/{trigger}: exit={process.returncode}, {output}, {error}")
        if trigger != "none" and elapsed >= 2:
            raise AssertionError(f"{mode}/{trigger}: stop took {elapsed:.3f}s")
        print(f"PASS {mode}/{trigger} ({elapsed:.3f}s)", flush=True)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=3)
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream is not None and not stream.closed:
                stream.close()


def main():
    if platform.system() != "Darwin" or os.getuid() == 0 or os.geteuid() != os.getuid():
        raise SystemExit("Run this native fixture on macOS as a normal user")
    with tempfile.TemporaryDirectory(prefix="macdpi-stop-channel-") as temporary:
        binary = compile_fixture(pathlib.Path(temporary))
        subprocess.run([str(binary), "lifetime"], check=True, timeout=5)
        for mode in ("poll-stop", "broker-cancel"):
            for trigger in ("SIGTERM", "SIGINT", "parent-eof", "parent-input", "signal-burst"):
                run_case(binary, mode, trigger)
        run_case(binary, "poll-idle", "none")
        run_case(binary, "broker-timeout", "none")
    print("13 normal-user native stop-channel cases passed", flush=True)


if __name__ == "__main__":
    main()
