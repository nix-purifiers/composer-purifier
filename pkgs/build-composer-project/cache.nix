# The Composer cache directory of a project: every dist of composer.lock at
# its path in Composer's cache, and every version-control checkout at its
# path (<kind>/<package>), as links into the store. It is a package for
# callPackage, with the entries of entries.nix and the purifier library
# among its arguments. The library fetches each entry (fetchEntry) and lays
# the entries out (tree).
#
# Composer reads it as its cache directory (COMPOSER_CACHE_DIR) when the
# cache is read-only (COMPOSER_CACHE_READ_ONLY=1): `composer install` then
# finds every dist of composer.lock in the cache and downloads nothing.
# Composer does not look at the checkouts; offline-lock.nix points the
# packages with version-control sources at them. buildComposerProject's
# `cache` is this, and `composer-purifier prefetch` builds it on its own
# for an install outside Nix.
{
  # The packages that fetchEntry and tree of the purifier library fetch,
  # unpack and build with, by name.
  fetchurl,
  fetchgit,
  fetchhg,
  fetchsvn,
  fetchfossil,
  runCommand,
  unzip,
  zstd,
  python3,
  writeText,
  # The entries of entries.nix.
  entries,
  # The `purifier` library namespace (lib.purifier of
  # github:nix-purifiers/purifier).
  purifier,
  # Replaces fetchers of the purifier library, by name (fetchurl, fetchgit,
  # fetchhg, fetchsvn, fetchfossil): for a company mirror or credentials.
  # Each takes the arguments of the nixpkgs fetcher of its name.
  fetchers ? { },
}:
let
  # A file entry is fetched with nixpkgs' fetchurl, which tries its mirrors
  # too.
  libraryArguments = {
    inherit
      fetchurl
      fetchgit
      fetchhg
      fetchsvn
      fetchfossil
      runCommand
      unzip
      zstd
      python3
      writeText
      ;
  }
  // fetchers;
in
purifier.tree (
  libraryArguments
  // {
    name = "composer-cache";
    entries = entries.entries;
  }
)
// {
  inherit entries;
  # The store path of one entry.
  fetch = purifier.fetchEntry libraryArguments;
}
