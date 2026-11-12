# Reads a composer-purifier lockfile (written by `composer-purifier lock`).
#
# The lockfile holds only what composer.lock lacks: the hashes of the
# downloads whose hash composer.lock does not record. entries.nix derives
# everything else from composer.lock.
#
#   version      the lock format version (lock-version.nix)
#   contentHash  the hash of every other field of the lockfile, so that an
#                edit by hand fails evaluation (contentHash below)
#   dists        the SRI SHA-256 hash of each dist whose `shasum` is empty
#                in composer.lock, by its `dist.url` in composer.lock
#   sources      the hash of the checkout of each package that
#                composer.lock gives only a git, hg, svn or fossil source,
#                by "<source url>#<source reference>" of composer.lock; it
#                is the hash that the purifier library checks for that
#                checkout
#
# The result holds `dists` and `sources`, and `problems`: the reasons the
# lockfile cannot be used, each naming the command that fixes it, which
# read-lock.nix passes on. Needs no nixpkgs.
{ lockFile }:
let
  supportedVersion = import ./lock-version.nix;
  file = toString lockFile;
  exists = builtins.pathExists lockFile;
  lock = if exists then builtins.fromJSON (builtins.readFile lockFile) else { };

  relock = "Run `composer-purifier lock --force` to write it again.";
  invalid = message: "composer-purifier: ${file} ${message}. ${relock}";

  hashes = field: builtins.all builtins.isString (builtins.attrValues lock.${field});

  # The hash of everything in the lockfile but `contentHash`: the SRI
  # SHA-256 of its JSON as builtins.toJSON writes it, with sorted keys and
  # no whitespace. contentHash in src/functions.php computes the same hash.
  contentHash = builtins.convertHash {
    hash = builtins.hashString "sha256" (builtins.toJSON (builtins.removeAttrs lock [ "contentHash" ]));
    hashAlgo = "sha256";
    toHashFormat = "sri";
  };

  problem =
    if !exists then
      "composer-purifier: there is no ${file}. Run `composer-purifier lock`."
    else if !(builtins.isAttrs lock) then
      invalid "holds no JSON object"
    else if (lock.version or null) != supportedVersion then
      "composer-purifier: ${file} has lock format version ${
        builtins.toJSON (lock.version or null)
      }; this library reads version ${toString supportedVersion}. ${relock}"
    else if !(builtins.isAttrs (lock.dists or null)) || !(hashes "dists") then
      invalid "has no valid `dists` field"
    else if !(builtins.isAttrs (lock.sources or null)) || !(hashes "sources") then
      invalid "has no valid `sources` field"
    else if (lock.contentHash or null) != contentHash then
      "composer-purifier: ${file} was edited after `composer-purifier lock` wrote it: its content does not match its contentHash. ${relock}"
    else
      null;
in
{
  problems = if problem == null then [ ] else [ problem ];
  dists = if problem == null then lock.dists else { };
  sources = if problem == null then lock.sources else { };
  inherit file;
  projectInputs = lock.projectInputs or [ ];
  provided = lock.provided or [ ];
  composerLockHash = lock.composerLock or null;
  providedRoots = lock.providedRoots or { };
}
