# SPDX-License-Identifier: MIT
"""Project Composer's installed graph into a native artifact repository."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def version(identity, normalized='0.0.0'):
    # PHP's version_compare overflows on arbitrary 256-bit decimal components.
    # Composer accepts a stable patch qualifier with several numeric components.
    # Each component fits exactly in both a 64-bit integer and an IEEE double.
    if len(identity) != 64 or any(letter not in '0123456789abcdef' for letter in identity):
        raise ValueError('Composer identity must be a SHA-256 hexadecimal digest')
    chunks = [str(int(identity[max(0, 64 - 13 * (index + 1)):64 - 13 * index], 16))
              for index in range(5)]
    core = normalized.split('-', 1)[0]
    if not all(part.isdigit() for part in core.split('.')):
        core = '0.0.0'
    return core + '-p' + '.'.join(reversed(chunks))


def manifest(archive):
    with zipfile.ZipFile(archive) as package:
        names = [name for name in package.namelist() if name == 'composer.json']
        if len(names) != 1:
            raise ValueError(f'Composer archive must contain one root composer.json: {archive}')
        return json.loads(package.read(names[0]))


def normalize_archive(source, destination):
    # Composer applies archive exclusions and creates the native dist. Normalize
    # only ZIP order, timestamps and permissions for independent Nix rebuilds.
    with zipfile.ZipFile(source) as original, zipfile.ZipFile(destination, 'w') as output:
        for entry in sorted(original.infolist(), key=lambda item: item.filename):
            copied = zipfile.ZipInfo(entry.filename, (1980, 1, 1, 0, 0, 0))
            copied.compress_type = entry.compress_type
            copied.create_system = 3
            copied.external_attr = entry.external_attr
            output.writestr(copied, original.read(entry))


def extract_archive(archive, destination):
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    root = destination.resolve()
    with zipfile.ZipFile(archive) as package:
        for entry in package.infolist():
            relative = Path(entry.filename)
            target = destination / relative
            if relative.is_absolute() or '..' in relative.parts or not target.resolve().is_relative_to(root):
                raise ValueError('unsafe Composer archive member')
            mode = entry.external_attr >> 16
            target.parent.mkdir(parents=True, exist_ok=True)
            if entry.is_dir():
                target.mkdir(exist_ok=True)
            elif stat.S_ISLNK(mode):
                link = package.read(entry).decode()
                if not (target.parent / link).resolve().is_relative_to(root):
                    raise ValueError('unsafe Composer archive symlink')
                target.symlink_to(link)
            else:
                target.write_bytes(package.read(entry))
                target.chmod((mode & 0o777) | 0o600)
    return destination


def project(request, destination, catalog_path, composer):
    out = Path(destination)
    out.mkdir(parents=True, exist_ok=True)
    supplied = {}
    for dependency in request.get('dependencies', []):
        repository = Path(dependency['repository'])
        catalog = json.loads(Path(dependency['catalog']).read_text())
        if catalog.get('format') != 'composer':
            raise ValueError('not a Composer artifact repository')
        for entry in catalog['packages']:
            archive = entry['archive']
            if Path(archive).name != archive:
                raise ValueError('invalid Composer archive path')
            source = repository / archive
            data = source.read_bytes()
            if hashlib.sha256(data).hexdigest() != entry['checksum']:
                raise ValueError('corrupt supplied Composer archive')
            metadata = manifest(source)
            if (metadata['name'], metadata['version']) != (entry['name'], entry['version']):
                raise ValueError('inconsistent supplied Composer archive')
            if entry['name'] in supplied and supplied[entry['name']][0] != entry:
                raise ValueError(f"conflicting Nix sources for Composer package {entry['name']}")
            supplied[entry['name']] = entry, source, metadata
    root = json.loads((Path(request['src']) / 'composer.json').read_text())
    root_name = root['name']
    installed = Path(request['installed'])
    installed_file = installed / 'vendor/composer/installed.json'
    native = json.loads(installed_file.read_text()) if installed_file.exists() else {'packages': []}
    packages = native if isinstance(native, list) else native['packages']
    nodes = {}
    locked = json.loads(Path(request['composerLock']).read_text())
    lock_packages = {item['name']: item for field in ('packages', 'packages-dev') for item in locked.get(field, [])}
    for package in packages:
        name = package['name']
        if name in supplied:
            continue
        if package.get('type') == 'metapackage':
            source = None
        elif 'install-path' in package:
            source = (installed / 'vendor/composer' / package['install-path']).resolve()
        else:
            # Composer 1 records a flat installed.json without install-path.
            # Its standard library layout is vendor/<package-name>.
            if package.get('type', 'library') != 'library':
                raise ValueError(f'Composer 1 package {name} requires an installation-path adapter for its type')
            source = (installed / 'vendor' / name).resolve()
        original = lock_packages[name]
        nodes[name] = {'metadata': package, 'source': source,
                       'identity': request['origins'][name], 'version': original['version']}
    nodes[root_name] = {'metadata': root, 'source': Path(request['src']),
                        'identity': request['sourceIdentity'], 'version': root.get('version', '1.0.0')}
    names = set(nodes) | set(supplied)
    link_packages = {name: {'metadata': node['metadata'], 'version': node['version']} for name, node in nodes.items()}
    link_packages.update({name: {'metadata': value[2], 'version': value[0]['sourceVersion']}
                          for name, value in supplied.items()})
    native_links = json.loads(subprocess.check_output([
        request['php'], str(Path(__file__).with_name('composer_links.php')), request['autoload']],
        input=json.dumps({'packages': link_packages, 'installed': [root_name, *[package['name'] for package in packages]]}), text=True))
    links = native_links['links']
    def edges(name):
        fields = ('require', 'require-dev') if name == root_name else ('require',)
        return sorted({dependency for field in fields for dependencies in links.get(name, {}).get(field, {}).values()
                       for dependency in dependencies})
    def fingerprint(start):
        pending, visited, graph = [start], set(), []
        while pending:
            name = pending.pop()
            if name in visited:
                continue
            visited.add(name)
            if name in supplied:
                entry = supplied[name][0]
                graph.append({'name': name, 'provided': entry['version'], 'checksum': entry['checksum']})
            else:
                node = nodes[name]
                dependencies = edges(name)
                graph.append({'name': name, 'source': node['identity'], 'version': node['version'],
                              'dependencies': dependencies})
                pending.extend(dependencies)
        return digest({'projector': request['projectorIdentity'],
                       'graph': sorted(graph, key=lambda item: item['name'])})
    versions = {name: version(fingerprint(name), native_links['versions'][name]) for name in nodes}
    versions.update({name: value[0]['version'] for name, value in supplied.items()})
    catalog_packages = []
    for name, (entry, source, metadata) in sorted(supplied.items()):
        shutil.copyfile(source, out / entry['archive'])
        catalog_packages.append(entry)
    with tempfile.TemporaryDirectory(prefix='composer-projector-') as temporary:
        temporary = Path(temporary)
        environment = dict(os.environ, COMPOSER_HOME=str(temporary / 'home'),
                           COMPOSER_CACHE_DIR=str(temporary / 'cache'), COMPOSER_ALLOW_SUPERUSER='1',
                           COMPOSER_DISABLE_NETWORK='1', COMPOSER_POLICY='0')
        for index, (name, node) in enumerate(sorted(nodes.items())):
            source = temporary / str(index)
            if node['source'] is None:
                source.mkdir()
                metadata = {key: value for key, value in node['metadata'].items()
                            if not key.startswith('_') and key not in {'install-path', 'installation-source',
                                'dev_requirement', 'version_normalized', 'dist', 'source'}}
                (source / 'composer.json').write_text(json.dumps(metadata))
            else:
                shutil.copytree(node['source'], source, symlinks=True,
                                ignore=shutil.ignore_patterns('.git', 'vendor', '.composer-purifier', 'result*'))
            for path in [source, *source.rglob('*')]:
                if not path.is_symlink():
                    path.chmod(path.stat().st_mode | 0o200)
            metadata = json.loads((source / 'composer.json').read_text())
            if name != root_name:
                metadata['require'] = dict(node['metadata'].get('require', {}))
            metadata['version'] = versions[name]
            for field in (('require', 'require-dev') if name == root_name else ('require',)):
                for dependency, providers in links.get(name, {}).get(field, {}).items():
                    metadata[field].pop(dependency, None)
                    for provider in providers:
                        metadata[field][provider] = '=' + versions[provider]
            for field in ('provide', 'replace', 'conflict'):
                for dependency, requirement in metadata.get(field, {}).items():
                    if requirement == 'self.version':
                        metadata[field][dependency] = node['version']
            (source / 'composer.json').write_text(json.dumps(metadata, sort_keys=True, indent=2) + '\n')
            archive = digest({'name': name, 'version': versions[name]}) + '.zip'
            build = temporary / 'archives'
            build.mkdir(exist_ok=True)
            subprocess.run([composer, 'archive', '--no-plugins',
                            *(['--no-scripts'] if request.get('archiveNoScripts', True) else []), '--no-interaction',
                            '--format=zip', '--dir=' + str(build), '--file=' + archive[:-4]],
                           cwd=source, env=environment, check=True)
            normalize_archive(build / archive, out / archive)
            catalog_packages.append({'name': name, 'version': versions[name], 'sourceVersion': node['version'],
                                     'archive': archive, 'checksum': hashlib.sha256((out / archive).read_bytes()).hexdigest()})
    catalog = {'format': 'composer', 'roots': [{'name': root_name, 'version': versions[root_name]}],
               'packages': sorted(catalog_packages, key=lambda item: item['name'])}
    for entry in catalog['packages']:
        extract_archive(out / entry['archive'], Path(catalog_path).parent / 'sources' / entry['archive'][:-4])
    text = json.dumps(catalog, sort_keys=True, indent=2) + '\n'
    (out / '.catalog').write_text(text)
    Path(catalog_path).parent.mkdir(parents=True, exist_ok=True)
    Path(catalog_path).write_text(text)


if __name__ == '__main__':
    project(json.loads(Path(sys.argv[1]).read_text()), *sys.argv[2:])
