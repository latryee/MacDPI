#!/usr/bin/env python3
"""Refresh sanitized JSON evidence from completed tests. Maintained Markdown is never overwritten."""
import argparse
import json
import pathlib
import platform
import plistlib
import re
import shutil
import subprocess
from datetime import datetime
from zoneinfo import ZoneInfo

root = pathlib.Path(__file__).resolve().parents[1]
reports = root / 'build/reports'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--reports', type=pathlib.Path, default=reports)
parser.add_argument('--unit-log', type=pathlib.Path)
parser.add_argument('--xcode-summary', type=pathlib.Path)
parser.add_argument('--app', type=pathlib.Path, default=root / 'build/release/MacDPI.app')
args = parser.parse_args()
reports = args.reports
network = json.loads((reports / 'integration.json').read_text())
xcode = json.loads((args.xcode_summary or reports / 'xcode-summary.json').read_text())
log = (args.unit_log or reports / 'core-tests.log').read_text()
counts = re.findall(r'Executed (\d+) tests, with 0 failures', log)
if "Test Suite 'All tests' passed" not in log or not counts:
    raise SystemExit('A completed passing core run is required.')
if xcode['result'] != 'Passed' or xcode['failedTests'] != 0:
    raise SystemExit('A completed passing native test run is required.')
if network['engine_final_snapshot']['state'] != 'disabled' or network['engine_final_snapshot']['activeConnections'] != 0:
    raise SystemExit('The integration run must leave the engine stopped and drained.')
verification = root / 'docs/verification'
verification.mkdir(parents=True, exist_ok=True)

def bundle_info(bundle):
    return plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())

def architectures(path):
    return subprocess.check_output(['xcrun', 'lipo', '-archs', str(path)], text=True).split()

app_info = bundle_info(args.app)
version = app_info['CFBundleShortVersionString']
if version != (root / 'VERSION').read_text().strip():
    raise SystemExit('The app version does not match VERSION.')
providers = {}
for bundle in sorted((args.app / 'Contents/Library/SystemExtensions').glob('*.systemextension')):
    info = bundle_info(bundle)
    providers[info['CFBundleIdentifier']] = architectures(bundle / 'Contents/MacOS' / info['CFBundleExecutable'])
if len(providers) != 2:
    raise SystemExit('Both bundled providers are required for the verification summary.')

summary = {
    'version': version,
    'build': app_info['CFBundleVersion'],
    'date': datetime.now(ZoneInfo('Europe/Istanbul')).date().isoformat(),
    'toolchain': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
    'runtime': f'macOS {platform.mac_ver()[0]} {platform.machine()}',
    'core_tests_passed': int(counts[-1]),
    'native_tests_passed': xcode['passedTests'],
    'integration_scenarios_passed': len(network['tests']),
    'failures': 0,
    'app_architectures': architectures(args.app / 'Contents/MacOS' / app_info['CFBundleExecutable']),
    'provider_architectures': providers,
    'deployment_target': app_info['LSMinimumSystemVersion'],
    'provider_runtime': 'unverified; never installed or activated',
    'public_signing_notarization': 'not performed',
    'github_publication': 'not performed',
    'real_network_scope': 'No current live checks. See REAL_NETWORK_VALIDATION.md for the earlier 0.1.0 scope.',
}
for name in ['integration.json', 'app-idle.json', 'soak-clean.json', 'udp-buffer-ab.json', 'native-transports.json']:
    source = reports / name
    if source.exists():
        json.loads(source.read_text())
        shutil.copyfile(source, verification / f'{version}-{name}')
(verification / f'{version}-test-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print('Refreshed sanitized JSON evidence. Review Markdown reports separately; no claims were generated.')
