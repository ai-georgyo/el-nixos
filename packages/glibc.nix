# glibc-2.39-142.el10_2: the Rocky glibc SRPM rebuilt with `rpmbuild --rebuild`
# in a stage0 buildroot.  See docs/glibc.md.
#
#   build      buildSrpm result ($out/RPMS/{x86_64,noarch}, SRPMS, logs)
#   rpms       <binary rpm name> -> rpmTree (allowedReferences = [ ]) for every
#              subpackage Rocky ships (from rpmsLock.bySrpm.glibc) plus the
#              three the spec builds but Rocky does not ship
#   trees      linkFarm of all of `rpms`: building it is the purity check
#   sanity     post-build checks (report.txt)
#   buildroot  the glibc buildroot (layers)
#
# Everything is static (the subpackage list comes from the lock), no IFD.
{ pkgs
, stage0                   # legacyPackages.stage0 (bootstrap/default.nix)
, rpmsLock                 # parsed lock/rocky-<rel>/rpms.json
, officialRpms             # name -> official RPM FOD (comparison only)
, kernelHeadersRpm ? null  # mkBuildroot rpm spec of Rocky's kernel-headers
                           # (a .rpm path, a buildSrpm result, or { from; names; });
                           # null: stage0's kernel headers (not in the rpmdb)
}:
let
  inherit (pkgs) lib;
  inherit (stage0.lib) mkBuildroot buildSrpm rpmTree runInBuildroot;
  e = stage0.lib.fetch.entry "glibc";

  # ------------------------------------------------------------------ buildroot
  # = stage0-full (same root contents + rocky-release + the macro packages)
  # + the build deps missing from it (bootstrap/glibc-build-deps.nix)
  # + kernel headers: either stage0's (copied into the root) or Rocky's
  #   kernel-headers RPM (installed into the rpmdb, so the spec's
  #   `rpm -ql kernel-headers` fills the sysroot package).
  root = stage0.mkRoot {
    name = "stage0-root-glibc";
    kernelHeaders = if kernelHeadersRpm == null then stage0.kernelHeaders else null;
    extraTrees = [ stage0.glibcBuildDeps ];
  };
  buildroot = mkBuildroot {
    name = "stage0-glibc";
    base = root;
    rpms = stage0.fullRpms ++ lib.optional (kernelHeadersRpm != null) kernelHeadersRpm;
  };

  # ------------------------------------------------------------------ rpmbuild
  build = buildSrpm {
    srpm = "glibc";
    inherit buildroot;
    # %check is hours long and needs gdb/valgrind/static C++/nested namespaces;
    # it does not change the binary RPMs (docs/research/glibc-spec.md §1.1).
    # Every bcond stays at its default (no --with bootstrap / --without werror).
    rpmbuildArgs = [ "--nocheck" ];
    defines = {
      # Annobin is off in stage0 (no plugin for the stage0 gcc yet).  The spec
      # tests `0%{?_annotated_build} > 0` for its own -fplugin=annobin
      # (BuildFlagsNonshared), so the macro must be 0, not just the plugin
      # spec emptied; keeping it *defined* keeps redhat-rpm-config's
      # `--remove-section .gnu.build.attributes` for find-debuginfo, as in
      # Rocky's build.
      _annotated_build = "0";
      _annobin_gcc_plugin = "%{nil}"; # also in /etc/rpm/macros.stage0
    };
    requiredSystemFeatures = [ "big-parallel" ];
  };

  # ------------------------------------------------------------------ subpackages
  shipped = map (k: rpmsLock.rpms.${k}) rpmsLock.bySrpm.glibc;
  # built by the spec, not in BaseOS/AppStream/CRB
  unshipped = [
    { name = "glibc32"; arch = "x86_64"; }
    { name = "sysroot-x86_64-el10-glibc"; arch = "noarch"; }
    { name = "compat-libpthread-nonshared"; arch = "x86_64"; }
  ];
  # NEVRs are the SRPM's (the shipped ones are asserted equal by `sanity`)
  fileOf = p: "RPMS/${p.arch}/${p.name}-${e.version}-${e.release}.${p.arch}.rpm";
  all = shipped ++ unshipped;
  rpms = lib.listToAttrs (map (p: lib.nameValuePair p.name (rpmTree { inherit build; inherit (p) name; file = fileOf p; })) all);
  trees = pkgs.linkFarm "glibc-${e.version}-${e.release}-rpm-trees"
    (map (p: { name = p.name; path = rpms.${p.name}; }) all);

  expected = pkgs.writeText "glibc-expected-rpms" (lib.concatMapStrings (p:
    "${p.name} ${p.arch} ${toString (p.epoch or 0)} ${p.version or e.version} ${p.release or e.release} ${if p ? srpm then "shipped" else "unshipped"}\n") all);

  # official RPMs of the main subpackages, for the informational diff in `sanity`
  compareNames = [ "glibc" "glibc-common" "glibc-devel" "glibc-doc" "glibc-utils" "glibc-static"
    "glibc-gconv-extra" "glibc-minimal-langpack" "glibc-langpack-en" "glibc-locale-source"
    "glibc-nss-devel" "glibc-benchtests" "nss_db" "nss_hesiod" "libnsl" ];
  official = pkgs.linkFarm "glibc-official-rpms"
    (map (n: { name = "${n}.rpm"; path = officialRpms.${n}; }) compareNames);

  sanity = runInBuildroot {
    name = "glibc-sanity-${e.version}-${e.release}";
    inherit buildroot;
    binds = { "/inputs/build" = build; "/inputs/expected" = expected; "/inputs/official" = official; };
    script = builtins.readFile ./glibc-sanity.sh;
  };
in
{
  inherit build rpms trees sanity buildroot root expected;
  subpackages = map (p: p.name) all;
}
