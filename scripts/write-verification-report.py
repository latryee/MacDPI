#!/usr/bin/env python3
"""Refresh sanitized JSON evidence from completed tests. Maintained Markdown is never overwritten."""
import argparse
import json
import pathlib
import platform
import re
import shutil
import subprocess
from datetime import datetime
from zoneinfo import ZoneInfo

root = pathlib.Path(__file__).resolve().parents[1]
reports = root / 'build/reports'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--unit-log', type=pathlib.Path, default=reports / 'core-tests.log')
parser.add_argument('--xcode-summary', type=pathlib.Path, default=reports / 'xcode-summary.json')
args = parser.parse_args()
network = json.loads((reports / 'integration.json').read_text())
xcode = json.loads(args.xcode_summary.read_text())
log = args.unit_log.read_text()
assert "Test Suite 'All tests' passed" in log, 'A completed passing core run is required'
counts = re.findall(r'Executed (\d+) tests, with 0 failures', log)
assert counts, 'No completed core test count'
assert xcode['result'] == 'Passed' and xcode['failedTests'] == 0, 'Native tests must pass'
assert network['engine_final_snapshot']['state'] == 'disabled'
assert network['engine_final_snapshot']['activeConnections'] == 0
verification = root / 'docs/verification'
verification.mkdir(parents=True, exist_ok=True)
for name in ['integration.json', 'app-idle.json', 'real-network.json']:
    source = reports / name
    if source.exists():
        json.loads(source.read_text())
        shutil.copyfile(source, verification / name)

def architectures(path):
    return subprocess.check_output(['xcrun', 'lipo', '-archs', str(path)], text=True).split()

summary = {
    'date': datetime.now(ZoneInfo('Europe/Istanbul')).date().isoformat(),
    'toolchain': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
    'runtime': f'macOS {platform.mac_ver()[0]} {platform.machine()}',
    'core_tests_passed': int(counts[-1]),
    'native_tests_passed': xcode['passedTests'],
    'integration_scenarios_passed': len(network['tests']),
    'failures': 0,
    'app_architectures': architectures(root / 'build/release/MacDPI.app/Contents/MacOS/MacDPI'),
    'provider_architectures': architectures(root / 'build/extension/io.github.latryee.MacDPI.TransparentProxy.systemextension/Contents/MacOS/MacDPITransparentProxy'),
    'deployment_target': '12.0',
    'provider_runtime': 'unverified; never installed or activated',
    'public_signing_notarization': 'not performed',
    'github_publication': 'not performed',
    'real_network_scope': 'See REAL_NETWORK_VALIDATION.md and real-network.json; no universal, native game or voice claim',
}
(verification / 'test-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print('Refreshed sanitized JSON evidence. Review Markdown reports separately; no claims were generated.')
