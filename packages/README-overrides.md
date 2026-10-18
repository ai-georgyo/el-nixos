# Per-package overrides (`packages/<srpm>/default.nix`)

Relocated, Nix-native packages (`docs/nix-native-design.md`) are built from the
SRPM alone: `mkRpmPackage` takes the spec, the lock data and the generic
machinery. A package that needs more gets an optional override file
`packages/<srpm>/default.nix` (`<srpm>` = the lock name, e.g. `glibc`,
`krb5`). Most SRPMs have none.

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
  naming the key and the file), and each value must have the listed type.
  All problems of a file are reported at once.
* Missing fields take the default. `nn.overrides.overridesFor { inherit stage rocky; } "<srpm>"`
  returns the validated, defaults-filled set (`nn.overrides.defaults` when
  there is no file); `checks.nn-names` tests the schema and checks that this
  file mentions every field.
* Output names in fields below are Nix output names (`out`, `dev`, `lib`,
  `common`, `langpack_de`, …: see "Output names"); subpackage names are RPM
  names (`glibc-devel`).

## Recipe fields

| field | type (default) | meaning |
|---|---|---|
| `defines` | set of single-line string or int (`{ }`) | extra `rpmbuild --define "<name> <value>"`; names must be macro names; multi-line values are rejected (rpmbuild drops everything after a raw newline; put such macros into a macro file) |
| `bconds` | `{ with = [ str ]; without = [ str ]; }` (both `[ ]`) | `--with X` / `--without X`; also applied when the lock generator computes `subpackages.json` |
| `configSite` | null, path, string or derivation (`null`) | an extra `CONFIG_SITE` fragment appended after the generic `lib/rocky/config.site` (glibc: `./glibc.site`) |
| `nixPatches` | list of path/string/derivation (`[ ]`) | Nix-side patches applied (`patch -p1`) by `%__spec_prep_post` in the unpacked source, never added to the spec's patch list; each one is a named parity difference |
| `prepScript` | string (`""`) | shell run in the unpacked source after `nixPatches` (same hook) |
| `specSubstitutions` | list of `{ from; to; count ? 1; }` (`[ ]`) | literal replacements in the `.spec` before rpmbuild; the number of occurrences of `from` must be exactly `count` (asserted at build time). Fallback for what the `/usr` view and the self-prefix alias cannot do |
| `env` | set of string/int/bool/path/derivation/null (`{ }`) | environment of the build (keys may contain `-`, e.g. glibc's `"user-defined-trusted-dirs"` make variable; `NIX_NO_SELF_RPATH`, `NIX_DONT_SET_RPATH`) |
| `doCheck` | bool (`false`) | run `%check` (omit `--nocheck`); give the reason in a comment when it stays off in S3 |
| `prefixView` | bool (`true`) | bind the declared-input `/usr` view at `$out` while rpmbuild runs (self-prefix alias, §1.5); `false` = the `$out` directory is empty during the build and the package needs `specSubstitutions` instead |
| `strictFhs` | bool (`false`) | FHS literals found in outputs (`/usr/…`, `/lib64/…` not on the runtime allowlist) are errors instead of report entries |
| `inputs` | `{ add = [ ]; addNative = [ ]; drop = [ str ]; }` | `add` / `addNative`: extra host / build inputs (derivations, store paths) beyond `builddeps.json`; `drop`: BuildRequires names not to map to inputs |
| `stage` | null or string (`null`) | bootstrap placement of a low-level package (which `rockyBoot` stage first builds it) |

## Output fields

| field | type (default) | meaning |
|---|---|---|
| `prefixSubpackage` | null or string (`null`) | the subpackage that gets `%_prefix = $out` and is named `out`; default from `subpackages.json` (eponymous > `<srpm>-libs` > most `/usr` files in the official filelists) |
| `mergeOutputs` | list of lists of subpackage names (`[ ]`) | subpackages sharing one output (reference cycles, functional or prefix-relative merges, §3.3); the first member is the representative, a group containing the prefix subpackage is `out`; groups have ≥ 2 members, a subpackage is in at most one group. RPM-name attributes of merged members alias the representative |
| `layout` | set of macro → output name (`{ }`) | compile a directory macro as another output's path: `{ _datadir = "common"; }` → `--define "_datadir $common/share"`; only when that output owns the whole directory in the official filelists (`tools/layout-suggest.py`) |
| `runtimeSearchPaths` | set of output-relative path → union variable (`{ }`) | compiled-in defaults that may dangle because a search path serves them: `{ "lib/locale" = "LOCPATH"; }`; the variable must be in `lib/rocky/unions.nix` |
| `unionDirs` | set of output-relative dir → string (`{ }`) | acknowledged union directories (owned by several outputs) and the mechanism that makes them work (text) |
| `danglingOk` | list of output-relative paths (`[ ]`) | references to paths that no output contains, accepted (glibc's default `TZDIR`, `share/zoneinfo`) |
| `opaqueRefs` | list of strings (`[ ]`) | acknowledged pieced/hidden references (store-by-pieces in `.rodata`, compressed files) from outputs other than `out` into `out`: output-relative globs of the files carrying them; the partitioner registers them in `nix-support/hidden-references` and errors on unacknowledged ones |
| `forward` | `{ deny = [ str ]; }` | `deny`: output-relative globs for which no forwarding stub (`$out/rel → $X/rel`) may be created (the reference then needs `layout`, a merge or a search path) |
| `noPatchelf` | list of globs (`[ ]`) | ELF files whose RUNPATH is never recomputed (glibc: the loader, libc and the sysroot) |
| `allowUnresolvedNeeded` | list of sonames (`[ ]`) | `DT_NEEDED` sonames that may stay unresolved (bootstrap stages: libraries not yet Rocky-built) |
| `fhsAllowlist` | set of literal → reason (`{ }`) | FHS strings (e.g. `"#!/usr/bin/bash"`) accepted in outputs, with the reason (bootstrap only, or late-bound later) |
| `lateBind` | set of output → `{ interpreters = [ ]; libs = [ ]; }` (`{ }`) | outputs whose shebangs (`interpreters`: SRPM names of bash, perl, …) and RUNPATH (`libs`: SRPM names) are bound to packages built later, by the cheap bind derivation (§2.9, §11.3) |
| `lateReferrers` | set of late output → list of output names/globs (`{ }`) | sibling outputs that reference a `lateBind` output and are therefore re-bound with it (glibc: `common → [ "minimal_langpack" "langpack_*" ]`); keys must be `lateBind` outputs; the partitioner verifies the list is complete |

## Output names

One Nix output per RPM subpackage (`lib/rocky/names.nix`, §2.12): the prefix
subpackage → `out`, `<srpm>-devel` → `dev`, `<srpm>-libs` → `lib` (unless it is
the prefix), every `*-debuginfo`/`*-debugsource` → `debug`, `<srpm>-X` → `X`,
others verbatim, then `[^A-Za-z0-9_]` → `_`. Names that collide after this
mapping, are not shell identifiers (`100dpi`) or are reserved (`src`, `system`,
`all`, … would shadow derivation attributes) use the full sanitized
subpackage name instead (`perl-lib`/`perl-libs` → `perl_lib`/`perl_libs`).
Plus `debug` and `logs`. Unshipped subpackages (in the spec, not in the Rocky
repos: glibc's `glibc32`, `sysroot-x86_64-el10-glibc`,
`compat-libpthread-nonshared`) are outputs too but get no `rocky.rpm.*` alias.
