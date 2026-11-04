# SPDX-License-Identifier: MIT
{
  inputs.caisson.url = "github:nix-caisson/caisson";
  inputs.flake-parts.url = "github:hercules-ci/flake-parts";
  # Same channel as the main flake, so dev-partition evals agree with the
  # exported pkgSet.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.treefmt-nix.url = "github:numtide/treefmt-nix";
  inputs.treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  # EOL PHP fixture only; production packages keep the main package set.
  inputs.historical-php = {
    url = "github:NixOS/nixpkgs/eabc38219184cc3e04a974fe31857d8e0eac098d";
    flake = false;
  };
  # The real-world project of the integration check: Composer itself, at
  # the commit of its 2.10.3 release. tests/projects/composer holds its
  # composer-purifier lockfile.
  inputs.composer-src = {
    url = "github:composer/composer/f0de0bf90226853b841672f086d8b58b02332504";
    flake = false;
  };
  outputs = { ... }: { };
}
