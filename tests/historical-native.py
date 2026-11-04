#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Exact historical PHP/Composer lifecycle and ordinary outgoing consumption."""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading


def run(*args, cwd, env):
    return subprocess.check_output(args, cwd=cwd, env=env, text=True).strip()


tools, expected, expected_version = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
expected_php = sys.argv[4] if len(sys.argv) > 4 else '7.4.29'
fixture = sys.argv[5] if len(sys.argv) > 5 else 'legacy-php'
with tempfile.TemporaryDirectory(prefix='composer-historical-') as temporary:
    temporary = Path(temporary)
    project = temporary / 'project'
    shutil.copytree(Path(__file__).parent / 'fixtures' / fixture, project)
    original = {p.relative_to(project): p.read_bytes() for p in project.rglob('*') if p.is_file()}
    env = dict(os.environ, LC_ALL='C', PATH=str(tools / 'bin') + os.pathsep + os.environ['PATH'],
               HOME=str(temporary / 'home'), COMPOSER_HOME=str(temporary / 'home/composer'),
               COMPOSER_CACHE_DIR=str(temporary / 'cache'))
    assert run('php', '-r', 'echo PHP_VERSION;', cwd=project, env=env) == expected_php
    assert expected_version in run('composer', '--version', cwd=project, env=env)
    run('composer-purifier', 'lock', '--no-audit', cwd=project, env=env)
    run('composer-purifier', 'prefetch', cwd=project, env=env)
    offline = dict(env, http_proxy='http://127.0.0.1:9', https_proxy='http://127.0.0.1:9',
                   HTTP_PROXY='http://127.0.0.1:9', HTTPS_PROXY='http://127.0.0.1:9', NO_PROXY='')
    run('composer', 'install', '--no-interaction', cwd=project, env=offline)
    assert run('composer', 'run-script', 'test', cwd=project, env=offline).splitlines()[-1] == '42 on ' + expected_php
    assert (project / 'built.txt').read_text() == expected_php
    # A generated assertion file is not part of the original project source.
    (project / 'built.txt').unlink()
    repository = temporary / 'repository'
    server = ThreadingHTTPServer(('127.0.0.1', 0), partial(SimpleHTTPRequestHandler, directory=str(repository)))
    url = 'http://127.0.0.1:' + str(server.server_port)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        run('composer-purifier', 'publish', '--repository-url', url, str(repository), cwd=project, env=env)
        for archive in expected.glob('*.zip'):
            assert (repository / archive.name).read_bytes() == archive.read_bytes(), 'native publication differs from pure projection: ' + archive.name
        catalog = json.loads((repository / '.catalog').read_text())
        root = next(entry for entry in catalog['packages'] if entry['name'] == 'proof/legacy-php')
        consumer = temporary / 'ordinary'
        consumer.mkdir()
        (consumer / 'composer.json').write_text(json.dumps({
            'name': 'proof/ordinary', 'require': {'proof/legacy-php': '=' + root['version']},
            'repositories': [{'type': 'composer', 'url': url}, {'packagist.org': False}],
            'config': {'secure-http': False}}))
        ordinary = dict(env, COMPOSER_PURIFIER='0', COMPOSER_CACHE_DIR=str(temporary / 'ordinary-cache'))
        run('composer', 'update', '--no-interaction', '--prefer-dist', cwd=consumer, env=ordinary)
        assert run('php', '-r', 'require "vendor/autoload.php"; $x = new Psr\\Log\\NullLogger(); echo get_class($x);', cwd=consumer, env=ordinary) == 'Psr\\Log\\NullLogger'
        assert run('php', consumer / 'vendor/proof/legacy-php/bin/legacy-php', cwd=consumer, env=ordinary) == '42 on ' + expected_php
        assert not (consumer / '.composer-purifier').exists()
    finally:
        server.shutdown()
        server.server_close()
    for path, data in original.items():
        assert (project / path).read_bytes() == data, 'native workflow changed source ' + str(path)
    print('PASS PHP' + expected_php + '/Composer' + expected_version + ' lock/prefetch/offline install/scripts, byte-equal publication and ordinary downstream install/execution; source unchanged')
