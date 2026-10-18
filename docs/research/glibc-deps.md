# glibc 2.39-142.el10_2: build dependencies in stage0, and official baselines

Status: research notes (no repo code changed). Target: `glibc-2.39-142.el10_2.src.rpm`
(sha256 `68c89e62…ceb96`), Rocky Linux 10.2, x86_64. nixpkgs pin:
`26f4107e47e3ad0ffd0db220469ba83b6f6d96e8` (nixos-26.05, from `flake.lock`).

Everything below was checked against the extracted SRPM (`glibc.spec`, the
`glibc-2.39.tar.xz` source, `wrap-find-debuginfo.sh`), the official binary
RPMs, and the store paths of the pinned nixpkgs. Statements marked
**(verified)** were checked by running commands. Statements marked
**(inferred)** were not.

---

## TL;DR

1. **Linking against nixpkgs libraries carries no symbol-version risk at this pin
   (verified).** Every library the shipped glibc artifacts link against
   (libgd + its full closure, libpng, zlib, libselinux) and the ones configure
   probes (libaudit, libcap, libidn2, libstdc++, libgcc_s) reference at most
   `GLIBC_2.38`. None of them references `GLIBC_2.40` or later, so linking them
   against the new 2.39 libc works.
2. **The real stage0 blocker is the compiler driver, not the libraries (verified).**
   The unwrapped nixpkgs `gcc14.cc` has these problems inside an FHS chroot:
   - its native header dir is hard-wired to `/nix/store/…-glibc-2.42-100-dev/include`;
   - it has no `/usr/lib64` library or startfile search path (`-print-file-name=crt1.o`
     returns just `crt1.o`);
   - its specs hard-wire the dynamic linker to `/nix/store/…glibc-2.42-100/lib64/ld-linux-x86-64.so.2`;
   - it is built with `--disable-multilib`, without `--enable-linker-build-id`
     and without `--with-linker-hash-style=gnu`.

   Rocky's gcc is built with `--enable-multilib --enable-linker-build-id
   --with-linker-hash-style=gnu --with-arch_64=x86-64-v3 --with-arch_32=x86-64 --enable-cet`
   (verified from the official `gcc-14.3.1-4.4.el10` driver binary).
   With the nixpkgs driver as-is, the build goes wrong in these ways:
   - glibc configure **silently** turns off memusagestat (`LIBGD=no`, after which
     `%files utils` fails), SELinux in makedb, and `_FORTIFY_SOURCE=3`
     (it drops to 2);
   - the x86_64 spec **always** builds a 32-bit glibc (`glibc32`) with `gcc -m32`;
   - find-debuginfo fails on binaries that have no build-id (inferred from
     redhat-rpm-config's strict mode).

   → Stage0 needs an **FHS-configured, multilib gcc14**, built once from nixpkgs'
   gcc14 sources with Rocky-like configure flags. See §B.3.
3. **The spec has implicit build-time needs outside the BuildRequires list.**
   They hold even with `--without testsuite`:
   - diffutils (`diff` in `%prep` and in `%install`);
   - util-linux `hardlink` (`%install`);
   - python3 (`%prep` runs `parse-SUPPORTED.py`; configure treats python as critical);
   - debugedit, dwz, elfutils (`eu-strip`), binutils, xz, gdb (`gdb-add-index`),
     used by find-debuginfo and the glibc wrapper.

   Perl is *not* needed outside the testsuite. The Rocky patches
   `glibc-rh2292195-{1,2,3}.patch` (upstream bug 31892) make `mtrace` a
   `#! /bin/sh` wrapper that runs `exec perl …` through PATH, and install it
   unconditionally. `Requires: /usr/bin/perl` is written by hand in the spec.
4. **nixpkgs `coreutils` is a multicall binary that references `GLIBC_2.42`
   (`cfsetispeed@GLIBC_2.42`) (verified).** `%check` runs
   `$run_ldso /bin/true` (new 2.39 `ld.so`, `--library-path` set to the new libdir).
   When the testsuite is on, that command fails unless `/bin/true` (and
   `/usr/bin/true` for the valgrind smoke test) come from a non-multicall
   coreutils build.
5. **rpm 4.20 (nixpkgs) changes the build directory to `BUILD/glibc-2.39-build/glibc-2.39`
   (verified with a test spec).** Official binaries embed
   `/builddir/build/BUILD/glibc-2.39/...`: 76 of 422 benchtests binaries, plus the
   annobin notes in `libc.so.6` and `libc.a`. Rocky built with rpm 4.19.1.1.
   To match those paths, use rpm 4.19 built from the Rocky SRPM (another track's call).

---

## Part A: official baselines

Downloaded 16 binary RPMs built from `glibc-2.39-142.el10_2.src.rpm` (sha256
verified against repodata) to
`/tmp/claude-60514/-run-host-home-ai-shammas-Code-el-nixos/dadc2aad-80ad-416a-b238-b2a3e0de53b8/scratchpad/research-deps/rpms/`.
Per-RPM reports are in `docs/research/baseline/<name>.txt`. Each report holds:
- the header summary (NEVRA, buildhost, build time, payload, optflags, sizes, rpm version);
- the description;
- the full file list with octal mode, user, group, size, file flags and link targets;
- provides, requires, weak dependencies, conflicts and obsoletes;
- scripts, triggers and file triggers;
- `readelf -d` NEEDED, RPATH and INTERP for every ELF file;
- leak checks.

The generator script is
`/tmp/claude-60514/-run-host-home-ai-shammas-Code-el-nixos/dadc2aad-80ad-416a-b238-b2a3e0de53b8/scratchpad/research-deps-scripts/baseline.sh`.

### What Rocky ships (x86_64, 205 `glibc-langpack-*` omitted except `-en`)

| RPM | repo | files | installed bytes | notable non-glibc requires |
|---|---|---|---|---|
| glibc | BaseOS | 102 | 6,560,802 | basesystem, libgcc(x86-64) |
| glibc-common | BaseOS | 51 | 1,072,866 | /usr/bin/bash |
| glibc-gconv-extra | BaseOS | 619 | 8,159,598 | (internal gconv libs) |
| glibc-minimal-langpack | BaseOS | 0 | 0 | |
| glibc-langpack-en | BaseOS | 492 | 5,980,174 | |
| glibc-all-langpacks | BaseOS | 41 | 234,414,577 | (locale-archive) |
| libnsl | BaseOS | 4 | 104,393 | |
| glibc-devel | AppStream | 526 | 2,350,921 | kernel-headers >= 3.2, libxcrypt-devel >= 4.0.0 |
| glibc-doc (noarch) | AppStream | 25 | 1,237,885 | |
| glibc-locale-source | AppStream | 601 | 15,681,556 | gzip |
| glibc-utils | AppStream | 14 | 137,790 | /usr/bin/perl, /usr/bin/bash, /usr/bin/sh, libgd.so.3, libpng16.so.16, libz.so.1 |
| glibc-static | CRB | 6 | 11,273,358 | libxcrypt-static >= 4.0.0 |
| glibc-nss-devel | CRB | 3 | 50 | |
| glibc-benchtests | CRB | 914 | 20,540,275 | /usr/bin/bash, /usr/bin/python3 |
| nss_db | CRB | 8 | 70,089 | libselinux.so.1(LIBSELINUX_1.0) |
| nss_hesiod | CRB | 5 | 33,911 | |

**Packages that do not exist in RHEL/Rocky 10:**
- nscd: the spec has `Obsoletes: nscd < 2.35` and configure gets
  `--disable-build-nscd --disable-nscd`;
- glibc-headers;
- compat-libcrypt (built with `--disable-crypt`; libxcrypt replaces it).

**Built by the spec but not shipped in BaseOS/AppStream/CRB (verified against all
three repodata files):**
- `compat-libpthread-nonshared`;
- `sysroot-x86_64-el10-glibc` (noarch);
- `glibc32`;
- the debuginfo and debugsource packages.

Our rpmbuild will produce these too. The comparison should ignore them, or
document them as extras.

Older builds are also still in the repos (121, 124, 126, 128). Only 142
matters here, and the lock generator must keep only the newest version.

### Header facts that matter for reproduction (all 16 RPMs)

- Build host `ord1-prod-x86build009.svc.aws.rockylinux.org`, BUILDTIME 1791453144,
  RPM version 4.19.1.1.
- Payload `cpio` / `zstd` level 19 (`%_binary_payload w19.zstdio`). File digest algo
  8 (sha256). `rpmlib(PayloadIsZstd)` is required.
- OPTFLAGS:
  `-O2 -flto=auto -ffat-lto-objects -fexceptions -g -grecord-gcc-switches -pipe -Wall -Wno-complain-wrong-lang -Werror=format-security -Wp,-U_FORTIFY_SOURCE,-D_FORTIFY_SOURCE=3 -Wp,-D_GLIBCXX_ASSERTIONS -specs=/usr/lib/rpm/redhat/redhat-hardened-cc1 -fstack-protector-strong -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1 -m64 -march=x86-64-v3 -mtune=generic -fasynchronous-unwind-tables -fstack-clash-protection -fcf-protection -mtls-dialect=gnu2`.
  The glibc spec does not use these flags directly. Its Lua code (`inherit_flags`)
  keeps only a whitelist: `-march=x86-64-v3 -mtune=generic -m64 -O2 -Wall
  -Wp,-D_GLIBCXX_ASSERTIONS -fasynchronous-unwind-tables -fstack-clash-protection -g`
  and the annobin specs file. `-flto`, the hardened specs, `-mtls-dialect=gnu2` and
  `-fcf-protection` are **not** inherited. `--enable-cet` and
  `--enable-stack-protector=strong` come from configure arguments instead.
- Compiler: `.comment` reads `GCC: (GNU) 14.3.1 20251022 (Red Hat 14.3.1-4)`,
  annobin `gcc 14.3.1 20251022`.

### ELF linkage of the shipped artifacts (verified, from the baseline files)

- **Only two shipped binaries link non-glibc libraries:**
  - `/usr/bin/memusagestat` (glibc-utils): NEEDED `libgd.so.3 libpng16.so.16 libz.so.1 libm.so.6 libc.so.6`.
    Version needs: libc only (`GLIBC_2.2.5 … GLIBC_2.38`, `GLIBC_ABI_DT_RELR`).
    No versioned gd, png or zlib symbols. It uses 11 `gdImage*` functions plus `gdFontSmall` and `gdFontLarge`.
  - `/usr/bin/makedb` (nss_db): NEEDED `libselinux.so.1 libc.so.6`, verneed `LIBSELINUX_1.0`.
- Nothing links libaudit, libcap or libidn2. Those BuildRequires only feed configure
  probes (libaudit and libcap are used only by nscd and pt_chown, and neither is
  built) or the testsuite (libidn2).
- All other ELF files need only glibc's own libraries. `ldconfig` is static-pie
  (no NEEDED). Programs use INTERP `/lib64/ld-linux-x86-64.so.2`.
- Every program and library carries `BIND_NOW`.
- Hash style:
  - programs have only `.gnu.hash`, because gcc is configured with `--with-linker-hash-style=gnu`;
  - shared libraries have `.hash` and `.gnu.hash`, because glibc passes `-Wl,--hash-style=both`
    through `LDFLAGS.so` and `LDFLAGS-rtld`.
- `libc.so.6` carries:
  - GNU property `x86 feature: IBT, SHSTK` and `ISA needed: x86-64-baseline, v2, v3`;
  - 80 SystemTap SDT probes (`.note.stapsdt`, from `--enable-systemtap`);
  - `.annobin.notes`, `.gnu.build.attributes` and `.gnu_debuglink`;
  - a stripped `.symtab` that the glibc wrapper intentionally keeps.
- `ld-linux-x86-64.so.2` keeps full `.debug_*` sections and `.symtab` (for valgrind).
  `wrap-find-debuginfo.sh` restores the unstripped ld.so, rewrites its source paths
  to `/usr/src/debug/glibc-2.39-142.el10_2.x86_64/` with debugedit, strips the
  annobin symbols and runs `dwz` on it.
- Other ELF files carry `.gnu_debugdata` (xz minidebuginfo) and `.gnu_debuglink`.
- `/usr/lib/.build-id/xx/…` symlinks ship inside the main RPMs (56 of them in
  `glibc`). We need build-ids (`--build-id`) and `%_build_id_links` to match.
- Static archives are **not** deterministic: members carry uid/gid 993/135 and real
  mtimes. nixpkgs binutils is built with deterministic archives (0/0, mtime 0), so
  expect a byte difference there.

### Leak checks: `/usr/lib/debug` and build paths (verified)

- No payload has any path under `/usr/lib/debug`. Debuginfo lives in separate
  -debuginfo RPMs that are not in these repos.
- Files whose content mentions such paths:
  - `/usr/bin/sprof` contains the string `/usr/lib/debug/`. This is legitimate:
    sprof looks up separate debuginfo there.
  - `libc.so.6`, `libc.a`, `libm-2.39.a`, `libg.a` and `libmcheck.a` contain
    `/builddir/build/BUILD/glibc-2.39/build-x86_64-redhat-linux/...` in annobin
    `CF:`/`GW:` strings (`.gnu.build.attributes`, `.annobin.notes`).
  - `ld-linux-x86-64.so.2` contains `/usr/src/debug/glibc-2.39-142.el10_2.x86_64/...`
    in the retained DWARF.
  - 76 of the 422 files in `glibc-benchtests` embed
    `/builddir/build/BUILD/glibc-2.39[/build-x86_64-redhat-linux[/elf/ld-linux-x86-64.so.2]]`
    in `.rodata` (the support library's objdir and srcdir paths).
  - No `/nix/store` occurs anywhere. That is expected; this is the check our own
    output must also pass.

Implications for our build: `%_topdir` must be `/builddir/build`, which DESIGN
already specifies. The build dir must be `BUILD/glibc-2.39`, which rpm 4.20 does
not produce (see Risks). Annobin strings appear only if annobin is used.

---

## Part B: BuildRequires → why → nixpkgs → risk → recommendation

### B.1 How the spec uses each dependency

The spec header defines these switches:
- `%bcond_without testsuite`
- `%bcond_without benchtests`
- `%bcond_with bootstrap`
- `%bcond_without werror`
- `%bcond_without docs`
- `valgrind` on for `%{valgrind_arches}`.

`--with bootstrap` drops gd, png, zlib, selinux, benchtests, werror, docs,
valgrind and the sysroot package, and removes memusage and memusagestat from
`%files utils`. That changes the shipped package set, so do **not** use
bootstrap mode for the milestone.

`%{without bootstrap} && %{with testsuite}` gate these BuildRequires:
diffutils, gcc-c++, libstdc++-static, glibc-static, libidn2, perl-interpreter.

Important configure behaviours (glibc 2.39 `configure.ac`, verified):

- `AC_CHECK_PROG_VER` treats these tools as *critical*: make ≥ 4, gawk ≥ 3.1.2,
  bison ≥ 2.7, python3 (`PYTHON_PROG`), and GNU ld, gold or lld at a minimum version.
  msgfmt, makeinfo and sed are *aux*: if one is missing it is set to `:`, and
  the outputs it would make (.mo files, info pages) silently disappear.
- These checks link a test program with the **build-host** compiler and libc
  (stage0 = nixpkgs glibc 2.42). Each one degrades silently when linking fails:
  - libgd: `LIBGD` → memusagestat and memusage;
  - `-lselinux` → `have-selinux` (makedb);
  - `-laudit` and `-lcap`, probed only inside the selinux branch → `have-libaudit`
    and `have-libcap` (config.h only);
  - `__builtin_dynamic_object_size` → **`_FORTIFY_SOURCE` level 3 vs 2** for glibc's own programs;
  - C++ dynamic and *static* link (`-static` iostream) → otherwise `CXX=` and the C++ tests are skipped.
- `AC_PATH_PROG(BASH_SHELL, bash)` records an **absolute path** that becomes
  the `#!` line of `ldd`, `sotruss`, `tzselect`, `xtrace` and `memusage`.
  Official: `#!/usr/bin/bash` (verified). So the chroot's `PATH` must start
  with `/usr/bin` (mock uses `/usr/bin:/bin:/usr/sbin:/sbin`), and `/usr/bin/bash`
  must be an FHS path. If not, a `/nix/store` path ends up in a shipped script;
  brp-mangle-shebangs only rewrites `/usr/bin/env` and `/bin` → `/usr/bin`, not
  nix paths. `AC_PATH_PROG(PERL)` no longer affects shipped files after the
  rh2292195 patches. Official `mtrace` starts with `#!/usr/bin/sh` (mangled from
  `/bin/sh`) and calls `perl` through PATH.
- `--with-headers=/usr/include` makes `SYSINCLUDES = -nostdinc -isystem <gcc include>
  -isystem <gcc include-fixed> -isystem /usr/include`. Exception:
  `memusagestat.o` (and nscd's `selinux.o`, which is not built) sets
  `sysincludes = # nothing`. That object is compiled with the **compiler's default
  include path**, so `gd.h` must be on that path.
- `LDLIBS-memusagestat = -lgd -lpng -lz -lm` and `LDLIBS-makedb = -lselinux`
  (when `have-selinux=yes`). Programs are linked with `-Wl,-rpath-link=<build dirs>`
  and the new `libc.so`. ld therefore resolves libgd's own DT_NEEDED `libc.so.6`
  against the new 2.39 libc. That is why the GLIBC_2.40+ check matters.
  Programs get `-Wl,-dynamic-linker=/lib64/ld-linux-x86-64.so.2`
  (`installed-rtld-LDFLAGS`). glibc never passes `--build-id`; it relies on the
  gcc default.

### B.2 Mapping table

Versions are from the pinned nixpkgs. Rocky versions come from 10.2 repodata.
The "GLIBC≥2.40 refs" column gives the result of `objdump -T` on the nixpkgs
library: undefined symbols with `GLIBC_2.4[0-9]` versions (verified).

| BuildRequire | Why glibc needs it (source evidence) | nixpkgs attr (version) vs Rocky | GLIBC≥2.40 refs / link risk | Recommendation (stage0) |
|---|---|---|---|---|
| audit-libs-devel | `AC_CHECK_LIB(audit, audit_log_user_avc_message)` only inside the SELinux branch → `HAVE_LIBAUDIT`. Used only by `nscd/selinux.c` and `nscd/connections.c` (nscd is disabled) and `login/programs/pt_chown.c` (not enabled). No shipped file links libaudit. | `audit.lib` + `audit.dev` (4.2.1) | `libaudit.so.1` max GLIBC_2.38: **none**. Not linked into any output. | **Provide from nixpkgs** for config.h parity; it costs nothing. Dropping it changes nothing that ships. |
| binutils ≥ 2.30-17 | as, ld, objcopy, strip, nm, readelf. `ASFLAGS="-g -Wa,--generate-missing-build-notes=yes"` is always passed (`glibc_make_flags_as`). The debuginfo wrapper uses `objcopy --merge-notes`, `strip -w -K`, `nm`. | `binutils-unwrapped` (2.46) vs 2.41-63.el10 | Tool, no link risk. 2.46 supports `--generate-missing-build-notes`, `-z pack-relative-relocs`, `-z mark-plt` (verified). | **Provide `binutils-unwrapped`** (never the cc-wrapper/ld-wrapper: they inject nix rpaths and flags). ld has **no default SEARCH_DIR** (verified), so the driver must pass `-L/usr/lib64`. Expect diffs: deterministic `ar` (0/0 uid/gid, mtime 0) and possible note-layout differences from 2.41. Rebuild from the Rocky SRPM in stage1. |
| bison ≥ 2.7 | `intl/plural.y` → `$(objpfx)plural.c` (generated in the build dir; the official annobin string shows `build-x86_64-redhat-linux/intl/plural.c`). Configure treats it as critical. | `bison` (3.8.2) = Rocky 3.8.2 | Tool, none. | **Provide.** |
| diffutils | `diff -u` in `%prep` (locale table check against `localedata/SUPPORTED`). `diff -ur` in `%install` (x86_64 32/64 header consistency check). `cmp` in the testsuite and Makerules. The BuildRequire is listed under testsuite, but **`%prep`/`%install` need it regardless**. | `diffutils` (3.12) | Tool, none. | **Provide always.** |
| gawk | Configure critical (`AWK` must be gawk ≥ 3.1.2). Many `scripts/*.awk` generators (versions.awk, gen-libc-modules, etc.). | `gawk` (5.4.1) vs 5.3.x | Tool, none. awk output could differ in generated-file ordering (unlikely). | **Provide.** |
| gcc ≥ 7.2.1-6 | Compiler (needs `-fstack-clash-protection`, `--enable-cet`, `-march=x86-64-v3`). The **x86_64 spec always builds `build-x86_64-redhat-linux-32` with `CC="gcc -m32"`** for the `glibc32` subpackage, so multilib is needed: 32-bit `libgcc.a`, `libgcc_eh.a` and `crtbegin*.o`. Annobin: if `%_annotated_build` is set, `-specs=…redhat-annobin-cc1` and `BuildFlagsNonshared="-fplugin=annobin …"` are used. | `gcc14.cc` (14.4.0) vs 14.3.1-4.4.el10. **nixpkgs gcc14 is `--disable-multilib`; `gcc14_multi` does not exist; `gcc14.cc.override { enableMultilib = true; }` evaluates but is NOT in cache.nixos.org (verified)**. `gcc_multi` is gcc 15 (cached). No `annobin` attr in nixpkgs. | libgcc.a, libgcc_eh.a and crt*.o have no GLIBC version refs, and all 298 libgcc.a objects carry IBT/SHSTK properties (verified), so CET marking survives. **Driver problems, all verified:** native header dir is the nix glibc-2.42-dev; no `/usr/lib64` search (no crt1.o, no libc.so found); `-dynamic-linker /nix/store/…glibc-2.42…`; no default `--build-id`; no `--hash-style=gnu`; `x86_64-unknown-linux-gnu` triple. | **Build an FHS multilib gcc14 in stage0** (§B.3). Run rpmbuild with `--undefine _annotated_build` (no annobin plugin), or later build Rocky's `annobin` SRPM as a gcc plugin against our gcc14 (nixpkgs gcc14 ships `plugin/include`, verified). Do not use gcc 15 to compile glibc 2.39 with `-Werror`. |
| gcc-c++ | Testsuite only: C++ tests and the configure C++ link check (`CXX` is set to `g++ …` explicitly by the spec; if linking fails configure sets `CXX=`). | in `gcc14.cc` (g++) | libstdc++.so.6 (gcc14) max GLIBC_2.38: none. | Comes with the FHS gcc. Needed only with the testsuite. |
| gd-devel | `memusagestat` (malloc/Makefile: built if `LIBGD != no`; configure test `#include <gd.h>` + `gdImagePng` with `-lgd -lpng -lz -lm`). `memusage` is installed only in the same branch, and `%files utils` lists both whenever not bootstrapping. | `gd` (`gd.dev`, `gd.out`; 2.3.3) = Rocky 2.3.3-22 | `libgd.so.3` max GLIBC_2.38. **Whole closure** (fontconfig, freetype, X11/xcb, jpeg, tiff, webp, avif, aom, dav1d, …, 120+ DSOs) max GLIBC_2.38: **none** (verified). Output memusagestat would have NEEDED `libgd.so.3` and no versioned gd symbols, as in the official build. | **Provide from nixpkgs.** Expose `gd.h` in the compiler's default include path (`/usr/include` with an FHS gcc) and `libgd.so` in `/usr/lib64`. ld follows libgd's DT_RUNPATH to its nix deps at link time. Because the driver is unwrapped, nothing nix-specific lands in memusagestat (check: no RUNPATH, no `/nix/store`). Rebuilding gd from a Rocky SRPM would pull in a large graph. |
| gdb | Testsuite: pretty-printer tests (`scripts/test_printers_common.py`, which also wants python `pexpect`; otherwise UNSUPPORTED). Also `gdb-add-index` from find-debuginfo (`%_include_gdb_index`) → `.gdb_index` in the -debuginfo files. If gdb is missing, find-debuginfo skips that step silently (verified in the debugedit 5.2 script). | `gdb` (17.2) | `gdb` itself references GLIBC_2.42 (`cfsetispeed`), but it runs under its own nix ld.so, so it doesn't matter. | **Provide** (cheap, and keeps debuginfo closer to the official build). Optional for the milestone. |
| gettext | `msgfmt` → `po/*.mo` → `libc.mo` in the langpacks (39 in all-langpacks, 1 in langpack-en). Aux tool: if missing, the .mo files silently disappear. | `gettext` (1.0) vs 0.22.x | Tool, none. msgfmt 1.0 may lay out the hash table differently (byte diff possible). | **Provide.** |
| glibc-static | Configure's *static* C++ link check (`-static` iostream program). Testsuite only. | `glibc.static` (2.42) | Used only for the configure probe with the host libc. Tests link the new libc.a. | Provide only when the testsuite is on. |
| kernel-headers ≥ 3.2 | `--with-headers=/usr/include` (`linux/`, `asm/`, `asm-generic/`). Configure version check. glibc-devel `Requires: kernel-headers`. The testsuite's `misc/tst-syscall-list` compares the kernel headers' syscall list with glibc's list. | `linuxHeaders` (6.18.7) vs Rocky 6.12.0-211.x | Headers only, no link risk. Could change compile-time constants. With 6.18 headers, newer syscalls than glibc 2.39 + RHEL patches know about (6.13+: `*xattrat`, `open_tree_attr`, …) would likely fail `tst-syscall-list` (inferred). | **Stage0: nixpkgs `linuxHeaders`** is acceptable for the build. **Preferred: Rocky `kernel-headers` built from the kernel SRPM** (`headers_install` only; see the kernel research track). Alternatively override `linuxHeaders` to a 6.12 tarball. Build it before glibc. |
| libcap-devel | `AC_CHECK_LIB(cap, cap_init)` inside the SELinux branch → `HAVE_LIBCAP`. Used only by nscd and pt_chown (neither built). Nothing links it. | `libcap.lib` + `libcap.dev` (2.77) | `libcap.so.2` max GLIBC_2.38: none. | **Provide from nixpkgs** for parity (no effect on shipped bits). |
| libidn2 | Testsuite only (`AI_IDN`/`NI_IDN` tests `dlopen("libidn2.so.0")` into test programs that run on the new libc). | `libidn2` (2.3.8) | max GLIBC_2.14: none, so it is safe to dlopen under 2.39. | Provide when the testsuite is on. Must be findable by the test ld.so (`/usr/lib64` or the library path). |
| libpng-devel | memusagestat (`-lpng`) and the configure libgd test. | `libpng` (1.6.58, **APNG-patched** `libpng-apng`) vs 1.6.40 | `libpng16.so.16` max GLIBC_2.29: none. memusagestat uses no png symbols directly (official has no verneed on png). | **Provide from nixpkgs.** |
| libselinux-devel ≥ 1.33.4-3 | `makedb` (`LDLIBS-makedb := -lselinux`, `<selinux/selinux.h>` in `nss/makedb.c`) → official NEEDED `libselinux.so.1`, verneed `LIBSELINUX_1.0`. Also gates the audit and cap probes. If missing, makedb silently builds **without** SELinux and nss_db's Requires change. | `libselinux` (`.out` + `.dev`; 3.10) = Rocky 3.10-1.el10 | `libselinux.so.1` max GLIBC_2.38 (deps: libpcre2-8 max 2.33): none. | **Provide from nixpkgs.** Verify `have-selinux = yes` in config.make. |
| libstdc++-static | Testsuite only (static C++ tests and the configure static C++ link probe). | `gcc14.cc` has `lib/libstdc++.a` (verified) | none | With the FHS gcc. Testsuite only. |
| make ≥ 4.0 | Build driver (`-O`). | `gnumake` (4.4.1) = Rocky 4.4.1 | Tool | **Provide.** |
| perl-interpreter | Testsuite only: `tst-mtrace`, `tst-dynarray-mem` and others are gated on `PERL != no`. Upstream 2.39 installed `mtrace` only when perl was found (`#! @PERL@`). Rocky's `glibc-rh2292195-1..3.patch` (BZ 31892, changelog "Support --without testsuite builds without perl installed") makes `mtrace` a `#! /bin/sh` + `exec perl` wrapper that is always installed. glibc-utils' `Requires: /usr/bin/perl` is explicit in the spec. | `perl` (5.42.3) | Tool, no link risk. No path leak (mtrace doesn't embed the configure-found perl path any more). | Provide when the testsuite is on. Harmless to always provide as `/usr/bin/perl`. Note that texinfo's `makeinfo` is a perl script, but the nixpkgs one carries its own perl. |
| procps-ng | Testsuite (`/bin/ps`, per the spec comment). | `procps` (4.0.6) | Tool | Provide when the testsuite is on (cheap anyway). |
| python3 | Configure critical (`PYTHON = python3 -B`). Build-time generators (`scripts/gen-as-const.py`, `gen-libm-test.py`, `gen-tunables`, …). **`%prep` runs `python3 parse-SUPPORTED.py`**. benchtests ship `compare_bench.py`, `import_bench.py`, `validate_benchout.py` (official Requires `/usr/bin/python3` via brp-mangle-shebangs). | `python3` (3.13.15) vs 3.12 | Tool | **Provide** as `/usr/bin/python3`. |
| python3-devel | Only so that `/usr/bin/python3` exists (spec comment). In Rocky it also pulls python-rpm-macros and generators, which don't matter for glibc. | (n/a) | none | **Skip**; the `/usr/bin/python3` symlink covers it. |
| sed ≥ 3.95 | Everywhere (configure aux, Makefiles, mtrace generation). | `gnused` (4.10). Note: **attr `sed` does not exist** | Tool | **Provide `gnused`.** |
| systemtap-sdt-devel | `--enable-systemtap` (always passed) needs `<sys/sdt.h>` with asm support, or configure **fails**. Probes go to `.note.stapsdt` (80 in libc.so.6, plus ldconfig and ld.so). Header-only. | **`libsystemtap`** (5.3; `include/sys/sdt.h` + generated `sdt-config.h` with `_SDT_ASM_SECTION_AUTOGROUP_SUPPORT 1`, verified) vs 5.4-3.el10. **`systemtap-sdt` is only the `dtrace` tool, without headers (verified).** Top-level `systemtap` attr is missing. | Header-only: none | **Provide `libsystemtap`** (headers into `/usr/include/sys/`). Later: the Rocky systemtap SRPM's `-sdt-devel` subpackage. |
| texinfo ≥ 5.0 | `makeinfo` → `libc.info*` (glibc-doc, gzip-compressed by brp-compress). Aux tool: if missing, glibc-doc loses its info files. `INSTALL_INFO` is detected too. | `texinfo` (7.2) vs 7.1 | Tool | **Provide.** Expect byte diffs in the info files (makeinfo version banner). |
| util-linux | **`hardlink -c /usr/lib/locale` in `%install`, unconditionally.** `/bin/kill` in the testsuite. | `util-linux` (`.bin` has `hardlink` and `kill`, verified; 2.42.3) | Tool | **Provide always.** |
| valgrind | `%check`: smoke test `$run_ldso /usr/bin/valgrind --error-exitcode=1 $run_ldso /usr/bin/true`, run only if `_enable_debug_packages` and `%{with valgrind}`. In-tree `elf/tst-valgrind-smoke` (exit 77 if valgrind is absent). | `valgrind` (3.26.0) | valgrind launcher max GLIBC_2.34. Tools are static; vgpreload has no GLIBC refs: fine. **But `/usr/bin/true` from nixpkgs coreutils needs GLIBC_2.42, so the smoke test fails.** | With the testsuite: provide valgrind **and** a non-multicall `true`, or pass `--without valgrind`. Without the testsuite: irrelevant. |
| zlib-devel | memusagestat (`-lz`) and the configure libgd test. | `zlib` (1.3.2) vs Rocky **zlib-ng-compat 2.2.3** | `libz.so.1` max GLIBC_2.14: none. memusagestat has no zlib verneed. | **Provide from nixpkgs.** (Runtime pairing on Rocky is zlib-ng-compat; NEEDED `libz.so.1` is identical.) |

#### Implicit buildroot (not in BuildRequires; mock's EL `chroot_setup_cmd`)

The usual EL mock `chroot_setup_cmd` (inferred) installs:
bash, bzip2, coreutils, cpio, diffutils, rocky-release, findutils, gawk,
glibc-minimal-langpack, grep, gzip, info, patch, redhat-rpm-config, rpm-build,
sed, shadow-utils, tar, unzip, util-linux, which, xz.

rpm-build in turn pulls in debugedit, elfutils, dwz, file, binutils and zstd.

The glibc spec and the debuginfo pipeline actually use:
- `patch` (`%autosetup -p1`, more than 600 patches);
- `tar`, `xz` (source tarball and minidebuginfo);
- `gzip` (brp-compress, info pages);
- `find`, `xargs`, `grep`, `sort`, `comm`, `cpio`;
- `debugedit` and `find-debuginfo` (debugedit 5.x);
- `eu-strip` (elfutils), `dwz`, `objcopy`, `nm`, `gdb-add-index`;
- `truncate` (coreutils, `%install`).

nixpkgs attrs:
`bash`, `bzip2`, `coreutils` (see the multicall warning), `cpio`, `findutils`,
`gnugrep`, `gzip`, `gnupatch`, `gnutar`, `xz`, `zstd`, `unzip`, `which`,
`shadow`, `file`, `debugedit` (5.2; Rocky 5.1), `elfutils` (0.194), `dwz` (0.16).
rpm is 4.20.1 in nixpkgs, with zstd payload support and Lua 5.4 (verified).

### B.3 Recommended stage0 compiler: FHS multilib gcc14 (the critical item)

Why it is needed:
- the spec builds a 32-bit glibc on x86_64 (`glibc32`);
- the configure probes need a driver that finds `/usr/include` and `/usr/lib64`;
- RPM's debuginfo pipeline needs `--build-id`.

None of this can be fixed without rebuilding gcc, because the multilib libgcc
must be built anyway. Therefore build one gcc14 from the nixpkgs gcc14 source
and expression, overridden to match Rocky's configure flags (taken from
`strings /usr/bin/gcc` in the official `gcc-14.3.1-4.4.el10.x86_64.rpm`):

```
--enable-multilib --with-arch_64=x86-64-v3 --with-arch_32=x86-64 --with-tune=generic
--enable-linker-build-id --with-linker-hash-style=gnu --enable-cet
--enable-gnu-indirect-function --enable-initfini-array --enable-gnu-unique-object
--enable-__cxa_atexit --disable-libunwind-exceptions --enable-plugin
--enable-host-pie --enable-host-bind-now --enable-threads=posix --enable-shared
--with-gcc-major-version-only --with-system-zlib --without-isl
(Rocky also: --build=x86_64-redhat-linux, --enable-languages=c,c++,fortran,lto,
 offload targets, bootstrap-lto; not needed for stage0)
```

The FHS-specific parts:
- `--with-native-system-header-dir=/usr/include`.
- Drop nixpkgs' `no-sys-dirs` patch and the `GLIBC_DYNAMIC_LINKER` substitution,
  so the defaults are `/lib64/ld-linux-x86-64.so.2` and `/lib/ld-linux.so.2`,
  and `/usr/lib64` and `/lib64` are searched.
- Pass `--with-build-sysroot=<nix-built FHS staging tree made from glibc_multi + linuxHeaders>`
  so the target libraries (libgcc, libstdc++) can be built inside the Nix sandbox.
  `glibc_multi` and `pkgsi686Linux.glibc` are both cached (verified).
- Optionally use `--target=x86_64-redhat-linux` so `lib/gcc/x86_64-redhat-linux/14/` matches Rocky.

Cost: one uncached gcc build, about 1–2 h on 2 vCPUs (inferred). It is then
cached and reused by every stage0 build.

Quick fallback for 64-bit-only experiments: a `/usr/bin/gcc` shim that execs
unwrapped `gcc14.cc` with `-B/usr/lib64/ -L/usr/lib64 -idirafter /usr/include -Wl,--build-id`.
It still cannot build the mandatory `-m32` pass, and the nix glibc-2.42 headers
stay first in the default include path. Use it only to iterate on the rest of
the pipeline.

### B.4 Post-configure verification for stage0 (add as build assertions)

In `build-x86_64-redhat-linux/config.make` (and `config.h`), expect:

```
LIBGD = yes                 have-selinux = yes
have-libaudit = yes         have-libcap = yes
BASH = /usr/bin/bash        PERL = /usr/bin/perl   (PERL only matters for tests)
PYTHON = python3 -B         MSGFMT = msgfmt         MAKEINFO = makeinfo
fortify-source = -Wp,-D_FORTIFY_SOURCE=3   (i.e. libc_cv_supported_fortify_source=3)
build-nscd = no             cross-compiling = no
config.h: #define USE_STAP_PROBE 1
CXX = g++ ...               (only if the testsuite is on)
```

Then on the produced RPMs, check:
- `memusagestat`: NEEDED is exactly `libgd.so.3 libpng16.so.16 libz.so.1 libm.so.6 libc.so.6`;
- `makedb`: NEEDED has `libselinux.so.1` with verneed `LIBSELINUX_1.0`;
- programs: INTERP `/lib64/ld-linux-x86-64.so.2`, no RPATH or RUNPATH;
- no `/nix/store` string anywhere (the `rpmTree` `allowedReferences = [ ]` check);
- every ELF has `.note.gnu.build-id`;
- `libc.so.6` has 80 stapsdt notes and the `IBT, SHSTK` property;
- the first lines of `ldd`, `sotruss`, `xtrace`, `memusage` and `tzselect` read
  `#!/usr/bin/bash`, and `mtrace` reads `#!/usr/bin/sh` (official, verified).

### B.5 Testsuite decision

`%check` runs `make check` with `TIMEOUTFACTOR=16`. That takes hours on a
2-vCPU nixbuild.net builder (inferred). Inside an unprivileged user namespace,
some container, setuid and `/proc`-dependent tests are likely to fail; there are
allowed-failure lists `allowed-failures-{noarch,x86_64}.txt`.

Recommendation:
- Milestone 1: build with `--nocheck` (equivalently `--without testsuite`).
  That also removes the gcc-c++, libstdc++-static, glibc-static, libidn2,
  procps, perl and gdb requirements. **diffutils, util-linux (`hardlink`) and
  python3 are still required.**
- Turn the testsuite on later as a separate derivation, so it does not block
  getting packages out. It then needs:
  - `/bin/true` and `/usr/bin/true` that reference glibc ≤ 2.39, for example
    `coreutils.override { singleBinary = false; }` (inferred: non-multicall `true`
    doesn't pull in termios). Any other system binary that `%check` runs through
    `$run_ldso` needs the same;
  - Rocky kernel-headers, for `tst-syscall-list`.

---

## Risks and open items

- **rpm 4.20 build dir:** nixpkgs rpm 4.20.1 puts sources in
  `%{_builddir}/%{name}-%{version}-build/` (verified). Embedded paths in
  benchtests, annobin strings and debuginfo would differ from the official
  `/builddir/build/BUILD/glibc-2.39`. Use Rocky's rpm 4.19.1.1 from its SRPM for
  stage0 rpmbuild, or accept and document the difference. nixpkgs rpm also has
  `%_rpmconfigdir`, `%_usr` and `%_libdir` pointing into `/nix/store` (verified),
  which the macro track already plans to fix.
- **Silent configure degradation** (LIBGD, selinux, fortify level, CXX) when the
  compiler cannot link test programs in the chroot. Mitigation: the §B.4 assertions.
- **Shebang leakage** if `/usr/bin` is not first in PATH, or if bash resolves
  to a `/nix/store` path during configure (`BASH_SHELL`).
- **Missing build-ids:** find-debuginfo (debugedit 5.2) returns 2 on
  "No build ID note found" under `--strict-build-id` (verified in the script).
  rpm passes that flag when `%_missing_build_ids_terminate_build` is set, and
  redhat-rpm-config sets it (inferred). Without a gcc that defaults to
  `--build-id`, the build fails, or at best produces no `.build-id` links.
- **nixpkgs gcc14 driver:** no build-id, no gnu hash default, nix dynamic linker,
  nix header dir, no multilib. Mitigation: §B.3.
- **Annobin absent:** no `.annobin.notes` and fewer `.gnu.build.attributes`
  entries. Our build lacks the `/builddir/...` annobin strings: a documented
  difference, unless annobin is built from the Rocky SRPM as a plugin for our gcc14.
- **Toolchain version drift** (gcc 14.4.0 vs 14.3.1, binutils 2.46 vs 2.41,
  texinfo 7.2 vs 7.1, gettext 1.0 vs 0.22, python 3.13 vs 3.12): byte-level
  differences in code generation, info pages and .mo files, which are expected.
  Linkage and ABI are unaffected. Use a stage1 rebuild with a Rocky toolchain
  for closer parity.
- **nixpkgs libraries** are built with gcc 15 and glibc 2.42 (gd's closure pulls
  `libstdc++.so.6.0.34`). That doesn't matter at this pin, but **re-run the
  GLIBC≥2.40 check whenever the nixpkgs pin moves**. The script
  `research-deps-scripts/glibcvers.sh` in the scratchpad does it. As soon as any
  libgd/png/zlib/selinux closure member uses a 2.40+ symbol, memusagestat or
  makedb will fail to link against 2.39. The failure is loud (link error), not silent.
  Fallback: rebuild those few libraries from Rocky SRPMs against the new glibc
  (two-pass bootstrap).
- **Kernel headers 6.18 vs 6.12:** fine for building, probably breaks
  `tst-syscall-list`. Build Rocky kernel-headers first.
- **Packages Rocky doesn't ship** (`glibc32`, `sysroot-x86_64-el10-glibc`,
  `compat-libpthread-nonshared`, `-debuginfo`, `-debugsource`): our output will
  contain them, so exclude them from the parity comparison.
