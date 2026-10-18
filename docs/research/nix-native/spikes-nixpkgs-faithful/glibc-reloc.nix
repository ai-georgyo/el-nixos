# Spike B: Rocky glibc SRPM built by rpmbuild OUTSIDE the FHS chroot, relocated to
# %_prefix = $out, with the nixpkgs cc-wrapper around the stage0 toolchain (ccwrap.nix),
# tools from PATH (store), and a thin "tool shim" namespace that only provides
# /bin,/usr/bin,/sbin,/usr/sbin (symlinks to PATH tools) and /usr/lib/rpm (rpm config).
let
  f = builtins.getFlake "git+file:///run/host/home/ai-shammas/Code/el-nixos";
  pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
  r = f.legacyPackages.x86_64-linux;
  s0 = r.stage0;
  inherit (pkgs) lib;
  ccw = import ./ccwrap.nix;
  src = s0.lib.unpackSrpm "glibc";
  hoistFhs = name: tree: pkgs.runCommand name { } ''
    mkdir -p $out; for d in include lib64 lib bin; do [ -e ${tree}/usr/$d ] && { mkdir -p $out/$d; cp -rs ${tree}/usr/$d/. $out/$d/; }; done; true
  '';
  kh = s0.rpms.kernel-headers;            # Rocky kernel-headers (FHS tree)
  deps = hoistFhs "glibc-build-deps-hoisted" s0.glibcBuildDeps;   # gd/png/z/selinux/audit/cap + sdt.h
  macroTrees = with s0.rpms; [ redhat-rpm-config rocky-release efi-srpm-macros fonts-srpm-macros forge-srpm-macros
    go-srpm-macros kernel-srpm-macros lua-srpm-macros ocaml-srpm-macros openblas-srpm-macros package-notes-srpm-macros
    perl-srpm-macros pyproject-srpm-macros python-srpm-macros qt6-srpm-macros ];
  # rpm configuration dir as Rocky has it at /usr/lib/rpm (rpm's own + macro packages)
  rpmConfig = pkgs.runCommand "rocky-rpm-config" { } ''
    mkdir -p $out
    cp -r ${s0.rpm}/usr/lib/rpm/. $out/; chmod -R u+w $out
    for t in ${lib.concatStringsSep " " (map toString macroTrees)}; do
      [ -d $t/usr/lib/rpm ] && { cp -r $t/usr/lib/rpm/. $out/; chmod -R u+w $out; }
    done
  '';
  tools = with pkgs; [ ccw.cc ccw.bintools bash coreutils gnused gnugrep gawk findutils diffutils gnupatch gnutar gzip bzip2 xz zstd
    cpio s0.rpmLibs.file util-linux procps gnumake perl python3 gnum4 bison gettext elfutils dwz gdb hostname-debian which ];
  fhsBins = [ "${s0.rpm}/usr/bin" "${s0.debugedit}/usr/bin" "${s0.texinfo71}/usr/bin" ];
in pkgs.stdenvNoCC.mkDerivation {
  name = "glibc-2.39-142.el10_2";
  nativeBuildInputs = tools ++ [ pkgs.bubblewrap ];
  buildInputs = [ deps ];
  requiredSystemFeatures = [ "big-parallel" ];
  # like nixpkgs glibc: no self-rpath (setup.sh adds it to NIX_LDFLAGS at setup time) and no
  # ld-wrapper rpaths: ld.so must not have DT_RPATH (rtld asserts)
  NIX_NO_SELF_RPATH = "1"; NIX_DONT_SET_RPATH = "1";
  # glibc's own configure cache variables (per-package override, like nixpkgs' configureFlags):
  # relocated prefix -> FHS-equivalent layout below $out (Rocky: slibdir=/lib64, rtlddir=/lib64,
  # complocaledir=/usr/lib/locale, rootsbindir=/sbin)
  passAsFile = [ "postPrep" ];
  # Nix-side glibc patch P1 (nixpkgs dont-use-system-ld-so-cache.patch, as a one-line sed):
  # ld.so must not read the host's /etc/ld.so.cache; everything else keeps sysconfdir=/etc
  postPrep = ''
    sed -i "s|# define LD_SO_CACHE SYSCONFDIR \"/ld.so.cache\"|# define LD_SO_CACHE \"$NIX_RPM_PREFIX/etc/ld.so.cache\"|" sysdeps/generic/dl-cache.h
    grep -n 'define LD_SO_CACHE' sysdeps/generic/dl-cache.h
  '';
  buildCommand = ''
    set -euo pipefail
    export CONFIG_SITE="${./config.site} ${./glibc.site}" NIX_RPM_PREFIX=$out
    export NIX_DONT_SET_RPATH=1 NIX_NO_SELF_RPATH=1 NIX_HARDENING_ENABLE=
    unset NIX_CFLAGS_COMPILE_FOR_TARGET || true

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
      --define "_usrsrc $P/src" --define "_rpmmacrodir $P/lib/rpm/macros.d"
      --define "__perl perl" --define "__python3 python3"
      --define "dist .el10_2" --define "_buildhost el-nixos.localdomain"
      --define "source_date_epoch_from_changelog 1" --define "use_source_date_epoch_as_buildtime 1" --define "clamp_mtime_to_source_date_epoch 1"
      --define "_smp_build_ncpus $NIX_BUILD_CORES"
      --define "_annotated_build 0" --define "_annobin_gcc_plugin %{nil}"
      --define "_binary_payload w0.ufdio"
      --define "__check_files sh ${./check-files-nix} %{buildroot}"
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
    if [ $rc -ne 0 ]; then grep -E '^checking (for libgd|for libselinux|for libaudit|for libcap|for systemtap|installed Linux|for bash|for perl)|^LIBGD|configure: WARNING' $TMPDIR/build.log; tail -n 60 $TMPDIR/build.log; exit 1; fi
    sed -E 's|/nix/store/[a-z0-9]{32}-|/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-|g' $TMPDIR/build.log > $out/nix-support/build.log
    BR=$(ls -d $top/BUILDROOT/*)
    echo "buildroot top level:"; ls -la $BR
    # payload -> $out (the prefix); non-prefix FHS leftovers reported
    cp -a $BR$P/. $out/
    (cd $BR && find . -path ./nix -prune -o -print | grep -v '^\./nix$' | sort) > $out/nix-support/outside-prefix.txt || true
    # %files partition from the transient RPMs
    mkdir -p $out/nix-support/rpm-files
    export RPM_CONFIGDIR=${rpmConfig}
    for f in $top/RPMS/*/*.rpm; do
      n=$(rpm -qp --nosignature --qf '%{NAME}' $f)
      rpm -qp --nosignature --qf '[%{FILEFLAGS:fflags}\t%{FILEMODES:perms}\t%{FILELINKTOS}\t%{FILENAMES}\n]' $f > $out/nix-support/rpm-files/$n.txt
      rpm -qp --nosignature --requires $f > $out/nix-support/rpm-files/$n.requires
    done
  '';
}
