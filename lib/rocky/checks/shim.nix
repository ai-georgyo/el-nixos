# checks.nn-shim: the tool shim (lib/rocky/tool-shim.sh, mkview.py) in a real
# build sandbox (docs/nix-native-design.md §5.4, WP3):
#   - /usr/bin/rpmbuild (the stage0 rpm, reached through the view) runs and
#     reads its config from /usr/lib/rpm = RPM_CONFIG_DIR; /bin/true runs;
#     /sbin and /usr/sbin are bin
#   - only declared inputs are visible in /usr: an undeclared store path that
#     IS in the sandbox (this check references it) does not show up
#   - first wins on collisions, which are reported; FHS-in-store inputs
#     (<p>/usr/include) contribute their usr/ dirs
#   - $out alias: the view is at $out (read-only) during the command, gone
#     after; $out is empty after, then filled by the builder as usual
#   - fresh tmpfs root and /tmp, SIGPIPE at its default
{ bootPkgs, stage0, self, ... }:
let
  pkgs = bootPkgs;
  # small fake inputs (the content says who it is)
  fake = name: layout: pkgs.runCommand "nn-shim-${name}" { } ''
    mkdir -p $out/${layout}include/sub $out/${layout}lib64/pkgconfig $out/${layout}share/${name}
    echo ${name} > $out/${layout}include/${name}.h
    echo ${name} > $out/${layout}include/common.h
    echo ${name} > $out/${layout}include/sub/${name}.h
    echo ${name} > $out/${layout}lib64/pkgconfig/${name}.pc
    echo ${name} > $out/${layout}share/${name}/data
    mkdir -p $out/bin; printf '#!/bin/sh\necho ${name}\n' > $out/bin/${name}-tool; chmod +x $out/bin/${name}-tool
  '';
  declared1 = fake "declared1" "";
  declared2 = fake "declared2" "";
  fhsInput = fake "fhsinput" "usr/";
  undeclared = fake "undeclared" "";
  rpm = stage0.rpm;
in
{
  nn-shim = pkgs.runCommand "nn-shim-test" {
    nativeBuildInputs = with pkgs; [ coreutils findutils gnugrep diffutils ];
    rockyViewInputs = "${declared1} ${declared2}:${fhsInput}";
    undeclared = "${undeclared}";
  } ''
    set -euo pipefail
    shim=${self.toolShim}
    fail() { echo "FAIL: $*" >&2; exit 1; }
    ok() { echo "ok: $*"; }
    export PATH="${rpm}/usr/bin:$PATH"
    report=$TMPDIR/report.txt; : > $report
    log() { echo "$*" | tee -a $report; }

    # --- tools through the view; rpm config at /usr/lib/rpm
    export RPM_CONFIG_DIR=${rpm}/usr/lib/rpm
    v=$($shim -- /usr/bin/rpmbuild --version)
    log "rpmbuild: $v"
    case $v in "RPM version 4.19."*) ok "rpmbuild via /usr/bin" ;; *) fail "rpmbuild --version: $v" ;; esac
    cfg=$($shim -- /usr/bin/rpm --eval '%{_rpmconfigdir}:%{_bindir}')
    [ "$cfg" = /usr/lib/rpm:/usr/bin ] || fail "rpm --eval: $cfg"
    $shim -- test -f /usr/lib/rpm/macros || fail "/usr/lib/rpm/macros missing"
    $shim -- sh -c 'cmp /usr/lib/rpm/macros "$RPM_CONFIG_DIR/macros"' || fail "/usr/lib/rpm is not RPM_CONFIG_DIR"
    $shim -- /bin/true || fail /bin/true
    $shim -- /sbin/true || fail /sbin/true
    $shim -- /usr/sbin/true || fail /usr/sbin/true
    [ "$($shim -- readlink /bin)" = usr/bin ] || fail "/bin is not -> usr/bin"
    [ "$($shim -- /usr/bin/sh -c 'echo $0')" = /usr/bin/sh ] || fail "/usr/bin/sh"
    ok "/bin/true /sbin/true /usr/sbin/true"
    # tools come from PATH, first wins: coreutils' ls, not something later
    [ "$($shim -- readlink /usr/bin/ls)" = "$(command -v ls)" ] || fail "/usr/bin/ls is not PATH's first ls"
    # inputs' bin dirs are NOT in the view (only PATH is)
    $shim -- test ! -e /usr/bin/declared1-tool || fail "input bin/ leaked into /usr/bin"
    ok "PATH tools"

    # --- only declared inputs
    $shim -- test -f /usr/include/declared1.h || fail "declared1.h missing"
    $shim -- test -f /usr/include/sub/declared2.h || fail "declared2 sub/ not merged"
    $shim -- test -f /usr/include/fhsinput.h || fail "FHS-in-store input not used"
    $shim -- test -f /usr/lib64/pkgconfig/declared2.pc || fail "lib64 not merged"
    $shim -- test -f /usr/share/declared2/data || fail "share not merged"
    $shim -- test -d "$undeclared/include" || fail "undeclared store path not in the sandbox (test is void)"
    # real directories and files (overlayfs), as on FHS: glibc's configure refuses
    # a symlinked $prefix/include/scsi
    $shim -- test -d /usr/include/sub -a ! -L /usr/include/sub || fail "/usr/include/sub not a real dir"
    $shim -- test ! -L /usr/include/sub/declared1.h || fail "/usr/include files are symlinks"
    [ "$($shim -- find /usr/include -type f | wc -l)" -ge 7 ] || fail "find -type f in /usr/include"
    # read-only
    if $shim -- touch /usr/x 2>/dev/null; then fail "/usr writable"; fi
    if $shim -- mkdir /usr/include/x 2>/dev/null; then fail "/usr/include writable"; fi
    if $shim -- touch /usr/bin/x 2>/dev/null; then fail "/usr/bin writable"; fi
    $shim -- test ! -e /usr/include/undeclared.h || fail "undeclared input visible in /usr/include"
    [ -z "$($shim -- find -L /usr/include /usr/lib64 /usr/share -name 'undeclared*')" ] || fail "undeclared input visible"
    ok "only declared inputs visible"
    # first wins + collision report
    [ "$($shim -- cat /usr/include/common.h)" = declared1 ] || fail "first input does not win"
    grep -P '^file\tinclude/common.h\t${declared1}/include/common.h\t${declared2}/include/common.h$' \
      $NIX_BUILD_TOP/rocky-view-collisions.txt || fail "collision not reported"
    grep -c . $NIX_BUILD_TOP/rocky-view-collisions.txt | sed 's/^/collision lines: /' | tee -a $report
    ok "first wins, collisions reported"
    # no stage0 root / nixpkgs dev trees behind /usr: only what mkview made
    [ -z "$($shim -- ls /usr/local 2>/dev/null)" ] || fail "/usr/local exists"
    $shim -- test ! -e /lib64 || fail "/lib64 exists"
    log "root: $($shim -- ls / | tr '\n' ' ')"
    [ "$($shim -- ls / | tr '\n' ' ')" = "bin build dev etc nix proc sbin tmp usr " ] || fail "unexpected root entries"
    [ -z "$($shim -- ls -A /tmp)" ] || fail "/tmp not fresh"
    sigign=$($shim -- grep SigIgn /proc/self/status | awk '{print $2}')
    [ $(( 0x$sigign & 0x1000 )) = 0 ] || fail "SIGPIPE ignored inside (SigIgn=$sigign)"
    ok "fresh root, /tmp, SIGPIPE default"

    # --- without RPM_CONFIG_DIR there is no /usr/lib/rpm mount
    (unset RPM_CONFIG_DIR; $shim -- test ! -e /usr/lib/rpm) || fail "/usr/lib/rpm without RPM_CONFIG_DIR"
    ok "RPM_CONFIG_DIR optional"

    # --- $out self-prefix alias
    test ! -e $out || fail "\$out exists before"
    $shim -- test ! -e $out/include || fail "alias without ROCKY_PREFIX_VIEW"
    ROCKY_PREFIX_VIEW=1 $shim -- sh -c '
      set -e
      test -f "$out/include/declared1.h"
      test "$(cat "$out/include/common.h")" = declared1
      test -x "$out/bin/true"
      test "$(cd "$out/include" && find . | sort)" = "$(cd /usr/include && find . | sort)"
      test ! -L "$out/include/sub"
      if touch "$out/written" 2>/dev/null; then echo "alias is writable" >&2; exit 1; fi
      if touch "$out/include/written" 2>/dev/null; then echo "alias include/ is writable" >&2; exit 1; fi
      # what a configure with --with-headers=%{_prefix}/include sees
      echo "#include <declared1.h>" > /tmp/t.c; grep -q declared1 "$out/include/$(sed -n "s/.*<\(.*\)>.*/\1/p" /tmp/t.c)"
    ' || fail "alias during the command"
    test -d $out || fail "\$out not a directory after"
    [ -z "$(ls -A $out)" ] || fail "\$out not empty after: $(ls -A $out)"
    ok "\$out alias appears during, gone after, \$out empty"
    # a non-empty $out is refused; a write-through attempt never lands
    touch $out/stray
    if ROCKY_PREFIX_VIEW=1 $shim -- true 2>/dev/null; then fail "non-empty \$out accepted"; fi
    rm $out/stray
    # --no-prefix-view overrides the env
    ROCKY_PREFIX_VIEW=1 $shim --no-prefix-view -- test ! -e $out/include || fail "--no-prefix-view"
    # exit status passes through
    set +e; $shim -- sh -c 'exit 7'; rc=$?; set -e
    [ $rc = 7 ] || fail "exit status $rc"
    ok "refusals, exit status"

    cp $report $out/report.txt
    cp $NIX_BUILD_TOP/rocky-view-collisions.txt $out/collisions.txt
    echo PASS | tee $out/result
  '';
}
