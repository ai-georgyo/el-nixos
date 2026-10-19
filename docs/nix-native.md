# Nix-native Rocky packages: user and developer guide

Relocated, composable Nix store paths built from the official Rocky Linux 10.2
SRPMs: one derivation per SRPM, one Nix output per RPM subpackage, rpmbuild
as the spec engine. The design contract is
[`nix-native-design.md`](nix-native-design.md) (revision 2); this guide
says how to use and extend what it describes.

**Status (milestone M1, branch nn/m1).** `mkRpmPackage`/`mkStage` (WP6),
stage S1 with which, xz, zlib-ng, gzip, kernel-headers (WP8) and the
relocated glibc (WP7), the parity and runtime checks against the official
RPMs (WP9), the attributes below (WP10) and late binding (WP11, wired into
`mkRpmPackage`, inactive in S1) exist and are built. **M1 =
`rockyBoot.s1.glibc`**: 225 outputs, built by the stage0 gcc, closure = its
own outputs + `libgccForGlibc`, verified by `checks.nn-glibc-{files,abi,content,closure,runtime,smoke,hooks}`
(results in §7 and `research/nix-native/experiments/m1.md`). The S1
packages after glibc¹ (`nn.stages.s1Glibc1`: which, xz, zlib-ng, gzip) are
built and checked too (`checks.nn-s1-glibc1`). Not done yet:
the rest of S1 (macro packages, gmp … gcc¹), S2, S3 (`rocky.*`, M2),
profiles (§6), `keepBuildTree` (§5).

## 1. What a relocated package looks like

* **Store paths**: `/nix/store/<hash>-<srpm>-<version>-<release>[-<output>]`,
  e.g. `…-glibc-2.39-142.el10_2` (`out`), `…-glibc-2.39-142.el10_2-dev`.
  Store names do not depend on the bootstrap stage (design §2.12).
* **Layout inside an output**: Rocky's `/usr` tree without the `usr`
  component: `bin`, `sbin`, `lib64`, `lib` (32-bit and arch-independent),
  `libexec`, `include`, `share`. A file Rocky ships as `/usr/bin/ldd` is
  `<output>/bin/ldd`; `/lib64/x` and `/bin/x` (usrmerge spellings) fold to the
  same places.
* **Compile prefix**: the spec is built with `%_prefix` = the path of the
  output named `out` (design §3.1). Binaries are never rewritten: references
  to the other outputs are made by moving files, rewriting *text* files,
  recomputing RUNPATH and, rarely, forwarding symlinks (§5).
* **Runtime FHS stays FHS**: `/etc`, `/var`, `/run`, `/proc`, `/sys`, `/dev`,
  `/tmp`, `/bin/sh`, `/usr/bin/env` are compiled in unchanged (design §1.4).
  Files a spec installs under `/etc` or `/var` land in `<output>/etc`,
  `<output>/var` as defaults; nothing installs them on the host (§9).
* **ELF interpreter**: programs use the relocated loader,
  `<glibc>/lib64/ld-linux-x86-64.so.2` (32-bit: `<glibc>/lib/ld-linux.so.2`),
  whose system directories are `<glibc>/lib64` and the libgcc directories
  (design §4.2, measured in E5). Other libraries are found through RUNPATH.
* **Debug info**: all `*-debuginfo`/`*-debugsource` subpackages go to one
  `debug` output: `lib/debug/.build-id/xx/….debug` and `src/debug`
  (nixpkgs layout, for `NIX_DEBUG_INFO_DIRS`). DWARF names `/usr/…` paths
  exactly like Rocky's (prefix maps, design §5.1).
* **Metadata**: every output has `nix-support/rpm/<subpkg>.json` (file list
  with flags, modes, owners, caps, digests; Requires/Provides; scriptlets;
  triggers) and `nix-support/rpm-name`. The prefix output has
  `nix-support/rocky-report.json`, the partitioner's decision log.

## 2. Attributes

| attribute | meaning |
|---|---|
| `rockyBoot.s1.<srpm>` | the multi-output derivation of `<srpm>` in bootstrap stage S1 (`legacyPackages.x86_64-linux.rockyBoot.s1`): `glibc`, `kernel-headers` (the kernel SRPM headers-only, a mkStage variant), `which`, `xz`, `zlib-ng`, `gzip` |
| `rockyBoot.s1.<srpm>.<output>` | one output, e.g. `rockyBoot.s1.glibc.dev`, `.common`, `.langpack_de` |
| `rockyBoot.s1.rpm."<rpm-name>"` | alias by RPM name, e.g. `rockyBoot.s1.rpm."glibc-devel"` = `rockyBoot.s1.glibc.dev` (shipped subpackages only; 234 names in S1). `rpm` is reserved: the rpm SRPM, once built, is `rockyBoot.<stage>.rpm.rpm` |
| `rocky.<srpm>`, `rocky.rpm."<rpm-name>"` | the final stage S3, same shape (M2 and later; not yet) |
| `<pkg>.raw`, `<pkg>.bound`, `<pkg>.lateBound` | where a stage binds late outputs (§5.6): the rpmbuild derivation, the bind derivation, the bound output names |
| `passthru.rpmOutputs` | `{ "<rpm-name>" = "<output>"; }` for every subpackage (`shippedRpmOutputs`: shipped only) |
| `passthru.unshipped` | subpackages the spec builds but Rocky does not publish (glibc's `glibc32`, `sysroot-x86_64-el10-glibc`, `compat-libpthread-nonshared`); they are real outputs without an `rpm.*` alias |
| `passthru.rockyStage`, `passthru.srpm`, `passthru.pname`, `passthru.overrides` | stage name, lock name, variant name, validated overrides |
| `passthru.rockyRequisites`, `rockyOutputsByName`, `rockyCompanions`, `rockyPlan`, `rockyDeps` | closure bound for consumers, outputs by name, `-devel` companions, the partition plan, the resolved build inputs |
| `nn.stages.s1` | the stage object: `pkgs`, `rpm`, `resolveBuildDeps`, `glibcBuildDeps`, `libgccForGlibc`, `ccGlibc1` (the S1 toolchain over the relocated glibc + kernel headers), `glibc1Libc`, … ; `nn.stages.s1Glibc1` = S1 with every package after glibc linked against it (built by `checks.nn-s1-glibc1`); `develClosure srpm { names; drop; }` (the -devel propagation) |
| `hydraJobs.nixNative.x86_64-linux.<stage>.<srpm>` | `rockyBoot` without the `rpm` aliases (they name the same derivations), for `tools/build-jobs.sh`; plus `<srpm>-bound` = the bind derivation of a late-bound package (`nn.nixNative.jobsFor`): such a package's own `drvPath` (and `nix build <pkg>^*`) is the raw build, so build `<pkg>.bound` (or a bound output such as `<pkg>.common`) to get what consumers reference |

```sh
nix build -L .#rockyBoot.s1.glibc.dev                  # one output
nix build -L '.#rockyBoot.s1.glibc^*'                  # all 225
nix build -L '.#rockyBoot.s1.rpm."glibc-langpack-de"'  # by RPM name
```

The machinery is reachable as `legacyPackages.x86_64-linux.nn.<name>`
(plug-in layout of `lib/rocky/default.nix`: `lib/rocky/parts/<name>.nix` →
`nn.<name>`, `lib/rocky/checks/<name>.nix` → `checks.x86_64-linux.nn-*`):

| attribute | what it is |
|---|---|
| `nn.mkRpmPackage stage { srpm; pname ? srpm; overrides ? … }` | one derivation per SRPM (`lib/rocky/mk-rpm-package.nix`) |
| `nn.mkStage { … }` | a bootstrap stage as a lazy fixpoint (`lib/rocky/stage.nix`, parameters in its header) |
| `nn.stages`, `nn.rockyBoot` | the stage objects and their packages |
| `nn.lateBind` | `wrap raw { binds; referrers; … }`, `fromOverrides`, `mk` (§5.6) |
| `nn.nixNative` | `jobsFor <stage pkgs>` (the CI job set: packages + `<srpm>-bound`), `jobs.<stage>` (= `hydraJobs.nixNative`) |
| `nn.nnChecks` | `glibc { glibc; … }` parity/runtime check builder, `selftest`, `dev.replay` |
| `nn.cc` | S1 cc-wrapper: `wrap { libc }`, `libcAdapter`, `stage0Libc`, `stage0`, `storescan`, `e1.*` |
| `nn.toolShim` | the bwrap shim (`${nn.toolShim} [--no-prefix-view] -- cmd…`), `mk`, `mkview`, `e2.*` |
| `nn.rpmConfig` | rpm configuration + relocation macros + `nix/` helper scripts (`instantiate`), `configSite` |
| `nn.partitionTool` | `tools/rocky-partition` as a source path; `trees.*` test build trees |
| `nn.libgccForGlibc` | RUNPATH-free copy of the stage0 `libgcc_s.so.1` (64 + 32-bit) |
| `nn.lockgen` | `rpmspec -q` per SRPM for `subpackages.json` (`nix run .#lock-subpackages`) |
| `nn.names`, `nn.overrides`, `nn.unions` | output names, override schema, search-path table |
| `nn.purity` | eval-time build-purity assertion |

## 3. Output names and RPM aliases

One output per subpackage (`nn.names.outputsFor`, design §2.12):

1. the prefix subpackage (eponymous > `<srpm>-libs` > the version-less stem
   > most `/usr` files among non-test/doc/devel subpackages, chosen by the
   lock generator) → `out`;
2. `<srpm>-devel` → `dev`, `<srpm>-libs` → `lib` (unless it is the prefix);
3. every `*-debuginfo` / `*-debugsource` → `debug`;
4. `<srpm>-X` → `X`, other names verbatim;
5. `[^A-Za-z0-9_]` → `_`;
6. a name that collides, is not a shell identifier (`100dpi`) or is reserved
   (`src`, `system`, `all`, `env`, `name`, `version`, …) uses the full
   sanitized subpackage name instead (`perl_lib`, `perl_libs`,
   `xorg_x11_fonts_100dpi`, `rust_src`).

Plus `debug` (if the spec builds debug packages) and `logs`. Order: `out`
first, the rest sorted, then `debug`, `logs`. Merged subpackages
(`mergeOutputs`) share the representative's output; their RPM names alias it.

Examples (measured, [NM]): glibc's 224 subpackages give 225 outputs (223 +
`debug` + `logs`; `glibc32` merged into `out`): `out`, `dev`, `common`,
`utils`, `static`, `gconv_extra`, `locale_source`, `all_langpacks`,
`minimal_langpack`, `langpack_de`, …, `nss_db`, `nss_devel`,
`sysroot_x86_64_el10_glibc`. krb5 has no eponymous subpackage: `krb5-libs` is
`out`.

The subpackage list comes only from `lock/rocky-10.2/subpackages.json`
(`rpmspec -q --builtrpms` of the locked SRPM); an SRPM without an entry is an
evaluation error. Regenerate with `python3 -I tools/lock_subpackages.py
--stale`, then `python3 -I tools/update-lock.py --derived-only`.

## 4. Per-package overrides

Most SRPMs need no override. A package that does gets
`packages/<srpm>/default.nix`, a function of `{ lib, stage, rocky }`
returning a typed attribute set; every field, its type, default and meaning
is documented in **[`packages/README-overrides.md`](../packages/README-overrides.md)**
(validated by `nn.overrides`; unknown keys are evaluation errors naming the
file and key).

```nix
# packages/ncurses/default.nix (E3 result; not committed yet)
{ ... }: {
  prefixSubpackage = "ncurses-base";                       # data subpackage as out
  runtimeSearchPaths."share/terminfo" = "TERMINFO_DIRS";
  # prefixRelativeOk = [ "dev:bin/ncurses*-config" ];      # pending field, see below
}
```

Typical needs, from the experiments (design §2.7, §2.5.1):

| situation | field |
|---|---|
| the libraries compile in a data directory of another subpackage | `prefixSubpackage` |
| a reference cycle, or programs of a non-prefix output that run each other by prefix path | `mergeOutputs` |
| a compiled-in default that a search path serves (locales, gconv, terminfo) | `runtimeSearchPaths` |
| a directory several outputs fill (plugin dirs) | `unionDirs` |
| a compiled-in path that exists nowhere on purpose (`share/zoneinfo`) | `danglingOk` |
| store-by-pieces copies of the prefix outside `out` | `opaqueRefs` |
| a library whose RUNPATH must not change (loader, libc, FIPS modules) | `noPatchelf` |
| the spec reaches its build deps through a path the view cannot provide | `specSubstitutions` (or `prefixView = false`) |
| Nix-side patches (glibc P1–P3) | `nixPatches`, `prepScript` |
| a make variable with a non-identifier name | `env."<name>"` (passed as `env 'name=value' rpmbuild`, never in the structured derivation env) |

Fields added by WP6–WP8 (all in the README): `prefixRelativeOk`,
`integrityOk`, `systemLibDirs`, `builtSubpackages` (a variant that builds
part of a spec: kernel-headers), `runtimeLibc`, `inputs.addBuildOnly`
(glibc's kernel-headers: host input, never a runtime input),
`inputs.buildRequires`. `opaqueRefs` uses PLAN.md's `"<output>[:<rel glob>]"`.

## 5. How splitting works

One derivation per SRPM does everything (design §0.1, §2):

1. **Unpack** the locked SRPM; apply `specSubstitutions` (counts asserted).
2. **Configure**: `nix/instantiate` writes the per-build rpm config
   (relocation macros appended to `redhat/macros`, `%_prefix = $out`,
   `%distcore` of the SRPM); `CONFIG_SITE` = the generic `config.site` + the
   package fragment.
3. **rpmbuild -bb --noclean** inside the tool shim: `/usr` is a read-only view
   of the *declared* inputs only (overlayfs), `/usr/lib/rpm` the config, and
   the same view mounted at `$out` while rpmbuild runs, so specs that look for
   build deps under `%{_includedir}`/`%{_libdir}` work unmodified. The
   cc-wrapper maps every input and `$out` to `/usr` in debug info.
   `%install` writes `BUILDROOT/$out/…` (`BUILDROOT/usr` is a link to it);
   brp scripts and find-debuginfo run as in Rocky.
4. **Partition** (`rocky-partition`, design §2): read the transient RPM
   headers, move every file to the output of the subpackage that owns it,
   fix symlinks, rewrite text references to other outputs (`.pc`, `.la`,
   ld scripts, scripts), recompute RUNPATH from `DT_NEEDED` (keeping FIPS
   `.hmac` files valid), create forwarding stubs only where nothing else
   works and the graph stays acyclic, register hidden references, check the
   output graph for cycles, write metadata and setup hooks. Every decision is
   in `$out/nix-support/rocky-report.json`.
5. **Fixup**: `patchShebangs --host` binds FHS shebangs to runtime inputs; no
   strip (rpm did it), no nixpkgs output moving.
6. **Late binding** (`nn.lateBind`, design §2.9, §11.3): outputs whose
   interpreters or libraries are built later (glibc's `common`, `utils`,
   `nss_db`, `benchtests`) get a cheap bind derivation that copies those
   outputs and the sibling outputs that reference them (`lateReferrers`:
   138 langpacks, `nss_devel`), rewrites raw hashes in symlinks and text,
   binds shebangs (patchShebangs against the interpreters) and RUNPATH
   (the libs that resolve an unresolved `DT_NEEDED`), and refuses ELF
   contents that reference a raw late output. `mkRpmPackage` returns
   `lateBind.wrap raw` when the package declares `lateBind` **and** the
   stage binds it (`mkStage { lateBindFor = srpm: …; lateBindPkgs;
   interpreterPkgs; }`, from S3); the result keeps `.raw`, and each output
   carries its own `rockyRequisites` (a consumer of `glibc.out` never sees
   the bind derivation). Nix checks the bound outputs like any other:
   `allowedReferences`/`allowedRequisites` are raw's (late siblings by name)
   plus the binds' outputs and `rockyRequisites`, and the raw late outputs
   are `disallowedRequisites`. CI builds the bind derivation through the
   `<srpm>-bound` job (§2). S1 does not bind (no Rocky bash/perl/python3/gd
   yet): `rockyBoot.s1.glibc` is the raw build and names its FHS shebangs
   and unresolved `NEEDED` as S1 exceptions. `checks.nn-glibc-late-bind`
   binds the real S1 glibc to test stand-ins.

Reading a failure: the partitioner exits 1 and prints each finding with its
code; the table of codes and remedies is in `tools/rocky-partition/PLAN.md`
("The report"). The most common: `prefix-relative`, `union-unacked`,
`dangling`, `binary-ref`, `pieced-unacked`, `cycle`, `unresolved-needed`,
`integrity-runpath`.

Developer loop (design §11.4): keep the build tree and replay the partition
without rebuilding:

```sh
python3 -I tools/rocky-partition/rocky-partition --plan plan.json --replay TREE [--remap OLD=NEW]
```

(`TREE/BUILDROOT`, `TREE/RPMS`, `TREE/prefix`; development copies only.)
**TODO:** the `keepBuildTree` attribute that produces such a tree from
`mkRpmPackage` is not written; today the trees come from
`tools/rocky-partition/tests/{reloc-tree,trees}.nix`.

## 6. Search paths and profiles

A compiled-in directory names one output, so directories Rocky shares
between packages become environment search paths (design §4.1), listed in
`lib/rocky/unions.nix` (`nn.unions.table`): `PKG_CONFIG_PATH`,
`ACLOCAL_PATH`, `XDG_DATA_DIRS`, `GI_TYPELIB_PATH`, `PERL5LIB`, `PYTHONPATH`
(python3.12 only), `MANPATH`, `INFOPATH`, `TERMINFO_DIRS`, `GCONV_PATH`,
`LOCPATH`, `LOCALE_ARCHIVE`, `I18NPATH`, `TZDIR`, `NIX_DEBUG_INFO_DIRS`.

* **Build time**: each output that has one of those directories gets a
  `nix-support/setup-hook` line (`addToSearchPath VAR "$o/rel"`, or `export
  VAR="${VAR:-$o/rel}"` for single-valued ones), so dependents see them like
  nixpkgs packages. The partitioner applies the table's rules
  (`searchPathRules` in the plan, for the generic dirs and for an override's
  `runtimeSearchPaths` alike): a `provider` glob decides whether a
  directory counts (`LOCPATH`: `*/LC_CTYPE`), `yieldsTo` guards the line
  (`[ -n "${LOCALE_ARCHIVE-}" ] || addToSearchPath LOCPATH …`) and the
  archive's export is followed by `unset LOCPATH`, so the result does not
  depend on hook order. Run-time-only variables (`MANPATH`, `INFOPATH`,
  `TERMINFO_DIRS`, `TZDIR`, `NIX_DEBUG_INFO_DIRS` and `GCONV_PATH`) get no
  hook line. `GCONV_PATH` is run time only on purpose: in a build it also
  reaches the foreign glibcs of the build tools (nixpkgs' `iconv`,
  `msgfmt`), which then load Rocky's 2.39 modules (they import
  `GLIBC_PRIVATE` symbols); a build that needs `gconv_extra`'s charsets
  sets it itself. `checks.nn-glibc-hooks` builds against the real hooks.
* **Run time**: a profile (`buildEnv` of outputs) exports the variables for
  its root; `nn.unions.profileScript root` is the sh fragment. **TODO:**
  `rocky.lib.mkProfile` (buildEnv + `etc/profile.d/rocky.sh` + trigger
  emulation such as `iconvconfig`) is not written.
* **Locales**: glibc reads `LOCALE_ARCHIVE` only when `LOCPATH` is unset. So
  `LOCPATH` is set only for directory-format locales (langpacks) and never
  where an archive is provided; `all_langpacks` (the archive, every locale)
  exports `LOCALE_ARCHIVE` and unsets `LOCPATH`, in setup hooks and
  profiles. Without `LOCPATH`, libc also looks in its compiled-in
  `<glibc>/lib/locale`, which holds `C.utf8`, and reads its compiled-in
  `<glibc>/share/locale/locale.alias`: both are glibc-common files in
  Rocky, moved into `out` here (`pullToPrefix`; `common` keeps symlinks), so
  `C.UTF-8` works with no variable and in archive mode, and alias names
  (`deutsch`, `norwegian`, …) resolve with directory locales too.

| want | compose |
|---|---|
| German messages and formats | `glibc.langpack_de` (sets `LOCPATH`) |
| every locale | `glibc.all_langpacks` (sets `LOCALE_ARCHIVE`, read through the P2 patch; unsets `LOCPATH`) |
| `C.UTF-8` | nothing (`out`) |
| extra iconv charsets | `glibc.gconv_extra` (`GCONV_PATH`, run time: profiles; set it yourself in a build) |
| `localedef` with Rocky's sources | `glibc.locale_source` (`I18NPATH`) |
| time zones | tzdata's output (`TZDIR`; glibc's compiled-in default dangles) |

## 7. Verification

Checks that exist (`nix build -L --cores 8 --max-jobs 2
.#checks.x86_64-linux.<name>`; the flake sees git-tracked files only):

| check | covers |
|---|---|
| `nn-cc-toolchain` | the S1 wrapper: C, C++, shared, `-m32`, `-static`, `-flto`; store loader, DT_RUNPATH only, `$out/lib64` self-rpath, no store path in DWARF, no `-frandom-seed` |
| `nn-shim` | the tool shim: rpmbuild in the view, only declared inputs visible, overlay dirs read-only, `$out` alias and emptiness, nested and concurrent calls |
| `nn-rpm-config` | 75 macros with exact values, macro load order (negative control), fold-usr/check-files/prep-hooks/instantiate unit tests, two relocated rpmbuilds |
| `nn-partition-selftest` | 22 synthetic cases (split, cycles, search paths, dangling/foreign/union, pieced, prefix-relative, late binding, replay, layout, plan errors, FIPS, cmake export files, the shebang gate, setup-hook rules sourced in both orders, `pullToPrefix`; a removed RUNPATH leaves no bytes) |
| `nn-partition-replay` | the relocated glibc tree replayed into 224 outputs: 0 errors, no cycles, no old prefix left (~20 min, big-parallel) |
| `nn-glibc-prep` | glibc P1–P3 apply with `--fuzz=0` after Rocky's `%prep` and have their effects |
| `nn-libgcc-for-glibc` | `libgccForGlibc` references nothing, no RUNPATH, right ELF classes |
| `nn-order` | `order.json` recomputed from `builddeps.json` |
| `nn-purity` | 42 eval-time tests of the build-purity assertion (E6) |
| `nn-names` | output names, override schema, unions table and hook/profile scripts |
| `nn-stage-deps` | mkStage input resolution on the real S1: -devel propagation (`develClosure`: glibc-devel → kernel-headers, libxcrypt-devel; unprovidable → eval error; `inputs.drop`), no consumer-specific drop in the stage fallback |

Stage and package checks (WP6–WP11):

| check | covers |
|---|---|
| `nn-s1-smoke` | which, xz, zlib-ng, gzip: outputs = `subpackages.json`, 0 partition errors, closures = own outputs + the stage0 libc tree, programs run from the store without `/usr`, `find_package(ZLIB CONFIG)`, purity violations only from declared bootstrap parts |
| `nn-kernel-headers` | the kernel SRPM headers-only through mkRpmPackage vs the official kernel-headers RPM (file list, bytes, NEVR, deps) |
| `nn-glibc-smoke` | M1 acceptance: 225 outputs, outputChecks, closures = siblings + `libgccForGlibc`, nested store-path scan (0 foreign paths in 14 738 files), programs from the S1 toolchain in a `/usr`-free sandbox (dynamic, `-static`, `-m32`, C++, `pthread_cancel`, locales via LOCPATH / LOCALE_ARCHIVE), ld.so diagnostics, P1/P2/P3 |
| `nn-glibc-files` | per shipped RPM: file set, types, modes, symlinks, flags, owners, Requires/Provides vs the 221 official RPMs |
| `nn-glibc-abi` | `abi-compare.py` through the path map: 709 DSOs, 3541 archive members, 480 headers |
| `nn-glibc-content` | bytes / text after the path map / ELF loaded sections classified (displacement-normalised disassembly, string pools, layout) for 7724 files |
| `nn-glibc-closure` | every output's closure ⊆ siblings + `libgccForGlibc` |
| `nn-glibc-runtime` | official RPM roots vs a `/usr`-free root of the relocated outputs: ~1460 report items, 503 LOCPATH locales, 884 archive locales, 1180 iconv charsets, NSS, getconf, tz, programs (dynamic, static, static-pie, `-m32`), plus assertions for P1, P2, P3, trusted dirs, LOCPATH-wins |
| `nn-glibc-late-bind` | mkRpmPackage's late binding on the real glibc with self-contained test stand-ins: the bind derivation's outputChecks (allowedReferences/allowedRequisites, enforced by the real bind build), bound closures without raw late outputs, langpack symlinks into the bound common, ldd's bound shebang, memusagestat's RUNPATH, the `glibc-bound` CI job |
| `nn-glibc-hooks` | the generated setup hooks in real stdenv builds: `all_langpacks` (alone, with `langpack_de`, either order) exports `LOCALE_ARCHIVE` and leaves `LOCPATH` unset; `langpack_de` + `common` set `LOCPATH`; no `GCONV_PATH`; `C.UTF-8` and the alias `deutsch` resolve |
| `nn-s1-glibc1` | which, xz, zlib-ng, gzip against glibc¹ (`nn.stages.s1Glibc1`): 0 partition errors, closures = own + glibc¹, no byte of a build-only path (gcc copy, glibc dev, stage0 libc), RUNPATH/DT_BIND_NOW, programs run without `/usr` |
| `nn-late-bind`, `nn-late-bind-unit` | the bind derivation on synthetic trees |
| `nn-parity-selftest` | every `nn-parity.py` comparator on a synthetic package, faithful and broken |

Every difference the parity checks accept is a rule in
`tools/parity/nn-default.json` or `tools/parity/nn-glibc-<check>.json`
with its `effect` (P1, P2, P3, trusted-dirs, store-by-pieces, stage0
annobin, locale-search-path, libc-catalogs, late-bind, pull-to-prefix,
transient-payload) and reason; the M1 review pinned the P2 rules to the
exact changed values (section sizes, entry counts); each check also has a `.report` attribute
that always builds (`$out/report.txt`). Results at M1:
`research/nix-native/experiments/m1.md`.

## 8. Known differences from Rocky

Deliberate, named differences (design §0.4, §4.3):

* **P1** `ld-so-cache.patch`: the loader and `ldconfig` use
  `<glibc>/etc/ld.so.cache` and `<glibc>/etc/ld.so.conf`, not `/etc/…`, so a
  host's cache never injects host libraries. That cache does not exist; the
  relocated loader finds libraries through its system dirs and RUNPATH.
* **P2** `locale-archive.patch`: the locale archive is looked up in
  `$LOCALE_ARCHIVE_2_27`, `$LOCALE_ARCHIVE` (ignored for setuid programs),
  then `/run/current-system/sw/lib/locale/locale-archive` and
  `/usr/lib/locale/locale-archive` (nixpkgs' host fallbacks, kept for now:
  open decision), then the compiled-in path.
* **P3** `ld-preload.patch`: the preload file is `/etc/ld-nix.so.preload`, not
  `/etc/ld.so.preload`.
* P2 calls glibc's internal `__libc_secure_getenv` inside libc (nixpkgs'
  public `secure_getenv` added an interposable PLT slot to libc.so.6);
  `locale` and `localedef` call `secure_getenv` and so need
  `GLIBC_2.17`.
* The loader also trusts the `libgccForGlibc` directories
  (`user-defined-trusted-dirs`), so `pthread_cancel` and `backtrace` find
  `libgcc_s.so.1` without `/lib64` (a stage0-built copy in S1, the named
  bootstrap exception).

Consequences of relocation:

* **Dangling `TZDIR`**: glibc's compiled-in default
  `<glibc>/share/zoneinfo` does not exist (tzdata is another SRPM). Set
  `TZDIR` (profiles, NixOS); `/etc/localtime` is still read from `/etc`.
* **`locale.alias` and `C.utf8` in `out`**: libc's compiled-in alias file
  and complocaledir name files of glibc-common, which references `out`, so
  no forwarding stub can serve them: they live in `out` and `common` has
  symlinks to them (`files` parity: named differences `pull-to-prefix`).
  Alias names and `C.UTF-8` behave as on Rocky.
* **-devel propagation is evaluation-time**: a stage-built BuildRequire's
  cross-SRPM -devel/-headers/-static Requires (lock `develrequires.json`:
  glibc-devel → kernel-headers, libxcrypt-devel; mpfr-devel → gmp-devel)
  are inputs of `mkRpmPackage` builds too (`mkStage` `develClosure`), as
  mock installs them. A dev output's `nix-support/propagated-build-inputs`
  names its own siblings only (a cross-SRPM entry there would be a
  reference, part of its runtime closure): an ordinary nixpkgs-style
  consumer with `buildInputs = [ glibc.dev ]` adds the others itself
  (the S1 toolchain brings kernel-headers; `crypt.h` needs libxcrypt's dev).
* **Untranslated libc messages**: glibc's own message catalogs live in
  `<glibc>/share/locale` only when composed; without a profile or
  `TEXTDOMAINDIR`, libc's messages are English (as in nixpkgs).
* **Compiled-in defaults of other outputs** (`share/i18n`, `lib/locale`,
  `lib64/gconv` of `gconv_extra`) need their search path (§6);
  `GCONV_PATH` is not set by setup hooks (run time only, §6).
* **Scriptlets and triggers are not run**: `%post`, `%posttrans`, file
  triggers, `ldconfig`, `gconv-modules.cache` generation (`iconvconfig`),
  `glib-compile-schemas`, … are recorded in `nix-support/rpm/*.json`, not
  executed. glibc's `gconv-modules.cache` (`%ghost`) is not generated; glibc
  parses the module configuration instead.
* **`/etc`, `/var`, owners, setuid, capabilities**: `%config` files are
  defaults under `<output>/etc`; owners, setuid/setgid bits and file
  capabilities are not representable in the store and are recorded in the
  metadata only (NixOS modules / image tooling would apply them; out of scope
  for M1/M2).
* **`/usr/lib/.build-id` links** of non-debug subpackages are dropped (Nix
  finds debug info through `debug/lib/debug/.build-id`).
* **RUNPATH**: binaries carry store RUNPATHs as DT_RUNPATH (Rocky has
  none); Rocky's own `$ORIGIN` RPATHs stay DT_RPATH and `-z now` stays
  `DT_BIND_NOW` (every spec links with `--disable-new-dtags`, Rocky's ld
  default). The ELF contents are otherwise Rocky's, compared semantically by
  the parity checks.
* **Unshipped subpackages** (glibc32, sysroot, `-static`, `-tests`) are
  outputs of the derivation, without `rpm.*` aliases.

## 9. Adding a package (developer checklist)

1. Make sure the SRPM has a `subpackages.json` entry and `builddeps.json`
   inputs (§3).
2. Add it to the stage's `packages` (`bootstrap/nn/s1.nix`). Evaluation
   fails, listing every name, for BuildRequires the stage neither builds nor
   has in its `fallback` set, and for BuildRequires the lock could not
   resolve: map each (stage package, fallback entry with a reason, or the
   package's `inputs.drop`). A drop that stands for this package's own
   substitute (glibc's `glibcBuildDeps`, which's unused readline) belongs in
   its `inputs.drop`, never in the stage fallback, which applies to every
   package of the stage and would hide the library from the others. The
   -devel chain of stage-built BuildRequires is added (§8) and resolved the
   same way.
3. Build `rockyBoot.<stage>.<srpm>` with no override. Read the partitioner's
   findings (`$out/nix-support/rocky-report.json`, also in the `logs`
   output) and the shebang gate; fix with the smallest override (§4), each
   entry with a comment saying why.
4. Check the spec for path edits that use the package name or
   `$RPM_BUILD_ROOT/usr` (krb5, gnutls hazards, design §1.5 item 4).
5. Check the closure (`nix path-info -r`), `nix build --rebuild`, run the
   program from the store in a sandbox without `/usr`; for libraries in FIPS
   mode, check the integrity data (design §2.6). Parity against the
   official RPMs: `nn.nnChecks.glibc { glibc = <pkg>; srpm = "<srpm>"; }`
   is written for glibc but takes any multi-output package with
   `passthru.rpmOutputs` (allowlists `tools/parity/nn-<srpm>-<check>.json`).

## 10. Further reading

* [`nix-native-design.md`](nix-native-design.md) — the contract (§14:
  changelog of revision 2).
* [`research/nix-native/foundation-handoff.md`](research/nix-native/foundation-handoff.md)
  — component interfaces and open requests.
* [`research/nix-native/experiments/`](research/nix-native/experiments/) —
  E1–E6, lock, rpmconfig, names, wp6–wp8 and m1 (milestone M1) records.
* `tools/rocky-partition/PLAN.md` — partition plan schema and error codes.
* [`packages/README-overrides.md`](../packages/README-overrides.md) — override
  fields.
