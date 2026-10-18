# Spike (designer spec-generic): rpmbuild --rebuild of unmodified Rocky SRPMs
# with relocated macros (%_prefix = P, a /nix/store placeholder) in the
# existing stage0 chroot; P is an alias of the buildroot's /usr inside the
# chroot.  mode = "control" (stock macros) | "reloc".
#   nix build --impure -f reloc-spike.nix -A reloc.which
{ }:
let
  f = builtins.getFlake "git+file:///run/host/home/ai-shammas/Code/el-nixos";
  lp = f.legacyPackages.x86_64-linux;
  s = lp.stage0;
  pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
  inherit (pkgs) lib;

  cmakeSrpm = s.lib.unpackSrpm "cmake";
  mesonSrpm = s.lib.unpackSrpm "meson";
  extraTools = pkgs.runCommand "spike-extra-tools" { } ''
    mkdir -p $out/usr/bin $out/usr/share/aclocal
    for p in ${lib.concatMapStringsSep " " toString (with pkgs; [
      cmake ninja meson autoconf automake libtool pkg-config help2man dejagnu swig doxygen
      xmlto docbook_xsl libxslt gtk-doc autoconf-archive gperf groff ed
    ])}; do
      for b in $p/bin/*; do [ -e $out/usr/bin/$(basename $b) ] || ln -s $b $out/usr/bin/; done
      if [ -d $p/share/aclocal ]; then for m in $p/share/aclocal/*; do [ -e $out/usr/share/aclocal/$(basename $m) ] || ln -s $m $out/usr/share/aclocal/; done; fi
    done
    for m in ${pkgs.gettext}/share/gettext/m4/* ${pkgs.pkg-config}/share/aclocal/*; do [ -e $out/usr/share/aclocal/$(basename $m) ] || ln -s $m $out/usr/share/aclocal/; done
    ln -s ${pkgs.gnupg}/bin/gpgv $out/usr/bin/gpgv2
    mkdir -p $out/etc/rpm $out/usr/lib64/cmake $out/usr/include
    sed -e 's/@@CMAKE_VERSION@@/3.31.8/' -e 's/@@CMAKE_MAJOR_VERSION@@/3/' ${cmakeSrpm}/macros.cmake.in > $out/etc/rpm/macros.cmake
    tar xzf ${mesonSrpm}/meson-1.4.1.tar.gz -O meson-1.4.1/data/macros.meson > $out/etc/rpm/macros.meson
    ln -s ${pkgs.gtest.dev}/lib/cmake/GTest $out/usr/lib64/cmake/GTest
    ln -s ${pkgs.gtest.dev}/include/gtest ${pkgs.gtest.dev}/include/gmock $out/usr/include/
    for l in ${pkgs.gtest}/lib/*.so*; do ln -s $l $out/usr/lib64/; done
  '';
  root = s.mkRoot { name = "spike-reloc-root"; extraTrees = [ extraTools ]; };
  buildroot = s.lib.mkBuildroot { name = "spike-reloc"; base = root; rpms = s.fullRpms; };

  runnerTools = with pkgs; [ bubblewrap coreutils findutils gnugrep gnused gawk diffutils attr cpio bash python3 ];

  run = { srpm, mode, br ? buildroot, defines ? { }, extraArgs ? [ ], name ? srpm, extraMacros ? "", configSiteExtra ? null, macros ? ./reloc.macros }:
    let
      e = s.lib.fetch.entry srpm;
      srpmFile = s.lib.fetchSrpm srpm;
      # padded so that every output path /nix/store/<h>-<srpm>-<evr>-<output> (output
      # names <= 32 chars) is not longer than P: rewriting is length-preserving
      P = "/nix/store/00000000000000000000000000000000-${srpm}-${e.version}-${e.release}-${lib.fixedWidthString 32 "x" ""}";
      dist = s.lib.distOf srpm;
      defs = {
        _topdir = "/builddir/build"; inherit dist; _buildhost = "el-nixos.localdomain";
        source_date_epoch_from_changelog = "1"; use_source_date_epoch_as_buildtime = "1";
        clamp_mtime_to_source_date_epoch = "1"; _binary_payload = "w3.zstdio";
      } // lib.optionalAttrs (mode == "reloc") { _el_nixos_prefix = P; } // defines;
      defArgs = lib.concatLists (lib.mapAttrsToList (k: v: [ "--define" "${k} ${v}" ]) defs);
      macrosFile = pkgs.writeText "macros.reloc" (builtins.readFile macros + extraMacros);
    in
    pkgs.stdenvNoCC.mkDerivation {
      name = "spike-${mode}-${name}";
      nativeBuildInputs = runnerTools;
      buildCommand = ''
        set -euo pipefail
        source ${s.lib.chrootLib}
        chroot_setup $TMPDIR/st ${lib.escapeShellArgs br.layers}
        mkdir -p $TMPDIR/builddir/build $out
        cp ${srpmFile} $TMPDIR/builddir/x.src.rpm
        cp ${./analyze.py} $TMPDIR/builddir/analyze.py
        P=${P}
        storebinds=()
        for sp in /nix/store/*; do storebinds+=(--ro-bind "$sp" "$sp"); done
        spike_exec() {
          chroot__parse "$@" || return 1
          chroot__fresh_dirs
          local st=$chroot__state
          local -a lowers envs
          mapfile -d "" lowers < <(chroot__lowers)
          mapfile -d "" envs < <(chroot__env_default /builddir)
          chroot__bwrap "''${chroot__args[@]}" \
            "''${lowers[@]}" --overlay "$st/upper" "$st/work" / \
            --tmpfs /nix/store "''${storebinds[@]}" \
            ${lib.optionalString (mode == "reloc") ''--symlink /usr "$P"''} \
            --proc /proc --dev /dev --perms 1777 --tmpfs /dev/shm \
            --perms 1777 --tmpfs /tmp --perms 1777 --tmpfs /var/tmp \
            ${lib.optionalString (mode == "reloc") "--ro-bind ${macrosFile} /etc/rpm/macros.zz-el-nixos-reloc --ro-bind ${./check-files} /etc/el-nixos/check-files --ro-bind ${./config.site} /etc/el-nixos/config.site"}${lib.optionalString (mode == "reloc" && macros == ./reloc.macros) " --ro-bind ${./realias} /etc/el-nixos/realias"} ${lib.optionalString (configSiteExtra != null) "--ro-bind ${configSiteExtra} /etc/el-nixos/config.site.extra"} \
            "''${chroot__binds[@]}" \
            "''${envs[@]}" "''${chroot__env[@]}" \
            --chdir "$chroot__cwd" \
            "''${chroot__cmd[@]}"
        }
        runc() {
          spike_exec --user 1000 135 --bind $TMPDIR/builddir /builddir --hostname el-nixos.localdomain \
            --chdir /builddir --setenv USER mockbuild --setenv LOGNAME mockbuild \
            --setenv PKG_CONFIG_PATH /usr/lib64/pkgconfig:/usr/share/pkgconfig \
            --setenv ACLOCAL_PATH /usr/share/aclocal \
            ${lib.optionalString (mode == "reloc") ''--setenv CONFIG_SITE /etc/el-nixos/config.site --setenv EL_NIXOS_PREFIX "$P" --setenv EL_NIXOS_CONFIG_SITE_EXTRA /etc/el-nixos/config.site.extra''} -- "$@"
        }
        ncpus=''${NIX_BUILD_CORES:-1}
        set +e
        runc /usr/bin/rpmbuild --rebuild /builddir/x.src.rpm ${lib.escapeShellArgs defArgs} \
          --define "_smp_build_ncpus $ncpus" --target x86_64 --nodeps --nocheck ${lib.escapeShellArgs extraArgs} \
          > $TMPDIR/build.log 2>&1
        rc=$?
        set -e
        cp $TMPDIR/build.log $out/build.log
        echo $rc > $out/rc
        { grep -E '^\+ |^Executing\(%' $TMPDIR/build.log | grep -E '^Executing' | tail -1 || true; } > $out/phase
        { grep -nE '(^error:|^ERROR|File not found|No such file|cannot|Installed \(but unpackaged\)|^   /)' $TMPDIR/build.log | tail -60 || true; } > $out/errors
        tail -60 $TMPDIR/build.log > $out/tail
        ls -R $TMPDIR/builddir/build/RPMS > $out/rpms 2>/dev/null || true
        ${lib.optionalString (mode == "reloc") ''
          if [ $rc -eq 0 ]; then
            set +e
            runc /usr/bin/python3 /builddir/analyze.py /builddir/build/RPMS "$P" /builddir/an > $out/analysis.txt 2>&1
            echo $? > $out/analysis.rc
            set -e
            cp $TMPDIR/builddir/an/analysis.json $out/ 2>/dev/null || true
            # keep the extracted trees small: only the file lists
            (cd $TMPDIR/builddir/an/x && find . \( -type f -o -type l \) | sort) > $out/files.txt || true
            cp -r $TMPDIR/builddir/build/RPMS $out/RPMS
            echo "$P" > $out/P
          fi
        ''}
        echo "rc=$rc $(cat $out/phase)"
      '';
    };

  names = [ "which" "xz" "popt" "libffi" "gzip" "bzip2" "lz4" "libsepol" "attr" "gmp" "libunistring" "libyaml"
    "m4" "cpio" "ncurses" "json-c" "zlib-ng" "expat" "libxcrypt" "diffutils" "redhat-rpm-config" "rocky-release"
    "bash" "sed" ];
  # stage0 limitations only (not relocation): no libasan in the stage0 gcc
  perPkg = { zlib-ng = { extraArgs = [ "--without" "sanitizers" ]; }; };
  glibcDefines = { _annotated_build = "0"; _annobin_gcc_plugin = "%{nil}"; };
in
{
  inherit buildroot extraTools run;
  control = lib.genAttrs names (n: run ({ srpm = n; mode = "control"; } // (perPkg.${n} or { })));
  reloc = lib.genAttrs names (n: run ({ srpm = n; mode = "reloc"; } // (perPkg.${n} or { })));
  glibc = {
    control = run { srpm = "glibc"; mode = "control"; br = lp.packageSets.glibc.buildroot; defines = glibcDefines; };
    reloc = run { srpm = "glibc"; mode = "reloc"; br = lp.packageSets.glibc.buildroot; defines = glibcDefines; configSiteExtra = ./glibc.config.site; macros = ./reloc-v1.macros; };
  };
}
