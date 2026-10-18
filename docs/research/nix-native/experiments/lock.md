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

*lock-fix:* the first version only logged a warning when a package had no
summary (its tags silently became `other`), and its summary cache key
(filelists checksums + number of packages) ignored the pkgids, so a cached
summary was reused for a lock whose builds differ. Now: the cache key
covers every wanted `pkgid name.arch`; a missing summary is an error
(`--allow-missing-filelists` turns it into a warning); the filelists are only
used if the repomd.xml they come from has the primary checksum rpms.json
records for that repo (`get_repodata` returns that repomd's primary sha too);
the filelists checksums are recorded as `filelists` in builddeps.json and
subpackages.json. Verified on copies of the lock: zeroing the sha256 of
make/gcc/readline-devel in rpms.json → `error: filelists: 3 of 6907 locked
packages not found by pkgid`, exit 1, with and without the old summary
cache present; changing BaseOS' recorded primary → `error: ... repomd.xml has
primary 24c60a59…, rpms.json records 0000…`, exit 1; with
`--allow-missing-filelists` a warning and the file is written.

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
  RPMs; 3 BRs have more than one provider in the buildroot. (With the
  lock-fix unshipped fallback below: 2016 providers = 1918 + 98 unshipped.)
* **Not provided by a published RPM**: 222 SRPMs have ≥ 1 BuildRequire nothing
  in BaseOS/AppStream/CRB provides (226 distinct, 322 occurrences).
  *Correction (lock-fix review):* the first version called all of them
  build-only packages Rocky does not publish. In fact **132 of the 322
  occurrences (81 SRPMs) are unshipped subpackages of in-lock SRPMs**
  (gdb → `libipt-devel`, ModemManager → `libmbim-devel`/`libqmi-devel`,
  NetworkManager → `libndp-devel`, corosync → `libqb-devel`, gcc →
  `(glibc32 or glibc-devel(x86-32))`, gcc → binutils' `cross-binutils-*`, ...),
  and order.json therefore ordered gdb before libipt, ModemManager before
  libmbim etc. These unshipped subpackages are outputs (design §0.4.4, §3.2),
  so builddeps now resolves the rest against subpackages.json: a simple dep
  matches an unshipped name (shipped by no SRPM) when the SRPM's EVR satisfies
  its range; `or` takes the first matching branch, `and`/`with` need all.
  Such providers are marked `"unshipped": true`, tagged from the name
  (`-devel|-static|-headers|-libs` or `lib*` → lib, else other; no file
  lists exist for them). Result: **132 BRs resolved by 98 unshipped
  providers** (70 lib, 28 other); **190 occurrences (119 distinct) in 154
  SRPMs remain unresolved**: `gi-docgen` 21, `python3-dbusmock` 7,
  `rubygem-asciidoctor` 6, `umockdev-devel` 5, `pkgconfig(gi-docgen)` 5,
  `asciidoctor` 4, `xxhash-devel` 4, `python3-fonttools` 4,
  `pkgconfig(libcupsfilters) >= 2.0b3` 3, `mandoc` 3, `pkgconfig(gsound)` 3,
  `elinks` 3, ... None of the remaining ones names a subpackage of any SRPM
  in the lock (checked by token match against all 7805 names); virtual
  provides of unshipped packages (`pkgconfig(...)`, files) cannot be known
  without building them. `stats` in builddeps.json records these counts.
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

| quantity | this lock (lock-fix: + unshipped providers) | first version (published RPMs only) | spike [BP-1/2] |
|---|---|---|---|
| edges (S ≠ T) | **18 797** | 18 721 | 18 721 |
| self-loops | 33 | 33 | 33 |
| non-trivial SCCs | 4: 949, 2 (ibus-table ↔ ibus-table-chinese), 2 (jaxb ↔ jaxb-istack-commons), 2 (python3.14-pybind11 ↔ python3.14-scipy) | 3: 926, 2, 2 | largest 926 |
| back edges (S ≠ T) | 782 (tool 384, lib 252, lang 93, doc 49, test 30, macro 16) | 773 | 771 |
| boot targets (incl. self-loops) | 286 | 282 | 265 (without self-loops) |
| SRPMs with a back edge | 343 | 339 | 337 |
| second pass (lib back edge) | 150 | 152 | 144 |
| levels (longest chain after back-edge removal) | 66 | 61 | – |

The 76 extra edges are the BuildRequires that only unshipped subpackages
provide (see builddeps.json above). Now gdb (index 704) follows libipt (702),
ModemManager (1086) libmbim (1076) and libqmi (1078), NetworkManager (1097)
libndp (1083), emacs (1017) libotf (1013), ghostscript (800) libijs (796),
corosync (1454) libqb (1452); in the first version all of them came before
their library. gcc → glibc (`glibc32`) is a back edge, like gcc's other
needs. The second pass lost ninja-build, python-docutils, python-pygments,
sqlite and gained net-tools, prrte (the FAS changes with the bigger SCC).

The comparison with the spike below is for the first version (published
RPMs only, the spike's input). With the spike's name-only `lib` class the numbers are lib 231 / second pass
**144**, i.e. the spike is reproduced exactly; the filelist `lib` tag adds 8
SRPMs to the second pass (liberation-fonts, libgcrypt, libglvnd, pygobject3,
sharutils, tzdata, valgrind, zlib-ng). The 2-edge difference in the FAS is
the deterministic tie-breaking.

Note: the greedy FAS is purely graph-driven: it puts gcc at level 3 and so
makes 28 (first version: 29) of gcc's needs (binutils, glibc, gmp, mpfr, texinfo, ...) back edges,
which is what the stage plan does anyway (gcc¹ from S1). Nothing in the
order is hand-tuned yet; pinning the stdenv set to "earlier stage" would be
a later refinement.

### checks.nn-order

`nix build -L --cores 6 --max-jobs 2 .#checks.x86_64-linux.nn-order`:
`order.json: 2217 SRPMs, 18830 edges, 815 back edges (incl. 33 self-loops),
286 boot targets, 150 second-pass SRPMs, 66 levels / result: OK` (after the
lock-fix changes; first version: 18754 edges, 806 back edges, 282, 152, 61).

What it verifies, independently of how order.json was produced: same SRPM
sets in srpms/builddeps/order; `needs` recomputed from builddeps.json; index
is a permutation; every non-back edge points to an earlier SRPM, every back
edge to a later one (or itself); the graph minus back edges is acyclic (Kahn
from scratch) and `level` matches; every back edge's target is in
`bootTargets`; every SRPM with a lib back edge is in `secondPass`.

*lock-fix:* that only tested that the summary lists *contain* what they
must. A copy with `zzz-not-an-srpm` appended to `secondPass`, an extra boot
target, `selfLoops = []`, `sccs = []` and glibc's `scc` removed still passed.
`--check` now recomputes `sccs` (Tarjan on `needs`), `bootTargets`,
`secondPass`, `selfLoops`, `stats` and the per-SRPM `scc` ids from
needs/back/level with the same `derived()` that `compute()` uses, and
requires equality. Each of the five tamperings above (and all at once) is
now rejected (exit 1, e.g. `secondPass differs from the graph: 1 extra
["zzz-not-an-srpm"], 0 missing []`, `scc differs for 1 SRPMs, e.g.
['glibc']`); the unchanged copy passes. The self-test has the same six cases
on the toy graph.

Negative tests of the first version (tampered copies of order.json, scratch script):

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
stage0) + `macros.rust-srpm` (lock-fix, see below). The SRPM is the locked FOD, read from the store; its payload is
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
into subpackages.json; prefix (see "Prefix rule" below) and `shipped` (∈
rpms.json `bySrpm`) are derived there, so a repodata change never re-runs
rpmspec.

*lock-fix:* (1) `--no-build` used to drop the previous entry of a selected
SRPM before checking whether its result was in the store, so after a GC, on
a fresh clone or after any change to the lockgen machinery `--all --no-build`
emptied the file (reviewer: `which glibc` after editing rpmspec-query.sh →
both gone, coverage `missing: 2`). Now only collected results replace
entries. (2) Every entry and failure records `lockgen`, the hash of its query
.drv; `--stale` evaluates all 2217 queries (2 s) and also selects entries
from another derivation, so a change of the buildroot, the query script,
the SRPM or the bootstrap nixpkgs is detected, not only an EVR change.
Repro on a copy of the lock: appending a comment to rpmspec-query.sh, then
`--no-build which glibc` → `notBuilt: 2`, file byte-identical;
`--stale --no-build` → selects all 2217 (`notBuilt: 2217`), file
byte-identical; with the script restored `--stale` → "up to date".
(3) Top-level `duplicateNames`: one name, `rubygem-racc`, is built by two
SRPMs (ruby unshipped, rubygem-racc shipped); the `rpm.<name>` alias must
take the SRPM whose `shipped` is true. (4) Top-level `filelists`: the
filelists checksums the shipped/prefix data came from.

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
| **lock-fix full** (buildroot + macros.rust-srpm, `lockgen` hashes) | `python3 -I tools/lock_subpackages.py --all --log …` | **2217/2217 ok, 0 failures**, 26.5 min (SRPMs already in the store); compared with the first version only the 10 `%{rust_arches}` exclusiveArch values changed (names, shipped, debug, noarch, notBuilt, shippedMissing identical) |
| lock-fix `--stale` | | 2 s, "up to date" |
| lock-fix re-collect | `--all --no-build` | 2.4 s, byte-identical |
| lock-fix `update-lock.py --derived-only` on a copy | | all three files byte-identical to the committed ones |

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
* Prefix rule, first version: eponymous 1960, `usr-files` 252, `-libs` 4,
  `first` 1 (shim: its only subpackage `shim-x64` has 0 /usr files).
  *Correction (lock-fix review):* the first report said the usr-files rule
  picks an odd output only "sometimes" (antlr → `antlr-javadoc`, cmocka →
  `libcmocka-devel`). In fact 23 of the 252 were -test/-tests/-doc/-docs/
  -javadoc/-devel subpackages, including python3.12 → `python3-test`,
  postgresql16 → `postgresql-docs`, mariadb10.11 → `mariadb-test` (whose
  `%_prefix` would have been the test suite's output). The rule is now
  (`choose_prefix`): eponymous > `<srpm>-libs` > the same two for the SRPM
  name without its version (`stem`/`stem-libs`: python3.12 → python3,
  postgresql16 → postgresql, mariadb10.11 → mariadb10, mariadb) > most /usr
  files among shipped names that are not -test(s)/-testsuite/-doc(s)/
  -javadoc/-apidoc/-manual/-example(s)/-demo(s)/-devel/-static/-headers >
  the same allowing -devel/-static/-headers > the same allowing all > first
  (non-doc/devel preferred). Counts: eponymous 1960, usr-files 248, `-libs` 4,
  `stem` 4, first 1. Changed prefixes (19): antlr → antlr-C++, cmocka →
  libcmocka, ding-libs → libpath_utils, kronosnet → libknet1, mariadb10.11 →
  mariadb, mesa-compat → mesa-compat-libxatracker, msv → msv-xsdlib, nodejs22
  → nodejs (was nodejs-npm), openwsman → openwsman-server, postgresql16 →
  postgresql, py3c → py3c-devel (was py3c-doc), pyparsing → python3-pyparsing,
  python-psutil → python3-psutil, python-pyqt6 → python3-pyqt6-base,
  python-testpath → python3-testpath, python3.12 → python3, rpcsvc-proto →
  rpcgen, tesseract-tessdata → tesseract-osd, wayland → libwayland-client.
  Left as -devel/-headers because nothing else of the SRPM ships /usr files
  (header-only or protocol-data packages): eigen3, mingw-headers (mingw32-headers),
  py3c, spirv-headers, vulkan-utility-libraries, vulkan-volk, wayland-protocols.
  Mechanical choices among several libraries (ding-libs, wayland) can still
  get a `prefixSubpackage` override when packaged.
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
  `shipped: false`. First version: 10 SRPMs carried an unexpanded
  `%{rust_arches}` (clevis-pin-tpm2, keylime-agent-rust, python-cryptography,
  python3.14-cryptography, rust-coreos-installer, rust-sequoia-sqv,
  rust-ssh-key-dir, stratis-cli, stratisd, virtiofsd; all ship x86_64 RPMs),
  because redhat-rpm-config's `rust-srpm-macros` was missing.
  *lock-fix:* in Rocky 10 that is `rust-toolset-srpm-macros` from the 270 MB
  rust SRPM, whose `%files` is one file installed verbatim from Source101
  (`%{__install} -D -m 644 %{S:101} %{buildroot}%{rpmmacrodir}/macros.rust-srpm`).
  `nn.lockgen.rustSrpmMacros` extracts that source from the locked rust SRPM
  (checking both spec lines and that it defines `%rust_arches`), and the
  lockgen buildroot installs it as `/usr/lib/rpm/macros.d/macros.rust-srpm`
  (`extraCommands`; not in the rpmdb, rpmspec only needs the macros). Now
  all 10 have x86_64 in `exclusiveArch` and no `exclusiveArch` value starts
  with `%`.
* stdout noise: only ksc (111 lines) and kabi-dw (54), both `%forgemeta -v`.

## Not done / open

* `nn.lockgen` uses stage0-full's macro set (+ the `*-rpm-macros` of the stage0
  macro builds + macros.rust-srpm). javapackages, perl-macros, cmake/meson
  macros etc. are not present; this explains all `shippedMissing` above.
  Default bconds only (as asked); per-package bcond overrides (design §8.1)
  are not modelled yet.
* builddeps: 190 BuildRequire occurrences (119 distinct, 154 SRPMs) stay
  unresolved: build-only packages outside the lock, or virtual provides
  (`pkgconfig(...)`, files) of unshipped subpackages, which are unknown
  until those are built. Unshipped providers are matched by name and the
  SRPM's EVR only (a subpackage with its own Version: would be compared
  with the SRPM's).
* After `lock_subpackages.py` changes subpackages.json, builddeps.json and
  order.json must be regenerated (`update-lock.py --derived-only`; the tool
  prints this). update-lock.py itself refreshes subpackages.json first.
* No nix-eval-jobs: one `nix eval` of `nn.lockgen.paths` (filtered with
  `--apply`) + one `nix build --stdin` was fast enough (eval < 1 min for 2217).
* `lock_subpackages.py` is not a flake app (flake.nix is not mine); run it
  with `python3 -I tools/lock_subpackages.py` from the repository root.

