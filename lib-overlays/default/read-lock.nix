# readLock: the lock in memory of the purifier contract (CONTRACT.md of
# github:nix-purifiers/purifier). The flake publishes it as
# `lib.composer-purifier.readLock`:
#
#   lib.composer-purifier.readLock { src = ./.; }
#   # =>
#   {
#     purifier = "composer-purifier";
#     entries  = [ … ];  # the download entries of composer.lock
#     outputs  = { … };  # the outputs, named from composer.json
#     problems = [ … ];  # why the lockfiles cannot be used, each naming
#                        # the command that fixes it
#   }
#
# It reads composer.json and composer.lock of the project, and the hashes
# that composer.lock lacks from composer-purifier.lock.json (lock.nix).
# `entries` is what entries.nix derives; no entry carries `systems`, since
# composer.lock is the same on every system. `outputs` holds the project
# under its package name, and each entry of the `bin` list of
# composer.json. buildComposerProject passes the result to the `checkLock`
# of the purifier library, which fails on the problems.
{ lib }:
{
  # The root of the Composer project: the directory of composer.json.
  src,
  # The lockfile; the default is the one `composer-purifier lock` writes
  # next to composer.lock.
  lockFile ? src + "/composer-purifier.lock.json",
  # composer.lock, for a project whose source holds none.
  composerLock ? src + "/composer.lock",
}:
let
  composerJson = builtins.fromJSON (builtins.readFile (src + "/composer.json"));
  hasComposerLock = builtins.pathExists composerLock;
  lockedPackages =
    if hasComposerLock then builtins.fromJSON (builtins.readFile composerLock) else { };

  lock = import ./lock.nix { inherit lockFile; };
  derived =
    if lock.problems != [ ] || !hasComposerLock then
      {
        entries = [ ];
        byName = { };
        problems = [ ];
      }
    else
      import ./entries.nix {
        inherit lib composerJson lock;
        composerLock = lockedPackages;
      };

  # `vendor/name` becomes the package name `vendor-name`.
  pname = import ./package-name.nix { inherit composerJson src; };
  bins = lib.toList (composerJson.bin or [ ]);
in
{
  purifier = "composer-purifier";
  inherit (derived) entries;
  outputs = {
    ${pname} = {
      kind = "project";
      version = composerJson.version or "0";
    };
  }
  // lib.listToAttrs (
    map (
      bin:
      lib.nameValuePair (baseNameOf bin) {
        kind = "bin";
        script = bin;
      }
    ) bins
  );
  problems =
    lib.optional (
      !hasComposerLock
    ) "composer-purifier: there is no composer.lock for ${toString src}. Run `composer update`."
    ++ lock.problems
    ++ lib.optional (
      hasComposerLock
      && lock.composerLockHash != null
      &&
        lock.composerLockHash != builtins.convertHash {
          hash = builtins.hashFile "sha256" composerLock;
          hashAlgo = "sha256";
          toHashFormat = "sri";
        }
    ) "composer-purifier: composer.lock changed. Run `composer-purifier lock`."
    ++ derived.problems;
  # The entries by package name, and the parsed lockfiles, for the
  # builder.
  inherit (derived) byName;
  inherit composerJson lockedPackages;
  inherit (lock) projectInputs provided providedRoots;
}
