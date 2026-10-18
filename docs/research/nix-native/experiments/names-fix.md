# names-fix: review fixes for WP6a (names, overrides schema, unions table)

Branch `nn/names` (on top of cb8ca61). The original record is [names.md](names.md).

## Commands

```
git add -A
nix build -L --cores 6 --max-jobs 2 --no-link --print-out-paths .#checks.x86_64-linux.nn-names
#  -> /nix/store/lx3na9x75p5ap79cnid0c63ak3mlvg1r-nn-names
#     44 eval-time + 11 build-time tests, 0 failed ($out holds all 55 lines + "0 failed")
```

## 1. subpackages.json: WP1's actual format (major)

WP1 (`tools/lock_subpackages.py`, branch `nn/lock`, 35-SRPM seed) writes
`{ format = 1; srpms = { <srpm> = { names; debug = [ ... ]; prefix; shipped; ... }; }; failed; coverage; ... }`.
`names` excludes debug packages and `debug` is a *list*. The old loader unwrapped
only `subpackages`/`bySrpm` and so silently fell back to the fixture. On top of
that, `outputsFor` failed on a list-valued `debug` ("expected a Boolean").

Fix:
* `parts/names.nix` reads `format = 1` / `srpms` (bare `{ <srpm> = entry; }` still
  accepted; an unknown `format` is an eval error) and exposes `subpackagesDoc`.
* `outputsFor` accepts `debug` as a list (it is merged into the names, and those map
  to `debug`) or a bool. It errors on other types and on list members that are not
  debug names. `isDebugName` now also matches WP1's `-debuginfo-common-`. Debug
  packages are never "unshipped".
* `subpackagesFor srpm` = lock entry, else fixture, else an **eval error**. The error
  names the lock file, its coverage or recorded failure, and
  `python3 -I tools/lock_subpackages.py <srpm>`. It no longer guesses silently from
  rpms.json (no unshipped subpackages there, which §3.2 makes a build error).
  `subpackagesOrRpms` is the explicit lenient variant.
* The check's "lock entry = fixture" test FAILS when the lock file exists without a
  glibc entry. It is skipped only when the file does not exist. A new test runs
  `outputsFor` over every lock entry.

Verified with WP1's in-progress file (copied from worktree wf_9a971b8a-060-5 and
staged; **not committed**, because WP1 owns it):

| run | result |
|---|---|
| WP1 file staged | 0 failed; "glibc lock entry = fixture [compared: 224 names, debug [glibc-debuginfo, glibc-debugsource]]"; "225 outputs (subpackages from the lock)"; "every lock entry gives valid outputs [35 entries, coverage {failed 0, missing 2182, ok 35, srpms 2217}]" (/nix/store/7lp0grisnkxannhp95w4gs6mdp14hwp5-nn-names) |
| WP1 file minus glibc | 1 failed: "glibc lock/subpackages.json entry = fixture [the lock file has no glibc entry]" |
| `outputsFor { srpm = "bash"; sub = subpackages.bash; }` | outputs out dev doc debug logs; unshipped { bash-doc = doc }; debuginfo/debugsource -> debug |
| `subpackagesFor "zsh"` (not in the seed) | `error: nn.names: no subpackage list for zsh: lock/rocky-10.2/subpackages.json has no entry (coverage: {...,"missing":2182,...}); run python3 -I tools/lock_subpackages.py zsh` |

The tests for krb5, perl and xorg-x11-fonts now call `outputsFor` over
`fromRpms` explicitly. They test name rules, and lock coverage should not affect
them. (WP1's krb5 entry adds the unshipped `krb5-tests`.)

## 2. LOCPATH vs LOCALE_ARCHIVE (major)

Measured with nixpkgs glibc 2.42-100 (`localedef`, `locale`): an archive holding
en_US.UTF-8 and a directory-format de_DE.UTF-8:

| env | `LC_ALL=... locale -k abday` |
|---|---|
| `LOCALE_ARCHIVE=<archive>`, en_US | `abday="Sun;Mon;..."` |
| same + `LOCPATH=<dir of the archive>` | `Cannot set LC_CTYPE to default locale` |
| `LOCPATH=<de dir>`, de_DE | `abday="So;Mo;..."` |
| `LOCALE_ARCHIVE` + `LOCPATH=<de dir>`, en_US | `Cannot set LC_CTYPE ...` |

The reviewer was right: glibc reads the archive only when LOCPATH is unset. The old
table exported LOCPATH for every `lib/locale`, all_langpacks included.

Fix in `lib/rocky/unions.nix`: entries gain `provider` and `yieldsTo` (every entry has
all 7 keys).
* LOCPATH has `provider = "*/LC_CTYPE"`: only directory-format locales count.
* LOCPATH has `yieldsTo = [ "LOCALE_ARCHIVE" ]`:
  * in a profile, a root that provides the archive unsets LOCPATH;
  * in build hooks, LOCPATH lines are guarded by `[ -n "${LOCALE_ARCHIVE-}" ] ||`,
    and the LOCALE_ARCHIVE line is followed by `unset LOCPATH`, so the result does
    not depend on hook order.

The archive of all_langpacks holds every locale, so it wins. New `hookScript o`
is the reference implementation of the hook contract (header of unions.nix).

Build-time tests (bash, in the check):
* profileScript over langpack / archive-only / archive+langpack / empty roots;
* hookScript over a langpack output and an all_langpacks output, in both orders,
  plus pkgconfig order;
* end to end with nixpkgs glibc: archive+langpack profile → en_US from the archive;
  control with LOCPATH forced → "Cannot set LC_CTYPE"; langpack-only → de_DE via
  LOCPATH.

Mutation check: restoring the old LOCPATH semantics (`provider = null; yieldsTo = [ ]`)
makes **7** tests fail. Reverting gives the green path above.

## 3. Minor findings

* `overrides.errors` on a function-valued field: `describe` now says "a function
  (missing an argument?)" instead of calling `toJSON`. Tested via `tryEval`:
  `doCheck = x: true`, `allowUnresolvedNeeded = lib.optionals true`, `env.X = x: x`,
  and a whole file that is a function.
* Shape checks:
  * `layout` values must be output names (identifiers);
  * `lateBind` keys must be identifiers;
  * `lateReferrers` values must be identifiers or globs over them;
  * `runtimeSearchPaths` / `unionDirs` keys and `danglingOk` items must be
    output-relative paths (no leading or trailing `/`, no empty, `.` or `..`
    component);
  * `noPatchelf`, `opaqueRefs` and `forward.deny` must be relative globs;
  * `specSubstitutions[].from` must be non-empty.

  New `outputErrors` / `checkOutputs file overrides outs` cross-check `layout`
  values and `lateBind`/`lateReferrers` keys and values against
  `outputsFor(...).outputs`. The §11.5 glibc example passes against glibc's 225
  outputs.
* The test count in names.md is corrected (36 eval + 1 build). Build-time results
  are now in `$out`.
* The override fixtures moved to `lib/rocky/tests/names-overrides/{good,bad}`, a
  directory named after this work package. It is still outside the literal
  owned-file list, which the orchestrator has to approve.
* Heads-up on nixpkgs `multiple-outputs.sh`: verified in nixpkgs 26f4107. The file
  adds `_multioutDocs` and `_multioutDevs` (preFixup), `_multioutPropagateDev`
  (postFixup) and `_multioutConfig` (preConfigure), and has no `dontMoveDocs`. This
  is documented in the names.nix header and README-overrides.md, and requested of
  WP6.
* I18NPATH is now `build` + `run`. The PYTHONPATH python3.12-only limitation is
  stated in the unions.nix header and in its doc string.

## Not done

* WP1's subpackages.json is not committed here: WP1 owns it. Until it lands,
  `subpackagesFor` works only for glibc (fixture) and throws for every other SRPM.
  `subpackagesOrRpms` exists for exploration.
* The design text §2.12 still lacks the reserved/non-identifier fallback. §4.1/§4.2
  could mention the LOCPATH/LOCALE_ARCHIVE rule. Both are for the design owner.
