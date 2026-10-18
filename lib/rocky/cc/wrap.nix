# S1 C toolchain for the nix-native builds (design §5.1, WP4): nixpkgs'
# cc-wrapper / bintools-wrapper (wrapCCWith / wrapBintoolsWith from bootPkgs,
# unmodified sources) around copies of the stage0 gcc 14.3.1 and binutils 2.41
# (Rocky sources, FHS trees under usr/), with a relocated glibc as libc.
#
#   wrap { libc }   the wrapped compiler; libc = { out, dev } of a relocated
#                   glibc (a multi-output derivation qualifies)
#   stage0Libc      the stage0 glibc 2.39 + Rocky kernel-headers relocated into
#                   one store path, already adapted: compiles glibc¹ and tests
#                   the wrapper before any relocated glibc exists
#   stage0          wrap { libc = stage0Libc; }
#   libcAdapter     { out, dev } -> what the wrappers read (exported for WP7)
#
# Rocky-specific settings on top of the nixpkgs defaults:
#   * cc-cflags-before empty (no -fno-omit-frame-pointer / machine flags), no
#     default hardening (NIX_HARDENING_ENABLE=""): the flags are
#     redhat-rpm-config's %optflags / %build_ldflags, exactly Rocky's;
#   * cc-wrapper-hook add-prefix-map.sh: -ffile-prefix-map=<input>=/usr for every
#     store include root and the gcc prefix; -frandom-seed from the environment
#     (nixpkgs' reproducible-builds.sh) dropped [F-1, E1];
#   * --enable-new-dtags (Rocky's ld defaults to DT_RPATH [NF-S2]) so the
#     wrapper's -rpath entries become DT_RUNPATH;
#   * self rpath $out/lib64 instead of $out/lib (lib64-rpath.sh, setup hook);
#   * dynamic-linker <out>/lib64/ld-linux-x86-64.so.2, -m32: <out>/lib/ld-linux.so.2.
#
# Usable from PATH without setup hooks (mkRpmPackage's tool shim): gcc cc g++
# c++ cpp, x86_64-redhat-linux-{gcc,g++,c++}, gcc-ar gcc-nm gcc-ranlib gcov
# and binutils (ld as ar nm objcopy ...); with no NIX_* variables set, the
# wrappers add only libc/gcc paths, the dynamic linker and the maps above.
{ bootPkgs, lib, stage0, ... }:
let
  pkgs = bootPkgs;
  storeDir = builtins.storeDir;

  # GNU ld scripts naming FHS paths (/lib64/libgcc_s.so.1, /lib64/libc.so.6,
  # /usr/lib64/libc_nonshared.a) -> the same files in this store path.
  relocLdScripts = ''
    find $out -name 'lib*.so' -type f -size -4k | while read -r f; do
      grep -q 'GNU ld script' "$f" || continue
      sed -i -E "s,([ (])(/usr)?/(lib64|lib)/,\\1$out/\\3/,g" "$f"
      echo "ld script ''${f#$out/}: $(grep -E 'GROUP|INPUT' "$f")"
      if grep -qE '[ (](/usr)?/lib(64)?/' "$f"; then echo "FHS path left in $f" >&2; exit 1; fi
    done
  '';

  # FHS tree (usr/...) -> the top-level layout the wrappers expect.  A real
  # copy: gcc locates cc1, crt*.o, libgcc and its headers relative to its own
  # executable, and a symlink farm makes it use the original tree [NF-S2].
  hoist = { name, tree, passthru ? { }, postCopy ? "" }:
    pkgs.runCommand name {
      nativeBuildInputs = [ pkgs.patchelf ];
      inherit passthru;
    } ''
      mkdir -p $out
      cp -a ${tree}/usr/. $out/
      chmod -R u+w $out
      ${relocLdScripts}
      ${postCopy}
    '';

  gcc = hoist {
    name = "rocky-s1-gcc-14.3.1-4.4.el10";
    tree = stage0.gcc;
    passthru = { isGNU = true; langC = true; langCC = true; version = "14.3.1"; };
    # The runtime libraries have no RUNPATH (on Rocky libgcc_s.so.1 is in the
    # system dir).  libstdc++.so.6 NEEDs libgcc_s.so.1, and a DT_RUNPATH of the
    # program does not apply to libstdc++'s own dependencies: $ORIGIN finds the
    # copy's libgcc_s next to it.  Bootstrap-only (gcc¹ replaces these in S1).
    postCopy = ''
      for f in $out/lib64/*.so.* $out/lib/*.so.*; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        case "$(head -c 4 "$f" | od -An -c | tr -d ' ')" in *ELF*) ;; *) continue ;; esac
        if [ -z "$(patchelf --print-rpath "$f")" ] && patchelf --print-needed "$f" | grep -qx 'libgcc_s.so.1'; then
          patchelf --set-rpath '$ORIGIN' "$f"
          echo "RUNPATH \$ORIGIN: ''${f#$out/}"
        fi
      done
    '';
  };

  binutils = hoist {
    name = "rocky-s1-binutils-2.41-63.el10";
    tree = stage0.binutils;
    passthru = { isGNU = true; version = "2.41"; };
  };

  libcAdapter = libc:
    let
      out = libc.out or libc;
      dev = libc.dev or out;
    in
    out // {
      inherit out dev;
      lib = dev;   # crt*.o, the libc.so ld script, libc_nonshared.a: -devel [NF-S6]
      bin = dev;   # keeps glibc's tools (ldd, iconv, localedef) off the build PATH
      libdir = "/lib64/";
      incdir = "/include";
      dynamicLinker = "${out}/lib64/ld-linux-x86-64.so.2";
      dynamicLinkerM32 = "${out}/lib/ld-linux.so.2";
      rockyLibc = true;
    };

  # stage0 glibc (FHS, prefix /usr) + Rocky kernel-headers as one relocated
  # tree: include/ (glibc + kernel headers), lib64/, lib/ (i686).  Programs it
  # links run from the store (PT_INTERP and RUNPATH name this path); its ld.so
  # still has the FHS system dirs compiled in (harmless in the sandbox).
  stage0LibcTree = pkgs.runCommand "stage0-libc-2.39-142.el10_2" { } ''
    mkdir -p $out
    cp -a ${stage0.glibc}/usr/include ${stage0.glibc}/usr/lib64 ${stage0.glibc}/usr/lib $out/
    chmod -R u+w $out
    cp -a ${stage0.rpms.kernel-headers}/usr/include/. $out/include/
    ${relocLdScripts}
    test -x $out/lib64/ld-linux-x86-64.so.2 && test -e $out/lib/ld-linux.so.2
  '';
  stage0Libc = libcAdapter { out = stage0LibcTree; dev = stage0LibcTree; };

  wrap = { libc, name ? "rocky-s1" }:
    let
      l = if libc.rockyLibc or false then libc else libcAdapter libc;
      outIsNotDev = l.out.outPath != l.dev.outPath;
      bintools = pkgs.wrapBintoolsWith {
        name = "${name}-binutils-wrapper";
        bintools = binutils;
        libc = l;
        sharedLibraryLoader = null;   # the loader paths are written below
        defaultHardeningFlags = [ ];  # hardening: Rocky's own flags
        extraBuildCommands = ''
          echo ${l.dynamicLinker} > $out/nix-support/dynamic-linker
          echo ${l.dynamicLinkerM32} > $out/nix-support/dynamic-linker-m32
          touch $out/nix-support/ld-set-dynamic-linker
          echo --enable-new-dtags >> $out/nix-support/libc-ldflags-before
          cat ${./lib64-rpath.sh} >> $out/nix-support/setup-hook
        '';
      };
    in
    pkgs.wrapCCWith {
      inherit bintools;
      cc = gcc;
      libc = l;
      extraBuildCommands = ''
        : > $out/nix-support/cc-cflags-before
        substitute ${./add-prefix-map.sh} $out/nix-support/cc-wrapper-hook \
          --subst-var-by gcc ${gcc} --subst-var-by storeDir ${storeDir}
        substitute ${./m32-libc.sh} m32-libc.sh --subst-var-by libcDev ${l.dev} \
          --subst-var-by libcOutB "${lib.optionalString outIsNotDev "-B${l.out}/lib/"}"
        cat m32-libc.sh >> $out/nix-support/cc-wrapper-hook
        ${lib.optionalString outIsNotDev ''
          # out != dev: crt files / libraries may also live in out's lib64
          echo "-B${l.out}/lib64/" >> $out/nix-support/libc-crt1-cflags
        ''}
        # names Rocky has in /usr/bin; the cc-wrapper scripts ignore argv[0]
        for n in x86_64-redhat-linux-gcc x86_64-redhat-linux-gcc-14; do ln -s gcc $out/bin/$n; done
        for n in x86_64-redhat-linux-g++ x86_64-redhat-linux-c++; do ln -s g++ $out/bin/$n; done
        # unwrapped helpers: they find the LTO plugin relative to their real path
        for n in gcc-ar gcc-nm gcc-ranlib gcov gcov-dump gcov-tool lto-dump \
                 x86_64-redhat-linux-gcc-ar x86_64-redhat-linux-gcc-nm x86_64-redhat-linux-gcc-ranlib; do
          if [ -e ${gcc}/bin/$n ]; then ln -s ${gcc}/bin/$n $out/bin/$n; fi
        done
      '';
    };
in
{
  inherit wrap libcAdapter stage0Libc gcc binutils;
  stage0 = wrap { libc = stage0Libc; name = "rocky-s1-stage0libc"; };
}
