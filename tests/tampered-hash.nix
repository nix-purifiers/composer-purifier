# SPDX-License-Identifier: MIT
#
# The fetch of the monolog dist of tests/fixtures/app with the hash that
# tests/fixtures/edited/tampered-hash.json gives it, the one of psr/log.
# Evaluation of that lockfile rejects the edit by its content hash; this
# fetch takes the edited hash without that check, to show that Nix rejects
# the download too: building it fails with "hash mismatch in fixed-output
# derivation". The CI workflow builds it and expects that failure, since a
# check cannot run a build that must fail.
#
#   nix build --file tests/tampered-hash.nix --no-link
let
  flake = builtins.getFlake (toString ../.);
  pkgs = flake.inputs.nixpkgs.legacyPackages.${builtins.currentSystem};
  lock = flake.lib.composer-purifier.readLock { src = ./fixtures/app; };
  monolog = builtins.head (
    builtins.filter (
      entry: entry.path == "files/monolog/monolog/13f7456348238a63d970854498776d96f53cdee8.zip"
    ) lock.entries
  );
  tampered = builtins.fromJSON (builtins.readFile ./fixtures/edited/tampered-hash.json);
in
flake.inputs.purifier.lib.purifier.fetchEntry { inherit pkgs; } (
  monolog // { hash = tampered.dists.${monolog.url}; }
)
