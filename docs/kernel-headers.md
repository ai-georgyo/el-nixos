# kernel-headers: Rocky's kernel SRPM built headers-only in stage0

`packages/kernel-headers.nix`, wired up in `bootstrap/default.nix`. Background
research, including why the full kernel is not built: [research/kernel-headers.md](research/kernel-headers.md).

## TL;DR

* We run a real `rpmbuild --rebuild` of `kernel-6.12.0-211.66.1.el10_2.src.rpm`
  in stage0. Every kernel, tools, perf, selftests, doc and UKI variant is
  switched off, and `configchecks` stays **on**.
* It produces `kernel-headers-6.12.0-211.66.1.el10_2.x86_64.rpm` (plus the empty
  `kernel-modules-extra-matched` meta package, which the spec always emits).
* Compared with the official RPM:
  * NEVR, provides, obsoletes, requires and the metadata tags are the same.
  * The file list is the official one minus exactly the 21 known leaked
    tools-header paths.
  * Every common file is byte-identical, with the same mode, owner, mtime and
    digest.
* **What the glibc buildroot should consume:**
  * the RPM spec `{ from = stage0.kernelHeadersBuild; names = [ "kernel-headers" ]; }`,
    for mkBuildroot's `rpms` list (`kernelHeadersPkg.rpmSpec` inside bootstrap/), or
  * better, the ready-made buildroot `stage0.buildrootFullKernelHeaders`. This is
    stage0-full with the nixpkgs headers removed and Rocky's kernel-headers
    installed and registered in the rpmdb. See "Which attr to consume" below.

## Attributes (`legacyPackages.x86_64-linux.stage0.*`)

| attr | what |
|---|---|
| `kernelHeadersBuild` (= `srpm.kernel`) | `buildSrpm` result: `$out/RPMS/x86_64/kernel-headers-6.12.0-211.66.1.el10_2.x86_64.rpm`, `…/kernel-modules-extra-matched-…rpm`, `$out/SRPMS/kernel-…src.rpm`, `$out/logs/` |
| `rpms.kernel-headers` | `rpmTree` of it (`$out/usr/include/…`), `allowedReferences = [ ]` |
| `buildrootKernel` | the build environment: `buildrootFull` + one new layer (see below) |
| `buildrootFullKernelHeaders` | stage0-full on a root **without** nixpkgs' headers, with kernel-headers installed via `rpm -i` |
| `tests.kernelHeaders` | check derivation: our RPM vs `officialRpms."kernel-headers.x86_64"` (`report.txt`) |
| `tests.kernelHeadersBuildroot` | in-chroot check of `buildrootFullKernelHeaders` (rpmdb, ownership, version.h, gcc -m64/-m32) |
| `tests.toolchainKernelHeaders` | the stage0 toolchain acceptance test (`tests/toolchain.sh`) run in `buildrootFullKernelHeaders` |

The `tests.*` entries are also `checks.x86_64-linux.*`.

`srpm.kernel` is the **headers-only** variant. When BaseOS work builds the full
kernel later, that build should get its own attribute, so the cheap headers
build stays separate (research §6).

## The build

```
rpmbuild --rebuild kernel-6.12.0-211.66.1.el10_2.src.rpm --target x86_64 --nodeps \
  --without debug --without up --without realtime --without perf --without libperf \
  --without tools --without ynl --without selftests --without debuginfo --without kmap \
  --without cross_headers --without doc --without efiuki --without kabichk \
  --without kabidwchk --without vdso_install \
  + buildSrpm's usual defines (dist .el10_2, _buildhost, SOURCE_DATE_EPOCH from changelog, -jN)
```

What runs:

1. `%prep` unpacks the 153 MB tarball and applies the Rocky debrand patch with
   `git apply`.
2. `%py3_shebang_fix` runs.
3. `generate_all_configs.sh` runs, followed by the Secure Boot cert block
   (`openssl x509 -inform der` on the `rocky-sb-certs` files).
4. `process_configs.sh -w -n -c 6.12.0` runs. This is configchecks: 20
   configs × `listnewconfig`/`olddefconfig` with dummy cross tools.
5. `%build` runs only `InitBuildVars`, which does `make mrproper` and copies
   `.config`.
6. `%install` runs `make ARCH=x86_64 headers_install` and `%files headers`
   packages the result.

The only build warnings are `NOKEY` (the SRPM signature) and
`File not found: …/usr/include/cpufreq.h`. The second one comes from the
spec's `%exclude`, because cpupower is not built. It is a warning, not an error.

### Build environment: `buildrootKernel`

This is a **new layer on top of `buildrootFull`**, so the base root and the
toolchain derivations are untouched. It is built with `mkBuildroot` and
contains:

* `rpm -i` of **python3-rpm-macros + python-rpm-macros** (from `srpm.python-rpm-macros`).
  These are needed because `%py3_shebang_fix` is defined in `macros.python3`.
  stage0-full only carries python-srpm-macros, and the first attempt failed in
  `%prep` with `%py3_shebang_fix: fg: no job control`, which is how the
  unexpanded macro shows up.
* `rpm -i` of **kernel-rpm-macros** (from `srpm.kernel-srpm-macros`). It is in
  the effective BuildRequires, and Rocky's buildroot has it.
* symlinks `/usr/bin/{openssl,rsync,bc}` → nixpkgs (`extraCommands`). They are
  used as follows:
  * `openssl`: the `%prep` cert conversion.
  * `rsync`: `headers_install`.
  * `bc`: listed in BuildRequires but not run by this path. It is included
    because it costs nothing.

  The layer build asserts that the sb-cert files `%prep` reads exist.

Everything else the headers-only path uses was already in stage0:
* bash as `/bin/sh`
* gawk at `/usr/bin/awk`
* python3, perl, git, flex, bison, make, tar, xz
* the stage0 gcc, used as the host compiler for kconfig, fixdep, unifdef and relocs
* `rocky-sb-certs`, which `buildrootRelease` installs together with rocky-release

`%_arch`/`%_isa` come from the stage0 rpm's platform macros, so the automatic
`kernel-headers(x86-64)` provide is present. The research notes called this
pitfall out for nixpkgs rpm 4.20. It does not apply here.

### configchecks

`configchecks` is **on** by default (`configchecks ? true` in
`packages/kernel-headers.nix`), as it is in Rocky's real build. It was tested:
`process_configs.sh -w -n -c` passes with the stage0 toolchain, and the
resulting kernel-headers RPM passes the same check as the build with it off.
Its cost is the same 20 `olddefconfig` runs, which happen anyway, plus the
mismatch checks. If a future toolchain change makes the checks trip, pass
`configchecks = false`. That does not change the payload, because the
configs never reach UAPI.

## Verification (`tests.kernelHeaders`)

The check derivation (`packages/kernel-headers.nix`, `check`) uses the stage0
rpm outside the chroot. It **fails** on any of the following:

| check | result |
|---|---|
| NEVR = `kernel-headers-6.12.0-211.66.1.el10_2`, for ours and for the official RPM | PASS |
| epoch, arch, sourcerpm equal | PASS |
| exactly 2 binary RPMs: kernel-headers, kernel-modules-extra-matched | PASS |
| tags SUMMARY, DESCRIPTION, LICENSE, GROUP, URL, OS, PLATFORM, RPMVERSION equal | PASS |
| provides include `kernel-headers(x86-64) = 6.12.0-211.66.1.el10_2` | PASS |
| provides, obsoletes, conflicts, weak deps identical | PASS (`glibc-kernheaders = 3.0-46`, `kernel-headers`, `kernel-headers(x86-64)`; obsoletes `glibc-kernheaders < 3.0-46`) |
| requires identical (only `rpmlib()` allowed to differ) | PASS. In fact they are fully identical, including the `PayloadIsXz` rpmlib entry. |
| no `/nix/store` in any header tag | PASS |
| no paths only in ours | PASS: 1065 ours, 1086 official, 1065 common |
| paths only in official == the 21 leaked tools-header paths (hard-coded list) | PASS |
| per-file mode, owner, group, mtime, digest, flags, link target identical for every common path | PASS |
| extracted payloads `diff -r` (official minus the 21 paths) | PASS |
| content oracle from the research notes (`3c2cc557…f8d3f8`) | PASS |
| payload has no `/nix/store` strings | PASS |

Informational differences, all of which are expected:

| tag | ours | official |
|---|---|---|
| BUILDHOST | el-nixos.localdomain | hou1-build-x86-01.releng.rockylinux.org |
| BUILDTIME | 1792022400 (changelog date) | 1792061892 |
| VENDOR / PACKAGER | (none) | Rocky Enterprise Software Foundation / Release Engineering |
| SIZE | 7022925 | 7073348 (the 21 extra files) |
| signature | none | RSA/SHA256 key 6fedfc85 |

The payload format is the same as the official one (xz, level `3T`): the spec
sets it.

### The 21 paths

```
/usr/include/cpuidle.h  /usr/include/powercap.h
/usr/include/internal/{,cpumap,evlist,evsel,lib,mmap,rc_check,threadmap,xyarray}.h   (dir + 8)
/usr/include/perf/{,bpf_perf,core,cpumap,event,evlist,evsel,mmap,perf_dlfilter,threadmap}.h  (dir + 9)
```

In the full kernel build, libperf's `install_headers` and cpupower's `install`
write into the shared buildroot, and `%files headers` is `/usr/include/*`
(minus `cpufreq.h`/`ynl`). That is how these files end up in the official
kernel-headers, even though libperf-devel and kernel-tools-libs-devel own them
too. A headers-only build cannot produce them. We do not fake them, and
nothing on the glibc path uses them.

## Which attr to consume (for the glibc track)

glibc.spec needs `kernel-headers` **registered in the rpmdb**. Its sysroot
step runs `rpm -ql kernel-headers | … install -D`. If the package is not
registered, the sysroot package silently ships without kernel headers. So the
headers must come in as an RPM, not as a tree.

The stage0 base root (`stage0.buildroot`) already contains nixpkgs'
**linuxHeaders 6.18** in `/usr/include`, copied in by `root.nix` from
`bootstrap/kernel-headers.nix`. Installing Rocky's RPM on top overwrites the
common files. However, **21 headers exist only in 6.18** (`linux/coredump.h`,
`linux/ovpn.h`, `linux/psp.h`, `linux/io_uring/query.h`, `config/kernel.release`,
…), and they would stay behind, because a layer cannot delete lower files.
Two options:

1. **`stage0.buildrootFullKernelHeaders` (recommended).** It is the same layer
   stack as `buildrootFull`:
   * The bottom layer is replaced with `stage0-root-nokh`. That is `root.nix`
     called with `fhsTrees = [ glibc binutils gcc ]` (no kernel headers); the
     file itself is unmodified.
   * The unchanged release/macro layers sit on top. None of them touches
     `/usr/include`.
   * The final layer runs `rpm -i --nodeps --noscripts` of kernel-headers.

   `tests.kernelHeadersBuildroot` verifies the result:
   * `rpm -q` gives the right NEVR.
   * `rpm -ql` lists 1065 paths.
   * `rpm -V` content is clean (owner, mode and mtime cannot verify in store
     layers).
   * Every file in the kernel UAPI dirs is owned by kernel-headers. The
     exception is `scsi/{scsi,scsi_ioctl,sg}.h`, which glibc owns, as on Rocky.
   * `version.h` has `RHEL_MAJOR 10` and LINUX_VERSION_CODE 6.12.
   * gcc `-m64`/`-m32` programs build and run.

   `tests.toolchainKernelHeaders` runs the full toolchain test there, and it
   passes.

   Use it as the `base` of the glibc buildroot:
   `mkBuildroot { base = stage0.buildrootFullKernelHeaders; rpms = [ …other BRs… ]; }`.
2. Add `{ from = stage0.kernelHeadersBuild; names = [ "kernel-headers" ]; }` to
   the `rpms` of any `mkBuildroot` on top of `buildrootFull`. This is fine if
   the 21 stale 6.18-only headers are acceptable. glibc 2.39 uses none of them.

The stage0 **toolchain** itself (stage0 glibc, gcc's sysroot) was still built
against nixpkgs' 6.18 headers. Swapping `kernelHeaders` for the toolchain would
rebuild glibc and gcc, which takes about an hour. It is not needed: the stage0
toolchain does not ship.

## Results (nixbuild.net, 2026-10-18)

| attr | store path |
|---|---|
| `kernelHeadersBuild` | `/nix/store/8jb83lpypx42k3wdvp0r1v2lm44y3kij-srpm-kernel-headers-6.12.0-211.66.1.el10_2` (kernel-headers RPM 3,513,297 bytes; official 3,527,657) |
| `rpms.kernel-headers` | `/nix/store/lh9qkjr4r711gipqp1y2gjc3qcy3f31i-rpm-kernel-headers` (9.2M, references nothing) |
| `buildrootKernel` | `/nix/store/pwzhc1h9xv6i08zwk4p77csvxqjmpxwb-buildroot-stage0-kernel` (552K layer) |
| `buildrootFullKernelHeaders` | `/nix/store/0lqhiwknqs24n36hvwc6kz972xh24jqw-buildroot-stage0-full-kernel-headers` (12M layer) on `/nix/store/qvkml3mv8nrcd2qq6q45y9s5hnb6y4m8-stage0-root-nokh` |
| `tests.kernelHeaders` | `/nix/store/nv1abj71jb25py6pfyxxgcf9n4nbffn5-check-kernel-headers-vs-official` — ALL KERNEL-HEADERS CHECKS PASSED |
| `tests.kernelHeadersBuildroot` | `/nix/store/l7aim40mc8231g3lv695ql3564hw9bsq-stage0-test-kernel-headers-buildroot` — ALL CHECKS PASSED |
| `tests.toolchainKernelHeaders` | `/nix/store/3qml4mmpx2vx1ss4kk2fb0vi4y0p0jkp-stage0-test-toolchain-kernel-headers` — ALL TOOLCHAIN CHECKS PASSED |

The rpmbuild ran with `-j16` on the builder it was given, and took a few
minutes, mostly the xz unpack and the config runs. The output is ~5 MB and
references nothing.

## Not done / later

* `kernel-modules-extra-matched` (the empty meta package, 1.7 MB because of
  the changelog) is built but not compared with the official one, and not
  exposed as an `rpms.*` tree.
* `kernel-cross-headers` (`--without cross_headers`): it is cheap to turn on,
  but nothing on the glibc path needs it.
* Stage1+: under real BuildRequires checking, the headers-only build still
  lists ~40 BRs. See research §6 for the options.
