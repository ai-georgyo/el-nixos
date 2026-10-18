# E2: one SRPM built by rpmbuild OUTSIDE the FHS chroot, relocated to
# %_prefix = $out, through the tool shim (nn.toolShim), in one of two
# variants that differ ONLY in the shim's view:
#   noview  /usr = PATH tools only (bin, sbin), no alias -- the [NF-S3] shim
#   view    /usr = PATH tools + declared inputs' include lib lib64 libexec share,
#           and the same view bind-mounted read-only at $out (self-prefix alias)
# Both variants have the same store name (same $out length), so their outputs
# compare byte-for-byte modulo the own store hash.  Base:
# docs/research/nix-native/spikes-nixpkgs-faithful/glibc-reloc.nix.
# The output is the whole payload under $out (no partition; that is WP5) +
# nix-support/{build.log,rpm-files/,outside-prefix.txt,view-*}.
{ pkgs, stage0, toolShim, ccw, rpmConfig }:
{ srpm
, variant                 # "view" | "noview"
, viewInputs ? [ ]        # declared inputs (store paths) -> /usr (view variant only)
, buildInputs ? [ ]       # library inputs: cc-wrapper flags in both variants
, tools ? [ ]             # extra nativeBuildInputs (PATH, setup hooks)
, specSubstitutions ? [ ] # [ { from; to; } ] exactly once each (noview only)
, configSite ? [ ]
, env ? { }
, postPrep ? null         # shell run in the unpacked source (%__spec_prep_post)
, bigParallel ? false
  # a local spec instead of the locked SRPM (positive control): { dir; version; release; dist; }
, local ? null
}:
let
  inherit (pkgs) lib;
  s0 = stage0;
  e = if local != null then local else s0.lib.fetch.entry srpm;
  src = if local != null then local.dir else s0.lib.unpackSrpm srpm;
  dist = if local != null then local.dist else s0.lib.distOf srpm;
  view = variant == "view";
  baseTools = with pkgs; [ ccw.cc ccw.bintools bash coreutils gnused gnugrep gawk findutils diffutils gnupatch
    gnutar gzip bzip2 xz zstd cpio s0.rpmLibs.file util-linux procps gnumake perl python3 gnum4 bison gettext
    elfutils dwz gdb hostname-debian which ]
    # redhat-rpm-config's brp-ldconfig runs /sbin/ldconfig (glibc's spec disables it)
    ++ lib.optional (srpm != "glibc") ldconfig;
  ldconfig = pkgs.runCommand "stage0-ldconfig" { } ''
    mkdir -p $out/bin; ln -s ${s0.glibc}/usr/sbin/ldconfig $out/bin/ldconfig
  '';
  fhsBins = [ "${s0.rpm}/usr/bin" "${s0.debugedit}/usr/bin" "${s0.texinfo71}/usr/bin" ];
  substs = lib.concatMapStrings (s: ''
    n=$(grep -cF -- ${lib.escapeShellArg s.from} $top/SPECS/${srpm}.spec || true)
    [ "$n" = 1 ] || { echo "specSubstitution ${lib.escapeShellArg s.from}: $n matches (want 1)" >&2; exit 1; }
    substituteInPlace $top/SPECS/${srpm}.spec --replace-fail ${lib.escapeShellArg s.from} ${lib.escapeShellArg s.to}
  '') (lib.optionals (!view) specSubstitutions);
in
assert lib.elem variant [ "view" "noview" ];
pkgs.stdenvNoCC.mkDerivation ({
  name = "${srpm}-${e.version}-${e.release}";
  e2Variant = variant;
  # nixpkgs' reproducible-builds hook seeds gcc with the first 10 chars of $out's
  # hash ([F-1]); the seed reaches DW_AT_producer and the order of .debug_str.
  # One seed for both variants, so only the view can make them differ.
  NIX_OUTPATH_USED_AS_RANDOM_SEED = "e2seed0000";
  nativeBuildInputs = baseTools ++ tools;
  inherit buildInputs;
  requiredSystemFeatures = lib.optional bigParallel "big-parallel";
  rockyViewInputs = if view then map toString viewInputs else [ ];
  passthru = {
    inherit variant viewInputs srpm;
    # what the shim's /usr/bin is made from (PATH)
    viewPath = lib.concatStringsSep ":" (fhsBins ++ map (p: "${lib.getBin p}/bin") (baseTools ++ tools));
  };
  buildCommand = ''
    set -euo pipefail
    export CONFIG_SITE="${lib.concatMapStringsSep " " (p: "${p}") configSite}" NIX_RPM_PREFIX=$out
    export NIX_HARDENING_ENABLE=
    # check-rpaths: every absolute RUNPATH outside /lib*, /usr/lib* is "invalid"
    # (0x0002), i.e. every store RUNPATH the cc-wrapper adds
    export QA_RPATHS=$(( 0x0002 ))
    unset NIX_CFLAGS_COMPILE_FOR_TARGET || true
    export PATH="${lib.concatStringsSep ":" fhsBins}:$PATH"

    top=$TMPDIR/rpmbuild; mkdir -p $top/SOURCES $top/SPECS
    cp -r ${src}/. $top/SOURCES/; chmod -R u+w $top/SOURCES
    cp $top/SOURCES/${srpm}.spec $top/SPECS/${srpm}.spec
    ${substs}

    P=$out
    defs=(
      --define "_topdir $top" --define "_sourcedir $top/SOURCES" --define "_tmppath $TMPDIR"
      --define "_prefix $P" --define "_exec_prefix $P" --define "_prefix_rel ''${P#/}"
      --define "_sysconfdir /etc" --define "_localstatedir /var" --define "_sharedstatedir /var/lib" --define "_rundir /run"
      --define "_usrsrc $P/src" --define "_rpmmacrodir $P/lib/rpm/macros.d"
      --define "__perl perl" --define "__python3 python3"
      --define "dist ${dist}" --define "_buildhost el-nixos.localdomain"
      --define "source_date_epoch_from_changelog 1" --define "use_source_date_epoch_as_buildtime 1" --define "clamp_mtime_to_source_date_epoch 1"
      --define "_smp_build_ncpus $NIX_BUILD_CORES"
      --define "_annotated_build 0" --define "_annobin_gcc_plugin %{nil}"
      --define "_binary_payload w0.ufdio"
      --define "__check_files sh ${./check-files-nix} %{buildroot}"
      --define "_e2_realias ${./realias}"
      ${lib.optionalString (postPrep != null) ''--define "__spec_prep_post cd %{_builddir}/%{buildsubdir} \&\& sh ${pkgs.writeText "post-prep.sh" postPrep}; %{___build_post}"''}
      # hard-coded /usr, /etc in %install fold into the prefix (BUILDROOT/usr -> prefix)
      --define '__spec_install_pre %{___build_pre}; rm -rf "%{buildroot}"; mkdir -p "%{buildroot}%{_prefix}"; ln -s "%{_prefix_rel}" "%{buildroot}/usr"'
    )
    # rpm config: redhat/macros + macros.e2 (multi-line __spec_install_post).  Not
    # macros.d (platform/x86_64-linux/macros, read later, redefines it) and not
    # --load (dropped when --target re-reads the configuration).
    cp -r ${rpmConfig} $TMPDIR/rpm-config; chmod -R u+w $TMPDIR/rpm-config
    cat ${./macros.e2} >> $TMPDIR/rpm-config/redhat/macros
    export RPM_CONFIG_DIR=$TMPDIR/rpm-config
    export ROCKY_PREFIX_VIEW=${if view then "1" else "0"}
    echo "=== rpmbuild -bb ${srpm} (relocated to $P, variant ${variant})"
    set +e
    ${toolShim} -- rpmbuild -bb --nodeps --nocheck --noclean --target x86_64 \
      "''${defs[@]}" $top/SPECS/${srpm}.spec > $TMPDIR/build.log 2>&1
    rc=$?
    set -e
    if [ $rc -ne 0 ]; then
      grep -v '^+ ' $TMPDIR/build.log | grep -E -B 25 -m 3 'configure: error|Error [0-9]|No such file|cannot find' || true
      echo ...; tail -n 60 $TMPDIR/build.log; exit 1
    fi
    # nothing may have been written to the prefix itself (view: the shim checks it too)
    if [ -e $out ] && [ -n "$(ls -A $out)" ]; then echo "\$out not empty after rpmbuild" >&2; exit 1; fi
    mkdir -p $out/nix-support
    sed -E 's|/nix/store/[a-z0-9]{32}-|/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-|g' $TMPDIR/build.log > $out/nix-support/build.log
    BR=$(ls -d $top/BUILDROOT/*)
    # payload -> $out (the prefix); non-prefix FHS leftovers listed
    cp -a $BR$P/. $out/
    (cd $BR && find . -path ./nix -prune -o -print | grep -v '^\./nix$' | sort) > $out/nix-support/outside-prefix.txt || true
    # %files partition from the transient RPMs (rpm reads /usr/lib/rpm: in the shim)
    mkdir -p $TMPDIR/rpm-files
    ROCKY_PREFIX_VIEW=0 ${toolShim} -- bash -euc '
      for f in "$1"/RPMS/*/*.rpm; do
        n=$(rpm -qp --nosignature --qf "%{NAME}" "$f")
        rpm -qp --nosignature --qf "[%{FILEFLAGS:fflags}\t%{FILEMODES:perms}\t%{FILELINKTOS}\t%{FILENAMES}\n]" "$f" > "$2/$n.txt"
      done' _ $top $TMPDIR/rpm-files
    cp -r $TMPDIR/rpm-files $out/nix-support/rpm-files
    # what the shim showed
    printf '%s\n' ${lib.escapeShellArgs (if view then map toString viewInputs else [ ])} > $out/nix-support/view-inputs
    cp $NIX_BUILD_TOP/rocky-view-collisions.txt $out/nix-support/view-collisions.txt
  '';
} // env)
