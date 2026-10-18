# WP6: mkRpmPackage, mkStage, stage S1

Branch `nn/wp6` (base b9fdc83). Design: `docs/nix-native-design.md` §5.3–5.6,
§6 S1, §7.1, §11.1, §11.2, §12 WP6.

## What exists

| file | role |
|---|---|
| `lib/rocky/mk-rpm-package.nix` (`nn.mkRpmPackage stage { srpm; overrides ? ...; }`) | one multi-output derivation per SRPM |
| `lib/rocky/stage.nix` (`nn.mkStage { ... }`) | a stage as a lazy fixpoint: `pkgs`, `rpm.<rpm-name>`, `resolveBuildDeps`, libc/cc/exception selection, purity wiring |
| `bootstrap/nn/s1.nix` | stage S1 (`nn.stages.s1`, `nn.stages.s1Glibc1`) |
| `lib/rocky/parts/{mkRpmPackage,mkStage,stages,rockyBoot}.nix` | plug-ins; `legacyPackages.x86_64-linux.rockyBoot.s1.<srpm>` |
| `lib/rocky/checks/s1-smoke.nix` | `checks.nn-s1-smoke` |
| `packages/zlib-ng/default.nix` | S1-only override (`WITH_GTEST=OFF`) |

## Results (real builds, this branch)

RESULTS_PLACEHOLDER

## The derivation (what mkRpmPackage does)

* `outputs` = `names.outputsFor` (out first, the rest sorted, `debug`,
  `logs`); `__structuredAttrs`, `strictDeps`.
* `unpackPhase`: `bsdtar` of the locked SRPM (`fetchSrpm`, a lock FOD) into
  `rpmbuild/SOURCES`; `specSubstitutions` on the copy in `rpmbuild/SPECS`
  with an exact occurrence count (python, not `grep -c`, so two hits on one
  line count twice).
* `configurePhase`: `<rpmConfig>/nix/instantiate` with `--prefix $out
  --dist <distOf srpm>` (→ `%distcore`, appended to `redhat/macros`),
  `NIX_RPM_MACRO_DIRS` from macro inputs and fallback `macroDirs`;
  `CONFIG_SITE` = `lib/rocky/config.site` + the override fragment;
  `NIX_PREP_PATCHES` / `NIX_PREP_SCRIPT` (a file) for `%__spec_prep_post`.
* `buildPhase`: `${toolShim} -- env -u SOURCE_DATE_EPOCH [-u CONFIG_SHELL
  PATH=/usr/bin SHELL=/bin/bash] ['k=v'...] rpmbuild -bb --nodeps --noclean
  [--nocheck] --target x86_64 [--define ...] [--with/--without ...]`;
  `rockyViewInputs` (structured attr, read by mkview.py) = host inputs + the
  libc's dev; `RPM_CONFIG_DIR`; `ROCKY_PREFIX_VIEW` = `prefixView`;
  `NIX_ROCKY_MAP_ROOTS` += `$out` while the alias is mounted.
* `installPhase`: the plan = structured `rockyPlan` + `buildroot`/`rpmsDir`/
  `outputs`/`reportFile` found at build time → `$NIX_BUILD_TOP/plan.json`;
  `python3 -I <partitionTool>/rocky-partition --plan plan.json`; the `logs`
  output gets `build.log`, the report, the plan and the view collisions with
  every store hash replaced by `eeee…` (so `logs` references nothing);
  `-devel` outputs get `nix-support/propagated-build-inputs` (below); the
  moving hooks of `multiple-outputs.sh`/`move-docs.sh` are removed from
  `preFixupHooks`/`postFixupHooks`.
* fixup: only `patchShebangs --host` (HOST_PATH = buildInputs' `bin`, i.e.
  runtime inputs, thanks to `strictDeps`) and audit-tmpdir; `dontStrip`,
  `dontPatchELF`, `dontMoveLib64`, `dontMoveSbin`, `dontMoveSystemdUserUnits`,
  `dontGzipMan`, `dontPruneLibtoolFiles`, `dontRewriteSymlinks`,
  `dontCheckForBrokenSymlinks`, `setOutputFlags = false`, `moveToDev = false`,
  `propagatedBuildOutputs = ""`.
* `outputChecks.<o>.allowedRequisites` (every managed output) = sibling
  outputs minus `debug`/`logs` + the runtime closure; `debug` additionally
  itself; `logs.allowedReferences = [ ]`.
* runtime closure = `stage.exceptionsFor srpm` + the runtime libc
  (`stage.runtimeLibcFor`, none for the libc itself) + Rocky-built host
  inputs' `passthru.rockyRequisites` (inductive). The same list is the
  plan's `allowedStorePaths`; its `lib64`/`lib` dirs are `inputLibDirs`.
* passthru: `rockyStage srpm rpmOutputs shippedRpmOutputs unshipped
  overrides rockyOutputs rockyRequisites rockyDeps rockyPlan`; the result
  goes through `stage.purity.check stage` (no-op unless `buildPure`).

## Design deviations (and why)

1. **PATH=/usr/bin and a mock shell environment for every S1 package**
   (`stage.fhsPath`, design §5.4 says only for packages below the
   interpreters). In S1 no interpreter is Rocky-built, so every store path a
   configure script could record is a nixpkgs one. Measured: the first gzip
   and xz builds failed the partition with `foreign-store-path`
   `#!/nix/store/…-bash-5.3p9/bin/bash` in 12 + 4 scripts and in the rpm
   header's auto-Requires — from stdenv's `CONFIG_SHELL` (autoconf writes
   `#! @SHELL@` = `$CONFIG_SHELL`), not from PATH. So rpmbuild also runs with
   `CONFIG_SHELL` unset and `SHELL=/bin/bash` (what mock sets): the scripts
   now say `#!/usr/bin/sh`, as in the official RPMs.
2. **The view holds host (library) inputs and the libc's dev only; tools
   are PATH-only** (§1.5 puts every input's include/lib/share in the view).
   This enforces the shim's "library rule" (every library reachable through
   the view is also a cc-wrapper input) by construction, keeps nixpkgs tool
   packages' headers/libraries out of gcc's built-in `/usr/include` and ld's
   `/usr/lib64` search (the stage0 gcc has no no-sys-dirs patch), and costs
   nothing for relocated tools (they find their data by their own store
   paths). A fallback entry can still put a tree into the view (`view = [ ]`;
   used for stage0 texinfo, whose makeinfo reads `/usr/share/texinfo`).
3. **The libc's dev is the last view input** (§1.5 says declared inputs
   only): Rocky's buildroot always has glibc-devel in `/usr/include`
   (gcc Requires it); first-wins keeps any declared input in front.
4. **Runtime vs build-only inputs** (§5.6/§7.1 do not distinguish): only the
   stage libc, Rocky-built host inputs (they carry `rockyRequisites`) and the
   named stage exceptions may be referenced; nixpkgs/stage0 trees given via
   the fallback set or `inputs.add` (glibc's `glibcBuildDeps`) are build-only
   — not in `inputLibDirs`, not in `allowedStorePaths`, not in
   `allowedRequisites`. This is what keeps memusagestat's nixpkgs libgd out of
   glibc¹'s RUNPATH.
5. **`-devel` outputs propagate the sibling outputs they Require**
   (§5.6 wants this from `deps.json.gz` at eval time; there is no such lock
   file yet): mkRpmPackage reads the partition report's `outputRequires`
   (unique-provider Requires from the transient headers) and writes
   `nix-support/propagated-build-inputs` of every output holding a `*-devel`
   subpackage (xz: dev → lib; zlib-ng: dev → out, compat_devel → compat).
6. **ld-wrapper hook for the -devel/-libs split** (new,
   `lib/rocky/cc/ld-rpath-devel.sh`): nixpkgs' ld-wrapper adds `-rpath D` for
   the -L dir D where `libfoo.so` was found; in a Rocky split that is
   `$dev/lib64`, which has only the unversioned link, so a consumer built
   with `buildInputs = [ xz.dev ]` did not start (`liblzma.so.5: cannot open
   shared object file`, first nn-s1-smoke run). The hook adds the link
   target's directory (`$lib/lib64`) too. mkRpmPackage builds do not need it
   (Phase E recomputes RUNPATH from DT_NEEDED).
7. **rocky-partition: RUNPATH entries are checked after Phase E** (case 7).
   The first `which` build failed with `foreign-store-path` for the gcc copy
   `rocky-s1-gcc-14.3.1`: the ld-wrapper's `-rpath <gcc>/lib/gcc/x86_64-
   redhat-linux/14` (a -L dir holding libgcc_s.so) was counted although
   Phase E drops it (the handoff's cc request "drop RUNPATH entries for -L
   dirs that hold only scripts or links" is exactly what Phase E does). Hashes
   inside an ELF's RUNPATH/RPATH bytes are now decided on the final RUNPATH
   (`Refs.check_rpath_foreign`).
8. **rocky-partition: CMake export files** (new info code
   `cmake-expanded`): zlib-ng's `zlib-ng.cmake`/`ZLIB.cmake`
   (install(EXPORT) output in the -devel outputs) define
   `set(_IMPORT_PREFIX "<P>")` and name `${_IMPORT_PREFIX}/include` — a
   `prefix-relative` error, and wrong after the split (headers live in
   -devel). Like `.pc` files (R2/R3), the uses are written out in full and
   classified/rewritten (`$dev/include`); the unused definition is acked.
9. **`opaqueRefs` format settled to PLAN.md's output pattern**
   (`"<output glob>[:<rel glob>]"`); the draft `"<output>/<rel>"` form of
   `packages/glibc/default.nix` is converted when its first component is an
   output. New override keys `prefixRelativeOk`, `integrityOk`,
   `systemLibDirs` (PLAN.md keys; README-overrides.md documents them).
   `env` keys must match `[A-Za-z_][A-Za-z0-9_.+-]*`; identifier keys go into
   the structured `env`, the others only onto rpmbuild's command line
   (`env 'k=v'`).
10. **`layout`** (§2.7) is implemented as `--define "<macro>
    <placeholder output>/<rel>"` for the standard directory macros
    (`_bindir _sbindir _libdir _libexecdir _datadir _includedir _infodir
    _mandir _docdir _defaultdocdir _datarootdir _localedir`); others are an
    eval error. Not exercised by a build yet.
11. **Generated setup hooks**: the plan's `searchPaths` are the
    `lib/rocky/unions.nix` list variables used at build time without
    provider/yieldsTo, minus XDG_DATA_DIRS (every output with `share/` would
    get one). The partitioner's hook writer does not implement
    provider/yieldsTo (LOCPATH/LOCALE_ARCHIVE): those come only from
    `runtimeSearchPaths` overrides for now.
12. **`config.site` ends with `true`** (E2/E3 finding; the rpmconfig WP's
    file still ended in a `test … && …`).
13. **S1 package list**: `glibc which xz zlib-ng gzip` + an interim
    `kernel-headers` (Rocky's kernel-headers RPM tree from stage0, `$out/
    include`) until WP8. The design's other S1 members (macro packages, gmp,
    mpfr, libmpc, zstd, binutils¹, gcc¹) need fallback entries/overrides first
    (zstd: lz4-devel; gmp: git, perl-Carp; binutils: dejagnu, jansson, …).
14. **libc of the S1 packages: the stage0 libc tree** (`nn.cc.stage0Libc`)
    for now, also for packages the design builds after glibc¹; `nn.stages.
    s1Glibc1` (`glibc1 = true`) switches every S1 package except glibc and
    kernel-headers to `nn.cc.wrap { libc = rockyBoot.s1.glibc }`. Reason:
    glibc¹ is WP7's and unverified; the stage0 libc tree is a named S1
    exception (`exceptionsFor`), and its loader has FHS system dirs only, so
    S1 programs keep `<stage0Libc>/lib64` in RUNPATH (`systemLibDirs = [ ]`).
    glibc uses no S1 package (`usesStagePackage`): S1's zlib-ng links the
    stage0 libc and must not enter glibc¹'s closure; glibc's -devel deps come
    from `glibcBuildDeps` (stage0, hoisted, build-only).
15. **`stage.rpm` is the RPM-name alias set** (§11.2); the rpm package is
    `stage.rpmPkg` (`stage.rpmBin`, `stage.rpmLibDir`).
16. **`rockyBoot.s1` = the stage's `pkgs` only** (nix-eval-jobs recurses into
    `hydraJobs.nixNative`); the stage objects are `nn.stages.<stage>`.

## Fallback set (S1, `bootstrap/nn/s1.nix`)

Build-only, listed explicitly; `nn.stages.s1.fallbackReasons` prints the
table. `drop` entries map a BuildRequire to nothing (the stage cc, baseTools,
`%check`-only, or a hoisted stage0 tree for glibc); `tool` entries put a
nixpkgs package on PATH; texinfo is stage0's Rocky-source 7.1 (PATH + view);
cmake is nixpkgs cmake + Rocky's `macros.cmake` from the locked cmake SRPM
(`cmakeRpmMacros`, as cmake.spec's %install writes it). `readline-devel`
(which) is dropped: the official which binary NEEDs only libc.so.6.
baseTools (every package): bash coreutils sed grep gawk findutils diffutils
patch tar gzip bzip2 xz zstd cpio file (stage0 rpmLibs) util-linux procps make
perl elfutils dwz gdb hostname which, stage0's static ldconfig, gpgv2 (→
nixpkgs gpgv), gnupg, python3, bsdtar; FHS bins: stage0 rpm, debugedit.

## Hand-off requests: addressed / rejected

HANDOFF_PLACEHOLDER

## Open

OPEN_PLACEHOLDER
