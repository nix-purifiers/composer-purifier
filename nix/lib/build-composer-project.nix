# buildComposerProject: the sandboxed builds of a Composer project, from the
# lockfile that `composer-purifier lock` writes next to composer.lock.
#
# The file is a package for callPackage: the first argument set is what it
# takes from the package set, and the result is the builder. The
# composer-purifier overlay (`overlays.default`) adds it to the scope
# `composer-purifier` of the package set, so a package written for
# callPackage takes the scope by name:
#
#   { composer-purifier }:
#   (composer-purifier.buildComposerProject { src = ./.; }).packages.my-vendor-my-app
#
# `composer-purifier.buildComposerProject.override` replaces what the
# builder takes, and `composer-purifier.overrideScope` replaces what
# everything in the scope shares.
#
# `fetchers` goes unchanged to fetchEntry and tree of the purifier library,
# so a company mirror or credentials go into `fetchers.fetchurl`, and a
# private git repository into `fetchers.fetchgit`.
#
# Each build runs `composer install` in the Nix sandbox, offline, with the
# Composer cache of the lockfile (cache.nix) and the composer.lock of
# offline-lock.nix. The result names every output from composer.json, which
# Nix reads as JSON, without building anything:
#
#   packages.<name>  the project with its `vendor` directory under
#                    share/php/<name>, where <name> is the `name` of
#                    composer.json with "/" made "-"; it has a wrapper in
#                    bin/ for each entry of the `bin` list of composer.json
#   packages.<bin>   one package per entry of `bin`, holding only that
#                    executable
#   tests            the `test` script of composer.json, run in the sandbox
#                    on the project with its require-dev packages
#   release          the dist archive that `composer archive` makes,
#                    <name>-<version>.zip, which `composer-purifier publish`
#                    copies into an artifact repository
#   fetches          the entries of the lock in memory (read-lock.nix): the
#                    downloads of the purifier library that the builds
#                    fetch, derived from composer.lock and the hashes of
#                    the lockfile
#   cache            the Composer cache of the lockfile (cache.nix)
#   php              the PHP of the packages, with the extensions the
#                    project requires (php.nix)
{
  lib,
  stdenvNoCC,
  runCommand,
  makeBinaryWrapper,
  callPackage,
  python3,
  php,
  repositoryTools ? ../../tools,
  # The `purifier` library namespace (lib.purifier of
  # github:nix-purifiers/purifier). The overlay passes the one of this
  # flake's pin.
  purifier,
}:
let
  helperPhp = php;
in
{
  # The root of the Composer project: the directory of composer.json.
  src,
  dependencies ? purifier.lockedProjectInputs {
    inputs = (builtins.fromJSON (builtins.readFile lockFile)).projectInputs or [ ];
    system = stdenvNoCC.hostPlatform.system;
  },
  # Replaces fetchers of the purifier library, by name (fetchurl, fetchgit,
  # fetchhg, fetchsvn, fetchfossil). Each takes the arguments of the
  # nixpkgs fetcher of its name.
  fetchers ? { },
  # The lockfile; the default is the one `composer-purifier lock` writes
  # next to composer.lock. A lockfile outside `src` lets a packaging flake
  # build a project whose source holds none, and replaces any copy in it.
  lockFile ? src + "/composer-purifier.lock.json",
  # composer.lock, for a project whose source holds none. A composer.lock
  # given outside `src` replaces the copy in it.
  composerLock ? src + "/composer.lock",
  # The PHP the project builds and runs with. The default is the package
  # set's `php` with the extensions the project requires (php.nix).
  php ? null,
  # Native Composer is selected independently of the project PHP package.
  composer ? null,
  # Metadata tooling may need newer PHP/Composer APIs than the project.
  capturePhp ? null,
  captureComposer ? helperPhp.packages.composer,
  # Installs the require-dev packages into `packages` too. `tests` always
  # has them.
  dev ? false,
  # Skips the scripts of composer.json (`--no-scripts`).
  noScripts ? false,
  # Further arguments of `composer install`.
  composerFlags ? [ ],
  # The Nix path of each `path` repository outside the project directory,
  # by the URL that composer.json gives it: { "../lib" = ../lib; }.
  pathRepositories ? { },
  # Filters the project root before it is copied into the store, as the
  # `filter` of builtins.path. The default leaves out `vendor`, `.git` and
  # `.composer-purifier`.
  srcFilter ? null,
}:
let
  # The lock in memory (read-lock.nix), which checkLock of the purifier
  # library fails on when it has problems.
  locked = purifier.checkLock (
    import ./read-lock.nix { inherit lib; } { inherit src lockFile composerLock; }
  );
  inherit (locked) composerJson lockedPackages;

  entries = {
    entries = purifier.entriesFor stdenvNoCC.hostPlatform.system locked;
    inherit (locked) byName;
  };
  cache = callPackage ./cache.nix { inherit entries fetchers purifier; };

  phpOf =
    withDev:
    if php != null then
      php
    else
      callPackage ./php.nix {
        inherit composerJson;
        composerLock = lockedPackages;
        dev = withDev;
        extraRequirements = lib.concatMap (input: input.repository.platformRequirements or [ ]) selected;
      };
  composerOf = projectPhp: if composer == null then projectPhp.packages.composer else composer;
  captureRuntime =
    if capturePhp != null then
      capturePhp
    else
      callPackage ./php.nix {
        php = helperPhp;
        inherit composerJson;
        composerLock = lockedPackages;
        dev = true;
        extraRequirements = lib.concatMap (input: input.repository.platformRequirements or [ ]) selected;
      };

  offlineLock = callPackage ./offline-lock.nix {
    inherit pathRepositories entries;
    composerLock = lockedPackages;
    inherit (cache) fetch;
    rewritePaths = true;
    provided = locked.provided or [ ];
  };

  selected = purifier.projectInputs {
    inherit dependencies;
    formats = [ "composer" ];
  };
  platformRequirements = lib.unique (
    builtins.filter (name: name == "php" || lib.hasPrefix "ext-" name || lib.hasPrefix "composer-" name)
      (
        builtins.attrNames (composerJson.require or { })
        ++ builtins.attrNames (composerJson.require-dev or { })
        ++ lib.concatMap (package: builtins.attrNames (package.require or { })) (
          (lockedPackages.packages or [ ]) ++ (lockedPackages.packages-dev or [ ])
        )
      )
    ++ lib.concatMap (input: input.repository.platformRequirements or [ ]) selected
  );
  providedRequest = builtins.toJSON {
    roots = locked.providedRoots or { };
    repositories = map (input: {
      repository = toString input.repository;
      catalog = input.repository.catalog;
      producer = toString input.producer;
    }) selected;
  };

  # The environment of every Composer run in the sandbox. Composer reads
  # the locked dists from the read-only cache, and the disabled network
  # makes any other download fail the build rather than reach out.
  #
  # COMPOSER_POLICY=0 turns off the install-time policy of Composer 2.10,
  # which fetches malware and advisory lists from the package repositories.
  # Those lists change over time, so an offline build cannot use them.
  # `composer-purifier lock` runs `composer audit` online instead.
  composerEnvironment = ''
    export HOME="$TMPDIR/home"
    export COMPOSER_HOME="$TMPDIR/composer-home"
    export COMPOSER_CACHE_DIR=${cache}
    ${lib.optionalString (composer != null && lib.versionOlder composer.version "2") ''
      # Composer 1 disables a cache that is not writable. Give it a private
      # copy of the pinned bytes; the Nix store cache stays immutable.
      export COMPOSER_CACHE_DIR="$TMPDIR/composer-writable-cache"
      mkdir -p "$COMPOSER_CACHE_DIR"
      cp -rL ${cache}/. "$COMPOSER_CACHE_DIR/"
      chmod -R u+w "$COMPOSER_CACHE_DIR"
    ''}
    export COMPOSER_CACHE_FILES_DIR="$COMPOSER_CACHE_DIR/files"
    export COMPOSER_CACHE_READ_ONLY=1
    export COMPOSER_DISABLE_NETWORK=1
    export COMPOSER_POLICY=0
    export COMPOSER_HTACCESS_PROTECT=0
  '';

  # `vendor/name` becomes the package name `vendor-name`.
  pname = import ./package-name.nix { inherit composerJson src; };
  version = composerJson.version or "0";

  defaultSrcFilter =
    path: type:
    let
      name = baseNameOf path;
    in
    !((type == "directory" && name == "vendor") || name == ".git" || name == ".composer-purifier");

  source = builtins.path {
    path = src;
    name = "${pname}-source";
    filter = if srcFilter != null then srcFilter else defaultSrcFilter;
  };

  # composer.json gives `bin` as one path or as a list of paths.
  bins = lib.toList (composerJson.bin or [ ]);
  binName = bin: baseNameOf bin;

  # The project installed with `composer install`, with the require-dev
  # packages when `withDev` is set.
  project =
    withDev:
    let
      projectPhp = phpOf withDev;
      installFlags = [
        "--no-interaction"
        "--no-progress"
        "--optimize-autoloader"
      ]
      ++ lib.optional (!withDev) "--no-dev"
      ++ lib.optional noScripts "--no-scripts"
      ++ composerFlags;
    in
    stdenvNoCC.mkDerivation {
      pname = if withDev then "${pname}-dev" else pname;
      inherit version;
      src = source;

      strictDeps = true;
      inherit providedRequest;
      passAsFile = [ "providedRequest" ];
      nativeBuildInputs = [
        projectPhp
        (composerOf projectPhp)
        makeBinaryWrapper
      ];

      dontConfigure = true;

      buildPhase = ''
        runHook preBuild
        ${composerEnvironment}
        cp --no-preserve=mode ${offlineLock} composer.lock
        ${lib.optionalString (dependencies != [ ]) ''
          ${lib.getExe python3} ${repositoryTools}/composer_inputs.py . "$providedRequestPath" \
            ${lib.getExe' captureRuntime "php"} ${captureComposer}/share/php/composer/vendor/autoload.php
        ''}
        composer install ${lib.escapeShellArgs installFlags}
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        dir="$out/share/php/${pname}"
        mkdir -p "$dir"
        cp -r . "$dir"
        ${lib.concatMapStrings (bin: ''
          makeWrapper ${lib.getExe' projectPhp "php"} "$out/bin/${binName bin}" \
            --add-flags "$dir/${bin}"
        '') bins}
        runHook postInstall
      '';

      passthru = {
        php = projectPhp;
        inherit projections;
      };

      meta = lib.optionalAttrs (bins != [ ]) { mainProgram = binName (builtins.head bins); };
    };

  installed = project dev;
  withDevPackages = project true;

  projections.composer = import ./composer-projections.nix {
    inherit
      lib
      purifier
      runCommand
      python3
      composerLock
      dependencies
      repositoryTools
      platformRequirements
      ;
    src = source;
    composer = composerOf (phpOf true);
    php = phpOf true;
    capturePhp = captureRuntime;
    inherit captureComposer;
    installed = "${withDevPackages}/share/php/${pname}";
    origins = lib.listToAttrs (
      map (
        package:
        lib.nameValuePair package.name (
          if (package.type or "") == "metapackage" then
            builtins.hashString "sha256" (builtins.toJSON package)
          else if entries.byName ? ${package.name} then
            (purifier.inputIdentity (cache.fetch entries.byName.${package.name})).hash
          else
            "${(purifier.inputIdentity source).hash}:${package.name}"
        )
      ) ((lockedPackages.packages or [ ]) ++ (lockedPackages.packages-dev or [ ]))
    );
  };

  binPackages = lib.listToAttrs (
    map (
      bin:
      lib.nameValuePair (binName bin) (
        runCommand "${pname}-${binName bin}" { meta.mainProgram = binName bin; } ''
          mkdir -p $out/bin
          ln -s ${installed}/bin/${binName bin} $out/bin/${binName bin}
        ''
      )
    ) bins
  );

  # `composer archive` packs the root package from the project source,
  # leaving out what composer.json's `archive.exclude` and the export-ignore
  # attributes of .gitattributes name.
  release =
    let
      archivePhp = phpOf false;
    in
    stdenvNoCC.mkDerivation {
      name = "${pname}-${version}.zip";
      passthru = { inherit projections; };
      src = source;
      strictDeps = true;
      nativeBuildInputs = [
        archivePhp
        (composerOf archivePhp)
      ];
      dontConfigure = true;
      dontFixup = true;
      buildPhase = ''
        runHook preBuild
        ${composerEnvironment}
        composer archive --no-interaction --format=zip --dir="$TMPDIR/archive" --file=${pname}-${version}
        mv "$TMPDIR/archive/${pname}-${version}.zip" $out
        runHook postBuild
      '';
      dontInstall = true;
    };

  tests =
    if (composerJson.scripts or { }) ? test then
      runCommand "${pname}-tests"
        {
          nativeBuildInputs = [
            withDevPackages.php
            (composerOf withDevPackages.php)
          ];
        }
        ''
          ${composerEnvironment}
          cp -r ${withDevPackages}/share/php/${pname} project
          chmod -R u+w project
          cd project
          composer run-script --no-interaction test
          touch $out
        ''
    else
      throw "composer-purifier: the composer.json of ${toString src} has no `test` script, which `tests` runs. Add one to its `scripts`, such as \"test\": \"phpunit\".";
in
assert
  !(binPackages ? ${pname})
  || throw "composer-purifier: the bin ${pname} of ${toString src} has the name of the project, so `packages` cannot hold both.";
{
  packages = {
    ${pname} = installed;
  }
  // binPackages;
  inherit
    tests
    release
    cache
    projections
    ;
  fetches = locked.entries;
  php = installed.php;
}
