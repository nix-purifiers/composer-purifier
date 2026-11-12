# The PHP a Composer project builds with: `php` with every extension that
# composer.json or a locked package requires (`ext-<name>` in `require`).
#
# An extension that `php` does not load is added from `php.extensions`
# when nixpkgs has it. A requirement nixpkgs has no extension for stays
# out, and `composer install` then reports it as an unmet platform
# requirement.
{
  lib,
  php,
  # composer.json, as an attribute set.
  composerJson,
  # composer.lock, as an attribute set.
  composerLock,
  # Whether the build installs the require-dev packages.
  dev,
  extraRequirements ? [ ],
}:
let
  rootRequires =
    (composerJson.require or { }) // lib.optionalAttrs dev (composerJson.require-dev or { });
  packages = (composerLock.packages or [ ]) ++ lib.optionals dev (composerLock.packages-dev or [ ]);
  requires =
    builtins.attrNames rootRequires
    ++ lib.concatMap (p: builtins.attrNames (p.require or { })) packages
    ++ extraRequirements;

  # `ext-pdo_mysql` is the extension `pdo_mysql`. Composer names
  # extensions with lower case and either separator; nixpkgs names them
  # with "_".
  extensionNames = lib.unique (
    map (r: builtins.replaceStrings [ "-" ] [ "_" ] (lib.toLower (lib.removePrefix "ext-" r))) (
      builtins.filter (lib.hasPrefix "ext-") requires
    )
  );

  # Composer calls the opcode cache `zend-opcache`; nixpkgs calls it
  # `opcache`.
  nixpkgsName = name: if name == "zend_opcache" then "opcache" else name;
in
php.withExtensions (
  { enabled, all }:
  let
    enabledNames = map (e: e.extensionName) enabled;
    missing = builtins.filter (name: !(builtins.elem name enabledNames) && all ? ${name}) (
      map nixpkgsName extensionNames
    );
  in
  enabled ++ map (name: all.${name}) missing
)
