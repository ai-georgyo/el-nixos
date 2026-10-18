# runs inside the stage0-full chroot as mockbuild; /inputs/which.src.rpm bound
set -euo pipefail
P=/nix/store/00000000000000000000000000000000-which-2.21-44.el10_0
D=(--define "_prefix $P" --define "_exec_prefix %{_prefix}" --define "_usr %{_prefix}"
   --define "_bindir %{_prefix}/bin" --define "_sbindir %{_prefix}/sbin" --define "_libdir %{_prefix}/lib64"
   --define "_libexecdir %{_prefix}/libexec" --define "_datadir %{_prefix}/share" --define "_includedir %{_prefix}/include"
   --define "_infodir %{_datadir}/info" --define "_mandir %{_datadir}/man"
   --define "_sysconfdir /etc" --define "_localstatedir /var" --define "_sharedstatedir /var/lib" --define "_rundir /run"
   --define "_rpmmacrodir %{_prefix}/lib/rpm/macros.d" --define "_sysusersdir %{_prefix}/lib/sysusers.d")
out=/builddir/out; mkdir -p $out
names="_prefix _exec_prefix _usr _bindir _sbindir _libdir _libexecdir _datadir _includedir _infodir _mandir _docdir _defaultdocdir _defaultlicensedir _sysconfdir _localstatedir _sharedstatedir _rundir _initddir _rpmconfigdir _rpmmacrodir _sysusersdir _usrsrc _fmoddir _pkgdocdir _unitdir _userunitdir _tmpfilesdir _udevrulesdir _pam_moduledir _bashcompletiondir python3_sitelib python3_sitearch perl_vendorlib perl_vendorarch __global_ldflags build_ldflags _hardening_ldflags _build_id_links _debugsource_path _debuginfo_path __debug_install_post"
{ for n in $names; do printf '%-22s default=%s\n%-22s reloc  =%s\n' "$n" "$(rpm --eval "%{?$n}")" "" "$(rpm "${D[@]}" --eval "%{?$n}")"; done; } > $out/macros.txt 2>&1
# hard-coded /usr in the macro files (not through %_prefix et al.)
grep -nE '(^|[^{_a-z])/usr/' /usr/lib/rpm/macros /usr/lib/rpm/redhat/macros /usr/lib/rpm/macros.d/* /usr/lib/rpm/platform/x86_64-linux/macros > $out/hardcoded-usr.txt || true
mkdir -p /builddir/build
set +e
rpmbuild --rebuild /inputs/which.src.rpm --define "_topdir /builddir/build" --define "dist .el10_0" --nodeps "${D[@]}" > $out/build.log 2>&1
echo "rc=$?" >> $out/build.log
set -e
cd /builddir/build/RPMS/x86_64
for f in *.rpm; do echo "== $f"; rpm -qlvp $f; rpm -qp --requires --provides $f | sed 's/^/   dep: /'; done > $out/files.txt
cp -r /builddir/build/RPMS $out/RPMS; grep -nE "brp-|check-buildroot|find-debuginfo|extracting debug|Wrote" $out/build.log > $out/brp.txt || true
mkdir -p /builddir/x && cd /builddir/x && rpm2cpio /builddir/build/RPMS/x86_64/which-2*.rpm | cpio -idm --quiet
find . -type f -name which -exec readelf -lhd {} \; > $out/elf.txt
grep -aoE '/[a-z]+/[A-Za-z0-9/._-]+' ./nix/store/*/bin/which | sort -u > $out/which-strings.txt || true
