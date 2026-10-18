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
| `rpmLibs.{zstd,file,elfutils}` | the stage0 rpm's libzstd / libmagic from Rocky's zstd/file SRPM sources, elfutils re-linked against that zstd (`bootstrap/rpm-libs.nix`) |
| `buildroot` | stage0 base layer (toolchain + nixpkgs tools + rpm + `/etc`) |
| `buildrootRelease` | + Rocky `rocky-release` RPMs (built from SRPM in `buildroot`) |
| `buildrootFullA` | + redhat-rpm-config and the `*-srpm-macros` (pass A) |
| `buildrootFull` | **stage0-full**: release + macro packages rebuilt in `buildrootFullA` (pass B) |
| `srpm.<srpm-name>` | `buildSrpm` results: `$out/RPMS/<arch>/*.rpm`, `$out/SRPMS/*.src.rpm`; `.logs`: `build.log`, `srpm.log`, `files`, `purity.json` |
| `srpmPassA.<srpm-name>` | the pass-A builds of the macro packages |
| `rpms.<binary-name>` | `rpmTree`: one binary RPM's payload as an FHS tree, `allowedReferences = [ ]` |
| `tests.{toolchain,toolchainFull,macros,whichRpms,whichTree}` | acceptance tests (output: `report.txt`) |
| `tests.{chrootOpaque,chrootWhiteout,chrootAccept,chrootUsrmerge,chrootUnreadable}` | the layer machinery: deletions refused, additions/unreadable files/dir symlinks handled (`bootstrap/tests/chroot.nix`) |
| `kernelHeadersBuild`, `rpms.kernel-headers`, `buildrootKernel`, `buildrootFullKernelHeaders`, `tests.{kernelHeaders,kernelHeadersBuildroot,toolchainKernelHeaders}` | Rocky kernel-headers from the kernel SRPM (headers-only rpmbuild) — see [kernel-headers.md](kernel-headers.md) |
| `buildStage0 { srpm = "<name>"; ... }` | helper: build any lock SRPM in stage0-full |
| `mkRoot { name, kernelHeaders ? <stage0>, extraTrees ? [ ] }` | a root layer like `buildroot` with other kernel headers (`null` = none, install an RPM on top) and/or extra FHS trees; the toolchain is not rebuilt |
| `fullRpms` | the rpm specs stage0-full installs (rocky-release + pass-B macro packages), for `mkBuildroot` on a `mkRoot` |
| `glibcBuildDeps` | FHS tree of what the glibc SRPM needs beyond the root (see [glibc.md](glibc.md)) |
| `lib` | `{ buildSrpm, mkBuildroot, rpmTree, runInBuildroot, fetchSrpm, unpackSrpm, distOf, ... }` |
| `dev.*` | machinery smoke tests on a root without the FHS toolchain (fast iteration) |

## The pieces

### 1. Fetching SRPMs (`lib/fetch-srpm.nix`, `lib/srpm.nix`)

Driven by the generated lock `lock/rocky-10.2/srpms.json` (format in
DESIGN.md). `fetchSrpm name` (`lib/fetch-srpm.nix`, also behind
`legacyPackages.sources.<srpm>`) is a `fetchurl` FOD over all mirrors
(`<mirror>/<repo>/source/tree/<path>`) with the lock's sha256.
`lib/srpm.nix` adds `unpackSrpm name` (spec + sources + patches, unpacked with
`bsdtar`, which reads the rpm container directly), `entry name` (the lock
entry) and `distOf name`, which recovers the `%dist` an SRPM was built with
from its lock release (`142.el10_2` → `.el10_2`, `44.el10_0` → `.el10_0`,
`295-1.el10.rocky.0.2` → `.el10`), so rebuilt NEVRs equal the official ones.

(Until the integration, stage0 used a temporary seed fetcher,
`lib/fetch-srpm-seed.nix`, over a hand-extended seed lock. The generated lock
is a superset with the same path/sha256 for every seed entry, so the switch
changed no store path: same FOD name + hash, hence the same downstream
derivations.)

Which binary packages an SRPM produces (`rpms.<name>` trees) comes from
`lock/rocky-10.2/rpms.json`'s `bySrpm`, except where a stage0 build
deliberately produces a subset (the headers-only kernel build, the noarch
go-rpm-macros build).

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
   `--prefix=/usr`, **no sysroot** (like Rocky: `gcc -print-sysroot` is empty).
   A native gcc build compiles *and runs* target test programs (libstdc++ /
   libgomp configure), whose `PT_INTERP` is `/lib64/ld-linux-x86-64.so.2` — so
   configure/make/install run through `fhsRun`, a bwrap namespace whose `/usr`
   is the stage0 sysroot (glibc + kernel headers) with `/lib64`, `/lib`
   symlinks: the gcc build sees a genuine FHS system; the nixpkgs host compiler
   only uses store paths and is unaffected. (A first attempt with
   `--with-build-sysroot` failed exactly there: "cannot run C compiled
   programs".) Target libraries (libgcc_s, libstdc++, libgomp, libatomic,
   libquadmath, libitm) are compiled against the stage0 glibc, have no RUNPATH,
   their debug info is stripped (it names build paths; Rocky moves it to
   gcc-debuginfo) and the build fails if any target object mentions
   `/nix/store`. Layout tweaks from gcc.spec: `libgcc_s.so` linker scripts,
   `cc`, `/usr/lib/cpp`, LTO plugin in `/usr/lib/bfd-plugins`,
   fixincludes-edited headers removed, libssp deleted (done in root.nix),
   libcc1 (host-side gdb plugin) not built.
   `gcc --version` → `gcc (GCC) 14.3.1 20251022 (Red Hat 14.3.1-4)`, same
   string as Rocky's gcc.

   The stage0 glibc's debug info is stripped for the same reason (crt files,
   libc_nonshared.a and libc.a are linked into every program), and its
   installed scripts get FHS interpreters (`BASH_SHELL=/usr/bin/bash`,
   `PERL=/usr/bin/perl`); the build fails on any `/nix/store` string.
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
  and removed everywhere), a copy of every **symlink to a directory** (the
  usrmerge links `/lib64 -> usr/lib64`, `/bin`, `/var/run` …: in a store
  layer they are owned by `nobody`, and rpm 4.19 refuses to install through
  a directory symlink that is owned neither by root nor by the file's owner —
  "cpio: Unsafe symlink"; `tests.chrootUsrmerge` installs Rocky's libgcc,
  whose payload uses `/lib64/…`, onto the stage0 root) and full copies of the
  small trees tools rewrite in place (`/etc`, `/var`, `/usr/lib/sysimage` —
  the rpmdb). Seeded entries that end up unchanged are dropped again by
  `chroot_layer_out`.
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
  SIGPIPE is reset to its default disposition (`env --default-signal=PIPE
  bwrap …`): the Nix build sandbox starts builders with SIGPIPE *ignored*
  (`SigIgn: …1000`, observed on this Determinate Nix 2.36 setup), which
  survives exec and makes `grep … | head`-style pipelines print "write
  error: Broken pipe" instead of terminating quietly as under mock.
* `chroot_tools`: run a command *outside* the root (nixpkgs world) with the
  merged root mounted rw at `$BUILDROOT` — used for `rpm --root $BUILDROOT -i`
  with the stage0 rpm. This works for every stage, including later ones where
  the root contains no usable rpm and `/nix/store` is not visible inside;
  with `installFlags = [ ]` rpm checks dependencies and runs scriptlets
  chrooted into the root (ns-root has `CAP_SYS_CHROOT`).
* `chroot_layer_out`: the upper dir minus the seeding (empty seeded dirs,
  unchanged seeded files and symlinks) becomes a new **layer**. Deletions of
  lower content cannot be stored in the Nix store, so they fail the build:
  whiteouts (char 0/0 devices) and opaque / redirected / metacopy
  directories (`user.overlay.{opaque,redirect,metacopy}` xattrs — a lower
  directory removed and recreated would otherwise silently get its deleted
  files back once Nix drops the xattrs; the check reads `getfattr`'s output,
  not its exit status, which is 1 whenever any file lacks the attribute and
  made the old check a no-op under `pipefail`). `tests.chrootOpaque`,
  `tests.chrootWhiteout` and `tests.chrootAccept` cover both directions.
  Files rpm created unreadable for their owner (setup's `/etc/shadow` and
  `/etc/gshadow` are mode `0000`) are made owner-readable before the
  unprivileged copy-out (`tests.chrootUnreadable`); the store cannot
  represent such modes, nor owners, anyway (see "Known gaps"). The rpmdb's
  sqlite WAL must be checkpointed (it is, rpm closes the db) and
  `-wal`/`-shm` are never stored in layers.

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
  `rpmbuild -rs` for the rebuilt source package. Outputs: `out` =
  `RPMS/<arch>/`, `SRPMS/`; `logs` = `build.log`, `srpm.log`, `files`,
  `purity.json` (store hashes in logs are nuked so no output has references;
  the logs are a separate output because parallel build logs are never
  reproducible). On failure the last 80 log lines are printed.
  **Purity**: after the build, `tools/rpm_purity.py` searches every binary
  RPM byte by byte for `/nix/store` — headers, payload files, symlink
  targets, and inside gzip/xz/bzip2/zstd members, ELF `.gnu_debugdata` and
  compressed ELF sections — and any hit fails the build (skipped only with
  `allowStoreReferences = true`). `allowedReferences = [ ]` is kept, but on
  its own it only catches store paths of the build's input closure in the
  uncompressed RPM headers.
  `requiredSystemFeatures ? [ ]` is passed through (only set when non-empty,
  so existing derivations are unchanged); glibc uses `[ "big-parallel" ]`.
* `rpmTree { build, name, file ? null }`: the payload of the binary RPM whose `%{NAME}` is
  `name`, extracted (`rpm2cpio | cpio`) into `$out`, with
  `allowedReferences = [ ]`. That alone is **not** the purity guarantee: Nix
  only scans for hashes of paths in the derivation's input closure (rpm,
  cpio, stdenv — not the nixpkgs tools of the buildroot) and never inside
  compressed files. The guarantee is `buildSrpm`'s byte-level purity scan,
  which every `rpmTree` depends on through `build`. `file`
  (`RPMS/<arch>/<n-v-r.a>.rpm`, still checked against `%{NAME}`) avoids
  querying every RPM of an SRPM with hundreds of subpackages (glibc: 233).
* `runInBuildroot { name, buildroot, script, root ? false, binds ? { } }`:
  run a script in a buildroot; `/builddir/out` becomes `$out` (used by tests).

### 7. Stage0 package flow (validation a–d)

a. `srpm.rocky-release`: built in `buildroot` with plain rpm macros; installed
   → `buildrootRelease` (provides `macros.dist`: `%dist`, `%rhel 10`, `%el10`…).
b. redhat-rpm-config + the srpm-macros packages it `Requires` (resolved from
   binary repodata): efi-srpm-macros, fonts-srpm-macros, forge-srpm-macros,
   go-srpm-macros, kernel-srpm-macros, lua-srpm-macros, ocaml-srpm-macros,
   openblas-srpm-macros, package-notes-srpm-macros, perl-srpm-macros,
   pyproject-srpm-macros, python-srpm-macros, qt6-srpm-macros.
   Pass A runs in **waves**, each installed before the next, because the macro
   packages use each other's macros at build time: `[redhat-rpm-config]`
   (provides `%rpmmacrodir`) → `[python-rpm-macros]` (redhat-rpm-config's
   `%__os_install_post` expands `%{__os_install_post_python}` from
   python-srpm-macros; only this one build gets it as `%{nil}`) →
   `[forge-srpm-macros]` (`%forgemeta`, used by fonts/go) → `[the rest]`
   ⇒ `buildrootFullA`. Pass B (final, `srpm.*`) rebuilds all of them in
   `buildrootFullA` and installs them on top of `buildrootRelease` ⇒
   **`buildrootFull`**. `tests.macros` checks the `rpm --eval` results and
   compiles with them.
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
| kernel headers from nixpkgs (6.18) for the stage0 *toolchain* and the base root | kernel-headers.nix | the toolchain does not ship; package builds that need Rocky's headers use a root without them plus the Rocky kernel-headers RPM (glibc does: [glibc.md](glibc.md), [kernel-headers.md](kernel-headers.md)) |
| rpm's libzstd and libmagic: built from **Rocky's zstd-1.5.5-9.el10 and file-5.45-9.el10 SRPM sources** (tarball + all spec patches) with nixpkgs' toolchain; elfutils re-linked against that zstd | rpm-libs.nix, rpm.nix | they write bytes into every RPM: the compressed payload (nixpkgs' zstd 1.5.7 compressed identical payloads to different bytes) and the FILECLASS strings (nixpkgs' file 5.47: "dynamically linked" for ld.so, a gzip "original size" suffix). `installCheckPhase` asserts which `libzstd.so.1`/`libmagic.so.1` rpmbuild loads. The `file` command in the root is the same build |
| makeinfo 7.1 from Rocky's texinfo SRPM, Unicode::Collate hidden (`texinfo71`) | texinfo.nix | only in package roots that ship info pages (glibc); nixpkgs' 7.2 and Unicode::Collate change the info output |
| `%_annobin_gcc_plugin %{nil}` | macros.stage0 | no annobin plugin for the stage0 gcc yet (empties `-specs=…redhat-annobin-cc1`); `%_annotated_build` stays defined so `--remove-section .gnu.build.attributes` is still passed to find-debuginfo (harmless) |
| `%_binary_payload w19.zstdio` | macros.stage0 | same value as redhat-rpm-config, for packages built before it is installed |
| `%el_nixos_stage 0` | macros.stage0 | marker |
| `--nodeps` for rpmbuild, `--nodeps --noscripts` for installs | lib/default.nix | nixpkgs tools are not in the rpmdb |
| macro packages: `--nocheck` for forge-srpm-macros, pyproject-rpm-macros, python-rpm-macros | bootstrap/default.nix | their `%check` needs pytest/pyyaml/… |
| pass A: `__os_install_post_python=%{nil}` for python-rpm-macros only | bootstrap/default.nix | chicken-and-egg with redhat-rpm-config; pass B builds it normally |
| gcc built through `fhsRun` (sysroot mounted at `/usr`) | gcc.nix | target-library configure must run target programs |
| libssp removed while assembling the root (not in gcc.nix) | root.nix | gcc.spec removes it; done there to avoid a 40-min gcc rebuild — move into gcc.nix on its next rebuild |
| stage0 glibc/gcc target objects: debug info stripped | glibc.nix, gcc.nix | their DWARF names build-time store paths and would be linked into every program |
| go-rpm-macros built with `--target noarch` | bootstrap/default.nix | `%ifarch golang_arches` builds the bundled golist with golang; for a non-go arch the spec ships just go-srpm-macros, whose content (written by `%writevars` in `%prep`) is identical |
| rust-srpm-macros not installed | bootstrap/default.nix | comes from the 270 MB rust SRPM; nothing on the glibc path needs it |
| no `%vendor`/`%packager` | buildSrpm | Rocky's build system sets them; we do not claim Rocky's identity (overridable) |
| buildhost `el-nixos.localdomain`, buildtime = changelog date | buildSrpm | reproducibility |

## Results (real builds on nixbuild.net, nixpkgs 26f4107, 2026-10-18)

Note: the store paths in this table predate later changes that rebuilt
everything above the toolchain (the stage0 rpm now links Rocky-sourced
libzstd/libmagic; `lib/chroot.sh` and `buildSrpm` changed); current paths
for the glibc build are in [glibc.md](glibc.md) ("Store paths").

Note: the SIGPIPE reset in `lib/chroot.sh` (added by the glibc track) changed
the hashes of every derivation that uses the runner (buildroot layers above
the root, `srpm.*`, `rpms.*`, `tests.*`); the toolchain, `rpm`, `debugedit` and
the root layer are unchanged. All tests were rebuilt and pass; the store paths
below for those derivations are from before that change.

`flake.lock` was added, pinning nixpkgs (nixos-26.05) to the revision all of
this was built with (`26f4107e47e3ad0ffd0db220469ba83b6f6d96e8`).

| attr | store path | size | build time | CPUs |
|---|---|---|---|---|
| `binutils` | `/nix/store/n9knrf5xwmnihh4xvi2avglg6gnp2zj8-stage0-binutils-2.41-63.el10` | 138M | 1 min | 2 |
| `gccPass1` | `/nix/store/4jcl31bw9kz46ljzz2n0waixpsw9p4yq-stage0-gcc-pass1-14.3.1-4.4.el10` | 140M | 13 min | 2 |
| `glibc` | `/nix/store/0ysxpa6yig258a7hcg8x0a5vwdfphwd0-stage0-glibc-2.39-142.el10_2` | 61M | 6 min (11 min on 2 CPUs) | 4 |
| `gcc` | `/nix/store/bxz0gx446vl8b1m106bqibngg88sv22c-stage0-gcc-14.3.1-4.4.el10` | 270M | buildPhase 6 min (nixbuild gave the retry more CPUs; the failed 2-CPU attempt ran 14 min) | ? |
| `rpm` | `/nix/store/iaky4rzwlnsqgpzpqb3a739d8lbwf3qg-stage0-rpm-4.19.1.1-23.el10` | 15M | < 1 min | 2–4 |
| `debugedit` | `/nix/store/4gjq83smqp95wnmvspny1fxwchxznj5q-stage0-debugedit-5.1-8.el10` | 428K | 11 s | 2 |
| `kernelHeaders` | `/nix/store/hqy1zz8hllm324188b816g8bnji0ksyp-stage0-kernel-headers-6.18.7` | 9.3M | 3 s | 2 |
| `buildroot` (base layer) | `/nix/store/c8cqyahsj7nixh93bpxbjalf326vnrd2-stage0-root` | 479M | seconds | |
| `buildrootRelease` (layer) | `/nix/store/njpm5gab1l36r9yn5x9ispfy2svbad96-buildroot-stage0-release` | 1.2M | seconds | |
| `buildrootFullA` (layer) | `/nix/store/2d4d34g8gknd6g19bsibacw04rjbdk8c-buildroot-stage0-full-a-3` | 672K | seconds | |
| `buildrootFull` (layer) | `/nix/store/9ycgffhsrl70hqrd9hnb7r5w961y486j-buildroot-stage0-full` | 1.1M | seconds | |
| `srpm.rocky-release` | `/nix/store/y57lqghn7qrpakcj3x35kdyspdrwl4vj-srpm-rocky-release-10.2-1.2.el10` | 312K | ~5 s | |
| `srpm.redhat-rpm-config` | `/nix/store/0f5y1pr267ir74afzj9sxw49779qi28k-srpm-redhat-rpm-config-295-1.el10.rocky.0.2` | 256K | ~5 s | |
| `srpm.which` | `/nix/store/mc75ikyzqf55mrrfzw9bhzvknl7bfkp6-srpm-which-2.21-44.el10_0` | 328K | < 1 min | |
| `rpms.which` | `/nix/store/pf4b8p0zvxbzss2xzrnsravh7gjd8bcb-rpm-which` | 112K | seconds | |
| `tests.toolchain` | `/nix/store/xsyjclzr0b76ibxhvqr9zs4bfy4arwxj-stage0-test-toolchain` | | | |
| `tests.macros` | `/nix/store/9in24v7m4f1bq4x8lv72r9kwd0qzilg8-stage0-test-macros` | | | |
| `tests.whichRpms` | `/nix/store/nvngnm6iy15cnzblig2mwh1pjj3va5xd-stage0-test-which-rpms` | | | |

Every SRPM build output is a few hundred KB and references nothing
(`allowedReferences = [ ]`); buildroot layers above the base are ~1 MB each.

**Toolchain acceptance (`tests.toolchain`, also in stage0-full)** — all pass:
`gcc -dumpmachine` = `x86_64-redhat-linux`; include search list
`/usr/lib/gcc/x86_64-redhat-linux/14/include, /usr/local/include,
…/include-fixed, /usr/include` (C++: `/usr/include/c++/14` first); every
`-print-file-name=` answer under `/usr`; C, C++, shared library, `-m32`,
`-static` and `-flto` programs build **and run**; PT_INTERP
`/lib64/ld-linux-x86-64.so.2` (`/lib/ld-linux.so.2` for `-m32`), no
RPATH/RUNPATH, no `/nix/store` string even in unstripped `-g` binaries;
`/lib64/ld-linux-x86-64.so.2 --list` resolves libstdc++/libc from `/lib64`;
`-fcf-protection` binaries carry IBT+SHSTK.

**stage0-full `rpm --eval` (`tests.macros`)** — `%dist .el10`, `%rhel 10`,
`%el10 1`, `%_target_platform x86_64-redhat-linux-gnu`, and

```
%optflags = -O2 -flto=auto -ffat-lto-objects -fexceptions -g -grecord-gcc-switches -pipe -Wall
  -Wno-complain-wrong-lang -Werror=format-security -Wp,-U_FORTIFY_SOURCE,-D_FORTIFY_SOURCE=3
  -Wp,-D_GLIBCXX_ASSERTIONS -specs=/usr/lib/rpm/redhat/redhat-hardened-cc1 -fstack-protector-strong
  -m64 -march=x86-64-v3 -mtune=generic -fasynchronous-unwind-tables -fstack-clash-protection
  -fcf-protection -mtls-dialect=gnu2 ...
%build_ldflags = -Wl,-z,relro -Wl,--as-needed -Wl,-z,pack-relative-relocs -Wl,-z,now
  -specs=/usr/lib/rpm/redhat/redhat-hardened-ld -specs=/usr/lib/rpm/redhat/redhat-hardened-ld-errors
  -Wl,--build-id=sha1
```

i.e. Rocky 10's flags minus `-specs=/usr/lib/rpm/redhat/redhat-annobin-cc1`
(stage0 hack). A test program built with them is PIE, BIND_NOW, IBT+SHSTK,
"x86 ISA needed: x86-64-v3", no RUNPATH. Package notes are active inside
rpmbuild (`%_package_note_flags` is only defined there).

**`which` (`srpm.which`, `tests.whichRpms`)** vs the official
`which-2.21-44.el10_0.x86_64.rpm`: identical Requires (incl.
`GLIBC_ABI_DT_RELR`, max `GLIBC_2.34`), Provides and file list (only the
`.build-id` link name differs); `/usr/bin/which` has the same section list
(incl. `.gnu_debugdata` minidebuginfo and `.relr.dyn`), same dynamic flags
(`NOW PIE`), same GNU property note and the same
`FDO_PACKAGING_METADATA {"type":"rpm","name":"which","version":"2.21-44.el10_0",
"architecture":"x86_64","osCpe":""}` note. which-debuginfo/-debugsource are
produced (find-debuginfo + dwz + gdb-add-index). No `/nix/store` string in any
payload, debuginfo included. `rpms.which` (rpmTree, `allowedReferences = [ ]`)
builds; so do all 19 `rpms.*`.

**Macro packages vs official RPMs**: redhat-rpm-config (42 files) and
python-srpm-macros (8 files) are **byte-identical** to Rocky's (same Requires,
Provides, file list, file digests and modes).

## Known gaps / next steps

* rust-srpm-macros (from the rust SRPM) is not installed in stage0-full.
* Annobin: build Rocky's annobin SRPM in stage0 against the stage0 gcc's plugin
  headers, then drop `%_annobin_gcc_plugin %{nil}`.
* The glibc SRPM is built (milestone 1): see [glibc.md](glibc.md) for its
  buildroot (`mkRoot` + `glibcBuildDeps` + `fullRpms`) and results.
* Kernel headers: Rocky's kernel-headers RPM is built (`kernelHeadersBuild`,
  see [kernel-headers.md](kernel-headers.md)) and installed into the glibc
  buildroot with rpm (registered in the rpmdb); `buildrootFullKernelHeaders`
  is stage0-full with it instead of nixpkgs' headers. The stage0 *toolchain*
  still uses nixpkgs' 6.18 headers (swapping would rebuild glibc/gcc for no
  shipped benefit).
* `mkBuildroot` cannot represent deletions of lower-layer files (fails
  loudly); later stages installing with scriptlets may need a "flatten" mode.
* Later stages: `rpm --root` installs with `installFlags = [ ]` (deps +
  scriptlets) and no `--store`. **Non-root owners** recorded in RPMs cannot
  be applied in the single-uid namespace: rpm's `fchown` to an unmapped
  uid/gid fails and aborts the package ("cpio: chown failed - Device or
  resource busy" for filesystem's `root:mail /var/spool/mail`; "- No such
  file or directory" in another reproduction). Today the only such path in
  the glibc runtime roots is excluded (`--excludepath=/var/spool/mail`).
  Options for stage1: run the unpack as a non-zero uid with the needed
  capabilities (rpm only chowns when `getuid() == 0`), or a chown shim, and
  then restore owners and modes from the rpmdb at the final image step
  (`rpm --setugids --setperms`).
* **Owners and modes are not representable in store layers**: every file
  of a layer appears as `nobody` with the store's `0444`/`0555` modes in the
  next chroot (`/etc/shadow` of setup is `0000` in the RPM). The rpmdb in the
  layer still records the intended values, so an image built from layers
  must re-apply them (`rpm --setperms --setugids`), and `rpm -V` inside a
  stage0/stage1 chroot reports mode/owner mismatches for such files.
