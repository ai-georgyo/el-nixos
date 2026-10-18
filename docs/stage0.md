# stage0: the bootstrap buildroot and the rpmbuild-in-chroot machinery

This document describes `bootstrap/` (the stage0 FHS buildroot) and `lib/`
(the generic machinery: chroot runner, buildroots, `buildSrpm`, `rpmTree`).
It complements [DESIGN.md](DESIGN.md), which is the contract.

Everything here is **plain derivations** (no IFD, no dynamic derivations, no
recursive-nix). Nothing at evaluation time depends on a build result: the
binary-package names an SRPM produces are only *selected* at build time (by
`%{NAME}` from the RPM headers).

## TL;DR — attributes

`legacyPackages.x86_64-linux.stage0.<attr>`:

| attr | what |
|---|---|
| `binutils`, `gccPass1`, `glibc`, `gcc`, `kernelHeaders`, `sysroot` | the stage0 toolchain (FHS trees under `$out/usr`) |
| `rpm`, `debugedit` | Rocky's rpm 4.19.1.1 / debugedit 5.1 built with FHS paths compiled in |
| `buildroot` | stage0 base layer (toolchain + nixpkgs tools + rpm + `/etc`) |
| `buildrootRelease` | + Rocky `rocky-release` RPMs (built from SRPM in `buildroot`) |
| `buildrootFullA` | + redhat-rpm-config and the `*-srpm-macros` (pass A) |
| `buildrootFull` | **stage0-full**: release + macro packages rebuilt in `buildrootFullA` (pass B) |
| `srpm.<srpm-name>` | `buildSrpm` results: `$out/RPMS/<arch>/*.rpm`, `$out/SRPMS/*.src.rpm`, `$out/logs/` |
| `srpmPassA.<srpm-name>` | the pass-A builds of the macro packages |
| `rpms.<binary-name>` | `rpmTree`: one binary RPM's payload as an FHS tree, `allowedReferences = [ ]` |
| `tests.{toolchain,toolchainFull,macros,whichRpms,whichTree}` | acceptance tests (output: `report.txt`) |
| `buildStage0 { srpm = "<name>"; ... }` | helper: build any lock SRPM in stage0-full |
| `lib` | `{ buildSrpm, mkBuildroot, rpmTree, runInBuildroot, fetchSrpm, unpackSrpm, distOf, ... }` |
| `dev.*` | machinery smoke tests on a root without the FHS toolchain (fast iteration) |

## The pieces

### 1. Fetching SRPMs (`lib/fetch-srpm-seed.nix`)

Temporary, driven by the seed lock `lock/rocky-10.2/srpms.json` (format in
DESIGN.md). `fetchSrpm name` is a `fetchurl` over all mirrors
(`<mirror>/<repo>/source/tree/<path>`) with the lock's sha256.
`unpackSrpm name` unpacks spec + sources + patches with `bsdtar` (reads the rpm
container directly). `distOf name` recovers the `%dist` an SRPM was built with
from its lock release (`142.el10_2` → `.el10_2`, `44.el10_0` → `.el10_0`,
`295-1.el10.rocky.0.2` → `.el10`), so rebuilt NEVRs equal the official ones.

Seed-lock additions made by this track (same format, generated with the seed
generator from repodata): `debugedit dwz efi-rpm-macros filesystem
fonts-rpm-macros forge-srpm-macros go-rpm-macros lua-rpm-macros package-notes
qt6 setup` (macro packages whose SRPM name differs from the binary name were
found through the binary repodata `sourcerpm` field).

### 2. The stage0 toolchain (`bootstrap/{binutils,gcc,glibc,kernel-headers}.nix`)

Requirement: inside the chroot, `gcc hello.c` must behave like on a normal
distro: headers from `/usr/include`, crt files and libc from `/usr/lib64`,
`PT_INTERP /lib64/ld-linux-x86-64.so.2`, no RPATH/RUNPATH.

**Empirical findings that ruled out reusing nixpkgs' toolchain directly**

* nixpkgs `gcc14.cc` (unwrapped): `gcc -v -E -` shows the native system header
  dir hard-wired to `/nix/store/…-glibc-2.42-dev/include`;
  `-print-search-dirs` lists no FHS library dir at all (nixpkgs' `no-sys-dirs`
  patch). A specs file can add `-idirafter /usr/include` / `startfile_prefix_spec`,
  but cannot remove the store include dir (it would silently win for any
  header missing in `/usr/include`), and `-print-file-name=include` etc. would
  still answer store paths (which then end up in debug info).
* nixpkgs `ld` (binutils 2.46): `ld --verbose` has **no** `SEARCH_DIR` at all.
* nixpkgs glibc's `ld.so`: `strings` shows its system search path and its
  `ld.so.cache` are store paths (`…-glibc-2.42-100/lib/`,
  `…/etc/ld.so.cache`). Copied to `/lib64/ld-linux-x86-64.so.2` it would
  never look in `/usr/lib64`. It is also glibc **2.42**: binaries compiled
  against it could reference symbol versions newer than Rocky's 2.39.

**What we do instead**: build a small, real FHS toolchain from **Rocky's own
source tarballs** (taken out of the Rocky SRPMs) with the nixpkgs compiler,
following the classic `build-many-glibcs.py` order. Rocky's glibc.spec builds a
32-bit glibc on x86_64 (`gcc -m32`), so the compiler must be multilib, which in
turn needs a 32+64-bit libc before the full gcc:

1. **binutils** — `binutils-2.41.tar.xz` + all 65 applicable patches of
   binutils.spec (Patch14 is `%if enable_new_dtags`, off on RHEL), configured
   with binutils.spec's native flags (`--with-sysroot=/`, `--prefix=/usr`,
   `--enable-default-hash-style=gnu`, execstack/rwx warnings, …). Result:
   `GNU ld version 2.41-63.el10`, `SEARCH_DIR("=/usr/lib64") …`,
   `--error-execstack`/`--package-metadata` supported (needed by
   redhat-rpm-config's hardening specs and package notes).
2. **gcc pass 1** — `gcc-14.3.1-20251022.tar.xz` (the Red Hat gcc-14 branch
   snapshot) as a store-prefixed `x86_64-redhat-linux` C compiler without libc
   (`--without-headers --with-newlib`, static libgcc for `-m64`/`-m32`).
3. **glibc** — `glibc-2.39.tar.xz` (no Rocky patches) configured like
   glibc.spec (`--prefix=/usr`, usrmove symlinks in the install root,
   `--enable-bind-now --enable-stack-protector=strong --enable-cet
   --with-rtld-early-cflags=-march=x86-64 --disable-crypt …`,
   `LDFLAGS.so=-Wl,--hash-style=both`), i686 first then pruned to libraries,
   then x86_64 — exactly the glibc.spec sequence.
4. **gcc** — same tarball + Rocky patches (hack, libgomp-omp_h-multilib,
   libtool-no-rpath, no-add-needed, Wno-format-security, rh1574936, pr101523),
   `DEV-PHASE` "Red Hat 14.3.1-4", isl-0.24 from the SRPM built in-tree,
   Rocky's x86_64 configure options (`--enable-multilib --with-arch_64=x86-64-v3
   --with-arch_32=x86-64 --with-tune=generic --enable-cet
   --with-linker-hash-style=gnu --enable-gnu-indirect-function
   --enable-host-pie --enable-host-bind-now --with-gcc-major-version-only …`),
   `--prefix=/usr`, `--with-sysroot=/ --with-build-sysroot=<stage0 sysroot>`,
   `--with-native-system-header-dir=/usr/include`. Target libraries (libgcc_s,
   libstdc++, libgomp, libatomic, libquadmath, libitm) are compiled against the
   stage0 glibc, have no RUNPATH and no store references (checked at build
   time). Layout tweaks from gcc.spec: `libgcc_s.so` linker scripts, `cc`,
   `/usr/lib/cpp`, LTO plugin in `/usr/lib/bfd-plugins`, fixincludes-edited
   headers removed.
5. **kernel headers** — parameter `kernelHeaders` of `bootstrap/` (FHS tree
   with `usr/include`); default: nixpkgs `linuxHeaders` (plain
   `headers_install`, checked free of store references).

The compiler/linker *executables* are host programs linked against nixpkgs
libraries (RUNPATH into the store). They run in stage0 chroots because
`/nix/store` is visible read-only there, and they never leak into their
output.

### 3. rpm (`bootstrap/rpm.nix`) and debugedit (`bootstrap/debugedit.nix`)

**Decision: build Rocky's rpm-4.19.1.1 (+ all 33 patches of rpm.spec's
`%patchlist`) rather than overriding nixpkgs' rpm 4.20.1.**
rpm 4.20 moved the build tree to `%{_builddir}/%{NAME}-%{VERSION}-build/`,
changed `%setup`/`%prep` semantics and the debugsource layout; packages built
with it would differ from Rocky's. Rocky's macro packages (redhat-rpm-config
295) are written for 4.19. Building the exact rpm Rocky uses costs one small
cmake build.

Configured like rpm.spec (`-DRPM_VENDOR=redhat`, sqlite+ndb, Sequoia OpenPGP
via nixpkgs `rpm-sequoia` — the PQC patches need it), with
`CMAKE_INSTALL_PREFIX=/usr`, `RPM_CONFIGDIR=/usr/lib/rpm`, sysconfdir `/etc`,
localstatedir `/var`, installed with `DESTDIR`. rpm's `findutil()` only
searches `$MYPATH` and `/usr/bin:/bin:…`, so in the sandbox every tool path in
the generated macros resolves to `/usr/bin/<tool>`, like on Rocky. Result:
`/usr/lib/rpm/{macros,rpmrc,platform/*}` are **byte-identical** to the
official `rpm-4.19.1.1-23.el10.x86_64.rpm`; the only difference left in the
config dir was shebangs (`#!/bin/sh` vs `#!/usr/bin/sh`), which Rocky's
`brp-mangle-shebangs` rewrites — we apply the same rewrite.

The rpm binaries live in the store (`$out/usr/bin`, RUNPATH patched to
`$out/usr/lib64` + nixpkgs libs) and are symlinked into `/usr/bin` of the
buildroot; `/usr/lib/rpm` is a **real directory** in the buildroot, so Rocky's
macro packages install into `/usr/lib/rpm/macros.d`, `/usr/lib/rpm/redhat`, …
unmodified. rpm's own libraries are deliberately *not* placed in
`/usr/lib64` (they are nixpkgs-linked and must not shadow Rocky's rpm-libs).

Outside the chroot the same rpm is used with `RPM_CONFIGDIR=<store>/usr/lib/rpm`
(rpm honours that variable) for `rpm --root` installs and header queries.

debugedit: Rocky's debugedit-5.1 + its 6 patches, `--prefix=/usr`
(`find-debuginfo` calls the tools by name from `PATH`).

### 4. The base layer (`bootstrap/root.nix`)

* usrmerge layout as `filesystem-3.18-17.el10`: `/bin→usr/bin`,
  `/sbin→usr/sbin`, `/lib→usr/lib`, `/lib64→usr/lib64`; **`/usr/sbin` is a
  real directory** (RHEL 10 did not do Fedora 42's bin/sbin merge: glibc's
  binary package ships `/usr/sbin/ldconfig`, filesystem.spec creates
  `usr/sbin` and links `sbin→usr/sbin`). Same directory skeleton,
  `/var/run→../run`, `/usr/tmp→../var/tmp`, `/usr/lib/debug/*` links.
* toolchain trees copied as real files; rpm config dir copied; rpm/rpmbuild,
  debugedit and the nixpkgs buildsys-build tools symlinked into `/usr/bin`
  (bash/sh, coreutils, sed, grep, gawk/awk, findutils, diffutils, patch, tar,
  gzip, bzip2, xz, zstd, cpio, unzip, zip, which, file, util-linux, procps,
  make, perl, python3, m4, bison, flex, texinfo, gettext, elfutils (eu-*),
  dwz, gdb (gdb-add-index: redhat-rpm-config sets `%_include_gdb_index 1`),
  git (`%autosetup -S git`), hostname, gnupg). First provider of a name wins,
  the FHS toolchain first.
* `/etc/passwd`, `/etc/group` (root, the usual system ids, `mockbuild` 1000,
  group `mock` 135), `shadow`, `hosts`, `nsswitch.conf`, `ld.so.conf` (+ cache
  generated by the stage0 glibc's static `ldconfig -r`), `/etc/rpm/macros.stage0`,
  an empty rpmdb (sqlite) at `/usr/lib/sysimage/rpm`.
* `/proc`, `/dev`, `/tmp`, `/var/tmp`, `/dev/shm` are provided by the runner,
  `/nix/store` only for stage0.

### 5. The chroot runner (`lib/chroot.sh`)

Verified on the nixbuild.net builders:

* unprivileged user+mount namespaces work inside the Nix sandbox (bwrap 0.12);
* **overlayfs works** in the user namespace (`bwrap --overlay-src … --overlay`
  and `unshare` + `mount -t overlay` both succeed); later `--overlay-src`
  arguments stack on top of earlier ones (tested);
* **nested** user namespaces are *not* permitted ("setting up uid map:
  Operation not permitted"), so a namespace can map exactly one uid;
* store files appear owned by `nobody` (their owner is unmapped) and store
  dirs are `0555`, so even ns-root cannot write into them through overlayfs.

Design:

* A buildroot is a list of **layers** (store paths, bottom → top). The root
  of a chroot is an overlayfs: lowers = layers, upper/work in `$TMPDIR` —
  "making the root writable" is free.
* `chroot_setup` seeds the upper dir with a writable copy of every
  **directory** of the merged lower view (so files can be created, replaced
  and removed everywhere) and full copies of the small trees tools rewrite in
  place (`/etc`, `/var`, `/usr/lib/sysimage` — the rpmdb).
* Work is split into phases sharing the upper dir, each with a single uid
  mapping: **root phases** (uid 0, all caps in the namespace) and **build
  phases** (uid 1000 `mockbuild`, gid 135 `mock`). Files created in a root
  phase are really owned by the sandbox uid and show up as `mockbuild` in a
  build phase.
* `chroot_exec`: the merged root as `/`, fresh `/proc`, minimal `/dev`, tmpfs
  `/tmp` `/var/tmp` `/dev/shm`, new pid/ipc/uts/net/cgroup namespaces,
  hostname, cleared environment with mock's variables
  (`PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `HOME`, `TERM=vt100`,
  `SHELL=/bin/bash`, `LANG=C.UTF-8`, `TZ=UTC`); `/nix/store` read-only **only
  with `--store`** (stage0); extra binds (`/builddir` from `$TMPDIR`).
* `chroot_tools`: run a command *outside* the root (nixpkgs world) with the
  merged root mounted rw at `$BUILDROOT` — used for `rpm --root $BUILDROOT -i`
  with the stage0 rpm. This works for every stage, including later ones where
  the root contains no usable rpm and `/nix/store` is not visible inside;
  with `installFlags = [ ]` rpm checks dependencies and runs scriptlets
  chrooted into the root (ns-root has `CAP_SYS_CHROOT`).
* `chroot_layer_out`: the upper dir minus the seeding (empty seeded dirs,
  unchanged seeded files) becomes a new **layer**. Overlay whiteouts / opaque
  dirs (deletions of lower content) cannot be stored in the Nix store, so they
  fail the build; the rpmdb's sqlite WAL must be checkpointed (it is, rpm
  closes the db) and `-wal`/`-shm` are never stored in layers.

### 6. `mkBuildroot`, `buildSrpm`, `rpmTree`, `runInBuildroot` (`lib/default.nix`)

* `mkBuildroot { name, base, rpms ? [ ], installFlags ? [ "--nodeps" "--noscripts" ], extraCommands ? "" }`
  → a new layer; `passthru.layers = base.layers ++ [ self ]`. `rpms` entries:
  an `.rpm` path, a `buildSrpm` result (all its non-debug RPMs), or
  `{ from = <buildSrpm result>; names = [ "<%{NAME}>" … ]; }`.
  Later stages: pass `installFlags = [ ]` for real dependency checking and
  scriptlets.
* `buildSrpm { srpm, buildroot, rpmbuildArgs ? [ ], defines ? { }, dist ? <from lock>,
  extraRpms ? [ ], nodeps ? <stage0>, target ? "x86_64", buildhost ?
  "el-nixos.localdomain", vendor ? null, packager ? null, allowStoreReferences ? false }`:
  runs **`rpmbuild --rebuild`** on the fetched SRPM as `mockbuild` in the
  chroot with `%_topdir /builddir/build`, `%dist`, `%_buildhost`,
  `%source_date_epoch_from_changelog 1`, `%use_source_date_epoch_as_buildtime 1`,
  `%clamp_mtime_to_source_date_epoch 1`, `%_smp_build_ncpus $NIX_BUILD_CORES`
  (→ `%_smp_mflags -jN`), `--target`, `--nodeps` in stage0; then
  `rpmbuild -rs` for the rebuilt source package. Output `$out/RPMS/<arch>/`,
  `$out/SRPMS/`, `$out/logs/{build.log,srpm.log,files}` (store hashes in logs
  are nuked so the output has no references). On failure the last 80 log
  lines are printed. `allowedReferences = [ ]`: a store path in any RPM header
  (e.g. an auto-generated `Requires: /nix/store/…/bin/perl`) fails the build.
* `rpmTree { build, name }`: the payload of the binary RPM whose `%{NAME}` is
  `name`, extracted (`rpm2cpio | cpio`) into `$out`, with
  **`allowedReferences = [ ]`** — the enforcement that shipped packages do
  not depend on nixpkgs.
* `runInBuildroot { name, buildroot, script, root ? false, binds ? { } }`:
  run a script in a buildroot; `/builddir/out` becomes `$out` (used by tests).

### 7. Stage0 package flow (validation a–d)

a. `srpm.rocky-release`: built in `buildroot` with plain rpm macros; installed
   → `buildrootRelease` (provides `macros.dist`: `%dist`, `%rhel 10`, `%el10`…).
b. redhat-rpm-config + the srpm-macros packages it `Requires` (resolved from
   binary repodata): efi-srpm-macros, fonts-srpm-macros, forge-srpm-macros,
   go-srpm-macros, kernel-srpm-macros, lua-srpm-macros, ocaml-srpm-macros,
   openblas-srpm-macros, package-notes-srpm-macros, perl-srpm-macros,
   pyproject-srpm-macros, python-srpm-macros, qt6-srpm-macros; pass A in
   `buildrootRelease` → `buildrootFullA`; pass B (final, `srpm.*`) in
   `buildrootFullA` → **`buildrootFull`**. `tests.macros` checks the
   `rpm --eval` results and compiles with them.
c. `srpm.which`: arch-dependent C package with the full Rocky flags and
   debuginfo generation; `tests.whichRpms` inspects the RPMs.
d. `rpms.which` (and every other `rpms.*`): `rpmTree` with
   `allowedReferences = [ ]`.

## Every stage0 hack, and why

| hack | where | why / impact |
|---|---|---|
| nixpkgs tools at FHS paths as symlinks into a visible read-only `/nix/store` | root.nix, runner `--store` | bootstrap only; later stages never see the store |
| toolchain built from Rocky tarballs **without** Rocky's glibc patches and with a subset of gcc patches | glibc.nix, gcc.nix | stage0 libc/compiler only build stage0 packages; the real glibc/gcc RPMs come from the SRPMs |
| gcc: `--disable-bootstrap`, no profiledbootstrap/LTO-bootstrap, no fortran/go/d/ada/m2, no sanitizers, no offloading | gcc.nix | build time; enough for C/C++ packages incl. glibc (glibc's spec needs `gcc -m32` and C++) |
| binutils: no gold, static libbfd/libopcodes (`--disable-shared`), no jansson/debuginfod | binutils.nix | host libs must not be looked up in `/usr/lib64` by the nixpkgs loader |
| rpm: no plugins/python/selinux/audit/dbus/fapolicyd/imaevm/fsverity, `ENABLE_NLS=OFF` | rpm.nix | not needed to build packages |
| kernel headers from nixpkgs (6.18) | kernel-headers.nix | parameter; to be replaced by Rocky kernel-headers |
| `%_annobin_gcc_plugin %{nil}` | macros.stage0 | no annobin plugin for the stage0 gcc yet (empties `-specs=…redhat-annobin-cc1`); `%_annotated_build` stays defined so `--remove-section .gnu.build.attributes` is still passed to find-debuginfo (harmless) |
| `%_binary_payload w19.zstdio` | macros.stage0 | same value as redhat-rpm-config, for packages built before it is installed |
| `%el_nixos_stage 0` | macros.stage0 | marker |
| `--nodeps` for rpmbuild, `--nodeps --noscripts` for installs | lib/default.nix | nixpkgs tools are not in the rpmdb |
| macro packages: `--nocheck` for forge-srpm-macros, pyproject-rpm-macros, python-rpm-macros | bootstrap/default.nix | their `%check` needs pytest/pyyaml/… |
| go-rpm-macros built with `--target noarch` | bootstrap/default.nix | `%ifarch golang_arches` builds the bundled golist with golang; for a non-go arch the spec ships just go-srpm-macros, whose content (written by `%writevars` in `%prep`) is identical |
| rust-srpm-macros not installed | bootstrap/default.nix | comes from the 270 MB rust SRPM; nothing on the glibc path needs it |
| no `%vendor`/`%packager` | buildSrpm | Rocky's build system sets them; we do not claim Rocky's identity (overridable) |
| buildhost `el-nixos.localdomain`, buildtime = changelog date | buildSrpm | reproducibility |

## Results

(see below; filled from real builds)
