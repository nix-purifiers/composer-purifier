# SPDX-License-Identifier: MIT
# Exact historical SDK points, not a minimum supported PHP version.
{
  pkgs,
  historicalPhpSource,
  command,
  buildComposerProject,
  selectedPhp ? null,
  fixture ? ./fixtures/legacy-php,
}:
let
  old = import historicalPhpSource {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.permittedInsecurePackages = [ "php-7.4.29" ];
  };
  php =
    if selectedPhp == null then
      old.php74.withExtensions ({ enabled, all }: enabled ++ [ all.zip ])
    else
      selectedPhp;
  composerOf =
    version: hash:
    let
      phar = pkgs.fetchurl {
        url = "https://getcomposer.org/download/${version}/composer.phar";
        inherit hash;
      };
    in
    (pkgs.writeShellApplication {
      name = "composer";
      runtimeInputs = [
        php
        pkgs.unzip
        pkgs.git
      ];
      text = ''exec ${php}/bin/php ${phar} "$@"'';
    }).overrideAttrs
      (_: {
        inherit version;
        src = phar;
      });
  composer1 = composerOf "1.10.27" "sha256-Iw0o+ynzxsB6sjgjkL7zE+Nt4Xhosr0jsuBwVUyuI9I=";
  composer22 = composerOf "2.2.26" "sha256-L4ibHRlmavYIFEilJlOfc7HZXRD3RVNq/YEyrLE3Q/M=";
  projectOf =
    composer:
    buildComposerProject {
      src = fixture;
      inherit php composer;
    };
  check =
    composer:
    let
      project = projectOf composer;
    in
    pkgs.runCommand "composer-${composer.version}-php-${php.version}"
      {
        nativeBuildInputs = [
          project.packages.proof-legacy-php
          pkgs.unzip
        ];
        passthru = { inherit project php composer; };
      }
      ''
        test "$(legacy-php)" = "42 on ${php.version}"
        test "$(cat ${project.packages.proof-legacy-php}/share/php/proof-legacy-php/built.txt)" = "${php.version}"
        test -e ${project.tests}
        unzip -p ${project.release} composer.json > manifest.json
        test -s manifest.json
        test -e ${project.projections.composer.catalog}
        touch "$out"
      '';
  toolsOf =
    composer:
    pkgs.symlinkJoin {
      name = "composer-${composer.version}-php${php.version}-native-tools";
      paths = [
        (command.override {
          projectPhp = php;
          projectComposer = composer;
        })
        php
      ];
    };
in
{
  legacy-php-composer1 = check composer1;
  legacy-php-composer22 = check composer22;
  legacy-php-composer1-tools = toolsOf composer1;
  legacy-php-composer22-tools = toolsOf composer22;
}
