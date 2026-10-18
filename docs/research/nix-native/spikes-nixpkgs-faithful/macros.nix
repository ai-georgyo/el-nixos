let
  f = builtins.getFlake "git+file:///run/host/home/ai-shammas/Code/el-nixos";
  r = f.legacyPackages.x86_64-linux;
  s0 = r.stage0;
  glibcSrc = s0.lib.unpackSrpm "glibc";
in s0.lib.runInBuildroot {
  name = "spike-macros";
  buildroot = r.packageSets.glibc.buildroot;
  binds = { "/inputs/glibc" = glibcSrc; };
  script = ''
    P=/nix/store/00000000000000000000000000000000-glibc-2.39-142.el10_2
    ms="_prefix _exec_prefix _bindir _sbindir _libdir _lib _libexecdir _datadir _datarootdir _includedir _oldincludedir _infodir _mandir _docdir _defaultdocdir _licensedir _sysconfdir _localstatedir _sharedstatedir _rundir _unitdir _userunitdir _rpmconfigdir _rpmmacrodir _usrsrc _initddir _tmpfilesdir _sysusersdir _pkgdocdir _javadir _var _usr _udevrulesdir _presetdir _modprobedir python3_sitelib python3_sitearch perl_vendorlib _fontbasedir _emacs_sitelispdir __python3 __perl __make __cc __cxx __cpp __awk __id_u _bindir_x"
    {
    echo "== defaults vs %_prefix=$P (only _prefix overridden)"
    for m in $ms; do
      a=$(rpm --eval "%{$m}" 2>/dev/null); b=$(rpm --define "_prefix $P" --eval "%{$m}" 2>/dev/null)
      printf '%-22s %-45s %s\n' "$m" "$a" "$b"
    done
    echo "== which macros are literal /usr (do NOT follow _prefix):"
    rpm --showrc | grep -E '^-[0-9]+[:=] _' | grep -E '\s/(usr|etc|var|run|lib)' | head -80
    echo "== redhat-rpm-config: literal /usr/lib/rpm refs"
    grep -rn '/usr/lib/rpm' /usr/lib/rpm/redhat/macros /usr/lib/rpm/macros.d/ 2>/dev/null | head -40
    echo "== build flags"
    rpm --eval '%{build_cflags}'; rpm --eval '%{build_ldflags}'
    echo "== macro file path"; rpm --showrc | grep -i 'macro path' -A2 | head
    } > /builddir/out/macros.txt 2>&1
    # rpmspec -P of glibc with relocation
    cp -r /inputs/glibc /builddir/src; chmod -R u+w /builddir/src
    rpmspec -P --define "_sourcedir /builddir/src" --define "dist .el10_2" --define "_prefix $P" --target x86_64 /builddir/src/glibc.spec > /builddir/out/glibc-P.spec 2>/builddir/out/rpmspec.err || true
    grep -nE '(^|[^a-zA-Z0-9_])/(usr|lib64|lib|bin|sbin)(/|\b)' /builddir/out/glibc-P.spec | grep -v '^[0-9]*:#' > /builddir/out/hardcoded-usr.txt || true
    rpmspec -q --define "_sourcedir /builddir/src" --define "dist .el10_2" --target x86_64 --qf '%{name}\n' /builddir/src/glibc.spec > /builddir/out/subpackages.txt 2>&1 || true
  '';
}
