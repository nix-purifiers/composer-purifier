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
  inputs.older-php = {
    url = "github:NixOS/nixpkgs/f22817d8d2bc17d2bcdb8ac4308a4bce6f5d1d2b";
    flake = false;
  };
  inputs.php54-sdk = {
    url = "github:NixOS/nixpkgs/770822493e3962d795739fafd522e771bfe06e3d";
    flake = false;
  };
  inputs.php53-sdk = {
    url = "github:NixOS/nixpkgs/081d5aaabaf2dc52bb77407648514af2bebe0e1c";
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
