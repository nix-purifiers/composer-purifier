<?php
// Canonical package records through the selected native metadata SDK.
declare(strict_types=1);
require $argv[1];
$request = json_decode(stream_get_contents(STDIN), true, 512, JSON_THROW_ON_ERROR);
$parser = new Composer\Package\Version\VersionParser();
$loader = new Composer\Package\Loader\ArrayLoader($parser);
$dumper = new Composer\Package\Dumper\ArrayDumper();
$result = [];
foreach ($request as $group => $packages) {
    $result[$group] = [];
    foreach ($packages as $name => $record) {
        if (isset($record['version_normalized']) && $parser->normalize($record['version']) !== $record['version_normalized']) {
            throw new RuntimeException('composer-purifier: inconsistent installed normalized version: ' . $name);
        }
        // Native installation bookkeeping does not change package metadata.
        unset($record['version_normalized'], $record['install-path'], $record['installation-source'], $record['dev_requirement']);
        $package = $loader->load($record);
        $canonical = $dumper->dump($package);
        $canonical['version_normalized'] = $package->getVersion();
        $result[$group][$name] = $canonical;
    }
    $result[$group] = (object) $result[$group];
}
echo json_encode($result, JSON_THROW_ON_ERROR);
