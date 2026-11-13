<?php
// Composer 1 authority: its actual PHAR, target PHP, RootPackage and parser.
// Keep this data helper compatible with the existing historical PHP points.
require 'phar://' . $argv[1] . '/vendor/autoload.php';
if (strpos(Composer\Composer::VERSION, '1.') !== 0 || Composer\Composer::VERSION !== $argv[3]) {
    throw new RuntimeException('composer-purifier: legacy root adapter requires the selected native Composer 1');
}
$installed = realpath($argv[2]);
if ($installed === false) {
    throw new RuntimeException('composer-purifier: missing installed native project');
}
$factory = new Composer\Factory();
// fullLoad=false injects a 1.0.0 shortcut before RootPackageLoader. Never use it.
$composer = $factory->createComposer(new Composer\IO\NullIO(), $installed . '/composer.json', false, $installed, true);
$package = $composer->getPackage();
$parser = new Composer\Package\Version\VersionParser();
$normalized = $parser->normalize($package->getVersion());
$pretty = $package->getPrettyVersion();
$sourceVersion = $pretty;
try {
    if ($parser->normalize($pretty) !== $normalized) {
        throw new RuntimeException('composer-purifier: inconsistent native Composer 1 root versions');
    }
} catch (UnexpectedValueException $error) {
    // This exact native diagnostic is not a version. The version comes from
    // RootPackage itself, independently normalized by the same native parser.
    if ($pretty !== 'No version set (parsed as 1.0.0)') {
        throw $error;
    }
    $sourceVersion = $normalized;
}
if (isset($argv[4]) && $argv[4] !== '' && $parser->normalize($argv[4]) !== $normalized) {
    throw new RuntimeException('composer-purifier: explicit native root version differs from Composer 1 RootPackage');
}
$aliases = $package->getAliases();
foreach ($aliases as $alias) {
    if (isset($alias['alias'], $alias['alias_normalized']) &&
        $parser->normalize($alias['alias']) !== $alias['alias_normalized']) {
        throw new RuntimeException('composer-purifier: inconsistent native Composer 1 root alias');
    }
}
echo json_encode(array(
    'name' => $package->getName(),
    'pretty_version' => $pretty,
    'version' => $normalized,
    'source_version' => $sourceVersion,
    'reference' => $package->getSourceReference(),
    'type' => $package->getType(),
    'aliases' => $aliases,
    'dev' => $package->isDev(),
    'install_path' => $installed,
    'authority' => 'Composer1RootPackage',
    'composer_version' => Composer\Composer::VERSION
));
