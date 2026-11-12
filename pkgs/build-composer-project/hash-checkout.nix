# What `composer-purifier lock` builds to learn the hash of a checkout: the
# fetch of the purifier library (fetchEntry) for that checkout, with a fake
# hash. The build fetches the checkout and fails with the hash it got,
# which composer-purifier-hash-checkout reads. The hash is then exactly the
# one that the same fetch checks in a build.
#
#   nixpkgs    the nixpkgs source directory
#   purifier   the source directory of the purifier library
#   system     the system to build for
#   kind       git, hg, svn or fossil
#   checkout   the checkout of the lockfile entry, as JSON
{
  nixpkgs,
  purifier,
  system,
  kind,
  checkout,
}:
let
  pkgs = import nixpkgs { inherit system; };
  library = import (/. + purifier) { inherit (pkgs) lib; };
in
library.fetchEntry { inherit pkgs; } {
  path = "prefetch/checkout";
  ${kind} = builtins.fromJSON checkout;
  hash = pkgs.lib.fakeHash;
}
