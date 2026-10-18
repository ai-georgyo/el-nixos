# WP6a names: output names, overrides schema, unions table

Files: `lib/rocky/{names,overrides,unions}.nix`, `lib/rocky/parts/{names,overrides,unions}.nix`
(→ `legacyPackages.x86_64-linux.nn.{names,overrides,unions}`), `lib/rocky/checks/names.nix`
(→ `checks.x86_64-linux.nn-names`), fixtures `lib/rocky/tests/glibc-subpackages.json`,
`lib/rocky/tests/names-overrides/{good,bad}/default.nix`, `packages/README-overrides.md`.
Review fixes: [names-fix.md](names-fix.md).

## Commands

```
git add -A
nix build -L --cores 6 --max-jobs 2 --no-link --print-out-paths .#checks.x86_64-linux.nn-names
#  -> /nix/store/wqy3w4bjb8y6ci14vyyg6dk9dg4dyh93-nn-names: 36 eval-time + 1 build-time test, 0 failed
#  (after the review fixes: /nix/store/lx3na9x75p5ap79cnid0c63ak3mlvg1r-nn-names,
#   44 eval-time + 11 build-time tests, 0 failed; see names-fix.md)
```

Mutation check: removing `"src"` from `names.reserved` makes 2 tests fail
("collision -> both fall back…", "synthetic outputs list"), so the check is not vacuous.

## glibc

* Subpackages: `lock/rocky-10.2/subpackages.json` does not exist yet (WP1), so the
  fixture `lib/rocky/tests/glibc-subpackages.json` is used. The check verifies the fixture
  against the lock: its names = the 221 distinct names of `rpms.json` `bySrpm.glibc`
  plus the unshipped `glibc32`, `sysroot-x86_64-el10-glibc`, `compat-libpthread-nonshared`
  = **224**, prefix `glibc`. Once `subpackages.json` has a glibc entry, the check compares
  it with the fixture (names, prefix, unshipped set) and uses it.
* `outputsFor` with `mergeOutputs = [ [ "glibc" "glibc32" ] ]`: **225 outputs = 223 + debug +
  logs**, `out` first, the rest sorted, all unique shell identifiers, none reserved;
  `rpmOutputs` has 224 entries (`glibc32 = "out"`), `shippedRpmOutputs` 221, `unshipped` the 3.
  Without the merge: 226.
* Compared with the output names of the nixpkgs-faithful split spike that was actually built
  (`/nix/store/vyg5nzdi2vsvs21pc493mwhpkpv6j0ls-glibc-2.39-142.el10_2.drv`, 224 outputs,
  no merge, no debug/logs): the 223 common names are **identical**; only `glibc32` (merged
  here) and `debug`/`logs` (added here) differ. (The 224-output spec-generic drvs use
  verbatim suffixes, `devel`, `langpack-de`, so they are not comparable.)

## All 2198 SRPMs of the lock (shipped subpackages)

`outputsFor` over every `bySrpm` entry (prefix: eponymous > `-libs`, else the shortest
name as a stand-in for the lock generator's filelist rule):

| | |
|---|---|
| SRPMs | 2198 |
| outputs (incl. debug + logs) | 11303 |
| SRPMs without eponymous / `-libs` subpackage (need `subpackages.json` prefix) | 264 |
| largest SRPM | texlive, 378 subpackages |
| collision fallbacks | 2 (`perl-lib`, `perl-libs` → `perl_lib`, `perl_libs`) |
| non-identifier / reserved fallbacks | 12 |
| failures | 0 |

The 12: `boost-system`, `cockpit-system` (`system`); `fence-agents-all`, `git-all` (`all`);
`golang-src`, `java-21-openjdk-src`, `java-25-openjdk-src`, `rust-src` (`src`, which
would become `$src`); `kernel-debug`, `python3.14-debug` (our `debug`);
`xorg-x11-fonts-100dpi`, `-75dpi` (not identifiers). Each uses its full sanitized name.
These two refinements of §2.12 are documented in `lib/rocky/names.nix` and
`packages/README-overrides.md`.

## Overrides

Schema = §8.1 exactly (25 fields; nested records `bconds`, `inputs`, `forward`,
`lateBind.<o>`, `specSubstitutions[i]`). Errors are collected (all at once), each prefixed
with the file, e.g. for the `bad` fixture:

```
lib/rocky/tests/names-overrides/bad/default.nix: unknown key `mergeOutput` (known: allowUnresolvedNeeded, ...)
lib/rocky/tests/names-overrides/bad/default.nix: `doCheck`: expected a bool, got string "yes"
lib/rocky/tests/names-overrides/bad/default.nix: unknown key `lateBind.common.interp` (known: interpreters, libs)
```

Cross-field rules: merge groups ≥ 2 and disjoint, `runtimeSearchPaths` values ∈ unions
table, `lateReferrers` keys ∈ `lateBind`, `defines`/`layout` keys are macro names,
`defines` values single-line. The §11.5 glibc override (with stand-in store paths)
validates. `validate` throws (catchable by `tryEval`); `errors` returns the list.

## Unions

15 variables of §4.1 (`PYTHONPATH` for "python .pth/PYTHONPATH"), `kind` list/single,
`when` build/run. `profileScript` was run by bash in the check on a fake root: exports only
existing paths, prepends to existing values, `single` kinds do not override a set value.

## Not done / open

* `subpackages.json` (WP1) not available: the real-lock comparison test is skipped and
  reported as such in the check output. (Fixed in names-fix.md: the loader reads WP1's
  actual format, and the test fails when the file exists without a glibc entry.)
* The partitioner hook generator (WP5) and profiles are not written here; the hook-line
  contract is in the header of `lib/rocky/unions.nix`.
