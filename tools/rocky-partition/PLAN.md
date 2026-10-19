# rocky-partition: invocation and plan.json (schema v1)

`rocky-partition` is the in-build step of design §2
(`docs/nix-native-design.md`): after `rpmbuild -bb --noclean` it moves the
BUILDROOT into one Nix output per subpackage, fixes symlinks, rewrites text
references, recomputes RUNPATH, creates forwarding stubs, registers hidden
references, checks the output graph and writes metadata. ELF contents are
never rewritten (only RUNPATH, through patchelf; FIPS integrity files of
patched libraries are recomputed or the patch is refused, see Phase E below).

## Invocation

```sh
python3 -I $tool/rocky-partition --plan "$NIX_ATTRS_JSON_FILE"            # in the build
python3 -I $tool/rocky-partition --plan plan.json --replay TREE [--remap OLD=NEW]   # development
PYTHONPATH=tools/rocky-partition python3 -m rocky_partition --plan ...    # from a checkout
python3 -I $tool/rocky-partition --plan plan.json --check-shebangs        # after fixupPhase
```

`$tool` = `self.partitionTool` (`lib/rocky/parts/partitionTool.nix`), a plain
source store path (no derivation; allowed as a build input in every stage):
`$tool/rocky-partition` (entry script; `-I` ignores `PYTHONPATH`, so the
script puts its own directory on `sys.path`) and `$tool/rocky_partition/`
(the package). Python >= 3.11, stdlib only; external programs: the `rpm`
binary of the plan, `patchelf` of the plan (only when a RUNPATH changes), and
`zstd` only for zstd-compressed members on Python < 3.14.

| option | meaning |
|---|---|
| `--plan FILE` | the plan (below) |
| `--replay TREE` | take `buildroot`, `rpmsDir` and the compile prefix from a kept build tree (`TREE/BUILDROOT`, `TREE/RPMS`, `TREE/prefix`); files are copied, never moved; at the end every output is remapped OLD -> NEW (same length: path names (the debug tree mirrors the prefix: `lib/debug/<P>/...`), raw bytes, store-by-pieces windows, symlink targets, whole-file gzip/xz/bzip2/zstd members re-encoded; verified fipscheck `.hmac` files are recomputed afterwards). Development only (design §11.4): embedded integrity HMACs do not survive it (`integrity-replay`) |
| `--remap OLD=NEW` | with `--replay`: OLD must be the tree's prefix, NEW the path of `prefixOutput` (default: exactly that) |
| `--report FILE` | also write the report here (e.g. `$NIX_BUILD_TOP`, survives a failed build with `--keep-failed`) |
| `--no-fail` | exit 0 even with errors (experiments; `failOnError = false` in the plan does the same) |
| `--check-shebangs` | only the shebang gate (design decision 11, §1.4.3), run after `patchShebangs` (mkRpmPackage's `postFixup`): every executable regular file of a managed output (not `debugOutput`, not `unmanagedOutputs`) whose `#!` interpreter is under `/usr/`, `/bin/`, `/sbin/` is an error (exit 1) unless runtime FHS (`/bin/sh`, `/usr/bin/env`), its basename is in `lateBind.<output>.interpreters`, or it is in `fhsAllowlist`. Only `outputs`, `debugOutput`, `unmanagedOutputs`, `lateBind`, `fhsAllowlist` of the plan are read |

Exit status: **0** done (no error, or errors not fatal), **1** errors (listed
on stderr, all in `$<prefixOutput>/nix-support/rocky-report.json`), **2**
tool/plan error (unknown plan key, wrong type, rpm query failed, ...).

Run it as the derivation's install step, **before** `fixupPhase`
(`patchShebangs` binds the FHS shebangs afterwards; strip, patchELF,
moveLib64, moveSbin, moveDocs, gzipMan must be off).

## The plan file

Either the plan object itself, or a `__structuredAttrs` attrs file
(`$NIX_ATTRS_JSON_FILE`) containing the plan under **`rockyPlan`**; then the
output paths are taken from the attrs file's `outputs` (unless the plan has
its own `outputs`). WP6 (`mkRpmPackage`) is expected to set
`rockyPlan = { ... }` with `__structuredAttrs = true` and pass the attrs file.
Unknown keys are an error (exit 2); every key but `subpackages` has a default.

### Terms

* **P**, the compile prefix: `%_prefix` of the build = the path of
  `prefixOutput` (unless `--replay`). `prefix` must equal it in a build.
* **rel**: a path relative to an output root. Header paths are mapped
  (design §2.2): `P/x`, `/usr/x`, `/bin/x`, `/sbin/x`, `/lib/x`, `/lib64/x`,
  and `$X/x` for any other output X (a `layout` build) -> `x`; `/etc/x`, `/var/x`, `/run/x` -> `etc/x`, `var/x`, `run/x`;
  debuginfo/debugsource subpackages: `lib/debug/...`, `src/debug/...` in the
  debug output; `usr/lib/.build-id` links of other subpackages are dropped;
  any other absolute path `/a/b` -> `a/b` (reported).
* **rel pattern** (`danglingOk`, `noPatchelf`, keys of `runtimeSearchPaths`,
  `unionDirs`, `searchPaths`, `forward.deny`): matches `rel` if equal, if
  `rel` lies below it, or by `fnmatch` (`*` also matches `/`, so `a/**` works).
* **output pattern** (`opaqueRefs`, `prefixRelativeOk`, `integrityOk`): `"<output>"` or
  `"<output>:<rel glob>"`, both fnmatch (`"langpack_*"`, `"common:bin/locale*"`).
* **@name@** in `systemLibDirs`, `inputLibDirs`, `allowedStorePaths`: replaced
  by the path of output `name` (`"@out@/lib64"`).
* **Requires X**: output Y requires output X if a subpackage of Y has a
  Requires that exactly one subpackage of X provides among the siblings
  (unique provider, [SG] rule; virtual provides of several siblings, like
  `glibc-langpack`, do not count; `rpmlib()` ignored). From `requires` if given,
  else from the RPM headers.

### Keys

| key | type | default | used in | meaning |
|---|---|---|---|---|
| `version` | int | `1` | | schema version |
| `srpm` | string | `""` | report | SRPM name |
| `buildroot` | path | – (required unless `--replay`) | A, B | rpm's `%{buildroot}` after `%install`, brp scripts and find-debuginfo (`--noclean`). `BUILDROOT/usr` may be the fold link to `nix/store/<P>` or a real directory (both are read). Files are **moved** out of it (sole owner) unless `copy` |
| `rpmsDir` | path | – (required unless `--replay`) | A | directory searched recursively for `*.rpm`, one per built subpackage incl. debuginfo. Only headers are read (`rpm -qp --nosignature --nodigest --qf`): payloads may be truncated after the header |
| `rpm` | path | – (required) | A | the rpm binary that reads the headers |
| `rpmConfigDir` | path / null | null | A | `RPM_CONFIGDIR` for it (stage0's FHS rpm needs `${stage0.rpm}/usr/lib/rpm`) |
| `prefix` | path / null | `outputs[prefixOutput]` | all | the compile prefix P (must equal it unless replaying) |
| `prefixOutput` | string | `"out"` | all | the output compiled as `%_prefix` (design §3.1) |
| `outputs` | {name: path} / null | the attrs file's `outputs` | all | every output of the derivation. Each managed output directory is created (Nix needs all) |
| `subpackages` | {rpm name: output} | – (**required**) | A | every **non-debug** subpackage that is built, after merges (merged ones map to the representative's output). A built subpackage missing here -> `undeclared-subpackage`; one listed but not built -> `missing-subpackage`. `*-debuginfo`, `*-debugsource` go to `debugOutput` automatically |
| `debugOutput` | string / null | `"debug"` | A, H | output for all debug subpackages; must be in `outputs` if any is built. May reference siblings; nothing may reference it |
| `unmanagedOutputs` | [output] | `[]` | B, H | outputs the partitioner neither creates nor scans (e.g. `"logs"`, written by the builder). Nothing may reference them |
| `requires` | {subpkg: [subpkg]} / null | null (from headers) | D, E, F | sibling unique-provider Requires (design §2.1: resolved at eval time from `deps.json.gz`); null: computed from the transient headers with the same rule |
| `mergeOutputs` | [[subpkg]] | `[]` | report | the merge groups the caller applied in `subpackages` (first = representative); the report lists references between members and flags groups without any (`merge-unneeded`) |
| `layout` | {macro: output} | `{}` | A | informational: the caller compiles with it (`--define "_datadir $common/share"`); header paths below any output path are mapped anyway. References to such a path are not classified (§2.7: valid only when the whole dir belongs to X) |
| `runtimeSearchPaths` | {rel pattern: VAR} | `{}` | D, F, I | a compiled-in default that dangles: references at/below rel are allowed to dangle (no stub, no error) and every output that has rel gets a setup hook for VAR (dir: `addToSearchPath VAR $o/rel`; file: `export VAR=${VAR:-$o/rel}`; both subject to `searchPathRules.VAR`). Also acks union references |
| `searchPaths` | {rel: VAR} | `{}` | I | extra setup-hook entries (generic table, `lib/rocky/unions.nix`) |
| `searchPathRules` | {VAR: {kind, provider, yieldsTo, hook}} | `{}` | I | the `lib/rocky/unions.nix` contract per variable (mkRpmPackage passes the whole table): `hook: false` = run time only, no hook line (GCONV_PATH); `provider` glob: a directory is an entry only if `<dir>/<glob>` matches (LOCPATH `*/LC_CTYPE`); a list line is guarded `[ -n "${Y-}" ] \|\| addToSearchPath ...` per `yieldsTo` Y; a file/single export is followed by `unset V` for every V yielding to it. A variable without a rule is a plain list |
| `pullToPrefix` | {rel pattern: reason} | `{}` | B | regular files of a non-prefix output X that the prefix output names (a compiled-in default) where no forwarding stub can serve because X references the prefix output: moved into the prefix output, X keeps an absolute symlink (after the symlink phase, so links into rel keep resolving); the ownership index then names the prefix output. glibc: `share/locale/locale.alias`, `lib/locale/C.utf8`. An entry matching nothing, a symlink or an existing target -> `pull-to-prefix` error |
| `unionDirs` | {rel pattern: reason} | `{}` | D | acks references to a directory several outputs fill (design case 3); the reason names the mechanism (search path, profile) |
| `danglingOk` | [rel pattern] | `[]` | C, D | references / symlink targets allowed to exist nowhere (`share/zoneinfo`); also an ld.so token expansion not found in the output the reference points into (`lib/libmemusage.so`, see the classification below) |
| `opaqueRefs` | [output pattern] | `[]` | G | acks store-by-pieces references to P in a non-prefix output (a behaviour test is expected). The reference is registered in `hidden-references` with or without ack |
| `prefixRelativeOk` | [output pattern] | `[]` | D | acks references from a non-prefix output to the bare P, to a top-level dir several outputs fill (`$P/bin`), to a union, or to a path that exists nowhere, in matching files (test support, a cross sysroot, a copied build tree like krb5-tests, `*-config` scripts). Not in design §8.1: requested for `overrides.nix` |
| `forward` | {deny: [rel pattern]} | `{}` | F | rels for which no forwarding stub may be created |
| `lateBind` | {output: {interpreters: [name], libs: [srpm], sonames: [glob]}} | `{}` | E, H | outputs bound later (design §2.9, §11.3). `interpreters`: FHS shebangs of these basenames are expected (info); `libs`/`sonames`: unresolved DT_NEEDED of the output are left to the bind step (all of them if `sonames` is absent) |
| `lateReferrers` | {late output: [output pattern]} | `{}` | H | the static L* list of the bind derivation: every sibling that reaches a late output (except debug/unmanaged) must match, else `late-referrer-missing` |
| `noPatchelf` | [rel pattern] | `[]` | E | ELF files whose RUNPATH is never touched (ld.so, libc, a sysroot; FIPS modules whose RUNPATH is set at link time) |
| `integrityOk` | [output pattern] | `[]` | E | acks `integrity-runpath`: patch the RUNPATH of a matching file although its integrity data cannot follow (an embedded HMAC, an unverifiable companion), because the data is regenerated later or the self-check is known unused |
| `fhsAllowlist` | {string: reason} | `{}` | D | allowed FHS shebangs (`"#!/usr/bin/bash"` or `"/usr/bin/bash"`) |
| `strictFhs` | bool | `false` | D | FHS literals (`/usr/...`, `/bin/...` in text and loaded ELF sections) become errors |
| `allowUnresolvedNeeded` | [soname glob] | `[]` | E | DT_NEEDED allowed to resolve nowhere (bootstrap stages) |
| `inputLibDirs` | [dir] | `[]` | E | library dirs of runtime inputs, searched after the siblings; absolute RUNPATH entries that are not outputs are searched as well |
| `systemLibDirs` | [dir] | `[]` | E | the stage libc's system dirs: sonames found there get no RUNPATH entry (glibc itself: `["@out@/lib64", "@out@/lib"]`) |
| `allowedStorePaths` | [store path] / null | null | D, G | store paths (other than own outputs) allowed in outputs, also inside compressed data (runtime input closure, design §2.5 case 7). null: not checked, reported in `foreignStorePaths` |
| `patchelf` | path / null | null | E | patchelf binary; needed only if a RUNPATH changes (else `runpath-changed` error) |
| `storeDir` | path | `"/nix/store"` | D, H | store dir of the outputs (tests use a fake one); `/nix/store` paths are always recognised |
| `failOnError` | bool | `true` | | exit 1 on errors |
| `reportFile` | path / null | null | | extra copy of the report |
| `copy` | bool | `false` | B | copy files out of the BUILDROOT instead of moving them |
| `maxSamples` | int | `20` | report | info findings listed per code (the rest is counted) |

### Minimal example (structured attrs form, as mkRpmPackage would write it)

```nix
__structuredAttrs = true;
outputs = [ "out" "dev" "lib" "debug" "logs" ];
rockyPlan = {
  srpm = "xz";
  rpm = "/usr/bin/rpm";                     # inside the tool shim; or "${rpm}/bin/rpm"
  buildroot = "/build/rpmbuild/BUILDROOT/xz-5.6.2-4.el10_2.1.x86_64";  # whatever rpmbuild used
  rpmsDir = "/build/rpmbuild/RPMS";
  patchelf = "${patchelf}/bin/patchelf";
  subpackages = { xz = "out"; xz-libs = "lib"; xz-devel = "dev"; xz-static = "static"; xz-lzma-compat = "lzma_compat"; };
  unmanagedOutputs = [ "logs" ];
  systemLibDirs = [ "${glibc}/lib64" ];      # the stage libc
  inputLibDirs = [ ];                       # runtime inputs' lib64/lib
  allowedStorePaths = [ "${glibc}" ];       # runtime input closure
};
installPhase = ''python3 -I ${partitionTool}/rocky-partition --plan "$NIX_ATTRS_JSON_FILE"'';
```

The complete glibc entries (design §11.5 plus what the replay found) are in
`tests/glibc-overrides.nix`.

## What the outputs get

| file | in | content |
|---|---|---|
| `nix-support/rpm/<subpkg>.json` | the subpackage's output | name/EVR/arch, files (header path with P written as `/usr`, rel (exact: a debug file's rel `lib/debug/<P>/...` names P), flags `cdmnsglra`, mode, type, user, group, caps, digest, linkto, size, setid, ghost, config), requires/provides/conflicts/obsoletes/recommends/suggests/supplements/enhances, scriptlets (body + prog), triggers, file triggers, sibling Requires |
| `nix-support/rpm-name` | every managed output with subpackages | its subpackage names, one per line |
| `nix-support/setup-hook` | outputs owning a search-path rel | appended search-path lines |
| `nix-support/hidden-references` | outputs with pieced/nested references | store paths Nix's scanner cannot see in that output (the file makes Nix register them) |
| `nix-support/rocky-stubs` | prefixOutput | `rel target` per forwarding stub |
| `nix-support/rocky-late.json` | prefixOutput | L, L*, referrers, binds (if `lateBind`) |
| `nix-support/rocky-report.json` | prefixOutput | the decision log (below); other outputs' paths written as `$name`, foreign hashes shortened, so it references nothing |

Metadata writes P as `/usr` everywhere except a debug file's `rel` (the
debug output may reference the prefix output anyway). Other store paths in
header data (scriptlets, triggers, dependencies) are checked like file
contents (`foreign-store-path` against `allowedStorePaths`, listed in the
`metadataStorePaths` section). `/etc`, `/var` files are materialised as
`<o>/etc/...` (defaults), `%ghost` files are not.

## The report

`{tool, version, srpm, prefixOutput, replay, outputs, subpackages,
outputRequires, summary{errors, warnings, info, byCode}, findings[], ...sections}`.
Each finding: `{severity, code, message, output?, file?, ref?, owner?, ...}`.
Sections: `materialise`, `symlinks`, `rewrites` (counts per `Y->X` +
samples), `runpath` (changes), `stubs`, `piecedRefs`, `nestedRefs`,
`foreignStorePaths`, `metadataStorePaths`, `fhsLiterals`, `hiddenReferences`,
`setupHooks`, `integrity` (companions, unverifiable, embedded, rehashed),
`graph` (edges with evidence file and count, `sccs`), `merges`, `late`,
`replay`.

| code | severity | when | remedy |
|---|---|---|---|
| `undeclared-subpackage` / `missing-subpackage` | error | built vs `subpackages` | fix the static subpackage list |
| `unclaimed-file` | error | a BUILDROOT file no RPM claims (fold mistake) | fix the fold |
| `missing-file` | error | a header file (not %ghost) is not in BUILDROOT | — |
| `symlink-dangling` | error (info if danglingOk) | target in no output | `danglingOk` |
| `symlink-union` | error | target owned by several outputs, none of them the link's, none uniquely Required | merge / layout |
| `prefix-relative` | error (info if acked) | non-prefix output names bare P, or P/<top dir several outputs fill> (case 5) | `mergeOutputs` (into prefixOutput) or `prefixRelativeOk` |
| `union-unacked` | error | reference to a union dir (case 3) | `unionDirs` / `runtimeSearchPaths` |
| `dangling` | error (info if acked) | reference to a path that exists nowhere (case 4; view leaks), or an ld.so token expansion owned by another output than the one the reference points into | `danglingOk` / `runtimeSearchPaths` / fix the build / `mergeOutputs` |
| `not-required` | warning | text reference into an output the referrer does not Require (case 6): kept as `P/rel` | — |
| `foreign-store-path` | error | store path not allowed (case 7), in a file or in the rpm header data written to `nix-support/rpm/*.json`; also a RUNPATH entry phase E dropped whose bytes are still in the file (phase E overwrites the string `patchelf --remove-rpath` leaves in `.dynstr` with X, as `--set-rpath` does) | `allowedStorePaths` / fix the build |
| `pull-to-prefix` | error / info | a `pullToPrefix` entry that matches nothing, a symlink, or a target that exists (error); a moved file (info) | `pullToPrefix` |
| `binary-ref` | error (info with runtimeSearchPaths) | compiled-in `P/rel` of X ≠ prefix that no stub can serve (not Required, Y == X, cycle, `forward.deny`) | `layout`, `mergeOutputs`, `runtimeSearchPaths` |
| `stub` | info | forwarding stub `$out/rel -> $X/rel` created | — |
| `unresolved-needed` | error (info if allowed/late) | DT_NEEDED found nowhere | `allowUnresolvedNeeded` / `lateBind` / inputs |
| `integrity-runpath` | error (info if acked) | the RUNPATH must change, but the file carries an embedded HMAC or has a companion `.hmac` that cannot be recomputed; the file is left as linked | `noPatchelf` (RUNPATH set at link time), `integrityOk` |
| `integrity-orphan` | warning | a companion `.hmac` whose target is in no output | — |
| `integrity-replay` | warning | `--replay` only: the remap changed a file whose integrity data cannot be recomputed | — (development copy) |
| `ambiguous-needed` | warning | soname in several siblings, none uniquely Required | — |
| `pieced-unacked` | error | store-by-pieces reference in a non-prefix output | `opaqueRefs` (+ behaviour test) |
| `cycle` | error | reference cycle between outputs (with evidence and the suggested `mergeOutputs`) | `mergeOutputs` |
| `debug-referenced` | error | an output references debug/unmanaged output | — |
| `late-referrer-missing` | error | an output reaches a lateBind output but is not in `lateReferrers` | add it |
| `late-elf-ref` | error | ELF content in L* references a late output (outside RUNPATH) | — |
| `replay-remap-incomplete` | warning | the replayed tree's prefix survives (e.g. in a compressed ELF section) | — |
| info codes | info | `union-self`, `pc-expanded`, `cmake-expanded`, `cmake-unrequired`, `integrity-file`, `integrity-rehashed`, `prefix-relative-out`, `nested-ref`, `pieced`, `runpath-changed`, `shared-file`, `pull-to-prefix`, `setid-dropped`, `hardlink-split`, `build-id-dropped`, `other-absolute`, `fhs-shebang`, `fhs-literal`, `merge-unneeded`, `late-referrer-unused` | |

## Reference classification (design §2.5, as implemented)

For every occurrence of `P` (followed by path characters, also ld.so's
`$LIB`/`${PLATFORM}` tokens, whose expansions `lib64`/`lib` are classified:
the native `lib64` expansion decides; an expansion owned by another output
than the one the reference ends up pointing into is a `dangling` error,
ack `danglingOk` with that expansion, e.g. glibc's 32-bit
`lib/libmemusage.so`) in a regular file of output Y, the referenced rel is resolved to an
**anchor**: rel itself if an output has it, else its deepest existing
ancestor below a non-standard directory (`share/locale/%s/...` -> `share/locale`);
no anchor = dangling.

* owner = prefixOutput (or a file shared by it): keep.
* single owner X: text -> rewritten to `$X/rel` if Y == X or Y Requires X,
  else kept + `not-required`; ELF/archive/other binary -> Phase F (forwarding
  stub `$P/anchor -> $X/anchor` if Y Requires X, Y ≠ X and X does not reach
  P; else `binary-ref`), except the bytes of the RUNPATH string (Phase E).
* several owners: a shared *file* -> Y's own copy, or the uniquely Required
  owner; a *directory* -> union (`union-unacked` unless acked); a standard
  top-level dir (`bin`, `lib64`, `share`, ...) -> like the bare prefix.
  **Text in a non-prefix output Y that owns part of a `lib64`/`lib`/`include`
  union is rewritten to `$Y/...`** (`union-self`: a `-devel` `.pc` libdir
  points at the unversioned `.so` link).
* bare P (or a top-level dir several outputs fill) from a non-prefix output:
  `prefix-relative`, except a pkg-config variable defined as it that no
  other line uses (also via `exec_prefix=${prefix}`).
* pkg-config files of a non-prefix output (`pc-expanded`): variables derived
  from P (`libdir=${prefix}/lib64`, `exec_prefix=${prefix}`,
  `pkgdatadir=${datadir}/foo`, as meson and cmake write them) are written
  out in full in their definitions, and `${prefix}`-aliases in other lines
  (`Cflags: -I${prefix}/include`); the literal paths then follow the rules
  above (`$dev/lib64`, `$dev/include`), and the prefix variables are unused.
  `Libs: -L${libdir}` lines keep their variables.
* CMake export files of a non-prefix output (`cmake-expanded`, `*.cmake`
  holding `set(_IMPORT_PREFIX "<P>")`, as install(EXPORT) writes it for
  absolute install dirs): every `${_IMPORT_PREFIX}` is written out as P, so
  `${_IMPORT_PREFIX}/include` becomes a literal path the rules above rewrite
  (`$dev/include`); the now unused definition is acked.
  A reference in a CMake export file (`*.cmake` naming
  `_cmake_import_check_files_for_*`, `_IMPORT_CHECK_FILES_FOR_*` or
  `IMPORTED_LOCATION`) to a sibling the file's output does not Require is
  rewritten anyway (`cmake-unrequired`, info; the edge is added): find_package()
  checks that every imported file exists, and `$P/rel` never would (zlib-ng:
  `compat_devel`'s `ZLIB::zlibstatic` names `libz.a` of `compat_static`; on
  Rocky installing `-static` makes the path exist, in Nix the edge does).
* files below `share/doc`, `share/man`, `share/info`, `share/gtk-doc`,
  `share/help`: references are classified and recorded (edges) but never
  errors (prose mentions install dirs).
* shebangs: `#!/bin/sh` and `#!/usr/bin/env` are runtime FHS (design §1.4);
  other FHS interpreters are `fhs-shebang` warnings unless allowlisted or
  late-bound (patchShebangs in fixupPhase is expected to bind them); what is
  still unbound after it fails `--check-shebangs`.

Store-by-pieces windows: 8-byte windows of P holding at least 6 bytes of its
hash, in loaded sections of ELF files, outside full occurrences.

## Phase E: RUNPATH tags and dropped strings

* mkRpmPackage links with `--disable-new-dtags` (Rocky's ld default: Rocky's
  `-z now` stays DT_BIND_NOW, its `-rpath '$ORIGIN'` stays DT_RPATH), so the
  cc wrapper's store `-rpath` entries land in a DT_RPATH. Phase E writes
  every recomputed RUNPATH with `patchelf --set-rpath`, which makes it
  DT_RUNPATH; a DT_RPATH whose recomputed value is unchanged but still holds
  an input's store dir is rewritten too (DT_RUNPATH, Nix's convention). A
  DT_RPATH of Rocky's own entries only (`$ORIGIN`, the package's dirs) keeps
  its tag.
* `patchelf --remove-rpath` drops the dynamic entry but leaves the old
  string in `.dynstr` (`--set-rpath` overwrites it with X): phase E
  overwrites every NUL-delimited copy of the removed string in `.dynstr`
  with X, and `foreign-store-path` fires for a dropped entry whose hash is
  still anywhere in the file (M1 review: sed and bzip2 against glibc¹ kept
  the cc wrapper's gcc copy and the libc dev output as references).

## Phase E and FIPS integrity data

patchelf changes the bytes of the file, which invalidates the FIPS
self-check data Rocky ships for some libraries:

* **companion files** (fipscheck format: one hex HMAC-SHA256 line, key
  `orboDeJITITejsirpADONivirpUkvarP`): `<dir>/fipscheck/<name>.hmac`
  (libxcrypt) and `<dir>/.<name>.hmac` (nettle); `<name>` may be a symlink
  (`libcrypt.so.2.hmac`). A companion that verifies against its target
  before Phase E is **recomputed** after the target changed
  (`integrity-rehashed`), exactly what `fipshmac` did at the end of
  `%install`. A companion in another format (gnutls' INI file) cannot be
  verified: patching its target is refused (`integrity-runpath`).
* **embedded HMACs**: ELF section `.rodata1` (openssl's `fips.so`,
  `fips-hmacify.sh`) or `.note.fdo.integrity` (libgcrypt,
  `gen-note-integrity.sh`): patching is refused (`integrity-runpath`).

A refused file keeps the RUNPATH it was linked with; the remedy is to set
the RUNPATH at link time (`LDFLAGS=-Wl,-rpath,...`) and list the file in
`noPatchelf`, or `integrityOk` when the data is regenerated after the
partition or known unused.
