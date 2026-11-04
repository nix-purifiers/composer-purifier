# What the `composer-purifier` command builds, with nixpkgs and the purifier
# library from the composer-purifier package that runs the command:
#
#   cache        the Composer cache of the project (cache.nix)
#   composer     Composer on the PHP that the project requires with its
#                require-dev packages (php.nix)
#   offlineLock  the composer.lock that the composer of this package reads
#                for an offline install (offline-lock.nix), with the path
#                repositories as they are on the file system
#   release      the dist archive of the project, as the builder
#                builds it in the sandbox
#
# Arguments:
#
#   nixpkgs     the nixpkgs source directory
#   purifier    the source directory of the purifier library
#   system      the system to build for
#   projectDir  the absolute path of the directory of composer.json
#   lockFile    the absolute path of the lockfile; "" for the
#               composer-purifier.lock.json of the project directory
#   toolLockFile  the absolute path of the composer.lock to use in place of
#               the one in the project directory; "" for that one
{
  nixpkgs,
  purifier,
  system,
  projectDir,
  lockFile ? "",
  toolLockFile ? "",
  additionalPackages ? [ ],
  additionalPackagesJson ? null,
  repositoryTools ? null,
  targetPhpExpression ? "",
  targetComposerExpression ? "",
}:
let
  pkgs = import nixpkgs { inherit system; };
  library = import (/. + purifier) { inherit (pkgs) lib; };
  dir = /. + projectDir;
  lockPath = if lockFile == "" then dir + "/composer-purifier.lock.json" else /. + lockFile;
  composerLockPath = if toolLockFile == "" then dir + "/composer.lock" else /. + toolLockFile;
  selected = library.projectInputs {
    dependencies = library.lockedProjectInputs {
      inputs =
        if additionalPackagesJson != null || !builtins.pathExists lockPath then
          [ ]
        else
          (builtins.fromJSON (builtins.readFile lockPath)).projectInputs or [ ];
      inherit system;
    };
    formats = [ "composer" ];
  };
  locked = library.checkLock (
    import ./read-lock.nix { inherit (pkgs) lib; } {
      src = dir;
      lockFile = lockPath;
      composerLock = composerLockPath;
    }
  );
  # The PHP reads composer.json and composer.lock alone, so that
  # `composer-purifier update` gets it while the purifier lockfile is stale
  # or composer.lock does not exist yet.
  targetPhp =
    if targetPhpExpression == "" then
      null
    else
      import (builtins.toFile "composer-target-php.nix" targetPhpExpression);
  targetComposer =
    if targetComposerExpression == "" then
      null
    else
      import (builtins.toFile "composer-target-tool.nix" targetComposerExpression);
  php =
    if targetPhp != null then
      targetPhp
    else
      pkgs.callPackage ./php.nix {
        composerJson = builtins.fromJSON (builtins.readFile (dir + "/composer.json"));
        composerLock =
          (
            if builtins.pathExists composerLockPath then
              builtins.fromJSON (builtins.readFile composerLockPath)
            else
              { }
          )
          // {
            packages =
              (
                if additionalPackagesJson == null then
                  additionalPackages
                else
                  builtins.fromJSON additionalPackagesJson
              )
              ++ (
                if builtins.pathExists composerLockPath then
                  (builtins.fromJSON (builtins.readFile composerLockPath)).packages or [ ]
                else
                  [ ]
              );
          };
        dev = true;
        extraRequirements = pkgs.lib.concatMap (
          input: input.repository.platformRequirements or [ ]
        ) selected;
      };
  composer = if targetComposer != null then targetComposer else php.packages.composer;
  projectSdk =
    pkgs.lib.optionalAttrs (targetPhp != null) { php = targetPhp; }
    // pkgs.lib.optionalAttrs (targetComposer != null) { composer = targetComposer; };
  cache = pkgs.callPackage ./cache.nix {
    entries = {
      entries = library.entriesFor system locked;
      inherit (locked) byName;
    };
    purifier = library;
  };
  build = pkgs.callPackage ./build-composer-project.nix (
    {
      purifier = library;
    }
    // pkgs.lib.optionalAttrs (repositoryTools != null) {
      repositoryTools = builtins.storePath repositoryTools;
    }
  );
  baseOfflineLock = pkgs.callPackage ./offline-lock.nix {
    composerLock = locked.lockedPackages;
    inherit (cache) entries fetch;
    rewritePaths = false;
    provided = locked.provided or [ ];
  };
  providedRequest = builtins.toJSON {
    roots = locked.providedRoots or { };
    repositories = map (input: {
      repository = toString input.repository;
      catalog = input.repository.catalog;
      producer = toString input.producer;
    }) selected;
  };
in
{
  inherit cache;
  nativeTools = pkgs.linkFarm "composer-project-native-tools" {
    inherit php composer;
  };
  inherit composer;
  offlineLock =
    if selected == [ ] then
      baseOfflineLock
    else
      pkgs.runCommand "composer-native-lock"
        {
          inherit providedRequest;
          passAsFile = [ "providedRequest" ];
          manifest = builtins.toFile "composer.json" (builtins.readFile (dir + "/composer.json"));
        }
        ''
          export HOME="$TMPDIR/home"
          export COMPOSER_HOME="$TMPDIR/composer-home"
          cp --no-preserve=mode "$manifest" composer.json
          cp --no-preserve=mode ${baseOfflineLock} composer.lock
          ${pkgs.lib.getExe pkgs.python3} ${
            if repositoryTools == null then ../../tools else builtins.storePath repositoryTools
          }/composer_inputs.py \
            . "$providedRequestPath" ${pkgs.lib.getExe' php "php"} ${pkgs.php.packages.composer}/share/php/composer/vendor/autoload.php
          cp composer.lock "$out"
        '';
  release =
    (build (
      projectSdk
      // {
        src = dir;
        lockFile = lockPath;
        composerLock = composerLockPath;
      }
    )).release;
  repository =
    (build (
      projectSdk
      // {
        src = dir;
        lockFile = lockPath;
        composerLock = composerLockPath;
      }
    )).projections.composer;
}
