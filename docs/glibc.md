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
| `legacyPackages.x86_64-linux.srpm.glibc` = `packages.x86_64-linux.glibc-rpms` | the rpmbuild result: `RPMS/{x86_64,noarch}/*.rpm` (233), `SRPMS/`, `logs/{build.log,srpm.log,files}` |
| `legacyPackages.x86_64-linux.rpms.<name>` | payload tree (`rpmTree`, `allowedReferences = [ ]`) of every glibc subpackage: the 221 Rocky ships (`rpmsLock.bySrpm.glibc`) + `glibc32`, `sysroot-x86_64-el10-glibc`, `compat-libpthread-nonshared` |
| `packages.x86_64-linux.glibc` | `rpms.glibc` (tree of the main `glibc` RPM) |
| `packages.x86_64-linux.glibc-rpms` | = `srpm.glibc` |
| `checks.x86_64-linux.glibc-purity` = `legacyPackages.….packageSets.glibc.trees` | linkFarm of all 224 trees: **one `nix build` = the purity check** |
| `checks.x86_64-linux.glibc-parity` (`.report`) | `tools/rpm-parity.py` vs all 221 official RPMs (see "Parity with the official RPMs") |
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
| rpmbuild links nixpkgs' libmagic 5.47 (Rocky: file 5.45) | FILECLASS header strings only: gzip descriptions gain `, original size modulo 2^32 N`; ld.so is "dynamically linked" instead of "static-pie linked" |
| -devel libraries from nixpkgs (above) | `memusagestat` `.bss` is 0x78 vs 0x50 bytes and `.gnu_debugdata` 4 bytes smaller — it is the one object glibc compiles with the *system* headers (`sysincludes = # nothing`), here the stage0 glibc's (unpatched 2.39) `/usr/include` + nixpkgs gd.h, on Rocky the previous Rocky glibc-devel |
| ~~kernel headers 6.18 (nixpkgs)~~ — fixed: Rocky's 6.12.0-211 RPM | (the sysroot package now carries them) |
| buildhost `el-nixos.localdomain`, BUILDTIME = changelog date (1789344000), no vendor/packager | RPM headers only |
| rpm runs `--nodeps --noscripts` installs into the buildroot | none |
| SIGPIPE: reset to default in the chroot (the Nix sandbox ignores it) | none (matches mock); before the fix, `manual/check-safety.sh` printed two harmless "grep: write error: Broken pipe" |

## Results

Build (16 CPUs, i9-9900K, `make -O -j16`): `rpmbuild --rebuild` succeeds,
≈ 10 min. It was built four times during integration (glibc track; + Rocky
kernel-headers; + makeinfo 7.1; + Unicode::Collate hidden), every time on the
first attempt. Output store path: see "Store paths".

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

`checks.glibc-purity`: all 224 `rpmTree`s (221 shipped + 3 unshipped) build with
`allowedReferences = [ ]` — **no shipped package references nixpkgs**.

### Parity with the official RPMs

`checks.glibc-parity` (`tools/rpm-parity.py`, [parity.md](parity.md)) compares
our 233 RPMs with **all 221** official RPMs of `rpmsLock.bySrpm.glibc`
(langpacks included) and **passes**:

```
Compared 221 package pair(s); 0 unexpected difference(s), 2531 allowed;
0 purity violation(s); 0 integrity error(s).
```

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
  list — **all equal** except the missing `.annobin.notes` sections.
* 6458 payload digests per side recomputed and verified; no `/nix/store` in
  any of our headers or payloads (debuginfo/debugsource included).

Every remaining difference (all allowed, with the reason in the allowlist):

| difference | count | file | why |
|---|---|---|---|
| `header.BUILDHOST`, `BUILDTIME`, `COOKIE` | 221 each | default.json | our build host / changelog-date buildtime; `rpmbuild --rebuild` copies the SRPM's cookie (Rocky's build host) into the binaries |
| `header.VENDOR`, `PACKAGER`, `DISTRIBUTION`, `BUGURL` | 221 each | default.json | set by Rocky's build system; unset by us (we do not claim Rocky's identity) |
| `header.PAYLOADDIGEST`/`PAYLOADDIGESTALT`, `SIZE` | 219 / 10 / 6 | default.json | follow from differing bytes (ELF, payload mtimes/compression) |
| `content.elf:*` | 716 | default.json | ELF objects differ in build-id and debug-related bytes; properties compared above, equal |
| `content.ar:*` | 7 | default.json | static archives (`libc_nonshared.a`, `libg.a`, … in glibc-devel/-static); official members carry annobin notes |
| `elf.section:…:-.annobin.notes` | 9 | stage0.json | crt objects in glibc-devel (`crt1.o`, `Scrt1.o`, `Mcrt1.o`, …): no annobin plugin in stage0 |
| `header.OPTFLAGS` (rewrite) | 221 | stage0.json | official has `-specs=/usr/lib/rpm/redhat/redhat-annobin-cc1` |
| `file.class` gzip suffix (rewrite) / ld.so "dynamically linked" vs "static-pie linked" | 254 / 1 | stage0.json | rpmbuild's libmagic is nixpkgs' 5.47, Rocky's is 5.45 (FILECLASS text only) |
| `package.only-ours:` glibc32, sysroot-x86_64-el10-glibc, compat-libpthread-nonshared | 3 | glibc.json | built by the spec, not published by Rocky |
| `package.only-ours:*-debuginfo/-debugsource` | 9 | default.json | the lock has no debug repos |
| `file.only-*:/usr/lib/.build-id/<id>[.2] -> …/getconf/{POSIX_V7,XBS5}_LP64_OFF64` | 2+2 | glibc.json | hard-linked getconf binaries share one build-id; which link gets `.2` follows readdir order of the build filesystem |

Not visible to the parity tool (it compares ELF *properties*, not section
sizes) but found with a section-size comparison by the glibc track (below):
memusagestat's `.bss` (0x78 vs 0x50) and ld.so's `.debug_str` (annobin
producer strings).

ELF-level comparison with the official RPMs (scratch script, section name +
size per file, ignoring `.annobin.notes`/`.shstrtab`/`.gnu_debugdata`/
`.gnu_debuglink`):

| package | ELF files | same section sizes | differ |
|---|---|---|---|
| glibc | 29 | 28 | ld-linux-x86-64.so.2 (`.debug_str`: annobin producer strings) |
| glibc-common | 10 | 10 | |
| glibc-utils | 4 | 3 | memusagestat (`.bss`, see deviations) |
| glibc-gconv-extra | 246 | 246 | |
| glibc-devel | 9 | 8 (2 byte-identical) | libmcheck.a (official member has `.annobin.notes`; `.debug_str` shorter) |
| glibc-benchtests | 416 | 416 | |
| nss_db / nss_hesiod / libnsl | 2 / 1 / 1 | all | |

i.e. the generated code (`.text`, `.rodata`, `.data`, … sizes) matches
Rocky's build for every compared file except memusagestat's `.bss`.
Byte-level differences remain from build-ids/`.gnu_debuglink` CRCs (debug info
differs by the annobin strings), annobin notes and archive member metadata.

## Store paths

Final integrated build (nixpkgs `26f4107`, 2026-10-18, local 16-CPU builder):

| attr | store path |
|---|---|
| `stage0.glibcBuildDeps` | `/nix/store/451v3lamp2vym2nv90amdl652k3rm405-stage0-glibc-build-deps` |
| `stage0.texinfo71` | `/nix/store/ah7vb063q9pb6l81hv25lp2q7zal4pl1-stage0-texinfo-tree-7.1-6.el10` |
| `stage0.kernelHeadersBuild` | `/nix/store/w4l78pxvf30hnkyivcd83q8vnmyzgh9i-srpm-kernel-headers-6.12.0-211.66.1.el10_2` |
| `srpm.glibc` = `packages.glibc-rpms` (197 MB, 233 RPMs + SRPM) | `/nix/store/bp4q5wy3hs6kvb11a6yg3i5vaqbyxgc4-srpm-glibc-2.39-142.el10_2` |
| `rpms.glibc` = `packages.glibc` | `/nix/store/chhmsr5ffla0jy4ljddlrclbzm9zr9bg-rpm-glibc` |
| `checks.glibc-purity` | `/nix/store/mb3ihllmh5i8qv39kj201mh8dpw700xd-glibc-2.39-142.el10_2-rpm-trees` |
| `checks.glibc-sanity` | `/nix/store/b7d0dcrppn79s3j33p693a142c600kw1-glibc-sanity-2.39-142.el10_2` |
| `checks.glibc-parity` | `/nix/store/146zcywjsfpfbg7khbickxsj63sc6fd1-parity-glibc` |

(The glibc track's build before integration — stage0 kernel headers, nixpkgs
makeinfo 7.2 — was `/nix/store/kilh3yyhyyxd2xkc42adyvsx8x007lkq-srpm-glibc-…`;
the section-size comparison above was made on an even earlier one,
`…lsb2grqb…`, before the SIGPIPE runner fix. Neither change touches compiled
code.)

## Next steps

* Annobin plugin for the stage0 gcc (Rocky annobin SRPM) → drop the two
  defines; then `.annobin.notes`, the archive members and the producer
  strings match too, and the annobin rules leave `stage0.json`.
* Build rpm against Rocky's file-5.45 libmagic (or run stage1) → the
  FILECLASS rules go away.
* stage1: rebuild glibc in a buildroot of Rocky RPMs only (this glibc +
  gcc/binutils/… and the real gd/libselinux/zlib-ng/… SRPMs), no `/nix/store`;
  memusagestat's `.bss` should then match (Rocky glibc-devel headers).
* Optional: `%check` as a separate derivation (needs a non-multicall
  `/usr/bin/true` ≤ GLIBC_2.39, valgrind, gdb, nested namespaces).
