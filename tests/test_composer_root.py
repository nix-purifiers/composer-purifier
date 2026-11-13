"""Native Composer controls for target root authority and source provenance."""
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.environ.get('COMPOSER_REPOSITORY_TOOLS',
                                str(Path(__file__).resolve().parents[1] / 'tools')))
from composer_root import FORMAT, observe, payload, verify

composer, php, autoload = sys.argv[1:4]
sys.argv = sys.argv[:1]


class NativeRoot(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source = self.root / 'source'
        self.source.mkdir()
        (self.source / 'cache').mkdir()
        (self.source / 'cache/authored.php').write_text('<?php return 42;\n')
        (self.source / 'entry.php').write_text('<?php echo 42;\n')
        (self.source / 'entry.php').chmod(0o755)
        (self.source / 'inside.php').symlink_to('cache/authored.php')
        (self.source / 'composer.json').write_text(json.dumps({
            'name': 'native/provenance', 'license': 'MIT',
            'autoload': {'files': ['entry.php']},
        }, indent=2) + '\n')
        self.installed = self.root / 'installed'
        shutil.copytree(self.source, self.installed, symlinks=True)
        self.environment = dict(os.environ, COMPOSER_HOME=str(self.root / 'home'),
                                COMPOSER_CACHE_DIR=str(self.root / 'cache'),
                                COMPOSER_ROOT_VERSION='0.24.0', COMPOSER_DISABLE_NETWORK='1',
                                COMPOSER_ALLOW_SUPERUSER='1', COMPOSER_POLICY='0')
        self.install()
        self.lock = self.root / 'captured.lock'
        self.lock.write_bytes((self.installed / 'composer.lock').read_bytes())
        self.request = {
            'src': str(self.source), 'installed': str(self.installed),
            'composerLock': str(self.lock), 'php': php, 'autoload': autoload,
            'sourceIdentity': hashlib.sha256(b'ordinary-native-source-control').hexdigest(),
            'dependencies': [], 'runtimeIdentity': {'php': php, 'composer': composer},
            'nativeVersionInput': '0.24.0',
        }

    def tearDown(self):
        self.temporary.cleanup()

    def install(self, *flags):
        subprocess.run([composer, 'install', '--no-interaction', '--no-progress', *flags],
                       cwd=self.installed, env=self.environment, check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def context(self):
        data = observe(self.request)
        path = self.installed / '.composer-purifier/root-context.json'
        path.parent.mkdir(exist_ok=True)
        path.write_text(json.dumps(data))
        return data, path

    def test_native_root_version_and_capture_autoload_are_distinct(self):
        original = (self.source / 'composer.json').read_bytes()
        context, identity = verify(self.request)
        self.assertEqual(context['nativeRoot']['pretty_version'], '0.24.0')
        self.assertEqual(context['nativeRoot']['version'], '0.24.0.0')
        self.assertNotIn('version', json.loads(original))
        self.assertEqual((self.installed / 'composer.json').read_bytes(), original)
        self.assertEqual(context['format'], FORMAT)
        self.assertEqual(subprocess.check_output([php, str(self.installed / 'entry.php')], text=True), '42')
        self.assertEqual(len(identity), 64)

    def test_context_rejects_forged_version_source_and_format(self):
        original, path = self.context()
        for field, value in [('sourceIdentity', 'f' * 64), ('format', 1),
                             ('upstreamLockSha256', '0' * 64),
                             ('runtimeIdentity', {'php': 'different-native-context'}),
                             ('nativeRoot', dict(original['nativeRoot'], pretty_version='9.9.9'))]:
            forged = dict(original, **{field: value})
            path.write_text(json.dumps(forged))
            with self.assertRaises(ValueError, msg=field):
                verify(self.request)
        path.write_text(json.dumps(original))
        verify(self.request)

    def test_authored_cache_and_modes_are_not_dropped(self):
        current, _ = payload(self.source)
        self.assertIn('cache/authored.php', current)
        target = self.installed / 'entry.php'
        mode = target.stat().st_mode & 0o7777
        target.chmod(mode & ~0o222)
        observe(self.request)  # A writable build copy becomes a read-only store output.
        for changed in [mode ^ 0o100, mode ^ 0o040, mode | 0o2000]:
            try:
                target.chmod(changed)
            except PermissionError:
                if changed & 0o2000:
                    print('Native sandbox forbids setgid control; executable/read permission controls still required')
                    continue
                raise
            with self.assertRaises(ValueError):
                observe(self.request)
        target.chmod(mode)
        (self.installed / 'cache/authored.php').write_text('<?php return 43;\n')
        with self.assertRaises(ValueError):
            observe(self.request)

    def test_link_escape_and_dangling_are_rejected(self):
        link = self.source / 'inside.php'
        for target in ['missing.php', '../outside.php']:
            (self.root / 'outside.php').write_text('outside')
            link.unlink()
            link.symlink_to(target)
            with self.assertRaises((ValueError, FileNotFoundError)):
                payload(self.source)

    def test_missing_native_record_is_explicitly_unsupported(self):
        (self.installed / 'vendor/composer/installed.php').unlink()
        with self.assertRaisesRegex(ValueError, 'native root metadata unavailable'):
            observe(self.request)

    def test_explicit_provenance_path_must_not_silently_fall_back(self):
        with self.assertRaisesRegex(ValueError, 'provenance file is missing'):
            verify(dict(self.request, rootContext=str(self.root / 'missing.json'), rootContextExplicit=True))

    def test_explicit_native_version_mismatch_is_refused(self):
        with self.assertRaises(subprocess.CalledProcessError):
            observe(dict(self.request, nativeVersionInput='9.9.9'))

    def test_absent_source_lock_and_external_lock_are_independently_bound(self):
        context, path = self.context()
        self.assertIsNone(context['sourceComposerLockSha256'])
        self.assertEqual(context['upstreamLockSha256'], hashlib.sha256(self.lock.read_bytes()).hexdigest())
        (self.source / 'composer.lock').write_bytes(self.lock.read_bytes())
        self.assertEqual(observe(self.request)['sourceComposerLockSha256'],
                         hashlib.sha256(self.lock.read_bytes()).hexdigest())
        with self.assertRaisesRegex(ValueError, 'stale native root provenance'):
            verify(self.request)

        (self.source / 'composer.lock').unlink()
        self.lock.write_text(self.lock.read_text() + '\n')
        with self.assertRaisesRegex(ValueError, 'stale native root provenance'):
            verify(self.request)

    def test_native_development_graph_cannot_be_silently_trimmed(self):
        library = self.source / 'devlib'
        library.mkdir()
        (library / 'composer.json').write_text(json.dumps({
            'name': 'native/local-dev', 'version': '1.0.0', 'license': 'MIT',
        }))
        manifest = json.loads((self.source / 'composer.json').read_text())
        manifest.update({'require-dev': {'native/local-dev': '1.0.0'},
                         'repositories': [{'type': 'path', 'url': './devlib',
                                           'options': {'symlink': False}}, {'packagist.org': False}]})
        (self.source / 'composer.json').write_text(json.dumps(manifest))
        shutil.rmtree(self.installed)
        shutil.copytree(self.source, self.installed, symlinks=True)
        subprocess.run([composer, 'update', '--no-interaction', '--no-progress'],
                       cwd=self.installed, env=self.environment, check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.lock.write_bytes((self.installed / 'composer.lock').read_bytes())
        observe(self.request)
        shutil.rmtree(self.installed / 'vendor')
        self.install('--no-dev')
        with self.assertRaisesRegex(ValueError, 'native development installation'):
            observe(self.request)

    def test_unresolved_root_dev_requirement_is_not_silently_dropped(self):
        document = json.loads((self.source / 'composer.json').read_text())
        document['require-dev'] = {'native/missing-dev': '^1.0'}
        tool = Path(sys.modules['composer_root'].__file__).with_name('composer_links.php')
        result = subprocess.run([php, str(tool), autoload], input=json.dumps({
            'root': document['name'], 'packages': {document['name']: {
                'metadata': document, 'version': '0.24.0'}}, 'installed': [document['name']],
        }), text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('unresolved native dependency', result.stdout + result.stderr)

    def test_self_version_provider_uses_the_native_root_version(self):
        document = json.loads((self.source / 'composer.json').read_text())
        document.update({'require': {'native/virtual-root': '^0.24'},
                         'provide': {'native/virtual-root': 'self.version'},
                         'repositories': [{'packagist.org': False}]})
        for root in [self.source, self.installed]:
            (root / 'composer.json').write_text(json.dumps(document))
        subprocess.run([composer, 'update', '--no-interaction', '--no-progress'],
                       cwd=self.installed, env=self.environment, check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.lock.write_bytes((self.installed / 'composer.lock').read_bytes())
        native = observe(self.request)['nativeRoot']
        self.assertEqual(native['source_version'], '0.24.0')
        tool = Path(sys.modules['composer_root'].__file__).with_name('composer_links.php')
        request = {'root': document['name'], 'packages': {document['name']: {
            'metadata': document, 'version': native['source_version']}}, 'installed': [document['name']]}
        result = subprocess.run([php, str(tool), autoload], input=json.dumps(request),
                                text=True, capture_output=True, check=True)
        self.assertEqual(json.loads(result.stdout)['links'][document['name']]['require']['native/virtual-root'],
                         [document['name']])
        request['packages'][document['name']]['version'] = '1.0.0'  # Reproduce the removed helper guess.
        result = subprocess.run([php, str(tool), autoload], input=json.dumps(request),
                                text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
