<?php
// SPDX-License-Identifier: MIT
// Resolve virtual links with Composer's own constraint implementation.
declare(strict_types=1);
require $argv[1];
$request = json_decode(stream_get_contents(STDIN), true, 512, JSON_THROW_ON_ERROR);
$parser = new Composer\Package\Version\VersionParser();
$result = [];
foreach ($request['packages'] as $name => $package) {
    // A supplied repository can also contain its producer's development graph.
    // Composer does not install a dependency's require-dev in this consumer.
    if (!in_array($name, $request['installed'], true)) {
        continue;
    }
    foreach (['require', 'require-dev'] as $field) {
        foreach ($package['metadata'][$field] ?? [] as $dependency => $requirement) {
            if (isset($request['packages'][$dependency]) && in_array($dependency, $request['installed'], true)) {
                $result[$name][$field][$dependency] = [$dependency];
                continue;
            }
            $providers = [];
            foreach ($request['packages'] as $candidate => $value) {
                if (!in_array($candidate, $request['installed'], true)) {
                    continue;
                }
                foreach (['provide', 'replace'] as $kind) {
                    if (isset($value['metadata'][$kind][$dependency])) {
                        $provided = $value['metadata'][$kind][$dependency];
                        if ($provided === 'self.version') {
                            $provided = $value['version'];
                        }
                        if ($parser->parseConstraints($provided)->matches($parser->parseConstraints($requirement))) {
                            $providers[$candidate] = true;
                        }
                    }
                }
            }
            if ($providers !== []) {
                $result[$name][$field][$dependency] = array_keys($providers);
            } elseif (($field === 'require' || $name === ($request['root'] ?? null)) &&
                      !Composer\Repository\PlatformRepository::isPlatformPackage($dependency)) {
                throw new RuntimeException('composer-purifier: unresolved native dependency ' . $name . ' -> ' . $dependency);
            }
        }
    }
}
$normalized = [];
foreach ($request['packages'] as $name => $package) {
    $normalized[$name] = $parser->normalize($package['version']);
}
echo json_encode(['links' => $result, 'versions' => $normalized], JSON_THROW_ON_ERROR);
