# SPDX-License-Identifier: MIT
#
# The checks of composer-purifier. Each builds in the Nix sandbox. Only
# the fixed-output fetches of the fixtures' lockfiles reach the network.
#
# The checks of the purifier contract (CONTRACT.md of
# github:nix-purifiers/purifier):
#
#   conformance-stale      a lockfile older than the composer.lock of
#                          tests/fixtures/stale, where monolog moved to
#                          another dist, fails evaluation and
#                          `composer-purifier prefetch`, and a composer.lock
#                          that changes after a prefetch stops the offline
#                          `composer install`; each names
#                          `composer-purifier lock`
#   conformance-tampered   a lockfile with an edited hash fails evaluation
#                          and `prefetch`, naming `composer-purifier lock
#                          --force`; the fetch of the entry checks the
#                          edited hash, and the CI workflow builds it
#                          (tests/tampered-hash.nix) to see Nix reject it
#   conformance-missing    a lockfile without the hash of a dist that
#                          composer.lock needs fails evaluation and
#                          `prefetch`, naming `composer-purifier lock`
#   conformance-malformed  lockfiles that are not valid fail evaluation and
#                          `prefetch`, naming `composer-purifier lock --force`
#   conformance-relock     relocking tests/fixtures/app, from the hashes it
#                          has, and tests/fixtures/vcs, with a stand-in for
#                          the checkout hash (tests/fake-hash-checkout.sh),
#                          reproduces each lockfile byte for byte
#   conformance-rebuild    two independent builds of tests/fixtures/app give
#                          the same package and the same release
#   conformance-offline    after `composer-purifier prefetch`, the everyday
#                          loop of tests/fixtures/app (`composer install`,
#                          the bin, `composer test`) and of
#                          tests/fixtures/sources runs with no network
#   conformance-update     `composer-purifier update` on a project pinned at
#                          old versions moves the named package, then every
#                          package, and both lockfiles pass the stale check
#                          after each run
#   conformance-external   tests/fixtures/app builds from a source that
#                          holds only its composer.lock, with the
#                          purifier lockfile given from tests/external/app,
#                          and from a source that holds neither lockfile,
#                          with both given from there; a composer.lock
#                          given from outside replaces the one in the
#                          source
#
# The checks of composer-purifier itself:
#
#   fixture-app            the package of tests/fixtures/app runs its
#                          `hello` bin, which needs ext-bz2 (an extension
#                          the default nixpkgs PHP does not load) and
#                          monolog; its post-install-cmd script ran
#   fixture-sources        tests/fixtures/sources, whose packages come from
#                          a git source, a tar archive at a URL, a path
#                          repository inside the project and one outside
#                          it, builds and runs its `check` bin
#   fixture-vcs            tests/fixtures/vcs, whose packages come from
#                          git, hg, svn and fossil sources, builds with
#                          stand-ins for the fetchers that check the
#                          arguments the purifier library gives them
#   real-world-composer    composer/composer 2.10.3, a real project pinned
#                          in tests/dependencies, builds from the lockfile
#                          of tests/projects/composer and runs
#   tests                  the `tests` of tests/fixtures/app run its `test`
#                          script in the sandbox
#   unit                   the unit tests of src/functions.php
#                          (tests/unit/functions.php)
#   lock-reuse             a composer.lock with the same packages keeps the
#                          lockfile byte for byte, and its relock downloads
#                          nothing
#   urls                   the URLs and cache paths that Composer computes
#                          (tests/unit/urls.php) are the ones that
#                          nix/lib/entries.nix derives, for the fixtures
#                          with dists and for composer/composer
#   read-lock              `lib.composer-purifier.readLock` gives the lock in
#                          memory of the contract, with its problems for a
#                          stale composer.lock
#   outputs                `packages`, `release`, `fetches` and `tests` of
#                          the fixtures are known at evaluation time and
#                          name the right outputs
#   release                the release of tests/fixtures/app is a zip of
#                          the project without its vendor directory
#   mirrors                the entry of a package with a mirror and a
#                          shasum has the URL, then the mirror with its
#                          placeholders filled in, and the SHA-1 of the
#                          shasum; its fetch tries both, with nixpkgs'
#                          fetchurl and with a `fetchurl` in its place
{
  pkgs,
  overlay,
  # lib.composer-purifier.readLock of this flake.
  readLock,
  # The `purifier` library namespace (lib.purifier of
  # github:nix-purifiers/purifier).
  purifier,
  # The source of composer/composer at its 2.10.3 release, an input of
  # tests/dependencies.
  composerSource,
  historicalPhpSource,
}:
let
  purified = pkgs.extend overlay;
  inherit (purified) lib runCommand unzip;
  command = purified.composer-purifier.composer-purifier;

  # Every fixture builds the way a consumer's package does: through
  # composer-purifier.buildComposerProject of a package set the overlay
  # applies to.
  inherit (purified.composer-purifier) buildComposerProject;
  build = buildComposerProject;

  app = build { src = ./fixtures/app; };
  appPackage = app.packages.composer-purifier-fixture-app;

  # Composer itself, with the lockfile of tests/projects/composer.
  realComposer = build {
    src = composerSource;
    lockFile = ./projects/composer/composer-purifier.lock.json;
  };

  sources = build {
    src = ./fixtures/sources;
    pathRepositories."../outer-package" = ./fixtures/outer-package;
  };

  # The stand-in checkout of a version-control package: a source tree
  # with the class that tests/fixtures/vcs/bin/check calls.
  standInCheckout =
    kind:
    let
      namespace = lib.toUpper (builtins.substring 0 1 kind) + builtins.substring 1 (-1) kind;
    in
    runCommand "fixture-${kind}-checkout" { } ''
      mkdir -p $out/src
      cat > $out/src/Hello.php <<'EOF'
      <?php
      namespace Fixture\${namespace};
      final class Hello
      {
          public static function text(): string
          {
              return 'hello from the ${kind} checkout';
          }
      }
      EOF
    '';

  # Stand-ins for the nixpkgs fetchers. Each checks the arguments that
  # the purifier library gives it for the entry of tests/fixtures/vcs.
  standInFetchers = {
    fetchgit =
      args:
      assert args.url == "https://example.invalid/fixture/git.git";
      assert args.rev == "0123456789abcdef0123456789abcdef01234567";
      assert args.fetchSubmodules == false;
      assert args.leaveDotGit == false;
      standInCheckout "git";
    fetchhg =
      args:
      assert args.url == "https://example.invalid/fixture/hg";
      assert args.rev == "89abcdef0123456789abcdef0123456789abcdef";
      assert args.fetchSubrepos;
      standInCheckout "hg";
    fetchsvn =
      args:
      assert args.url == "https://example.invalid/fixture/svn/trunk";
      assert args.rev == "7";
      assert args.ignoreExternals == false;
      assert args.ignoreKeywords == false;
      standInCheckout "svn";
    fetchfossil =
      args:
      assert args.url == "https://example.invalid/fixture/fossil";
      assert args.rev == "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210";
      assert lib.hasPrefix "sha256-" args.hash;
      standInCheckout "fossil";
  };

  vcs = build {
    src = ./fixtures/vcs;
    fetchers = standInFetchers;
  };

  # The app fixture from a source that holds neither of its lockfiles.
  external = build {
    src = builtins.path {
      path = ./fixtures/app;
      name = "fixture-app-without-lockfiles";
      filter =
        path: type:
        !(builtins.elem (baseNameOf path) [
          "composer-purifier.lock.json"
          "composer.lock"
        ]);
    };
    lockFile = ./external/app/composer-purifier.lock.json;
    composerLock = ./external/app/composer.lock;
  };

  # The app fixture from a source that holds its composer.lock and not the
  # purifier lockfile, which a flake keeps outside it.
  externalLockfile = build {
    src = builtins.path {
      path = ./fixtures/app;
      name = "fixture-app-without-purifier-lockfile";
      filter = path: type: baseNameOf path != "composer-purifier.lock.json";
    };
    lockFile = ./external/app/composer-purifier.lock.json;
  };

  # Whether the app fixture evaluates with a lockfile, and with a
  # composer.lock.
  acceptedWith =
    arguments:
    (builtins.tryEval
      (build ({ src = ./fixtures/app; } // arguments)).packages.composer-purifier-fixture-app.drvPath
    ).success;
  accepted = lockFile: acceptedWith { inherit lockFile; };

  # The monolog entry of the app fixture, and the same entry with the hash
  # of tests/fixtures/edited/tampered-hash.json, whose content hash
  # rejects it before any fetch.
  monologEntry = app.cache.entries.byName."monolog/monolog";
  tamperedHash =
    (builtins.fromJSON (builtins.readFile ./fixtures/edited/tampered-hash.json))
    .dists.${monologDistUrl};
  monologDistUrl =
    (builtins.head (
      builtins.filter (p: p.name == "monolog/monolog")
        (builtins.fromJSON (builtins.readFile ./fixtures/app/composer.lock)).packages
    )).dist.url;
  originalFetch = purifier.fetchEntry { pkgs = purified; } monologEntry;
  tamperedFetch = purifier.fetchEntry { pkgs = purified; } (monologEntry // { hash = tamperedHash; });

  # What `composer-purifier prefetch` links for a fixture, in place of the
  # nix-build it runs outside the sandbox.
  prefetched = package: src: {
    COMPOSER_PURIFIER_CACHE = package.cache;
    COMPOSER_PURIFIER_COMPOSER = package.php.packages.composer;
    COMPOSER_PURIFIER_OFFLINE_LOCK = purified.callPackage ../nix/lib/offline-lock.nix {
      composerLock = builtins.fromJSON (builtins.readFile (src + "/composer.lock"));
      inherit (package.cache) entries fetch;
      rewritePaths = false;
    };
  };

  # A package of composer.lock with a mirror and a shasum: its entry has
  # the URL, then the mirror with its placeholders filled in, and the
  # SHA-1 of the shasum. The lockfile holds no hash for it.
  mirrored =
    (import ../nix/lib/entries.nix {
      inherit lib;
      composerJson = { };
      lock = {
        dists = { };
        sources = { };
        file = "composer-purifier.lock.json";
      };
      composerLock.packages = [
        {
          name = "fixture/mirrored";
          version = "1.0.0";
          version_normalized = "1.0.0.0";
          dist = {
            type = "zip";
            url = "https://example.invalid/dists/fixture-mirrored.zip";
            reference = "0123456789abcdef0123456789abcdef01234567";
            shasum = "da39a3ee5e6b4b0d3255bfef95601890afd80709";
            mirrors = [
              {
                url = "https://mirror.example.invalid/%package%/%version%/%reference%.%type%";
                preferred = false;
              }
            ];
          };
        }
      ];
    }).byName."fixture/mirrored";
  mirroredUrls = [
    "https://example.invalid/dists/fixture-mirrored.zip"
    "https://mirror.example.invalid/fixture/mirrored/1.0.0.0/0123456789abcdef0123456789abcdef01234567.zip"
  ];
  nixpkgsFetch = purifier.fetchEntry { pkgs = purified; } mirrored;
  overriddenFetch = purifier.fetchEntry {
    pkgs = purified;
    fetchurl = args: args;
  } mirrored;

  # The URLs and cache path of each dist, as nix/lib/entries.nix derives
  # them, in the canonical JSON of tests/unit/urls.php.
  derivedUrls =
    package:
    purified.writeText "derived-urls.json" (
      builtins.toJSON (
        lib.mapAttrs (name: entry: {
          inherit (entry) path;
          urls = [ entry.url ] ++ entry.mirrors;
        }) (lib.filterAttrs (name: entry: entry ? url) package.cache.entries.byName)
      )
    );

  commandEnvironment = ''
    export HOME="$TMPDIR/home"
    export COMPOSER_HOME="$TMPDIR/composer-home"
    export COMPOSER_DISABLE_NETWORK=1
  '';

  # Copies tests/fixtures/app to ./project and changes into it.
  appProject = ''
    cp -r ${./fixtures/app} project
    chmod -R u+w project
    cd project
  '';

  # Runs `composer-purifier prefetch` on the project in the current
  # directory with the lockfile $1, and checks that it fails with a message
  # that contains $2.
  prefetchFails = ''
    prefetchFails() {
      if composer-purifier prefetch --lockfile "$1" 2> error; then
        echo "prefetch accepted $1" >&2
        exit 1
      fi
      cat error
      grep -qF "$2" error
    }
  '';
in
({
  composition-native-resolver =
    runCommand "composer-native-resolver-tests"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.php
          pkgs.php.packages.composer
        ];
        COMPOSER_REPOSITORY_TOOLS = ../tools;
        COMPOSER_REPOSITORY_SCRIPTS = ../src;
      }
      ''
        python3 ${./test_composer_repository.py} ${lib.getExe pkgs.php.packages.composer} \
          ${lib.getExe pkgs.php} ${pkgs.php.packages.composer}/share/php/composer/vendor/autoload.php
        touch "$out"
      '';
  composition-native-export = import ./composition-export.nix {
    inherit pkgs;
    project = purified.composer-purifier.buildComposerProject { src = ./fixtures/app; };
    alternate = purified.composer-purifier.buildComposerProject {
      src = ./fixtures/app;
      php = pkgs.php.withExtensions (
        { enabled, all }:
        enabled
        ++ [
          all.bz2
          all.ffi
        ]
      );
    };
  };
  composition-metapackage = import ./composition-export.nix {
    inherit pkgs;
    project = purified.composer-purifier.buildComposerProject { src = ./fixtures/composition-meta; };
  };
  # tests/fixtures/stale/composer.lock is the composer.lock of the app
  # fixture after an update that its lockfile has not seen.
  conformance-stale =
    assert !(acceptedWith { composerLock = ./fixtures/stale/composer.lock; });
    runCommand "conformance-stale-check"
      ({ nativeBuildInputs = [ command ]; } // prefetched app ./fixtures/app)
      ''
        ${commandEnvironment}
        ${appProject}
        ${prefetchFails}
        cp ${./fixtures/stale/composer.lock} composer.lock
        prefetchFails composer-purifier.lock.json 'has no hash for the dist of monolog/monolog'
        grep -qF 'Run `composer-purifier lock`.' error
        # Automatic prefetch must reject a changed native lock before install
        # and name the command that refreshes its captured hashes.
        cp ${./fixtures/app/composer.lock} composer.lock
        composer-purifier prefetch
        cp ${./fixtures/stale/composer.lock} composer.lock
        if composer install 2> error; then
          echo "composer install ran on a stale lockfile" >&2
          exit 1
        fi
        cat error
        grep -qF 'Run `composer-purifier lock`.' error
        touch $out
      '';

  conformance-tampered =
    assert !(accepted ./fixtures/edited/tampered-hash.json);
    assert tamperedFetch.outputHash == tamperedHash;
    assert tamperedFetch.outputHash != originalFetch.outputHash;
    runCommand "conformance-tampered-check" { nativeBuildInputs = [ command ]; } ''
      ${commandEnvironment}
      ${appProject}
      ${prefetchFails}
      prefetchFails ${./fixtures/edited/tampered-hash.json} 'was edited after `composer-purifier lock` wrote it'
      grep -qF 'Run `composer-purifier lock --force`' error
      touch $out
    '';

  conformance-missing =
    assert !(accepted ./fixtures/edited/missing-dist.json);
    runCommand "conformance-missing-check" { nativeBuildInputs = [ command ]; } ''
      ${commandEnvironment}
      ${appProject}
      ${prefetchFails}
      prefetchFails ${./fixtures/edited/missing-dist.json} 'has no hash for the dist of psr/log'
      grep -qF 'Run `composer-purifier lock`.' error
      touch $out
    '';

  conformance-malformed =
    assert
      !(builtins.any accepted [
        ./fixtures/malformed/version-3.json
        ./fixtures/malformed/no-dists.json
        ./fixtures/malformed/dist-hash-not-text.json
      ]);
    runCommand "conformance-malformed-check" { nativeBuildInputs = [ command ]; } ''
      ${commandEnvironment}
      ${appProject}
      ${prefetchFails}
      prefetchFails ${./fixtures/malformed/version-3.json} 'has lock format version 3'
      prefetchFails ${./fixtures/malformed/no-dists.json} 'has no valid `dists` field'
      prefetchFails ${./fixtures/malformed/dist-hash-not-text.json} 'has no valid `dists` field'
      printf '{"version": 4,' > broken.json
      prefetchFails broken.json 'is not valid JSON'
      grep -qF 'Run `composer-purifier lock --force`' error
      touch $out
    '';

  conformance-relock =
    runCommand "conformance-relock-check"
      {
        nativeBuildInputs = [
          command
          purified.jq
        ];
      }
      ''
        ${commandEnvironment}
        ${appProject}
        # A lockfile whose content hash is gone is written again; its hashes
        # come from the old one, without downloads.
        jq '.contentHash = ""' composer-purifier.lock.json > old.json
        mv old.json composer-purifier.lock.json
        composer-purifier lock --no-audit
        cmp ${./fixtures/app/composer-purifier.lock.json} composer-purifier.lock.json
        cd ..

        cp -r ${./fixtures/vcs} vcs
        chmod -R u+w vcs
        cd vcs
        rm composer-purifier.lock.json
        cp ${./fake-hash-checkout.sh} "$TMPDIR/fake-hash-checkout"
        chmod +x "$TMPDIR/fake-hash-checkout"
        patchShebangs "$TMPDIR/fake-hash-checkout"
        COMPOSER_PURIFIER_HASH_CHECKOUT="$TMPDIR/fake-hash-checkout" composer-purifier lock --no-audit
        cmp ${./fixtures/vcs/composer-purifier.lock.json} composer-purifier.lock.json
        touch $out
      '';

  conformance-rebuild =
    let
      # The same build as a second derivation, so that Nix builds it again
      # rather than reusing the first output.
      again =
        drv:
        drv.overrideAttrs (old: {
          composerPurifierRebuild = "again";
        });
    in
    # The wrappers in bin/ hold the store path of their own package, which
    # differs between the two builds, so each tree is compared with its own
    # store path replaced by the same placeholder. On darwin a wrapper is a
    # Mach-O binary whose UUID and code signature are hashes of its
    # content, its store path included, so there each wrapper is compared
    # by the makeCWrapper command it was made with, which it embeds. The
    # CI workflow also runs `nix build --rebuild` of the package, which
    # compares one derivation built twice.
    runCommand "conformance-rebuild-check" { } ''
      normalize() {
        local tree="$1" copy="$2"
        cp -r "$tree" "$copy"
        chmod -R u+w "$copy"
        ${lib.optionalString purified.stdenv.hostPlatform.isDarwin ''
          for wrapper in "$copy"/bin/*; do
            ${purified.makeBinaryWrapper.extractCmd} "$tree/bin/''${wrapper##*/}" > "$wrapper"
            test -s "$wrapper"
          done
        ''}
        find "$copy" -type f -exec sed -i "s|$tree|/nix/store/rebuilt|g" {} +
      }
      normalize ${appPackage} first
      normalize ${again appPackage} second
      diff -r first second
      cmp ${app.release} ${again app.release}
      touch $out
    '';

  conformance-offline =
    runCommand "conformance-offline-check"
      (
        {
          nativeBuildInputs = [
            command
            app.php
          ];
        }
        // prefetched app ./fixtures/app
      )
      ''
        ${commandEnvironment}
        ${appProject}
        composer-purifier prefetch
        composer install --no-interaction --no-progress
        test -f vendor/monolog/monolog/composer.json
        test "$(cat installed-by-script)" = yes
        test "$(php bin/hello)" = "hello from composer-purifier"
        composer test
        touch $out
      '';

  conformance-offline-sources =
    runCommand "conformance-offline-sources-check"
      (
        {
          nativeBuildInputs = [
            command
            sources.php
          ];
        }
        // prefetched sources ./fixtures/sources
      )
      ''
        ${commandEnvironment}
        mkdir work
        cp -r ${./fixtures/sources} work/sources
        cp -r ${./fixtures/outer-package} work/outer-package
        chmod -R u+w work
        cd work/sources
        composer-purifier prefetch
        composer install --no-interaction --no-progress
        php bin/check > output
        grep -q "outside the project" output
        test -f vendor/fixture/psr-clock/src/ClockInterface.php
        test -f vendor/fixture/psr-container/src/ContainerInterface.php
        touch $out
      '';

  # A project that requires fixture/greeting and fixture/farewell at ^1.0
  # from a package repository in composer.json, which offers 1.0.0 and
  # 1.1.0 of each as local zips without a shasum. Both start pinned at
  # 1.0.0. `update fixture/greeting` moves only greeting, and `update`
  # moves farewell too; each time both lockfiles pass the stale check.
  conformance-update =
    runCommand "conformance-update-check"
      {
        nativeBuildInputs = [
          command
          app.php
          purified.zip
          purified.jq
        ];
        COMPOSER_PURIFIER_COMPOSER = app.php.packages.composer;
        COMPOSER_PURIFIER_CACHE = app.cache;
        COMPOSER_PURIFIER_OFFLINE_LOCK = app.php;
      }
      ''
        ${commandEnvironment}
        # The dists are local files, which Composer refuses to read while
        # the network is disabled; the sandbox has no network either way.
        unset COMPOSER_DISABLE_NETWORK
        mkdir -p project/dists
        cd project
        packages='[]'
        for name in greeting farewell; do
          for version in 1.0.0 1.1.0; do
            mkdir -p "src/$name-$version"
            echo "{\"name\": \"fixture/$name\", \"version\": \"$version\"}" > "src/$name-$version/composer.json"
            (cd "src/$name-$version" && zip -qX "$PWD/../../dists/$name-$version.zip" composer.json)
            packages="$(jq -c --arg name "$name" --arg version "$version" --arg url "file://$PWD/dists/$name-$version.zip" \
              '. + [{name: ("fixture/" + $name), version: $version, dist: {type: "zip", url: $url}}]' <<< "$packages")"
          done
        done
        jq -n --argjson packages "$packages" '{
          name: "fixture/update",
          require: {"fixture/greeting": "^1.0", "fixture/farewell": "^1.0"},
          repositories: [{type: "package", package: $packages}, {"packagist.org": false}]
        }' > composer.json

        version() {
          jq -r --arg name "fixture/$1" '.packages[] | select(.name == $name) | .version' composer.lock
        }
        # The stale check of `composer-purifier prefetch`, with the store
        # paths of the environment in place of its builds.
        stale() {
          composer-purifier prefetch
        }

        composer update --no-install --prefer-lowest --no-interaction
        composer-purifier lock --no-audit
        stale
        test "$(version greeting)" = 1.0.0
        test "$(version farewell)" = 1.0.0

        # With a tool lockfile outside the tree, `update` writes the moved
        # composer.lock there, starting from the tree's copy, and leaves
        # the tree's copy as it is. `prefetch` accepts the pair, and a
        # relock of the tree restores the lockfile for the next steps.
        cp composer.lock tree-composer.lock
        composer-purifier update --no-audit --tool-lockfile "$PWD/outside/composer.lock" fixture/greeting
        cmp composer.lock tree-composer.lock
        test "$(jq -r '.packages[] | select(.name == "fixture/greeting") | .version' outside/composer.lock)" = 1.1.0
        test "$(jq -r '.packages[] | select(.name == "fixture/farewell") | .version' outside/composer.lock)" = 1.0.0
        composer-purifier prefetch --tool-lockfile "$PWD/outside/composer.lock"
        composer-purifier lock --force --no-audit

        composer-purifier update --no-audit fixture/greeting
        stale
        test "$(version greeting)" = 1.1.0
        test "$(version farewell)" = 1.0.0

        composer-purifier update --no-audit
        stale
        test "$(version greeting)" = 1.1.0
        test "$(version farewell)" = 1.1.0
        test "$(jq '.dists | length' composer-purifier.lock.json)" = 2
        touch $out
      '';

  # The tool lockfile replaces the one in `src`: the stale composer.lock
  # that the source's own copy would pass is rejected when given from
  # outside, and the matching copy from outside builds.
  conformance-external =
    assert !(acceptedWith { composerLock = ./fixtures/stale/composer.lock; });
    assert acceptedWith { composerLock = ./external/app/composer.lock; };
    runCommand "conformance-external-check" { } ''
      test "$(${lib.getExe external.packages.composer-purifier-fixture-app})" = "hello from composer-purifier"
      test "$(${lib.getExe externalLockfile.packages.composer-purifier-fixture-app})" = "hello from composer-purifier"
      touch $out
    '';

  fixture-app = runCommand "fixture-app-check" { } ''
    output="$(${lib.getExe appPackage})"
    if [ "$output" != "hello from composer-purifier" ]; then
      echo "hello printed: $output" >&2
      exit 1
    fi
    test "$(cat ${appPackage}/share/php/composer-purifier-fixture-app/installed-by-script)" = yes
    test -f ${appPackage}/share/php/composer-purifier-fixture-app/vendor/monolog/monolog/composer.json
    touch $out
  '';

  fixture-sources = runCommand "fixture-sources-check" { } ''
    ${lib.getExe sources.packages.composer-purifier-fixture-sources} > output
    printf '%s\n' \
      "hello from the path package inside the project" \
      "hello from the path package outside the project" > expected
    diff expected output
    touch $out
  '';

  fixture-vcs = runCommand "fixture-vcs-check" { } ''
    ${lib.getExe vcs.packages.composer-purifier-fixture-vcs} > output
    printf '%s\n' \
      "hello from the git checkout" \
      "hello from the hg checkout" \
      "hello from the svn checkout" \
      "hello from the fossil checkout" > expected
    diff expected output
    touch $out
  '';

  # The integration check on a real project: Composer 2.10.3 builds from
  # its own composer.lock, its `composer` bin runs, and it validates its own
  # composer.json offline.
  real-world-composer =
    assert
      builtins.attrNames realComposer.packages == [
        "composer"
        "composer-composer"
      ];
    runCommand "real-world-composer-check" { } ''
      export HOME="$TMPDIR/home"
      export COMPOSER_HOME="$TMPDIR/composer-home"
      export COMPOSER_DISABLE_NETWORK=1
      ${lib.getExe realComposer.packages.composer} --version | grep -q 'Composer version 2.10.3'
      cd ${realComposer.packages.composer-composer}/share/php/composer-composer
      ${lib.getExe realComposer.packages.composer} validate --no-check-publish --no-check-lock
      touch $out
    '';

  inherit (app) tests;

  unit =
    runCommand "unit-check"
      {
        nativeBuildInputs = [ app.php ];
      }
      ''
        php ${./unit/functions.php} \
          ${app.php.packages.composer}/share/php/composer/vendor/autoload.php \
          ${../src/functions.php} \
          ${./fixtures}
        touch $out
      '';

  lock-reuse = runCommand "lock-reuse-check" { nativeBuildInputs = [ command ]; } ''
    ${commandEnvironment}
    ${appProject}
    echo >> composer.lock
    composer-purifier lock --no-audit 2> output
    cat output
    grep -qF 'is up to date with composer.lock' output
    cmp ${./fixtures/app/composer-purifier.lock.json} composer-purifier.lock.json
    touch $out
  '';

  urls =
    runCommand "urls-check"
      {
        nativeBuildInputs = [ app.php ];
      }
      ''
        ${commandEnvironment}
        compare() {
          cp -r "$1" project
          chmod -R u+w project
          (cd project && php ${./unit/urls.php} \
            ${app.php.packages.composer}/share/php/composer/vendor/autoload.php \
            ${../src/functions.php} > ../computed.json)
          rm -rf project
          diff "$2" computed.json
        }
        compare ${./fixtures/app} ${derivedUrls app}
        compare ${./fixtures/sources} ${derivedUrls sources}
        compare ${composerSource} ${derivedUrls realComposer}
        touch $out
      '';

  outputs =
    assert
      builtins.attrNames app.packages == [
        "composer-purifier-fixture-app"
        "hello"
      ];
    assert
      builtins.attrNames sources.packages == [
        "check"
        "composer-purifier-fixture-sources"
      ];
    assert app.fetches == app.cache.entries.entries;
    assert
      map (entry: entry.path) app.fetches == [
        "files/monolog/monolog/13f7456348238a63d970854498776d96f53cdee8.zip"
        "files/psr/log/2961e31604f4f4de116b458f772c4aa21861c5b4.zip"
      ];
    assert app.release.name == "composer-purifier-fixture-app-0.zip";
    # tests/fixtures/sources has no `test` script.
    assert !(builtins.tryEval sources.tests).success;
    runCommand "outputs-check" { } ''
      test "$(${lib.getExe app.packages.hello})" = "hello from composer-purifier"
      touch $out
    '';

  read-lock =
    let
      lock = readLock { src = ./fixtures/app; };
      stale = readLock {
        src = ./fixtures/app;
        composerLock = ./fixtures/stale/composer.lock;
      };
    in
    assert lock.purifier == "composer-purifier";
    assert lock.problems == [ ];
    assert lock.entries == app.fetches;
    assert
      builtins.attrNames lock.outputs == [
        "composer-purifier-fixture-app"
        "hello"
      ];
    assert builtins.length stale.problems == 1;
    assert lib.hasInfix "has no hash for the dist of monolog/monolog" (builtins.head stale.problems);
    assert lib.hasInfix "Run `composer-purifier lock`." (builtins.head stale.problems);
    runCommand "read-lock-check" { } "touch $out";

  release = runCommand "release-check" { nativeBuildInputs = [ unzip ]; } ''
    unzip -l ${app.release} > listing
    grep -q ' composer.json$' listing
    grep -q ' src/Greeting.php$' listing
    ! grep -q ' vendor/' listing
    touch $out
  '';

  mirrors =
    assert [ mirrored.url ] ++ mirrored.mirrors == mirroredUrls;
    # The SHA-1 of the empty string, from the shasum of composer.lock.
    assert mirrored.hash == "sha1-2jmj7l5rSw0yVb/vlWAYkK/YBwk=";
    assert nixpkgsFetch.urls == mirroredUrls;
    assert overriddenFetch.urls == mirroredUrls;
    runCommand "mirrors-check" { } "touch $out";
})
// lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") (
  import ./historical-toolchains.nix {
    inherit
      pkgs
      historicalPhpSource
      command
      buildComposerProject
      ;
  }
)
