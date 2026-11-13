"""Bind a target Composer installation's native root to its authored source.

All reads happen at build time. This package-private record is evidence, not
a replacement Composer manifest or a new purifier input format.
"""
import copy
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

FORMAT = 'composer-purifier-native-root-context-v1'
EXCLUDED = {'vendor', '.git', '.composer-purifier', 'composer.json', 'composer.lock'}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(data):
    return json.dumps(data, sort_keys=True, separators=(',', ':')).encode()


def payload(source, paths=None):
    source = Path(source).resolve()
    records, raw_modes = {}, {}

    def visit(relative):
        path = source / relative
        info = path.lstat()
        mode = stat.S_IMODE(info.st_mode)
        raw_modes[str(relative)] = mode
        entry = {'mode': mode & ~0o222}
        if stat.S_ISLNK(info.st_mode):
            target = path.resolve(strict=True)
            if not target.is_relative_to(source):
                raise ValueError('composer-purifier: source payload link escapes project: ' + str(relative))
            entry.update(type='link', target=os.readlink(path))
        elif stat.S_ISREG(info.st_mode):
            entry.update(type='file', sha256=digest(path.read_bytes()))
        elif stat.S_ISDIR(info.st_mode):
            entry.update(type='directory')
        else:
            raise ValueError('composer-purifier: unsupported source payload type: ' + str(relative))
        records[str(relative)] = entry
        if paths is None and entry['type'] == 'directory':
            for child in sorted(path.iterdir()):
                visit(child.relative_to(source))

    if paths is None:
        for child in sorted(source.iterdir()):
            if child.name not in EXCLUDED:
                visit(child.relative_to(source))
    else:
        for name in sorted(paths):
            visit(Path(name))
    return records, raw_modes


def installed_snapshot(root):
    """Retain all native installed files around a Composer 1 metadata query."""
    result = {}
    for parent, directories, files in os.walk(root, followlinks=False):
        for name in sorted(directories + files):
            path = Path(parent) / name
            info = path.lstat()
            record = {'mode': stat.S_IMODE(info.st_mode), 'type': stat.S_IFMT(info.st_mode)}
            if path.is_symlink():
                record['target'] = os.readlink(path)
            elif path.is_file():
                record['sha256'] = digest(path.read_bytes())
            result[str(path.relative_to(root))] = record
    return result


def native_root(request, installed):
    native_file = installed / 'vendor/composer/installed.php'
    if native_file.is_file():
        output = subprocess.check_output([
            request['php'], str(Path(__file__).with_suffix('.php')), request['autoload'],
            str(installed), request.get('nativeVersionInput') or '',
        ], text=True)
        return json.loads(output), digest(native_file.read_bytes()), {'kind': 'installed.php'}, {}
    if not str(request.get('nativeComposerVersion', '')).startswith('1.'):
        raise ValueError('composer-purifier: native root metadata unavailable; no selected Composer 1 adapter authority')
    before = installed_snapshot(installed)
    with tempfile.TemporaryDirectory(prefix='composer-native-root-') as temporary:
        env = dict(os.environ)
        if not env.get('COMPOSER_HOME'):
            env.update(HOME=temporary, COMPOSER_HOME=temporary + '/composer',
                       COMPOSER_CACHE_DIR=temporary + '/cache')
        env['COMPOSER_DISABLE_NETWORK'] = '1'
        env.pop('COMPOSER_ROOT_VERSION', None)
        if request.get('nativeVersionInput') is not None:
            env['COMPOSER_ROOT_VERSION'] = request['nativeVersionInput']
        output = subprocess.check_output([
            request['nativePhp'], str(Path(__file__).with_name('composer_root_legacy.php')),
            request['nativeComposerSource'], str(installed), request['nativeComposerVersion'],
            request.get('nativeVersionInput') or '',
        ], text=True, env=env, cwd=installed)
    if before != installed_snapshot(installed):
        raise ValueError('composer-purifier: native root query changed installed source, lock or payload')
    authority = {'kind': 'Composer1RootPackage', 'composerVersion': request['nativeComposerVersion'],
                 'composerSourceSha256': digest(Path(request['nativeComposerSource']).read_bytes())}
    return json.loads(output), digest(output.encode()), authority, {'nativeQueryOutput': output}


def observe(request):
    source, installed = Path(request['src']), Path(request['installed'])
    original_manifest = (source / 'composer.json').read_bytes()
    installed_manifest = (installed / 'composer.json').read_bytes()
    upstream_lock = Path(request['composerLock']).read_bytes()
    effective_lock = (installed / 'composer.lock').read_bytes()
    manifest = json.loads(original_manifest)
    from composer_inputs import bind, packages
    selected = packages(request.get('dependencies', []))
    if selected:
        if json.loads(installed_manifest) != bind(copy.deepcopy(manifest), selected):
            raise ValueError('composer-purifier: installed manifest is not the source native input binding')
    elif installed_manifest != original_manifest:
        raise ValueError('composer-purifier: installed manifest differs from source')
    source_payload, source_modes = payload(source)
    installed_payload, installed_modes = payload(installed, source_payload)
    if source_payload != installed_payload:
        raise ValueError('composer-purifier: installed authored payload differs from source')
    root_record, native_hash, authority, authority_evidence = native_root(request, installed)
    if Path(root_record['install_path']).resolve() != installed.resolve():
        raise ValueError('composer-purifier: native root path differs from installed project')
    if root_record['name'] != manifest['name']:
        raise ValueError('composer-purifier: native root name differs from source')
    native = json.loads((installed / 'vendor/composer/installed.json').read_text())
    captured_lock = json.loads(upstream_lock)
    effective = json.loads(effective_lock)
    if captured_lock.get('packages-dev') and isinstance(native, dict) and native.get('dev') is not True:
        raise ValueError('composer-purifier: full projection requires native development installation')
    installed_packages = native if isinstance(native, list) else native['packages']
    actual = {package['name']: package for package in installed_packages}
    expected = {package['name']: package for group in ('packages', 'packages-dev')
                for package in captured_lock.get(group, [])}
    effective_packages = {package['name']: package for group in ('packages', 'packages-dev')
                          for package in effective.get(group, [])}
    if set(expected) - set(actual):
        raise ValueError('composer-purifier: installed graph omits locked production or development packages')
    if set(actual) - set(expected) - set(selected):
        raise ValueError('composer-purifier: installed graph contains unbound packages')
    for name, package in actual.items():
        version = selected[name]['entry']['version'] if name in selected else expected[name]['version']
        if package['version'] != version or effective_packages.get(name, {}).get('version') != version:
            raise ValueError('composer-purifier: installed lock/package version differs from bound source: ' + name)
    # The location is checked by native PHP; it is deliberately not semantic identity.
    root = {key: root_record.get(key) for key in
            ('name', 'pretty_version', 'version', 'reference', 'type', 'aliases', 'dev')}
    root['source_version'] = root_record.get('source_version', root_record['pretty_version'])
    return {
        'format': FORMAT,
        'sourceIdentity': request['sourceIdentity'],
        'upstreamManifestSha256': digest(original_manifest),
        'upstreamLockSha256': digest(upstream_lock),
        'sourceComposerLockSha256': digest((source / 'composer.lock').read_bytes())
        if (source / 'composer.lock').exists() else None,
        'installedManifestSha256': digest(installed_manifest),
        'installedLockSha256': digest(effective_lock),
        'sourcePayloadSha256': digest(canonical(source_payload)),
        'installedPayloadSha256': digest(canonical(installed_payload)),
        'nativeRootMetadataSha256': native_hash,
        'nativeAuthority': authority,
        'nativeRoot': root,
        'nativeVersionInput': request.get('nativeVersionInput'),
        'manifestTransform': {
            'kind': 'composer_inputs.bind-v1' if selected else 'none',
            'selected': {name: value['entry']['version'] for name, value in sorted(selected.items())},
            'catalogs': [digest(Path(view['catalog']).read_bytes()) for view in request.get('dependencies', [])],
        },
        'runtimeIdentity': request['runtimeIdentity'],
        'evidence': {'installPath': root_record['install_path'], 'sourceRawModes': source_modes,
                     'installedRawModes': installed_modes, 'payload': source_payload,
                     'nativeAuthority': authority_evidence},
    }


def verify(request):
    context_path = Path(request.get('rootContext') or Path(request['installed']) / '.composer-purifier/root-context.json')
    if request.get('rootContextExplicit') and not context_path.is_file():
        raise ValueError('composer-purifier: explicit native root provenance file is missing')
    captured = json.loads(context_path.read_text()) if context_path.exists() else None
    if captured is None and not (Path(request['installed']) / 'vendor/composer/installed.php').is_file() and \
            str(request.get('nativeComposerVersion', '')).startswith('1.'):
        raise ValueError('composer-purifier: Composer 1 projection requires root context captured during native installation')
    if captured is not None:
        if captured.get('format') != FORMAT:
            raise ValueError('composer-purifier: unsupported native root provenance format')
        if 'nativeVersionInput' in request and request['nativeVersionInput'] != captured.get('nativeVersionInput'):
            raise ValueError('composer-purifier: stale explicit native root version input')
        request = dict(request, nativeVersionInput=captured.get('nativeVersionInput'))
    current = observe(request)
    if captured is not None:
        for key in current:
            if key == 'nativeRootMetadataSha256' and current['nativeAuthority']['kind'] == 'Composer1RootPackage':
                continue  # Raw query JSON embeds the checked current install path; retain it only as evidence.
            if key != 'evidence' and current[key] != captured.get(key):
                raise ValueError('composer-purifier: stale native root provenance: ' + key)
    semantic = {key: value for key, value in current.items()
                if key not in ('evidence', 'nativeRootMetadataSha256', 'runtimeIdentity')}
    return current, digest(canonical(semantic))


def capture(request, environment_file, environment_hash):
    raw = Path(environment_file).read_bytes()
    if digest(raw) != environment_hash:
        raise ValueError('composer-purifier: native installation environment snapshot changed')
    environment = json.loads(raw)
    if environment.get('format') != 'composer-purifier-native-install-env-v1':
        raise ValueError('composer-purifier: invalid native installation environment snapshot')
    for name, value in environment['values'].items():
        if os.environ.get(name) != value:
            raise ValueError('composer-purifier: installation environment changed before root capture: ' + name)
    actual_version = environment['values']['COMPOSER_ROOT_VERSION']
    if request.get('nativeVersionInput') is not None and request['nativeVersionInput'] != actual_version:
        raise ValueError('composer-purifier: declared root version differs from native installation environment')
    current = observe(dict(request, nativeVersionInput=actual_version))
    current['evidence']['nativeInstallEnvironment'] = environment
    current['evidence']['nativeInstallEnvironmentSha256'] = environment_hash
    return current


if __name__ == '__main__':
    request = json.loads(Path(sys.argv[1]).read_text())
    if len(sys.argv) > 3:
        request['installed'] = sys.argv[3]
    if len(sys.argv) != 6:
        raise ValueError('composer-purifier: root capture requires the original native installation environment snapshot and hash')
    context = capture(request, sys.argv[4], sys.argv[5])
    destination = Path(sys.argv[2])
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(context, indent=2) + '\n')
