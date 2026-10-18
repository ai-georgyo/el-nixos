# shellcheck shell=bash
# Runs INSIDE the lockgen buildroot (stage0-full + the *-rpm-macros
# subpackages of stage0's macro builds), as mockbuild:
#   bash rpmspec-query.sh SRPM DIST
# Writes raw results to /builddir/out (lib/rocky/lockgen/raw2json.py turns
# them into JSON outside the chroot).  rpmspec failures are recorded (rc +
# stderr), never fatal: the lock records them per SRPM.
set -uo pipefail
srpm=$1 dist=$2
out=/builddir/out src=/builddir/src
mkdir -p "$out" "$src" /builddir/build
cd "$src"

# The spec, macro files, %include'd lists etc. come from the payload.  Large
# files (tarballs, big patches) are not extracted -- rpmspec -q never reads
# them and the build directory is small -- but an empty placeholder keeps
# %{SOURCEn} existence tests honest.  File names/sizes from the header.
rpm -qp --nosignature --nodigest --qf '[%{FILESIZES}\t%{FILENAMES}\n]' "$srpm" > "$out/files.tsv"
awk -F'\t' '$1 <= 2097152 { print $2 }' "$out/files.tsv" > "$out/extract.list"
rpm2cpio "$srpm" | cpio -idm --quiet --no-absolute-filenames -E "$out/extract.list"
awk -F'\t' '$1 > 2097152 { print $2 }' "$out/files.tsv" | while IFS= read -r f; do : > "$f"; done

spec=
for f in *.spec; do
  [ -e "$f" ] || continue
  if [ -z "$spec" ] || [ "$f" = "$(rpm -qp --nosignature --nodigest --qf '%{NAME}' "$srpm").spec" ]; then spec=$f; fi
done
if [ -z "$spec" ]; then
  echo "no .spec in the SRPM" > "$out/srpm.err"; echo 1 > "$out/srpm.rc"
  exit 0
fi
echo "$spec" > "$out/spec"
rpm --version > "$out/rpm-version"

# rocky-release's macros.dist: %dist = %{?distprefix...}%{distcore}%{?distsuffix};
# so the release is set through %distcore -- defining %dist itself would drop
# the prefix %forgemeta adds (".git<commit>") and give the wrong release.
common=(--target x86_64 --define "distcore $dist" --define "_sourcedir $src"
  --define "_topdir /builddir/build")
# Every result line starts with "LOCKGEN<TAB>": macros may print to stdout
# while the spec is parsed (e.g. `%forgemeta -v`), so other lines are noise.
q() {  # q NAME RPMSPEC-ARGS...
  local n=$1; shift
  timeout 900 rpmspec -q "${common[@]}" "$@" "$spec" > "$out/$n.tsv" 2> "$out/$n.err"
  echo $? > "$out/$n.rc"
}
# source header: NEVR (checked against the lock) and arch restrictions
q srpm --srpm --qf 'LOCKGEN\t%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t[%{EXCLUSIVEARCH} ]\t[%{EXCLUDEARCH} ]\n'
# binary packages that rpmbuild would produce (%package with a %files section)
q builtrpms --builtrpms --qf 'LOCKGEN\t%{NAME}\t%{ARCH}\n'
# every declared %package (to report the ones without %files)
q rpms --rpms --qf 'LOCKGEN\t%{NAME}\t%{ARCH}\n'
exit 0
