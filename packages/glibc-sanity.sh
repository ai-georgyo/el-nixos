# Post-build sanity checks of the stage0 glibc rpmbuild (packages/glibc.nix).
# Runs inside the glibc buildroot as mockbuild.  Inputs (read-only binds):
#   /inputs/build      buildSrpm result (RPMS/, SRPMS/)
#   /inputs/logs       its logs output (build.log, srpm.log, files, purity.json)
#   /inputs/expected   "name arch epoch version release shipped|unshipped" per line
#   /inputs/official/  official Rocky RPMs of a few subpackages (comparison only)
# Output: /builddir/out/report.txt (+ details).  Hard failures exit non-zero;
# everything marked "info" is reported only.
set -euo pipefail
out=/builddir/out
mkdir -p $out
R=$out/report.txt
: > $R
fail=0
say() { echo "$*" | tee -a $R; }
bad() { say "FAIL: $*"; fail=1; }
ok() { say "ok:   $*"; }

B=/inputs/build
log=/inputs/logs/build.log

# ---------------------------------------------------------------- RPM set + NEVRs
say "== RPM set"
for f in $B/RPMS/*/*.rpm; do
  rpm -qp --nosignature --qf '%{NAME} %{ARCH} %{EPOCHNUM} %{VERSION} %{RELEASE}\n' "$f"
done | sort > $out/built.txt
sort /inputs/expected > $out/expected.txt
nbuilt=$(wc -l < $out/built.txt)
nship=$(grep -c ' shipped$' $out/expected.txt)
say "built $nbuilt binary RPMs; lock lists $nship shipped"
missing=0
while read -r n a ep v r kind; do
  got=$(awk -v n="$n" '$1 == n' $out/built.txt)
  if [ -z "$got" ]; then bad "missing $kind package $n"; missing=$((missing+1)); continue; fi
  if [ "$got" != "$n $a $ep $v $r" ]; then bad "$n: built '$got', official '$n $a $ep $v $r'"; fi
done < $out/expected.txt
[ $missing = 0 ] && ok "all $nship shipped + $(grep -c ' unshipped$' $out/expected.txt) known unshipped packages built, NEVRA equal to the official ones"
awk '{print $1}' $out/expected.txt > $out/expected-names.txt
extra=$(awk '{print $1}' $out/built.txt | grep -vxF -f $out/expected-names.txt || true)
nonDebugExtra=$(grep -vE -- '-debug(info|source)$' <<<"$extra" | grep . || true)
[ -z "$nonDebugExtra" ] && ok "no unexpected non-debug packages" || bad "unexpected packages: $nonDebugExtra"
say "info: debug packages: $(grep -cE -- '-debug(info|source)$' <<<"$extra" || true): $(grep -E -- '-debug(info|source)$' <<<"$extra" | tr '\n' ' ')"
rpm -qp --nosignature --qf '%{SOURCERPM} %{BUILDHOST} %{BUILDTIME} payload=%{PAYLOADCOMPRESSOR}/%{PAYLOADFLAGS}\n' $B/RPMS/x86_64/glibc-2.*.x86_64.rpm | sed 's/^/info: glibc header: /' | tee -a $R

# ---------------------------------------------------------------- kernel headers
say "== kernel headers"
if kh=$(rpm -q kernel-headers 2>/dev/null); then
  ok "buildroot has $kh in the rpmdb"
  sysroot=$(ls $B/RPMS/noarch/sysroot-x86_64-el10-glibc-*.rpm)
  rpm -ql kernel-headers | grep '^/usr/include/.*\.h$' | sort > $out/kernel-headers.h.txt
  rpm -qlp --nosignature "$sysroot" | sed -n 's|^/usr/x86_64-redhat-linux/sys-root/el10||p' | grep '^/usr/include/.*\.h$' | sort > $out/sysroot-headers.h.txt
  nmiss=$(comm -23 $out/kernel-headers.h.txt $out/sysroot-headers.h.txt | wc -l)
  if [ "$nmiss" = 0 ]; then ok "sysroot-x86_64-el10-glibc contains all $(wc -l < $out/kernel-headers.h.txt) kernel-headers .h files (rpm -ql kernel-headers in the spec)"
  else bad "sysroot-x86_64-el10-glibc lacks $nmiss kernel-headers files"; fi
else
  say "info: no kernel-headers RPM in the buildroot (stage0 headers); sysroot package has no kernel headers"
fi

# ---------------------------------------------------------------- configure results
say "== configure (from build.log; 32-bit build first, then x86_64)"
for pat in 'checking for libgd\.\.\. ' 'checking for is_selinux_enabled in -lselinux\.\.\. ' \
           'checking for audit_log_user_avc_message in -laudit\.\.\. ' 'checking for cap_init in -lcap\.\.\. ' \
           'checking for maximum supported _FORTIFY_SOURCE level\.\.\. ' 'checking for systemtap static probe support\.\.\. ' \
           'checking for bash\.\.\. ' 'checking for perl\.\.\. ' 'checking for python3\.\.\. ' \
           'checking for msgfmt\.\.\. ' 'checking for makeinfo\.\.\. ' 'checking whether gcc .*builds a 32-bit|checking for gcc\.\.\. '; do
  say "info: $(grep -E "$pat" $log | sed -E "s/^(checking for |checking )//" | tr '\n' '|')"
done
need() { if grep -qE "$1" $log; then ok "build.log: $2"; else bad "build.log lacks: $2"; fi; }
need '^checking for libgd\.\.\. yes' "LIBGD = yes"
need '^checking for is_selinux_enabled in -lselinux\.\.\. yes' "have-selinux = yes"
need '^checking for audit_log_user_avc_message in -laudit\.\.\. yes' "have-libaudit = yes"
need '^checking for cap_init in -lcap\.\.\. yes' "have-libcap = yes"
need '^checking for maximum supported _FORTIFY_SOURCE level\.\.\. 3' "fortify level 3"
grep -qE '^checking for maximum supported _FORTIFY_SOURCE level\.\.\. 2' $log && bad "a configure run found fortify level 2"
need '^checking for systemtap static probe support\.\.\. yes' "systemtap probes"
need '^checking for bash\.\.\. /usr/bin/bash$' "BASH_SHELL = /usr/bin/bash"
need '^checking for perl\.\.\. /usr/bin/perl$' "PERL = /usr/bin/perl"
grep -qE '^checking for (bash|perl|python3?|msgfmt|makeinfo|gawk|bison|make|gcc)\.\.\. /nix/store' $log && bad "configure found a tool in /nix/store"
if grep -q 'annobin' $log; then
  say "info: 'annobin' occurs $(grep -c annobin $log) times in build.log, e.g.: $(grep -m3 annobin $log | cut -c1-200 | tr '\n' '|')"
fi
if grep -qE -- '-fplugin=annobin|-specs=/usr/lib/rpm/redhat/redhat-annobin-cc1' $log; then bad "annobin plugin flags used"; else ok "no annobin plugin flags in compile commands"; fi
grep -E -- '--disable-werror' $log >/dev/null && bad "--disable-werror was used" || ok "werror on (no --disable-werror)"
grep -m1 -E '^model name|^flags' $log | cut -c1-120 | sed 's/^/info: builder cpu: /' | tee -a $R || true
grep -m1 -oE 'make -O -j[0-9]+' $log | sed 's/^/info: main build: /' | tee -a $R || true
say "info: signals ignored in the chroot (SigIgn): $(grep SigIgn /proc/self/status | tr -s '\t ' ' ')"

# ---------------------------------------------------------------- payload checks
say "== payloads"
mkdir -p /builddir/x /builddir/dbg
for f in $B/RPMS/*/*.rpm; do
  n=$(rpm -qp --nosignature --qf '%{NAME}' "$f")
  case $n in *-debuginfo|*-debugsource) d=/builddir/dbg/$n ;; *) d=/builddir/x/$n ;; esac
  mkdir -p $d && (cd $d && rpm2cpio "$f" | cpio -idm --quiet --no-absolute-filenames)
done
X=/builddir/x
U=$X/glibc-utils/usr/bin
if [ -f $U/memusagestat ]; then
  needed=$(readelf -dW $U/memusagestat | sed -nE 's/.*\(NEEDED\).*\[(.*)\]/\1/p' | sort | tr '\n' ' ')
  [ "$needed" = "libc.so.6 libgd.so.3 libm.so.6 libpng16.so.16 libz.so.1 " ] && ok "memusagestat NEEDED: $needed" || bad "memusagestat NEEDED: $needed"
else bad "no memusagestat"; fi
M=$X/nss_db/usr/bin/makedb
md=$(readelf -dW $M; readelf -VW $M)  # (no `| grep -q`: with pipefail an early grep exit SIGPIPEs readelf)
if grep -q 'NEEDED.*libselinux.so.1' <<<"$md" && grep -q LIBSELINUX_1.0 <<<"$md"; then ok "makedb links libselinux.so.1 (LIBSELINUX_1.0)"; else bad "makedb not linked with libselinux"; fi
for s in ldd sotruss xtrace memusage tzselect mtrace; do
  p=$(ls $X/*/usr/bin/$s 2>/dev/null | head -n1)
  [ -n "$p" ] || { bad "$s not packaged"; continue; }
  say "info: $s: $(head -n1 $p)"
done
for s in ldd sotruss xtrace memusage tzselect; do
  [ "$(head -n1 $X/*/usr/bin/$s)" = '#!/usr/bin/bash' ] || bad "$s shebang"
done
[ "$(head -n1 $U/mtrace)" = '#!/usr/bin/sh' ] && ok "shebangs: #!/usr/bin/bash (ldd sotruss xtrace memusage tzselect), #!/usr/bin/sh (mtrace)" || bad "mtrace shebang"
L=$X/glibc/usr/lib64/libc.so.6
nstap=$(readelf -nW $L | grep -c 'NT_STAPSDT' || true)
[ "$nstap" -gt 0 ] && ok "libc.so.6: $nstap stapsdt probes (official: 79)" || bad "libc.so.6 has no stapsdt notes"
readelf -nW $L | grep -E 'x86 (feature|ISA needed)' | sed 's/^ */info: libc.so.6 property: /' | tee -a $R
grep -q 'x86 feature: IBT, SHSTK' <<<"$(readelf -nW $L)" && ok "libc.so.6: IBT, SHSTK" || bad "libc.so.6 lacks IBT/SHSTK"
say "info: libc.so.6 sections: $(readelf -SW $L | sed -nE 's/^ *\[ *[0-9]+\] ([^ ]+) .*/\1/p' | tr '\n' ' ')"
say "info: ld.so sections: $(readelf -SW $X/glibc/usr/lib64/ld-linux-x86-64.so.2 | sed -nE 's/^ *\[ *[0-9]+\] ([^ ]+) .*/\1/p' | tr '\n' ' ')"
say "info: libc.so.6 .comment: $(readelf -p .comment $L | sed -nE 's/^ *\[ *[0-9a-f]+\] *//p' | sort -u | tr '\n' '|')"

# every ELF: build-id, no RPATH/RUNPATH, standard interpreter
nelf=0; : > $out/elf-problems.txt
while IFS= read -r -d '' f; do
  head -c4 "$f" 2>/dev/null | grep -q ELF || continue
  case $f in *.o|*.a) continue ;; esac
  nelf=$((nelf+1))
  h=$(readelf -lndW "$f" 2>/dev/null || true)
  grep -q 'Build ID' <<<"$h" || echo "no build-id: ${f#$X/}" >> $out/elf-problems.txt
  # gconv modules carry RPATH $ORIGIN (libGB.so, libJIS.so, ... next to them), as in Rocky's
  rp=$(sed -nE 's/.*\((RPATH|RUNPATH)\).*\[(.*)\]/\1=\2/p' <<<"$h")
  case $rp in ''|'RPATH=$ORIGIN') ;; *) echo "rpath $rp: ${f#$X/}" >> $out/elf-problems.txt ;; esac
  [ -n "$rp" ] && echo "$rp ${f#$X/}" >> $out/rpaths.txt
  i=$(sed -nE 's/.*Requesting program interpreter: (.*)\]/\1/p' <<<"$h")
  case $i in ''|/lib64/ld-linux-x86-64.so.2|/lib/ld-linux.so.2) ;; *) echo "interp $i: ${f#$X/}" >> $out/elf-problems.txt ;; esac
done < <(find $X -type f -print0)
if [ -s $out/elf-problems.txt ]; then
  # glibc32 / sysroot ship stripped/unlinked objects; report, fail only for shipped packages
  say "info: ELF problems ($(wc -l < $out/elf-problems.txt)): $(head -n 20 $out/elf-problems.txt | tr '\n' '|')"
  grep -vE '^[^:]*: (glibc32|sysroot-x86_64-el10-glibc|compat-libpthread-nonshared)/' $out/elf-problems.txt > $out/elf-problems-shipped.txt || true
  [ -s $out/elf-problems-shipped.txt ] && bad "ELF problems in shipped packages (see elf-problems.txt)"
fi
ok "$nelf ELF files checked (build-id, RPATH/RUNPATH, PT_INTERP)"

# /nix/store anywhere
if grep -rlF /nix/store $X > $out/store-refs.txt; then bad "/nix/store in non-debug payloads: $(head -n 10 $out/store-refs.txt | tr '\n' ' ')"; else ok "no /nix/store string in any non-debug payload"; fi
if grep -rlF /nix/store /builddir/dbg > $out/store-refs-debug.txt; then
  say "info: /nix/store occurs in $(wc -l < $out/store-refs-debug.txt) debuginfo/debugsource files (see store-refs-debug.txt)"
  # what kind of store paths (hash-stripped)
  grep -rhoaE '/nix/store/[a-z0-9]{32}-[^/ "]+' /builddir/dbg | sed -E 's|/nix/store/[a-z0-9]{32}-|/nix/store/<hash>-|' | sort | uniq -c | sort -rn > $out/store-refs-debug-kinds.txt || true
  sed 's/^/info:   /' $out/store-refs-debug-kinds.txt | tee -a $R
else ok "no /nix/store string in debuginfo/debugsource payloads"; fi
sed -i -E 's|/nix/store/[a-z0-9]{32}-|/nix/store/<hash>-|g' $out/*.txt

# ---------------------------------------------------------------- vs official (info)
say "== vs official RPMs (info only; the parity checker track does the full comparison)"
for o in /inputs/official/*.rpm; do
  [ -e "$o" ] || continue
  n=$(rpm -qp --nosignature --qf '%{NAME}' "$o")
  m=$(ls $B/RPMS/*/"$n"-[0-9]*.rpm 2>/dev/null | head -n1)
  [ -n "$m" ] || { say "info: $n: not built"; continue; }
  for q in list requires provides; do
    case $q in list) qa=(-ql) ;; requires) qa=(--requires) ;; provides) qa=(--provides) ;; esac
    rpm -qp --nosignature "${qa[@]}" "$o" | sort > $out/off.$n.$q
    rpm -qp --nosignature "${qa[@]}" "$m" | sort > $out/our.$n.$q
  done
  # build-id link names necessarily differ
  dl=$(diff <(grep -v /.build-id/ $out/off.$n.list) <(grep -v /.build-id/ $out/our.$n.list) | grep -c '^[<>]' || true)
  dr=$(diff $out/off.$n.requires $out/our.$n.requires | grep -c '^[<>]' || true)
  dp=$(diff $out/off.$n.provides $out/our.$n.provides | grep -c '^[<>]' || true)
  say "info: $n: files $(wc -l < $out/off.$n.list)/$(wc -l < $out/our.$n.list) (official/ours), diff lines: files(no .build-id) $dl, requires $dr, provides $dp"
  { echo "### $n"; diff <(grep -v /.build-id/ $out/off.$n.list) <(grep -v /.build-id/ $out/our.$n.list) || true
    diff $out/off.$n.requires $out/our.$n.requires || true; diff $out/off.$n.provides $out/our.$n.provides || true; } >> $out/official-diff.txt
  rm -f $out/off.$n.* $out/our.$n.*
done

say "== result: $([ $fail = 0 ] && echo PASS || echo FAIL)"
exit $fail
