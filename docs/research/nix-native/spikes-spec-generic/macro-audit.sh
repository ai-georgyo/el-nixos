P=/nix/store/00000000000000000000000000000000-relocprefix-placeholder
rpm --showrc | grep -E '^-?[0-9]+[:=] ' | awk '{print $2}' | sed 's/(.*//' | sort -u > /builddir/names
echo "$(wc -l < /builddir/names) macros"
ev() { # $@ extra args
  while read -r n; do printf '%s\t' "$n"; v=$(rpm "$@" --eval "%{$n}" 2>/dev/null </dev/null || true); printf "%s\n" "${v//$'\n'/ }" | cut -c1-400; done < /builddir/names
}
ev > /builddir/out/default.tsv
ev --define "_prefix $P" > /builddir/out/prefix-only.tsv
rpm --showrc > /builddir/out/showrc.txt
ls /usr/lib/rpm/macros.d/ > /builddir/out/macrofiles.txt
grep -rn '/usr' /usr/lib/rpm/macros /usr/lib/rpm/macros.d/ /usr/lib/rpm/redhat/macros /usr/lib/rpm/platform/x86_64-linux/macros > /builddir/out/usr-in-macrofiles.txt || true
cat /usr/lib/rpm/brp-compress > /builddir/out/brp-compress; cat /usr/lib/rpm/check-files > /builddir/out/check-files || true
ls /usr/lib/rpm /usr/lib/rpm/redhat > /builddir/out/rpmdir.txt
