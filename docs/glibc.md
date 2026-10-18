# glibc-2.39-142.el10_2 built from the Rocky SRPM (milestone 1)

The official `glibc-2.39-142.el10_2.src.rpm` is rebuilt, unmodified, with
**`rpmbuild --rebuild`** in a stage0 buildroot ([stage0.md](stage0.md)). All
plain derivations, no IFD: the subpackage list comes from the lock.

Code: `packages/glibc.nix` (buildroot, build, trees, sanity),
`packages/glibc-sanity.sh` (post-build checks), `bootstrap/glibc-build-deps.nix`
(build inputs missing from the stage0 root), `bootstrap/texinfo.nix` (makeinfo
7.1), `tools/parity/glibc.json` (parity allowlist), `bootstrap/default.nix`
(`mkRoot`, `fullRpms`, `glibcBuildDeps`).

## Attributes

| attr | what |
|---|---|
| `legacyPackages.x86_64-linux.srpm.glibc` = `packages.x86_64-linux.glibc-rpms` | the rpmbuild result: `RPMS/{x86_64,noarch}/*.rpm` (233), `SRPMS/`; output `logs`: `build.log`, `srpm.log`, `files`, `purity.json` (the build-time purity scan) |
| `legacyPackages.x86_64-linux.rpms.<name>` | payload tree (`rpmTree`, `allowedReferences = [ ]`) of every glibc subpackage: the 221 Rocky ships (`rpmsLock.bySrpm.glibc`) + `glibc32`, `sysroot-x86_64-el10-glibc`, `compat-libpthread-nonshared` |
| `packages.x86_64-linux.glibc` | `rpms.glibc` (tree of the main `glibc` RPM) |
| `packages.x86_64-linux.glibc-rpms` | = `srpm.glibc` |
| `checks.x86_64-linux.glibc-purity` = `legacyPackages.….packageSets.glibc.trees` | linkFarm of all 224 trees (each depends on `srpm.glibc`, whose build ran the byte-level purity scan; see "Purity") |
| `checks.x86_64-linux.glibc-parity` (`.report`) | `tools/rpm-parity.py` vs all 221 official RPMs (see "Parity with the official RPMs") |
| `checks.x86_64-linux.glibc-abi` = `….packageSets.glibc.abi` | binutils-based ABI comparison of all 221 shipped subpackages with the official ones (see "ABI check") |
| `checks.x86_64-linux.glibc-runtime` = `….packageSets.glibc.runtime` | our glibc in a root made only of RPMs, no `/nix/store`, same behaviour as the official glibc (see "Runtime check") |
| `checks.x86_64-linux.glibc-sanity` = `….packageSets.glibc.sanity` | post-build checks, `report.txt` (below) |
| `legacyPackages.….packageSets.glibc.{buildroot,root,subpackages,expected}` | the buildroot (layers), its root layer, the subpackage names, the expected NEVRA list |

Debuginfo/debugsource RPMs (9) are in `srpm.glibc/RPMS` but get no `rpms.*`
tree (Rocky ships them in separate debug repos).

The glibc buildroot uses Rocky's kernel-headers RPM, rebuilt from the kernel
SRPM (`stage0.kernelHeadersBuild`, [kernel-headers.md](kernel-headers.md));
`import ./default.nix { bootPkgs; kernelHeadersRpm = <rpm spec>; }` swaps in
another one (see "Kernel headers").

## How it is built

```
buildSrpm {
  srpm = "glibc"; buildroot = <glibc buildroot>;
  rpmbuildArgs = [ "--nocheck" ];
  defines = { _annotated_build = "0"; _annobin_gcc_plugin = "%{nil}"; };
  requiredSystemFeatures = [ "big-parallel" ];
}
```

plus what `buildSrpm` always passes: `--target x86_64`, `--nodeps` (stage0),
`%_topdir /builddir/build`, `%dist .el10_2` (from the lock release),
`%_buildhost el-nixos.localdomain`, `%_smp_build_ncpus $NIX_BUILD_CORES`,
`%source_date_epoch_from_changelog 1`, `%use_source_date_epoch_as_buildtime 1`,
`%clamp_mtime_to_source_date_epoch 1`; rpmbuild runs as `mockbuild` in the
chroot with mock's environment (`PATH=/usr/bin:/bin:/usr/sbin:/sbin` — FHS only,
so configure records `/usr/bin/bash`, `/usr/bin/perl`).

* **Every bcond at its default**: testsuite, benchtests, werror, docs, valgrind
  on; bootstrap off. `--nocheck` only skips `%check` (hours long; it does not
  change the binary RPMs). **`-Werror` passed** with the stage0 gcc 14.3.1 +
  binutils 2.41 (the same versions Rocky used) — no `--without werror`.
* **Annobin**: there is no annobin plugin for the stage0 gcc yet. The spec has
  its own test `%if 0%{?_annotated_build} > 0` that adds
  `-fplugin=annobin` to `BuildFlagsNonshared` (libc_nonshared.a), so emptying
  `%_annobin_gcc_plugin` (macros.stage0) alone is **not** enough;
  `_annotated_build 0` turns that off while keeping the macro *defined*, so
  redhat-rpm-config still passes `--remove-section .gnu.build.attributes` to
  find-debuginfo exactly as in Rocky's build. Verified by `sanity`: no
  `-fplugin=annobin`/`redhat-annobin-cc1` in any compile command.
  `ASFLAGS=-Wa,--generate-missing-build-notes=yes` (unconditional in the spec)
  still produces `.gnu.build.attributes`.
* **x86-64-v3**: the spec runs v3 binaries in `%install` (static `ldconfig`,
  `localedef` through the new `ld.so`). The builder's
  `ld.so --help` lists `x86-64-v3 (supported, searched)`; the build log's
  `cat /proc/cpuinfo` shows an Intel i9-9900K (avx2, bmi1/2, fma, movbe).
* **CPUs / time**: the builds ran on a 16-CPU builder (`NIX_BUILD_CORES=16`,
  `make -O -j16`; a `big-parallel` probe got the same 16 CPUs as a normal one
  on this setup — on nixbuild.net `big-parallel` may get bigger machines).
  Whole `rpmbuild --rebuild` (prep, i686 + x86_64 glibc, 497 locales,
  locale-archive, benchtests, docs, find-debuginfo, 233 RPMs at zstd -19,
  `rpmbuild -rs`): **≈ 9–10 min wall**. %prep (675 patches) ≈ 1 min, %build
  ≈ 3 min, %install + packaging ≈ 6 min. Output 196 MB.

## Buildroot contents and provenance

`buildroot` = `mkBuildroot { base = mkRoot { … }; rpms = fullRpms ++ [kernel-headers RPM?]; }`:

1. **Root layer** `stage0-root-glibc` (`stage0.mkRoot`): the same root as
   stage0's `buildroot` — stage0 toolchain as real files (binutils 2.41-63,
   gcc 14.3.1-4.4 multilib, stage0 glibc 2.39 x86_64+i686, all built from
   Rocky's tarballs), Rocky's rpm 4.19.1.1 + debugedit 5.1 (FHS paths), the
   nixpkgs buildsys tools as `/usr/bin` symlinks, `/etc`, empty rpmdb — plus:
   * kernel headers: none — Rocky's kernel-headers RPM is installed in 2.
     (`packages/glibc.nix` still supports `kernelHeadersRpm = null`, which
     copies stage0's nixpkgs 6.18 headers instead);
   * `texinfo71` (`bootstrap/texinfo.nix`): makeinfo **7.1** built from
     Rocky's texinfo SRPM (tarball + all 5 spec patches, `--disable-perl-xs`)
     with nixpkgs' recipe, as `/usr/bin/{makeinfo,texi2any,…}` symlinks that
     win over nixpkgs' texinfo 7.2 (whose output differs: banner, index sort
     order, sentence spacing — every `libc.info*` page differed);
   * `glibcBuildDeps` (`bootstrap/glibc-build-deps.nix`), copied in as real
     files (headers in `/usr/include`, `.so*` in `/usr/lib64`).
   Rebuilding this root costs seconds; the toolchain is untouched.
2. **Layer** `buildroot-stage0-glibc`: `rocky-release` + the pass-B macro
   packages (`fullRpms`, i.e. exactly what stage0-full installs) and
   Rocky's `kernel-headers-6.12.0-211.66.1.el10_2`, installed with
   `rpm --root` (registered in the rpmdb).

What the spec needs, and where it comes from:

| need (why) | provider in the buildroot | provenance |
|---|---|---|
| gcc (multilib, `-m32` build), binutils | stage0 gcc 14.3.1-4.4, binutils 2.41-63 | built from Rocky tarballs (stage0) |
| make, gawk, bison, sed, python3 (configure-critical; `%prep` parse-SUPPORTED.py) | `/usr/bin/{make,gawk,bison,sed,python3}` | nixpkgs (4.4.1, 5.4.1, 3.8.2, 4.10, 3.13) |
| gettext `msgfmt` (libc.mo), perl (mtrace, manual) | `/usr/bin/{msgfmt,perl}` | nixpkgs (1.0, 5.42) |
| texinfo `makeinfo` (glibc-doc's `libc.info*`) | `/usr/bin/makeinfo` | **Rocky texinfo-7.1-6.el10 sources**, built with nixpkgs' recipe (`stage0.texinfo71`) |
| diffutils (`diff` in %prep/%install), util-linux `hardlink -c`, procps, coreutils `df`/`truncate`, findutils, grep, gzip, xz, zstd, cpio, patch, tar | `/usr/bin/*` | nixpkgs |
| debuginfo: find-debuginfo/debugedit, dwz, eu-strip/eu-elfclassify, gdb-add-index, objcopy/strip/nm | debugedit 5.1 (Rocky SRPM, stage0), dwz 0.16, elfutils 0.194, gdb 17.2, binutils (stage0) | stage0 / nixpkgs |
| `/proc` mounted, working `df` | chroot runner (`--proc /proc`) | — |
| redhat-rpm-config 295 + srpm-macros, rocky-release (`%rhel 10`, `%valgrind_arches`, …) | RPMs | **built from Rocky SRPMs** (stage0 pass B) |
| `sys/sdt.h`, `sys/sdt-config.h` (`--enable-systemtap` is a hard requirement) | `/usr/include/sys/` | **Rocky systemtap-5.4 SRPM source**: `sdt.h` taken from the tarball (the spec applies no patches), `sdt-config.h` generated from its `.in` with the two assembler capabilities = 1 — both byte-identical to the official `systemtap-sdt-devel-5.4-3.el10` headers (checked). Building the systemtap SRPM itself needs dyninst, boost, libvirt, avahi, java, … |
| gd + libpng + zlib (memusagestat, `LIBGD`) | `/usr/include/{gd*.h,png*.h,libpng16/,zlib.h,zconf.h}`, `/usr/lib64/lib{gd,png16,png,z}.so*` | **nixpkgs** gd 2.3.3, libpng(-apng) 1.6.58, zlib 1.3.2 |
| libselinux (makedb, `have-selinux`) | `/usr/include/selinux/`, `/usr/lib64/libselinux.so*` | **nixpkgs** libselinux 3.10 (= Rocky's version) |
| audit-libs, libcap (configure probes only: nscd/pt_chown, neither built) | `libaudit.h`…, `sys/capability.h`, `/usr/lib64/lib{audit,auparse,auplugin,cap,psx}.so*` | **nixpkgs** audit 4.2.1, libcap 2.77 |
| kernel headers (`--with-headers=/usr/include`; `rpm -ql kernel-headers` for the sysroot package) | `/usr/include/{linux,asm,asm-generic,…}` | **Rocky kernel-headers-6.12.0-211.66.1.el10_2, rebuilt from the kernel SRPM** (`stage0.kernelHeadersBuild`), installed with rpm |
| not needed with `--nocheck`: gcc-c++/libstdc++-static/glibc-static (configure C++ probes gate tests only), libidn2, valgrind, python3-devel | (g++ and libstdc++ are there anyway) | — |

**Why nixpkgs for the -devel libraries, not their Rocky SRPMs**: none of
their code ends up in a shipped glibc file — `memusagestat` and `makedb` link
them by soname only (`NEEDED libgd.so.3 libpng16.so.16 libz.so.1`,
`libselinux.so.1`), and only `gd.h`/`selinux/selinux.h` are compiled in (the
nixpkgs gd.h differs from Rocky's gd-devel-2.3.3-22 only by a comment; the
official one additionally ships `gd_io_stream.h`, unused). Their Rocky SRPMs
are not cheap in stage0: zlib-ng needs cmake + its rpm macros + GTest +
libabigail; libselinux needs swig, ruby-devel and python3-devel/pip/setuptools/
wheel (bindings are unconditional) on top of libsepol and pcre2; libcap needs
golang; audit needs krb5/openldap/libcap-ng/swig/python3-devel; gd needs the
whole X11/fontconfig/freetype/jpeg/tiff/webp stack. They will be real Rocky
builds in stage1. The nixpkgs `.so` files keep RUNPATHs into `/nix/store`
(visible in stage0 chroots) so ld can resolve their dependencies; glibc links
programs without `-rpath`, so nothing of that reaches the output (checked:
no RPATH/RUNPATH but `$ORIGIN` on gconv modules, no store string anywhere).

**Symbol versions**: those libraries are linked against the stage0 glibc 2.39
here, so `glibc-build-deps.nix` **fails the build** if any library in their
runtime closure (115 DSOs incl. gd's X11/fontconfig/… closure, nixpkgs glibc
excluded) references a `GLIBC_2.40`+ symbol version. Current maximum:
`GLIBC_2.38` (list in `$out/nix-support/glibc-versions.txt`). This re-runs
automatically whenever the nixpkgs pin moves.

### Kernel headers

`default.nix` passes `kernelHeadersRpm = { from = stage0.kernelHeadersBuild;
names = [ "kernel-headers" ]; }`: Rocky's `kernel-headers-6.12.0-211.66.1.el10_2`,
rebuilt from the kernel SRPM ([kernel-headers.md](kernel-headers.md);
`checks.kernel-headers-parity`: all 1015 common files byte-identical to the
official RPM, 21 leaked tools headers absent by design). The root layer then
gets **no** kernel headers and the RPM is installed by rpm into the buildroot
(registered in the rpmdb), so glibc builds against exactly Rocky's UAPI
headers and the spec's `rpm -ql kernel-headers | … install -D` (spec:1822)
fills `sysroot-x86_64-el10-glibc` (`glibc-sanity`: all 1015 `.h` files
present; the package grew from 562 to 1626 files).

`kernelHeadersRpm` (argument of `default.nix` → `packages/glibc.nix`) is any
`mkBuildroot` rpm spec (a `.rpm` path, a `buildSrpm` result, or
`{ from; names; }`). `packages/glibc.nix` with `kernelHeadersRpm = null`
falls back to stage0's nixpkgs 6.18 headers copied into the root (not in the
rpmdb; the sysroot package then has no kernel headers).

## Deviations from Rocky's build (all of them)

| deviation | effect on the output |
|---|---|
| `--nocheck` | none on the RPMs (`%check` only tests) |
| `--nodeps` (stage0: nixpkgs tools are not in the rpmdb) | none; the rebuilt `.src.rpm` keeps the official BuildRequires |
| annobin off (`_annotated_build 0`, `_annobin_gcc_plugin %{nil}`) | no `.annobin.notes` section (libc.so.6: 0x1eade bytes, ld.so: 0x315d), shorter `.shstrtab`, fewer `.debug_str` bytes in ld.so (its DWARF producer strings lack `-fplugin=gcc-annobin`) |
| build tools from nixpkgs (python 3.13, gettext 1.0, gawk 5.4, perl 5.42, …) instead of Rocky's | none visible: the parity check finds every non-ELF file byte-identical (incl. the `.mo` catalogs and, with makeinfo 7.1, the info pages) |
| makeinfo: Rocky's texinfo 7.1 sources built with nixpkgs' recipe and perl 5.42, `Unicode::Collate` hidden from it (Rocky's buildroot has no perl-Unicode-Collate, so its texi2any sorts indices by code point) | none: the 21 `libc.info*` pages are byte-identical (with nixpkgs' 7.2 all differed; with 7.1 + Unicode::Collate, the index order in 3 of them) |
| rpm's libzstd and libmagic: Rocky's zstd-1.5.5-9.el10 / file-5.45-9.el10 *sources* built in stage0 (`bootstrap/rpm-libs.nix`) instead of Rocky's binaries | none any more: with nixpkgs' zstd 1.5.7 / file 5.47 (until this was fixed) 209 payloads differed only in their compressed bytes and the FILECLASS strings differed (gzip "original size" suffix, ld.so "dynamically linked"); now 211 of 221 RPM payloads are byte-identical to Rocky's, compressed, and no FILECLASS differs |
| -devel libraries from nixpkgs (above) | `memusagestat` (glibc-utils) links nixpkgs' `libgd.so.3`, whose `gdFontLarge`/`gdFontSmall` are 32-byte aligned (Rocky's gd-2.3.3-22.el10: 8-byte). ld places copy-relocated objects by the defining DSO's alignment, so memusagestat's `.bss` is 0x78/align 32 instead of 0x50/align 16, its 3 copy-relocated symbols move (`.dynsym` values, `.rela.dyn`, RIP-relative displacements in `.text`) and `.dynstr` follows libgd's symbol order. The machine code is identical (displacement-normalized `objdump -d`), and so are the dynamic symbols, versions and NEEDED. (Earlier versions of this document blamed the system headers; a relink test against both libgd builds shows it is the library.) Allowed by exact section ids in `glibc.json`; see "Known differences / open issues" |
| ~~kernel headers 6.18 (nixpkgs)~~ — fixed: Rocky's 6.12.0-211 RPM | (the sysroot package now carries them) |
| buildhost `el-nixos.localdomain`, BUILDTIME = changelog date (1789344000), no vendor/packager | RPM headers only |
| rpm runs `--nodeps --noscripts` installs into the buildroot | none |
| SIGPIPE: reset to default in the chroot (the Nix sandbox ignores it) | none (matches mock); before the fix, `manual/check-safety.sh` printed two harmless "grep: write error: Broken pipe" |

## Results

Build (16 CPUs, i9-9900K, `make -O -j16`): `rpmbuild --rebuild` succeeds,
≈ 10 min. It was built five times during integration (glibc track; + Rocky
kernel-headers; + makeinfo 7.1; + Unicode::Collate hidden; + Rocky-sourced
libzstd/libmagic in rpm, purity scan, logs output), every time on the first
attempt. Output store path: see "Store paths".

`checks.glibc-sanity` (`report.txt`), all hard checks pass:

* **RPM set**: 233 binary RPMs = the **221 shipped** (220 x86_64 + glibc-doc
  noarch) + `glibc32`, `sysroot-x86_64-el10-glibc` (noarch),
  `compat-libpthread-nonshared` + 9 debug packages (`glibc-debuginfo`,
  `glibc-debugsource`, `glibc-{common,utils,gconv-extra,benchtests}-debuginfo`,
  `libnsl-`, `nss_db-`, `nss_hesiod-debuginfo`). **Every NEVRA equals the
  official one** (`2.39-142.el10_2`, epoch 0, same arch). Payload zstd/19.
* **configure** (x86_64 build, from build.log): `LIBGD yes`, `have-selinux
  yes`, `have-libaudit yes`, `have-libcap yes`, `_FORTIFY_SOURCE` level **3**
  (both builds), systemtap probes yes, `BASH_SHELL /usr/bin/bash`,
  `PERL /usr/bin/perl`, no tool found in `/nix/store`. (The i686 build has
  libgd/selinux `no`, as on Rocky: there are no 32-bit gd/selinux libraries.)
* **payloads**: memusagestat NEEDED exactly `libc.so.6 libgd.so.3 libm.so.6
  libpng16.so.16 libz.so.1`; makedb NEEDED `libselinux.so.1` with
  `LIBSELINUX_1.0`; `#!/usr/bin/bash` in ldd/sotruss/xtrace/memusage/tzselect,
  `#!/usr/bin/sh` in mtrace; libc.so.6: **79 stapsdt probes, identical to the
  official list**, `x86 feature: IBT, SHSTK`, `ISA needed: x86-64-baseline,
  v2, v3`, `.comment` `GCC: (GNU) 14.3.1 20251022 (Red Hat 14.3.1-4)` (Rocky's
  string); all 745 ELF files have a build-id, every program has PT_INTERP
  `/lib64/ld-linux-x86-64.so.2`, no RPATH/RUNPATH except the official
  `RPATH $ORIGIN` of 14 gconv modules.
  ld.so keeps its full DWARF + `.symtab`, libc.so.6 its `.symtab` and
  `.gnu.build.attributes` (wrap-find-debuginfo.sh works).
* **/nix/store**: no occurrence in any non-debug payload, **and none in the
  debuginfo/debugsource payloads either** (the stage0 toolchain has FHS paths;
  debugedit rewrites the build dir).
* **vs official** (15 main subpackages, informational): file lists, Requires
  and Provides **identical** for glibc, glibc-common, glibc-devel, glibc-doc,
  glibc-utils, glibc-static, glibc-gconv-extra, glibc-minimal-langpack,
  glibc-langpack-en, glibc-locale-source, glibc-nss-devel, glibc-benchtests,
  nss_db, nss_hesiod, libnsl (ignoring `/usr/lib/.build-id/xx` entries, whose
  names depend on the build-id hashes).

### Purity

`srpm.glibc`'s build ends with `tools/rpm_purity.py` over all 233 binary
RPMs (`logs/purity.json`): a byte-level search for `/nix/store` in every
header, payload file and symlink target, including inside the 254 gzip'ed
members, the xz `.gnu_debugdata` of 707 ELF files and any compressed ELF
section — **no hit**, so the build succeeds; a hit would fail it, and with
it everything built from it (`rpms.*`, the checks). `checks.glibc-parity`
runs the same scan. `checks.glibc-purity` builds all 224 `rpmTree`s
(221 shipped + 3 unshipped); their `allowedReferences = [ ]` adds little on
top: Nix only scans for hashes of a derivation's input closure (rpm, cpio,
stdenv), not for the nixpkgs perl/python/… the stage0 chroot exposes, and
not inside compressed files.

### Parity with the official RPMs

`checks.glibc-parity` (`tools/rpm-parity.py`, [parity.md](parity.md)) compares
our 233 RPMs with **all 221** official RPMs of `rpmsLock.bySrpm.glibc`
(langpacks included) and **passes**:

```
Compared 221 package pair(s); 0 unexpected difference(s), 5117 allowed;
0 purity violation(s); 0 integrity error(s).
```

(The allowed count grew from 2531 because archives are now compared member
by member: 2790 of the 5117 are the per-member annobin sections below.)

* 221/221 pairs: NEVR, every header tag except the allowed ones below,
  changelog, all dependency kinds (Requires/Provides/… with scriptlet
  qualifiers), scriptlets and triggers, file lists and per-file mode, owner,
  group, flags, verify flags, link targets, caps, color, lang, nlink — **all
  equal**. `OPTFLAGS` is equal once the annobin `-specs=` token is removed from
  the official value.
* 9925 common paths; 7724 common regular files, of which **7001 are
  byte-identical** (header digest) — every non-ELF file (locales,
  `locale-archive` sources, gconv data, headers, scripts, `.mo` catalogs, the
  21 `libc.info*` pages, man pages) — and the other 723 are 716 ELF objects
  and 7 static archives. For each of those the ELF facts are compared: type,
  INTERP, NEEDED, SONAME, RPATH/RUNPATH, hash styles, BIND_NOW, PIE, TEXTREL,
  RELR, execstack, RELRO, build-id presence, GNU properties (IBT/SHSTK, ISA
  level), ABI tag, stapsdt probe count, package note, `.comment`, section
  list, **every dynamic symbol with its version, binding, type, visibility
  and size, the version definitions and needs, the sha256 of every loaded
  (`SHF_ALLOC`) section and the program headers**; the 7 archives
  (libc.a's 2214 members, libm, libmvec, libresolv, libc_nonshared, …)
  member by member: member order, armap, each member's loaded section bytes,
  non-local symbols and relocations. **All equal**, except the missing
  annobin sections and memusagestat's copy-relocation layout (below): the
  generated code and data of 715 of the 716 differing ELF files and of
  every archive member are byte-identical to Rocky's.
* 6458 payload digests per side recomputed and verified; no `/nix/store` in
  any of our headers or payloads (debuginfo/debugsource included).

Every remaining difference (all allowed, with the reason in the allowlist):

| difference | count | file | why |
|---|---|---|---|
| `header.BUILDHOST`, `BUILDTIME`, `COOKIE` | 221 each | default.json | our build host / changelog-date buildtime; `rpmbuild --rebuild` copies the SRPM's cookie (Rocky's build host) into the binaries |
| `header.VENDOR`, `PACKAGER`, `DISTRIBUTION`, `BUGURL` | 221 each | default.json | set by Rocky's build system; unset by us (we do not claim Rocky's identity) |
| `header.PAYLOADDIGESTALT` / `PAYLOADDIGEST`, `SIZE` | 10 / 10, 6 | default.json | the uncompressed payload differs in exactly the 10 packages that contain ELF objects (and only there: the other 211 payloads are byte-identical, compressed or not); `SIZE` = the 6 with size-changing ELF differences, mostly the missing `.annobin.notes` (glibc.x86_64: libc.so.6 lacks 0x1eade bytes of them) |
| `content.elf:*` | 716 | default.json | ELF files differ in build-id, `.gnu_debuglink` CRC and debug-related bytes; everything loaded or linked is compared (above) and equal |
| `content.ar:*` | 7 | default.json | static archives differ in member headers (ar dates/uid) and in their members' annobin/debug sections; members compared one by one (above) |
| `elf.section:…:-.annobin.notes` | 9 + 2772 | stage0.json | no annobin plugin in stage0. Top level: 7 glibc-devel objects (`crt1.o`, `Scrt1.o`, `Mcrt1.o`, `gcrt1.o`, `grcrt1.o`, `rcrt1.o`, `libmcheck.a`) and, in glibc, `libc.so.6` and `ld-linux-x86-64.so.2`; plus 2772 archive members: `libc.a` 1880, `libm-2.39.a` 709, `libmvec.a` 162, `libresolv.a` 19, `libg.a` 1, `libBrokenLocale.a` 1 |
| `elf.section:…:-.gnu.build.attributes` / `-.rela.gnu.build.attributes` | 9 / 9 | stage0.json | the 9 `libc_nonshared.a` members: glibc.spec compiles them with `-fplugin=annobin` (`BuildFlagsNonshared`), whose notes carry relocations |
| `elf.alloc:/usr/bin/memusagestat:{.bss,.dynstr,.dynsym,.rela.dyn,.text}`, `elf.segments:/usr/bin/memusagestat` | 5 + 1 | glibc.json | copy relocations laid out after nixpkgs' libgd (deviations table; "Known differences / open issues") |
| `header.OPTFLAGS` (rewrite) | 221 | stage0.json | official has `-specs=/usr/lib/rpm/redhat/redhat-annobin-cc1` |
| `package.only-ours:` glibc32, sysroot-x86_64-el10-glibc, compat-libpthread-nonshared | 3 | glibc.json | built by the spec, not published by Rocky |
| `package.only-ours:*-debuginfo/-debugsource` | 9 | default.json | the lock has no debug repos |
| `file.only-*:/usr/lib/.build-id/<id>[.2] -> …/getconf/{POSIX_V7,XBS5}_LP64_OFF64` | 2+2 | glibc.json | hard-linked getconf binaries share one build-id; which link gets `.2` follows readdir order of the build filesystem |

Not loaded, so not compared beyond the purity scan: debug information. ld.so
keeps its DWARF, whose `.debug_str` lacks the `-fplugin=gcc-annobin`
producer strings; the debuginfo packages have no official counterpart in
the lock.

### ABI check (`checks.glibc-abi`)

An independent answer to "is the ABI Rocky's?", with GNU binutils instead of
rpm-parity's own ELF reader (`tools/abi-compare.py`), for all 221 shipped
subpackages (our `rpms.*` trees vs the extracted official payloads), with
**no allowlist**:

```
abi-compare: PASS
packages 221; ELF DSOs/executables 709 (20428 dynamic symbols); relocatable objects 9;
static archives 12 (3541 members); external symbols of objects/archives 19590; headers 480
differences: 0 unexpected, 0 allowed; 0 unused allowlist rule(s)
```

Compared: `readelf --dyn-syms` (name@version, type, binding, visibility,
defined/undefined, size; addresses left out), `readelf -V` (all 46
`GLIBC_*` version definitions of libc.so.6, the needed versions, the version
index table), the dynamic tags that matter (NEEDED, SONAME, RPATH/RUNPATH,
FLAGS, FLAGS_1, VERDEFNUM/VERNEEDNUM), `ar t` member order and `nm -g` of
every archive member and crt object, and every file under `/usr/include`
byte for byte. (memusagestat passes here: its symbols are the same, only
their addresses moved.) `abi-compare-selftest` proves the check fires on a
symbol removed from an existing version node.

### Runtime check (`checks.glibc-runtime`)

`packages/glibc-runtime/`: two roots made **only of RPMs** — no nixpkgs, no
busybox; `/nix` does not exist inside — that differ only in the C library:
our 12 glibc subpackages + our kernel-headers, or the 13 official Rocky RPMs
of the same names, each on the same 34 official non-glibc Rocky RPMs
(filesystem, setup, basesystem, bash, coreutils-single, grep, sed, gzip,
diffutils, tzdata, libgcc, libxcrypt(-devel,-static), ncurses-libs, … and
their closure). They are installed with `rpm --root` **with scriptlets**
(chrooted: glibc's Lua `%post` runs our `ldconfig`/`iconvconfig`), plus a
32-bit root (our `glibc32`) and all-langpacks roots. All sessions run in one
derivation, i.e. on the same machine. The ~1550-line behaviour report must
be identical between the two roots (apart from the CPU's APIC id and inode
numbers): ld.so `--version/--help/--list-tunables/--list-diagnostics/--verify`,
running libc.so.6, ldd, ldconfig `-p`/`-v`, locale/localedef/date in several
locales, iconv `-l` and conversions to 20 charsets (incl. gconv-extra ones),
a regenerated `gconv-modules.cache` byte-identical to the shipped one, NSS
(`getent passwd/group/hosts/ahosts/services/protocols/rpc/shadow/initgroups`,
nss_db via makedb), `getconf -a`, zdump, gencat, sotruss, sprof, makedb,
pldd, and programs **compiled against each root's glibc-devel/-static** with
the stage0 gcc (dynamic, dlopen/dlsym/dladdr, 8 threads + TLS + mutex +
`pthread_cancel`, NSS, libm in `%a`, libcrypt, `-static` with threads/iconv/
libm, `-static` NSS, `-static-pie`), each run in both roots. All 885 locales
of glibc-all-langpacks (`locale -k LC_ALL` + `date`) must be identical too.
Result: `glibc-runtime: PASS -- 1543 report lines and 885 locales identical
to the official RPMs`. The `/var/spool/mail` directory of filesystem is
excluded from the install (see "Known differences / open issues").

## Store paths

Final integrated build (nixpkgs `26f4107`, 2026-10-18, local 16-CPU builder):

| attr | store path |
|---|---|
| `stage0.glibcBuildDeps` | `/nix/store/451v3lamp2vym2nv90amdl652k3rm405-stage0-glibc-build-deps` |
| `stage0.texinfo71` | `/nix/store/ah7vb063q9pb6l81hv25lp2q7zal4pl1-stage0-texinfo-tree-7.1-6.el10` |
| `stage0.rpmLibs.zstd` / `.file` | `/nix/store/by3bqx64rrlgvladgqc2j2sdjf9mppcr-stage0-zstd-1.5.5-9.el10`, `/nix/store/2nkmigshbk6syl9666cnzlz70h6pclys-stage0-file-5.45-9.el10` |
| `stage0.rpm` | `/nix/store/nfn9dhdh74372w9hfls1dhwqwqsj0dja-stage0-rpm-4.19.1.1-23.el10` |
| `stage0.kernelHeadersBuild` | `/nix/store/n5zcq2rqi5fyy7d3nlzmwk4zsqrp0q0s-srpm-kernel-headers-6.12.0-211.66.1.el10_2` |
| `srpm.glibc` = `packages.glibc-rpms` (171 MB, 233 RPMs + SRPM) | `/nix/store/10hfxa7fk6p5x3vd8jrkp6zz8mlb9sny-srpm-glibc-2.39-142.el10_2` |
| `srpm.glibc.logs` | `/nix/store/s4j1adpiwr5yqwp96n43nqkji2rbl71s-srpm-glibc-2.39-142.el10_2-logs` |
| `rpms.glibc` = `packages.glibc` | `/nix/store/p8wvx276pzqz026bzwv3w1scvnqvh6gb-rpm-glibc` |
| `checks.glibc-purity` | `/nix/store/k4i6rmsaxzlf6ziwb018rsdq2jvqrkhb-glibc-2.39-142.el10_2-rpm-trees` |
| `checks.glibc-sanity` | `/nix/store/vpyn6kj72a11k1cnq01a4j7glla80ili-glibc-sanity-2.39-142.el10_2` |
| `checks.glibc-parity` | `/nix/store/mpy964h3c27dkc4qxj8ll5ilkvlrrklv-parity-glibc` |
| `checks.glibc-abi` | `/nix/store/n1jwadx204b6ar2nl3khxrcbj2zbg2zk-glibc-abi-2.39-142.el10_2` |
| `checks.glibc-runtime` | `/nix/store/aagqb6is8a1i1n2cfrc6r6rhr5jz0qwm-glibc-runtime-2.39-142.el10_2` |

(Earlier builds: before the stage0 rpm got Rocky's libzstd/libmagic and the
build-time purity scan, `…bp4q5wy3…-srpm-glibc-…` (parity
`…146zcywj…`); before integration `…kilh3yyh…`. None of these changes
touches compiled code: the parity tool finds the same loaded bytes.)

## Known differences / open issues

Everything that still differs from Rocky's build, or is known not to work
yet, with its cause; none of it is papered over (each allowlist rule names
exact ids and the reason):

1. **memusagestat copy-relocation layout** (glibc-utils; `glibc.json`, 5
   section ids + segments). Cause: it links nixpkgs' gd 2.3.3 `libgd.so.3`
   (`bootstrap/glibc-build-deps.nix`), whose font objects are 32-byte
   aligned; ld copies them into `.bss` with that alignment. Code, symbols,
   versions and NEEDED are identical; no runtime/ABI effect (the copy slots
   are 8-byte pointers). Fix: link against Rocky's libgd — which needs the gd
   SRPM and its X11/fontconfig/freetype/jpeg/tiff/webp stack (stage1), or
   Rocky's binary gd/gd-devel plus their library closure in the stage0
   buildroot (policy decision: binaries we did not build).
2. **No annobin** in stage0 (`stage0.json`): no `.annobin.notes`
   (libc.so.6, ld.so, crt objects, 2772 archive members), no plugin
   `.gnu.build.attributes` notes (and relocations) in the 9 libc_nonshared.a
   members, OPTFLAGS
   without the annobin `-specs`, ld.so's `.debug_str` without the plugin's
   producer strings. Fix: build Rocky's annobin SRPM for the stage0 gcc.
3. **Not bit-reproducible on rebuild: static archive member dates.** With
   `nix build --rebuild`, every RPM is bit-identical except the 4 that ship
   `.a` files (glibc-static, glibc-devel, glibc32,
   sysroot-x86_64-el10-glibc): GNU ar stores the wall-clock time in every
   member header (`ar cruv`; binutils configured like Rocky's,
   `--enable-deterministic-archives=no`; ar ignores `SOURCE_DATE_EPOCH`).
   Rocky's archives have wall-clock dates too, and parity ignores member
   headers. Measured: `nix build --rebuild --keep-failed` of `srpm.glibc`,
   then `cmp` of the kept build directory's RPMs with `$out`: 230 of 234
   files (233 RPMs + SRPM) identical, exactly these 4 differ. Logs are a
   separate output (`logs`) and never reproducible, so Nix's `--rebuild`
   always reports "may not be deterministic" (and stops at `logs`, before
   comparing `out`). Fix, if bit-reproducibility is wanted: rewrite the
   member headers to `SOURCE_DATE_EPOCH` after the build (a step Rocky's
   build does not have) or a deterministic `ar` (a toolchain deviation).
4. **Non-root file owners cannot be applied in buildroot layers** (one uid
   per user namespace): rpm aborts on filesystem's `root:mail
   /var/spool/mail` ("cpio: chown failed - Device or resource busy").
   `checks.glibc-runtime` installs filesystem with
   `--excludepath=/var/spool/mail`. Store layers cannot represent owners or
   modes such as setup's `0000` `/etc/shadow` either (the layer machinery now
   copies such files out; the rpmdb still records the intended owner/mode).
   Needed for stage1 roots, see [stage0.md](stage0.md) "Known gaps".
5. **Build tools from nixpkgs** (python, perl, gawk, gettext, bison, make,
   …) and the gd/libpng/zlib/libselinux/audit/libcap -devel libraries still
   come from nixpkgs in the stage0 buildroot. Their effect on the output is
   checked, not assumed: every non-ELF file is byte-identical to Rocky's, and
   every loaded section of every ELF file except memusagestat (item 1).
6. Outside glibc, found by the stronger parity comparison: the stage0
   validation package **`which`** has different machine code in `main()`
   (same section sizes; `which.json`). Not the C library (rebuilt against
   our glibc-devel: same bytes); which is built with LTO, glibc is not;
   prime suspect is the missing annobin plugin's effect on Rocky's LTO IR
   (item 2). Not proven.

## Next steps

* Annobin plugin for the stage0 gcc (Rocky annobin SRPM) → drop the two
  defines; then `.annobin.notes`, the archive members and the producer
  strings match too, the annobin rules leave `stage0.json`, and `which`'s
  LTO code can be re-checked.
* stage1: rebuild glibc in a buildroot of Rocky RPMs only (this glibc +
  gcc/binutils/… and the real gd/libselinux/zlib-ng/… SRPMs), no `/nix/store`;
  memusagestat's layout should then match (Rocky's libgd). Needs the
  owner/mode handling of item 4.
* Optional: `%check` as a separate derivation (needs a non-multicall
  `/usr/bin/true` ≤ GLIBC_2.39, valgrind, gdb, nested namespaces).
