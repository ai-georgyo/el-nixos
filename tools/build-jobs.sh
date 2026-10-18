#!/usr/bin/env bash
# Build every job of the flake's `hydraJobs` that is not built yet.
#
#   tools/build-jobs.sh [options] [-- NIX-BUILD-ARGS...]
#   nix run .#build-jobs -- [options] [-- NIX-BUILD-ARGS...]
#
#   --flake REF         flake to evaluate (default: .)
#   --attr ATTR         attribute holding the jobs (default: hydraJobs)
#   --workers N         nix-eval-jobs evaluation workers (default: 4)
#   --max-memory-size M MiB per evaluation worker before it is restarted (default: 4096)
#   --dry-run           evaluate and report, build nothing
#   --jobs-file FILE    keep nix-eval-jobs' JSON lines in FILE
#
# 1. `nix-eval-jobs --flake REF#ATTR --check-cache-status --force-recurse`
#    evaluates all jobs in parallel workers, with import-from-derivation
#    DISABLED (so an IFD anywhere is an evaluation error, i.e. this is also
#    the IFD-free evaluation check), and reports for each job whether its
#    outputs are already in the local store ("local"), substitutable from a
#    binary cache ("cached") or neither ("notBuilt").
# 2. Jobs that are local or cached are skipped; the remaining derivations
#    (deduplicated) go to ONE `nix build --keep-going --no-link --stdin`, so
#    Nix schedules them together (shared dependencies built once, in
#    parallel up to max-jobs).
# 3. A summary: jobs, evaluation errors, local/cached/to-build, and which
#    builds failed.  Exit status 0 only if everything evaluated and built.
#
# nix-eval-jobs and jq come from PATH (the flake app provides the pinned
# nixpkgs' ones) or, when missing, from the flake's pinned nixpkgs.
set -euo pipefail

flake=. attr=hydraJobs workers=4 mem=4096 dry=0 jobs_file=
while [ $# -gt 0 ]; do
  case $1 in
    --flake) flake=$2; shift 2 ;;
    --attr) attr=$2; shift 2 ;;
    --workers) workers=$2; shift 2 ;;
    --max-memory-size) mem=$2; shift 2 ;;
    --dry-run) dry=1; shift ;;
    --jobs-file) jobs_file=$2; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
    --) shift; break ;;
    *) echo "build-jobs: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
done

tool() {  # tool NAME NIXPKGS-ATTR -> path of the executable
  if command -v "$1" >/dev/null 2>&1; then command -v "$1"; return; fi
  echo "build-jobs: $1 not in PATH, taking it from the flake's pinned nixpkgs" >&2
  echo "$(nix build --no-link --print-out-paths --inputs-from "$flake" "nixpkgs#$2")/bin/$1"
}
NIX_EVAL_JOBS=$(tool nix-eval-jobs nix-eval-jobs)
JQ=$(tool jq jq.bin)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
jobs=${jobs_file:-$work/jobs.jsonl}

echo "build-jobs: evaluating $flake#$attr ($workers workers, IFD disabled)" >&2
t0=$(date +%s)
rc=0
"$NIX_EVAL_JOBS" --flake "$flake#$attr" --workers "$workers" --max-memory-size "$mem" \
  --check-cache-status --force-recurse --gc-roots-dir "$work/gcroots" \
  --option allow-import-from-derivation false > "$jobs" || rc=$?
t1=$(date +%s)

"$JQ" -r 'select(.error) | "\(.attr): \(.error)"' "$jobs" > "$work/errors"
"$JQ" -r 'select(.drvPath) | [.cacheStatus // (if .isCached then "cached" else "notBuilt" end), .drvPath, .attr] | @tsv' \
  "$jobs" > "$work/ok"
n_jobs=$(wc -l < "$work/ok")
n_err=$(wc -l < "$work/errors")
cut -f2 "$work/ok" | sort -u > "$work/drvs"
n_drvs=$(wc -l < "$work/drvs")
n_local=$(awk -F'\t' '$1=="local"' "$work/ok" | cut -f2 | sort -u | wc -l)
n_cached=$(awk -F'\t' '$1=="cached"' "$work/ok" | cut -f2 | sort -u | wc -l)
awk -F'\t' '$1!="local" && $1!="cached"' "$work/ok" | cut -f2 | sort -u > "$work/todo"
n_todo=$(wc -l < "$work/todo")

failed=0
if [ "$n_todo" -gt 0 ] && [ $dry = 0 ]; then
  echo "build-jobs: building $n_todo derivation(s)" >&2
  sed 's/$/^*/' "$work/todo" | nix build --keep-going --no-link --stdin "$@" || true
  # which ones are still missing an output?
  while read -r drv; do
    if ! nix-store --check-validity $(nix-store -q --outputs "$drv") 2>/dev/null; then
      echo "$drv" >> "$work/failed"
    fi
  done < "$work/todo"
  failed=$( [ -s "$work/failed" ] && wc -l < "$work/failed" || echo 0)
fi

echo
echo "build-jobs summary ($flake#$attr)"
printf '  %-32s %s\n' "jobs evaluated" "$n_jobs ($n_drvs distinct derivations, $((t1 - t0)) s)"
printf '  %-32s %s\n' "evaluation errors" "$n_err"
if [ $rc -ne 0 ]; then
  printf '  %-32s %s\n' "nix-eval-jobs" "FAILED with exit status $rc (messages above); the job list is incomplete"
fi
printf '  %-32s %s\n' "already built (local)" "$n_local"
printf '  %-32s %s\n' "substitutable (binary cache)" "$n_cached"
if [ $dry = 1 ]; then
  printf '  %-32s %s\n' "to build (dry run)" "$n_todo"
  awk -F'\t' '$1!="local" && $1!="cached" {print "    " $3 "  " $2}' "$work/ok" | sort -u
else
  printf '  %-32s %s\n' "built now" "$((n_todo - failed))"
  printf '  %-32s %s\n' "failed" "$failed"
fi
if [ "$n_err" -gt 0 ]; then
  echo "evaluation errors:"; sed 's/^/    /' "$work/errors" | head -50
fi
if [ "$failed" -gt 0 ]; then
  echo "failed builds:"
  while read -r drv; do
    awk -F'\t' -v d="$drv" '$2==d {print "    " $3 "  " d}' "$work/ok" | head -1
  done < "$work/failed"
fi
[ $rc -eq 0 ] && [ "$n_err" -eq 0 ] && [ "$failed" -eq 0 ]
