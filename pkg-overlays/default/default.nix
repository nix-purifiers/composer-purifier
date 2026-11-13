# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds one attribute to the package set:
# the scope `pkgs.composer-purifier`, made with lib.makeScope. The scope
# holds the packages of pkgs/ and the builder:
#
#   composer-purifier.composer-purifier        the command, with `lock`,
#                                              `update`, `prefetch` and
#                                              `publish`, and the
#                                              `composer` that runs a
#                                              prefetched install offline
#   composer-purifier.buildComposerProject     the builder
#                                              (pkgs/build-composer-project/default.nix),
#                                              a package for callPackage in
#                                              the scope
#
# A package written for callPackage takes the scope by name, as
# `{ composer-purifier }:`. `composer-purifier.overrideScope` replaces what
# everything in the scope shares, and `buildComposerProject.override`
# replaces what the builder takes.
#
# The builder and the command take the purifier library
# (github:nix-purifiers/purifier) of this flake's pin: the builder as the
# library itself, the command as the source its nix-build calls import.
{ closure-lib, closure-inputs, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "composer-purifier";
in
{
  overlay =
    final: prev:
    let
      added = packages final prev;
    in
    {
      composer-purifier = added.composer-purifier.overrideScope (
        self: super: {
          composer-purifier = super.composer-purifier.override {
            purifierSource = closure-inputs.purifier;
          };
          buildComposerProject = self.callPackage ../../pkgs/build-composer-project/default.nix {
            purifier = import closure-inputs.purifier { inherit (final) lib; };
          };
          # Paths may be unbuilt derivation outputs: metadata is read at build time.
          projectComposerRepository =
            args:
            let
              projectPhp = args.php or final.php;
            in
            self.callPackage ../../pkgs/build-composer-project/composer-projections.nix (
              {
                purifier = import closure-inputs.purifier { inherit (final) lib; };
                php = projectPhp;
                composer = projectPhp.packages.composer;
                dependencies = [ ];
                platformRequirements = [ ];
              }
              // args
            );
        }
      );
    };
}
