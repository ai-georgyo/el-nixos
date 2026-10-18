# checks.nn-parity-selftest: tools/nn-parity.py end to end on a synthetic
# package, so every comparator is shown to pass on a faithful relocation AND
# to fire on each kind of breakage (no glibc build needed).
#
#   official   "nnt" built by rpmbuild (nixpkgs rpm), prefix /usr:
#              nnt (bin/nnt ELF + bin/nnt-wrap script + lib64/libnnt.so.1 +
#              %config /etc/nnt.conf + %ghost /var/lib/nnt/state),
#              nnt-devel (include/nnt.h, lib64/libnnt.so -> libnnt.so.1),
#              nnt-common (share/nnt/data, %doc README)
#   good       the same sources compiled with the store prefix, one output per
#              subpackage (out dev common), cross-output symlink absolute,
#              metadata from the headers (meta-from-rpm): files, content, abi,
#              closure must PASS (content: string/RIP-displacement/layout
#              classification of the relocated ELF)
#   broken     data file missing, symlink to the wrong target, config text
#              changed, an extra exported symbol, exec bit dropped, a foreign
#              store reference, a tampered Requires: each check must FAIL with
#              the expected ids
#   runtime    two tiny reports: equal after normalisation, then one changed
#              item (FAIL), then the same with an allowlist rule (PASS)
{ bootPkgs, lib, ... }:
let
  pkgs = bootPkgs;
  tool = import ./tool.nix { inherit lib; };
  py = "python3 -I ${tool}/nn-parity.py";
  # explicit rpaths only (the official one is /usr/lib64: purity filtering off)
  common = { NIX_DONT_SET_RPATH = "1"; NIX_NO_SELF_RPATH = "1"; NIX_HARDENING_ENABLE = ""; NIX_ENFORCE_PURITY = "0"; };

  srcs = pkgs.writeTextDir "nnt.c" ''
    #include <stdio.h>
    extern int nnt_lib(void);
    static const char data[] = PREFIX "/share/nnt/data";
    int main(int argc, char **argv) { (void)argv; if (argc > 5) puts(PREFIX "/libexec/nnt/helper-with-a-longer-name");
      printf("%s %d\n", data, nnt_lib()); return 0; }
  '';
  # compile: PREFIX, lib dir for the rpath, extra symbol?
  compile = ''
    build() {  # prefix rpath dest extra
      mkdir -p $3
      printf 'int nnt_lib(void){return 42;}\n%s\n' "$4" > lib.c
      gcc -O2 -fPIC -shared -Wl,-soname,libnnt.so.1 lib.c -o $3/libnnt.so.1
      gcc -O2 -DPREFIX="\"$1\"" ${srcs}/nnt.c -o $3/nnt -L$3 -l:libnnt.so.1 -Wl,-rpath,$2 \
        -Wl,--dynamic-linker=/lib64/ld-linux-x86-64.so.2
      printf '#!/bin/sh\nexec %s/bin/nnt "$@"\n' "$1" > $3/nnt-wrap
      printf 'path=%s/share/nnt/data\n' "$1" > $3/nnt.conf
      printf 'int nnt_lib(void);\n' > $3/nnt.h
      if grep -l /nix/store $3/nnt.h; then exit 1; fi
    }
  '';

  official = pkgs.runCommandCC "nn-selftest-official-rpms" ({ nativeBuildInputs = [ pkgs.rpm ]; } // common) ''
    cd $TMPDIR
    ${compile}
    build /usr /usr/lib64 $TMPDIR/b ""
    mkdir -p top tmp
    cat > nnt.spec <<EOF
    Name: nnt
    Version: 1
    Release: 1
    Summary: nn-parity selftest
    License: MIT
    Requires: nnt-common = %{version}-%{release}
    %description
    t
    %package devel
    Summary: devel
    Requires: nnt = %{version}-%{release}
    %description devel
    t
    %package common
    Summary: common
    BuildArch: noarch
    %description common
    t
    %install
    install -Dm755 $TMPDIR/b/nnt %{buildroot}/usr/bin/nnt
    install -Dm755 $TMPDIR/b/nnt-wrap %{buildroot}/usr/bin/nnt-wrap
    install -Dm755 $TMPDIR/b/libnnt.so.1 %{buildroot}/usr/lib64/libnnt.so.1
    ln -s libnnt.so.1 %{buildroot}/usr/lib64/libnnt.so
    install -Dm644 $TMPDIR/b/nnt.h %{buildroot}/usr/include/nnt.h
    install -Dm644 $TMPDIR/b/nnt.conf %{buildroot}/etc/nnt.conf
    mkdir -p %{buildroot}/var/lib/nnt
    install -Dm644 /dev/null %{buildroot}/usr/share/nnt/data
    echo hello > %{buildroot}/usr/share/nnt/data
    install -Dm644 /dev/null %{buildroot}/usr/share/doc/nnt/README
    %files
    /usr/bin/nnt
    /usr/bin/nnt-wrap
    /usr/lib64/libnnt.so.1
    %config(noreplace) /etc/nnt.conf
    %dir /var/lib/nnt
    %ghost /var/lib/nnt/state
    %files devel
    /usr/include/nnt.h
    /usr/lib64/libnnt.so
    %files common
    /usr/share/nnt/data
    %doc /usr/share/doc/nnt/README
    EOF
    HOME=$TMPDIR rpmbuild -bb --quiet --define "_topdir $TMPDIR/top" --define "_tmppath $TMPDIR/tmp" \
      --define '__os_install_post %{nil}' --define 'debug_package %{nil}' --define '_build_id_links none' \
      --define '_binary_payload w9.gzdio' --nodeps nnt.spec
    mkdir -p $out; cp top/RPMS/*/*.rpm $out/
    for f in $out/*.rpm; do mv $f $out/$(rpm -qp --qf '%{NAME}' $f).rpm; done
    ls $out
  '';

  # a relocated "build" of the same: one output per subpackage
  relocated = { name, broken ? false }: pkgs.runCommandCC name ({
    outputs = [ "out" "dev" "common" ];
    nativeBuildInputs = [ pkgs.python3 ];
    passthru.rpmOutputs = { nnt = "out"; nnt-devel = "dev"; nnt-common = "common"; };
  } // common) ''
    cd $TMPDIR
    ${compile}
    build $out $out/lib64 $TMPDIR/b ${lib.optionalString broken "'int nnt_extra(void){return 1;}'"}
    install -Dm555 b/nnt $out/bin/nnt
    install -D${if broken then "m444" else "m555"} b/nnt-wrap $out/bin/nnt-wrap
    install -Dm555 b/libnnt.so.1 $out/lib64/libnnt.so.1
    ${lib.optionalString broken "echo 'extra=1' >> b/nnt.conf"}
    install -Dm444 b/nnt.conf $out/etc/nnt.conf
    install -Dm444 b/nnt.h $dev/include/nnt.h
    mkdir -p $dev/lib64; ln -s $out/lib64/${if broken then "libnnt.so.2" else "libnnt.so.1"} $dev/lib64/libnnt.so
    mkdir -p $common/share/nnt $common/share/doc/nnt
    ${lib.optionalString (!broken) "echo hello > $common/share/nnt/data"}
    touch $common/share/doc/nnt/README
    ${lib.optionalString broken "mkdir -p $out/share; echo ${pkgs.hello} > $out/share/foreign"}
    for n in nnt:out nnt-devel:dev nnt-common:common; do
      o=''${n#*:}; eval d=\$$o; mkdir -p $d/nix-support/rpm
      ${py} meta-from-rpm --rpm ${official}/''${n%%:*}.rpm --output-name $o --out $d/nix-support/rpm/''${n%%:*}.json
    done
    ${lib.optionalString broken ''
      python3 -I -c 'import json,sys; p=sys.argv[1]; m=json.load(open(p)); m["requires"].append({"name":"bogus","version":"","flags":0}); json.dump(m,open(p,"w"))' $out/nix-support/rpm/nnt.json
    ''}
  '';
  good = relocated { name = "nn-selftest-good"; };
  broken = relocated { name = "nn-selftest-broken"; broken = true; };

  planFor = drv: pkgs.writeText "${drv.name}-plan.json" (builtins.toJSON {
    name = drv.name;
    outputs = lib.genAttrs drv.outputs (o: drv.${o}.outPath);
    inherit (drv) rpmOutputs;
    official = lib.genAttrs [ "nnt" "nnt-devel" "nnt-common" ] (n: "${official}/${n}.rpm");
    extraAllowed = [ ];
  });
  graphs = drv: lib.concatMap (o: [ "graph-${o}" drv.${o} ]) drv.outputs;
in
pkgs.runCommand "nn-parity-selftest" {
  nativeBuildInputs = [ pkgs.python3 pkgs.zstd pkgs.binutils-unwrapped ];
  exportReferencesGraph = map (x: if lib.isString x then "good-" + x else x) (graphs good) ++ [ ]
    ++ map (x: if lib.isString x then "broken-" + x else x) (graphs broken);
  passthru = { inherit official good broken; };
} ''
  set -u
  ${py} selftest
  mkdir -p $out g-good g-broken
  for f in good-graph-* broken-graph-*; do mv $f g-''${f%%-graph-*}/''${f#*-}; done
  fails=0
  expect() {  # check plan rc graphs ids...
    local check=$1 plan=$2 want=$3 gr=$4; shift 4
    local o=$out/$check-$(basename $plan .json) rc=0
    ${py} $check --plan $plan --out $o --workdir $TMPDIR/w --graphs $gr > $o.log 2>&1 || rc=$?
    if [ $rc != $want ]; then echo "FAIL: $check $plan: rc $rc, want $want"; cat $o.log; fails=$((fails+1)); return; fi
    for id in "$@"; do
      if ! grep -qF -- "\"$id" $o/report.json; then echo "FAIL: $check: no difference $id"; fails=$((fails+1)); fi
    done
    echo "ok: $check $(basename $plan) rc=$rc $(head -3 $o/report.txt | tail -2 | tr '\n' ' ')"
  }
  for c in files content abi closure; do expect $c ${planFor good} 0 g-good; done
  expect files ${planFor broken} 1 g-broken \
    'files.missing:/usr/share/nnt/data' 'files.linkto:/usr/lib64/libnnt.so' 'files.exec:/usr/bin/nnt-wrap' \
    'files.only-ours:/usr/share/foreign' 'meta.requires:+bogus'
  expect content ${planFor broken} 1 g-broken 'content.text:/etc/nnt.conf' \
    'elf.dynsym:/usr/lib64/libnnt.so.1:+nnt_extra'
  expect abi ${planFor broken} 1 g-broken 'abi.dynsym:/usr/lib64/libnnt.so.1'
  expect closure ${planFor broken} 1 g-broken 'closure.foreign:hello-'
  # the good content check really classified relocated ELF sections
  python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1]))["stats"]; print("content stats:", s); assert s.get("elf_compared",0)>=1 and s.get("alloc_strings",0)+s.get("alloc_path_map",0)>=1 and s.get("alloc_displacement",0)>=1, s' \
    $out/content-$(basename ${planFor good} .json)/report.json || fails=$((fails+1))

  # runtime: normalised item comparison + allowlist
  P=${good.out}
  mkdir -p rt/off rt/ours1 rt/ours2
  printf '### a\n/lib64/libc.so.6 (0x7f0000)\n### b\nsame\n' > rt/off/report.txt
  printf '### a\n%s/lib64/libc.so.6 (0x7f1234)\n### b\nsame\n' $P > rt/ours1/report.txt
  printf '### a\n%s/lib64/libc.so.6 (0x7f1234)\n### b\nchanged\n' $P > rt/ours2/report.txt
  printf '{"allow":[{"id":"runtime.item:b","effect":"test","reason":"selftest"}]}' > rt/allow.json
  rplan=${planFor good}
  r() { local rc=0; ${py} runtime --plan $rplan --ours rt/$1 --official rt/off --out $out/rt-$1-$2 ''${3:+--allow $3} > /dev/null 2>&1 || rc=$?; echo $rc; }
  [ "$(r ours1 a)" = 0 ] && echo "ok: runtime equal after normalisation" || { echo "FAIL: runtime ours1"; fails=$((fails+1)); }
  [ "$(r ours2 a)" = 1 ] && grep -q '"runtime.item:b"' $out/rt-ours2-a/report.json && echo "ok: runtime difference found" \
    || { echo "FAIL: runtime ours2"; fails=$((fails+1)); }
  [ "$(r ours2 b rt/allow.json)" = 0 ] && echo "ok: runtime difference allowed by rule" || { echo "FAIL: runtime allow"; fails=$((fails+1)); }

  if [ $fails != 0 ]; then echo "nn-parity-selftest: $fails failure(s)"; exit 1; fi
  echo "nn-parity-selftest: PASS" | tee $out/result.txt
''
