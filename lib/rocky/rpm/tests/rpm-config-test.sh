# checks.nn-rpm-config (lib/rocky/checks/rpm-config.nix): the relocation
# rpm config, its helper scripts and lib/rocky/config.site.
# Environment: $cfg (rpmConfig with the systemd stand-in macro dir), $farm
# (bin/ = tools for the shim: stage0 rpm + bootstrap tools), $tests (this
# directory), $configSite, $out.
set -euo pipefail
shopt -s inherit_errexit
mkdir -p "$out"
log=$out/results.txt
fails=0
ok()   { echo "ok   $*" >> "$log"; }
bad()  { echo "FAIL $*" >> "$log"; echo "FAIL $*" >&2; fails=$((fails + 1)); }
# expect NAME GOT WANT
expect() { if [ "$2" = "$3" ]; then ok "$1 = $3"; else bad "$1: got '$2', want '$3'"; fi; }
# contains NAME HAYSTACK NEEDLE
contains() { if grep -qF -- "$3" <<<"$2"; then ok "$1 contains '$3'"; else bad "$1: '$3' not in: $2"; fi; }
lacks() { if grep -qF -- "$3" <<<"$2"; then bad "$1: unexpected '$3' in: $2"; else ok "$1 lacks '$3'"; fi; }

B=$NIX_BUILD_TOP
P=/nix/store/00000000000000000000000000000000-nn-rpm-config-test-1.0
cores=3

# ---- the shim: /usr/bin = tool farm, /usr/lib/rpm = an instantiated config ----
# usage: inshim CONFIGDIR CMD...
inshim() {
  local c=$1; shift
  bwrap --ro-bind /nix /nix --bind "$B" "$B" --ro-bind /etc /etc --proc /proc --dev /dev \
    --tmpfs /tmp --ro-bind "$farm/bin" /usr/bin --symlink usr/bin /bin --symlink usr/bin /sbin \
    --symlink bin /usr/sbin --ro-bind "$c" /usr/lib/rpm \
    --setenv PATH /usr/bin --setenv HOME "$B/home" --setenv TMPDIR /tmp --chdir "$B" \
    -- "$@"
}
mkdir -p "$B/home"

# ---- 1. instantiation ------------------------------------------------------
sh "$cfg/nix/instantiate" "$B/cfg" --prefix "$P" --buildtop "$B" --ncpus $cores --dist .el10_2
sh "$cfg/nix/instantiate" "$B/cfg-nodist" --prefix "$P" --buildtop "$B" --ncpus $cores
if grep -q '@[A-Z]*@' "$B/cfg/redhat/macros"; then bad "placeholders left in redhat/macros"; else ok "instantiated without placeholders"; fi
if sh "$cfg/nix/instantiate" "$B/cfg-bad" --prefix relative --buildtop "$B" --ncpus 1 2>/dev/null; then
  bad "instantiate accepted a relative prefix"; else ok "instantiate rejects a relative prefix"; fi
# NIX_RPM_MACRO_DIRS: a differing file of an existing name is an error
mkdir -p "$B/md"; echo '%dist .broken' > "$B/md/macros.dist"
if NIX_RPM_MACRO_DIRS=$B/md sh "$cfg/nix/instantiate" "$B/cfg-md" --prefix "$P" --buildtop "$B" --ncpus 1 2>/dev/null; then
  bad "instantiate accepted a conflicting macros.dist"; else ok "instantiate rejects a conflicting macro file"; fi
rm -rf "$B/md" "$B/cfg-md"; mkdir -p "$B/md"; echo '%nn_extra_macro %{_prefix}/extra' > "$B/md/macros.nn-extra"
NIX_RPM_MACRO_DIRS=$B/md sh "$cfg/nix/instantiate" "$B/cfg-md" --prefix "$P" --buildtop "$B" --ncpus 1
expect "NIX_RPM_MACRO_DIRS macro" "$(inshim "$B/cfg-md" rpm --eval '%{nn_extra_macro}')" "$P/extra"

ev() { inshim "$B/cfg" rpm --eval "$1"; }

# ---- 2. macro path: the relocation file must be read last -----------------
mp=$(inshim "$B/cfg" rpm --showrc | sed -n 's/^Macro path: //p')
echo "macro path: $mp" >> "$log"
case $mp in
  */usr/lib/rpm/macros.d/macros.*:*/usr/lib/rpm/platform/%{_target}/macros:*/usr/lib/rpm/redhat/macros:*)
    ok "macro path: macros.d < platform < redhat/macros" ;;
  *) bad "unexpected macro path: $mp" ;;
esac
# negative control: the same instantiated file as macros.d/macros.zz-nix-reloc
# (the design's first placement) is overridden by platform/x86_64-linux/macros
# and redhat/macros
cp -RP "$cfg/." "$B/cfg-macrosd"; chmod -R u+w "$B/cfg-macrosd"
cp "$B/cfg/nix/macros.nix-reloc" "$B/cfg-macrosd/macros.d/macros.zz-nix-reloc"
expect "macros.d placement: %_prefix" "$(inshim "$B/cfg-macrosd" rpm --eval '%{_prefix}')" "/usr"
expect "macros.d placement: %__brp_compress" "$(inshim "$B/cfg-macrosd" rpm --eval '%{__brp_compress}')" "/usr/lib/rpm/brp-compress"
expect "macros.d placement: %_binary_payload" "$(inshim "$B/cfg-macrosd" rpm --eval '%{_binary_payload}')" "w19.zstdio"
# a relocated macro package (rpmConfig macroPkgs, lib/rpm/macros.d)
expect "relocated macro package" "$(ev '%{nn_relocated_macro_pkg}')" "$P/share/nn"

# ---- 3. every macro of design §1.2 -----------------------------------------
while IFS='|' read -r m want; do
  [ -n "$m" ] || continue
  want=${want//@P@/$P}; want=${want//@B@/$B}; want=${want//@N@/$cores}
  expect "%$m" "$(ev "%{$m}")" "$want"
done <<'EOF'
_prefix|@P@
_exec_prefix|@P@
_usr|@P@
_prefix_rel|nix/store/00000000000000000000000000000000-nn-rpm-config-test-1.0
_lib|lib64
_bindir|@P@/bin
_sbindir|@P@/sbin
_libdir|@P@/lib64
_libexecdir|@P@/libexec
_datadir|@P@/share
_datarootdir|@P@/share
_includedir|@P@/include
_infodir|@P@/share/info
_mandir|@P@/share/man
_defaultdocdir|@P@/share/doc
_defaultlicensedir|@P@/share/licenses
_oldincludedir|@P@/include
_sysusersdir|@P@/lib/sysusers.d
_rpmmacrodir|@P@/lib/rpm/macros.d
rpmmacrodir|@P@/lib/rpm/macros.d
_rpmluadir|@P@/lib/rpm/lua
_fontbasedir|@P@/share/fonts
_fontconfig_templatedir|@P@/share/fontconfig/conf.avail
_pam_moduledir|@P@/lib64/security
gopath|@P@/share/gocode
_unitdir|@P@/lib/systemd/system
_userunitdir|@P@/lib/systemd/user
_presetdir|@P@/lib/systemd/system-preset
_udevrulesdir|@P@/lib/udev/rules.d
_tmpfilesdir|@P@/lib/tmpfiles.d
_modprobedir|@P@/lib/modprobe.d
_sysconfdir|/etc
_localstatedir|/var
_sharedstatedir|/var/lib
_rundir|/run
_runstatedir|/run
_initddir|/etc/rc.d/init.d
_pam_confdir|/etc/pam.d
_usrsrc|/usr/src
_dbpath|/usr/lib/sysimage/rpm
_rpmconfigdir|/usr/lib/rpm
__perl|/usr/bin/perl
__python3|/usr/bin/python3
__plugindir|/usr/lib64/rpm-plugins
_buildshell|/bin/sh
_topdir|@B@/rpmbuild
_tmppath|@B@/tmp
_smp_build_ncpus|@N@
_binary_payload|w0.ufdio
_source_payload|w0.ufdio
dist|.el10_2
distcore|.el10_2
_buildhost|el-nixos.localdomain
source_date_epoch_from_changelog|1
use_source_date_epoch_as_buildtime|1
clamp_mtime_to_source_date_epoch|1
__brp_compress|/usr/lib/rpm/brp-compress @P@
_annobin_gcc_plugin|
_unpackaged_files_terminate_build|1
EOF
expect "%dist (no --dist: macros.dist's %distcore)" "$(inshim "$B/cfg-nodist" rpm --eval '%{dist}')" ".el10"
expect "%dist with bootstrap bcond" "$(inshim "$B/cfg" rpm --define 'with_bootstrap 1' --eval '%{dist}')" ".el10_2~bootstrap"
expect "%_rpmconfigdir follows RPM_CONFIGDIR outside the shim" \
  "$(RPM_CONFIGDIR=$B/cfg "$farm/bin/rpm" --eval "%{_rpmconfigdir}" 2>/dev/null)" "$B/cfg"

contains "%__check_files" "$(ev '%{__check_files}')" "/usr/lib/rpm/nix/check-files $B/rpmbuild/BUILDROOT/"
lacks "%__check_files" "$(ev '%{__check_files}')" "/usr/lib/rpm/check-files"
expect "%__check_files prefix arg" "$(ev '%{__check_files}' | awk '{print $NF}')" "$P"

# multi-line hooks
v=$(ev '%{__spec_install_pre}')
contains "%__spec_install_pre" "$v" "/usr/lib/rpm/nix/fold-usr \"\$RPM_BUILD_ROOT\" \"$P\""
contains "%__spec_install_pre" "$v" 'rm -rf "${RPM_BUILD_ROOT}"'
contains "%__spec_install_pre (set_build_flags kept)" "$v" 'CFLAGS="${CFLAGS:-'
v=$(ev '%{__spec_install_post}')
expect "%__spec_install_post line 1" "$(head -n1 <<<"$v" | sed 's/[[:space:]]*$//')" "/usr/lib/rpm/nix/fold-usr \"\$RPM_BUILD_ROOT\" \"$P\""
contains "%__spec_install_post" "$v" "/usr/lib/rpm/check-buildroot"
contains "%__spec_install_post" "$v" "/usr/lib/rpm/brp-compress $P"
contains "%__spec_install_post" "$v" "/usr/lib/rpm/redhat/brp-mangle-shebangs"
v=$(ev '%{__spec_prep_post}')
hl=$(grep -n 'nix/prep-hooks' <<<"$v" | cut -d: -f1 || true)
el=$(grep -n 'exit \${RPM_EC}' <<<"$v" | cut -d: -f1 || true)
if [ -n "$hl" ] && [ -n "$el" ] && [ "$hl" -lt "$el" ]; then ok "%__spec_prep_post: prep-hooks before exit \$RPM_EC"
else bad "%__spec_prep_post order: $v"; fi

# compiler flags: Rocky's, without the annobin plugin
v=$(ev '%{optflags}')
[ -n "$v" ] && ok "%optflags non-empty" || bad "%optflags empty"
contains "%optflags" "$v" "-O2"
contains "%optflags" "$v" "-specs=/usr/lib/rpm/redhat/redhat-hardened-cc1"
contains "%optflags" "$v" "-march=x86-64-v3"
lacks "%optflags" "$v" "annobin"
contains "%build_ldflags" "$(ev '%{build_ldflags}')" "-Wl,-z,relro"
contains "%configure" "$(ev '%{configure}')" "--libdir=$P/lib64"
contains "%configure" "$(ev '%{configure}')" "--sysconfdir=/etc"
contains "%configure" "$(ev '%{configure}')" "--localstatedir=/var"

# ---- 4. macro audit: every non-parametric macro, Rocky config vs relocated --
# (report only; written to $out/macro-audit.tsv)
inshim "$B/cfg" rpm --showrc | sed -n 's/^ *-\{0,1\}[0-9]*[:=] \([A-Za-z_][A-Za-z0-9_]*\)\t.*/\1/p' \
  | LC_ALL=C sort -u > "$B/macro-names"
audit() { # CONFIGDIR -> name<TAB>value lines
  inshim "$1" rpm --eval "%{lua:
    for n in io.lines('$B/macro-names') do
      local okk, v = pcall(rpm.expand, '%' .. '{' .. n .. '}')
      if not okk then v = '<error>' end
      io.write(n, '\t', (v:gsub('[\n\t]', ' ')), '\n')
    end}" 2>/dev/null
}
audit "$cfg" > "$B/audit-rocky"
audit "$B/cfg" > "$B/audit-reloc"
LC_ALL=C join -t $'\t' "$B/audit-rocky" "$B/audit-reloc" | awk -F'\t' '$2 != $3' > "$out/macro-audit.tsv"
echo "macro audit: $(wc -l < "$B/macro-names") macros, $(wc -l < "$out/macro-audit.tsv") differ (macro-audit.tsv)" >> "$log"
# changed values that point into /usr (other than tools, rpm's own dirs) are suspects
awk -F'\t' '$3 ~ /^\/usr\// && $3 !~ /^\/usr\/(bin|lib\/rpm|src|lib\/sysimage)\//' "$out/macro-audit.tsv" > "$out/macro-audit-usr.tsv"
[ -s "$out/macro-audit-usr.tsv" ] && bad "changed macros pointing into /usr: $(cut -f1 "$out/macro-audit-usr.tsv" | tr '\n' ' ')" \
  || ok "no relocated macro newly points into /usr"

# ---- 5. fold-usr unit tests --------------------------------------------------
fold() { bash "$cfg/nix/fold-usr" "$@"; }
T=$B/fold
# a) plain: empty buildroot
mkdir -p "$T/a"
fold "$T/a" "$P"
expect "fold-usr plain: link" "$(readlink "$T/a/usr")" "${P#/}"
[ -d "$T/a$P" ] && ok "fold-usr plain: prefix dir" || bad "fold-usr plain: no $T/a$P"
mkdir -p "$T/a/usr/bin" && echo x > "$T/a/usr/bin/x"
[ -f "$T/a$P/bin/x" ] && ok "fold-usr plain: /usr/x lands in prefix" || bad "fold-usr plain: link does not resolve"
fold "$T/a" "$P" && ok "fold-usr idempotent" || bad "fold-usr second run failed"
# b) rm -rf'd buildroot with a real usr dir, overlapping directories
mkdir -p "$T/b/usr/share/doc/a" "$T/b/usr/bin" "$T/b$P/share/doc/b" "$T/b$P/lib64" "$T/b/etc"
echo 1 > "$T/b/usr/bin/tool"; echo 2 > "$T/b/usr/share/doc/a/README"; echo 3 > "$T/b/usr/.hidden"
echo 4 > "$T/b$P/share/doc/b/README"; echo 5 > "$T/b$P/lib64/libx.so"; echo 6 > "$T/b/etc/conf"
ln -s tool "$T/b/usr/bin/tool-link"
fold "$T/b" "$P" 2>/dev/null
expect "fold-usr merge: link" "$(readlink "$T/b/usr")" "${P#/}"
got=$(cd "$T/b$P" && find . ! -type d | LC_ALL=C sort | tr '\n' ' ')
expect "fold-usr merge: files" "$got" "./.hidden ./bin/tool ./bin/tool-link ./lib64/libx.so ./share/doc/a/README ./share/doc/b/README "
expect "fold-usr merge: symlink kept" "$(readlink "$T/b$P/bin/tool-link")" "tool"
[ -f "$T/b/etc/conf" ] && [ ! -L "$T/b/etc" ] && ok "fold-usr merge: etc untouched" || bad "fold-usr merge: etc changed"
# c) conflict: the same file under usr and under the prefix
mkdir -p "$T/c/usr/bin" "$T/c$P/bin"; echo a > "$T/c/usr/bin/x"; echo b > "$T/c$P/bin/x"
if fold "$T/c" "$P" 2> "$T/c.err"; then bad "fold-usr conflict not detected"
else contains "fold-usr conflict message" "$(cat "$T/c.err")" "/usr/bin/x"; fi
expect "fold-usr conflict: prefix file untouched" "$(cat "$T/c$P/bin/x")" "b"
# d) a wrong usr symlink
mkdir -p "$T/d"; ln -s /usr "$T/d/usr"
if fold "$T/d" "$P" 2>/dev/null; then bad "fold-usr accepted usr -> /usr"; else ok "fold-usr rejects a foreign usr link"; fi
# e) prefix /usr: no-op
mkdir -p "$T/e"; fold "$T/e" /usr; [ ! -e "$T/e/usr" ] && ok "fold-usr /usr no-op" || bad "fold-usr /usr created something"

# ---- 6. check-files unit tests ------------------------------------------------
cf() { sh "$cfg/nix/check-files" "$@"; }
BR=$B/cf/BUILDROOT/x-1-1.x86_64
mkdir -p "$BR"; fold "$BR" "$P"
mkdir -p "$BR$P/bin" "$BR$P/share/x" "$BR/etc"
echo > "$BR$P/bin/a"; echo > "$BR$P/share/x/b"; echo > "$BR$P/share/x/c"; echo > "$BR/etc/x.conf"
ln -s a "$BR$P/bin/a-link"
# packaged list as rpm passes it: mixed /usr and prefix spellings, dirs, the etc file
printf '%s\n' "$BR/usr/bin/a" "$BR$P/bin/a-link" "$BR/usr/share/x" "$BR/usr/share/x/b" \
  "$BR$P/share/x/c" "$BR/usr/share/x/c" "$BR/etc/x.conf" > "$B/cf/list"
expect "check-files: all packaged" "$(cf "$BR" "$P" < "$B/cf/list")" ""
echo > "$BR$P/share/x/unpackaged"
expect "check-files: unpackaged file reported" "$(cf "$BR" "$P" < "$B/cf/list")" "   $P/share/x/unpackaged"
grep -v "x.conf" "$B/cf/list" > "$B/cf/list2"
expect "check-files: unpackaged /etc file" "$(cf "$BR" "$P" < "$B/cf/list2" | sort | tr '\n' ' ')" "   /etc/x.conf    $P/share/x/unpackaged "
# rpm's own check-files reports every packaged-through-/usr file (what the
# canonicalisation avoids)
n=$(sh "$cfg/check-files" "$BR" < "$B/cf/list" | wc -l)
[ "$n" -gt 1 ] && ok "rpm's check-files reports $n false entries here (canonicalisation needed)" \
  || bad "rpm's check-files unexpectedly clean ($n)"

# ---- 7. prep-hooks unit tests -------------------------------------------------
mkdir -p "$B/ph"; echo old > "$B/ph/file.txt"
bash "$cfg/nix/prep-hooks" "$B/ph" && ok "prep-hooks: no-op without hooks" || bad "prep-hooks no-op failed"
NIX_PREP_PATCHES="$tests/prep-fix.patch" NIX_PREP_SCRIPT="$tests/prep-script.sh" bash "$cfg/nix/prep-hooks" "$B/ph" >/dev/null 2>&1
expect "prep-hooks: patch applied" "$(cat "$B/ph/file.txt")" "patched"
expect "prep-hooks: script ran" "$(cat "$B/ph/prep-marker")" "script"
if NIX_PREP_PATCHES="$tests/prep-fix.patch" bash "$cfg/nix/prep-hooks" "$B/ph" >/dev/null 2>&1; then
  bad "prep-hooks: re-applying a patch succeeded"; else ok "prep-hooks: a patch that does not apply fails"; fi

# ---- 8. config.site -------------------------------------------------------------
site() { # PREFIX HOST -> "libdir sysconfdir localstatedir sharedstatedir runstatedir"
  sh -c '
    prefix=$1 host_alias=$2 exec_prefix=NONE
    libdir="\${exec_prefix}/lib" sysconfdir="\${prefix}/etc" localstatedir="\${prefix}/var"
    sharedstatedir="\${prefix}/com" runstatedir="\${localstatedir}/run"
    . "$3"
    echo "$libdir $sysconfdir $localstatedir $sharedstatedir $runstatedir ${el_nixos_lib:-}"' sh "$1" "$2" "$configSite"
}
expect "config.site x86_64" "$(site "$P" x86_64-redhat-linux)" '${exec_prefix}/lib64 /etc /var /var/lib /run lib64'
expect "config.site i686" "$(site "$P" i686-redhat-linux)" '${exec_prefix}/lib /etc /var /var/lib /run lib'
expect "config.site no host (default x86_64)" "$(site "$P" "")" '${exec_prefix}/lib64 /etc /var /var/lib /run lib64'
expect "config.site /usr prefix untouched" "$(site /usr x86_64-redhat-linux)" '${exec_prefix}/lib ${prefix}/etc ${prefix}/var ${prefix}/com ${localstatedir}/run '
v=$(sh -c 'prefix=$1 host_alias=x86_64-redhat-linux libdir=/opt/lib sysconfdir=/opt/etc; . "$2"; echo "$libdir $sysconfdir"' sh "$P" "$configSite")
expect "config.site keeps explicit values" "$v" "/opt/lib /opt/etc"

# ---- 9. rpmbuild -bb of tiny specs with the relocation config ------------------
mkdir -p "$B/rpmbuild/SPECS" "$B/rpmbuild/SOURCES"
cp "$tests/nntest.spec" "$tests/nntest-rmrf.spec" "$B/rpmbuild/SPECS/"
export NIX_PREP_PATCHES="$tests/prep-fix.patch" NIX_PREP_SCRIPT="$tests/prep-script.sh"
for s in nntest nntest-rmrf; do
  if inshim "$B/cfg" rpmbuild -bb --nodeps --target x86_64 "$B/rpmbuild/SPECS/$s.spec" > "$out/rpmbuild-$s.log" 2>&1; then
    ok "rpmbuild -bb $s"
  else
    bad "rpmbuild -bb $s (log: rpmbuild-$s.log)"; tail -n 40 "$out/rpmbuild-$s.log" >&2
  fi
done
q() { inshim "$B/cfg" rpm -qp --nosignature --nodigest "$@"; }
r=$B/rpmbuild/RPMS/x86_64/nntest-1.0-1.el10_2.x86_64.rpm
if [ -f "$r" ]; then
  files=$(q --qf '[%{FILENAMES}\n]' "$r" | LC_ALL=C sort)
  echo "$files" > "$out/nntest.files"
  expect "nntest file list" "$(tr '\n' ' ' <<<"$files")" \
    "/etc/nntest.conf $P/bin/nntest $P/lib64/nntest $P/lib64/nntest/data.txt $P/share/nntest/README /usr/share/nntest/file.txt "
  expect "nntest %config" "$(q --qf '[%{FILEFLAGS:fflags} %{FILENAMES}\n]' "$r" | grep nntest.conf)" "cn /etc/nntest.conf"
  expect "nntest BUILDHOST" "$(q --qf '%{BUILDHOST}' "$r")" "el-nixos.localdomain"
  expect "nntest payload uncompressed (w0.ufdio)" "$(q --qf '%{PAYLOADCOMPRESSOR}' "$r")" "(none)"
else bad "no $r"; fi
r=$B/rpmbuild/RPMS/x86_64/nntest-rmrf-1.0-1.el10_2.x86_64.rpm
if [ -f "$r" ]; then
  files=$(q --qf '[%{FILENAMES}\n]' "$r" | LC_ALL=C sort)
  echo "$files" > "$out/nntest-rmrf.files"
  expect "nntest-rmrf file list" "$(tr '\n' ' ' <<<"$files")" \
    "$P/bin/nntest-rmrf $P/lib64/nntest-rmrf.txt $P/share/nntest-rmrf $P/share/nntest-rmrf/from-prefix $P/share/nntest-rmrf/from-usr "
  grep -q 'merging it into' "$out/rpmbuild-nntest-rmrf.log" && ok "nntest-rmrf: fold-usr merged a real usr" \
    || bad "nntest-rmrf: no merge message"
else bad "no $r"; fi
grep -q 'Installed (but unpackaged)' "$out"/rpmbuild-*.log && bad "unpackaged files reported by rpmbuild" \
  || ok "no unpackaged files in rpmbuild logs"

echo "$fails failure(s)" >> "$log"
cat "$log"
[ "$fails" -eq 0 ]
