# Research: kernel-headers from the Rocky kernel SRPM

Status: research notes (track "kernel headers"), 2026-10-18. Nothing here is
wired into the flake yet.

Inputs examined:

| what | value |
|---|---|
| SRPM | `BaseOS/source/tree/Packages/k/kernel-6.12.0-211.66.1.el10_2.src.rpm`, sha256 `229d1273…4e3c`, 159,659,270 bytes (matches `lock/rocky-10.2/srpms.json`) |
| Official binary | `AppStream/x86_64/os/Packages/k/kernel-headers-6.12.0-211.66.1.el10_2.x86_64.rpm`, sha256 `e725ab37559786f1038b27e2b87ecc817d5307c62e13ecd9cf9e8feb9339bd4c`, 3,527,657 bytes |
| sb certs (needed by `%prep`, see below) | `CRB/x86_64/os/Packages/r/rocky-sb-certs-10.2-1.2.el10.noarch.rpm`, sha256 `43c4411461a54d943ecd7159edfbec9409f8c28688d4b312246d95f681db88e1`, built from the **rocky-release** SRPM |

Lockfile notes:
* `kernel-headers` ships in **AppStream**, but its SRPM is in **BaseOS**.
  `kernel-cross-headers` ships in **CRB**.
* The binary repos keep **all 32** 10.2 kernel-headers builds (211.16.1 to 211.66.1).
  The generator has to choose the binary whose `sourcerpm` equals the locked SRPM.

---

## TL;DR

* `kernel-headers` comes from `%install` alone: `make ARCH=x86_64 INSTALL_HDR_PATH=$RPM_BUILD_ROOT/usr headers_install`,
  followed by a `find … -delete` of `.install`/`.check`/`..install.cmd`/`..check.cmd`.
  It does not need a kernel build, a `.config`, or any patches that touch UAPI. The only
  Rocky patch (`1000-debrand-some-messages.patch`) changes `kernel/rh_messages.h`, which is not UAPI.
* **Minimal rpmbuild (tested locally, it works):**
  ```
  rpmbuild --rebuild kernel-6.12.0-211.66.1.el10_2.src.rpm --nodeps --target x86_64 \
    --without debug --without up --without realtime \
    --without perf --without libperf --without tools --without ynl \
    --without selftests --without debuginfo --without kmap \
    --without cross_headers --without doc --without efiuki \
    --without kabichk --without kabidwchk --without configchecks \
    --without vdso_install
  ```
  It produces exactly two RPMs: `kernel-headers-6.12.0-211.66.1.el10_2.x86_64.rpm` and
  `kernel-modules-extra-matched-…x86_64.rpm` (an empty meta package that is always emitted on
  build arches). It took 45 s wall time on 16 local cores, with about 1.9 GB peak scratch,
  almost all of it the unpacked source tree.
* **The fallback (plain `make headers_install` on the tarball) produces byte-identical output**
  to the rpmbuild route. Both give **1065 paths (1015 files + 50 dirs)**. Every one of those files
  is byte-identical to the file of the same name in the official RPM.
* The official RPM has **1086 paths (1034 files + 52 dirs)**. The 21 extra paths are
  **userspace-tools headers that leak into `kernel-headers`** because the full build installs
  libperf/cpupower into the same buildroot and `%files headers` is `/usr/include/*`:
  `/usr/include/perf/*` (9 files + dir), `/usr/include/internal/*` (8 files + dir),
  `/usr/include/cpuidle.h`, `/usr/include/powercap.h`. These files are also owned by
  `libperf-devel` and `kernel-tools-libs-devel`. glibc does not use any of them.
* **Recommendation:** stage0 should use the **minimal rpmbuild** (it fits the DESIGN.md build
  model, is cheap, and gives a real RPM that can be registered in the buildroot rpmdb, which glibc.spec
  needs, see "glibc consumer notes"). Keep the fallback as a test oracle and as an emergency
  unblocker. Later (stage1+), keep the headers-only invocation as its own build variant of the
  kernel SRPM. Only build the full kernel when BaseOS work reaches the kernel packages. If byte-for-byte
  file-list parity matters, decide on the 21 leaked files then.

---

## 1. How kernel.spec builds kernel-headers

The spec is 1.9 MB, of which lines 4568 and later are `%changelog`. The relevant pieces:

### 1.1 Switches (spec lines ~203–300)

All switches are `%define with_X %{?_without_X: 0} %{?!_without_X: 1}`, so they are toggled with
`--without X` (or `--with X` for the default-off ones). Defaults and effect on x86_64:

| macro | default x86_64 | what it gates | needed off for headers-only? |
|---|---|---|---|
| `with_headers` | 1 | `%package headers`, `headers_install` in `%install`, `%files headers`; also `BuildRequires: rsync` | keep **on** |
| `with_cross_headers` | 1 | `kernel-cross-headers` (headers_install for arm64 powerpc s390 x86 riscv into `/usr/<arch>-linux-gnu/include`) | optional; cheap (5 extra headers_install runs) but glibc does not need it → off |
| `with_up` | 1 | standard kernel `BuildKernel` | **yes**: otherwise a full kernel build runs |
| `with_base` | 1 | base (non-debug) variants; also gates kmap | leave; turn kmap off instead |
| `with_debug` | 1 | debug kernel variants | **yes** |
| `with_realtime` | 1 (x86_64/aarch64) | kernel-rt + rt-debug builds | **yes** |
| `with_perf` / `with_libperf` | 1 | perf, python3-perf, libperf(-devel) | **yes** (heavy, many BRs) |
| `with_tools` | 1 | kernel-tools, cpupower, rtla, rv, bpftool bootstrap … | **yes** |
| `with_ynl` | 1 | tools/net/ynl (only built when tools on) **and** `%exclude /usr/include/ynl` in `%files headers` | off (avoids a "File not found" warning; not fatal) |
| `with_selftests` | 1 | kselftests (+ an extra in-tree `headers_install`, `modules_prepare`) | **yes** |
| `with_debuginfo` | 1 | `kernel-debuginfo-common-x86_64`, find-debuginfo, `BuildRequires: rpm-build, elfutils` | off (otherwise an extra debuginfo-common RPM is emitted) |
| `with_kmap` | 1 | `kernel-kmap-internal` (gated on `with_kmap && with_base`) | **yes**: with `--without up`, `%install` would try to install a `kernel-map.json` that was never generated |
| `with_doc` | 1, but forced 0 on non-noarch | kernel-doc | already off on x86_64 |
| `with_efiuki` | 1 (x86_64) | UKI build (dracut, systemd-ukify, …) | no runtime effect without `up`; turning it off removes ~12 BuildRequires |
| `with_kabichk`, `with_kabidwchk` | 1 | kABI checks in BuildKernel; `BuildRequires: kabi-dw` | no runtime effect without `up`; trims BRs |
| `with_configchecks` | 1 | `process_configs.sh -w -n -c` in `%prep` (error on config mismatches) | off is safer: a different toolchain could trip mismatch errors. Untested with it on. |
| `with_vdso_install` | 1 | vdso dirs | no effect without kernels |
| `with_kernel_abi_stablelists` | forced 0 on non-noarch | — | — |
| `with_zfcpdump`, `with_arm64_16k/64k`, `with_realtime_arm64_64k` | forced 0 on x86_64 | — | — |

The following options **do not exist** in this spec: `headers_only`, `--with toolsonly`, `with_bpftool`.
Use the `--without` list above. Shortcuts that exist but do not help:
* `--with baseonly` still builds the base kernel.
* `--with rtonly` and the automotive options set `with_headers 0`.
* `--target noarch` disables headers.

**Not controllable from the command line:** `signkernel` (by arch) and `signmodules` are `%global`
in the spec. I verified with rpm 4.20 that a spec `%global` overrides `--define`. As a result
`BuildRequires: openssl, system-sb-certs, nss-tools, pesign >= 0.10-4` stay in effect, and the
`%prep` cert block always runs (see 1.2). `pesign` and `nss-tools` are never executed in the
headers-only configuration. `openssl` and the sb-certs files are.

### 1.2 `%prep` (lines 1903–2190): runs fully even for headers-only

On x86_64 (not in `%nobuildarches`), `%prep` does all of the following:
1. `%setup -q -n kernel-6.12.0-211.66.1.el10_2 -c`, then renames the tree to `linux-%{KVERREL}`.
   Copies `Makefile.rhelver` (Source1) into the tree. This file is already identical in the tarball.
2. `ApplyOptionalPatch`: patches with 9 or fewer lines are skipped. `patch-6.12-redhat.patch` and
   `linux-kernel-test.patch` are empty. `1000-debrand-some-messages.patch` (Rocky, 23 lines) is
   applied with **`git --work-tree=. apply`**, so `git` is required.
3. `mv COPYING COPYING-…`, `rm -f localversion-next localversion-rt`, `%py3_shebang_fix …`
   (needs python-rpm-macros), and SBAT `sed`.
4. Config generation, in `configs/`:
   * `generate_all_configs.sh` is **`#!/bin/sh` with bashisms (`${i:n}`)**, so `/bin/sh` must be bash.
     Under dash it fails with "Bad substitution".
   * `merge.py` is `#!/usr/bin/python3`.
   * The **cert block** runs `openssl x509 -inform der` on
     `%{_datadir}/pki/sb-certs/{kernel-dup1,kernel-kpatch1,kernel-nvidiagpuoot101}-%{_arch}.der` and
     `rocky-ima-ca.crt`. These files come from `rocky-sb-certs` (Provides `system-sb-certs`), a
     subpackage of the **rocky-release** SRPM that stage0 already plans to build for `macros.dist`.
     The block also needs `%{_arch}` to be defined.
   * `process_configs.sh` (bash) calls **`/usr/bin/awk` by absolute path**. It runs
     `make listnewconfig` and `olddefconfig` for each of the 20 configs, across all 5 arches, with
     `CROSS_COMPILE=scripts/dummy-tools/`, so no cross compilers are needed. This builds
     `scripts/kconfig/conf`, which needs host gcc, flex and bison.
5. Removes `*.orig`, `*~` and `.gitignore` files.

### 1.3 `%build` (2194–3380) for headers-only

With every kernel variant off, no `BuildKernel` runs. The block
`%if !with_debug && !with_up && … && !with_automotive` calls `InitBuildVars` once. That function
runs `perl -p -i` to edit `EXTRAVERSION` and `PATCHLEVEL` in the Makefile, then
`make mrproper`, then copies `configs/kernel-6.12.0-x86_64.config` to `.config`, then disables
DEBUG_INFO with `sed` if debuginfo is off. It then writes `../vmlinux_h_path`, which `%install`
reads. perf, tools, selftests and docs are all skipped.

### 1.4 `%install` (3474–) — where kernel-headers is produced

```sh
%{__make} ARCH=%{hdrarch} INSTALL_HDR_PATH=$RPM_BUILD_ROOT/usr headers_install   # hdrarch = x86_64
find $RPM_BUILD_ROOT/usr/include \( -name .install -o -name .check -o \
     -name ..install.cmd -o -name ..check.cmd \) -delete
```

In-tree, `headers_install` depends on `headers`. `headers` in turn needs `$(version_h)`,
`scripts_unifdef`, `uapi-asm-generic`, `archheaders` (x86 syscall table → `unistd_{32,64,x32}.h`)
and `archscripts` (x86 host tool `arch/x86/tools/relocs`). The final step is
`rsync -mrl --include='*/' --include='*.h' --exclude='*' usr/include $INSTALL_HDR_PATH`.
Tools exercised: make, host gcc (unifdef, fixdep, relocs), sh/sed/awk, **rsync**.
`linux/version.h` also carries the RHEL macros (`RHEL_MAJOR 10`, `RHEL_MINOR 2`,
`RHEL_RELEASE "211.66.1"`, `RHEL_RELEASE_CODE 2562`) from `Makefile.rhelver`.

### 1.5 `%files headers`

```
%files headers
/usr/include/*
%exclude %{_includedir}/cpufreq.h
%if %{with_ynl}
%exclude %{_includedir}/ynl
%endif
```
In the full build, libperf `install_headers` and cpupower `install` also put files in `/usr/include`
of the shared buildroot. Only `cpufreq.h` and `ynl` are excluded, so `perf/`, `internal/`,
`cpuidle.h` and `powercap.h` end up in kernel-headers (this is the upstream packaging quirk behind
the 21-path delta). In headers-only mode `cpufreq.h` does not exist. rpm treats the dangling
`%exclude` as a **warning, not an error** (I checked this with rpm 4.20 and a toy spec).

Package metadata: `Provides: glibc-kernheaders = 3.0-46`, `kernel-headers = EVR`,
`kernel-headers(x86-64) = EVR`, and `Obsoletes: glibc-kernheaders < 3.0-46`. It has no Requires
apart from rpmlib(). All files are `root:root`, files are 0644 and dirs 0755. Official file mtimes all
equal 1792022400, which is SOURCE_DATE_EPOCH from the `%changelog`. Our build gives the same value
with `source_date_epoch_from_changelog`.

### 1.6 Effective BuildRequires

Evaluated with `rpmspec -q --buildrequires --target x86_64 --define 'rhel 10' --define 'rocky 10' --define 'dist .el10_2'`
and the minimal `--without` set:

```
bash bc binutils bison bzip2 coreutils diffutils dwarves elfutils-devel findutils flex gawk
gcc gcc-c++ git-core glibc-static hmaccalc hostname kernel-rpm-macros kmod m4 make net-tools
nss-tools openssl openssl-devel perl-Carp perl-devel perl-generators perl-interpreter
pesign >= 0.10-4 python3 python3-devel python3-pyyaml redhat-rpm-config rsync system-sb-certs
tar which xz
BuildConflicts: rhbuildsys(DiskFree) < 500Mb
```
The default configuration has 86 BuildRequires, including clang/llvm, java-devel, dracut, lvm2,
systemd-ukify, libbpf/bpftool and numactl.

The headers-only path **actually executes** a much smaller set. This is what stage0 must provide
at FHS paths. Under `--nodeps`, the rest of the list is not needed.

| tool | used by |
|---|---|
| bash as `/bin/sh` and `%_buildshell` | generate_all_configs.sh bashisms, process_configs.sh |
| coreutils, findutils, sed, grep, `/usr/bin/awk` (gawk) | everywhere; awk path hard-coded |
| tar + xz (rpmuncompress) | `%setup` |
| git (`git apply`) | Rocky debrand patch |
| python3 at `/usr/bin/python3` | merge.py |
| openssl | `%prep` cert conversion |
| rocky-sb-certs files under `/usr/share/pki/sb-certs/` | `%prep` cert conversion |
| perl | InitBuildVars Makefile edits |
| make, gcc (host CC), flex, bison | kconfig `conf`, unifdef, fixdep, relocs |
| rsync | `headers_install` |
| rpm macro packages: redhat-rpm-config, kernel-rpm-macros (kernel-srpm-macros SRPM), python-rpm-macros (`%py3_shebang_fix`), `macros.dist` | spec expansion |

These are **not** used in headers-only mode: bc, dwarves, elfutils-devel, glibc-static, hmaccalc,
kmod, pesign, nss-tools, openssl-devel, python3-pyyaml, net-tools, hostname, which, m4, bzip2.

---

## 2. Practicality of rpmbuild in the stage0 chroot

It is practical, and I confirmed it end to end with an approximate setup. I used **nixpkgs rpm 4.20.1**
inside `bwrap`, with a nixpkgs bash bind-mounted over `/bin/sh` (the host's `/bin/sh` is dash).
Script: `/tmp/claude-60514/-run-host-home-ai-shammas-Code-el-nixos/dadc2aad-80ad-416a-b238-b2a3e0de53b8/scratchpad/research-kernel-scripts/rpmbuild-headers.sh`.

```sh
R=…/scratchpad/research-kernel      # srpm/ = rpm2cpio of the SRPM, sbcerts/ = rpm2cpio of rocky-sb-certs
B=$(nix shell nixpkgs#bash -c sh -c 'command -v bash')
nix shell nixpkgs#bubblewrap nixpkgs#rpm nixpkgs#gnumake nixpkgs#gcc nixpkgs#perl nixpkgs#python3 \
  nixpkgs#openssl nixpkgs#git nixpkgs#rsync nixpkgs#flex nixpkgs#bison nixpkgs#bc nixpkgs#xz \
  nixpkgs#gawk nixpkgs#which -c \
  bwrap --dev-bind / / --ro-bind "$B" /usr/bin/dash -- \
  bash rpmbuild-headers.sh $R/srpm $R/sbcerts $R/top
```
The script runs `rpmbuild -bb kernel.spec --nodeps --target x86_64` with the minimal `--without`
list plus these defines, which exist only because nixpkgs rpm has no Rocky macros:
`_arch x86_64`, `_buildshell /bin/bash`, `rhel 10`, `rocky 10`, `dist .el10_2`, `_prefix/_exec_prefix /usr`,
`_includedir /usr/include`, `_datadir <sbcerts>/usr/share` (a hack to locate the certs),
`py3_shebang_fix true`, `_smp_mflags -j16`, `source_date_epoch_from_changelog 1`,
`use_source_date_epoch_as_buildtime 1`, `clamp_mtime_to_source_date_epoch 1`.

Result: rc=0 in **45 s** on 16 cores. Most of that time is the xz unpack and 20 parallel
`olddefconfig` runs. `headers_install` takes a few seconds and runs serially, because `%install`
does not pass `_smp_mflags`. The build wrote the kernel-headers RPM (3.5 MB) and the empty
modules-extra-matched RPM. Payload: 1065 paths, all files `0644 root:root`, all mtimes 1792022400.
`diff -r` against the official RPM payload is clean apart from the 21 leaked files. There are
no `/nix/store` strings in the payload (`grep -rl /nix/store` is empty).

Estimate for nixbuild.net with 2 CPUs and 7 GB: about **2–4 min**. The xz unpack of the 153 MB
tarball is mostly single-threaded, and process_configs drops to 2-way parallel. Scratch disk
is about **2.0 GB** (1.8 GB tree, plus the SRPM in SOURCES, plus the RPMs). RAM is negligible.
`BuildConflicts: rhbuildsys(DiskFree) < 500Mb` is irrelevant under `--nodeps`.

Pitfalls this exposed for the **stage0 infra** (they apply beyond the kernel):
1. **nixpkgs rpm has no `lib/rpm/platform/` directory.** As a result `%_arch` and `%_isa` are
   undefined, even with `--target x86_64`. Without them the auto `kernel-headers(x86-64)` provide
   was **missing** from our RPM, and the same would happen to `glibc(x86-64)` and every other
   package. `%_arch` is also used directly by kernel.spec (certs) and glibc.spec (sysroot paths).
   Stage0 must ship `/usr/lib/rpm/platform/x86_64-linux/macros` or an equivalent, or set
   `_target_cpu`/`_arch`/`_isa`/`__isa_name x86`/`__isa_bits 64` through the macro setup.
2. **`/bin/sh` must be bash.** Rocky's `%_buildshell` is `/bin/sh`, and RHEL sources assume bash there.
3. `/usr/bin/awk`, `/usr/bin/python3`, `/usr/bin/perl` are needed at FHS paths, because shebangs
   and absolute calls use them.
4. rpm 4.20 warns that `%clamp_mtime_to_source_date_epoch` is deprecated in favour of `%build_mtime_policy`.
   Rocky 10 ships rpm 4.19. Set both macros in buildSrpm.
5. rpm 4.20 uses the per-build directory `BUILD/<name>-<ver>-build/`. Nothing in kernel.spec cared.

---

## 3. Fallback: plain `make headers_install` (proven)

Script: `/tmp/claude-60514/-run-host-home-ai-shammas-Code-el-nixos/dadc2aad-80ad-416a-b238-b2a3e0de53b8/scratchpad/research-kernel-scripts/headers-fallback.sh`.
It replays the exact steps from §1.2–1.4 that can affect the tree:

```sh
tar -xJf linux-6.12.0-211.66.1.el10_2.tar.xz && cd linux-6.12.0-211.66.1.el10_2
patch -p1 -s < 1000-debrand-some-messages.patch          # no effect on UAPI, kept for fidelity
cp -a Makefile.rhelver .                                  # identical to the in-tarball copy
mv COPYING COPYING-6.12.0-211.66.1.el10_2
find . -name .gitignore -delete
perl -p -i -e "s/^EXTRAVERSION.*/EXTRAVERSION = -211.66.1.el10_2.x86_64/" Makefile
perl -p -i -e "s/^PATCHLEVEL.*/PATCHLEVEL = 12/" Makefile
make -s mrproper
make ARCH=x86_64 INSTALL_HDR_PATH=$OUT/usr headers_install
find $OUT/usr/include \( -name .install -o -name .check -o -name ..install.cmd -o -name ..check.cmd \) -delete
```
Run with `nix shell nixpkgs#gnumake nixpkgs#gcc nixpkgs#rsync nixpkgs#perl nixpkgs#gnupatch`.
It takes 5 s (16 cores) and produces a 9.2 MB tree.

Strictly, only `make ARCH=x86_64 INSTALL_HDR_PATH=… headers_install` and the `find -delete` matter.
The `.install` files are not even present in 6.12 output; the deletion is a no-op kept for parity.
The EXTRAVERSION edit does not reach UAPI, because `version.h` uses only VERSION, PATCHLEVEL,
SUBLEVEL and the RHEL_* values. No arch asm handling is needed beyond `ARCH=x86_64`:
`/usr/include/asm` is a real directory produced by headers_install, not a symlink. No
headers patching beyond that is done by the spec.

Result vs official (`rpm -qpl` of the official RPM vs `find usr -mindepth 2`):
* paths only in the fallback: **none**
* paths only in official: exactly the 21 leaked tools headers listed in the TL;DR
* `diff -r` of the common files: **no differences**
* the fallback tree is byte-identical to the payload of the minimal-rpmbuild RPM from §2

Oracles for tests (computed over the 1015 files, `find usr -type f | LC_ALL=C sort | xargs sha256sum | sha256sum`):
* fallback / minimal rpmbuild tree: `3c2cc5570191a364648006ffca5e60e0c5cfea8fe89234aee003ee744297d3f8`
* official RPM minus the 21 leaked paths: `3c2cc5570191a364648006ffca5e60e0c5cfea8fe89234aee003ee744297d3f8` (identical)
* sha256 of the sorted 1065-line path list (`/usr/include/...`, one per line): `676b53ec902dcbda6d015ba1b1c0fba6ccf6399152bf01f4211967440fb639d3`

## 4. Expected file list (official 10.2 kernel-headers x86_64)

There are 1086 rpm entries: 1034 regular files and 52 directories, with no symlinks. Everything
is under `/usr/include`. Entries per top-level directory, with our headers-only build in parentheses
where it differs:

```
linux 822   asm 67   asm-generic 38   drm 33   rdma 32   sound 28   scsi 12   misc 10
mtd 6   xen 5   video 4   fwctl 4   regulator 2   cxl 2
perf 10 (0)   internal 9 (0)   cpuidle.h 1 (0)   powercap.h 1 (0)
```
Headers-only build: 1065 entries (1015 files + 50 dirs).

---

## 5. glibc consumer notes (for the glibc track)

* glibc.spec: `BuildRequires: kernel-headers >= 3.2`, `--with-headers=%{_prefix}/include`,
  `--enable-kernel=3.2`.
* **glibc.spec `%install` (`%if %{without bootstrap}`, sysroot package) runs
  `rpm -ql kernel-headers | grep ^/usr/include | while read f; do install -D "$f" "./$f"; done`**
  to copy the kernel headers into `sysroot-x86_64-…-glibc`. If kernel-headers is merely extracted
  into the stage0 root and not **registered in the buildroot rpmdb**, `rpm -ql` fails quietly
  inside the pipeline. The sysroot package then ships without kernel headers and nothing breaks
  to warn us. So stage0 should install the kernel-headers RPM with
  `rpm -i --nodeps --root <buildroot>` (or `--justdb` on top of an extracted tree). This
  is the main reason to prefer producing a real RPM (approach A) even in stage0.
* `asm/` must be the x86_64 one (`ARCH=x86_64`). It contains `unistd_32.h`, `unistd_64.h` and
  `unistd_x32.h`, which glibc's syscall-list generation consumes.

---

## 6. Recommendation

**Stage0, now: approach A, the minimal rpmbuild of the kernel SRPM.**
* Add `packages/kernel.nix` (or a variant attr such as `rocky.srpm.kernel-headers-only`) with
  `rpmbuildArgs` = the `--without` list above. Declare that this build produces only
  `kernel-headers` (+ `kernel-modules-extra-matched`). The lock's "SRPM produces N binaries"
  mapping (30 x86_64 RPMs for kernel) must not be assumed complete for this variant.
* Stage0 buildroot prerequisites: bash as /bin/sh, gawk at /usr/bin/awk, python3, perl, git, openssl,
  rsync, flex, bison, make, gcc, tar, xz, plus the Rocky macro packages (redhat-rpm-config,
  kernel-srpm-macros → kernel-rpm-macros, python-rpm-macros, rocky-release's macros.dist) and
  **rocky-sb-certs** (also from the rocky-release SRPM). Make sure the rpm platform macros define `%_arch`/`%_isa`.
* Cost: about 2–4 min and about 2 GB scratch on a 2-CPU nixbuild builder. One 160 MB fixed-output fetch.
* Verify with a check derivation that compares the extracted tree against the official RPM (fetched by sha256 from
  repodata) modulo the 21 known paths, or against the oracle hash above.

**Fallback / unblocker: approach B.** It is a ~10-line derivation (unpack the tarball from the
SRPM, then run `make ARCH=x86_64 headers_install` with nixpkgs make/gcc/rsync). Use it only
if the stage0 rpmbuild/macro infrastructure is not ready when glibc work needs headers, or as the
test oracle. It is byte-identical in content, but it has no RPM metadata and no rpmdb entry (see the
glibc sysroot caveat). The output has no store references, so `allowedReferences = [ ]` holds.

**Later (stage1+ / BaseOS):**
* Keep the headers-only invocation as a separate cheap build. glibc and everything else that needs
  `kernel-headers` should not wait on a multi-hour, multi-GB full kernel build.
* In stage1, BuildRequires are checked for real. The headers-only config still lists 40 BRs
  (dwarves, glibc-static, pesign, nss-tools, hmaccalc, python3-devel, …). Two options: build them
  all first, which glibc-static creates a cycle with glibc, or use `--nodeps` for this one
  build with a curated "really used" list as described in §1.6. The second option is recommended.
* The full kernel build (all 30 x86_64 RPMs: kernel-core, modules, rt, debug, devel, tools,
  perf, …) belongs in the BaseOS phase. That phase needs clang/llvm, java-devel, dracut/systemd-ukify,
  signing certs/pesign (the SB signing itself cannot be reproduced; unsigned is expected),
  and roughly 30–60 GB of disk and hours of build time.
* If exact file-list parity with the official kernel-headers matters, the full build reproduces
  the 21 leaked headers naturally. For the headers-only variant, document the difference. Do
  not fake it.

Rejected alternative: `rpmbuild --target i686`. i686 is in `%nobuildarches`, which skips the
config/cert `%prep` block and every kernel build. But it produces `kernel-headers.i686` with
`hdrarch=i386`, and redhat-rpm-config's i686 flags would apply. That is the wrong package arch
for the x86_64 repo, so the trick is not worth it now that the x86_64 path is shown to be cheap.
