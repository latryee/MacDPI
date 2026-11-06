"""Isolated release security-gate tests. No signing identity, keychain import or networking."""
import copy
import contextlib
import datetime
import importlib.util
import json
import io
import pathlib
import plistlib
import re
import stat
import sys
import tempfile
import unittest
import zipfile
from unittest import mock
from types import SimpleNamespace

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from versioning import PROJECT, advance, versions

SPEC = importlib.util.spec_from_file_location('release_metadata', ROOT / 'scripts/release-metadata.py')
METADATA = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(METADATA)


class ReleaseMetadataTests(unittest.TestCase):
    def test_release_bump_updates_shared_versions_and_rejects_downgrade(self):
        with tempfile.TemporaryDirectory(prefix='version-fixture-') as directory:
            root = pathlib.Path(directory)
            (root / PROJECT).parent.mkdir()
            (root / PROJECT).write_text((ROOT / PROJECT).read_text())
            (root / 'VERSION').write_text((ROOT / 'VERSION').read_text())
            old_version, old_build = versions(root)
            major, minor, patch = map(int, old_version.split('.'))
            new_version = f'{major}.{minor}.{patch + 1}'
            self.assertEqual(advance(new_version, root), str(int(old_build) + 1))
            self.assertEqual(versions(root), (new_version, str(int(old_build) + 1)))
            with self.assertRaisesRegex(ValueError, 'cannot decrease'):
                advance(old_version, root)

    def test_review_host_cannot_claim_unavailable_privileged_capabilities(self):
        context = METADATA.build_context({})
        self.assertEqual(context['mode'], 'local-review')
        self.assertEqual(METADATA.entitlements('host', context), METADATA.BASE)
        for kind in ['extension', 'dns']:
            provider = METADATA.entitlements(kind, context)
            self.assertEqual(set(provider['com.apple.developer.networking.networkextension']), METADATA.COMPONENTS[kind]['capabilities'])
            self.assertNotIn('com.apple.developer.team-identifier', provider)
            self.assertNotIn('com.apple.developer.system-extension.install', provider)

    def test_review_metadata_has_separate_provider_bundles_and_services(self):
        build = ROOT / 'build'
        build.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='metadata-test-', dir=build) as directory:
            for kind in ['extension', 'dns']:
                component = METADATA.COMPONENTS[kind]
                bundle = pathlib.Path(directory) / (component['identifier'] + '.systemextension')
                entitlement = pathlib.Path(directory) / (kind + '.entitlements')
                METADATA.prepare(kind, bundle, entitlement, METADATA.build_context({}))
                info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
                service = info['NetworkExtension']['NEMachServiceName']
                self.assertEqual(service, 'UNPROVISIONED.' + METADATA.GROUP_SUFFIX + '.' + component['service'])
                self.assertNotIn('$(', plistlib.dumps(info).decode())
                self.assertEqual(info['NetworkExtension']['NEProviderClasses'], component['provider'])
                self.assertEqual(info['CFBundleExecutable'], component['executable'])
                self.assertEqual(info['MacDPIIntegrationBuild'], 'local-review')
                self.assertEqual((info['CFBundleShortVersionString'], info['CFBundleVersion']), versions())
                self.assertFalse((bundle / 'Contents/embedded.provisionprofile').exists())

    def test_output_scope_rejects_source_and_unrelated_directories(self):
        with self.assertRaises(ValueError):
            METADATA.output_root(ROOT / 'Extension')
        with self.assertRaises(ValueError):
            METADATA.output_root(ROOT.parent / 'other-project')
        with self.assertRaises(ValueError):
            METADATA.output_root(ROOT / 'build')
        with self.assertRaises(ValueError):
            METADATA.validate_build_root(ROOT.parent / 'other-project')

    def test_developer_id_requires_explicit_owner_inputs(self):
        with self.assertRaises(ValueError):
            METADATA.build_context({'SIGN_IDENTITY': 'explicit-test-identity'})
        with self.assertRaises(ValueError):
            METADATA.build_context({'SIGN_IDENTITY': 'explicit-test-identity', 'MACDPI_TEAM_ID': 'TESTTEAM01'})

    def valid_profile(self, kind='host'):
        # Synthetic dictionaries only; this is not an Apple identity or provisioning profile.
        team = 'TESTTEAM01'
        identifier = METADATA.COMPONENTS[kind]['identifier']
        entitlement = {
            'com.apple.application-identifier': team + '.' + identifier,
            'com.apple.developer.team-identifier': team,
            'com.apple.developer.networking.networkextension': sorted(METADATA.COMPONENTS[kind]['capabilities']),
            'com.apple.security.application-groups': [team + '.' + METADATA.GROUP_SUFFIX],
        }
        if kind == 'host':
            entitlement['com.apple.developer.system-extension.install'] = True
        return {'TeamIdentifier': [team], 'Entitlements': entitlement,
                'ProvisionsAllDevices': True, 'DeveloperCertificates': [b'synthetic-public-certificate-fixture'],
                'ExpirationDate': datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=1)}

    def test_profile_validation_rejects_mismatched_identity_or_capability(self):
        valid = self.valid_profile()
        METADATA.validate_profile(valid, 'TESTTEAM01', METADATA.HOST_ID, 'host')
        mutations = [
            ('TeamIdentifier', ['OTHERTEAM1']),
            ('com.apple.developer.team-identifier', 'OTHERTEAM1'),
            ('com.apple.application-identifier', 'TESTTEAM01.other.application'),
            ('com.apple.developer.networking.networkextension', ['app-proxy-provider-systemextension']),
            ('com.apple.developer.system-extension.install', False),
        ]
        for key, value in mutations:
            profile = copy.deepcopy(valid)
            if key == 'TeamIdentifier':
                profile[key] = value
            else:
                profile['Entitlements'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                METADATA.validate_profile(profile, 'TESTTEAM01', METADATA.HOST_ID, 'host')

    def test_profiles_are_scoped_to_exact_component_and_distribution(self):
        for kind, component in METADATA.COMPONENTS.items():
            valid = self.valid_profile(kind)
            METADATA.validate_profile(valid, 'TESTTEAM01', component['identifier'], kind)
            for invalid_kind in METADATA.COMPONENTS:
                if invalid_kind != kind:
                    with self.subTest(kind=kind, invalid_kind=invalid_kind), self.assertRaises(ValueError):
                        METADATA.validate_profile(valid, 'TESTTEAM01', METADATA.COMPONENTS[invalid_kind]['identifier'], invalid_kind)
            for key, value in [('ProvisionsAllDevices', False), ('ProvisionedDevices', ['synthetic-device']), ('DeveloperCertificates', [])]:
                profile = copy.deepcopy(valid); profile[key] = value
                with self.subTest(kind=kind, key=key), self.assertRaises(ValueError):
                    METADATA.validate_profile(profile, 'TESTTEAM01', component['identifier'], kind)
            for key, value in [('com.apple.developer.networking.networkextension', sorted(METADATA.CAPABILITIES) + ['packet-tunnel-provider-systemextension']),
                               ('get-task-allow', True)]:
                profile = copy.deepcopy(valid); profile['Entitlements'][key] = value
                with self.subTest(kind=kind, key=key), self.assertRaises(ValueError):
                    METADATA.validate_profile(profile, 'TESTTEAM01', component['identifier'], kind)

    def test_macos_style_app_group_does_not_require_a_profile_grant(self):
        for kind, component in METADATA.COMPONENTS.items():
            profile = self.valid_profile(kind)
            del profile['Entitlements']['com.apple.security.application-groups']
            METADATA.validate_profile(profile, 'TESTTEAM01', component['identifier'], kind)
            context = {'mode': 'developer-id', 'team': 'TESTTEAM01', 'prefix': 'TESTTEAM01.'}
            self.assertEqual(METADATA.entitlements(kind, context)['com.apple.security.application-groups'],
                             ['TESTTEAM01.' + METADATA.GROUP_SUFFIX])

    def test_all_three_explicit_profiles_are_required_for_developer_id_mode(self):
        with tempfile.TemporaryDirectory(prefix='profile-fixtures-') as directory:
            env = {'SIGN_IDENTITY': 'synthetic-identity-fixture', 'MACDPI_TEAM_ID': 'TESTTEAM01'}
            profiles = {}
            for kind in METADATA.COMPONENTS:
                path = pathlib.Path(directory) / (kind + '.fixture')
                path.write_bytes(b'Synthetic fixture; not a real provisioning profile.')
                env['MACDPI_' + kind.upper() + '_PROFILE'] = str(path)
                profiles[str(path)] = self.valid_profile(kind)
            def decode(args, **kwargs):
                self.assertEqual(args[:4], ['security', 'cms', '-D', '-i'])
                return SimpleNamespace(stdout=plistlib.dumps(profiles[args[4]]))
            with mock.patch.object(METADATA.subprocess, 'run', side_effect=decode):
                context = METADATA.build_context(env)
                self.assertEqual(context['mode'], 'developer-id')
                self.assertTrue(all(kind + '_profile' in context for kind in METADATA.COMPONENTS))
                del env['MACDPI_DNS_PROFILE']
                with self.assertRaises(ValueError):
                    METADATA.build_context(env)

    def test_actual_signing_leaf_must_be_allowed_by_its_component_profile(self):
        profile = self.valid_profile('dns')
        build = ROOT / 'build'; build.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='signer-test-', dir=build) as directory:
            bundle = pathlib.Path(directory) / 'fixture.systemextension'
            def inspect(args, **kwargs):
                if args[:4] == ['security', 'cms', '-D', '-i']:
                    return SimpleNamespace(stdout=plistlib.dumps(profile))
                if '--extract-certificates' in args:
                    prefix = args[args.index('--extract-certificates') + 1]
                    pathlib.Path(prefix + '0').write_bytes(b'synthetic-public-certificate-fixture')
                return SimpleNamespace(stderr='Authority=Developer ID Application: Synthetic Fixture\nTeamIdentifier=TESTTEAM01\n')
            with mock.patch.object(METADATA.subprocess, 'run', side_effect=inspect):
                METADATA.verify_developer_signature('dns', bundle, 'TESTTEAM01')
                profile['DeveloperCertificates'] = [b'a-different-synthetic-certificate']
                with self.assertRaises(ValueError):
                    METADATA.verify_developer_signature('dns', bundle, 'TESTTEAM01')

    def test_bundle_verifier_rejects_wrong_signed_group_in_only_one_slice(self):
        spec = importlib.util.spec_from_file_location('packaging_verifier_fixture', ROOT / 'scripts/verify-packaging.py')
        verifier = importlib.util.module_from_spec(spec); spec.loader.exec_module(verifier)
        build = ROOT / 'build'; build.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='bundle-fixture-', dir=build) as directory:
            app = pathlib.Path(directory) / 'MacDPI.app'
            context = METADATA.build_context({})
            bundles = {'host': app}
            for kind, component in METADATA.COMPONENTS.items():
                if kind != 'host':
                    bundles[kind] = app / 'Contents/Library/SystemExtensions' / (component['identifier'] + '.systemextension')
                METADATA.prepare(kind, bundles[kind], pathlib.Path(directory) / (kind + '.entitlements'), context)
            fault = False
            def signed_entitlements(bundle, architecture='arm64'):
                kind = next(kind for kind, path in bundles.items() if path == bundle)
                result = METADATA.entitlements(kind, context)
                if fault and kind == 'dns' and architecture == 'x86_64':
                    result['com.apple.security.application-groups'] = ['UNPROVISIONED.unrelated']
                return result
            def inspect(args):
                interfaces = '\n'.join('@interface _TtC_' + name.replace('.', '_') + ' : ProviderBase'
                                       for component in METADATA.COMPONENTS.values() for name in component.get('provider', {}).values())
                return SimpleNamespace(stdout=interfaces, stderr='Signature=adhoc\n')
            with mock.patch.object(verifier, 'read_entitlements', side_effect=signed_entitlements), \
                 mock.patch.object(verifier, 'command', side_effect=inspect), \
                 mock.patch.object(verifier, 'slices'), contextlib.redirect_stdout(io.StringIO()):
                verifier.verify(app)
                fault = True
                with self.assertRaisesRegex(ValueError, 'dns/x86_64'):
                    verifier.verify(app)

    def test_release_archive_rejects_unsafe_zip_entries_before_extraction(self):
        spec = importlib.util.spec_from_file_location('packaging_verifier_fixture', ROOT / 'scripts/verify-packaging.py')
        verifier = importlib.util.module_from_spec(spec); spec.loader.exec_module(verifier)
        build = ROOT / 'build'; build.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='zip-safety-fixture-', dir=build) as directory:
            archive = pathlib.Path(directory) / 'MacDPI.zip'
            cases = [('MacDPI.app/../../outside', stat.S_IFREG, 'Unsafe ZIP entry path'),
                     ('/MacDPI.app/outside', stat.S_IFREG, 'Unsafe ZIP entry path'),
                     ('MacDPI.app/linked', stat.S_IFLNK, 'Unexpected ZIP entry type'),
                     ('Other.app/extra', stat.S_IFREG, 'Unexpected content outside')]
            for name, kind, error in cases:
                with self.subTest(name=name):
                    entry = zipfile.ZipInfo(name)
                    entry.external_attr = (kind | 0o644) << 16
                    with zipfile.ZipFile(archive, 'w') as zipped:
                        zipped.writestr(entry, b'synthetic content')
                    with mock.patch.object(verifier, 'command') as command:
                        with self.assertRaisesRegex(ValueError, error):
                            verifier.verify_zip(archive, {}, False)
                        command.assert_not_called()

    def test_xcode_embeds_two_actual_targets_with_safe_review_defaults(self):
        # Xcode's project.xcproj is JSON with trailing commas.
        text = (ROOT / 'MacDPI.xcodeproj/project.xcproj').read_text()
        project = json.loads(re.sub(r',\s*([}\]])', r'\1', text))
        targets = {target['name']: target for target in project['targets']}
        host = targets['MacDPI']
        self.assertTrue({'MacDPITransparentProxy', 'MacDPIDNSProxy'}.issubset(host['dependencies']))
        self.assertEqual(host['build-settings']['CODE_SIGN_ENTITLEMENTS'], 'MacDPI/App.entitlements')
        self.assertEqual(host['build-settings']['SWIFT_OBJC_BRIDGING_HEADER'], 'IntegrationSupport/ControlChannel.h')
        self.assertEqual(project['build-settings']['MACDPI_INTEGRATION_BUILD'], 'local-review')
        self.assertEqual(project['build-settings']['MACDPI_TEAM_PREFIX'], 'UNPROVISIONED.')
        version, build = versions()
        self.assertEqual(project['build-settings']['MARKETING_VERSION'], version)
        self.assertEqual(project['build-settings']['CURRENT_PROJECT_VERSION'], build)
        product_group = next(group for group in project['files'] if group.get('name') == 'Products')
        for kind, target_name in [('extension', 'MacDPITransparentProxy'), ('dns', 'MacDPIDNSProxy')]:
            target = targets[target_name]; settings = target['build-settings']
            self.assertEqual(target['product-type'], 'system-extension')
            self.assertEqual(settings['PRODUCT_BUNDLE_IDENTIFIER'], METADATA.COMPONENTS[kind]['identifier'])
            self.assertEqual(settings['PRODUCT_MODULE_NAME'], 'MacDPITransparentProxy')
            self.assertEqual(settings['SWIFT_INSTALL_MODULE'], 'NO')
            self.assertEqual(settings['SWIFT_INSTALL_OBJC_HEADER'], 'NO')
            self.assertEqual(settings['SWIFT_OBJC_BRIDGING_HEADER'], 'Extension/NetworkTransportBridge.h')
            self.assertEqual(settings['MACOSX_DEPLOYMENT_TARGET'], '12.0')
            info = plistlib.loads((ROOT / settings['INFOPLIST_FILE']).read_bytes())
            self.assertEqual(info['CFBundleShortVersionString'], '$(MARKETING_VERSION)')
            self.assertEqual(info['CFBundleVersion'], '$(CURRENT_PROJECT_VERSION)')
            for path in ['MacDPI/Core', 'Extension', 'IntegrationSupport']:
                group = next(group for group in project['files'] if group.get('path') == path)
                self.assertIn(target_name, group['target-membership'])
            product = next(product for product in product_group['children'] if METADATA.COMPONENTS[kind]['identifier'] + '.systemextension' in product['path'])
            self.assertTrue(any('MacDPI/copy/' in item.get('build-phase', '') and item.get('code-sign-on-copy') for item in product['target-membership']))

    def test_expired_profile_is_not_accepted(self):
        profile = self.valid_profile()
        profile['ExpirationDate'] = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=1)
        with self.assertRaises(ValueError):
            METADATA.validate_profile(profile, 'TESTTEAM01', METADATA.HOST_ID, 'host')


if __name__ == '__main__':
    unittest.main()
