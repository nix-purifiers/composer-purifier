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
// Bind package source paths independently of semantic package record normalization.
$nativePackages = json_decode(file_get_contents($installed . '/vendor/composer/installed.json'), true, 512, JSON_THROW_ON_ERROR);
foreach ($nativePackages['packages'] ?? [] as $package) {
    $record = $data['versions'][$package['name']] ?? null;
    if (!is_array($record) || !isset($record['version']) ||
        $parser->normalize($package['version']) !== $record['version']) {
        throw new RuntimeException('composer-purifier: installed package version differs from native installed.php: ' . $package['name']);
    }
}
$root['package_install_paths'] = [];
foreach ($data['versions'] ?? [] as $name => $record) {
    $root['package_install_paths'][$name] = isset($record['install_path'])
        ? realpath($record['install_path']) : null;
}
echo json_encode($root, JSON_THROW_ON_ERROR);
