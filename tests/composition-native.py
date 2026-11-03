#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Independent Nix producer and the normal Composer development workflow."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile

sdk = Path(__file__).resolve().parents[1]
tools = Path(sys.argv[1]).resolve()

def run(*arguments, cwd=None, env=None):
    return subprocess.check_output([str(argument) for argument in arguments], cwd=cwd, env=env, text=True)

snapshot = json.loads(run('nix', 'flake', 'archive', '--json', '--no-write-lock-file', sdk))['path']
system = run('nix', 'eval', '--impure', '--raw', '--expr', 'builtins.currentSystem').strip()
with tempfile.TemporaryDirectory(prefix='composer-composition-') as temporary:
    # The physical path: on macOS the temporary directory lies under /tmp
    # or /var, both symlinks, and Nix refuses a path: flake through one.
    root = Path(temporary).resolve()
    producer, consumer = root / 'producer', root / 'consumer'
    producer.mkdir()
    consumer.mkdir()
    (producer / 'flake.nix').write_text('''{
      inputs.sdk.url = "path:SDK";
      outputs = { sdk, ... }: let
        pkgs = import sdk.inputs.nixpkgs {
          system = "SYSTEM";
          overlays = [ sdk.overlays.default ];
        };
        project = pkgs.composer-purifier.buildComposerProject {
          src = sdk.outPath + "/tests/fixtures/app";
        };
      in { packages.SYSTEM.default = project.packages.composer-purifier-fixture-app; };
    }'''.replace('SDK', snapshot).replace('SYSTEM', system))
    run('nix', 'flake', 'lock', 'path:' + str(producer), cwd=producer)
    original = json.dumps({'name': 'proof/consumer', 'require': {'composer-purifier/fixture-app': '99',
        'psr/log-implementation': '^3'}, 'bin': ['bin/proof'],
        'scripts': {'proof': '@php -r \'require "vendor/autoload.php"; if (!str_starts_with(Composer\\InstalledVersions::getVersion("monolog/monolog"),"3.")) exit(1); echo Fixture\\Greeting::text();\''}}, indent=2) + '\n'
    (consumer / 'composer.json').write_text(original)
    (consumer / 'bin').mkdir()
    (consumer / 'bin/proof').write_text('<?php require __DIR__."/../vendor/autoload.php"; if (!str_starts_with(Composer\\InstalledVersions::getVersion("monolog/monolog"),"3.")) exit(1); echo Fixture\\Greeting::text();\n')
    environment = dict(os.environ, PATH=str(tools / 'bin') + ':' + os.environ['PATH'], COMPOSER_POLICY='0',
                       COMPOSER_HOME=str(root / 'composer-home'), COMPOSER_CACHE_DIR=str(root / 'composer-cache'),
                       COMPOSER_DISABLE_NETWORK='1')
    run(tools / 'bin/composer-purifier', 'lock', '--no-audit', '--input', 'path:' + str(producer),
        cwd=consumer, env=environment)
    assert (consumer / 'composer.json').read_text() == original
    lock = json.loads((consumer / 'composer-purifier.lock.json').read_text())
    assert lock['projectInputs'][0]['narHash']
    assert not lock['dists'] and not lock['sources']
    native = json.loads((consumer / 'composer.lock').read_text())
    assert native['packages'] == [] and not lock.get('provided')
    before = (consumer / 'composer-purifier.lock.json').read_bytes()
    run(tools / 'bin/composer-purifier', 'lock', '--no-audit', cwd=consumer, env=environment)
    assert (consumer / 'composer-purifier.lock.json').read_bytes() == before
    run(tools / 'bin/composer-purifier', 'prefetch', cwd=consumer, env=environment)
    run(tools / 'bin/composer', 'install', '--no-interaction', cwd=consumer, env=environment)
    assert run(tools / 'bin/composer', 'run-script', 'proof', cwd=consumer, env=environment) == 'hello from composer-purifier'
    assert (consumer / 'composer.json').read_text() == original
    run(tools / 'bin/composer', 'remove', 'composer-purifier/fixture-app',
        '--no-interaction', '--no-audit', cwd=consumer, env=environment)
    stale = subprocess.run([str(tools / 'bin/composer'), 'install', '--no-interaction'],
                           cwd=consumer, env=environment, text=True, capture_output=True)
    assert stale.returncode and 'composer.lock changed' in stale.stderr
    run(tools / 'bin/composer', 'require', 'composer-purifier/fixture-app:99',
        '--no-interaction', '--no-audit', cwd=consumer, env=environment)
    assert json.loads((consumer / 'composer.json').read_text()) == json.loads(original)
    original = (consumer / 'composer.json').read_text()
    run(tools / 'bin/composer-purifier', 'lock', '--no-audit', cwd=consumer, env=environment)
    run(tools / 'bin/composer-purifier', 'prefetch', cwd=consumer, env=environment)
    assert run(tools / 'bin/composer', '--working-dir', consumer, 'run-script', 'proof',
               cwd=root, env=environment) == 'hello from composer-purifier'
    (consumer / 'flake.nix').write_text('''{
      inputs.sdk.url = "path:SDK";
      outputs = { sdk, ... }: let
        pkgs = import sdk.inputs.nixpkgs {
          system = "SYSTEM";
          overlays = [ sdk.overlays.default ];
        };
      in { packages.SYSTEM.default =
        (pkgs.composer-purifier.buildComposerProject { src = ./.; }).packages.proof-consumer;
      };
    }'''.replace('SDK', snapshot).replace('SYSTEM', system))
    run('nix', 'flake', 'lock', 'path:' + str(consumer), cwd=consumer)
    built = json.loads(run('nix', 'build', '--no-link', '--json', 'path:' + str(consumer)))
    assert run(Path(built[0]['outputs']['out']) / 'bin/proof') == 'hello from composer-purifier'
    published = root / 'published'
    run(tools / 'bin/composer-purifier', 'publish', published, '--repository-url', published.as_uri(),
        cwd=consumer, env=environment)
    first = {path.name: path.read_bytes() for path in published.glob('*.zip')}
    run(tools / 'bin/composer-purifier', 'publish', published, cwd=consumer, env=environment)
    assert {path.name: path.read_bytes() for path in published.glob('*.zip')} == first
    catalog = json.loads((published / '.catalog').read_text())
    exported, = [entry for entry in catalog['roots'] if entry['name'] == 'proof/consumer']
    record, = [entry for entry in catalog['packages'] if entry['name'] == 'proof/consumer']
    with zipfile.ZipFile(published / record['archive']) as archive:
        metadata = json.loads(archive.read('composer.json'))
    assert 'psr/log-implementation' not in metadata['require']
    assert metadata['require']['monolog/monolog'].startswith('=3.') and '-p' in metadata['require']['monolog/monolog']
    ordinary = root / 'ordinary'
    ordinary.mkdir()
    (ordinary / 'composer.json').write_text(json.dumps({
        'name': 'proof/ordinary', 'require': {'proof/consumer': '=' + exported['version']},
        'repositories': [{'type': 'artifact', 'url': str(published)}, {'packagist.org': False}],
        'scripts': json.loads(original)['scripts'],
    }))
    ordinary_env = dict(os.environ, COMPOSER_HOME=str(ordinary / 'home'),
                        COMPOSER_CACHE_DIR=str(ordinary / 'cache'), COMPOSER_DISABLE_NETWORK='1', COMPOSER_POLICY='0')
    native_composer = consumer / '.composer-purifier/composer/bin/composer'
    run(native_composer, 'update', '--no-interaction', '--no-audit', cwd=ordinary, env=ordinary_env)
    assert run(native_composer, 'run-script', 'proof', cwd=ordinary, env=ordinary_env) == 'hello from composer-purifier'
    indexed = root / 'indexed'
    indexed.mkdir()
    indexed_manifest = json.loads((ordinary / 'composer.json').read_text())
    indexed_manifest['repositories'] = [{'type': 'composer', 'url': published.as_uri()}, {'packagist.org': False}]
    (indexed / 'composer.json').write_text(json.dumps(indexed_manifest))
    indexed_env = dict(ordinary_env, COMPOSER_HOME=str(indexed / 'home'), COMPOSER_CACHE_DIR=str(indexed / 'cache'))
    run(native_composer, 'update', '--no-interaction', '--no-audit', cwd=indexed, env=indexed_env)
    assert run(native_composer, 'run-script', 'proof', cwd=indexed, env=indexed_env) == 'hello from composer-purifier'
    catalog_bytes = (published / '.catalog').read_bytes()
    with (published / record['archive']).open('ab') as artifact:
        artifact.write(b'corrupt')
    refused = subprocess.run([str(tools / 'bin/composer-purifier'), 'publish', str(published)],
                             cwd=consumer, env=environment, text=True, capture_output=True)
    assert refused.returncode and 'different bytes' in refused.stderr
    assert (published / '.catalog').read_bytes() == catalog_bytes
    run(tools / 'bin/composer', 'remove', 'composer-purifier/fixture-app', 'psr/log-implementation',
        '--no-interaction', '--no-audit', cwd=consumer, env=environment)
    plain = json.loads((consumer / 'composer.json').read_text())
    plain['scripts']['proof'] = '@php -r \'echo "ordinary";\''
    (consumer / 'composer.json').write_text(json.dumps(plain))
    run(tools / 'bin/composer-purifier', 'lock', '--no-inputs', '--no-audit', cwd=consumer, env=environment)
    cleared = json.loads((consumer / 'composer-purifier.lock.json').read_text())
    assert not cleared.get('projectInputs') and not cleared.get('provided')
    assert not list((consumer / '.composer-purifier/inputs').glob('[0-9]*'))
    assert not (consumer / '.composer-purifier/offlineLock').exists()
    run(tools / 'bin/composer', 'install', '--no-interaction', cwd=consumer, env=environment)
    assert run(tools / 'bin/composer', 'run-script', 'proof', cwd=consumer, env=environment) == 'ordinary'
    unlocked = root / 'unlocked'
    unlocked.mkdir()
    fallback = subprocess.run([str(tools / 'bin/composer'), '--version'], cwd=unlocked,
                              env=environment, text=True, capture_output=True)
    assert fallback.returncode == 0 and 'warning: no lockfile' in fallback.stderr
    print('PASS composer.composition.source-pinned-lock')
