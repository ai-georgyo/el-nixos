# Research: Rocky `glibc-2.39-142.el10_2` spec, analysed for a stage0 rebuild

Scope: what `rpmbuild --rebuild glibc-2.39-142.el10_2.src.rpm` does on x86_64 with
`%rhel 10`, what it needs, and what goes wrong when the buildroot is assembled from
nixpkgs (nixos-26.05: gcc14 = 14.4.0, binutils 2.46, rpm 4.20.1).

All `glibc.spec:N` references are to the spec inside the SRPM
(sha256 `68c89e62…ceb96`, matches `lock/rocky-10.2/srpms.json`). It is 4702 lines,
and the changelog starts at line 2389. Methods used:

* Read the spec, `patch-git.lua`, `wrap-find-debuginfo.sh`, `verify-ld-so-abi.sh` and
  `parse-SUPPORTED.py`. Read the relevant parts of the glibc-2.39 tarball (`configure.ac`,
  `malloc/Makefile`, `nss/Makefile`, `localedata/Makefile`, `Makeconfig`).
* Ran `rpmspec -q` and `rpmspec -P` (nixpkgs rpm 4.20.1 in a no-network bwrap) with
  Rocky's `redhat-rpm-config-295-1.el10.rocky.0.2` macros and rpmrc loaded, plus
  `--define 'rhel 10' --define 'dist .el10_2' --target x86_64-redhat-linux`. The
  expanded flags and package list below come from that run.
* Inspected the official binary `glibc-2.39-142.el10_2.x86_64.rpm` (sections,
  `.comment`, `DW_AT_producer`, notes) to confirm the flag derivation.
* Parsed the official x86_64 repodata (`BaseOS`/`AppStream`/`CRB` `primary.xml.gz`) for
  every package with `sourcerpm == glibc-2.39-142.el10_2.src.rpm`.
* Ran small tests against nixpkgs `gcc14`: annobin specs, `-m32`, and the flags the
  cc-wrapper injects.

---------------------------------------------------------------------------

## 0. TL;DR: what stage0 must deal with

1. **There is an unconditional i686 build on x86_64.** `build build-%{target}-32`
   (spec:1391-1399) with `CC="gcc -m32" --host=i686-linux-gnu`, then
   `make install` (spec:1442-1464), then the `glibc32` package (spec:1147-1168,
   2379-2387). No bcond turns it off. nixpkgs `gcc14` is `--disable-multilib`
   (tested: `gcc -m32 … → ld: cannot find -lgcc`). Stage0 needs a multilib gcc14
   (`wrapCCMulti gcc14` evaluates to 14.4.0 but is **not in cache.nixos.org**, so it
   builds from source). It also needs 32-bit libc and crt files for configure's link
   test. The only other route is to edit the spec, which breaks the
   `--rebuild`-unmodified model.
2. **annobin is in CFLAGS.** `-specs=/usr/lib/rpm/redhat/redhat-annobin-cc1` is
   inherited into CFLAGS (spec:1293). The spec also hardcodes
   `-fplugin=annobin` in `BuildFlagsNonshared` (spec:1322) when `_annotated_build > 0`.
   With nixpkgs gcc this is fatal: `cc1: fatal error: inaccessible plugin file
   …/gcc-14.4.0/lib/gcc/x86_64-unknown-linux-gnu/14.4.0/plugin/annobin.so`. There are
   two choices: provide annobin built for *this* gcc and point at it with
   `-iplugindir=`, or rebuild with `--undefine _annotated_build`. The second loses the
   annobin notes, which official binaries carry in `.annobin.notes` and
   `.gnu.build.attributes`.
3. **The nixpkgs cc-wrapper and ld-wrapper must not be used as `/usr/bin/gcc`.** The
   wrapper always injects `-fno-omit-frame-pointer -mno-omit-leaf-frame-pointer
   -mtls-dialect=gnu2`, `-Wl,-dynamic-linker=/nix/store/…glibc-2.44…`, and `-B`, `-L`
   and `-idirafter` paths into nixpkgs glibc-2.44 (verified with `NIX_DEBUG=1`). Its
   ld-wrapper adds `-rpath` for `-L` dirs in /nix/store. These change code generation:
   RHEL 10 has *no* frame pointers, and the spec deliberately does not inherit
   `-mtls-dialect=gnu2`. They also leak store paths, for example into `memusagestat`,
   which links nixpkgs `-lgd -lpng -lz`.
4. **gcc's internal include dir ends up in shipped bytes.** `ld.so` **keeps its full
   DWARF** in the shipped `glibc` RPM (wrap-find-debuginfo.sh restores it, §5). The
   official `ld-linux-x86-64.so.2` has `.debug_info`, `.debug_line` and `.symtab`, and
   its line tables reference `/usr/lib/gcc/x86_64-redhat-linux/14`. If gcc runs from
   /nix/store, the store path of gcc's include dir lands in
   `/usr/lib64/ld-linux-x86-64.so.2`, and `rpmTree`'s `allowedReferences = []` fails.
   gcc must be installed at an FHS path as a real copy or bind mount, not a symlink,
   because gcc resolves its prefix via realpath. The alternative is
   `-ffile-prefix-map=<gcc store path>=/usr` injected by the stage0 driver.
5. **The build host must support x86-64-v3.** The main build uses
   `-march=x86-64-v3` (spec:1250 + rpmrc). Official `libc.so.6` carries
   `x86 ISA needed: x86-64-baseline, x86-64-v2, x86-64-v3`. The build *runs* the new
   libc in `%install`: the static `ldconfig` (spec:1597), `localedef` through the new
   `ld.so` (spec:1630-1635, plus `install-locale-files` for 497 locales), and
   `bench-build`. On a pre-AVX2 builder, ld.so refuses with "CPU ISA level is lower
   than required". The spec's `cat /proc/cpuinfo` (spec:1218) shows what the
   nixbuild.net machine has.
6. **These are effectively required although not listed as unconditional
   BuildRequires:** `diffutils` (`diff` in `%prep` spec:1198 and `%install` spec:1479),
   `perl` (mtrace, spec:2339; and the manual), `util-linux` (`hardlink`, spec:1474),
   `gzip`, `/proc` mounted (`cat /proc/cpuinfo`, `/proc/meminfo`, and `df` under
   `sh -e`, spec:1218-1221), and `rpm -ql kernel-headers` working (spec:1822).
7. **Recommended stage0 invocation:** `rpmbuild --rebuild --nodeps --nocheck` with
   default bconds (never `--with bootstrap`),
   `--define 'dist .el10_2' --define 'rhel 10' --define 'el10 1'`,
   `--define "_smp_build_ncpus $NIX_BUILD_CORES"`, and `--undefine _annotated_build`
   only if annobin is not provided. Details are in §7.

---------------------------------------------------------------------------

## 1. Switches (`%bcond`, `%define`, `%global`) and their x86_64 / RHEL 10 values

### 1.1 bconds

| switch | spec line | default (x86_64, rhel10) | what it changes / needs |
|---|---|---|---|
| `testsuite` | 39 (`%bcond_without`) | **ON** | BuildRequires `gdb` (411-413). Without bootstrap it also adds `diffutils gcc-c++ libstdc++-static glibc-static libidn2 perl-interpreter` (449-468). Enables the whole `%check` body (1909-2014). Nothing else, so `--nocheck` and `--without testsuite` give identical binary outputs. |
| `benchtests` | 41 | **ON** | `make BENCH_DURATION=1 bench-build` in `%install` (1707-1725, serial with no `-j`). Produces `glibc-benchtests` (1105-1111, 2366-2369) in CRB. |
| `bootstrap` | 43 (`%bcond_with`) | **OFF** | If ON, it undefines benchtests, werror, docs and valgrind (71-77). It drops gd/libpng/zlib and libselinux BRs (393-400), passes `--without-selinux` (1365-1367), skips memusage/memusagestat in `%files utils` (2335-2338), and drops the sysroot package (1129-1142, 1780-1839, 2374-2377). **Do not use** because it changes the outputs. |
| `werror` | 45 | **ON** | If OFF: `--disable-werror` (1361-1363). glibc `Makeconfig:861` adds `-Werror` to `+gccwarn`. |
| `docs` | 47 | **ON** | `glibc-doc` noarch package (557-572, 2318-2322), BR `texinfo >= 5.0` (567). `%install` moves, gzips and copies info and docs (1603-1621, 1736-1740). If OFF, info files are deleted (1619-1620). |
| `valgrind` | 50-62 | **ON** (x86_64 is in `%valgrind_arches`, from redhat-rpm-config `macros.valgrind-srpm`: `%{ix86} x86_64 ppc ppc64 ppc64le s390x armv7hl aarch64`) | BR `valgrind` (415-419) and two smoke runs in `%check` (2000-2006). These run only if `%_enable_debug_packages` is set. If `%valgrind_arches` is undefined, which happens without redhat-rpm-config, it is silently OFF. |

### 1.2 Other defines that matter on x86_64

| macro | line | value | effect |
|---|---|---|---|
| `glibc_release_url` / `glibc_autorequires` | 13-26 | URL defined; autorequires **0** (version is not `.9000`) | `glibc.req`/`glibc.attr` are *not* generated or shipped (1493-1501, 2287-2290). |
| `_auto_set_build_flags` | 81 | undefined | rpm does not export CFLAGS/LDFLAGS. The spec builds its own flags (§2). |
| `man_pages_version` | 83 | `6.06-3.el10` | Only a string passed via `--with-man-pages=` (1371). |
| `Version`/`Release` | 142-144 | from `patch-git.lua` → `2.39` / `142%{?dist}` | **`%dist` must be `.el10_2`** to reproduce the NEVRA. See §3.1. |
| `glibc_ldso` | 292-297 | `/lib64/ld-linux-x86-64.so.2` | Used by the debuginfo wrapper (317-318), `%files` (2209: `%{_prefix}%{glibc_ldso}` = `/usr/lib64/ld-linux-x86-64.so.2`), and `%check`. |
| `glibc_has_libnldbl` / `glibc_has_libmvec` | 294-295 | 0 / 1 | libmvec ships (2225-2227, 2309-2311, 2329-2332). |
| `glibc_rtld_early_cflags` | 296 | `-march=x86-64` | `--with-rtld-early-cflags=-march=x86-64` (1406). This lets ld.so print the "CPU not supported" diagnostic on pre-v3 CPUs. |
| `buildpower10` | 64-69 | 0 | no power10 or hwcaps subdirectory build on x86_64. |
| `__debug_install_post` | 310-319 | rewritten to `bash wrap-find-debuginfo.sh $RPM_BUILD_ROOT /usr/lib64/ld-linux-x86-64.so.2 <original>` | §5 |
| `_binaries_in_noarch_packages_terminate_build` | 323 | 0 | needed for the noarch sysroot package. |
| `sysroot_dist` / `sysroot_package_arch` / `sysroot_prefix` | 325-332 | `el10` / `sysroot-x86_64-el10-glibc` / `/usr/x86_64-redhat-linux/sys-root/el10` | `%{?rhel}` must be 10. |
| `_no_recompute_build_ids` / `_unique_build_ids` | 336-337 | 1 / undefined | Build IDs are not seeded or recomputed (the wrapper relies on this). |
| `glibc_ship_tracelibs_in_utils` | 339-349 | 1 | **dead**: defined but never referenced. |
| `__filter_GLIBC_PRIVATE`, `__provides_exclude` | 472-473 | 1, `^libc_malloc_debug\.so.*$` | dependency generator filtering. |
| `enablekernel` | 430 | 3.2 | `--enable-kernel=3.2` (1334), `Conflicts: kernel < 3.2`, `%pre` kernel check (2017-2023). |
| `target` | 432 | `%{_target_cpu}-redhat-linux` = **`x86_64-redhat-linux`** | `--build=` (1355), build dir names (`build-x86_64-redhat-linux[-32]`). |
| `__brp_ldconfig` | 620 | undefined | `ldconfig -N -r` is run by hand (1597). |
| `locale_rx` | 639 | `eo syr tok *_*` | glob for locale dirs in `%install`. |
| `glibc_make_flags` | 1328-1329 | `ASFLAGS="-g -Wa,--generate-missing-build-notes=yes"` | Passed to every main `make` (1387) **unconditionally**, even without annobin. nixpkgs binutils 2.46 `as` accepts it (tested). |
| `glibc_sysroot` | 1432 | `$RPM_BUILD_ROOT` | install root. |

---------------------------------------------------------------------------

## 2. Build: flags, configure, make

### 2.1 How CFLAGS are derived from `%optflags` (spec:1223-1313)

The Lua block walks `%build_cflags` and keeps **only** the flags on three allow-lists:

* `cc_main` (1243-1267): `-march=*`, `-mtune=*` and `-mcpu=*` variants. These go into
  CC/CXX of the **main build only**.
* `cc` (1270-1274): `-m31 -m32 -m64`. These go into CC/CXX of every build.
* `cflags` (1277-1294): `-O2 -O3 -Wall -Wp,-D_GLIBCXX_ASSERTIONS
  -fasynchronous-unwind-tables -fno-omit-frame-pointer -fstack-clash-protection
  -funwind-tables -g -mbackchain -mbranch-protection=standard -mfpmath=sse
  -mno-omit-leaf-frame-pointer -msse2 -mstackrealign
  -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1`.

Rocky's `%build_cflags` on x86_64 with rhel 10 (evaluated with Rocky redhat-rpm-config 295):

```
-O2 -flto=auto -ffat-lto-objects -fexceptions -g -grecord-gcc-switches -pipe -Wall
-Werror=format-security -Wp,-U_FORTIFY_SOURCE,-D_FORTIFY_SOURCE=3 -Wp,-D_GLIBCXX_ASSERTIONS
-specs=/usr/lib/rpm/redhat/redhat-hardened-cc1 -fstack-protector-strong
-specs=/usr/lib/rpm/redhat/redhat-annobin-cc1 -m64 -march=x86-64-v3 -mtune=generic
-fasynchronous-unwind-tables -fstack-clash-protection -fcf-protection -mtls-dialect=gnu2
```

(`-march=x86-64-v3` comes from `%__cflags_arch_x86_64_level` = `-v3` for `rhel > 9`.
Frame pointers are off because `%_include_frame_pointers` is `rhel >= 11`.)

Result (from `rpmspec -P`):

```
glibc_flags_cc_main="-march=x86-64-v3 -mtune=generic"
glibc_flags_cc="-m64"
glibc_flags_cflags="-O2 -g -Wall -Wp,-D_GLIBCXX_ASSERTIONS -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1 -fasynchronous-unwind-tables -fstack-clash-protection"
BuildFlagsNonshared="-fplugin=annobin -fplugin-arg-annobin-disable -Wa,--generate-missing-build-notes=yes"   # only if 0%{?_annotated_build} > 0 (1315-1323)
```

**Dropped** from optflags: LTO (`-flto=auto -ffat-lto-objects`), `-fexceptions`,
`-grecord-gcc-switches`, `-pipe`, `-Werror=format-security`, `-D_FORTIFY_SOURCE=3`,
`redhat-hardened-cc1` (PIE specs), `-fstack-protector-strong`, `-fcf-protection` and
`-mtls-dialect=gnu2`. glibc re-adds the equivalents itself through configure:
`--enable-fortify-source`, `--enable-stack-protector=strong` and `--enable-cet`
(which gives `-fcf-protection=full`). PIE comes from glibc's own default-pie logic.
LDFLAGS from rpm are **not** used at all, because `_auto_set_build_flags` is undefined
and `%build_ldflags` is never referenced.

Confirmed against the official binary: the `DW_AT_producer` of `ld-linux-x86-64.so.2`
is `GNU C11 14.3.1 20251022 (Red Hat 14.3.1-4) -m64 -march=x86-64-v3 -mtune=generic
-mno-mmx -g -O2 -std=gnu11 … -fasynchronous-unwind-tables -fstack-clash-protection …
-fstack-protector-strong … -fcf-protection=full -ftls-model=initial-exec
-fplugin=gcc-annobin`. `.comment` is `GCC: (GNU) 14.3.1 20251022 (Red Hat 14.3.1-4)`.

### 2.2 `build()` and its three callers

`build()` (spec:1343-1389) does: `rm -rf $builddir; mkdir; pushd`, then

```
../configure "$@" \
    --prefix=/usr \
    --with-headers=/usr/include --enable-kernel=3.2 \
    --with-nonshared-cflags="$BuildFlagsNonshared" \
    --enable-bind-now \
    --build=x86_64-redhat-linux \
    --enable-stack-protector=strong \
    --enable-systemtap \
    --disable-profile \
    --with-man-pages=6.06-3.el10 \
    --disable-crypt \
    --disable-build-nscd --disable-nscd \
    --enable-fortify-source  || { cat config.log; false; }
env LDFLAGS.so="-Wl,--hash-style=both" LDFLAGS-rtld="-Wl,--hash-style=both" \
    make -O -j${RPM_BUILD_NCPUS} V=1 VERBOSE=1 -r ASFLAGS="-g -Wa,--generate-missing-build-notes=yes"
```

These conditionals do not fire on x86_64 or rhel10: `--disable-multi-arch` (ix86 only),
`--disable-werror`, `--without-selinux` (bootstrap) and `--enable-memory-tagging`
(aarch64).

`--with-headers=/usr/include` means the **kernel UAPI headers must live in
`/usr/include`** (`linux/`, `asm/`, `asm-generic/`). On Rocky these come from
`kernel-headers` (BR spec:525). The same directory serves the 32-bit build, since the
x86 `asm/` headers cover both ABIs.

Invocations:

1. **i686 / glibc32** (spec:1391-1399): `build build-x86_64-redhat-linux-32 CC="gcc -m32"
   CXX="g++ -m32" CFLAGS="${glibc_flags_cflags/-m64/-m32}" --host=i686-linux-gnu`.
   `glibc_flags_cflags` contains no `-m64`, so CFLAGS are unchanged, annobin specs
   included. Since `--build` and `--host` are both given and differ, autoconf sets
   `cross_compiling=yes`. glibc then runs no built programs for this tree, skips
   memusagestat, and falls back to the unprefixed `ar`, `ld` and so on. The 32-bit code
   uses gcc's *default* `-m32` arch: Rocky gcc is configured `--with-arch_32=x86-64`,
   nixpkgs gcc defaults to `x86-64` too. Configure still **links** a test program, so a
   32-bit libc, crt1.o, libgcc and libgcc_s must exist.
2. **main x86_64** (spec:1401-1410): `build build-x86_64-redhat-linux
   CC="gcc -m64 -march=x86-64-v3 -mtune=generic" CXX="g++ -m64 -march=x86-64-v3
   -mtune=generic" CFLAGS="$glibc_flags_cflags" --with-rtld-early-cflags=-march=x86-64
   --enable-cet`.
3. power10 variant (spec:1412-1420): ppc64le only.

There is **no** x86-64-v2/v3/v4 `glibc-hwcaps` sub-build on x86_64. The whole libc is
v3, with runtime IFUNC multiarch. `install_different` (spec:1515-1546) is used only for
power10.

### 2.3 Make targets used

* `make -r` (all), once per build dir: spec:1387.
* `make install install_root=$RPM_BUILD_ROOT` for the 32-bit tree (1445) and the main
  tree (1468).
* `make install-locale-files -C ../localedata objdir=$(pwd)` (1469-1470). This compiles
  **all 497 SUPPORTED locales** individually with `localedef --no-archive
  --no-hard-links`, run through the freshly built `ld.so` (`localedata/Makefile:525-565`).
* `make BENCH_DURATION=1 bench-build` (1710, **no `-j`**).
* `make check` (1920, `%check` only).

---------------------------------------------------------------------------

## 3. Every external tool and hard-coded path, by phase

### 3.1 Spec parse time (before `%prep`): Lua

* `patch-git.lua` (spec:142-144, 235, 2390) is `dofile`d from `%_sourcedir`. Under rpm,
  `generate_files()` (patch-git.lua:493-551) runs `git` **only if** `/usr/bin/git` is
  executable **and** `%_sourcedir/.git` exists. Otherwise it reads the shipped
  `patch-git-generated-commit.txt`, `patch-git-generated-log.txt` (2030 commits) and
  `patch-git-override.txt`. It asserts if the commit file is missing. This is safe in a
  clean topdir: **do not** put `%_sourcedir` inside a git checkout dir named exactly
  `SOURCES/.git`.
* It emits `Version: 2.39`, `Release: 142%{?dist}`, the 675 `Patch:` lines (379
  `glibc-RHEL-*`, 283 `glibc-upstream-2.39-*`, a handful of Fedora/RH ones), and extra
  `Source:` lines `auto-generated/patch-git-generated-{commit,log}.txt`,
  `patch-git.lua` and `patch-git-override.txt`. rpm uses basenames, so
  `--rebuild` works. Uses rpm's built-in Lua `posix` module (`posix.access`).
* The changelog is generated by `patchgit.changelog()`. The top entry is
  `Mon Sep 14 2026 … 2.39-142`, which determines `SOURCE_DATE_EPOCH` when
  `%source_date_epoch_from_changelog 1`, as Rocky redhat-rpm-config sets
  (`macros:22-23`, also `%clamp_mtime_to_source_date_epoch`).
* `%make_build` itself contains a `%(…)` shell expansion that runs
  `make --version -O` (seen in rpmspec), so `/bin/sh` and `make` are needed at parse
  time.

### 3.2 `%prep` (spec:1173-1207)

| line | command | tool |
|---|---|---|
| 1174 | `%autosetup -n glibc-2.39 -p1` | `xz`/`tar` (via rpmuncompress), **GNU `patch`** (`-p1 -s --fuzz=0 --no-backup-if-mismatch -f`) for 675 patches. Some are git-style with renames, deletes or symlinks; `patch` ≥ 2.7 handles them. There is no "GIT binary patch". |
| 1180 | `chmod +x benchtests/scripts/*.py scripts/pylint` | coreutils |
| 1183 | `find . -type f -size 0 -o -name "*.orig" -exec rm -f {} \;` | findutils. Because of operator precedence only `*.orig` files are removed. |
| 1187 | ``touch `find . -name configure` `` | stops configure regeneration (no autoconf needed) |
| 1190 | `touch locale/programs/*-kw.h` | stops gperf regeneration |
| 1195-1201 | Lua `print_locale_pairs()` → file; **`python3 parse-SUPPORTED.py localedata/SUPPORTED`**; **`diff -u`** | python3 (`/usr/bin/python3` shebang, but invoked as `python3` from PATH), **diffutils** |
| 1204-1207 | `cp verify-ld-so-abi.sh`, `cp %{_sourcedir}/*.baseline .` | |

### 3.3 `%build` (spec:1212-1420)

* System logging: `uname -a`, `LD_SHOW_AUXV=1 /bin/true` (**needs `/bin/true`**),
  `ld.so --list-diagnostics || true`, `ld.so --list-tunables || true`,
  **`cat /proc/cpuinfo`**, `cat /proc/sysinfo 2>/dev/null || true`,
  **`cat /proc/meminfo`**, **`df`** (spec:1214-1221). rpm runs build scripts with
  `/bin/sh -e` (`%___build_args -e`), so a missing `/proc`, or a `df` that exits
  non-zero because some mount cannot be stat'ed, **fails the build**.
* configure needs: `gcc`; `g++` (optional, see §7.2); `make ≥ 4` (critic);
  `gawk ≥ 3.1.2` (critic); `bison ≥ 2.7` (critic); `python3 ≥ 3.4` (critic);
  `sed`, `msgfmt` and `makeinfo` (aux: missing ones are silently disabled, then
  `%files` breaks); `perl` (`AC_PATH_PROG`, feeds mtrace); `bash` (`AC_PATH_PROG`,
  build-time only); `install-info` (detected, not used in install_root installs);
  binutils `as`, `ld`, `ar`, `nm`, `objcopy`, `objdump`, `readelf`, `ranlib`;
  `sys/sdt.h` (hard failure with `--enable-systemtap`: `configure.ac:313-327`);
  libselinux (auto, `configure.ac:1465-1496`; if found it also probes libaudit and
  libcap); libgd, libpng and zlib (auto, `configure.ac:1450-1462`).
* **Absolute paths captured by configure and embedded in installed files:**
  `PERL` → `#! @PERL@` / `exec @PERL@` in `/usr/bin/mtrace` (malloc/Makefile:307).
  PATH inside the chroot must resolve `perl` to `/usr/bin/perl`, otherwise a
  `/nix/store/…/perl` shebang ships. `brp-mangle-shebangs` only rewrites
  `/bin`→`/usr/bin` and `env`, not store paths. The other installed scripts (`ldd`,
  `sotruss`, `xtrace`, `memusage`, `tzselect`) have a literal `#!/bin/bash` in the
  source, which brp-mangle-shebangs turns into `/usr/bin/bash` (glibc-common Requires
  `/usr/bin/bash`).

### 3.4 `%install` (spec:1426-1904)

| lines | what | tools / assumptions |
|---|---|---|
| 1436-1440 | create `$RPM_BUILD_ROOT/{bin,lib,lib64,sbin}` → `usr/*` symlinks (UsrMove), removed again at 1772-1774 | ln |
| 1442-1464 | 32-bit `make install`, then `rm -rf etc var usr/bin usr/lib/gconv usr/libexec usr/sbin usr/share`, `strip -g usr/lib/*.o`, `strip` of `.so` files, `cp -a` the headers aside | **binutils `strip` must handle elf32-i386** (nixpkgs x86_64 binutils does) |
| 1466-1471 | main `make install`; `make install-locale-files` (all 497 locales) | runs built `localedef` via built `ld.so` (needs a v3 CPU) |
| 1474 | **`hardlink -c /usr/lib/locale`** | **util-linux `hardlink`** (`-c` = `--content`); nixpkgs util-linux has it |
| 1476-1491 | `diff -ur` of 64-bit vs 32-bit headers: anything other than "Only in" fails the build | **diffutils** |
| 1572-1585 | rm libNoVersion, old nss, `sln` | |
| 1593-1597 | `truncate`; **`$RPM_BUILD_ROOT/sbin/ldconfig -N -r $RPM_BUILD_ROOT`** (the new static ldconfig, built for v3) | coreutils `truncate` |
| 1603-1617 | docs: move info, **`gzip -9nvf`** the info files, cp `rtld-debugger-interface.txt` and `gai.conf` | gzip |
| 1627-1678 | **locale archive**: `rm locale-archive`; `build/elf/ld.so --library-path build/ build/locale/localedef --alias-file=intl/locale.alias --prefix $RPM_BUILD_ROOT --add-to-archive eo syr tok *_*`; `ln locale-archive locale-archive.real` (hard link); then replace `LC_CTYPE`, `LC_NAME` and `LC_NUMERIC` copies that are `-samefile` with `C.utf8` by symlinks `../C.utf8/LC_*`; then generate `langpack-<lang>.filelist` (206 lists) from the `/usr/lib/locale` dirs and `share/locale/*/LC_MESSAGES/libc.mo` | find (`-samefile`), built localedef |
| 1685-1705 | write `/etc/ld.so.conf` (`include ld.so.conf.d/*.conf`), empty `ld.so.cache`, `gai.conf`, `gconv-modules.cache`; `touch -r %{SOURCE0} /etc/ld.so.conf`; `touch -r inet/etc.rpc /etc/rpc` | |
| 1707-1725 | benchtests: `make BENCH_DURATION=1 bench-build` (serial); `cp $(find build/benchtests -type f -executable)` plus `bench.mk`, `glibc-bench-compare` and 4 python scripts to `/usr/libexec/glibc-benchtests` | python3 (generates bench sources) |
| 1729-1734 | symlink `.gperf` files for debugsource | |
| 1743-1746 | rm `libc_malloc_debug.so`; `strip -g /usr/lib64/*.o` | binutils |
| 1751-1760 | sed `$LIB` paths in `xtrace` and `memusage` | |
| 1767 | `ar cr libpthread_nonshared.a` (empty) | binutils `ar` |
| 1780-1839 | sysroot package: copy headers (minus `gnu/*-32.h`), lib64 files and symlinks into `/usr/x86_64-redhat-linux/sys-root/el10/usr/`; **`rpm -ql kernel-headers \| grep ^/usr/include \| while read f; do install -D "$f" "./$f"; done`** (1822-1826); `chmod a-x` everything; sed `lib[cm].so` linker scripts | **queries the buildroot rpmdb.** With `--nodeps` and nixpkgs headers not in the rpmdb, `rpm -q` prints "package kernel-headers is not installed" to stdout, grep drops it, and without `pipefail` the pipeline still succeeds. The **sysroot package then silently lacks kernel headers.** That package is not shipped in the repos, so this is cosmetic. |
| 1854-1904 | `LC_ALL=C`; `find -printf`, `sort`, `comm`, `grep -E`, `tr` build `glibc.filelist` and `gconv-extra.filelist` | findutils, coreutils, grep |

Hard-coded FHS assumptions: `/bin/true` (1215, 1993), `/usr/bin/true` and
`/usr/bin/valgrind` (2001-2005), `/usr/lib/rpm/redhat/redhat-annobin-cc1` (via
optflags), and `/usr/lib/rpm/debugedit` as a fallback (wrapper:33).
`/usr/include` (`--with-headers`) and `/usr/lib/gcc/...` are where gcc's own include
dir is expected to resolve.

### 3.5 `%check` (spec:1909-2014; skipped with `--nocheck`)

* `make -j check` with `TIMEOUTFACTOR=16`. `allowed-failures-{noarch,x86_64}.txt` is
  copied into the tree (1962-1964). The tests need `gcc-c++`, `libstdc++-static`,
  `glibc-static` (static C++ tests), `perl` (`tst-mtrace`), `python3`
  (`tst-*-consts.py`), `libidn2` (AI_IDN), `gdb` (pretty-printer tests), the kernel
  namespaces used by `test-container`, and `ps`/`kill`/`awk` (procps-ng, util-linux,
  gawk).
* `readelf -Wr` on `ld-*.so` and `libc-*.so` (1984-1986). These glob patterns no longer
  match modern names; the output is informational.
* `LD_SHOW_AUXV=1 $run_ldso /bin/true`.
* valgrind smoke tests (2000-2006), only if `%_enable_debug_packages` is set.
* `./verify-ld-so-abi.sh x86_64 $RPM_BUILD_ROOT/usr/lib64/ld-linux-x86-64.so.2`
  (2010-2012). It runs **`gdb -batch -ex "ptype/o _rtld_global_ro"`** (and others)
  against the installed ld.so, which still has its DWARF because of the wrapper, and
  `diff`s the result against `ld-so-abi-x86_64.baseline`. The output depends on the
  gdb version's `ptype/o` formatting (Rocky gdb 16.3 vs nixpkgs gdb 17.2) and on
  identical struct layout. It is a likely false failure in stage0.

### 3.6 Scriptlets (install time; they do **not** run in `rpmbuild`)

All are `-p <lua>`, so no shell is needed at install:

* `%pre` (2017-2100): kernel version ≥ 3.2 via `posix.uname`; delete stale
  `%{_libdir}/{i686,power*,glibc-hwcaps/*}` copies of core libraries.
* `%post` (2102-2171): ensure `/etc/ld.so.conf` has the include line;
  `/usr/sbin/ldconfig`; `/usr/sbin/iconvconfig -o …/gconv-modules.cache --nostdlib
  /usr/lib64/gconv`; on upgrade, `systemctl daemon-reexec`.
* `%posttrans all-langpacks` (2173-2195): restore the `locale-archive` ↔
  `locale-archive.real` hard link.
* `%post`/`%postun gconv-extra` (2197-2203): `iconvconfig`.
* `%transfiletriggerin`/`postun common` (605-613): `ldconfig` whenever files appear in
  `/lib /usr/lib /lib64 /usr/lib64`.

For Nix `rpmTree` extraction: the shipped `ld.so.cache`, `gconv-modules.cache`,
`aux-cache` and `gai.conf` are **empty or `%ghost`**, and nothing regenerates them
unless the `%post` logic is replayed. glibc copes: an empty or invalid gconv cache
falls back to parsing `gconv-modules`.

---------------------------------------------------------------------------

## 4. Locales and langpacks (time cost)

* The 206 langpack subpackages are generated by Lua from the in-spec `locales` table
  (spec:641-1000). `%prep` checks the table against `localedata/SUPPORTED`
  (1192-1201).
* Locale data is compiled twice:
  1. `install-locale-files` (1469-1470): 497 `localedef` invocations producing
     `/usr/lib/locale/<locale>/LC_*` directories, deduplicated with `hardlink -c`
     (1474). These directories are what the `glibc-langpack-*` packages ship.
  2. `localedef --add-to-archive` over the same directories (1630-1635), producing
     `locale-archive` (about 220 MB uncompressed; `glibc-all-langpacks` RPM is
     19.1 MB compressed). It is single-threaded.
  3. Then `LC_CTYPE`, `LC_NAME` and `LC_NUMERIC` are replaced by symlinks to
     `C.utf8` (1650-1656), and the filelists are generated (1659-1678).
* Estimated cost (not yet measured on nixbuild): locale compilation is roughly
  15-25 CPU-minutes, so about 8-12 minutes wall time at `-j2`, plus a few serial
  minutes for the archive. Two full glibc builds (i686 + x86_64) are probably
  30-60 minutes at 2 cores. `bench-build` is serial. Debuginfo extraction of the
  roughly 200 MB `/usr/lib/locale` tree only scans ELF, so it is quick. **`%check`
  would add hours**, which is the main reason to use `--nocheck`.

---------------------------------------------------------------------------

## 5. Debuginfo quirks

* `__debug_install_post` is replaced (spec:310-319) by
  `bash wrap-find-debuginfo.sh $RPM_BUILD_ROOT /usr/lib64/ld-linux-x86-64.so.2 <original find-debuginfo command>`.
  The original command is Rocky's `/usr/bin/find-debuginfo -j… --strict-build-id -m -i
  --build-id-seed … --unique-debug-suffix … --unique-debug-src-base … -S
  debugsourcefiles.list <builddir>`. With annobin it adds `%_find_debuginfo_extra_opts`
  = `--remove-section .gnu.build.attributes` (redhat-rpm-config `macros:360`).
  `%_include_minidebuginfo 1`, `%_debugsource_packages 1` and
  `%_debuginfo_subpackages 1` are set (redhat-rpm-config `macros:26-29`).
* What `wrap-find-debuginfo.sh` does, by line:
  * 18-61: `mktemp -d`; save copies of ld.so and of every `libc.so.6` in the root.
  * 64: run find-debuginfo.
  * 66-95, for libc.so.6: extract `.gnu_debuglink` with `objcopy -O binary`, restore
    the **unstripped original**, `objcopy --merge-notes`, re-add `.gnu_debuglink`,
    then `strip -w -K '*' -K '!*.c' -K '!*.os' -K '!.annobin_*' -K '!__EI_*'
    -K '!__PRETTY_FUNCTION__*'`. Result: **libc.so.6 ships with a `.symtab`** (minus
    file, annobin and `__EI_` symbols) but no DWARF. Confirmed in the official RPM:
    `.symtab`, `.annobin.notes`, `.note.stapsdt`, `.gnu.build.attributes` and
    `.gnu_debuglink` are present.
  * 97-123, for ld.so: restore the original, `objcopy --merge-notes`, and delete the
    `ld*.so*.debug` files that find-debuginfo produced. **ld.so ships with full DWARF
    and `.symtab`**. Confirmed: the official `ld-linux-x86-64.so.2` has `.debug_info`,
    `.debug_line`, `.debug_str`, `.debug_line_str`, `.debug_loclists`,
    `.debug_rnglists` and `.symtab`.
  * 125-146: `debugedit -b <builddir> -d /usr/src/debug/glibc-2.39-142.el10_2.x86_64 -n
    ld.so` rewrites source paths. **Only the build dir prefix is rewritten**, so system
    include dirs stay as they are. The official DWARF dirs are
    `/usr/src/debug/glibc-…`, `/usr/include` and `/usr/lib/gcc/x86_64-redhat-linux/14`.
  * 147-151: strip `.annobin*` symbols with `nm --format=posix | grep` and
    `objcopy --strip-symbols`.
  * 154: **`dwz ld.so`**.
  * Tools used: `bash`, `mktemp`, `readlink -f`, `find` (`-regextype posix-extended`),
    binutils `objcopy`, `strip` and `nm`, `cut`, `grep`, `debugedit` (PATH, or
    `/usr/lib/rpm/debugedit`), `dwz`. find-debuginfo also needs elfutils (`eu-strip`,
    `eu-elfcompress`), `xz` (minidebuginfo, `-m`), `cpio`, and `gdb-add-index` if gdb
    index is enabled.
* `_no_recompute_build_ids 1` and `_unique_build_ids` undefined (336-337): the wrapper
  depends on debugedit not changing build IDs.
* Expected debug packages (`rpmspec` with full macros; `_debuginfo_subpackages 1`):
  `glibc-debuginfo` and `glibc-debugsource`, plus per-subpackage `*-debuginfo` for
  subpackages with unstripped ELF, such as glibc-common, glibc-utils,
  glibc-benchtests, glibc-gconv-extra, nss_db, nss_hesiod and libnsl. The debug repos
  were not available here, so this exact set is unverified.
* **rpm 4.20 (nixpkgs) vs 4.19.1.1 (Rocky):** 4.20 introduced `%{builddir}`
  (`BUILD/glibc-2.39-build/glibc-2.39`) and passes it to find-debuginfo. That changes
  debugsource layout and possibly the DWARF comp_dir relative to Rocky's 4.19 build.
  The lock also has `rpm-4.19.1.1-23.el10` for fidelity later.

---------------------------------------------------------------------------

## 6. Binary packages produced (x86_64)

`rpmspec -q` gives **226 packages** with Rocky macros: 20 named packages plus 206
langpacks, before per-subpackage debuginfo. The official repos ship **221** packages
built from `glibc-2.39-142.el10_2.src.rpm`: 220 x86_64 and 1 noarch. **No i686
packages exist; RHEL 10 has no multilib repos.**

| repo | package | arch | pkg size (bytes) |
|---|---|---|---|
| BaseOS | glibc | x86_64 | 2179600 |
| BaseOS | glibc-common | x86_64 | 318475 |
| BaseOS | glibc-all-langpacks | x86_64 | 19135556 |
| BaseOS | glibc-minimal-langpack | x86_64 | 28501 |
| BaseOS | glibc-gconv-extra | x86_64 | 1602619 |
| BaseOS | libnsl | x86_64 | 71211 |
| BaseOS | glibc-langpack-* (**206**: `glibc-langpack-aa`, `-af`, `-agr`, `-ak`, `-am`, … `-zh`, `-zu`) | x86_64 | |
| AppStream | glibc-devel | x86_64 | 482685 |
| AppStream | glibc-doc | **noarch** | 1143882 |
| AppStream | glibc-locale-source | x86_64 | 4242540 |
| AppStream | glibc-utils | x86_64 | 77349 |
| CRB | glibc-static | x86_64 | 1674182 |
| CRB | glibc-benchtests | x86_64 | 2545676 |
| CRB | glibc-nss-devel | x86_64 | 29432 |
| CRB | nss_db | x86_64 | 51126 |
| CRB | nss_hesiod | x86_64 | 41978 |

Built but **not shipped** in the BaseOS, AppStream or CRB os repos:
`compat-libpthread-nonshared` (x86_64), `sysroot-x86_64-el10-glibc` (noarch) and
`glibc32` (x86_64, "only for use in building GCC", spec:1144-1168). Debuginfo and
debugsource packages go to the separate debug repos.

External runtime dependencies from repodata show which optional build inputs matter
for fidelity:

* `nss_db` requires `libselinux.so.1(LIBSELINUX_1.0)`, because `makedb` is linked
  with `-lselinux` when libselinux is found (`nss/Makefile:446-447`).
* `glibc-utils` requires `libgd.so.3`, `libpng16.so.16` and `libz.so.1`
  (`memusagestat`), plus `/usr/bin/perl` (mtrace) and `/usr/bin/bash`.
* `glibc-benchtests` requires `/usr/bin/python3`.
* `glibc-common` requires `/usr/bin/bash`.
* `glibc-devel` requires `kernel-headers` and `libxcrypt-devel`.

---------------------------------------------------------------------------

## 7. Recommended stage0 rpmbuild invocation

### 7.1 Command

```sh
rpmbuild --rebuild \
  --nodeps \                                  # stage0: nixpkgs tools are not in the rpmdb (DESIGN.md)
  --nocheck \                                 # skip %check (spec:1909-2014): hours long, needs gdb/valgrind/static C++/
                                              #   libidn2/test-container namespaces; verify-ld-so-abi depends on gdb output format
  --define '_topdir /builddir/build' \
  --define 'dist .el10_2' \                   # Release = 142%{?dist} from patch-git (spec:144)
  --define 'rhel 10' --define 'el10 1' \      # normally from rocky-release macros.dist; drives -march=x86-64-v3,
                                              #   sysroot-…-el10-… name (spec:326), x86-64-v3 in redhat-rpm-config
  --define "_smp_build_ncpus ${NIX_BUILD_CORES}" \  # %make_build uses -j${RPM_BUILD_NCPUS} (= %_smp_build_ncpus);
                                              #   defining only %_smp_mflags would not reach %make_build in rpm 4.20
  [--undefine _annotated_build] \             # ONLY if no annobin plugin usable by the stage0 gcc (see §8.2)
  glibc-2.39-142.el10_2.src.rpm
```

* **Keep every bcond at its default.** `testsuite` and `valgrind` only affect
  BuildRequires and `%check` (§1.1). With `--nodeps --nocheck` they change nothing in
  the binary RPMs. Passing `--without testsuite` would change the BuildRequires of the
  re-emitted `.src.rpm` relative to the official one, so do not pass it in stage0.
  Consider it in stage1 if `glibc-static`/`libstdc++-static`/`gdb`/`valgrind` are not
  yet built, because `glibc-static` is a BuildRequires cycle on itself (spec:460).
* **Never `--with bootstrap`.** It drops memusage/memusagestat from glibc-utils, drops
  selinux from makedb, drops the sysroot package, and disables docs and benchtests
  (spec:71-77, 393-400, 1365-1367, 2335-2338).
* `--without benchtests` and `--without docs` are acceptable shortcuts only for
  iteration speed. They remove `glibc-benchtests` (CRB) and `glibc-doc` (AppStream).
* `--without werror` is the fallback if gcc 14.4 or binutils 2.46 introduce a new
  warning (§8.4).
* Reproducibility macros from DESIGN.md (`SOURCE_DATE_EPOCH`,
  `%use_source_date_epoch_as_buildtime`, `%clamp_mtime_to_source_date_epoch`) are
  compatible. redhat-rpm-config already sets `%source_date_epoch_from_changelog 1`.

### 7.2 Which BuildRequires are really needed with `--nocheck` and default bconds

| BuildRequires (spec line) | needed? | justification |
|---|---|---|
| `gcc >= 7.2.1-6` (429) | **yes, multilib** | 64-bit and `-m32` builds (1391-1410). Needs 32-bit libgcc.a, libgcc_eh.a, crtbegin*.o and libgcc_s, plus a 32-bit libc and crt1.o for configure's link test. |
| `binutils >= 2.30-17` (444) | **yes** | `--generate-missing-build-notes` (1322, 1328), strip, ar, objcopy, nm |
| `make >= 4.0` (438) | **yes** | `-O`, critic in configure |
| `bison >= 2.7` (441) | **yes** | critic in configure (`configure.ac:531`) |
| `gawk` (408) | **yes** | critic in configure (`configure.ac:528`) |
| `sed >= 3.95` (401) | **yes** | configure and `%install` |
| `python3` (426) | **yes** | critic in configure (`configure.ac:568`), `%prep` parse-SUPPORTED.py (1197), benchtests |
| `python3-devel` (426) | no | only there to guarantee `/usr/bin/python3` (comment 421-425) |
| `gettext` (401) | **yes** | `msgfmt` builds `libc.mo`; if it is missing the `%files all-langpacks` glob `share/locale/*/LC_MESSAGES/libc.mo` (2279) fails |
| `texinfo >= 5.0` (567, docs) | **yes** (docs ON) | `makeinfo`; otherwise `%files doc` `%{_infodir}/*.info*` (2321) fails |
| `perl-interpreter` (466, testsuite-only BR) | **yes in practice** | mtrace is installed only `ifneq ($(PERL),no)` (malloc/Makefile:208); `%files utils` lists `/usr/bin/mtrace` (2339) unconditionally. The manual summary also needs perl. In Koji it arrives through texinfo. |
| `diffutils` (451, testsuite-only BR) | **yes in practice** | `diff -u` in `%prep` (1198) and `diff -ur` in `%install` (1479) are unconditional |
| `util-linux` (408) | **yes** | `hardlink -c` (1474) |
| `procps-ng` (408) | no | `ps` is used by tests only |
| `kernel-headers >= 3.2` (525) | **yes** | `--with-headers=/usr/include` (1352). Sysroot copy needs `rpm -ql kernel-headers` (1822). |
| `systemtap-sdt-devel` (409) | **yes** | `--enable-systemtap` fails hard without `sys/sdt.h` (`configure.ac:313-327`); probes are in `.note.stapsdt` of libc.so.6 and ld.so. nixpkgs: `systemtap-unwrapped` has `include/sys/sdt.h` (5.4, same as Rocky's 5.4-3); `systemtap-sdt` does **not**. |
| `gd-devel libpng-devel zlib-devel` (394) | **yes for fidelity** | memusagestat is built only if libgd links (`configure.ac:1450-1462`, malloc/Makefile:224-239). `%files utils` lists `/usr/bin/memusagestat` (2337) when bootstrap is off, so the build **fails** without gd. Note that `memusagestat.o` is compiled with *system* headers (`sysincludes = # nothing`, malloc/Makefile:238), so in stage0 it would see nixpkgs glibc-2.44 headers. |
| `libselinux-devel` (399) | **yes for fidelity** | makedb links `-lselinux` (`nss/Makefile:446`); official nss_db requires `libselinux.so.1`. Omitting it builds fine but changes nss_db. |
| `audit-libs-devel`, `libcap-devel` (401) | **no** | Probed only when selinux is found. Used only by nscd (`nscd/Makefile:52-61`, disabled by `--disable-nscd`) and pt_chown (not built: no `--enable-pt_chown`). `HAVE_LIBAUDIT`/`HAVE_LIBCAP` appear only in `nscd/*.c` and `login/programs/pt_chown.c`. |
| `gdb` (412) | no | `%check` only (verify-ld-so-abi.sh, pretty-printer tests) |
| `valgrind` (418) | no | `%check` only |
| `gcc-c++` (454) | no | `configure.ac:56-81` sets `CXX=` if g++ cannot link **dynamic and static** C++. CXX only affects tests and `support/links-dso-program` (test infrastructure). |
| `libstdc++-static`, `glibc-static` (455, 460) | no | Only for configure's static C++ link check (comment 452-460), which only gates tests |
| `libidn2` (463) | no | AI_IDN tests only |
| implicit (Koji buildsys group) | **yes** | bash, coreutils, findutils, grep, gzip, tar, xz, GNU patch, rpm-build, redhat-rpm-config (brp-*, specs files), debugedit (find-debuginfo), dwz, elfutils, cpio, `file`. Also `/bin/true` and `/usr/bin/true`, a mounted `/proc`, and a working `df`. |

---------------------------------------------------------------------------

## 8. Hazards with non-Red-Hat GCC 14.4 (nixpkgs) and binutils 2.46

### 8.1 Multilib (blocker)
See TL;DR 1. nixpkgs `gcc14` is `--disable-multilib`. `wrapCCMulti gcc14` (14.4.0)
is not substituted from cache.nixos.org. `gcc_multi` (15.3.0) is cached, but it is
gcc 15 and should not be mixed with the gcc14 used for the main build. There is no
`%bcond` that skips the 32-bit build; the only spec-free way around it would be
`--target x86_64_v3`-style tricks, and those break `%ifarch x86_64` elsewhere and the
`--build` triple. **Plan to build multilib gcc14** in stage0.

### 8.2 annobin (blocker unless handled)
* `-specs=/usr/lib/rpm/redhat/redhat-annobin-cc1` is in CFLAGS for all builds
  (spec:1293 via `%build_cflags`). Its content:
  `*cc1_options: + %{!-fno-use-annobin:%{!iplugindir*:%:find-plugindir()} -fplugin=annobin}`.
  nixpkgs gcc 14.4 accepts the `find-plugindir()` spec function, then dies because
  `annobin.so` is not in its read-only store plugin dir.
* `BuildFlagsNonshared` (spec:1322) passes `-fplugin=annobin` **directly**. It is used
  for `libc_nonshared.a` objects through `--with-nonshared-cflags`, and is only set
  when `0%{?_annotated_build} > 0`.
* Rocky's file layout: the official build used the gcc-built plugin
  (`-fplugin=gcc-annobin` in `DW_AT_producer`, chosen by
  `redhat-annobin-plugin-select.sh`).
* Option A: `--undefine _annotated_build`. Then `%build_cflags` has no annobin specs,
  `BuildFlagsNonshared` stays empty and `%_find_debuginfo_extra_opts` is empty.
  `ASFLAGS=-Wa,--generate-missing-build-notes=yes` is still passed (spec:1328), and
  that works with binutils 2.46. Output loses `.annobin.notes` and annobin
  `.gnu.build.attributes`. Verify that `--undefine` takes effect *after* the macro
  files load: `rpm --undefine _annotated_build --eval '%{?_annotated_build}'` should be
  empty. Note that `%define _annotated_build %{nil}` is **wrong**, because
  `%{?_annotated_build:…}` still fires for a defined-but-empty macro.
* Option B: build the `annobin` SRPM (already in the lock) against the stage0 gcc and
  make `-iplugindir=<dir>` reach every compile through the stage0 gcc driver config,
  so that both the specs path and the bare `-fplugin=annobin` resolve. The annobin
  plugin is sensitive to the exact gcc version it was built against
  (redhat-annobin-plugin-select.sh explains why).

### 8.3 Compiler and linker wrappers, and store-path leakage (blocker for `allowedReferences`)
* nixpkgs cc-wrapper always adds `-fno-omit-frame-pointer -mno-omit-leaf-frame-pointer
  -mtls-dialect=gnu2` before user flags, and `-B/-L <glibc-2.44>`,
  `-idirafter <glibc-2.44-dev>/include`, `-B <gcc-lib>` and
  `-Wl,-dynamic-linker=<glibc-2.44>/lib/ld-linux-x86-64.so.2` (verified with
  `NIX_DEBUG=1`, hardening flags all off).
  * Frame pointers and gnu2 TLS change glibc's code. RHEL 10 has neither: the spec's
    inherit list deliberately excludes `-mtls-dialect=gnu2` (1277-1294), and frame
    pointers are off for rhel ≤ 10.
  * `-dynamic-linker` is overridden for glibc's own programs, because glibc appends
    `-Wl,-dynamic-linker=/lib64/ld-linux-x86-64.so.2` later (`Makeconfig:556-560`).
  * The ld-wrapper's automatic `-rpath` for `/nix/store` `-L` dirs would leak into
    `memusagestat` (`-lgd -lpng -lz`) and anything linked with `-lgcc_s`. Use
    **unwrapped** gcc and binutils (`gcc14.cc`, `binutils-unwrapped`) behind an
    FHS-aware stage0 driver, or set `NIX_DONT_SET_RPATH=1` and
    `NIX_HARDENING_ENABLE=` and strip the wrapper's cflags.
* With gcc living in /nix/store, **`ld.so`'s retained DWARF** records gcc's internal
  include dir. The official one records `/usr/lib/gcc/x86_64-redhat-linux/14`.
  debugedit does not rewrite it (wrapper:146 rewrites only the build dir). Result: a
  `/nix/store/<hash>-gcc-14.4.0/lib/gcc/...` string in `/usr/lib64/ld-linux-x86-64.so.2`
  in the **`glibc`** RPM. Fixes: install gcc's tree at an FHS path (bind mount or copy;
  a symlink does not work because gcc realpaths its own location), or have the stage0
  driver add `-ffile-prefix-map=<gcc-prefix>=/usr`. The same applies to any libgcc.a
  objects pulled into ld.so whose DWARF mentions store paths. Debuginfo RPMs will
  contain more of these: either do not run `rpmTree` with `allowedReferences = []` on
  `*-debuginfo`, or map all store prefixes.
* PATH must resolve `perl` to `/usr/bin/perl` (mtrace shebang, §3.3). Prefer PATH
  `/usr/bin:/usr/sbin` only, with no store dirs.
* nixpkgs rpm's built-in macros point at the store. `rpmspec -P` with nixpkgs rpm
  showed `--prefix=/nix/store/…-rpm-4.20.1` and `/nix/store/…/gnumake/bin/make`. The
  stage0 rpm config must set the FHS `%_prefix`, `%_libdir`, `%__make` and so on,
  which is what DESIGN.md's "config dir is `/usr/lib/rpm`" intends. Verify with
  `rpm --eval '%_prefix %_libdir %__make %_target_platform'` → `/usr /usr/lib64 /usr/bin/make x86_64-redhat-linux`.

### 8.4 -Werror (`werror` bcond ON, `Makeconfig:861`)
Rocky builds this exact source with gcc 14.3.1 and binutils 2.41. gcc 14.4.0 is a
same-branch bugfix release, so new C warnings under `-Wall -Werror` are unlikely but
not impossible. binutils 2.46 is five releases newer. Linker warnings are not turned
into errors by `-Werror` (glibc does not pass `--fatal-warnings` to ld), but configure
probes such as `LIBC_LINKER_FEATURE` see the new ld. Untested; the first build will
tell. The escape hatch is `--without werror` (spec:1361-1363).

### 8.5 Vendor triple and compiler identity
* `--build=x86_64-redhat-linux` (spec:1355; `%{_target_cpu}-redhat-linux`, spec:432)
  is passed regardless of the compiler's own triple: nixpkgs gcc reports
  `x86_64-unknown-linux-gnu`. glibc canonicalises it to `x86_64-redhat-linux-gnu` and
  probes for `sysdeps/…/redhat` dirs (none exist). `AC_CHECK_TOOL` tries
  `x86_64-redhat-linux-ar` and so on first, then falls back to plain names. CC is
  given explicitly, so no `x86_64-redhat-linux-gcc` is needed.
* The 32-bit build uses `--host=i686-linux-gnu`. Unprefixed `ar`, `ld` and `as` must
  handle 32-bit objects, which nixpkgs x86_64 binutils do.
* No vendor check of gcc exists. configure only requires `__GNUC__ >= 6.2`
  (`configure.ac:534-543`). `.comment` will read `GCC: (GNU) 14.4.0` instead of
  `… (Red Hat 14.3.1-4)`.
* Rocky gcc is configured `--with-arch_64=x86-64-v3 --with-arch_32=x86-64
  --with-tune=generic --enable-cet --enable-host-pie` (gcc.spec:1530-1545), and is
  *not* `--enable-default-pie`. nixpkgs gcc14 defaults to `-march=x86-64
  -mtls-dialect=gnu2` and `--enable-default-pie`. For the main build `-march` is
  explicit; for glibc32 both default to `x86-64`. Any default-PIE difference only
  matters to glibc configure probes. glibc builds its own PIE and static-pie decisions
  (`configure.ac:187`, 1254-1259, 1712-1732), but note the difference when comparing
  output.

### 8.6 Header and library mix in stage0
* `memusagestat.o` uses system headers (malloc/Makefile:238), which would be nixpkgs
  glibc-2.44 headers, and is linked against the new 2.39 libc. If 2.44 headers
  redirect a call to a symbol version newer than 2.39, the link fails. This is
  unlikely with gnu17 defaults, but it is a known class of stage0 failure.
* Kernel headers: Rocky `kernel-headers-6.12.0-211.*` vs nixpkgs
  `linux-headers-6.18.7`. They do not affect the glibc ABI; glibc keeps its own syscall
  tables. They do affect the sysroot package and test-only constant checks.
  `--with-headers` needs them physically present in `/usr/include`.
* Tool versions in nixpkgs vs Rocky:
  * gettext 1.0 vs 0.22.5; texinfo 7.2 vs 7.1. Output `.mo`/`.info` may differ
    byte-wise.
  * python 3.13 vs 3.12. No glibc 2.39 `.py` imports modules removed in 3.12 or 3.13
    (checked).
  * make 4.4.1 and bison 3.8.2 are identical.
  * debugedit 5.2 vs 5.1; dwz 0.16 is identical; elfutils 0.194 is identical.
  * gdb 17.2 vs 16.3 (only matters for `%check`).

### 8.7 Sandbox and runtime requirements
* The CPU must be x86-64-v3 (TL;DR 5).
* `/proc` must be mounted and `df` must succeed (spec:1218-1221 under `sh -e`).
* `rpm -ql kernel-headers` must work for a faithful sysroot package (spec:1822). It
  fails silently otherwise.
* No network access is needed: patch-git does not call git without a `.git` dir.
* `%check` (if ever enabled) needs nested user and mount namespaces for
  `test-container`, plus large timeouts (`TIMEOUTFACTOR=16`).
