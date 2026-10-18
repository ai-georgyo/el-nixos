# Experiment E1 (design §9, WP0a): does -ffile-prefix-map remove every input
# store path from the DWARF of a relocated glibc, incl. ld.so's retained DWARF?
#
# `glibc` is the [NF-S3] spike (docs/research/nix-native/spikes-nixpkgs-faithful/
# glibc-reloc.nix: the glibc SRPM built by rpmbuild outside the FHS chroot,
# %_prefix = $out, one output, no partition) with three changes:
#   * compiler = nn.cc.stage0 (lib/rocky/cc/wrap.nix): -ffile-prefix-map hook,
#     environment -frandom-seed dropped, --enable-new-dtags, lib64 self-rpath;
#   * %_usrsrc /usr/src (design §1.2) instead of $out/src;
#   * the inputs are this flake's attributes instead of builtins.getFlake.
# `report` scans the result: closure (exportReferencesGraph), full and pieced
# input store paths (storescan.py), DW_AT_producer.
# Pass condition: closure = { glibc } and no input store path anywhere.
# Results: docs/research/nix-native/experiments/E1.md.
{ bootPkgs, lib, stage0, cc, ... }:
let
  pkgs = bootPkgs;
  src = stage0.lib.unpackSrpm "glibc";
  kh = stage0.rpms.kernel-headers;        # Rocky kernel-headers (FHS tree)
  hoistFhs = name: tree: pkgs.runCommand name { } ''
    mkdir -p $out
    for d in include lib64 lib bin; do
      [ -e ${tree}/usr/$d ] && { mkdir -p $out/$d; cp -rs ${tree}/usr/$d/. $out/$d/; }
    done
    true
  '';
  deps = hoistFhs "glibc-build-deps-hoisted" stage0.glibcBuildDeps;  # gd/png/z/selinux/audit/cap + sdt.h
  # rpm configuration dir as Rocky has it at /usr/lib/rpm (rpm's own + macro packages)
  rpmConfig = (import ./rpm-config.nix { inherit bootPkgs lib stage0; }).config;
  tools = with pkgs; [ cc.stage0 bash coreutils gnused gnugrep gawk findutils diffutils gnupatch gnutar
    gzip bzip2 xz zstd cpio stage0.rpmLibs.file util-linux procps gnumake perl python3 gnum4 bison
    gettext elfutils dwz gdb hostname-debian which ];
  fhsBins = [ "${stage0.rpm}/usr/bin" "${stage0.debugedit}/usr/bin" "${stage0.texinfo71}/usr/bin" ];

  glibc = pkgs.stdenvNoCC.mkDerivation {
    name = "glibc-2.39-142.el10_2";
    nativeBuildInputs = tools ++ [ pkgs.bubblewrap ];
    buildInputs = [ deps ];
    requiredSystemFeatures = [ "big-parallel" ];
    # like nixpkgs glibc: no self-rpath and no ld-wrapper rpaths (rtld asserts
    # that ld.so has no DT_RPATH); derivation attributes, read at setup time
    NIX_NO_SELF_RPATH = "1"; NIX_DONT_SET_RPATH = "1";
    passAsFile = [ "postPrep" ];
    # Nix-side glibc patch P1 as a one-line sed (as in the spike)
    postPrep = ''
      sed -i "s|# define LD_SO_CACHE SYSCONFDIR \"/ld.so.cache\"|# define LD_SO_CACHE \"$NIX_RPM_PREFIX/etc/ld.so.cache\"|" sysdeps/generic/dl-cache.h
      grep -n 'define LD_SO_CACHE' sysdeps/generic/dl-cache.h
    '';
    buildCommand = ''
      set -euo pipefail
      export CONFIG_SITE="${./e1/config.site} ${./e1/glibc.site}" NIX_RPM_PREFIX=$out
      export NIX_DONT_SET_RPATH=1 NIX_NO_SELF_RPATH=1 NIX_HARDENING_ENABLE=
      echo "NIX_CFLAGS_COMPILE=''${NIX_CFLAGS_COMPILE:-}"   # carries -frandom-seed: the wrapper drops it

      # --- tool shim: /usr/bin etc. = symlinks to PATH tools (first wins); /usr/lib/rpm
      shim=$TMPDIR/shim; mkdir -p $shim/bin
      IFS=: read -ra pdirs <<< "${lib.concatStringsSep ":" fhsBins}:$PATH"
      for d in "''${pdirs[@]}"; do [ -d "$d" ] || continue
        for x in "$d"/*; do n=''${x##*/}; [ -e "$shim/bin/$n" ] || ln -s "$x" "$shim/bin/$n"; done; done
      export PATH="${lib.concatStringsSep ":" fhsBins}:$PATH"

      top=$TMPDIR/rpmbuild; mkdir -p $top/SOURCES $top/SPECS
      cp -r ${src}/. $top/SOURCES/; chmod -R u+w $top/SOURCES
      # spec adaptation (per-package override): kernel headers are a separate store path
      sed -e 's|--with-headers=%{_prefix}/include|--with-headers=${kh}/usr/include|' $top/SOURCES/glibc.spec > $top/SPECS/glibc.spec

      P=$out
      defs=(
        --define "_topdir $top" --define "_sourcedir $top/SOURCES" --define "_tmppath $TMPDIR"
        --define "_prefix $P" --define "_exec_prefix $P" --define "_prefix_rel ''${P#/}"
        --define "_sysconfdir /etc" --define "_localstatedir /var" --define "_sharedstatedir /var/lib" --define "_rundir /run"
        --define "_usrsrc /usr/src" --define "_rpmmacrodir $P/lib/rpm/macros.d"
        --define "__perl perl" --define "__python3 python3"
        --define "dist .el10_2" --define "_buildhost el-nixos.localdomain"
        --define "source_date_epoch_from_changelog 1" --define "use_source_date_epoch_as_buildtime 1" --define "clamp_mtime_to_source_date_epoch 1"
        --define "_smp_build_ncpus $NIX_BUILD_CORES"
        --define "_annotated_build 0" --define "_annobin_gcc_plugin %{nil}"
        --define "_binary_payload w0.ufdio"
        --define "__check_files sh ${./e1/check-files-nix} %{buildroot}"
        --define "__spec_prep_post cd %{_builddir}/%{buildsubdir} \&\& sh $postPrepPath; %{___build_post}"
        # hard-coded /usr, /etc in %install fold into the prefix (BUILDROOT/usr -> prefix)
        --define '__spec_install_pre %{___build_pre}; rm -rf "%{buildroot}"; mkdir -p "%{buildroot}%{_prefix}"; ln -s "%{_prefix_rel}" "%{buildroot}/usr"'
      )
      echo "=== rpmbuild -bb (relocated to $P)"
      set +e
      env --default-signal=PIPE bwrap --bind /nix /nix --bind "$NIX_BUILD_TOP" "$NIX_BUILD_TOP" --ro-bind /etc /etc --proc /proc --dev /dev --tmpfs /tmp \
        --dir /usr --ro-bind $shim/bin /usr/bin --symlink /usr/bin /usr/sbin --chdir "$PWD" \
        --ro-bind $shim/bin /bin --ro-bind $shim/bin /sbin --ro-bind ${rpmConfig} /usr/lib/rpm \
        -- rpmbuild -bb --nodeps --nocheck --noclean --target x86_64 "''${defs[@]}" $top/SPECS/glibc.spec > $TMPDIR/build.log 2>&1
      rc=$?
      set -e
      mkdir -p $out/nix-support
      if [ $rc -ne 0 ]; then tail -n 80 $TMPDIR/build.log; exit 1; fi
      sed -E 's|/nix/store/[a-z0-9]{32}-|/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-|g' $TMPDIR/build.log > $out/nix-support/build.log
      BR=$(ls -d $top/BUILDROOT/*)
      echo "buildroot top level:"; ls -la $BR
      cp -a $BR$P/. $out/
      (cd $BR && find . -path ./nix -prune -o -print | grep -v '^\./nix$' | sort) > $out/nix-support/outside-prefix.txt || true
      mkdir -p $out/nix-support/rpm-files
      export RPM_CONFIGDIR=${rpmConfig}
      for f in $top/RPMS/*/*.rpm; do
        n=$(rpm -qp --nosignature --qf '%{NAME}' $f)
        rpm -qp --nosignature --qf '[%{FILEFLAGS:fflags}\t%{FILEMODES:perms}\t%{FILELINKTOS}\t%{FILENAMES}\n]' $f > $out/nix-support/rpm-files/$n.txt
      done
    '';
  };

  # every store path the build could have leaked (direct inputs; their own
  # closures are caught by the generic full-hash scan)
  inputs = [ cc.stage0 cc.stage0.bintools cc.gcc cc.binutils cc.stage0Libc.out kh deps
    stage0.glibcBuildDeps rpmConfig src ] ++ tools ++ map (d: lib.removeSuffix "/usr/bin" d) fhsBins;

  report = pkgs.runCommand "e1-report" {
    nativeBuildInputs = [ pkgs.python3 pkgs.binutils-unwrapped pkgs.zstd ];
    exportReferencesGraph = [ "closure" glibc ];
    passAsFile = [ "inputList" ];
    inputList = lib.concatMapStringsSep "\n" toString inputs;
  } ''
    G=${glibc}
    mkdir -p $out
    {
      echo "== E1 report for $G"
      echo "== closure (exportReferencesGraph)"
      grep '^/nix/store/' closure | sort -u
      n=$(grep '^/nix/store/' closure | sort -u | grep -vxF "$G" | wc -l)
      echo "foreign paths in closure: $n"
      echo "== storescan: whole output (full store paths not self; pieced input hashes)"
      python3 -I ${./storescan.py} --self $G --inputs-file $inputListPath --summary $G || true
      echo "== storescan: ld.so, DWARF only"
      python3 -I ${./storescan.py} --self $G --inputs-file $inputListPath --debug-only $G/lib64/ld-linux-x86-64.so.2 || true
      echo "== DW_AT_producer of ld.so and libc.so.6 debuginfo"
      readelf --debug-dump=info $G/lib64/ld-linux-x86-64.so.2 2>/dev/null | grep -m3 DW_AT_producer || true
      dbg=$(find $G/lib/debug -name 'libc.so.6-*.debug' | head -n 1)
      readelf --debug-dump=info "$dbg" 2>/dev/null | grep -m3 DW_AT_producer || true
      echo "-frandom-seed in any producer: $(strings -a $G/lib64/ld-linux-x86-64.so.2 "$dbg" | grep -c -- -frandom-seed || true)"
      echo "== DWARF directory names (ld.so), store/usr only"
      readelf --debug-dump=line $G/lib64/ld-linux-x86-64.so.2 2>/dev/null | grep -oE '(/nix/store/[^ ]*|/usr/[^ ]*)' | sed -E 's|^(/nix/store/[^/]*/[^/]*/[^/]*).*|\1|' | sort | uniq -c | sort -rn | head -n 30
    } > $out/report.txt 2>&1
    cat $out/report.txt
  '';
in
{ inherit glibc report rpmConfig deps; }
