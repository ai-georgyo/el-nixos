# In-chroot inspection of binary RPMs built in stage0 (input at /inputs/build).
# For every non-debuginfo RPM: file list, requires/provides, ELF interpreter
# and RUNPATH of every ELF file, and a recursive grep of the unpacked payload
# for /nix/store (must find nothing).
out=/builddir/out
exec > >(tee "$out/report.txt") 2>&1
fail=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }
cd /builddir
for f in /inputs/build/RPMS/*/*.rpm; do
  n=$(rpm -qp --qf '%{NAME}' "$f")
  echo "================ $(basename $f)"
  rpm -qpi "$f" | grep -E '^(Name|Version|Release|Architecture|Build Date|Build Host|Source RPM)'
  echo "-- files";    rpm -qplv "$f"
  echo "-- requires"; rpm -qp --requires "$f"
  echo "-- provides"; rpm -qp --provides "$f"
  check "$n: no /nix/store in requires/provides" '! rpm -qp --requires --provides "$f" | grep -q /nix/store'
  d=x-$n; mkdir -p $d
  rpm2cpio "$f" | (cd $d && cpio -idm --quiet --no-absolute-filenames)
  case $n in
    *-debuginfo|*-debugsource) echo "(debug package: payload store-path scan informational only)"
      grep -rl /nix/store $d | head || true ;;
    *) check "$n: payload has no /nix/store strings" '! grep -rIl /nix/store $d && ! grep -rl /nix/store $d' ;;
  esac
  while IFS= read -r -d '' e; do
    if head -c4 "$e" | grep -q ELF; then
      echo "-- ELF ${e#$d}"
      readelf -lW "$e" | grep -i interpreter || true
      readelf -dW "$e" | grep -E 'NEEDED|RPATH|RUNPATH|SONAME' || true
      readelf -nW "$e" | grep -E 'Build ID|x86 ISA|IBT|Packaging Metadata|FDO_PACKAGING_METADATA|Package' || true
      check "${e#$d}: no RPATH/RUNPATH" '! readelf -dW "$e" | grep -qE "RPATH|RUNPATH"'
      if readelf -lW "$e" | grep -q interpreter; then
        check "${e#$d}: PT_INTERP /lib64/ld-linux-x86-64.so.2" 'readelf -lW "$e" | grep -q "interpreter: /lib64/ld-linux-x86-64.so.2]"'
      fi
    fi
  done < <(find $d -type f -print0)
done
echo
if [ $fail = 0 ]; then echo "ALL RPM CHECKS PASSED"; else echo "SOME RPM CHECKS FAILED"; exit 1; fi
