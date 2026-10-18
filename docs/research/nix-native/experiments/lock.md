# WP1 lock: subpackages.json, builddeps.json, order.json

Work package WP1 of `docs/nix-native-design.md` (§3.1, §3.2, §8.2, §8.3).
Rocky 10.2 lock (`lock/rocky-10.2/`, 2217 SRPMs). Machine: shared 16 CPU box,
builds with `--cores 6 --max-jobs 2`.

## What was built

| file | producer | needs |
|---|---|---|
| `lock/rocky-10.2/builddeps.json` | `tools/lock_builddeps.py` (also run by `update-lock.py`) | committed lock + repodata `filelists.xml` (cached) |
| `lock/rocky-10.2/order.json` | `tools/lock_order.py` (also run by `update-lock.py`) | `builddeps.json` |
| `lock/rocky-10.2/subpackages.json` | `tools/lock_subpackages.py` over `nn.lockgen.subpackages.<srpm>` | nix, the SRPMs (FODs), stage0 |
| `checks.x86_64-linux.nn-order` | `lib/rocky/checks/order.nix` → `tools/lock_order.py --check` | the three lock files |

`tools/update-lock.py` now also writes builddeps/order after the repodata
files (`--no-derived` skips that, `--derived-only` regenerates them from the
committed lock without touching srpms/rpms/deps) and refreshes
`subpackages.json` (drops entries whose SRPM EVR changed, re-derives
`shipped`/`prefix`). Its `--self-test` additionally runs the helpers'
self-tests (tag rules, prefix rule, a toy graph for the FAS + checker,
including a tampered order). `rpmvercmp` was not touched.

Shared helper `tools/lock_filelists.py`: downloads the binary trees'
`filelists.xml.gz` (sha256 from repomd.xml, cached as
`.cache/repodata/<rel>/<repo>-binary-<sha>-filelists.xml.gz`, together
27 MB for the 3 repos) and reduces it to `{usr, bin, solib, macro}` per package of
`rpms.json`, matched by pkgid (= the locked sha256). All 3 repos still serve
the exact repodata of the lock (same primary checksums), so every package
matched.

## builddeps.json

Command: `python3 -I tools/lock_builddeps.py` (7.5 s for all 2217 SRPMs).

* Resolver: `tools/resolve-buildrequires.py` unchanged, mock rocky-10 model
  (buildsys transaction, then `dnf builddep`, `install_weak_deps=0`). Per
  BuildRequire the providers are the selected packages that provide one of
  its *active* leaves (a conditional whose condition is false asks for
  nothing; 38 such BRs, e.g. `(python3dist(tomli) if python3-devel < 3.11)`).
* Experiment: the BR-only model (no buildsys transaction, as the spike's
  "direct" graph) gives **identical inputs for all 2217 SRPMs**; the mock model
  was kept since it is the one validated against dnf5.
* Result: 23 347 BuildRequires → 21 443 direct inputs, 1918 distinct provider
  RPMs; 3 BRs have more than one provider in the buildroot.
* **Unresolved**: 222 SRPMs have ≥ 1 BuildRequire nothing in BaseOS/AppStream/CRB
  provides (226 distinct, 322 occurrences). Top: `gi-docgen` 21,
  `python3-dbusmock` 7, `rubygem-asciidoctor` 6, `umockdev-devel` 5,
  `pkgconfig(gi-docgen)` 5, `ucrt64-filesystem >= 133` 5, `asciidoctor` 4,
  `xxhash-devel` 4, `python3-fonttools` 4, `libqb-devel` 3, ... These are
  build-only packages Rocky does not publish (and glibc's
  `(glibc32 or glibc-devel(x86-32))`: glibc32 is an unshipped subpackage of
  glibc itself). They are listed per SRPM (`unresolved`), not guessed.
* Tags (from filelists): `tool` = a file in `/usr/bin|/usr/sbin|/bin|/sbin`;
  `lib` = `-devel`/`-static`/`-headers` name or a shared library
  `/usr/lib{,64}/lib*.so*`; `macro` = rpm macro files
  (`/usr/lib/rpm/macros.d/*`, `/usr/lib/rpm/{,redhat/}macros`,
  `/etc/rpm/macros.*`); `other` otherwise. Distribution over the 1918
  providers: other 803, lib 547 (+ lib/tool 92, lib/macro 10,
  lib/macro/tool 6), tool 416, macro 29 (+ macro/tool 15).
  A first version also counted headers and `.pc` files as `lib`; that tagged
  `make` (ships `gnumake.h`) and `gdb` (`jit-reader.h`) as libraries, so it was
  dropped.

## order.json

Command: `python3 -I tools/lock_order.py` (0.2 s); check:
`python3 -I tools/lock_order.py --check lock/rocky-10.2`.

Graph S → T when a direct input of S is built from SRPM T. Edge classes per
provider: doc/test/lang name patterns of the spike `cycles.py`, then `lib`
(spike `LIB` pattern or the `lib` tag), `macro` (tag `macro` only), else
`tool`. SCCs by an iterative Tarjan, the Eades-Lin-Smyth heuristic inside
each SCC, components in dependency order (Kahn, ties by name); all
iteration sorted, so the output does not depend on Python's hash seed (two
runs with different seeds gave byte-identical files).

| quantity | this lock | spike [BP-1/2] |
|---|---|---|
| edges (S ≠ T) | **18 721** | 18 721 |
| self-loops | 33 | 33 |
| non-trivial SCCs | 3: 926, 2 (jaxb ↔ jaxb-istack-commons), 2 (python3.14-pybind11 ↔ python3.14-scipy) | largest 926 |
| back edges (S ≠ T) | 773 (tool 374, lib 251, lang 93, doc 47, test 30, macro 17) | 771 |
| boot targets (incl. self-loops) | 282 | 265 (without self-loops) |
| SRPMs with a back edge | 339 | 337 |
| second pass (lib back edge) | 152 | 144 |
| levels (longest chain after back-edge removal) | 61 | – |

With the spike's name-only `lib` class the numbers are lib 231 / second pass
**144**, i.e. the spike is reproduced exactly; the filelist `lib` tag adds 8
SRPMs to the second pass (liberation-fonts, libgcrypt, libglvnd, pygobject3,
sharutils, tzdata, valgrind, zlib-ng). The 2-edge difference in the FAS is
the deterministic tie-breaking.

Note: the greedy FAS is purely graph-driven: it puts gcc at level 3 and so
makes 29 of gcc's needs (binutils, glibc, gmp, mpfr, texinfo, ...) back edges,
which is what the stage plan does anyway (gcc¹ from S1). Nothing in the
order is hand-tuned yet; pinning the stdenv set to "earlier stage" would be
a later refinement.

### checks.nn-order

`nix build -L --cores 6 --max-jobs 2 .#checks.x86_64-linux.nn-order`:
`order.json: 2217 SRPMs, 18754 edges, 806 back edges (incl. 33 self-loops),
282 boot targets, 152 second-pass SRPMs, 61 levels / result: OK`.

What it verifies, independently of how order.json was produced: same SRPM
sets in srpms/builddeps/order; `needs` recomputed from builddeps.json; index
is a permutation; every non-back edge points to an earlier SRPM, every back
edge to a later one (or itself); the graph minus back edges is acyclic (Kahn
from scratch) and `level` matches; every back edge's target is in
`bootTargets`; every SRPM with a lib back edge is in `secondPass`.

Negative tests (tampered copies of order.json, scratch script):

| tampering | result |
|---|---|
| unchanged | exit 0, OK |
| drop one back edge (Cython → gdb) | exit 1: "edge Cython -> gdb (not a back edge) is not ordered dependencies-first" |
| drop a boot target | exit 1: "back edge Cython -> gdb: target not in bootTargets" (7 errors) |
| drop a secondPass entry | exit 1: "PyYAML has a lib back edge to libyaml but is not in secondPass" |
| unmark gcc's self-loop | exit 1: "self-loop gcc not marked as a back edge" |
| duplicate an index | exit 1: "index is not a permutation" |
| stale needs | exit 1: "which: needs differ from builddeps.json" |

## subpackages.json

### Mechanism

`nn.lockgen.subpackages.<srpm>` (lib/rocky/parts/lockgen.nix): one small
derivation per SRPM. It runs `lib/rocky/lockgen/rpmspec-query.sh` with the
existing chroot runner (`lib/chroot.sh`) as mockbuild inside
`nn.lockgen.buildroot` = stage0-full (stage0 rpm 4.19.1.1, redhat-rpm-config,
every `*-srpm-macros`, rocky-release) + the `*-rpm-macros` subpackages that
the same stage0 macro builds produce (python-, python3-, pyproject-,
kernel-, fonts-, lua-, qt6-rpm-macros; `--nodeps --noscripts` like all of
stage0). The SRPM is the locked FOD, read from the store; its payload is
extracted except files > 2 MiB (tarballs; empty placeholders keep
`%{SOURCEn}` tests honest). Queries, all `--target x86_64`:

* `rpmspec -q --srpm`: NEVR (checked against the lock), ExclusiveArch/ExcludeArch;
* `rpmspec -q --builtrpms`: the packages rpmbuild would produce (a `%package`
  without `%files` is not built: krb5's `krb5`, efi-rpm-macros'
  `efi-rpm-macros`, qt6's `qt6`/`qt6-devel`, gcc's `gcc-objc`, ...);
* `rpmspec -q --rpms`: all declared packages, to list the not-built ones.

`lib/rocky/lockgen/raw2json.py` writes the result as JSON (the output is a
single file, `allowedReferences = [ ]`). rpmspec failures are recorded in
the result, never fatal, so failures are cached like successes.

`tools/lock_subpackages.py` evaluates `nn.lockgen.paths` for the selected
SRPMs (one `nix eval`), builds the missing ones with one `nix build
--keep-going --no-link --stdin --cores 6 --max-jobs 2`, and folds the results
into subpackages.json; prefix (eponymous > `<srpm>-libs` > most `/usr` files
of the shipped subpackages in filelists.xml > first) and `shipped` (∈ rpms.json
`bySrpm`) are derived there, so a repodata change never re-runs rpmspec.

Two bugs found and fixed on the way (both invalidated the first 480 results,
the full run was restarted):

1. **stdout noise**: `%forgemeta -v` (ksc, kabi-dw, ... 111 lines for ksc)
   prints to stdout while the spec is parsed, so the first stdout line was
   not the query result. Every result line now starts with `LOCKGEN<TAB>`;
   other lines are counted (`stdoutNoise`).
2. **`--define dist` is wrong for forge packages**: rocky-release's
   `macros.dist` defines `%dist %{!?distprefix0:%{?distprefix}}%{expand:…}%{distcore}%{?distsuffix}…`;
   `%forgemeta` contributes `.git<commit>` through `%distprefix`. Defining
   `%dist` on the command line drops it: ksc parsed as `1.12-7.el10`, the
   lock (and the official RPM) is `1.12-7.git869a25c.el10`; kabi-dw
   `0-0.30.el10` vs `0-0.30.20250210giteedfcbf.el10`. The query now defines
   `%distcore` instead and both match. **The same applies to
   `buildSrpm` in lib/default.nix (`--define dist`) and to any future
   rpmbuild invocation**: forge-based SRPMs would get a wrong Release
   (reported as a requested change).

### Runs

| run | command | result |
|---|---|---|
| seed (35 SRPMs) | `python3 -I tools/lock_subpackages.py --seed` | 35/35 ok, 25 s (first version of the query) |
| full, 1st | `... --stale` | stopped after ~480 results: bugs 1 and 2 above |
| **full** | `python3 -I tools/lock_subpackages.py --all --log …/full2.log` | **2217/2217 ok, 0 rpmspec failures, 0 build failures**, 16:11 → 17:01 (≈ 50 min at `--max-jobs 2`; ~1700 SRPMs had to be downloaded, 19.7 GB in total) |
| re-collect | `... --all --no-build` | 2.8 s, byte-identical subpackages.json |
| `update-lock.py --derived-only` on a copy | | builddeps/order/subpackages byte-identical to the committed ones |

The seed set (glibc, kernel, which, xz, gzip, sed, m4, expat, libxcrypt,
ncurses, krb5, zlib-ng, zstd, gmp, mpfr, libmpc, binutils, gcc, bash,
coreutils, rocky-release, redhat-rpm-config, the 13 other stage0 macro SRPMs,
rust) is therefore covered by the full run as well. Coverage recorded in the
file: `"coverage": {"failed": 0, "missing": 0, "ok": 2217, "srpms": 2217}`,
`"rpm": ["RPM version 4.19.1.1"]`.

### Results

* 7805 subpackages (debug packages excluded; 2585 `-debuginfo`/`-debugsource`/
  `-debuginfo-common-*` names in `debug`, 1289 SRPMs build debuginfo).
  **6707 shipped, 1098 unshipped** (in 690 SRPMs): `-tests` 312, `-devel` 179,
  `-doc` 69, `-static` 46, `-docs` 13, other 479 (e.g. glibc's `glibc32`,
  `sysroot-x86_64-el10-glibc`, `compat-libpthread-nonshared`; binutils/gcc
  `cross-*`; kernel's `-internal`/`-partner` module packages).
* glibc: 224 subpackages, prefix `glibc`, 3 unshipped (the numbers of the
  design, §0.4/§12). kernel: 54 (`kernel-debuginfo-common-x86_64` correctly
  counted as debug). krb5: prefix `krb5-libs` (rule `libs`), `krb5` declared
  but not built.
* Prefix rule: eponymous 1960, `usr-files` 252, `-libs` 4, `first` 1 (shim:
  its only subpackage `shim-x64` has 0 /usr files). The usr-files rule is
  mechanical and sometimes picks an odd output, e.g. antlr → `antlr-javadoc`
  (537 files vs `antlr-tool` 5), cmocka → `libcmocka-devel` (10 vs 7); per
  design these get a `prefixSubpackage` override when they are packaged.
* `notBuilt` (declared `%package` without `%files`): 275 SRPMs, 322 names.
* **Shipped but not produced by the x86_64 spec parse** (`shippedMissing`):
  47 SRPMs, 200 of the 6907 official binary RPMs (97.1 % of the shipped RPMs
  are matched by name):
  * langpacks: 149 `default-fonts-*` names,
  * 38 `*-javadoc` + 6 `ant/maven-openjdk21|-openjdk25|-unbound`: generated by
    javapackages macros (`%javadoc_package` …) that are not in the lockgen
    buildroot (javapackages-tools is not a stage0 macro package),
  * noarch subpackages only built on another arch's builder: edk2-aarch64,
    ipxe-bootimgs-aarch64, grub2-efi-aa64-modules, s390utils-se-data, kernel's
    kernel-doc and kernel-abi-stablelists (Koji builds them in the noarch
    task), gcc-toolset-15-libstdc++-devel.
  These are listed per SRPM, so the package builder can decide (more macro
  packages in a later stage, or accept).
* 19 SRPMs ship nothing for x86_64 (s390x/ppc64le/aarch64-only: libica,
  librtas, powerpc-utils, shim-unsigned-aarch64, ...); their `names` are all
  `shipped: false`, and 26 SRPMs have an ExclusiveArch without x86_64/noarch;
  9 of those (10 SRPMs in all) carry an unexpanded `%{rust_arches}`
  (rust-srpm-macros is not in stage0): `exclusiveArch` values starting with
  `%` mean "unknown".
* stdout noise: only ksc (111 lines) and kabi-dw (54), both `%forgemeta -v`.

## Not done / open

* `nn.lockgen` uses stage0-full's macro set (+ the `*-rpm-macros` of the stage0
  macro builds). javapackages, rust-srpm-macros, perl-macros, cmake/meson
  macros etc. are not present; this explains all `shippedMissing` above and
  the `%{rust_arches}` values. Default bconds only (as asked); per-package
  bcond overrides (design §8.1) are not modelled yet.
* No nix-eval-jobs: one `nix eval` of `nn.lockgen.paths` (filtered with
  `--apply`) + one `nix build --stdin` was fast enough (eval < 1 min for 2217).
* `lock_subpackages.py` is not a flake app (flake.nix is not mine); run it
  with `python3 -I tools/lock_subpackages.py` from the repository root.

