# RPM parity + purity checks

`tools/rpm-parity.py` compares RPMs we build against the **official Rocky
RPMs** (fetched as FODs from `lock/rocky-<rel>/rpms.json`) and fails on any
difference that is not declared as expected in an allowlist. It also fails,
unconditionally, on any `/nix/store` string in our headers or payloads --
including inside compressed payload files, ELF MiniDebugInfo and compressed
ELF sections (the scanner is `tools/rpm_purity.py`, which every `buildSrpm`
also runs on its own output, see "Purity" below).
`lib/parity.nix` wraps it as a plain derivation (`mkParityCheck`), so a parity
check is just another `checks.x86_64-linux.*` attribute. No IFD: the official
package list comes from the lock at evaluation time; which binary packages a
build produced is discovered by the tool at build time.

## TL;DR

```nix
# legacyPackages.x86_64-linux.mkParityCheck
parity-glibc = mkParityCheck {
  name = "glibc";
  ours = glibcBuild;   # a buildSrpm result ($out/RPMS/*/*.rpm), or rpm files/dirs, or a list
  # srpm     ? ours.srpmName                     -> official = rpmsLock.bySrpm.glibc (221 RPMs)
  # allow    ? tools/parity/glibc.json if it exists (it does: extends stage0.json)
  # exclude  ? [ ]  keep ? [ ]                   regexes over NAME.ARCH, both sides
  # deep ? false   failOnDiff ? true   extraArgs ? [ ]
};
```

```
nix build .#checks.x86_64-linux.parity-glibc          # fails on unexpected differences
nix build .#checks.x86_64-linux.parity-glibc.report   # same, never fails: read result/report.md
nix log   .#checks.x86_64-linux.parity-glibc          # unexpected findings are printed to the log
nix run   .#rpm-parity -- --ours a/RPMS --official b.rpm --allow tools/parity/x.json --out /tmp/r
```

Output (`$out`): `report.md` (human) and `report.json` (machine-readable, same
content, every difference with its id, both values, allowed/reason).

## Checks in the flake

| check | what | result |
|---|---|---|
| `parity-which` | `stage0.srpm.which` vs official `which-2.21-44.el10_0` (`tools/parity/which.json` → stage0) | PASS: 0 unexpected, 19 allowed; `/usr/bin/which`: every ELF property, dynamic symbol, version and the segment layout equal, but the machine code of `main()` differs (6 loaded sections, same sizes; LTO; see which.json and [glibc.md](glibc.md) "Known differences") |
| `parity-redhat-rpm-config` | `stage0.srpm.redhat-rpm-config` vs official (`--deep`) | PASS: 37/37 files byte-identical (even the payload digest is equal); only header identity fields differ |
| `parity-glibc-official-self` | the 16 official glibc RPMs (all but the langpacks, `glibc-langpack-en` kept) vs themselves, `--deep --fail-on-unused`, no SRPM allowlist | PASS: 0 differences; 718 ELF + 12 ar files parsed and compared, 2 120 payload digests per side verified against the headers; 205 langpacks listed as excluded |
| `glibc-parity` | `srpm.glibc` (233 RPMs) vs **all 221** official glibc RPMs (`tools/parity/glibc.json` → stage0 → default) | PASS: 0 unexpected, 5117 allowed — numbers and every remaining difference in [glibc.md](glibc.md#parity-with-the-official-rpms) |
| `kernel-headers-parity` | `stage0.kernelHeadersBuild` vs official `kernel-headers` + `kernel-modules-extra-matched` (`tools/parity/kernel.json`; the other 28 kernel binaries are excluded) | PASS: 0 unexpected, 34 allowed; 1015/1015 common files identical; the 21 leaked tools headers are the only file-list difference |
| `parity-selftest-noallow` | which vs official **without** any allowlist must FAIL with the known differences (BUILDHOST, OPTFLAGS/annobin, `content.elf:/usr/bin/which`, `elf.alloc:/usr/bin/which:.text`, debuginfo only-ours, PAYLOADDIGESTALT) | negative test, passes |
| `parity-selftest-purity` | a tiny rpm built with nixpkgs' `rpmbuild` whose file, symlink and header mention `/nix/store` must FAIL with 3 purity violations | negative test, passes |
| `parity-selftest-purity-nested` | store paths **hidden** in a gzip'ed man page and in the xz `.gnu_debugdata` of an ELF (raw bytes clean) must FAIL with exactly those 2 nested hits | negative test, passes |
| `purity-selftest-nested`, `purity-selftest-plain` | the same fixtures through `tools/rpm_purity.py` (the build-time scanner): exit 1 and the hits | negative tests, pass |
| `parity-selftest-abi` | two `libx.so.1` that differ only in the dynamic symbol table (`bar@@X_1.0` removed; rpm's auto-Provides are identical) must FAIL with `elf.dynsym:…:-bar@@X_1.0 …` | negative test, passes |
| `abi-compare-selftest` | the same fixture through the binutils-based `tools/abi-compare.py` (`checks.glibc-abi`) | negative test, passes |
| `parity-selftest-empty` | comparing two empty directories must be a tool error (exit 2), never a PASS | negative test, passes |

The stage0 checks reuse the existing `stage0.srpm.*` builds (nothing in
`bootstrap/` is rebuilt). Each parity check runs in seconds (the glibc
16-package self comparison: ~2-3 s of CPU, 34 MB of RPMs).

The ELF reader was cross-checked against binutils `readelf` on all 718 ELF
files of those 16 glibc packages (NEEDED, SONAME, RUNPATH, INTERP, build-id,
GNU properties, stapsdt notes, section lists, BIND_NOW, PIE, GNU_HASH): no
mismatch apart from readelf's own formatting.

## How it works

`rpm-parity.py` is Python 3 stdlib only (runs with nixpkgs' python3 outside
any chroot; needs the `zstd` binary on Python < 3.14). It does not use rpm or
readelf, so its results do not depend on tool versions:

1. **Headers** are parsed directly (lead, signature header — ignored — and the
   main header). Tag numbers come from rpm's `rpmtag.h`; unknown tags are still
   compared, by number.
2. Packages from both sides are **paired by `NAME.ARCH`**; source RPMs are
   skipped (`--include-src` to compare them). Unpaired packages are listed as
   `package.only-ours:` / `package.only-official:` differences.
3. For each pair, header, dependency, scriptlet, trigger, changelog and file
   metadata comparisons are made from the headers; the set of regular files
   whose **header digests differ** is computed.
4. Each **payload** is streamed once (zstd/xz/gzip/bzip2 → newc cpio): every
   file's digest is recomputed and checked against the header (`integrity`),
   our payloads are scanned for `/nix/store` (file contents, symlink targets,
   and inside nested compression -- see "Purity"), and the files whose
   content differs are classified as `elf`, `ar` or `other` and analysed (ELF
   facts incl. the ABI and the loaded bytes, archive members one by one,
   unified diff of small text files). Hard links are handled by inode group.
5. Every difference gets a **stable id**; allowlist rules are matched against
   it. A package FAILs on any unallowed difference, any purity hit, or any
   integrity error. The tool exits 0 (PASS), 1 (FAIL) or 2 (tool error);
   comparing nothing (no package present on both sides after filtering) is a
   tool error.

### What is compared (difference ids)

| id | compared |
|---|---|
| `nevr` | `name-[epoch:]version-release` |
| `payload.compressed` | `PAYLOADDIGEST` differs although `PAYLOADDIGESTALT` (the uncompressed payload) is equal: the compressor produced different bytes for the same cpio (a different libzstd). Reported instead of `header.PAYLOADDIGEST`, which therefore only appears when the payload itself differs |
| `header.<TAG>` | every other main-header tag not listed below, by value (`LICENSE`, `GROUP`, `URL`, `SUMMARY`, `DESCRIPTION`, `ARCH`, `OPTFLAGS`, `PLATFORM`, `SOURCERPM`, `RPMVERSION`, `PAYLOADCOMPRESSOR`, `PAYLOADFLAGS`, `FILEDIGESTALGO`, `VENDOR`, `BUILDHOST`, `COOKIE`, …). Space-separated strings (OPTFLAGS) also get a token diff in the report |
| `changelog` | all changelog entries (time, name, text) |
| `provides:+X` / `provides:-X` | dependency only in ours (+) / only official (−); same for `requires`, `conflicts`, `obsoletes`, `recommends`, `suggests`, `supplements`, `enhances`, `order`. X is rendered like `name >= evr (pre,post)` with scriptlet qualifiers (`pre post preun postun pretrans posttrans preuntrans postuntrans verify interp meta`) |
| `script.<name>` | `pretrans prein postin preun postun posttrans preuntrans postuntrans verify`: interpreter (+args), flags (e.g. macro expansion) and body |
| `trigger<type>: <conditions> [prog …]` | each trigger script, likewise `filetrigger…`/`transfiletrigger…` (with priority) |
| `file.only-ours:<path>`, `file.only-official:<path>` | file list |
| `file.<attr>:<path>` | `mode` (octal, incl. type), `user`, `group`, `linkto` (symlink target), `flags` (letters: `c`onfig `d`oc `m`issingok `n`oreplace `s`pecfile `g`host `l`icense `r`eadme `p`ubkey `a`rtifact), `verifyflags` (hex), `lang`, `caps`, `color` (ELF class), `class` (libmagic text, build-id masked), `rdev`, `nlink` (hard-link count within the package) |
| `content.<kind>:<path>` | regular files (not ghosts) in both whose header digests differ; kind `elf`, `ar` or `other`. For `other` text files ≤ 1 MiB the report shows a unified diff |
| `ar.members:<path>` | member names **and order** of a differing static archive |
| `ar.armap:<path>:+S` / `:-S` | symbol in the archive's symbol index (armap) only in ours / only official |
| `ar.member:<path>(<m>)` | a non-ELF archive member's content digest |
| `elf.<prop>:<path>` | for differing ELF files: `class machine type interp needed soname rpath runpath gnu_hash sysv_hash bind_now pie textrel relr execstack relro build_id`(presence) `gnu_property` (x86 feature IBT/SHSTK, ISA needed/used, feature used, …) `abi_tag stapsdt` (note count) `package_note` (the FDO packaging-metadata JSON) `comment` (.comment strings) |
| `elf.section:<path>:+S` / `:-S` | section only in ours / only official (`.gnu_debugdata`, `.gnu_debuglink`, `.annobin.notes`, `.gnu.build.attributes`, `.symtab`, `.debug_*`, …) |
| `elf.dynsym:<path>:+S` / `:-S` | **dynamic symbol** only in ours / only official, rendered `name[@VER\|@@VER] TYPE BIND VISIBILITY SECTION SIZE` (values left out: addresses are layout, covered by `elf.alloc`). Catches a symbol added to / removed from an existing version node, or a changed type, binding, visibility or size -- which rpm's auto-Provides (`libx.so.1(X_1.0)`) cannot |
| `elf.verdef:<path>:±V`, `elf.verneed:<path>:±F:V` | version definitions (`name [BASE] [< parents]`) and needed versions (`file:version [WEAK]`) |
| `elf.alloc:<path>:<section>` | type, flags, size, alignment and **sha256 of the bytes** of every `SHF_ALLOC` section (everything the loader maps: code, data, `.dynsym`, `.rela.*`, notes …) except `.note.gnu.build-id`; duplicate names are numbered `name#2` |
| `elf.segments:<path>` | the program headers (type, offset, vaddr, filesz, memsz, flags, alignment) |
| `elf.symbol:<path>:±S` | relocatable objects only (crt files, archive members): non-local `.symtab` symbols (defined: type, binding, visibility, section, size; undefined: `UND`) |
| `elf.relocs:<path>:<section>` | relocatable objects only: count and digest of the relocations against each loaded section, by symbol *name* (section symbols as `[section]`), so they compare across differing symbol table order |
| `elf.error:<path>` | unparseable ELF |
| `package.only-ours:<key>`, `package.only-official:<key>` | subpackage present on one side only |
| purity | `/nix/store` in any header string, payload file or symlink target of OUR packages (debuginfo/debugsource included). **Cannot be allowlisted.** |
| integrity | payload file digest ≠ header digest (either side). Cannot be allowlisted. |

Static archives are compared member by member: every ELF member gets all of
the `elf.*` comparisons above under the path `<archive>(<member>)` (e.g.
`elf.alloc:/usr/lib64/libc.a(printf.o):.text`). Member headers (date,
uid/gid, mode) are archiver metadata and are not compared.

Not compared: signatures, `FILEMTIMES`, inode/device numbers (only used for
`nlink`), the per-file dependency tables (package-level deps cover them),
non-loaded ELF sections (`.debug_*`, `.symtab`/`.strtab` of linked objects,
`.comment` is compared as a property, `.annobin.notes`, `.gnu_debuglink`,
`.gnu_debugdata`), and ELF section *bytes* of relocatable objects that are
not loaded (`.group` member indices shift when sections are missing).
`--deep` additionally compares ELF/ar facts of files whose content is
identical (exercises the parsers; used by the self comparison).

### Purity

Our packages' headers (main and signature) and every payload member are
searched byte by byte for `/nix/store`, and so is everything **nested**:
gzip/xz/bzip2/zstd members are decompressed and searched again (man and info
pages, `.tar.gz` …), ELF files (also archive members) have their
xz-compressed MiniDebugInfo (`.gnu_debugdata`) and `SHF_COMPRESSED` sections
(zlib/zstd) decompressed and searched, up to 4 levels deep. Hits are
reported with the nesting chain (`payload>gzip`, `payload>.gnu_debugdata`,
`payload>(member.o)>.debug_info(zlib)` …). The scanner is
`tools/rpm_purity.py`; rpm-parity imports it, and **`buildSrpm` runs it on
every build** (`$logs/purity.json`), so a leak fails the build that produced
it, whether or not a parity check exists for the package.

This is the guard; `allowedReferences = [ ]` on `buildSrpm`/`rpmTree` is not
enough on its own: Nix only scans outputs for hashes of paths in the
derivation's *input closure* (for `rpmTree`: rpm, cpio, stdenv -- not the
nixpkgs tools of the buildroot), and never inside compressed data.

**Build-id normalization** (option `normalize_build_id`, on by default): the
`/usr/lib/.build-id/xx/yyyy…` links (and `/usr/lib/debug/.build-id/…`) are
keyed by their target, e.g. `/usr/lib/.build-id/<build-id> -> ../../../../usr/bin/which`,
and the `xx` fan-out directories are dropped, because build-ids always differ
between builds. `BuildID[sha1]=…` is masked in FILECLASS strings.

## Allowlists

JSON files; `tools/parity/default.json` is always loaded (unless
`--no-default-allow`), then each `--allow` file (`mkParityCheck`'s `allow`,
default `tools/parity/<srpm>.json` when that file exists).

```json
{
  "description": "why this file exists",
  "extends": ["stage0"],                  // other allowlists: by path, or name in tools/parity/
  "options": { "normalize_build_id": true },
  "rewrite": [                            // normalize a value BEFORE comparing
    { "field": "header.OPTFLAGS", "side": "official",     // ours | official | both (default)
      "pattern": "-specs=/usr/lib/rpm/redhat/redhat-annobin-cc1", "replace": "",
      "packages": "*", "reason": "…" }
  ],
  "allow": [                              // accept a difference
    { "id": "elf.section:*:-.annobin.notes", "packages": ["glibc*.x86_64"],
      "ours": "^null$", "official": "regex", "reason": "…" }
  ]
}
```

* `allow[].id` and `rewrite[].field` are shell-style globs (`fnmatch`, `*`
  also matches `/`; write a literal `[` as `[[]`) over the difference id /
  field; `allow[].id` may also be a list of globs (one reason for several
  exact ids, instead of one broad glob). `packages` (glob or list, default `*`) matches `NAME.ARCH`.
  `ours` / `official` are optional regexes searched in the JSON encoding of
  that side's value (`null` when absent), so a rule can say "allowed only
  while ours is unset".
* A `rewrite` applies `re.sub(pattern, replace)` to the field value on the
  given side (to each element for lists such as dependency sets, dropping
  elements that become empty unless `"drop_empty": false`). Fields:
  `header.<TAG>`, `nevr`, `changelog`, `script.<name>`, trigger keys,
  `file.<attr>:<path>`, `elf.<prop>:<path>`, `elf.section:<path>`, and the
  dependency kinds (`requires`, `provides`, …). Values made equal by a rewrite
  are listed under "Normalized by rewrite rules" in the report.
* `reason` is mandatory. Rules that match nothing are listed in the report
  ("unused"); `--fail-on-unused` turns that into a failure. Rules from
  `default.json` and rules with `"optional": true` are never reported unused.
* Purity and integrity findings cannot be allowed.

### Shipped allowlists (`tools/parity/`)

* **`default.json`** — true for any rebuild: `BUILDTIME`, `BUILDHOST`,
  `COOKIE` (rpmbuild `--rebuild` copies the SRPM's cookie, i.e. Rocky's build
  host, into the binaries; Koji-built official binaries have none), `SIZE`/
  `LONGSIZE`, `PAYLOADDIGESTALT` and `PAYLOADDIGEST` (only reported when the
  uncompressed payload differs; `payload.compressed` is never allowed here); `VENDOR`, `PACKAGER`,
  `DISTRIBUTION` (`Rocky Linux 10`), `BUGURL` (`https://bugs.rockylinux.org`)
  **only while ours is unset** (Rocky's build system sets these four macros;
  `buildSrpm` deliberately does not claim Rocky's identity — set them via
  `vendor`/`packager`/`defines` if that policy changes, and the rule stops
  matching); `content.elf:*` and `content.ar:*` (everything that is loaded or linked is
  compared instead: `elf.alloc`, `elf.segments`, `elf.dynsym`/`verdef`/`verneed`,
  `elf.symbol`/`elf.relocs`, `ar.members`/`ar.armap` and the properties --
  none of which is allowed by `default.json`); `package.only-ours:*-debuginfo.*` / `*-debugsource.*` (the lock
  has no debug repos).
* **`stage0.json`** — stage0 hacks (docs/stage0.md): the
  `-specs=/usr/lib/rpm/redhat/redhat-annobin-cc1` token is removed from the
  official `OPTFLAGS` (macros.stage0 empties `%_annobin_gcc_plugin`; the rest
  of the string must still match exactly, including the extra space it
  leaves); missing `.annobin.notes` / `.gnu.build.attributes` /
  `.rela.gnu.build.attributes` sections are allowed (optional rules).
  (The stage0 rpm links libzstd and libmagic built from Rocky's zstd/file
  SRPM sources, so payload compression and FILECLASS strings need no rules.)
* **`redhat-rpm-config.json`** — `extends: ["stage0"]`, nothing else.
* **`which.json`** — `extends: ["stage0"]` + the 6 loaded sections of
  `/usr/bin/which` whose bytes differ (machine code of `main()` under LTO,
  same sizes; not caused by the C library; not fully root-caused, see the
  rule's reason).
* **`glibc.json`** — `extends: ["stage0"]`: the three subpackages glibc.spec
  builds but Rocky does not publish (`glibc32`, `sysroot-x86_64-el10-glibc`,
  `compat-libpthread-nonshared`), the `<id>`/`<id>.2` build-id link names
  of the hard-linked getconf binaries (readdir order of the build filesystem),
  and the loaded-byte/segment differences of `/usr/bin/memusagestat` (copy
  relocations laid out after nixpkgs' libgd, five exact section ids; see
  docs/glibc.md "Known differences / open issues").
* **`kernel.json`** — `extends: ["stage0"]`: the 21 tools headers (`perf/`,
  `internal/`, `cpuidle.h`, `powercap.h`) that the full kernel build leaks
  into the official kernel-headers.

## Adding a parity check for a new SRPM

```nix
# default.nix, parityChecks
foo-parity = parity.mkParityCheck { name = "foo"; ours = <buildSrpm result>; };
```

`srpm` defaults to `ours.srpmName`, so `official` = every RPM of
`rpmsLock.bySrpm.<srpm>` and `allow` = `tools/parity/<srpm>.json` if present
(start it with `"extends": ["stage0"]`). Build `.report`, read
`result/report.md`, and for every unexpected difference either fix the build
or add a rule with a reason. `glibc-parity` and `kernel-headers-parity` in
`default.nix` are the worked examples (the latter with `exclude`/`keep`).

## Files

* `tools/rpm-parity.py` — the tool (docstring = CLI reference).
* `tools/rpm_purity.py` — the purity scanner (also run by every `buildSrpm`)
  and the shared rpm/cpio reader.
* `tools/abi-compare.py` — the binutils-based ABI cross-check
  (`checks.glibc-abi`, docs/glibc.md).
* `tools/parity/*.json` — allowlists.
* `lib/parity.nix` — `mkParityCheck`, the checks above, the fixtures
  (`impureRpm`, `nestedImpureRpm`, `abiRpms`), `tool` (store path of the
  script).
* Attributes: `legacyPackages.x86_64-linux.{mkParityCheck, parityChecks, parityTool}`,
  `checks.x86_64-linux.parity-*`, app `rpm-parity`.

## Limitations

* rpm's "stripped" cpio format for payloads with files ≥ 4 GiB is not
  supported (error, never silent).
* Only x86 GNU property bits are decoded by name (others shown in hex).
* Text diffs are shown for files ≤ 1 MiB; bigger differing files are only
  reported by size/digest.
* Non-loaded ELF content (debug sections, `.symtab` of linked objects, the
  MiniDebugInfo symbol list) is not compared, only searched for `/nix/store`;
  a debug-info-only difference shows up as `content.elf`, which is allowed.
* `.symtab`-level symbols of linked DSOs/executables (beyond `.dynsym`) are
  not compared; for relocatable objects only non-local symbols are.
* The nested purity scan follows up to 4 levels and refuses (tool error) to
  inflate a single member beyond 4 GiB; data that looks compressed but does
  not decompress is only searched raw; other formats (e.g. lzip, `.lzma`
  alone, squashfs images) are only searched raw.
