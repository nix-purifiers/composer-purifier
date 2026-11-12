# The Nix package name of a Composer project: the `name` of composer.json
# with "/" made "-", or the name of the project directory, made a valid
# store name. Store path names allow [A-Za-z0-9+._?=-], must not start with
# a dot, and are at most 211 characters; every other character becomes "_".
{ composerJson, src }:
let
  name = builtins.replaceStrings [ "/" ] [ "-" ] (composerJson.name or (baseNameOf (toString src)));
  # builtins.split alternates the text between matches with a list per
  # match.
  replaced = builtins.concatStringsSep "" (
    map (part: if builtins.isList part then "_" else part) (builtins.split "[^A-Za-z0-9+._?=-]" name)
  );
  undotted = builtins.head (builtins.match "\\.*(.*)" replaced);
in
builtins.substring 0 200 (if undotted == "" then "project" else undotted)
