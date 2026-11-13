<?php
// Read the target installation's native record, independently of capture-tool root metadata.
declare(strict_types=1);
require $argv[1];
$installed = realpath($argv[2]);
if ($installed === false || !is_file($installed . '/vendor/composer/installed.php')) {
    throw new RuntimeException('composer-purifier: native root metadata unavailable; this projection requires Composer installed.php (Composer 1 needs a native root adapter)');
}
$data = require $installed . '/vendor/composer/installed.php';
$root = $data['root'] ?? null;
if (!is_array($root) || !isset($root['name'], $root['pretty_version'], $root['version'], $root['install_path'])) {
    throw new RuntimeException('composer-purifier: incomplete native root metadata');
}
if (realpath($root['install_path']) !== $installed) {
    throw new RuntimeException('composer-purifier: native root install path does not identify the installed project');
}
$parser = new Composer\Package\Version\VersionParser();
if ($parser->normalize($root['pretty_version']) !== $root['version']) {
    throw new RuntimeException('composer-purifier: inconsistent native root versions');
}
foreach ($root['aliases'] ?? [] as $alias) {
    $parser->normalize($alias);
}
if (isset($argv[3]) && $argv[3] !== '' && $parser->normalize($argv[3]) !== $root['version']) {
    throw new RuntimeException('composer-purifier: explicit native root version differs from installed metadata');
}
echo json_encode($root, JSON_THROW_ON_ERROR);
