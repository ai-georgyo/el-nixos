# Test fixture: nn.cc.stage0Libc split like the relocated glibc will be
# (design §2.12, §5.1): out = glibc (+ glibc32 merged: lib/), dev =
# glibc-devel/-static (include/, crt*.o, *.a, the lib*.so links and ld
# scripts, which name out's libraries by absolute path).  Exercises the
# wrapper's out != dev path (nn.cc.wrap { libc = { out; dev; }; }) before
# WP7's glibc exists.  Not for builds: the loader is still stage0's (FHS
# system dirs), so programs need out/lib64 as their system dir (tests use
# LD_LIBRARY_PATH for that).
{ bootPkgs, stage0Libc }:
bootPkgs.runCommand "stage0-libc-split" { outputs = [ "out" "dev" ]; } ''
  T=${stage0Libc.out}
  mkdir -p $out $dev/lib64
  cp -a $T/lib64 $T/lib $out/
  cp -a $T/include $dev/
  chmod -R u+w $out $dev
  cd $out/lib64
  for f in *.o *.a lib*.so; do
    if [ -L "$f" ]; then
      ln -s "$out/lib64/$(readlink "$f")" "$dev/lib64/$f"; rm "$f"
    elif [ "''${f%.so}" != "$f" ] && ! grep -q 'GNU ld script' "$f"; then
      continue   # dlopen/LD_PRELOAD objects (libmemusage.so, libpcprofile.so) stay in out
    else
      mv "$f" "$dev/lib64/"
    fi
  done
  for f in $dev/lib64/lib*.so $out/lib/lib*.so; do
    [ -f "$f" ] && [ ! -L "$f" ] && grep -q 'GNU ld script' "$f" || continue
    sed -i -e "s|$T/lib64/libc_nonshared.a|$dev/lib64/libc_nonshared.a|g" -e "s|$T|$out|g" "$f"
    echo "ld script ''${f#/nix/store/*/}: $(grep GROUP "$f")"
  done
  ! grep -rqsF "$T" $out $dev
''
