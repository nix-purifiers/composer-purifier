# SPDX-License-Identifier: MIT
#
# The `composer-purifier` library namespace. It holds the lock reader of the
# purifier contract (github:nix-purifiers/purifier, CONTRACT.md):
#
#   lib.composer-purifier.readLock { src, lockFile ? ..., composerLock ? ... }
#
# lib-overlays/default/read-lock.nix documents its arguments and result. The builder
# needs a package set, so it is the package `buildComposerProject` that the
# default package overlay adds (pkg-overlays/default).
{ ... }:
{

  overlay = final: prev: {
    composer-purifier = {
      readLock = import ./read-lock.nix { lib = final; };
    };
  };

}
