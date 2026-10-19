# Per-package overrides (`packages/<srpm>/default.nix`)

Relocated, Nix-native packages (`docs/nix-native-design.md`) are built from the
SRPM alone: `mkRpmPackage` takes the spec, the lock data and the generic
machinery. A package that needs more gets an optional override file
`packages/<srpm>/default.nix` (`<srpm>` = the lock name, e.g. `glibc`,
`krb5`). Most SRPMs have none. A *variant* of an SRPM (mkStage
`variants = { <name> = "<srpm>"; }`: the same spec built another way under
another attribute name, e.g. `kernel-headers` = the kernel SRPM headers-only)
has its own file `packages/<name>/default.nix` and store name
`<name>-<version>-<release>[-<output>]`.

```nix
# packages/<srpm>/default.nix
{ lib, stage, rocky }: {
  mergeOutputs = [ [ "glibc" "glibc32" ] ];
  doCheck = stage.name == "s3";
}
```

* The file is a function of `{ lib, stage, rocky }` (only the arguments it
  names are passed, as with `callPackage`; a plain attrset also works).
  `lib` is nixpkgs' lib, `stage` the bootstrap stage being built (`stage.name`
  is `"s1"`, `"s2"`, `"s3"`; `stage.pkgs.<srpm>`, `stage.libgccForGlibc`, …),
  `rocky` the final package set.
* It is validated by `lib/rocky/overrides.nix` (`nn.overrides`): every key at
  every level must be one of the fields below (a typo is an evaluation error
  naming the key and the file), and each value must have the listed type
  (a function where a value belongs, e.g. `lib.optionals cond` without its
  list, is reported as "got a function" for that key). All problems of a
  file are reported at once.
* Missing fields take the default. `nn.overrides.overridesFor { inherit stage rocky; } "<srpm>"`
  returns the validated, defaults-filled set (`nn.overrides.defaults` when
  there is no file); `checks.nn-names` tests the schema and checks that this
  file mentions every field.
* Output names in fields below are Nix output names (`out`, `dev`, `lib`,
  `common`, `langpack_de`, …: see "Output names"); subpackage names are RPM
  names (`glibc-devel`). The schema checks that they are identifiers;
  `nn.overrides.checkOutputs file overrides outs` (`outs` =
  `nn.names.outputsFor …`) checks that `layout` values, `lateBind` keys and
  `lateReferrers` keys and values name outputs that exist.
* Output-relative paths (`lib/locale`) have no leading or trailing `/` and no
  empty, `.` or `..` component; output-relative globs (`lib64/lib*.so*`) do
  not start with `/`.

## Recipe fields

| field | type (default) | meaning |
|---|---|---|
| `defines` | set of single-line string or int (`{ }`) | extra `rpmbuild --define "<name> <value>"`; names must be macro names; multi-line values are rejected (rpmbuild drops everything after a raw newline; put such macros into a macro file) |
| `bconds` | `{ with = [ str ]; without = [ str ]; }` (both `[ ]`) | `--with X` / `--without X`; also applied when the lock generator computes `subpackages.json` |
| `configSite` | null, path, string or derivation (`null`) | an extra `CONFIG_SITE` fragment appended after the generic `lib/rocky/config.site` (glibc: `./glibc.site`) |
| `nixPatches` | list of path/string/derivation (`[ ]`) | Nix-side patches applied (`patch -p1`) by `%__spec_prep_post` in the unpacked source, never added to the spec's patch list; each one is a named parity difference |
| `prepScript` | string (`""`) | shell run in the unpacked source after `nixPatches` (same hook) |
| `specSubstitutions` | list of `{ from; to; count ? 1; }`, `from` non-empty (`[ ]`) | literal replacements in the `.spec` before rpmbuild; the number of occurrences of `from` must be exactly `count` (asserted at build time). Fallback for what the `/usr` view and the self-prefix alias cannot do |
| `env` | set of string/int/bool/path/derivation/null (`{ }`) | environment of the build. Shell-identifier keys (`NIX_NO_SELF_RPATH`, `NIX_DONT_SET_RPATH`) become derivation attributes (structured `env`, visible to setup hooks); other keys (make variables with `-`, `.`, `+`, e.g. glibc's `"user-defined-trusted-dirs"`) are passed only on rpmbuild's command line as `env 'k=v' rpmbuild` (setup.sh's `declare -x` would abort on them) |
| `doCheck` | bool (`false`) | run `%check` (omit `--nocheck`); give the reason in a comment when it stays off in S3 |
| `prefixView` | bool (`true`) | bind the declared-input `/usr` view at `$out` while rpmbuild runs (self-prefix alias, §1.5); `false` = the `$out` directory is empty during the build and the package needs `specSubstitutions` instead |
| `strictFhs` | bool (`false`) | FHS literals found in outputs (`/usr/…`, `/lib64/…` not on the runtime allowlist) are errors instead of report entries |
| `inputs` | `{ add = [ ]; addBuildOnly = [ ]; addNative = [ ]; drop = [ str ]; buildRequires = [ str ]; }` | `add` / `addNative`: extra host / build inputs (derivations, store paths) beyond `builddeps.json` (a Rocky-built `add` entry is a runtime input: outputs may reference it); `addBuildOnly`: extra host inputs (cc-wrapper input, `/usr` view) that are never runtime inputs, even when Rocky-built, so an output referencing one fails the partition and `outputChecks` (glibc: `kernel-headers`; its closure stays its siblings + `libgccForGlibc`); `drop`: BuildRequires names not to map to inputs (provider RPM names from `builddeps.json` `inputs`, or entries of its `unresolved` list, which must be named here or in the stage fallback, else evaluation fails); `buildRequires`: extra BuildRequires (RPM names) resolved exactly like the lock's (a stage package or variant, the stage fallback, else an evaluation error): what the spec gets in Rocky's buildroot that `builddeps.json` misses (a BuildRequire's own Requires, e.g. kernel's `python3-rpm-macros` via `python3-devel`; a conditional BuildRequire of a non-default bcond, e.g. `rsync` under `with_headers`) |
| `stage` | null or string (`null`) | bootstrap placement of a low-level package (which `rockyBoot` stage first builds it) |
| `runtimeLibc` | bool (`true`) | `false`: the stage libc is build-only for this package (its outputs hold no programs or libraries, e.g. `kernel-headers`): no runtime input, no allowed reference to it, no input lib dirs; an ELF in an output then fails the partition (unresolved `DT_NEEDED`) |

## Output fields

| field | type (default) | meaning |
|---|---|---|
| `prefixSubpackage` | null or string (`null`) | the subpackage that gets `%_prefix = $out` and is named `out`; default from `subpackages.json` (eponymous > `<srpm>-libs` > most `/usr` files in the official filelists) |
| `builtSubpackages` | null or list of subpackage names (`null`) | `null`: the build produces every subpackage of `subpackages.json` (computed with default bconds). A list: exactly the subpackages this build produces (debuginfo ones included when built) when `bconds`/`defines` switch the rest off; each must be in `subpackages.json`, and outputs, `rpmOutputs` and the stage's `rpm.*` aliases cover only these (the partitioner still fails on a built-but-unlisted or listed-but-unbuilt subpackage). `kernel-headers`: `[ "kernel-headers" "kernel-modules-extra-matched" ]` with `prefixSubpackage = "kernel-headers"` |
| `mergeOutputs` | list of lists of subpackage names (`[ ]`) | subpackages sharing one output (reference cycles, functional or prefix-relative merges, §3.3); the first member is the representative, a group containing the prefix subpackage is `out`; groups have ≥ 2 members, a subpackage is in at most one group. RPM-name attributes of merged members alias the representative |
| `layout` | set of macro name → output name (`{ }`) | compile a directory macro as another output's path: `{ _datadir = "common"; }` → `--define "_datadir $common/share"`; only when that output owns the whole directory in the official filelists (`tools/layout-suggest.py`) |
| `runtimeSearchPaths` | set of output-relative path → union variable (`{ }`) | compiled-in defaults that may dangle because a search path serves them: `{ "lib/locale" = "LOCPATH"; }`; the variable must be in `lib/rocky/unions.nix` (which also says when a variable is set: `LOCPATH` only for directory-format locales and never next to a `LOCALE_ARCHIVE`, since glibc then ignores the archive). The generated setup hooks apply that table's rules to these entries too (`provider`, `yieldsTo`; a run-time-only variable such as `GCONV_PATH` gets no hook line, only profiles set it) |
| `unionDirs` | set of output-relative dir → string (`{ }`) | acknowledged union directories (owned by several outputs) and the mechanism that makes them work (text) |
| `danglingOk` | list of output-relative paths (`[ ]`) | references to paths that no output contains, accepted (glibc's default `TZDIR`, `share/zoneinfo`) |
| `opaqueRefs` | list of output patterns (`[ ]`) | acknowledged pieced/hidden references (store-by-pieces in `.rodata`, compressed files) from outputs other than `out` into `out`: `"<output glob>"` or `"<output glob>:<rel glob>"` (PLAN.md); the draft form `"<output>/<rel>"` is converted by mkRpmPackage when its first component is an output. The partitioner registers them in `nix-support/hidden-references` and errors on unacknowledged ones |
| `forward` | `{ deny = [ output-relative glob ]; }` | `deny`: output-relative globs for which no forwarding stub (`$out/rel → $X/rel`) may be created (the reference then needs `layout`, a merge or a search path) |
| `noPatchelf` | list of output-relative globs (`[ ]`) | ELF files whose RUNPATH is never recomputed (glibc: the loader, libc and the sysroot) |
| `pullToPrefix` | set of output-relative path/glob → reason (`{ }`) | regular files of a non-prefix output that a compiled-in default of `out` names, where no forwarding stub can serve because their owner references `out` (a stub would close a cycle): the partitioner moves them into `out` and leaves an absolute symlink in the owner (PLAN.md `pullToPrefix`). glibc: `share/locale/locale.alias` (libc's alias file, glibc-common) and `lib/locale/C.utf8` (complocaledir, glibc-common), so alias names and `C.UTF-8` resolve without any search path, also in archive mode |
| `prefixRelativeOk` | list of output patterns (`[ ]`) | acknowledges references from a non-prefix output to the bare prefix, a shared top-level dir, a union or a path that exists nowhere, in matching files (test support, a cross sysroot, a copied build tree); PLAN.md `prefixRelativeOk` |
| `integrityOk` | list of output patterns (`[ ]`) | acknowledges patching the RUNPATH of a file whose FIPS integrity data cannot follow (PLAN.md `integrityOk`) |
| `systemLibDirs` | null or list of strings (`null`) | the libc system dirs for the RUNPATH recompute (sonames found there get no RUNPATH entry); `@<output>@` names an own output. `null`: the stage's (`["@out@/lib64" "@out@/lib"]` for the libc itself) |
| `allowUnresolvedNeeded` | list of sonames (`[ ]`) | `DT_NEEDED` sonames that may stay unresolved (bootstrap stages: libraries not yet Rocky-built) |
| `fhsAllowlist` | set of literal → reason (`{ }`) | FHS shebangs (`"#!/usr/bin/bash"` or `"/usr/bin/bash"`) accepted in outputs, with the reason; merged over the stage's `fhsAllowlist`; bootstrap stages only (an eval error in a `buildPure` stage). Any other FHS `#!` in an executable that patchShebangs did not bind, that is not runtime FHS (`/bin/sh`, `/usr/bin/env`) and not a lateBind interpreter fails the build (`rocky-partition --check-shebangs`) |
| `lateBind` | set of output name → `{ interpreters = [ ]; libs = [ ]; }` (`{ }`) | outputs whose shebangs (`interpreters`: shebang basenames such as `bash`, `perl`, `python3`; resolved by `nn.lateBind.fromOverrides` through the stage's `interpreterPkgs`, else the stage package of that SRPM, `python3` → `python3.12`) and RUNPATH (`libs`: SRPM names, stage `pkgs` // `lateBindPkgs`) are bound to packages built later, by the cheap bind derivation (§2.9, §11.3). Applied only in a stage whose `lateBindFor srpm` is true (mkRpmPackage then returns `lateBind.wrap` of the raw build, with `.raw`); elsewhere (S1) the raw late outputs ship as they are and the package names their FHS shebangs / unresolved NEEDED as bootstrap exceptions (`fhsAllowlist`, `allowUnresolvedNeeded`). The partitioner reads it in every stage (L* check; NEEDED and shebangs of a late output are left to the bind) |
| `lateReferrers` | set of late output → list of output names or globs over them (`{ }`) | sibling outputs that reference a `lateBind` output and are therefore re-bound with it (glibc: `common → [ "minimal_langpack" "langpack_*" ]`); keys must be `lateBind` outputs; the partitioner verifies the list is complete |

## Output names

One Nix output per RPM subpackage (`lib/rocky/names.nix`, §2.12): the prefix
subpackage → `out`, `<srpm>-devel` → `dev`, `<srpm>-libs` → `lib` (unless it is
the prefix), every `*-debuginfo`/`*-debugsource` → `debug`, `<srpm>-X` → `X`,
others verbatim, then `[^A-Za-z0-9_]` → `_`. Names that collide after this
mapping, are not shell identifiers (`100dpi`) or are reserved (`src`, `system`,
`all`, … would shadow derivation attributes) use the full sanitized
subpackage name instead (`perl-lib`/`perl-libs` → `perl_lib`/`perl_libs`).
Plus `debug` (when the spec builds debug packages: `subpackages.json` lists
them under `debug`) and `logs`. Unshipped subpackages (in the spec, not in the
Rocky repos: glibc's `glibc32`, `sysroot-x86_64-el10-glibc`,
`compat-libpthread-nonshared`) are outputs too but get no `rocky.rpm.*` alias.
The subpackage list comes from `lock/rocky-<rel>/subpackages.json` only
(`nn.names.subpackagesFor`): an SRPM without an entry there is an evaluation
error, not a guess from `rpms.json`, which lacks the unshipped subpackages.

Several of these names (`dev`, `doc`, `info`, `bin`, `lib`, `static`) mean
something to nixpkgs' `multiple-outputs.sh`, whose fixup hooks would move
`share/doc`, `share/info`, `share/man`, `include`, `lib/pkgconfig`, … between
outputs and add `$dev/nix-support/propagated-build-inputs`. `mkRpmPackage`
has to switch those hooks off (the partition is final; see the header of
`lib/rocky/names.nix`); override files should not need to.
