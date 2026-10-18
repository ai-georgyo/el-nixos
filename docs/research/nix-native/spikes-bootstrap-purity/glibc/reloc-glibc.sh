# relocated glibc rpmbuild in the stage0 glibc buildroot (spike). Runs as mockbuild.
set +e; set -u
shopt -s nullglob
out=/builddir/out; mkdir -p $out
# install prefix: synthetic store path, padded to >= the longest output path
P=/nix/store/00000000000000000000000000000000-glibc-2.39-142.el10_2-xxxxxxxxxxxxxxxxxxxxxxxxxxx
cat > /builddir/config.site <<CS
# el-nixos: glibc's configure special-cases prefix=/usr; restore Rocky's layout for a relocated prefix
case "\$host_alias" in
i686*) libdir='\${exec_prefix}/lib'; libc_cv_slibdir=$P/lib; libc_cv_rtlddir=$P/lib ;;
*)     libdir='\${exec_prefix}/lib64'; libc_cv_slibdir=$P/lib64; libc_cv_rtlddir=$P/lib64 ;;
esac
libc_cv_complocaledir=$P/lib/locale
sysconfdir=/etc; libc_cv_sysconfdir=/etc
localstatedir=/var; libc_cv_localstatedir=/var
CS
mkdir -p /builddir/build/SPECS /builddir/build/SOURCES
rpm -i --define "_topdir /builddir/build" /inputs/glibc.src.rpm 2>/dev/null
spec=/builddir/build/SPECS/glibc.spec
# spec rewrite: kernel headers are not under the package's own prefix
grep -c -- '--with-headers=%{_prefix}/include' $spec > $out/spec-rewrite-count.txt
sed -i 's|--with-headers=%{_prefix}/include|--with-headers=/usr/include|' $spec
D=(--define "_prefix $P" --define "_exec_prefix %{_prefix}" --define "_usr %{_prefix}"
   --define "_bindir %{_prefix}/bin" --define "_sbindir %{_prefix}/sbin" --define "_libdir %{_prefix}/lib64"
   --define "_libexecdir %{_prefix}/libexec" --define "_datadir %{_prefix}/share" --define "_includedir %{_prefix}/include"
   --define "_infodir %{_datadir}/info" --define "_mandir %{_datadir}/man"
   --define "_sysconfdir /etc" --define "_localstatedir /var" --define "_sharedstatedir /var/lib" --define "_rundir /run"
   --define "_rpmmacrodir %{_prefix}/lib/rpm/macros.d"
   --define "__brp_compress /usr/lib/rpm/brp-compress %{_prefix}"
   --define "_binary_payload w0.ufdio" --define "_unpackaged_files_terminate_build 0"
   --define "__spec_install_pre %{___build_pre}\\
%{__rm} -rf \"%{buildroot}\"\\
%{__mkdir_p} \"%{dirname:%{buildroot}}\"\\
%{__mkdir} \"%{buildroot}\"\\
ln -s ${P#/} \"%{buildroot}/usr\"; mkdir -p \"%{buildroot}$P\""
   --define "_annotated_build 0" --define "_annobin_gcc_plugin %{nil}"
   --define "dist .el10_2" --define "_topdir /builddir/build" --define "_smp_build_ncpus $(nproc)")
set +e
CONFIG_SITE=/builddir/config.site rpmbuild -bb --nocheck --nodeps --target x86_64 "${D[@]}" $spec > /builddir/build.log 2>&1
rc=$?
set +e
echo "rc=$rc" > $out/rc.txt
tail -n 150 /builddir/build.log > $out/build-tail.log
grep -nE "^\+ .*(ldconfig|localedef|iconvconfig)|No such file|not found|error:|Error " /builddir/build.log | head -100 > $out/errors.txt || true
grep -E "^(checking for|configure:).*(slibdir|rtlddir|sysconfdir|libdir)" /builddir/build.log | head > $out/configure.txt || true
ls -R /builddir/build/BUILDROOT 2>/dev/null | head -100 > $out/buildroot-ls.txt || true
find /builddir/build/BUILDROOT -maxdepth 6 -type d 2>/dev/null | head -60 > $out/buildroot-dirs.txt || true
cp /builddir/build.log $out/build.log; sed -n "/Installed (but unpackaged)/,/^RPM build warnings/p" /builddir/build.log > $out/unpackaged.txt
if true; then
  for f in /builddir/build/RPMS/*/*.rpm; do n=$(rpm -qp --qf '%{NAME}' $f); rpm -qlp $f | sed "s|^|$n |"; done > $out/filelists.txt
fi

BR=/builddir/build/BUILDROOT/glibc-2.39-142.el10_2.x86_64
{ readelf -l $BR$P/bin/getent | grep interpreter; readelf -d $BR$P/bin/getent | grep -E "RUNPATH|RPATH|NEEDED"
  strings -a $BR$P/lib64/libc.so.6 | grep -E "^/(nix|etc|usr|bin)" | sort -u
  strings -a $BR$P/lib64/ld-linux-x86-64.so.2 | grep -E "^/(nix|etc|usr)" | sort -u
  ls -la $BR $BR$P; } > $out/elf-facts.txt 2>&1
exit 0
