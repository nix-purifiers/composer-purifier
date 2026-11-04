# SPDX-License-Identifier: MIT
{ closure-lib, ... }:
{
  config,
  inputs,
  lib,
  ...
}:
{

  imports = [
    inputs.flake-parts.flakeModules.partitions
    closure-lib.caisson.modules.flake."purifier/purifier-packages"
  ];

  debug = false;
  caisson = {
    libOverlays.exported = libOverlays: {
      inherit (libOverlays) default;
    };
  };

  # The scope `composer-purifier` is the `default` entry of the package
  # overlay registry of this flake (pkg-overlays/): the package set applies
  # it by default, and the flake exports it as `pkgOverlays` and as the
  # plain `overlays.default`. The module purifier-packages of the purifier
  # library publishes the derivations of the scope as the packages output.
  purifier.scope = "composer-purifier";

  #
  # `nix run github:nix-purifiers/composer-purifier -- lock` writes
  # composer-purifier.lock.json for the Composer project in the current
  # directory. `nix develop` gives PHP, the composer-purifier command, its
  # `composer`, which installs offline after `composer-purifier prefetch`,
  # and phpactor, a PHP language server.
  perSystem =
    { config, pkgs, ... }:
    {
      packages.default = config.packages.composer-purifier;
      # The interactive toolchain is a package so nix shell can expose it
      # without entering the derivation's build environment.
      packages.toolchain = pkgs.buildEnv {
        name = "composer-purifier-toolchain";
        paths = [
          config.packages.composer-purifier
          pkgs.php
          pkgs.phpactor
        ];
      };
      devShells.default = pkgs.mkShell {
        packages = [
          config.packages.composer-purifier
          pkgs.php
          pkgs.phpactor
        ];
      };
    };

  partitionedAttrs.checks = "checks";
  partitionedAttrs.formatter = "formatter";

  partitions.formatter = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem.treefmt.programs.nixfmt.enable = true;
      };
  };

  partitions.checks = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, self, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem =
          { pkgs, system, ... }:
          {
            checks = import ../../../tests {
              inherit pkgs;
              overlay = self.overlays.default;
              inherit (self.lib.composer-purifier) readLock;
              inherit (inputs.purifier.lib) purifier;
              composerSource = inputs.composer-src;
              historicalPhpSource = inputs.historical-php;
            };
            treefmt.programs.nixfmt.enable = true;
          };
      };
  };

}
