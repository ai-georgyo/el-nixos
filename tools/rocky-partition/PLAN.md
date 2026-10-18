# rocky-partition: invocation and plan.json (schema v1)

`rocky-partition` is the in-build step of design §2
(`docs/nix-native-design.md`): after `rpmbuild -bb --noclean` it moves the
BUILDROOT into one Nix output per subpackage, fixes symlinks, rewrites text
references, recomputes RUNPATH, creates forwarding stubs, registers hidden
references, checks the output graph and writes metadata. ELF contents are
never rewritten (only RUNPATH, through patchelf).

## Invocation

```sh
python3 -I $tool/rocky-partition --plan "$NIX_ATTRS_JSON_FILE"            # in the build
python3 -I $tool/rocky-partition --plan plan.json --replay TREE [--remap OLD=NEW]   # development
PYTHONPATH=tools/rocky-partition python3 -m rocky_partition --plan ...    # from a checkout
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
| `--replay TREE` | take `buildroot`, `rpmsDir` and the compile prefix from a kept build tree (`TREE/BUILDROOT`, `TREE/RPMS`, `TREE/prefix`); files are copied, never moved; at the end every output is remapped OLD -> NEW (same length: raw bytes, store-by-pieces windows, symlink targets, whole-file gzip/xz/bzip2/zstd members re-encoded). Development only (design §11.4) |
| `--remap OLD=NEW` | with `--replay`: OLD must be the tree's prefix, NEW the path of `prefixOutput` (default: exactly that) |
| `--report FILE` | also write the report here (e.g. `$NIX_BUILD_TOP`, survives a failed build with `--keep-failed`) |
| `--no-fail` | exit 0 even with errors (experiments; `failOnError = false` in the plan does the same) |

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
* **output pattern** (`opaqueRefs`, `prefixRelativeOk`): `"<output>"` or
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
| `runtimeSearchPaths` | {rel pattern: VAR} | `{}` | D, F, I | a compiled-in default that dangles: references at/below rel are allowed to dangle (no stub, no error) and every output that has rel gets a setup hook for VAR (dir: `addToSearchPath VAR $o/rel`; file: `export VAR=${VAR:-$o/rel}`). Also acks union references |
| `searchPaths` | {rel: VAR} | `{}` | I | extra setup-hook entries (generic table, `lib/rocky/unions.nix`) |
| `unionDirs` | {rel pattern: reason} | `{}` | D | acks references to a directory several outputs fill (design case 3); the reason names the mechanism (search path, profile) |
| `danglingOk` | [rel pattern] | `[]` | C, D | references / symlink targets allowed to exist nowhere (`share/zoneinfo`) |
| `opaqueRefs` | [output pattern] | `[]` | G | acks store-by-pieces references to P in a non-prefix output (a behaviour test is expected). The reference is registered in `hidden-references` with or without ack |
| `prefixRelativeOk` | [output pattern] | `[]` | D | acks references from a non-prefix output to the bare P, to a top-level dir several outputs fill (`$P/bin`), to a union, or to a path that exists nowhere, in matching files (test support, a cross sysroot, a copied build tree like krb5-tests, `*-config` scripts). Not in design §8.1: requested for `overrides.nix` |
| `forward` | {deny: [rel pattern]} | `{}` | F | rels for which no forwarding stub may be created |
| `lateBind` | {output: {interpreters: [name], libs: [srpm], sonames: [glob]}} | `{}` | E, H | outputs bound later (design §2.9, §11.3). `interpreters`: FHS shebangs of these basenames are expected (info); `libs`/`sonames`: unresolved DT_NEEDED of the output are left to the bind step (all of them if `sonames` is absent) |
| `lateReferrers` | {late output: [output pattern]} | `{}` | H | the static L* list of the bind derivation: every sibling that reaches a late output (except debug/unmanaged) must match, else `late-referrer-missing` |
| `noPatchelf` | [rel pattern] | `[]` | E | ELF files whose RUNPATH is never touched (ld.so, libc, a sysroot) |
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
| `nix-support/rpm/<subpkg>.json` | the subpackage's output | name/EVR/arch, files (header path with P written as `/usr`, rel, flags `cdmnsglra`, mode, type, user, group, caps, digest, linkto, size, setid, ghost, config), requires/provides/conflicts/obsoletes/recommends/suggests/supplements/enhances, scriptlets (body + prog), triggers, file triggers, sibling Requires |
| `nix-support/rpm-name` | every managed output with subpackages | its subpackage names, one per line |
| `nix-support/setup-hook` | outputs owning a search-path rel | appended search-path lines |
| `nix-support/hidden-references` | outputs with pieced/nested references | store paths Nix's scanner cannot see in that output (the file makes Nix register them) |
| `nix-support/rocky-stubs` | prefixOutput | `rel target` per forwarding stub |
| `nix-support/rocky-late.json` | prefixOutput | L, L*, referrers, binds (if `lateBind`) |
| `nix-support/rocky-report.json` | prefixOutput | the decision log (below); other outputs' paths written as `$name`, foreign hashes shortened, so it references nothing |

Metadata never contains store paths (Nix would see edges); `/etc`, `/var`
files are materialised as `<o>/etc/...` (defaults), `%ghost` files are not.

## The report

`{tool, version, srpm, prefixOutput, replay, outputs, subpackages,
outputRequires, summary{errors, warnings, info, byCode}, findings[], ...sections}`.
Each finding: `{severity, code, message, output?, file?, ref?, owner?, ...}`.
Sections: `materialise`, `symlinks`, `rewrites` (counts per `Y->X` +
samples), `runpath` (changes), `stubs`, `piecedRefs`, `nestedRefs`,
`foreignStorePaths`, `fhsLiterals`, `hiddenReferences`, `setupHooks`, `graph`
(edges with evidence file and count, `sccs`), `merges`, `late`, `replay`.

| code | severity | when | remedy |
|---|---|---|---|
| `undeclared-subpackage` / `missing-subpackage` | error | built vs `subpackages` | fix the static subpackage list |
| `unclaimed-file` | error | a BUILDROOT file no RPM claims (fold mistake) | fix the fold |
| `missing-file` | error | a header file (not %ghost) is not in BUILDROOT | — |
| `symlink-dangling` | error (info if danglingOk) | target in no output | `danglingOk` |
| `symlink-union` | error | target owned by several outputs, none of them the link's, none uniquely Required | merge / layout |
| `prefix-relative` | error (info if acked) | non-prefix output names bare P, or P/<top dir several outputs fill> (case 5) | `mergeOutputs` (into prefixOutput) or `prefixRelativeOk` |
| `union-unacked` | error | reference to a union dir (case 3) | `unionDirs` / `runtimeSearchPaths` |
| `dangling` | error (info if acked) | reference to a path that exists nowhere (case 4; view leaks) | `danglingOk` / `runtimeSearchPaths` / fix the build |
| `not-required` | warning | text reference into an output the referrer does not Require (case 6): kept as `P/rel` | — |
| `foreign-store-path` | error | store path not allowed (case 7) | `allowedStorePaths` / fix the build |
| `binary-ref` | error (info with runtimeSearchPaths) | compiled-in `P/rel` of X ≠ prefix that no stub can serve (not Required, Y == X, cycle, `forward.deny`) | `layout`, `mergeOutputs`, `runtimeSearchPaths` |
| `stub` | info | forwarding stub `$out/rel -> $X/rel` created | — |
| `unresolved-needed` | error (info if allowed/late) | DT_NEEDED found nowhere | `allowUnresolvedNeeded` / `lateBind` / inputs |
| `ambiguous-needed` | warning | soname in several siblings, none uniquely Required | — |
| `pieced-unacked` | error | store-by-pieces reference in a non-prefix output | `opaqueRefs` (+ behaviour test) |
| `cycle` | error | reference cycle between outputs (with evidence and the suggested `mergeOutputs`) | `mergeOutputs` |
| `debug-referenced` | error | an output references debug/unmanaged output | — |
| `late-referrer-missing` | error | an output reaches a lateBind output but is not in `lateReferrers` | add it |
| `late-elf-ref` | error | ELF content in L* references a late output (outside RUNPATH) | — |
| `replay-remap-incomplete` | warning | the replayed tree's prefix survives (e.g. in a compressed ELF section) | — |
| info codes | info | `union-self`, `prefix-relative-out`, `nested-ref`, `pieced`, `runpath-changed`, `shared-file`, `setid-dropped`, `hardlink-split`, `build-id-dropped`, `other-absolute`, `fhs-shebang`, `fhs-literal`, `merge-unneeded`, `late-referrer-unused` | |

## Reference classification (design §2.5, as implemented)

For every occurrence of `P` (followed by path characters, also ld.so's
`$LIB`/`${PLATFORM}` tokens, whose expansions `lib64`/`lib` are classified)
in a regular file of output Y, the referenced rel is resolved to an
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
* bare P from a non-prefix output: `prefix-relative`, except a pkg-config
  variable defined as P that no other line uses (also via `exec_prefix=${prefix}`).
* files below `share/doc`, `share/man`, `share/info`, `share/gtk-doc`,
  `share/help`: references are classified and recorded (edges) but never
  errors (prose mentions install dirs).
* shebangs: `#!/bin/sh` and `#!/usr/bin/env` are runtime FHS (design §1.4);
  other FHS interpreters are `fhs-shebang` warnings unless allowlisted or
  late-bound (patchShebangs in fixupPhase is expected to bind them).

Store-by-pieces windows: 8-byte windows of P holding at least 6 bytes of its
hash, in loaded sections of ELF files, outside full occurrences.
