# SPDX-License-Identifier: MIT
#
# The package of tests/fixtures/app, for the conformance-rebuild job of the
# CI workflow, which builds it and then runs
#
#   nix build --file tests/app-package.nix --rebuild
#
# to build the same derivation again and compare the two outputs.
let
  flake = builtins.getFlake (toString ../.);
  pkgs = flake.inputs.nixpkgs.legacyPackages.${builtins.currentSystem}.extend flake.overlays.default;
in
(pkgs.composer-purifier.buildComposerProject {
  src = ./fixtures/app;
}).packages.composer-purifier-fixture-app
