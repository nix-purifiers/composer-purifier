# The entries of the purifier library that `composer install` needs for the
# packages of composer.lock, derived at evaluation time from composer.lock
# and from the hashes that composer.lock lacks (lock.nix).
#
# For a package with a dist, the entry is a file at its path in Composer's
# cache. Its URLs are what Composer's Package::getDistUrls gives (the dist
# URL and the mirrors of its repository, with their placeholders filled in
# as ComposerMirror::processUrl fills them), each with the reference
# rewrite of Url::updateDistReference. Its path is
# files/<package>/<sha1 of the first URL>.<dist type>, sanitized as
# Composer's Cache::copyTo sanitizes it. Its hash is the `shasum` of
# composer.lock when that is set, and the hash of the lockfile otherwise.
#
# For a package that composer.lock gives only a version-control source,
# the entry is a checkout at <kind>/<package>, with what Composer's
# downloader of that kind installs: git without submodules, since
# GitDownloader never runs `git submodule`; hg with subrepositories, since
# HgDownloader runs `hg update`, which checks them out; svn with externals
# and expanded keywords, as the plain `svn co` of SvnDownloader makes them.
# An SSH git URL becomes the HTTPS URL of the same repository, since the
# Nix sandbox has no SSH keys.
#
# src/functions.php computes the same URLs and paths for
# `composer-purifier lock`, and the `urls` check compares the two.
{
  lib,
  # composer.lock, as an attribute set.
  composerLock,
  # composer.json, as an attribute set; its `config` names the GitHub and
  # GitLab domains of the reference rewrite.
  composerJson,
  # The lock of lock.nix.
  lock,
}:
let
  vcsKinds = [
    "git"
    "hg"
    "svn"
    "fossil"
  ];

  # The dist types whose downloader keeps the downloaded file in Composer's
  # files cache (the downloaders that extend FileDownloader).
  cachedDistTypes = [
    "zip"
    "tar"
    "gzip"
    "xz"
    "rar"
    "phar"
    "file"
  ];

  config = composerJson.config or { };
  githubDomains = config.github-domains or [ "github.com" ];
  gitlabDomains = config.gitlab-domains or [ "gitlab.com" ];

  md5 = builtins.hashString "md5";

  hostOf =
    url:
    let
      match = builtins.match "[a-zA-Z][a-zA-Z0-9+.-]*://([^/?#]+).*" url;
    in
    if match == null then null else lib.last (lib.splitString "@" (builtins.head match));

  # Url::updateDistReference: the reference goes into the archive URLs of
  # GitHub, Bitbucket and GitLab.
  updateDistReference =
    reference: url:
    let
      host = hostOf url;
      try = pattern: builtins.match pattern url;
      githubLegacy = try "https?://(www\\.)?github\\.com/([^/]+)/([^/]+)/(zip|tar)ball/(.+)";
      githubArchive = try "https?://(www\\.)?github\\.com/([^/]+)/([^/]+)/archive/.+\\.(zip|tar)(\\.gz)?";
      githubApi = try "https?://api\\.github\\.com/repos/([^/]+)/([^/]+)/(zip|tar)ball(/.+)?";
      bitbucket = try "https?://(www\\.)?bitbucket\\.org/([^/]+)/([^/]+)/get/(.+)\\.(zip|tar\\.gz|tar\\.bz2)";
      gitlab = try "https?://(www\\.)?gitlab\\.com/api/v[34]/projects/([^/]+)/repository/archive\\.(zip|tar\\.gz|tar\\.bz2|tar)\\?sha=.+";
      githubDomain = try "(.*/repos/[^/]+/[^/]+/(zip|tar)ball)(/.*)?";
      gitlabDomain = try "(.*/api/v[34]/projects/[^/]+/repository/archive\\.(zip|tar\\.gz|tar\\.bz2|tar)\\?sha=).+";
      at = match: index: builtins.elemAt match index;
    in
    if
      builtins.elem host [
        "api.github.com"
        "github.com"
        "www.github.com"
      ]
    then
      if githubLegacy != null then
        "https://api.github.com/repos/${at githubLegacy 1}/${at githubLegacy 2}/${at githubLegacy 3}ball/${reference}"
      else if githubArchive != null then
        "https://api.github.com/repos/${at githubArchive 1}/${at githubArchive 2}/${at githubArchive 3}ball/${reference}"
      else if githubApi != null then
        "https://api.github.com/repos/${at githubApi 0}/${at githubApi 1}/${at githubApi 2}ball/${reference}"
      else
        url
    else if
      builtins.elem host [
        "bitbucket.org"
        "www.bitbucket.org"
      ]
    then
      if bitbucket != null then
        "https://bitbucket.org/${at bitbucket 1}/${at bitbucket 2}/get/${reference}.${at bitbucket 4}"
      else
        url
    else if
      builtins.elem host [
        "gitlab.com"
        "www.gitlab.com"
      ]
    then
      if gitlab != null then
        "https://gitlab.com/api/v4/projects/${at gitlab 1}/repository/archive.${at gitlab 2}?sha=${reference}"
      else
        url
    else if builtins.elem host githubDomains then
      if githubDomain != null then "${at githubDomain 0}/${reference}" else url
    else if builtins.elem host gitlabDomains then
      if gitlabDomain != null then "${at gitlabDomain 0}${reference}" else url
    else
      url;

  # ComposerMirror::processUrl: the placeholders of a mirror URL.
  processMirrorUrl =
    package: url:
    let
      dist = package.dist;
      reference = dist.reference or null;
      version = package.version_normalized or package.version;
      mirrorReference =
        if reference == null || reference == "" then
          ""
        else if builtins.match "([a-f0-9]*|%reference%)" reference != null then
          reference
        else
          md5 reference;
    in
    builtins.replaceStrings
      [
        "%package%"
        "%version%"
        "%reference%"
        "%type%"
        "%prettyVersion%"
      ]
      [
        package.name
        (if lib.hasInfix "/" version then md5 version else version)
        mirrorReference
        dist.type
        package.version
      ]
      url;

  # Package::getDistUrls, then the reference rewrite of each URL.
  distUrls =
    package:
    let
      dist = package.dist;
      reference = dist.reference or null;
      first = if lib.hasInfix "%" dist.url then processMirrorUrl package dist.url else dist.url;
      withMirrors = builtins.foldl' (
        urls: mirror:
        let
          mirrorUrl = processMirrorUrl package mirror.url;
        in
        if builtins.elem mirrorUrl urls then
          urls
        else if mirror.preferred or false then
          [ mirrorUrl ] ++ urls
        else
          urls ++ [ mirrorUrl ]
      ) [ first ] (dist.mirrors or [ ]);
    in
    if reference == null then withMirrors else map (updateDistReference reference) withMirrors;

  # Cache::copyTo replaces every character outside [a-z0-9_./], ignoring
  # case, with "-".
  sanitize =
    key:
    builtins.concatStringsSep "" (
      map (part: if builtins.isList part then "-" else part) (builtins.split "[^a-zA-Z0-9_./]" key)
    );

  cachePath =
    package: url:
    "files/"
    + sanitize "${lib.toLower package.name}/${builtins.hashString "sha1" url}.${package.dist.type}";

  # The HTTPS URL of a git repository that `url` names over SSH.
  httpsGitUrl =
    url:
    let
      ssh = builtins.match "ssh://([^@/]+@)?([^:/]+)(:[0-9]+)?/(.+)" url;
      scp = builtins.match "[^@/]+@([^:/]+):(.+)" url;
    in
    if ssh != null then
      "https://${builtins.elemAt ssh 1}/${builtins.elemAt ssh 3}"
    else if !(lib.hasInfix "://" url) && scp != null then
      "https://${builtins.elemAt scp 0}/${lib.removePrefix "/" (builtins.elemAt scp 1)}"
    else
      url;

  relock = "Run `composer-purifier lock`.";

  # The checkout of a version-control source, or null for an svn reference
  # with no revision number.
  checkoutOf =
    package:
    let
      source = package.source;
      inherit (source) url reference;
      svn = builtins.match "(.*)@([0-9]+)" reference;
      svnPath = lib.removeSuffix "/" (lib.removePrefix "/" (builtins.elemAt svn 0));
    in
    if source.type == "git" then
      {
        url = httpsGitUrl url;
        rev = reference;
        submodules = false;
        leaveDotGit = false;
        commitObject = null;
      }
    else if source.type == "hg" then
      {
        inherit url;
        rev = reference;
        subrepos = true;
      }
    else if source.type == "svn" then
      if svn == null then
        null
      else
        {
          url = lib.removeSuffix "/" url + lib.optionalString (svnPath != "") "/${svnPath}";
          rev = builtins.elemAt svn 1;
          ignoreExternals = false;
          ignoreKeywords = false;
        }
    else
      {
        inherit url;
        rev = reference;
      };

  entry = value: {
    entry = value;
    problem = null;
  };
  problem = message: {
    entry = null;
    problem = "composer-purifier: ${message}";
  };

  # The entry of a package, or a problem; neither for a package of a path
  # repository.
  entryOf =
    package:
    let
      dist = package.dist or null;
      source = package.source or { };
      sourceKey = "${source.url or ""}#${source.reference or ""}";
      checkout = checkoutOf package;
    in
    if dist != null && dist.type == "path" then
      {
        entry = null;
        problem = null;
      }
    else if dist != null then
      if !(builtins.elem dist.type cachedDistTypes) then
        problem "${package.name} has a dist of type ${dist.type}, which Composer does not keep in its files cache."
      else
        let
          urls = distUrls package;
          shasum = dist.shasum or "";
          locked = lock.dists ? ${dist.url};
        in
        if shasum == "" && !locked then
          problem "${lock.file} has no hash for the dist of ${package.name} at ${dist.url}, which composer.lock has. ${relock}"
        else
          entry {
            path = cachePath package (builtins.head urls);
            url = builtins.head urls;
            mirrors = builtins.tail urls;
            hash =
              if shasum != "" then
                builtins.convertHash {
                  hash = shasum;
                  hashAlgo = "sha1";
                  toHashFormat = "sri";
                }
              else
                lock.dists.${dist.url};
          }
    else if source.type or null == "perforce" then
      problem "${package.name} has only a perforce source. A Perforce depot has no anonymous protocol that a fetcher could use, needs a server and credentials, and nixpkgs has no fetcher for it."
    else if !(builtins.elem (source.type or null) vcsKinds) then
      problem "${package.name} has neither a dist nor a git, hg, svn or fossil source in composer.lock."
    else if checkout == null then
      problem "${package.name} has the svn reference ${source.reference}, which names no revision number."
    else if !(lock.sources ? ${sourceKey}) then
      problem "${lock.file} has no hash for the ${source.type} checkout of ${package.name} at ${sourceKey}, which composer.lock has. ${relock}"
    else
      entry {
        path = "${source.type}/${lib.toLower package.name}";
        ${source.type} = checkout;
        hash = lock.sources.${sourceKey};
      };

  packages = builtins.filter (package: (package.type or "") != "metapackage") (
    (composerLock.packages or [ ]) ++ (composerLock.packages-dev or [ ])
  );

  results = map (package: {
    inherit (package) name;
    value = entryOf package;
  }) packages;

  byName = builtins.listToAttrs (
    map (result: {
      inherit (result) name;
      value = result.value.entry;
    }) (builtins.filter (result: result.value.entry != null) results)
  );
in
{
  # The entries, by package name.
  inherit byName;
  # The entries, sorted by package name.
  entries = builtins.attrValues byName;
  # Why a package has no entry, each naming the command that fixes it.
  problems = builtins.filter (problem: problem != null) (map (result: result.value.problem) results);
}
