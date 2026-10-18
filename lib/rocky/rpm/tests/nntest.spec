# checks.nn-rpm-config: a tiny package built with rpmbuild -bb and the
# instantiated relocation config (%%_prefix = a fake /nix/store path).
Name:           nntest
Version:        1.0
Release:        1%{?dist}
Summary:        el-nixos relocation macro test
License:        MIT
%global debug_package %{nil}

%description
Installs into %{_bindir}, %{_libdir}, %{_datadir} (also through a literal
/usr path) and %{_sysconfdir}.

%prep
%setup -q -c -T
echo old > file.txt
# prep-hooks (NIX_PREP_PATCHES, NIX_PREP_SCRIPT) run after this, in this dir

%build
grep -qx patched file.txt
test "$(cat prep-marker)" = script
printf '#!/bin/sh\necho nntest\n' > nntest

%install
install -D -m 0755 nntest %{buildroot}%{_bindir}/nntest
mkdir -p %{buildroot}%{_libdir}/nntest
echo data > %{buildroot}%{_libdir}/nntest/data.txt
# hard-coded /usr: lands in the prefix through %%buildroot/usr -> prefix
mkdir -p %{buildroot}/usr/share/nntest
echo readme > %{buildroot}/usr/share/nntest/README
install -m 0644 file.txt %{buildroot}%{_datadir}/nntest/file.txt
mkdir -p %{buildroot}%{_sysconfdir}
echo conf > %{buildroot}%{_sysconfdir}/nntest.conf

%files
%{_bindir}/nntest
%dir %{_libdir}/nntest
%{_libdir}/nntest/data.txt
%{_datadir}/nntest/README
# named through the usr link: check-files must not report it as unpackaged
/usr/share/nntest/file.txt
%config(noreplace) %{_sysconfdir}/nntest.conf

%changelog
* Sun Oct 18 2026 el-nixos <el-nixos@localhost> - 1.0-1
- test package
