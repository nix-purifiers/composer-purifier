# The composer.lock that an offline install reads: the project's
# composer.lock with two kinds of package rewritten, so that Composer finds
# them without the network.
#
# A package that composer.lock gives only a version-control source (git,
# hg, svn or fossil) gets a `path` dist at its locked checkout. Composer
# installs such a source by cloning or checking out from the repository,
# which an offline install cannot reach, so the install takes the package
# as a path dist instead.
#
# A package of a `path` repository outside the project directory, such as
# `../lib`, gets its dist URL from `pathRepositories` when `rewritePaths`
# is set. The Nix build copies only the project directory into the store,
# so a path outside it has to come in as a Nix path.
#
# Both kinds get the transport option `symlink = false`, so Composer copies
# the package into `vendor` rather than linking to the store path or to the
# build directory. composer.json is unchanged, and the content-hash of
# composer.lock covers only composer.json, so Composer still takes the
# rewritten composer.lock as up to date.
{
  lib,
  writeText,
  # composer.lock, as an attribute set.
  composerLock,
  # The entries of entries.nix.
  entries,
  # The store path of an entry (the `fetch` of cache.nix).
  fetch,
  # The Nix path of each `path` repository outside the project directory,
  # by the URL that composer.json gives it.
  pathRepositories ? { },
  # Whether to rewrite `path` dists outside the project directory. An
  # install outside Nix reads them from the file system as they are.
  rewritePaths,
  provided ? [ ],
}:
let
  outsideProject = url: lib.hasPrefix "../" url || lib.hasPrefix "/" url;

  copied =
    package: dist:
    package
    // {
      inherit dist;
      transport-options = {
        symlink = false;
      };
    };

  rewrite =
    package:
    let
      dist = package.dist or null;
    in
    if (package.type or "") == "metapackage" then
      package
    else if builtins.any (entry: entry.name == package.name) provided then
      copied package dist
    else if dist == null then
      copied package {
        type = "path";
        url = "${fetch entries.byName.${package.name}}";
        reference = package.source.reference;
      }
    else if rewritePaths && dist != null && dist.type == "path" && outsideProject dist.url then
      if pathRepositories ? ${dist.url} then
        copied package (dist // { url = "${pathRepositories.${dist.url}}"; })
      else
        throw "composer-purifier: ${package.name} comes from the path repository ${dist.url}, outside the project directory. Pass it to buildComposerProject as `pathRepositories.\"${dist.url}\"`."
    else
      package;

  rewritten = composerLock // {
    packages = map rewrite (composerLock.packages or [ ]);
    packages-dev = map rewrite (composerLock.packages-dev or [ ]);
  };
in
writeText "composer.lock" (builtins.toJSON rewritten)
