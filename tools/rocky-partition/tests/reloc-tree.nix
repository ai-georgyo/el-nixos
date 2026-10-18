# Relocated rpmbuild trees: fixtures for rocky-partition (the glibc replay
# check, experiment E3). NOT mkRpmPackage (WP6): this is the [NF-S3] spike
# recipe (docs/research/nix-native/spikes-nixpkgs-faithful/glibc-reloc.nix)
# as a function, with the build tree kept (design §11.4 "buildtree"):
#
#   relocTree { srpm = "xz"; cc = "nixpkgs"; buildInputs = [ ... ]; }
#   -> $out = the compile prefix P (%_prefix), containing only
#      $out/buildtree/BUILDROOT   rpm's buildroot after %install + brp + debuginfo
#                                 (BUILDROOT/usr -> nix/store/<P>, relative)
#      $out/buildtree/RPMS/*/*.rpm  the transient RPMs, truncated after the
#                                 header (rpm -qp --nosignature --nodigest
#                                 reads them; the bytes are in BUILDROOT)
#      $out/buildtree/prefix      P
#      $out/buildtree/build.log   (store paths of inputs normalised)
#
# The store name is <srpm>-<version>-<release>, the name of the relocated
# package's `out`, so `rocky-partition --replay <tree> --remap P=<new out>`
# is a same-length remap.
{ pkgs, stage0 }:
let
  inherit (pkgs) lib;
  s0 = stage0;
  stage0cc = import ./stage0-cc.nix { inherit pkgs stage0; };
  macroTrees = with s0.rpms; [ redhat-rpm-config rocky-release efi-srpm-macros fonts-srpm-macros forge-srpm-macros
    go-srpm-macros kernel-srpm-macros lua-srpm-macros ocaml-srpm-macros openblas-srpm-macros package-notes-srpm-macros
    perl-srpm-macros pyproject-srpm-macros python-srpm-macros qt6-srpm-macros ];
  # rpm configuration dir as Rocky has it at /usr/lib/rpm (rpm's own + macro packages)
  rpmConfigFor = extraMacros: pkgs.runCommand "rocky-rpm-config" { inherit extraMacros; } ''
    mkdir -p $out
    cp -r ${s0.rpm}/usr/lib/rpm/. $out/; chmod -R u+w $out
    for t in ${lib.concatStringsSep " " (map toString macroTrees)}; do
      [ -d $t/usr/lib/rpm ] && { cp -r $t/usr/lib/rpm/. $out/; chmod -R u+w $out; }
    done
    [ -z "$extraMacros" ] || printf '%s\n' "$extraMacros" > $out/macros.d/macros.zz-test
  '';
  baseTools = with pkgs; [ bash coreutils gnused gnugrep gawk findutils diffutils gnupatch gnutar gzip bzip2 xz zstd
    cpio s0.rpmLibs.file util-linux procps gnumake perl python3 gnum4 bison gettext elfutils dwz gdb hostname-debian which ];
  fhsBins = [ "${s0.rpm}/usr/bin" "${s0.debugedit}/usr/bin" "${s0.texinfo71}/usr/bin" ];
  # drop everything after the header of an rpm (lead, signature header padded to 8, main header)
  truncatePy = pkgs.writeText "rpm-truncate.py" ''
    import struct, sys
    for p in sys.argv[1:]:
        with open(p, "rb") as f:
            lead = f.read(96)
            assert lead[:4] == b"\xed\xab\xee\xdb", p
            for pad in (True, False):
                n, size = struct.unpack(">II", f.read(16)[8:16])
                f.seek(16 * n + size + ((8 - size % 8) % 8 if pad else 0), 1)
            end = f.tell()
        with open(p, "r+b") as f:
            f.truncate(end)
  '';
in
{ srpm
, cc ? "stage0"            # "stage0": nixpkgs wrappers over the stage0 gcc/binutils/glibc; "nixpkgs": pkgs.stdenv.cc; or a cc-wrapper
, buildInputs ? [ ]        # libraries/headers (cc-wrapper, pkg-config setup hooks)
, tools ? [ ]              # extra native tools (PATH and the /usr/bin shim)
, specSed ? [ ]            # sed expressions applied to the spec
, defines ? { }            # extra/overriding rpmbuild --define
, extraMacros ? ""         # multi-line macro file (rpm config macros.d)
, baseConfigSite ? ./config.site
, configSite ? [ ]         # CONFIG_SITE fragments after baseConfigSite
, env ? { }                # derivation environment
, postPrep ? ""            # run in the unpacked source after %prep
, rpmbuildArgs ? [ ]       # e.g. [ "--without" "gpm" ]
, bigParallel ? false
, failTail ? 80            # log lines shown when rpmbuild fails
}:
let
  e = s0.lib.fetch.entry srpm;
  src = s0.lib.unpackSrpm srpm;
  rpmConfig = rpmConfigFor extraMacros;
  ccTools = if cc == "stage0" then [ stage0cc.cc stage0cc.bintools ] else if cc == "nixpkgs" then [ pkgs.stdenv.cc ] else [ cc ];
  defaults = {
    _sysconfdir = "/etc"; _localstatedir = "/var"; _sharedstatedir = "/var/lib"; _rundir = "/run";
    __perl = "perl"; __python3 = "python3";
    dist = s0.lib.distOf srpm; _buildhost = "el-nixos.localdomain";
    source_date_epoch_from_changelog = "1"; use_source_date_epoch_as_buildtime = "1"; clamp_mtime_to_source_date_epoch = "1";
    _annotated_build = "0"; _annobin_gcc_plugin = "%{nil}";
    _binary_payload = "w0.ufdio";
  };
  defArgs = lib.concatLists (lib.mapAttrsToList (k: v: [ "--define" "${k} ${v}" ]) (defaults // defines));
in
pkgs.stdenvNoCC.mkDerivation (env // {
  name = "${srpm}-${e.version}-${e.release}";
  nativeBuildInputs = ccTools ++ baseTools ++ tools ++ [ pkgs.bubblewrap ];
  inherit buildInputs;
  requiredSystemFeatures = lib.optional bigParallel "big-parallel";
  passAsFile = [ "postPrep" ];
  inherit postPrep;
  specSed = lib.concatMapStrings (x: "-e ${lib.escapeShellArg x} ") specSed;
  passthru = { inherit srpm rpmConfig; buildtree = "buildtree"; };
  buildCommand = ''
    set -euo pipefail
    export CONFIG_SITE="${lib.concatStringsSep " " ([ "${baseConfigSite}" ] ++ map (f: "${f}") configSite)}" NIX_RPM_PREFIX=$out
    export NIX_HARDENING_ENABLE=
    unset NIX_CFLAGS_COMPILE_FOR_TARGET || true

    # --- tool shim: /usr/bin etc. = symlinks to PATH tools (first wins); /usr/lib/rpm
    shim=$TMPDIR/shim; mkdir -p $shim/bin
    IFS=: read -ra pdirs <<< "${lib.concatStringsSep ":" fhsBins}:$PATH"
    for d in "''${pdirs[@]}"; do [ -d "$d" ] || continue
      for x in "$d"/*; do n=''${x##*/}; [ -e "$shim/bin/$n" ] || ln -s "$x" "$shim/bin/$n"; done; done
    [ -e $shim/bin/gpgv2 ] || { [ -e $shim/bin/gpgv ] && ln -s "$(readlink $shim/bin/gpgv)" $shim/bin/gpgv2; } || true
    export PATH="${lib.concatStringsSep ":" fhsBins}:$PATH"

    top=$TMPDIR/rpmbuild; mkdir -p $top/SOURCES $top/SPECS
    cp -r ${src}/. $top/SOURCES/; chmod -R u+w $top/SOURCES
    if [ -n "$specSed" ]; then eval "sed $specSed" < $top/SOURCES/${srpm}.spec > $top/SPECS/${srpm}.spec
    else cp $top/SOURCES/${srpm}.spec $top/SPECS/${srpm}.spec; fi
    if ! cmp -s $top/SOURCES/${srpm}.spec $top/SPECS/${srpm}.spec; then
      echo "spec adapted:"; diff $top/SOURCES/${srpm}.spec $top/SPECS/${srpm}.spec || true
    fi

    P=$out
    defs=(
      --define "_topdir $top" --define "_sourcedir $top/SOURCES" --define "_tmppath $TMPDIR"
      --define "_prefix $P" --define "_exec_prefix $P" --define "_prefix_rel ''${P#/}"
      --define "_usrsrc $P/src" --define "_rpmmacrodir $P/lib/rpm/macros.d"
      --define "_smp_build_ncpus $NIX_BUILD_CORES"
      --define "__check_files sh ${./check-files-nix} %{buildroot}"
      --define "__spec_prep_post cd %{_builddir}/%{buildsubdir} \&\& sh $postPrepPath; %{___build_post}"
      # hard-coded /usr in %install folds into the prefix (BUILDROOT/usr -> prefix)
      --define '__spec_install_pre %{___build_pre}; rm -rf "%{buildroot}"; mkdir -p "%{buildroot}%{_prefix}"; ln -s "%{_prefix_rel}" "%{buildroot}/usr"'
    )
    echo "=== rpmbuild -bb ${srpm} (relocated to $P)"
    set +e
    env --default-signal=PIPE bwrap --bind /nix /nix --bind "$NIX_BUILD_TOP" "$NIX_BUILD_TOP" --ro-bind /etc /etc --proc /proc --dev /dev --tmpfs /tmp \
      --dir /usr --ro-bind $shim/bin /usr/bin --symlink /usr/bin /usr/sbin --chdir "$PWD" \
      --ro-bind $shim/bin /bin --ro-bind $shim/bin /sbin --ro-bind ${rpmConfig} /usr/lib/rpm \
      -- rpmbuild -bb --nodeps --nocheck --noclean --target x86_64 "''${defs[@]}" ${lib.escapeShellArgs defArgs} \
         ${lib.escapeShellArgs rpmbuildArgs} $top/SPECS/${srpm}.spec > $TMPDIR/build.log 2>&1
    rc=$?
    set -e
    if [ $rc -ne 0 ]; then tail -n ${toString failTail} $TMPDIR/build.log; exit 1; fi
    T=$out/buildtree; mkdir -p $T/RPMS
    BR=$(ls -d $top/BUILDROOT/*)
    mv "$BR" $T/BUILDROOT
    for d in $top/RPMS/*/; do cp -r "$d" $T/RPMS/; done
    python3 -I ${truncatePy} $T/RPMS/*/*.rpm
    echo "$P" > $T/prefix
    sed -E 's|/nix/store/[a-z0-9]{32}-|/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-|g' $TMPDIR/build.log > $T/build.log
    echo "buildtree: $(find $T/BUILDROOT | wc -l) paths, $(ls $T/RPMS/*/*.rpm | wc -l) rpms"
  '';
})
