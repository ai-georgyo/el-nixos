# WP8: kernel-headers relocated (`rockyBoot.s1.kernel-headers`)

Branch `nn/wp8`, built on `nn/wp6` (abca219). Design: `docs/nix-native-design.md`
§12 WP8. Recipe: the FHS twin `packages/kernel-headers.nix`
(`docs/kernel-headers.md`).

## What exists

| file | role |
|---|---|
| `packages/kernel-headers/default.nix` | overrides of the kernel-headers **variant** of the kernel SRPM: headers-only bconds, `prefixSubpackage`, `builtSubpackages`, `runtimeLibc = false`, `inputs.drop` / `inputs.buildRequires` |
| `packages/kernel-headers/headers-only.nix` | the recipe data shared with the FHS twin: `withouts`, `builtSubpackages`, the 21 `leakedPaths`, the content oracle (`packages/kernel-headers.nix` now imports its lists from here; its derivations are unchanged, see below) |
| `lib/rocky/stage.nix` | new: `variants`, `rpmConfigWith`, fallback `macroPkgs`, `inputs.buildRequires` resolution, `variantBuilt`/`variantOf` |
| `lib/rocky/mk-rpm-package.nix` | new: `pname` (variant name), `builtSubpackages`, `runtimeLibc`, per-package rpm config from `deps.macroPkgs` |
| `lib/rocky/overrides.nix`, `packages/README-overrides.md` | schema + docs: `builtSubpackages`, `runtimeLibc`, `inputs.buildRequires` |
| `bootstrap/nn/s1.nix` | `variants = { kernel-headers = "kernel"; }` replaces the interim stage0 copy; fallback entries for the kernel's BuildRequires |
| `lib/rocky/checks/kernel-headers.nix` | `checks.nn-kernel-headers` |

## Decisions

* **A variant, not the SRPM.** `rockyBoot.s1.kernel-headers` is
  `mkRpmPackage stage { srpm = "kernel"; pname = "kernel-headers"; }`, listed
  in mkStage `variants`. The override file is
  `packages/kernel-headers/default.nix`, the store name is
  `kernel-headers-6.12.0-211.66.1.el10_2[-<output>]`. A full kernel build later
  is `packages = [ "kernel" ]` with `packages/kernel/default.nix` and does not
  collide. Stage functions keyed by SRPM (`ccFor`, `libcFor`,
  `exceptionsFor`, `resolveBuildDeps`) still get `"kernel"`.
* **Only the built subpackages** (`builtSubpackages`, new override field).
  `subpackages.json` lists the 54 subpackages of a default-bcond parse. With
  the 16 `--without` switches, rpmbuild produces `kernel-headers` and the
  spec's unconditional, empty `kernel-modules-extra-matched`, and no
  debuginfo. `builtSubpackages` restricts `names.outputsFor` input (names and
  debug list) to these. Every name must be in the lock (an eval error
  otherwise, tested). The plan's `subpackages` follows, so the partitioner
  still fails on any difference.
* **Output names: `out`, not `dev`.** The design text (§12) says
  `$dev/include`. The names rule (§2.12) gives `dev` only to `<srpm>-devel`.
  The SRPM's prefix subpackage `kernel` is not built, so
  `prefixSubpackage = "kernel-headers"` makes it `out`. Headers are at
  `<out>/include`; `lib.getDev` falls back to `out`. The meta package is
  `modules_extra_matched` (only `nix-support/rpm*` metadata). It is shipped
  by Rocky, so `nn.stages.s1.rpm."kernel-modules-extra-matched"` aliases it.
* **`runtimeLibc = false`** (new override field). The outputs hold headers
  only. The stage0 libc and cc build the host tools (kconfig, fixdep,
  unifdef, relocs) and must not be allowed in an output: no runtime input,
  `allowedStorePaths = [ ]`, `inputLibDirs = [ ]`, and `outputChecks`
  allowedReferences = allowedRequisites = the two siblings. S1's
  `exceptionsFor "kernel"` is `[ ]`.
* **No S1 package as input** (`usesStagePackage` false for kernel, as for
  glibc). The BuildRequires `which` and `xz` would otherwise resolve to S1's
  Rocky which/xz. With `glibc1 = true` those link glibc¹, and glibc¹ takes
  kernel-headers as input, which is a cycle (found by `nn-s1-smoke`'s
  evaluation of `s1Glibc1`). Now kernel-headers is the same derivation in
  `s1` and `s1Glibc1` (tested), and it builds before everything else (the
  design order: kernel-headers, glibc¹, the rest).
* **BuildRequires.** 44 inputs in `builddeps.json`:
  * The override drops 15 that only the switched-off parts use: doc tools,
    dwarves, elfutils-devel, kabi-dw, kmod, hmaccalc, net-tools,
    openssl-devel, perl-Carp/devel/generators, python3-pyyaml, glibc-static.
    glibc-static would also be a cycle with glibc (found at evaluation).
  * The override adds 2 with `inputs.buildRequires` (new field: extra
    BuildRequires resolved like the lock's):
    * `rsync`, for `make headers_install`. The spec has
      `BuildRequires: rsync` under `%if %{with_headers} || %{with_cross_headers}`,
      but the lock's set lacks it. Lock finding, not fixed here.
    * `python3-rpm-macros`, for `%py3_shebang_fix`. Rocky's buildroot has it
      through python3-devel's Requires.
  * New S1 fallback entries:
    * `openssl`: nixpkgs bin, for the x509 conversion in `%prep`.
    * `rsync`: nixpkgs.
    * `rocky-sb-certs`: the stage0 tree, in the view. `%prep` reads
      `%{_datadir}/pki/sb-certs/*.der`, which resolves through the `$out`
      alias.
    * `kernel-rpm-macros` and `python3-rpm-macros` (+ `python-rpm-macros`):
      stage0 trees as `macroPkgs`.
    * `redhat-rpm-config`, `rpm-build`, `elfutils`: drops (the stage machinery
      and baseTools).
* **Whole macro package trees** (fallback `macroPkgs`, mkStage
  `rpmConfigWith`). Design §5.5 copies only `lib/rpm/macros.d` of macro
  inputs (`NIX_RPM_MACRO_DIRS`), which is not enough here:
  * `%py3_shebang_fix` runs `%{_rpmconfigdir}/redhat/pathfix.py`, which is
    in python-rpm-macros.
  * kernel-rpm-macros ships `redhat/` scripts (kmodtool, find-provides.ksyms,
    brp-kmod-*) and `fileattrs/` (kabi, modalias, ksyms generators).

  A package whose inputs bring `macroPkgs` gets its own
  `rpmConfig { macroPkgs }` (a cheap copy derivation). All other packages
  keep sharing `stage.rpmConfig`, so which/xz/zlib-ng/gzip are unchanged.
* **The interim is gone.** `extraPkgs.kernel-headers` (the hoisted stage0 RPM
  tree) is replaced by the variant. Consequences for glibc (WP7):
  * `rockyBoot.s1.glibc`'s derivation changes (new input path; the header
    bytes are identical, see the oracle).
  * kernel-headers is now Rocky-built, so it is a runtime input of glibc.
    glibc's outputs may reference it (allowedReferences, allowedStorePaths).
    That matches Rocky (glibc-devel Requires kernel-headers) and design §5.6.
    It also means an accidental reference is no longer an outputChecks
    failure.

## Results (real builds, this branch)

`nix build -L --cores 8 --max-jobs 2`, local sandbox.

| attribute / check | result |
|---|---|
| `rockyBoot.s1.kernel-headers` | **built**. `out` = `/nix/store/p2lcw46jgpn7z53rklx9g3ya0s6cj93n-kernel-headers-6.12.0-211.66.1.el10_2` (`include/` 1065 paths + `nix-support/`), `modules_extra_matched` = `/nix/store/w8fm3r88…-modules_extra_matched` (metadata only), `logs`. Partition: 2 subpackages, 0 errors, 0 warnings, 0 info. `--check-shebangs`: 0. rpmbuild ~1 min (`%prep` with configchecks, `%py3_shebang_fix` via pathfix.py, x509 of the sb-certs through the `$out` alias, InitBuildVars, headers_install). Only rpm warning: `File not found: …/include/cpufreq.h` (the spec's `%exclude`, as in the FHS build). `nix-store -q --references`: nothing, for both outputs |
| `checks.nn-kernel-headers` | **passes**: 13 eval and 16 build assertions (`/nix/store/b2bk9qhjhnrfk0kkkp3ah0v9nabcc152-nn-kernel-headers`). File list = the official RPM's `/usr/include` list mapped to `include/`, minus exactly the 21 leaked tools headers (1065 vs 1086). Contents byte-identical (`diff -r`), file types equal, content oracle `3c2cc557…d3f8` equal to the FHS twin's. Transient-RPM metadata: NEVR, provides (3), requires (4), obsoletes (1) equal to the official RPM's. Closures = each output alone. A C program with `-I<out>/include` sees RHEL_MAJOR 10, Linux 6.12, `__NR_io_uring_setup` 425 |
| first build (before the usesStagePackage change: which/xz from S1 as tools) | also built, 0 errors, check passed (`/nix/store/5zx6v2a6…`); superseded |
| `nix build --rebuild .#rockyBoot.s1.kernel-headers` | **passes**: out, modules_extra_matched and logs are bit-identical |
| `checks.nn-names` | passes (README documents the new fields) |
| `nn-s1-smoke`, `nn-purity`, `nn-rpm-config`, `nn-order`, `nn-partition-selftest`, `nn-shim`, `nn-cc-toolchain` | derivations unchanged by this branch (dry-run: nothing to build, already built green by WP6). The eval-time assertions of `nn-s1-smoke` are part of its derivation, so they hold |
| `rockyBoot.s1.{which,xz,zlib-ng,gzip}` | unchanged derivations (cached) |
| `stage0.kernelHeadersBuild`, `stage0.tests.kernelHeaders` (FHS twin) | unchanged derivations (cached), after the move of its lists to `headers-only.nix` |
| `rockyBoot.s1.glibc` | derivation changes (kernel-headers input); **not built** here (WP7) |

## Open issues

* `builddeps.json` misses kernel's conditional `BuildRequires: rsync`. The
  lockgen also uses default bconds only, which is why `builtSubpackages`
  exists. Both are lock findings, not fixed here.
* The extended rpm config (`rpmConfigWith`) is not in `allowedBuildDrvs`.
  S1 is not buildPure. A buildPure stage must add the per-package configs, or
  build its macro packages as stage packages.
* `kernel-modules-extra-matched` is exposed (output and `rpm.*` alias)
  although it only Requires packages a headers-only build does not make.
  It is what the spec builds; dropping it would need a partition option to
  ignore a built subpackage.
* The S1 fallback entry `bc` (nixpkgs) is on PATH, unused by the headers path
  (as in the FHS build).
* `kernel-cross-headers` stays off (`--without cross_headers`), as in the FHS
  twin.
