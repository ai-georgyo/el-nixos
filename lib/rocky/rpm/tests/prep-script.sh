# NIX_PREP_SCRIPT of checks.nn-rpm-config: runs in %{_builddir}/%{buildsubdir}
# after NIX_PREP_PATCHES
grep -qx patched file.txt
echo script > prep-marker
