# Nix-native Rocky packages: user and developer guide

Relocated, composable Nix store paths built from the official Rocky Linux 10.2
SRPMs: one derivation per SRPM, one Nix output per RPM subpackage, rpmbuild
as the spec engine. The design contract is
[`nix-native-design.md`](nix-native-design.md) (revision 2); this guide
says how to use and extend what it describes.

**Status (after the foundation merge, c700802).** The machinery exists and is
tested piece by piece: lock data, rpm configuration, tool shim, cc-wrapper,
partitioner, names/overrides/unions, purity check (design §12 status table).
`mkRpmPackage`/`mkStage` (WP6), the relocated glibc (WP7), kernel-headers
(WP8), parity/runtime checks (WP9), attributes (WP10) and late binding (WP11)
are **not written yet**. Sections that depend on them are marked **TODO
(WP6)** etc.; their content is the design's plan, not a description of
working code.

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

**TODO (WP6, WP10).** Planned shape (design §2.12, §11.2):

| attribute | meaning |
|---|---|
| `rockyBoot.<stage>.<srpm>` | the multi-output derivation of `<srpm>` in bootstrap stage `s1`, `s2` (`legacyPackages.x86_64-linux.rockyBoot`; `default.nix` already exposes `rockyBoot = nn.rockyBoot or { }`, today empty) |
| `rockyBoot.<stage>.<srpm>.<output>` | one output, e.g. `rockyBoot.s1.glibc.dev`, `.common`, `.langpack_de` |
| `rockyBoot.<stage>.rpm."<rpm-name>"` | alias by RPM name, e.g. `rockyBoot.s1.rpm."glibc-devel"` = `rockyBoot.s1.glibc.dev` (shipped subpackages only) |
| `rocky.<srpm>`, `rocky.rpm."<rpm-name>"` | the final stage S3, same shape (M2 and later) |
| `<pkg>.raw` | the rpmbuild derivation when late binding wraps it (§5.6) |
| `passthru.rpmOutputs` | `{ "<rpm-name>" = "<output>"; }` for shipped subpackages |
| `passthru.unshipped` | subpackages the spec builds but Rocky does not publish (glibc's `glibc32`, `sysroot-x86_64-el10-glibc`, `compat-libpthread-nonshared`); they are real outputs without an `rpm.*` alias |
| `passthru.rockyStage`, `passthru.srpm`, `passthru.overrides` | stage name, lock name, validated overrides |
| `hydraJobs.nixNative.x86_64-linux` | = `rockyBoot`, for `tools/build-jobs.sh` |

The machinery is reachable today as `legacyPackages.x86_64-linux.nn.<name>`
(plug-in layout of `lib/rocky/default.nix`: `lib/rocky/parts/<name>.nix` →
`nn.<name>`, `lib/rocky/checks/<name>.nix` → `checks.x86_64-linux.nn-*`):

| attribute | what it is |
|---|---|
| `nn.cc` | S1 cc-wrapper: `wrap { libc }`, `libcAdapter`, `stage0Libc`, `stage0`, `storescan`, `e1.*` |
| `nn.toolShim` | the bwrap shim (`${nn.toolShim} [--no-prefix-view] -- cmd…`), `mk`, `mkview`, `e2.*` |
| `nn.rpmConfig` | rpm configuration + relocation macros + `nix/` helper scripts (`instantiate`), `configSite` |
| `nn.partitionTool` | `tools/rocky-partition` as a source path; `trees.*` test build trees |
| `nn.libgccForGlibc` | RUNPATH-free copy of the stage0 `libgcc_s.so.1` (64 + 32-bit) |
| `nn.lockgen` | `rpmspec -q` per SRPM for `subpackages.json` |
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

**Pending (WP6):** the override fields `prefixRelativeOk` (acks for
`*-config` scripts, test trees, a cross sysroot) and `integrityOk` exist as
partitioner plan keys (`tools/rocky-partition/PLAN.md`) but not yet in
`overrides.nix`; the `opaqueRefs` entry format is not settled (PLAN.md's
`"<output>:<rel glob>"` vs the glibc draft's `"<output>/<rel>"`).

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
6. **Late binding** (**TODO (WP11)**): outputs whose interpreters or
   libraries are built later (glibc's `common`, `utils`, `nss_db`,
   `benchtests`) get a cheap bind derivation that rewrites shebangs, symlinks,
   text and RUNPATH of those outputs and of the sibling outputs that
   reference them (`lateReferrers`).

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
**TODO (WP6):** the `keepBuildTree` attribute that produces such a tree from
`mkRpmPackage`; today the trees come from
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
  nixpkgs packages.
* **Run time**: a profile (`buildEnv` of outputs) exports the variables for
  its root; `nn.unions.profileScript root` is the sh fragment. **TODO:**
  `rocky.lib.mkProfile` (buildEnv + `etc/profile.d/rocky.sh` + trigger
  emulation such as `iconvconfig`) is not written.
* **Locales**: glibc reads `LOCALE_ARCHIVE` only when `LOCPATH` is unset. So
  `LOCPATH` is set only for directory-format locales (langpacks, `C.utf8` in
  `common`) and never where an archive is provided; a profile containing
  `all_langpacks` (the archive, every locale) unsets `LOCPATH`.

| want | compose |
|---|---|
| German messages and formats | `glibc.langpack_de` (sets `LOCPATH`) |
| every locale | `glibc.all_langpacks` (sets `LOCALE_ARCHIVE`, read through the P2 patch) |
| extra iconv charsets | `glibc.gconv_extra` (`GCONV_PATH`) |
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
| `nn-partition-selftest` | 12 synthetic trees (split, cycles, search paths, dangling/foreign/union, pieced, prefix-relative, late binding, replay, layout, plan errors, FIPS) |
| `nn-partition-replay` | the relocated glibc tree replayed into 224 outputs: 0 errors, no cycles, no old prefix left (~20 min, big-parallel) |
| `nn-glibc-prep` | glibc P1–P3 apply with `--fuzz=0` after Rocky's `%prep` and have their effects |
| `nn-libgcc-for-glibc` | `libgccForGlibc` references nothing, no RUNPATH, right ELF classes |
| `nn-order` | `order.json` recomputed from `builddeps.json` |
| `nn-purity` | 42 eval-time tests of the build-purity assertion (E6) |
| `nn-names` | output names, override schema, unions table and hook/profile scripts |

Planned (**TODO (WP9)**, design §7.5, §7.6): `checks.nn-glibc-{files,abi,content,closure,runtime}`:
relocated parity against the official RPMs (file sets with `/usr/x` ↔
`<o>/x`, ABI with a path map, content after store-path normalisation, the
closure rule) and behaviour in a `/usr`-free sandbox (loader diagnostics,
static/`-m32` programs, 885 locales, 1180 charsets, NSS, `pthread_cancel`).
Planned (**TODO (WP6)**): output closure enforcement by
`outputChecks.<o>.allowedRequisites` and the purity assertion wired into
`mkStage`.

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
* The loader also trusts the `libgccForGlibc` directories
  (`user-defined-trusted-dirs`), so `pthread_cancel` and `backtrace` find
  `libgcc_s.so.1` without `/lib64` (a stage0-built copy in S1, the named
  bootstrap exception).

Consequences of relocation:

* **Dangling `TZDIR`**: glibc's compiled-in default
  `<glibc>/share/zoneinfo` does not exist (tzdata is another SRPM). Set
  `TZDIR` (profiles, NixOS); `/etc/localtime` is still read from `/etc`.
* **Untranslated libc messages**: glibc's own message catalogs live in
  `<glibc>/share/locale` only when composed; without a profile or
  `TEXTDOMAINDIR`, libc's messages are English (as in nixpkgs).
* **Compiled-in defaults of other outputs** (`share/i18n`, `lib/locale`,
  `lib64/gconv` of `gconv_extra`) need their search path (§6).
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
* **RUNPATH**: binaries carry store RUNPATHs (Rocky has none); the ELF
  contents are otherwise Rocky's, compared semantically by the parity checks.
* **Unshipped subpackages** (glibc32, sysroot, `-static`, `-tests`) are
  outputs of the derivation, without `rpm.*` aliases.

## 9. Adding a package (developer checklist)

**TODO (WP6).** Expected flow once `mkRpmPackage` exists:

1. Make sure the SRPM has a `subpackages.json` entry and `builddeps.json`
   inputs (§3).
2. Build `rockyBoot.<stage>.<srpm>` with no override.
3. Read the partitioner's findings; fix with the smallest override (§4), each
   entry with a comment saying why.
4. Check the spec for path edits that use the package name or
   `$RPM_BUILD_ROOT/usr` (krb5, gnutls hazards, design §1.5 item 4).
5. Run the package's checks; for libraries in FIPS mode, check the
   integrity data (design §2.6).

## 10. Further reading

* [`nix-native-design.md`](nix-native-design.md) — the contract (§14:
  changelog of revision 2).
* [`research/nix-native/foundation-handoff.md`](research/nix-native/foundation-handoff.md)
  — component interfaces and open requests.
* [`research/nix-native/experiments/`](research/nix-native/experiments/) —
  E1–E6, lock, rpmconfig, names records.
* `tools/rocky-partition/PLAN.md` — partition plan schema and error codes.
* [`packages/README-overrides.md`](../packages/README-overrides.md) — override
  fields.
