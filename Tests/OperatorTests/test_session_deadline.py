import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
GUARD = ROOT / 'scripts/test-session-deadline.py'


@unittest.skipUnless(sys.platform == 'darwin', 'Uses the macOS ps executable identity contract')
class SessionDeadlineTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='macdpi-deadline-test-')
        self.directory = pathlib.Path(self.tmp.name)
        self.children = []

    def tearDown(self):
        for child in self.children:
            if child.poll() is None:
                child.terminate()
            child.wait(timeout=3)
        self.tmp.cleanup()

    def child(self):
        process = subprocess.Popen(['/bin/sleep', '20'])
        self.children.append(process)
        return process

    def run_guard(self, child, executable='/bin/sleep', marker=None):
        report = self.directory / 'report.json'
        command = [sys.executable, str(GUARD), '--pid', str(child.pid),
                   '--expected-executable', executable, '--deadline-epoch', str(time.time() + 0.8),
                   '--report', str(report)]
        if marker is not None:
            command += ['--stop-marker', str(marker)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=4)
        return result, json.loads(report.read_text())

    def test_deadline_stops_only_selected_child(self):
        target, unrelated = self.child(), self.child()
        result, report = self.run_guard(target)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(report['action'], 'deadline-stop-signal-sent')
        self.assertEqual(target.wait(timeout=2), -15)
        self.assertIsNone(unrelated.poll())

    def test_marker_disarms_without_stopping_target(self):
        target = self.child()
        marker = self.directory / 'disarm'
        marker.touch()
        result, report = self.run_guard(target, marker=marker)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(report['action'], 'disarmed')
        self.assertFalse(report['signal_sent'])
        self.assertIsNone(target.poll())

    def test_wrong_executable_is_refused_without_signal(self):
        target = self.child()
        result, report = self.run_guard(target, executable='/usr/bin/true')
        self.assertEqual(result.returncode, 2)
        self.assertEqual(report['action'], 'refused')
        self.assertFalse(report['signal_sent'])
        self.assertIsNone(target.poll())

    def test_backwards_wall_clock_does_not_extend_original_interval(self):
        spec = importlib.util.spec_from_file_location('deadline_guard_fixture', GUARD)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        clock = {'wall': 100.0, 'monotonic': 50.0, 'inspected': False}
        expected = {'uid': os.getuid(), 'start': 'fixture-start',
                    'executable': str(pathlib.Path('/bin/sleep').resolve())}

        def inspect(_):
            if not clock['inspected']:
                clock['monotonic'] += 0.75
                clock['wall'] -= 0.5
                clock['inspected'] = True
            return expected

        def sleep(seconds):
            clock['wall'] += seconds
            clock['monotonic'] += seconds

        with mock.patch.object(module, 'identity', side_effect=inspect), \
             mock.patch.object(module.time, 'time', side_effect=lambda: clock['wall']), \
             mock.patch.object(module.time, 'monotonic', side_effect=lambda: clock['monotonic']), \
             mock.patch.object(module.time, 'sleep', side_effect=sleep), \
             mock.patch.object(module.os, 'kill') as stop, mock.patch('builtins.print'):
            action, sent = module.guard(4444, '/bin/sleep', 101.0)
        self.assertEqual(action, 'deadline-stop-signal-sent')
        self.assertTrue(sent)
        self.assertLessEqual(clock['monotonic'], 51.0 + 0.000001)
        stop.assert_called_once_with(4444, module.signal.SIGTERM)
