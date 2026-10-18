set -uo pipefail
out=/builddir/out; mkdir -p $out
{ echo "== CLI define with newline:"; rpm --define "__spec_install_pre %{___build_pre}
ln -s FOLD" --eval '%{__spec_install_pre}' | tail -3
printf '%%__spec_install_pre %%{___build_pre}\\\n  ln -s nix/store/P "$RPM_BUILD_ROOT/usr"\n' > /builddir/m
echo "== macro file via --load:"; cat /builddir/m; rpm --load /builddir/m --eval '%{__spec_install_pre}' | tail -3
echo "== CLI define with escaped newline:"; rpm --define '__spec_install_pre %{___build_pre}\
ln -s FOLD2' --eval '%{__spec_install_pre}' | tail -3; } > $out/defs.txt 2>&1
