# SPDX-License-Identifier: MIT
"""Source-pinned Composer integration around the native Composer application."""
import argparse
import base64
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile

import project_inputs
from composer_inputs import borrowed_manifest, materialize_selected, packages, portable_lock, sdk_environment
from composer_repository import manifest


def read(path):
    return json.loads(path.read_text()) if path.is_file() else {}


def content_hash(value):
    canonical = json.dumps({key: item for key, item in value.items() if key != 'contentHash'},
                           sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()
    return 'sha256-' + base64.b64encode(hashlib.sha256(canonical).digest()).decode()


def write_lock(path, value):
    value['contentHash'] = content_hash(value)
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + '\n')


@contextmanager
def tool_lock_in_tree(root, path):
    native = root / 'composer.lock'
    if native == path:
        yield
        return
    original = native.read_bytes() if native.exists() else None
    if path.exists():
        native.write_bytes(path.read_bytes())
    try:
        yield
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(native.read_bytes())
    finally:
        if original is None:
            native.unlink(missing_ok=True)
        else:
            native.write_bytes(original)


def run_native(arguments, selected, root, environment=None, bindings=None, reconstruct=False, anchors=None):
    environment = dict(environment or os.environ)
    native = subprocess.check_output([
        'nix-build', environment['COMPOSER_PURIFIER_NIX_LIB'] + '/cli.nix',
        '--argstr', 'nixpkgs', environment['COMPOSER_PURIFIER_NIXPKGS'],
        '--argstr', 'purifier', environment['COMPOSER_PURIFIER_SHARED'],
        '--argstr', 'system', environment['COMPOSER_PURIFIER_SYSTEM'],
        '--argstr', 'projectDir', str(root), '--attr', 'nativeTools',
        '--argstr', 'additionalPackagesJson', json.dumps([value['metadata'] for value in selected.values()]),
        *sdk_arguments(environment), '--no-out-link'], text=True).strip()
    environment['COMPOSER_PURIFIER_PHP'] = native + '/php/bin/php'
    environment['COMPOSER_PURIFIER_AUTOLOAD'] = native + '/composer/share/php/composer/vendor/autoload.php'
    if not Path(environment['COMPOSER_PURIFIER_AUTOLOAD']).is_file():
        raise ValueError('selected native Composer does not expose the resolver integration autoloader; incoming Nix bindings need an adapter for this artifact')
    if reconstruct:
        materialize_selected(root, selected, environment['COMPOSER_PURIFIER_PHP'],
                             environment['COMPOSER_PURIFIER_AUTOLOAD'], bindings, environment, anchors)
    environment.update(sdk_environment(selected, environment['COMPOSER_PURIFIER_PHP'],
                                       environment['COMPOSER_PURIFIER_AUTOLOAD'], bindings, environment))
    return subprocess.call([environment['COMPOSER_PURIFIER_PHP'],
                            str(Path(__file__).with_name('composer_capture.php')), *arguments],
                           cwd=root, env=environment)


def sdk_arguments(environment):
    return ['--argstr', 'targetPhpExpression', environment.get('COMPOSER_PURIFIER_TARGET_PHP_EXPRESSION', ''),
            '--argstr', 'targetComposerExpression', environment.get('COMPOSER_PURIFIER_TARGET_COMPOSER_EXPRESSION', '')]


def main(arguments):
    parser = argparse.ArgumentParser(prog='composer-purifier', description=__doc__)
    parser.add_argument('command', choices=('lock', 'update', 'prefetch', 'publish'))
    parser.add_argument('--lockfile', default=os.environ.get('COMPOSER_PURIFIER_LOCKFILE'))
    parser.add_argument('--tool-lockfile', default=os.environ.get('COMPOSER_PURIFIER_TOOL_LOCKFILE'))
    parser.add_argument('--input', action='append')
    parser.add_argument('--no-inputs', action='store_true')
    parser.add_argument('--refresh-inputs', action='store_true')
    parser.add_argument('--repository-url')
    parser.add_argument('--force', action='store_true')
    parser.add_argument('--no-audit', action='store_true')
    options, remaining = parser.parse_known_args(arguments)
    root = Path.cwd()
    lock_path = Path(options.lockfile).resolve() if options.lockfile else root / 'composer-purifier.lock.json'
    native_lock = Path(options.tool_lockfile).resolve() if options.tool_lockfile else root / 'composer.lock'
    legacy = os.environ['COMPOSER_PURIFIER_LEGACY_COMMAND']
    try:
        previous = read(lock_path)
    except (ValueError, OSError):
        if options.input is None and not options.no_inputs:
            return subprocess.call([legacy, *arguments])
        previous = {}
    if options.input is None and not options.no_inputs and not previous.get('projectInputs') and not options.repository_url:
        return subprocess.call([legacy, *arguments])
    references = options.input
    if options.no_inputs:
        references = []
    elif references is None:
        references = [entry['reference'] for entry in previous.get('projectInputs', [])]
    pins = project_inputs.pin(references, previous.get('projectInputs', []),
                              options.refresh_inputs or options.command == 'update')
    roots = lock_path.parent / '.composer-purifier/inputs'
    views = project_inputs.native_views(pins, 'composer', roots)
    selected = packages(views)
    if selected:
        native_root = Path(os.environ['COMPOSER_PURIFIER_REAL_COMPOSER']).parent.parent
        if not (native_root / 'share/php/composer/vendor/autoload.php').is_file():
            raise ValueError('selected native Composer does not expose the resolver integration autoloader; incoming Nix bindings need an adapter for this artifact')
    legacy_options = []
    if options.lockfile:
        legacy_options += ['--lockfile', str(lock_path)]
    if options.tool_lockfile:
        legacy_options += ['--tool-lockfile', str(native_lock)]
    if options.command in ('lock', 'update'):
        with tempfile.TemporaryDirectory(prefix='composer-capture-') as temporary, tool_lock_in_tree(root, native_lock):
            bindings = Path(temporary) / 'bindings.json'
            with borrowed_manifest(root, selected):
                native_arguments = ['update', '--no-install', '--no-interaction', '--no-audit']
                if options.command == 'lock':
                    native_arguments += ['--minimal-changes']
                else:
                    native_arguments += [item for item in remaining if not item.startswith('--')]
                code = run_native(native_arguments, selected, root, bindings=bindings,
                                  reconstruct=options.command == 'update' and bool(remaining),
                                  anchors=previous.get('providedRoots'))
                if code:
                    return code
                if native_lock != root / 'composer.lock':
                    native_lock.parent.mkdir(parents=True, exist_ok=True)
                    native_lock.write_bytes((root / 'composer.lock').read_bytes())
                code = subprocess.call([legacy, 'lock', *legacy_options,
                                        *(['--force'] if options.force else []),
                                        *(['--no-audit'] if options.no_audit else [])])
                if code:
                    return code
            if pins:
                provided_roots = portable_lock(root, selected, bindings, os.environ['COMPOSER_PURIFIER_PHP'],
                                               os.environ['COMPOSER_PURIFIER_AUTOLOAD'])
        value = read(lock_path)
        value['composerLock'] = 'sha256-' + base64.b64encode(hashlib.sha256(native_lock.read_bytes()).digest()).decode()
        if pins:
            value['projectInputs'] = pins
            value['providedRoots'] = provided_roots
            value.pop('provided', None)
        else:
            value.pop('projectInputs', None)
            value.pop('provided', None)
            value.pop('providedRoots', None)
        write_lock(lock_path, value)
        if roots.exists():
            for path in roots.iterdir():
                number = path.name.split('-', 1)[0]
                if path.is_symlink() and number.isdigit() and int(number) >= len(pins):
                    path.unlink()
        if not pins:
            for name in ('cache', 'composer', 'offlineLock'):
                path = roots.parent / name
                if path.is_symlink():
                    path.unlink()
            for name in ('lock-hash', 'composer.json', 'composer.lock'):
                (roots.parent / name).unlink(missing_ok=True)
        return 0
    if options.command == 'publish':
        if len(remaining) != 1:
            raise ValueError('publish needs an artifact repository directory')
        repository = Path(subprocess.check_output([
            'nix-build', os.environ['COMPOSER_PURIFIER_NIX_LIB'] + '/cli.nix',
            '--argstr', 'nixpkgs', os.environ['COMPOSER_PURIFIER_NIXPKGS'],
            '--argstr', 'purifier', os.environ['COMPOSER_PURIFIER_SHARED'],
            '--argstr', 'system', os.environ['COMPOSER_PURIFIER_SYSTEM'],
            '--argstr', 'repositoryTools', os.environ['COMPOSER_PURIFIER_REPOSITORY_TOOLS'],
            '--argstr', 'projectDir', str(root), '--argstr', 'lockFile', str(lock_path),
            '--argstr', 'toolLockFile', str(native_lock), '--attr', 'repository', *sdk_arguments(os.environ), '--no-out-link'],
            text=True).strip())
        catalog = read(repository / '.catalog')
        target = Path(remaining[0]).resolve()
        target.mkdir(parents=True, exist_ok=True)
        for entry in catalog['packages']:
            source = repository / entry['archive']
            existing = target / entry['archive']
            if existing.exists() and existing.read_bytes() != source.read_bytes():
                raise ValueError(f"the artifact repository contains different bytes for {entry['name']} {entry['version']}")
        for entry in catalog['packages']:
            existing = target / entry['archive']
            if not existing.exists():
                shutil.copyfile(repository / entry['archive'], existing)
        old = read(target / '.catalog')
        entries = {(entry['name'], entry['version']): entry for entry in old.get('packages', [])}
        entries.update({(entry['name'], entry['version']): entry for entry in catalog['packages']})
        roots = {(entry['name'], entry['version']): entry for entry in old.get('roots', [])}
        roots.update({(entry['name'], entry['version']): entry for entry in catalog['roots']})
        (target / '.catalog').write_text(json.dumps({'format': 'composer', 'packages': list(entries.values()),
                                                   'roots': list(roots.values())}, sort_keys=True, indent=2) + '\n')
        if options.repository_url:
            index = {}
            for entry in entries.values():
                metadata = manifest(target / entry['archive'])
                metadata['dist'] = {'type': 'zip',
                    'url': options.repository_url.rstrip('/') + '/' + entry['archive'],
                    'shasum': hashlib.sha1((target / entry['archive']).read_bytes()).hexdigest()}
                index.setdefault(entry['name'], {})[entry['version']] = metadata
            (target / 'packages.json').write_text(json.dumps({'packages': index}, sort_keys=True, indent=2) + '\n')
        return 0
    with tool_lock_in_tree(root, native_lock):
        return subprocess.call([legacy, options.command, *legacy_options, *remaining])


if __name__ == '__main__':
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print('composer-purifier: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
