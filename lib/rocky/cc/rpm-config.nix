# Stage-0 rpm configuration as Rocky has it at /usr/lib/rpm (rpm's own files +
# redhat-rpm-config + the *-srpm-macros + macros.dist), assembled by copying,
# as the [NF-S3] spike did; WP2's rpmConfig replaces it for real builds.
#   config   the /usr/lib/rpm tree (FHS paths inside: needs the tool shim)
#   flags    Rocky's compiler flags for x86_64, evaluated by the stage0 rpm:
#            $out/{cflags,cxxflags,ldflags}, with /usr/lib/rpm pointing at a
#            copy of the config in $out/lib/rpm (the -specs= files resolve
#            without a shim); annobin off (§1.2: no annobin plugin in stage0)
{ bootPkgs, lib, stage0 }:
let
  pkgs = bootPkgs;
  macroTrees = with stage0.rpms; [ redhat-rpm-config rocky-release efi-srpm-macros fonts-srpm-macros
    forge-srpm-macros go-srpm-macros kernel-srpm-macros lua-srpm-macros ocaml-srpm-macros
    openblas-srpm-macros package-notes-srpm-macros perl-srpm-macros pyproject-srpm-macros
    python-srpm-macros qt6-srpm-macros ];
  config = pkgs.runCommand "rocky-rpm-config" { } ''
    mkdir -p $out
    cp -r ${stage0.rpm}/usr/lib/rpm/. $out/; chmod -R u+w $out
    for t in ${lib.concatStringsSep " " (map toString macroTrees)}; do
      [ -d $t/usr/lib/rpm ] && { cp -r $t/usr/lib/rpm/. $out/; chmod -R u+w $out; }
    done
  '';
  flags = pkgs.runCommand "rocky-compiler-flags" { } ''
    mkdir -p $out/lib
    cp -r ${config} $out/lib/rpm; chmod -R u+w $out/lib/rpm
    grep -rlI /usr/lib/rpm $out/lib/rpm | while read -r f; do sed -i "s|/usr/lib/rpm|$out/lib/rpm|g" "$f"; done
    ev() {
      RPM_CONFIGDIR=$out/lib/rpm ${stage0.rpm}/usr/bin/rpm --target x86_64 --define 'dist .el10_2' \
        --define '_annotated_build 0' --define '_annobin_gcc_plugin %{nil}' --eval "$1"
    }
    ev '%{build_cflags}' > $out/cflags
    ev '%{build_cxxflags}' > $out/cxxflags
    ev '%{build_ldflags}' > $out/ldflags
    head -v $out/cflags $out/cxxflags $out/ldflags
    grep -q -- '-march=x86-64-v3' $out/cflags   # rpmrc read (Rocky 10 baseline)
    ! grep -q annobin $out/cflags $out/ldflags
  '';
in
{ inherit config flags; }
