# SPDX-License-Identifier: MIT
#
# The commands of the purifier contract, for the Composer project in the
# current directory:
#
#   composer-purifier lock [--force] [--no-audit]
#       runs `composer audit --locked`, then writes
#       composer-purifier.lock.json next to composer.lock (src/lock.php)
#   composer-purifier prefetch
#       builds, with nix-build (nix/lib/cli.nix), the Composer cache of the
#       lockfile, Composer on the PHP the project requires with its
#       require-dev packages, and the composer.lock of an offline install;
#       keeps them alive with GC roots under .composer-purifier
#   composer-purifier publish <directory>
#       builds the release of the project, its dist archive, in the Nix
#       sandbox and copies it into the directory, such as the directory of
#       a Composer `artifact` repository
#
# and `composer`, the build tool of the everyday loop. After a prefetch,
# `composer install` reads the prefetched files and runs offline; every
# other subcommand, and `install` before a prefetch, is plain Composer.
#
# `prefetch` links the cache, Composer and the composer.lock of
# COMPOSER_PURIFIER_CACHE, COMPOSER_PURIFIER_COMPOSER and
# COMPOSER_PURIFIER_OFFLINE_LOCK instead when all three are set, and then
# runs no nix-build. `lock` hashes version-control checkouts with the
# command that COMPOSER_PURIFIER_HASH_CHECKOUT names, by default
# composer-purifier-hash-checkout (nix/lib/hash-checkout.nix).
{
  lib,
  path,
  stdenv,
  coreutils,
  symlinkJoin,
  writeShellApplication,
  php,
  python3,
  projectPhp ? null,
  projectComposer ? null,
  # The source directory of the purifier library, whose fetches the
  # nix-build calls of the commands import. The default package overlay
  # gives it from the `purifier` input of this flake.
  purifierSource ? throw "composer-purifier: the composer-purifier package needs the source of the purifier library as purifierSource.",
}:
let
  defaultComposer = php.packages.composer;
  nativeComposer =
    if projectComposer != null then
      projectComposer
    else if projectPhp != null then
      projectPhp.packages.composer
    else
      defaultComposer;
  sdkExpression =
    sdk: mainProgram:
    if sdk == null then
      ""
    else
      "(${(import ../../nix/lib/sdk-expression.nix sdk).expression} // { version = ${builtins.toJSON sdk.version}; meta.mainProgram = ${builtins.toJSON mainProgram}; ${
        lib.optionalString (
          sdk ? src
        ) "src = ${(import ../../nix/lib/sdk-expression.nix sdk.src).expression};"
      } })";
  targetPhpExpression = sdkExpression projectPhp "php";
  targetComposerExpression = sdkExpression (
    if projectComposer != null || projectPhp != null then nativeComposer else null
  ) "composer";
  # src/lock.php and src/check.php require src/functions.php beside them.
  scripts = ../../src;
  nixLib = ../../nix/lib;

  nixArguments = ''
    --argstr nixpkgs ${path} \
    --argstr purifier ${purifierSource} \
    --argstr system ${stdenv.hostPlatform.system}'';
  cliArguments =
    nixArguments
    + " --argstr repositoryTools ${../../tools}"
    + " --argstr targetPhpExpression ${lib.escapeShellArg targetPhpExpression}"
    + " --argstr targetComposerExpression ${lib.escapeShellArg targetComposerExpression}";

  hashCheckout = writeShellApplication {
    name = "composer-purifier-hash-checkout";
    text = ''
      # composer-purifier-hash-checkout <kind> <checkout as JSON>: prints
      # the hash of the checkout that the purifier library fetches.
      kind="$1"
      checkout="$2"
      if output="$(nix-build ${nixLib}/hash-checkout.nix ${nixArguments} \
          --argstr kind "$kind" \
          --argstr checkout "$checkout" \
          --no-out-link 2>&1)"; then
        echo "composer-purifier-hash-checkout: the $kind fetch accepted a fake hash" >&2
        exit 1
      fi
      hash="$(printf '%s\n' "$output" | sed -n 's/^[[:space:]]*got:[[:space:]]*\(sha256-[A-Za-z0-9+/=]*\).*$/\1/p')"
      if [ -z "$hash" ]; then
        printf '%s\n' "$output" >&2
        exit 1
      fi
      printf '%s\n' "$hash" | head -n 1
    '';
  };

  # The contentHash of the lockfile at "$lockFile".
  lockHash = ''php ${scripts}/lock-hash.php "$lockFile"'';

  compositionEnvironment = ''
    export PYTHONPATH="${purifierSource}/tools"
    export COMPOSER_PURIFIER_PHP=${lib.getExe php}
    export COMPOSER_PURIFIER_AUTOLOAD=${defaultComposer}/share/php/composer/vendor/autoload.php
    export COMPOSER_PURIFIER_LEGACY_COMMAND=${lib.getExe legacyCommand}
    export COMPOSER_PURIFIER_NIX_LIB=${nixLib}
    export COMPOSER_PURIFIER_NIXPKGS=${path}
    export COMPOSER_PURIFIER_SHARED=${purifierSource}
    export COMPOSER_PURIFIER_SYSTEM=${stdenv.hostPlatform.system}
    export COMPOSER_PURIFIER_SCRIPTS=${scripts}
    export COMPOSER_PURIFIER_REAL_COMPOSER=${lib.getExe nativeComposer}
    export COMPOSER_PURIFIER_NATIVE_VERSION=${nativeComposer.version}
    export COMPOSER_PURIFIER_TARGET_PHP_EXPRESSION=${lib.escapeShellArg targetPhpExpression}
    export COMPOSER_PURIFIER_TARGET_COMPOSER_EXPRESSION=${lib.escapeShellArg targetComposerExpression}
    export COMPOSER_PURIFIER_LEGACY_COMPOSER=${lib.getExe legacyComposerCommand}
    export COMPOSER_PURIFIER_REPOSITORY_TOOLS=${../../tools}
  '';

  legacyCommand = writeShellApplication {
    name = "composer-purifier-legacy";
    runtimeInputs = [
      php
      defaultComposer
      coreutils
    ];
    text = ''
      usage() {
        echo "usage: composer-purifier lock [--lockfile <path>] [--tool-lockfile <path>] [--force] [--no-audit]" >&2
        echo "       composer-purifier update [--lockfile <path>] [--tool-lockfile <path>] [--no-audit] [<package>...]" >&2
        echo "       composer-purifier prefetch [--lockfile <path>] [--tool-lockfile <path>]" >&2
        echo "       composer-purifier publish [--lockfile <path>] [--tool-lockfile <path>] <directory>" >&2
        exit 2
      }

      [ $# -gt 0 ] || usage
      command="$1"
      shift

      # --lockfile, or COMPOSER_PURIFIER_LOCKFILE, names a
      # composer-purifier.lock.json outside the project, for a project whose
      # source does not hold it.
      lockFile="''${COMPOSER_PURIFIER_LOCKFILE:-composer-purifier.lock.json}"
      # --tool-lockfile, or COMPOSER_PURIFIER_TOOL_LOCKFILE, names the
      # composer.lock to use in place of the one in the project.
      toolLockFile="''${COMPOSER_PURIFIER_TOOL_LOCKFILE:-}"
      audit=1
      force=0
      operands=()
      while [ $# -gt 0 ]; do
        case "$1" in
          --lockfile)
            [ $# -ge 2 ] || usage
            lockFile="$2"
            shift 2
            ;;
          --tool-lockfile)
            [ $# -ge 2 ] || usage
            toolLockFile="$2"
            shift 2
            ;;
          --no-audit) audit=0; shift ;;
          --force) force=1; shift ;;
          *) operands+=("$1"); shift ;;
        esac
      done
      lockFile="$(realpath -m "$lockFile")"
      toolArguments=()
      if [ -n "$toolLockFile" ]; then
        toolLockFile="$(realpath -m "$toolLockFile")"
        toolArguments=(--argstr toolLockFile "$toolLockFile")
      fi
      # The GC roots of `prefetch` lie beside the lockfile.
      roots="$(dirname "$lockFile")/.composer-purifier"

      # With a tool lockfile, Composer runs on copies of composer.json and
      # composer.lock in a temporary directory, so that the composer.lock
      # of the project stays as it is. The copy of composer.lock starts from
      # the tool lockfile, or from the one in the project when the tool
      # lockfile does not exist yet.
      toolWorkdir() {
        workdir="$(mktemp -d)"
        cp composer.json "$workdir/composer.json"
        if [ -e "$toolLockFile" ]; then
          cp "$toolLockFile" "$workdir/composer.lock"
        elif [ -e composer.lock ]; then
          cp composer.lock "$workdir/composer.lock"
        fi
      }

      # Writes the lockfile from composer.lock as it is (src/lock.php).
      lock() {
        lockArguments=(--lockfile "$lockFile")
        if [ "$force" = 1 ]; then
          lockArguments+=(--force)
        fi
        (
          if [ -n "$toolLockFile" ]; then
            toolWorkdir
            export COMPOSER="$workdir/composer.json"
          fi
          # The install-time policy of Composer is off in the offline
          # installs, so the advisory and malware check runs here, online.
          if [ "$audit" = 1 ]; then
            ${
              if lib.versionAtLeast nativeComposer.version "2.4" then
                ''
                  ${lib.getExe nativeComposer} audit --locked
                ''
              else
                ''
                  echo "composer-purifier: selected Composer has no audit command; no audit was performed" >&2
                ''
            }
          fi
          COMPOSER_PURIFIER_HASH_CHECKOUT="''${COMPOSER_PURIFIER_HASH_CHECKOUT:-${lib.getExe hashCheckout}}" \
            php ${scripts}/lock.php ${defaultComposer}/share/php/composer/vendor/autoload.php "''${lockArguments[@]}"
        )
      }

      case "$command" in
        lock)
          [ ''${#operands[@]} -eq 0 ] || usage
          lock
          ;;
        update)
          # Composer resolves on the PHP that the project requires, so that
          # its platform requirements hold; the purifier lockfile plays no
          # part in that PHP.
          if [ -n "''${COMPOSER_PURIFIER_COMPOSER:-}" ]; then
            projectComposer="$COMPOSER_PURIFIER_COMPOSER"
          else
            projectComposer="$(nix-build ${nixLib}/cli.nix ${cliArguments} \
              --attr composer \
              --argstr projectDir "$PWD" \
              --argstr lockFile "$lockFile" \
              "''${toolArguments[@]}" \
              --no-out-link)"
          fi
          if [ -n "$toolLockFile" ]; then
            toolWorkdir
            COMPOSER="$workdir/composer.json" "$projectComposer/bin/composer" update ${lib.optionalString (lib.versionAtLeast nativeComposer.version "2") "--no-install"} --no-interaction ${lib.optionalString (lib.versionAtLeast nativeComposer.version "2.4") "--no-audit"} "''${operands[@]}"
            mkdir -p "$(dirname "$toolLockFile")"
            cp --no-preserve=mode "$workdir/composer.lock" "$toolLockFile"
          else
            "$projectComposer/bin/composer" update ${lib.optionalString (lib.versionAtLeast nativeComposer.version "2") "--no-install"} --no-interaction ${lib.optionalString (lib.versionAtLeast nativeComposer.version "2.4") "--no-audit"} "''${operands[@]}"
          fi
          lock
          ;;
        prefetch)
          [ ''${#operands[@]} -eq 0 ] || usage
          # Stops with the command to run when the lockfile is missing,
          # malformed, stale or edited (src/check.php).
          php ${scripts}/check.php "$lockFile" "$toolLockFile"
          mkdir -p "$roots"
          if [ -n "''${COMPOSER_PURIFIER_CACHE:-}" ] && [ -n "''${COMPOSER_PURIFIER_COMPOSER:-}" ] && [ -n "''${COMPOSER_PURIFIER_OFFLINE_LOCK:-}" ]; then
            ln -sfn "$COMPOSER_PURIFIER_CACHE" "$roots/cache"
            ln -sfn "$COMPOSER_PURIFIER_COMPOSER" "$roots/composer"
            ln -sfn "$COMPOSER_PURIFIER_OFFLINE_LOCK" "$roots/offlineLock"
          else
            for attribute in cache composer offlineLock; do
              nix-build ${nixLib}/cli.nix ${cliArguments} \
                --attr "$attribute" \
                --argstr projectDir "$PWD" \
                --argstr lockFile "$lockFile" \
                "''${toolArguments[@]}" \
                --out-link "$roots/$attribute" >/dev/null
            done
          fi
          # The offline `composer install` checks that the lockfile has not
          # changed since this prefetch.
          ${lockHash} > "$roots/lock-hash"
          echo "composer-purifier: prefetched the downloads of $lockFile into $roots; \`composer install\` now runs offline." >&2
          ;;
        publish)
          [ ''${#operands[@]} -eq 1 ] || usage
          release="$(nix-build ${nixLib}/cli.nix ${cliArguments} \
            --attr release \
            --argstr projectDir "$PWD" \
            --argstr lockFile "$lockFile" \
            "''${toolArguments[@]}" \
            --no-out-link)"
          target="''${operands[0]}/$(basename "$release" | cut -d- -f2-)"
          cp --no-preserve=mode "$release" "$target"
          echo "$target"
          ;;
        *)
          usage
          ;;
      esac
    '';
  };

  purifierCommand = writeShellApplication {
    name = "composer-purifier";
    runtimeInputs = [
      python3
      php
      defaultComposer
      coreutils
    ];
    text = ''
      ${compositionEnvironment}
      exec ${lib.getExe python3} ${../../tools}/composer_cli.py "$@"
    '';
  };

  legacyComposerCommand = writeShellApplication {
    name = "composer-purifier-legacy-composer";
    runtimeInputs = [
      php
      coreutils
    ];
    text = ''
      # After `composer-purifier prefetch`, `composer install` runs offline
      # from the prefetched files, with Composer on the PHP the project
      # requires. Every other subcommand, and `install` before a prefetch,
      # is plain Composer.
      # The lockfile is the one of COMPOSER_PURIFIER_LOCKFILE, or the one in
      # the current directory, and the prefetched files lie beside it.
      lockFile="$(realpath -m "''${COMPOSER_PURIFIER_LOCKFILE:-composer-purifier.lock.json}")"
      roots="$(dirname "$lockFile")/.composer-purifier"
      projectComposer=${nativeComposer}
      if [ -e "$roots/composer" ]; then
        projectComposer="$(readlink -f "$roots/composer")"
      fi
      if [ "''${1:-}" != install ] || [ ! -e "$roots/cache" ]; then
        exec "$projectComposer/bin/composer" "$@"
      fi

      if ! php ${scripts}/check.php "$lockFile" "''${COMPOSER_PURIFIER_TOOL_LOCKFILE:-}"; then
        echo "composer-purifier: then run \`composer-purifier prefetch\`, and \`composer install\` again." >&2
        exit 1
      fi
      if [ "$(${lockHash})" != "$(cat "$roots/lock-hash")" ]; then
        echo "composer-purifier: $lockFile changed after the last prefetch. Run \`composer-purifier prefetch\`." >&2
        exit 1
      fi
      cache="$(readlink -f "$roots/cache")"
      ${lib.optionalString (lib.versionOlder nativeComposer.version "2") ''
        pinnedCache="$cache"
        cache="$(mktemp -d)"
        trap 'rm -rf "$cache"' EXIT
        cp -rL "$pinnedCache/." "$cache/"
        chmod -R u+w "$cache"
      ''}
      # Composer reads composer.json and the offline composer.lock from the
      # prefetched files, and the project paths stay relative to the
      # current directory, since COMPOSER comes from the environment.
      cp composer.json "$roots/composer.json"
      cp --no-preserve=mode "$roots/offlineLock" "$roots/composer.lock"
      export COMPOSER="$roots/composer.json"
      export COMPOSER_CACHE_DIR="$cache"
      export COMPOSER_CACHE_FILES_DIR="$cache/files"
      export COMPOSER_CACHE_READ_ONLY=1
      export COMPOSER_DISABLE_NETWORK=1
      # The install-time policy fetches malware and advisory lists, which
      # an offline install cannot reach; `lock` runs the audit instead.
      export COMPOSER_POLICY=0
      ${
        if lib.versionOlder nativeComposer.version "2" then "" else "exec "
      }"$projectComposer/bin/composer" "$@"
    '';
  };
  composerCommand = writeShellApplication {
    name = "composer";
    runtimeInputs = [
      python3
      php
      defaultComposer
      coreutils
    ];
    text = ''
      ${compositionEnvironment}
      exec ${lib.getExe python3} ${../../tools}/composer_runtime.py "$@"
    '';
  };
in
symlinkJoin {
  name = "composer-purifier";
  paths = [
    purifierCommand
    composerCommand
    hashCheckout
  ];
  meta = {
    description = "Locks the downloads of a Composer project, prefetches them, and installs it offline from them";
    license = lib.licenses.mit;
    mainProgram = "composer-purifier";
  };
}
