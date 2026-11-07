#!/usr/bin/env python3
"""Validate an embedded-provider release bundle without installing or activating it."""
import argparse
import hashlib
import importlib.util
import pathlib
import plistlib
import re
import stat
import subprocess
import tempfile
import unicodedata
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('release_metadata', ROOT / 'scripts/release-metadata.py')
METADATA = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(METADATA)


def command(args):
    return subprocess.run(args, capture_output=True, text=True, check=True)


def read_entitlements(bundle, architecture='arm64'):
    result = subprocess.run(['codesign', '-d', '--architecture', architecture, '--entitlements', '-', '--xml', str(bundle)], capture_output=True)
    if result.returncode:
        result = subprocess.run(['codesign', '-d', '--architecture', architecture, '--entitlements', ':-', str(bundle)], capture_output=True, check=True)
    return plistlib.loads(result.stdout) if result.stdout else {}


def slices(binary):
    architectures = set(command(['xcrun', 'lipo', '-archs', str(binary)]).stdout.split())
    require(architectures == {'arm64', 'x86_64'}, 'Both Universal 2 architecture slices are required.')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify(app, require_production=False):
    app = pathlib.Path(app)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    version, build = METADATA.versions()
    require(info['CFBundleIdentifier'] == METADATA.HOST_ID, 'Incorrect host bundle identifier.')
    require(info['CFBundleShortVersionString'] == version and info['CFBundleVersion'] == build, 'Incorrect host version or build number.')
    require(info['LSMinimumSystemVersion'] == '12.0', 'Incorrect minimum macOS version.')
    require(info.get('NSSystemExtensionUsageDescription'), 'Host purpose string is missing.')
    mode = info.get('MacDPIIntegrationBuild')
    require(mode in {'local-review', 'local-personal', 'developer-id'}, 'Build capability marker is missing or unresolved.')
    if require_production:
        require(mode == 'developer-id', 'Production distribution requires a Developer ID build.')
    extension_root = app / 'Contents/Library/SystemExtensions'
    if mode == 'local-personal':
        require(info.get('MacDPIPersonalTUN') is True, 'Personal TUN marker is missing.')
        require(not extension_root.exists(), 'Personal builds cannot contain Network Extension providers.')
        require(not (app / 'Contents/embedded.provisionprofile').exists(), 'Personal builds cannot contain provisioning profiles.')
        helper_root = app / 'Contents/Helpers'
        require({p.name for p in helper_root.iterdir()} == METADATA.TUN_BINARIES, 'Incorrect personal TUN components.')
        pins = info.get('MacDPITUNExecutableSHA256')
        require(pins == {name: hashlib.sha256((helper_root / name).read_bytes()).hexdigest()
                         for name in METADATA.TUN_BINARIES}, 'Personal TUN executable digests do not match the signed manifest.')
        for binary in [app / 'Contents/MacOS/MacDPI', *(helper_root / name for name in sorted(METADATA.TUN_BINARIES))]:
            require(binary.is_file() and not binary.is_symlink(), 'Invalid personal TUN executable.')
            require(not binary.stat().st_mode & (stat.S_ISUID | stat.S_ISGID), 'Unexpected elevated executable mode.')
            slices(binary)
            command(['codesign', '--verify', '--strict', '--all-architectures', str(binary if binary.parent == helper_root else app)])
            for architecture in ('arm64', 'x86_64'):
                target = binary if binary.parent == helper_root else app
                require(not read_entitlements(target, architecture), 'Personal builds cannot claim special entitlements.')
                require('Signature=adhoc' in command(['codesign', '-dvv', '--architecture', architecture, str(target)]).stderr,
                        'Personal builds must be explicitly ad hoc signed.')
        command(['codesign', '--verify', '--deep', '--strict', str(app)])
        print('Verified Universal 2 personal TUN bundle and ad hoc signatures. Activation requires separate authorization.')
        return
    require(info.get('MacDPIPersonalTUN') is not True and not (app / 'Contents/Helpers').exists(),
            'Personal TUN components must stay in their own build.')
    names = {component['identifier'] + '.systemextension' for kind, component in METADATA.COMPONENTS.items() if kind != 'host'}
    require({p.name for p in extension_root.iterdir()} == names, 'Unexpected/missing embedded extensions.')
    host_ent = read_entitlements(app)
    team = host_ent.get('com.apple.developer.team-identifier', '') if mode == 'developer-id' else None
    if mode == 'developer-id':
        require(re.fullmatch(r'[A-Z0-9]{10}', team), 'Developer ID team is missing or malformed.')
    context = {'mode': mode, 'team': team, 'prefix': team + '.' if team else 'UNPROVISIONED.'}
    bundles = {'host': app}
    for kind, component in METADATA.COMPONENTS.items():
        if kind == 'host':
            continue
        bundle = extension_root / (component['identifier'] + '.systemextension')
        bundles[kind] = bundle
        provider = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
        require(provider['CFBundlePackageType'] == 'SYSX', 'Incorrect extension package type.')
        require(provider['CFBundleIdentifier'] == component['identifier'], 'Incorrect extension bundle identifier.')
        require(provider['CFBundleExecutable'] == component['executable'], 'Incorrect extension executable.')
        require(provider['CFBundleShortVersionString'] == version and provider['CFBundleVersion'] == build, 'Incorrect extension version or build number.')
        require(provider['LSMinimumSystemVersion'] == '12.0', 'Incorrect extension minimum macOS version.')
        require(provider['CFBundleSupportedPlatforms'] == ['MacOSX'], 'Incorrect extension platform.')
        require(provider.get('MacDPIIntegrationBuild') == mode, 'Mixed build capability modes.')
        require(provider['NetworkExtension']['NEProviderClasses'] == component['provider'], 'Provider classes must match this single provider bundle.')
        service = context['prefix'] + METADATA.GROUP_SUFFIX + '.' + component['service']
        require(provider['NetworkExtension']['NEMachServiceName'] == service, 'Incorrect or unresolved app-group Mach service.')
        for architecture in ['arm64', 'x86_64']:
            # Internal Swift subclasses have local symbols, so nm -g would incorrectly
            # reject a valid provider. Inspect the actual Objective-C runtime class table.
            objc = command(['xcrun', 'dyld_info', '-objc', '-arch', architecture,
                            str(bundle / 'Contents/MacOS' / component['executable'])]).stdout
            interfaces = [line for line in objc.splitlines() if line.strip().startswith('@interface ')]
            for name in component['provider'].values():
                module, class_name = name.rsplit('.', 1)
                require(any(module in line and class_name in line for line in interfaces),
                        'The declared provider class is not compiled into the extension: ' + architecture)
    for kind, bundle in bundles.items():
        expected_entitlements = METADATA.entitlements(kind, context)
        for architecture in ['arm64', 'x86_64']:
            require(read_entitlements(bundle, architecture) == expected_entitlements, 'Signed entitlements are incorrectly scoped for ' + kind + '/' + architecture + '.')
        if mode == 'local-review':
            require(not (bundle / 'Contents/embedded.provisionprofile').exists(), 'Review builds must not embed production profiles.')
            for architecture in ['arm64', 'x86_64']:
                detail = command(['codesign', '-dvv', '--architecture', architecture, str(bundle)]).stderr
                require('Signature=adhoc' in detail, 'Review builds must use explicit ad hoc signatures.')
        else:
            require((bundle / 'Contents/embedded.provisionprofile').is_file(), 'Signed deployment requires all three embedded profiles.')
            METADATA.verify_developer_signature(kind, bundle, team)
        executable = METADATA.COMPONENTS[kind]['executable']
        binary = bundle / 'Contents/MacOS' / executable
        slices(binary)
        command(['codesign', '--verify', '--strict', '--all-architectures', str(bundle)])
    command(['codesign', '--verify', '--deep', '--strict', str(app)])
    print('Verified Universal 2 host and two separately scoped SYSX bundles, provider classes, app-group/Mach service metadata, signatures and build capability mode: ' + mode + '.')
    if mode == 'local-review':
        print('Local review only: no installation, activation, provisioning or notarization success is asserted.')


def manifest(app):
    result = {}
    require(app.is_dir() and not app.is_symlink(), 'An app directory is required.')
    for path in app.rglob('*'):
        if path.is_dir() and not path.is_symlink():
            continue
        require(path.is_file() and not path.is_symlink(), 'Unexpected file type in app bundle.')
        digest = hashlib.sha256()
        with path.open('rb') as stream:
            for chunk in iter(lambda: stream.read(65536), b''):
                digest.update(chunk)
        result[path.relative_to(app)] = digest.hexdigest()
    return result


def verify_zip(archive, expected, require_production):
    archive = METADATA.output_root(archive)
    require(archive.stat().st_size <= 128 * 1024 * 1024, 'Release ZIP exceeds the archive size limit.')
    with zipfile.ZipFile(archive) as zipped:
        entries = zipped.infolist()
        require(0 < len(entries) <= 256 and sum(entry.file_size for entry in entries) <= 128 * 1024 * 1024,
                'Release ZIP exceeds the app bundle verification limits.')
        seen = set()
        for entry in entries:
            require(entry.filename == entry.orig_filename, 'Invalid ZIP entry name.')
            name = entry.filename.rstrip('/')
            parts = name.split('/')
            kind = stat.S_IFMT(entry.external_attr >> 16)
            require(kind in {0, stat.S_IFDIR, stat.S_IFREG}, 'Unexpected ZIP entry type.')
            require(all(part not in {'', '.', '..'} and '\\' not in part and ':' not in part for part in parts),
                    'Unsafe ZIP entry path.')
            require(parts[0] == 'MacDPI.app' or parts[:2] == ['__MACOSX', 'MacDPI.app'] or parts == ['__MACOSX'],
                    'Unexpected content outside the MacDPI app.')
            canonical = unicodedata.normalize('NFD', name).casefold()
            require(canonical not in seen, 'Duplicate ZIP entry.')
            seen.add(canonical)
    with tempfile.TemporaryDirectory(prefix='verify-zip-', dir=archive.parent) as directory:
        command(['ditto', '-x', '-k', str(archive), directory])
        app = pathlib.Path(directory) / 'MacDPI.app'
        require(manifest(app) == expected, 'ZIP contains a different MacDPI build.')
        verify(app, require_production)
    print('Verified extracted ZIP against the exact source app files and signatures.')


def verify_dmg(image, expected, require_production):
    image = METADATA.output_root(image)
    command(['hdiutil', 'verify', str(image)])
    with tempfile.TemporaryDirectory(prefix='verify-dmg-', dir=image.parent) as directory:
        command(['hdiutil', 'attach', str(image), '-readonly', '-nobrowse', '-noautoopen', '-mountpoint', directory])
        try:
            app = pathlib.Path(directory) / 'MacDPI.app'
            require(manifest(app) == expected, 'DMG contains a different MacDPI build.')
            verify(app, require_production)
        finally:
            command(['hdiutil', 'detach', directory])
    print('Verified and detached the read-only DMG with the exact source app files and signatures.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', nargs='?', default=ROOT / 'build/release/MacDPI.app')
    parser.add_argument('--require-production', action='store_true')
    parser.add_argument('--zip', type=pathlib.Path)
    parser.add_argument('--dmg', type=pathlib.Path)
    args = parser.parse_args()
    verify(args.app, args.require_production)
    if args.zip or args.dmg:
        expected = manifest(pathlib.Path(args.app))
        if args.zip:
            verify_zip(args.zip, expected, args.require_production)
        if args.dmg:
            verify_dmg(args.dmg, expected, args.require_production)


if __name__ == '__main__':
    main()
