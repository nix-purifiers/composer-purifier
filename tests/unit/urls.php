<?php
// SPDX-License-Identifier: MIT
//
// Prints, for the Composer project in the current directory, the download
// URLs and cache path of each dist of composer.lock as Composer computes
// them (distUrls and cachePathFor in src/functions.php), as canonical JSON:
// { "<package>": { "path": …, "urls": [ … ] } }. The `urls` check compares
// it with what lib-overlays/default/entries.nix derives at evaluation time.
//
//   php tests/unit/urls.php <Composer's vendor/autoload.php> src/functions.php

declare(strict_types=1);

namespace ComposerPurifier;

use Composer\Factory;
use Composer\IO\NullIO;
use Composer\Package\AliasPackage;

require $argv[1];
require $argv[2];

$composer = Factory::create(new NullIO(), null, true);
$result = [];
foreach ($composer->getLocker()->getLockedRepository(true)->getPackages() as $package) {
    $type = $package->getDistType();
    if ($package instanceof AliasPackage || $type === null || $type === 'path') {
        continue;
    }
    $urls = distUrls($composer->getConfig(), $package);
    $result[$package->getName()] = ['path' => cachePathFor($package->getName(), $urls[0], $type), 'urls' => $urls];
}
echo canonicalJson((object) $result);
