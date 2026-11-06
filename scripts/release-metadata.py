#!/usr/bin/env python3
"""Prepare scoped bundle metadata and validate explicitly supplied Developer ID profiles.

This tool never installs a profile, registers an extension, changes networking, or uploads.
Local review hosts retain their original network-only sandbox permissions.
"""
import argparse
import datetime
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile
from versioning import versions

ROOT = pathlib.Path(__file__).resolve().parents[1]
HOST_ID = 'io.github.latryee.MacDPI'
EXTENSION_ID = HOST_ID + '.TransparentProxy'
DNS_ID = HOST_ID + '.DNSProxy'
GROUP_SUFFIX = HOST_ID + '.shared'
CAPABILITIES = {'app-proxy-provider-systemextension', 'dns-proxy-systemextension'}
TUN_BINARIES = {'MacDPITUNHelper', 'MacDPITUNEngine'}
COMPONENTS = {
    'host': {'identifier': HOST_ID, 'executable': 'MacDPI', 'capabilities': CAPABILITIES},
    'extension': {'identifier': EXTENSION_ID, 'executable': 'MacDPITransparentProxy',
                  'capabilities': {'app-proxy-provider-systemextension'}, 'template': 'Info.plist',
                  'service': 'TransparentProxy', 'provider': {'com.apple.networkextension.app-proxy': 'MacDPITransparentProxy.TransparentProxyProvider'}},
    'dns': {'identifier': DNS_ID, 'executable': 'MacDPIDNSProxy',
            'capabilities': {'dns-proxy-systemextension'}, 'template': 'DNSInfo.plist',
            'service': 'DNSProxy', 'provider': {'com.apple.networkextension.dns-proxy': 'MacDPITransparentProxy.SecureDNSProxyProvider'}},
}
BASE = {'com.apple.security.app-sandbox': True,
        'com.apple.security.network.client': True,
        'com.apple.security.network.server': True}


def build_context(environment=None):
    env = os.environ if environment is None else environment
    identity = env.get('SIGN_IDENTITY', '').strip()
    if env.get('MACDPI_PERSONAL_TUN') == '1':
        if identity and identity != '-':
            raise ValueError('The personal build is a separate ad hoc configuration.')
        return {'mode': 'local-personal', 'identity': '-', 'team': None, 'prefix': 'UNPROVISIONED.'}
    if not identity or identity == '-':
        return {'mode': 'local-review', 'identity': '-', 'team': None, 'prefix': 'UNPROVISIONED.'}
    team = env.get('MACDPI_TEAM_ID', '')
    if not re.fullmatch(r'[A-Z0-9]{10}', team):
        raise ValueError('Developer ID signing requires explicit MACDPI_TEAM_ID (ten uppercase letters/digits).')
    context = {'mode': 'developer-id', 'identity': identity, 'team': team, 'prefix': team + '.'}
    for kind, component in COMPONENTS.items():
        identifier = component['identifier']
        key = 'MACDPI_' + kind.upper() + '_PROFILE'
        path = pathlib.Path(env.get(key, ''))
        if not env.get(key) or not path.is_file() or path.stat().st_size > 1_048_576:
            raise ValueError('Developer ID signing requires an explicit valid ' + key + ' file.')
        # Decode only. No trust/keychain import, installation, or credentials printed.
        result = subprocess.run(['security', 'cms', '-D', '-i', str(path)], capture_output=True, check=True)
        validate_profile(plistlib.loads(result.stdout), team, identifier, kind)
        context[kind + '_profile'] = path
    return context


def validate_profile(profile, team, identifier, kind):
    if kind not in COMPONENTS or identifier != COMPONENTS[kind]['identifier']:
        raise ValueError('Unknown or mismatched release component.')
    entitlement = profile.get('Entitlements', {})
    if profile.get('TeamIdentifier') != [team] or entitlement.get('com.apple.developer.team-identifier') != team:
        raise ValueError('Provisioning profile TeamIdentifier does not match the supplied team.')
    if entitlement.get('com.apple.application-identifier') != team + '.' + identifier:
        raise ValueError('Provisioning profile requires the exact component application identifier.')
    capabilities = entitlement.get('com.apple.developer.networking.networkextension', [])
    if set(capabilities) != COMPONENTS[kind]['capabilities'] or len(capabilities) != len(set(capabilities)):
        raise ValueError('Provisioning profile must grant exactly this component\'s provider capabilities.')
    # Our macOS-style TEAMID.* app group is unrestricted on macOS (TN3125), so its
    # absence from a profile is valid. Verify the actual signed app-group claim instead.
    if kind == 'host' and entitlement.get('com.apple.developer.system-extension.install') is not True:
        raise ValueError('Host profile does not grant system-extension installation.')
    if kind != 'host' and entitlement.get('com.apple.developer.system-extension.install') is True:
        raise ValueError('Provider profiles must not claim host installation capability.')
    if entitlement.get('get-task-allow') is True or entitlement.get('com.apple.security.get-task-allow') is True:
        raise ValueError('Distribution profiles must not allow debugger attachment.')
    if profile.get('ProvisionsAllDevices') is not True or 'ProvisionedDevices' in profile:
        raise ValueError('A Developer ID distribution profile for all devices is required.')
    certificates = profile.get('DeveloperCertificates', [])
    if not certificates or not all(isinstance(value, bytes) and value for value in certificates):
        raise ValueError('Provisioning profile has no signing certificates.')
    expires = profile.get('ExpirationDate')
    if not isinstance(expires, datetime.datetime):
        raise ValueError('Provisioning profile expiration is missing.')
    if expires.replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
        raise ValueError('Provisioning profile has expired.')


def output_root(value):
    path = pathlib.Path(value).resolve()
    build = (ROOT / 'build').resolve()
    if path == build or not path.is_relative_to(build):
        raise ValueError('Generated release files must remain below this repository\'s build directory.')
    return path


def validate_build_root(value):
    path = pathlib.Path(value).resolve()
    if not path.is_relative_to((ROOT / 'build').resolve()):
        raise ValueError('MACDPI_BUILD_ROOT must remain inside this repository\'s build directory.')
    return path


def entitlements(kind, context):
    if context['mode'] == 'local-personal':
        if kind != 'host':
            raise ValueError('Personal builds do not contain Network Extension providers.')
        # Personal apps require an unprivileged Unix socket and child process outside
        # App Sandbox. This grants no special system or networking entitlement.
        return {}
    result = dict(BASE)
    if kind != 'host' or context['mode'] == 'developer-id':
        result['com.apple.developer.networking.networkextension'] = sorted(COMPONENTS[kind]['capabilities'])
        result['com.apple.security.application-groups'] = [context['prefix'] + GROUP_SUFFIX]
    if kind == 'host' and context['mode'] == 'developer-id':
        result['com.apple.developer.system-extension.install'] = True
    if context['team']:
        identifier = COMPONENTS[kind]['identifier']
        result['com.apple.developer.team-identifier'] = context['team']
        result['com.apple.application-identifier'] = context['team'] + '.' + identifier
    return result


def prepare(kind, bundle, entitlement_path, context):
    bundle = output_root(bundle)
    entitlement_path = output_root(entitlement_path)
    version, build = versions()
    if kind != 'host':
        component = COMPONENTS[kind]
        info = plistlib.loads((ROOT / 'Extension' / component['template']).read_bytes())
        info.update(CFBundleIdentifier=component['identifier'], CFBundleExecutable=component['executable'],
                    CFBundleShortVersionString=version, CFBundleVersion=build, CFBundleSupportedPlatforms=['MacOSX'])
        info['NetworkExtension']['NEMachServiceName'] = context['prefix'] + GROUP_SUFFIX + '.' + component['service']
        info['NetworkExtension']['NEProviderClasses'] = component['provider']
    else:
        info = {
            'CFBundleIdentifier': HOST_ID, 'CFBundleName': 'MacDPI', 'CFBundleDisplayName': 'MacDPI',
            'CFBundleExecutable': 'MacDPI', 'CFBundleIconFile': 'AppIcon', 'CFBundlePackageType': 'APPL',
            'CFBundleShortVersionString': version, 'CFBundleVersion': build, 'CFBundleSupportedPlatforms': ['MacOSX'],
            'LSMinimumSystemVersion': '12.0', 'LSApplicationCategoryType': 'public.app-category.utilities',
            'NSPrincipalClass': 'NSApplication', 'NSHighResolutionCapable': True,
            'NSSupportsAutomaticGraphicsSwitching': True,
            'NSHumanReadableCopyright': 'Copyright 2026 MacDPI contributors. MIT License.',
            'NSSystemExtensionUsageDescription': 'MacDPI uses an approved local networking extension to handle supported outbound traffic. No remote VPN or TLS certificate installation is used.',
        }
    info['MacDPIIntegrationBuild'] = context['mode']
    if kind == 'host' and context['mode'] == 'local-personal':
        info['MacDPIPersonalTUN'] = True
    (bundle / 'Contents').mkdir(parents=True, exist_ok=True)
    (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info, sort_keys=False))
    entitlement_path.parent.mkdir(parents=True, exist_ok=True)
    entitlement_path.write_bytes(plistlib.dumps(entitlements(kind, context), sort_keys=False))
    embedded = bundle / 'Contents/embedded.provisionprofile'
    if context['mode'] == 'developer-id':
        shutil.copyfile(context[kind + '_profile'], embedded)
    elif embedded.exists():
        # Remove only an obsolete generated profile in this exact owned output bundle.
        embedded.unlink()


def verify_developer_signature(kind, bundle, team):
    requirement = 'anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "' + team + '"'
    subprocess.run(['codesign', '--verify', '--strict', '--all-architectures', '-R', requirement, str(bundle)], check=True)
    embedded = bundle / 'Contents/embedded.provisionprofile'
    result = subprocess.run(['security', 'cms', '-D', '-i', str(embedded)], capture_output=True, check=True)
    profile = plistlib.loads(result.stdout)
    validate_profile(profile, team, COMPONENTS[kind]['identifier'], kind)
    # codesign is the supported signature-inspection API. Keep its temporary public certificate
    # output local and compare the actual leaf against the explicit profile's allowed signers.
    with tempfile.TemporaryDirectory(prefix='certificate-check-', dir=ROOT / 'build') as directory:
        for architecture in ['arm64', 'x86_64']:
            detail = subprocess.run(['codesign', '-dvv', '--architecture', architecture, str(bundle)], capture_output=True, text=True, check=True).stderr
            if 'Authority=Developer ID Application:' not in detail or 'TeamIdentifier=' + team not in detail:
                raise ValueError('The signed component is not the supplied team\'s Developer ID Application build.')
            prefix = pathlib.Path(directory) / (architecture + '-certificate')
            subprocess.run(['codesign', '-d', '--architecture', architecture, '--extract-certificates', str(prefix), str(bundle)], capture_output=True, check=True)
            if pathlib.Path(str(prefix) + '0').read_bytes() not in profile['DeveloperCertificates']:
                raise ValueError('The actual signing certificate is not permitted by this component\'s profile.')


def sign(kind, bundle, entitlement_path, context):
    args = ['codesign', '--force', '--sign', context['identity'], '--options', 'runtime',
            '--entitlements', str(entitlement_path)]
    if context['mode'] == 'developer-id':
        args.append('--timestamp')
    subprocess.run(args + [str(bundle)], check=True)
    if context['mode'] == 'developer-id':
        verify_developer_signature(kind, bundle, context['team'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['check', 'prepare', 'sign'])
    parser.add_argument('--kind', choices=list(COMPONENTS))
    parser.add_argument('--bundle')
    parser.add_argument('--entitlements')
    parser.add_argument('--build-root', default=os.environ.get('MACDPI_BUILD_ROOT', ROOT / 'build'))
    args = parser.parse_args()
    context = build_context()
    validate_build_root(args.build_root)
    if args.operation == 'check':
        versions()
        print('Release mode: ' + context['mode'] + '. No installation or activation is performed.')
        return
    if not args.kind or not args.bundle or not args.entitlements:
        parser.error('--kind, --bundle and --entitlements are required')
    bundle = output_root(args.bundle)
    entitlement_path = output_root(args.entitlements)
    if args.operation == 'prepare':
        prepare(args.kind, bundle, entitlement_path, context)
    else:
        sign(args.kind, bundle, entitlement_path, context)


if __name__ == '__main__':
    main()
