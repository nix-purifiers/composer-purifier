<?php
// SPDX-License-Identifier: MIT
//
// `composer-purifier lock`: writes composer-purifier.lock.json next to
// composer.lock, for the Composer project in the current directory.
//
//   php lock.php <Composer's vendor/autoload.php> [--force] [--lockfile <path>]
//
// --lockfile writes the lockfile at <path> rather than next to composer.lock,
// for a project whose source does not hold it.
//
// The lockfile holds only the hashes that composer.lock lacks; Nix derives
// every URL, mirror and cache path from composer.lock (lib-overlays/default/entries.nix):
//
//   dists    the SRI SHA-256 hash of each dist whose `shasum` is empty in
//            composer.lock, by its `dist.url`; a dist with a `shasum` is
//            fetched with that hash and gets no entry
//   sources  the hash of the checkout of each package that composer.lock
//            gives only a git, hg, svn or fossil source, by the source URL
//            and reference (sourceKey in functions.php)
//
// `contentHash` is the hash of everything else in the file (contentHash in
// functions.php), so that an edit by hand fails the build and
// `composer-purifier prefetch`.
//
// The script uses Composer as a library: it reads the locked packages the
// way `composer install` does, computes each download URL with Composer's
// own Url::updateDistReference, and downloads through Composer's
// HttpDownloader, so the credentials of auth.json apply. The command that
// COMPOSER_PURIFIER_HASH_CHECKOUT names hashes each checkout; the
// composer-purifier package sets it to a script that runs the fetch of the
// purifier library itself.
//
// A relock keeps the hashes the old lockfile has, and downloads only what
// it lacks, so a relock of an unchanged project writes the same bytes and
// downloads nothing. --force downloads everything again.

declare(strict_types=1);

namespace ComposerPurifier;

use Composer\Factory;
use Composer\IO\ConsoleIO;
use Composer\Package\AliasPackage;
use Symfony\Component\Console\Helper\HelperSet;
use Symfony\Component\Console\Helper\QuestionHelper;
use Symfony\Component\Console\Input\ArgvInput;
use Symfony\Component\Console\Output\ConsoleOutput;

require __DIR__ . '/functions.php';

$usage = "usage: lock.php <Composer vendor/autoload.php> [--force] [--lockfile <path>]\n";
$autoload = $argv[1] ?? null;
$force = false;
$lockFileOption = null;
$arguments = array_slice($argv, 2);
while ($arguments !== []) {
    $argument = array_shift($arguments);
    if ($argument === '--force') {
        $force = true;
    } elseif ($argument === '--lockfile' && $arguments !== []) {
        $lockFileOption = array_shift($arguments);
    } else {
        $autoload = null;
        break;
    }
}
if ($autoload === null) {
    fwrite(STDERR, $usage);
    exit(2);
}
require $autoload;

try {
    $io = new ConsoleIO(new ArgvInput([]), new ConsoleOutput(), new HelperSet([new QuestionHelper()]));

    // Plugins stay off: the lock step runs before `vendor` exists, and the
    // downloads of composer.lock do not depend on them.
    $composer = Factory::create($io, null, true);
    $composerLockFile = Factory::getLockFile(Factory::getComposerFile());
    $locker = $composer->getLocker();
    if (!$locker->isLocked()) {
        throw new PurifierException('there is no composer.lock. Run `composer update` first.');
    }
    if (!$locker->isFresh()) {
        throw new PurifierException('composer.lock is out of date with composer.json. Run `composer update --lock` first.');
    }

    $lockFile = $lockFileOption ?? dirname($composerLockFile) . '/' . LOCK_FILE;
    $old = $force ? ['dists' => [], 'sources' => []] : readOldLock($lockFile);

    $config = $composer->getConfig();
    $loop = $composer->getLoop();
    $downloader = $loop->getHttpDownloader();
    $downloadDir = sys_get_temp_dir() . '/composer-purifier-' . bin2hex(random_bytes(8));
    mkdir($downloadDir, 0700, true);

    $dists = [];
    $sources = [];
    $promises = [];
    $downloads = 0;
    foreach ($locker->getLockedRepository(true)->getPackages() as $package) {
        if ($package instanceof AliasPackage || $package->getType() === 'metapackage') {
            continue;
        }
        $name = $package->getPrettyName();
        $type = $package->getDistType();
        if ($type === null) {
            $kind = (string) $package->getSourceType();
            $sourceUrl = $package->getSourceUrl();
            $reference = $package->getSourceReference();
            if ($sourceUrl === null || $reference === null) {
                throw new PurifierException("{$name} has neither a dist nor a source with a URL and a reference in composer.lock.");
            }
            $checkout = checkoutOf($name, $kind, $sourceUrl, $reference);
            $key = sourceKey($sourceUrl, $reference);
            if (!isset($old['sources'][$key])) {
                $io->writeError("Fetching {$name} ({$package->getFullPrettyVersion()}) from {$sourceUrl}");
                $downloads++;
            }
            $sources[$key] = $old['sources'][$key] ?? hashCheckout($kind, $checkout);
            continue;
        }
        // A path package is installed from the project's own files.
        if ($type === 'path') {
            continue;
        }
        if (!in_array($type, CACHED_DIST_TYPES, true)) {
            throw new PurifierException("{$name} has a dist of type {$type}, which Composer does not keep in its files cache.");
        }
        // Nix fetches a dist with a shasum by that SHA-1 hash.
        $sha1 = $package->getDistSha1Checksum();
        if ($sha1 !== null && $sha1 !== '') {
            continue;
        }

        $key = (string) $package->getDistUrl();
        if (isset($old['dists'][$key])) {
            $dists[$key] = $old['dists'][$key];
            continue;
        }
        $url = distUrls($config, $package)[0];
        $target = $downloadDir . '/' . count($promises);
        $io->writeError("Downloading {$name} ({$package->getFullPrettyVersion()})");
        $downloads++;
        $promises[] = $downloader->addCopy($url, $target, $package->getTransportOptions())->then(
            function () use (&$dists, $key, $target): void {
                $dists[$key] = sriSha256($target);
                unlink($target);
            }
        );
    }
    $loop->wait($promises);
    rmdir($downloadDir);

    ksort($dists, SORT_STRING);
    ksort($sources, SORT_STRING);
    $lock = [
        'version' => FORMAT_VERSION,
        // Objects even when they are empty, so that Nix reads attribute sets.
        'dists' => (object) $dists,
        'sources' => (object) $sources,
    ];
    $lock['contentHash'] = contentHash($lock);
    $text = json_encode($lock, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n";
    if (is_file($lockFile) && file_get_contents($lockFile) === $text) {
        $io->writeError(LOCK_FILE . ' is up to date with composer.lock.');
        exit(0);
    }
    file_put_contents($lockFile, $text);
    $io->writeError('Wrote ' . LOCK_FILE . ", after {$downloads} downloads.");
} catch (PurifierException $e) {
    fwrite(STDERR, "composer-purifier: {$e->getMessage()}\n");
    exit(1);
}
