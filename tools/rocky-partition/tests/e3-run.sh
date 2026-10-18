#!/usr/bin/env bash
# Experiment E3 (docs/research/nix-native/experiments/E3.md): build the
# relocated trees and replay each into fake outputs, without overrides and
# with tests/e3-overrides.json. Run from the repository root (git add -A
# first: the flake sees tracked files only):
#   tools/rocky-partition/tests/e3-run.sh WORKDIR [srpm...]
# Prints one summary line per run; reports in WORKDIR/<run>/report.json.
set -euo pipefail
work=$1; shift
srpms=("$@"); [ ${#srpms[@]} -gt 0 ] || srpms=(xz expat libxcrypt ncurses krb5 pixman)
here=tools/rocky-partition
rpm=$(nix build --no-link --print-out-paths .#stage0.rpm)
patchelf=$(nix build --no-link --print-out-paths --inputs-from . nixpkgs#patchelf)/bin/patchelf
for n in "${srpms[@]}"; do
  tree=$(nix build -L --cores 6 --max-jobs 2 --no-link --print-out-paths ".#nn.partitionTool.trees.e3.$n")
  # runs: "none" (no overrides), "@" (the SRPM's entry), and every "SRPM:NAME" entry
  runs=($(python3 -I -c 'import json,sys; print(" ".join(k.partition(":")[2] or "@" for k in json.load(open(sys.argv[1])) if k.partition(":")[0] == sys.argv[2]))' $here/tests/e3-overrides.json "$n"))
  for r in none "${runs[@]}"; do
    if [ "$r" = none ]; then ov=(); rn=(--run none); else ov=(--overrides $here/tests/e3-overrides.json); rn=(); [ "$r" = @ ] || rn=(--run "$r"); fi
    python3 -I $here/tests/e3-replay.py --tool $here --rpm "$rpm" --patchelf "$patchelf" --work "$work" \
      "${ov[@]}" "${rn[@]}" "$tree/buildtree" "$n" 2>&1 | grep -E '^rocky-partition: [^ ]+: [0-9]+ outputs|^Traceback' | sed "s|^|[$n ${r/@/overrides}] |"
  done
done
