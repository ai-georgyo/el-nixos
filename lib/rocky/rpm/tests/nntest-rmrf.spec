# checks.nn-rpm-config: %%install starts with `rm -rf %%{buildroot}` (removing
# the usr link) and installs through a real %%{buildroot}/usr AND the prefix;
# fold-usr in %%__spec_install_post merges them before check-files.
Name:           nntest-rmrf
Version:        1.0
Release:        1%{?dist}
Summary:        el-nixos relocation macro test (rm -rf buildroot)
License:        MIT
%global debug_package %{nil}

%description
See nntest.spec.

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}/usr/bin %{buildroot}/usr/share/nntest-rmrf %{buildroot}%{_libdir}
printf '#!/bin/sh\necho rmrf\n' > %{buildroot}/usr/bin/nntest-rmrf
chmod 0755 %{buildroot}/usr/bin/nntest-rmrf
echo usr > %{buildroot}/usr/share/nntest-rmrf/from-usr
echo lib > %{buildroot}%{_libdir}/nntest-rmrf.txt
mkdir -p %{buildroot}%{_datadir}/nntest-rmrf
echo prefix > %{buildroot}%{_datadir}/nntest-rmrf/from-prefix

%files
%{_bindir}/nntest-rmrf
%{_libdir}/nntest-rmrf.txt
%{_datadir}/nntest-rmrf/

%changelog
* Sun Oct 18 2026 el-nixos <el-nixos@localhost> - 1.0-1
- test package
