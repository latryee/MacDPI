#!/usr/bin/env python3
"""Non-root fallback stop for an explicitly approved manual test session.

This operator tool never creates an interface, changes routes/settings, starts a
helper, or runs a shell. It pins one same-user process and sends SIGTERM only if
that exact process is still present at the deadline. Normal GUI Disable should
finish first. This is not an application session timer or cleanup verification.
"""
import argparse
import datetime
import json
import math
import os
import pathlib
import signal
import subprocess
import time


def identity(pid):
    result = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'uid=', '-o', 'lstart=', '-o', 'comm='],
                            capture_output=True, text=True, timeout=3,
                            env={**os.environ, 'LC_ALL': 'C'})
    if result.returncode == 1 and not result.stdout.strip():
        return None
    fields = result.stdout.strip().split(maxsplit=6)
    if result.returncode or len(fields) != 7:
        raise RuntimeError('Process identity could not be inspected')
    return {'uid': int(fields[0]), 'start': ' '.join(fields[1:6]),
            'executable': str(pathlib.Path(fields[6]).resolve())}


def guard(pid, executable, deadline, marker=None):
    if os.geteuid() == 0 or pid <= 1 or pid == os.getpid():
        raise ValueError('The guard requires a distinct normal-user test process')
    remaining = deadline - time.time()
    if not math.isfinite(remaining) or not 0 < remaining <= 1800:
        raise ValueError('Deadline must be within the next thirty minutes')
    monotonic_deadline = time.monotonic() + remaining
    expected = str(pathlib.Path(executable).resolve(strict=True))
    original = identity(pid)
    if not original or original['uid'] != os.getuid() or original['executable'] != expected:
        raise ValueError('The target does not match the expected same-user executable')
    print(json.dumps({'event': 'armed', 'deadline_epoch': deadline,
                      'recorded_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat()}), flush=True)
    while True:
        if marker is not None and marker.exists():
            return 'disarmed', False
        current = identity(pid)
        if current is None:
            return 'target-exited', False
        if current != original:
            return 'identity-changed-no-signal', False
        if time.time() >= deadline or time.monotonic() >= monotonic_deadline:
            # Recheck immediately before signalling; never acquire a replacement
            # process after an exit or identity change.
            if identity(pid) != original:
                return 'identity-changed-no-signal', False
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                return 'target-exited', False
            return 'deadline-stop-signal-sent', True
        time.sleep(min(0.25, max(0, deadline - time.time()),
                       max(0, monotonic_deadline - time.monotonic())))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', required=True, type=int)
    parser.add_argument('--expected-executable', required=True, type=pathlib.Path)
    parser.add_argument('--deadline-epoch', required=True, type=float)
    parser.add_argument('--stop-marker', type=pathlib.Path)
    parser.add_argument('--report', required=True, type=pathlib.Path)
    args = parser.parse_args()
    try:
        action, sent = guard(args.pid, args.expected_executable, args.deadline_epoch, args.stop_marker)
        result = {'action': action, 'signal_sent': sent,
                  'recorded_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  'scope': 'One pinned same-user test process only; independent network cleanup verification is still required'}
        status = 0
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
        result = {'action': 'refused', 'signal_sent': False,
                  'reason_category': type(error).__name__}
        status = 2
    args.report.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result), flush=True)
    return status


if __name__ == '__main__':
    raise SystemExit(main())
