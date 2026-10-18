# el-nixos, nix-native: Rocky SRPMs -> relocated, composable store paths

Designer: **bootstrap-purity**. Angle: the exact staged path from today's
stage0 to a self-hosted Rocky stdenv whose output closures contain only
Rocky-built store paths; how rpm/rpmbuild/redhat-rpm-config become
relocated Rocky-built tools; enforcement; reproducibility; cycle breaking in
the BuildRequires graph; where glibc fits. All nine questions are answered.
Section 0 lists the decisions and section 1 the spikes they rest on.

---

## 0. Decisions (TL;DR)

1. **Stages (new names; S0 exists today):**

   | stage | built in | by | outputs may reference | user-visible as |
   |---|---|---|---|---|
   | **S0** | FHS chroot (`lib/chroot.sh`, nixpkgs tools at `/usr/bin`) | nixpkgs-built Rocky-source gcc/binutils/glibc, stage0 rpm | (FHS trees; the existing RPM pipeline, unchanged) | `stage0.*`, `srpm.*`, `rpms.*` |
   | **S1 "boot"** | the S0 FHS chroot, but relocated macros and a composed sysroot (no stage0 libc visible to the compiler) | stage0 gcc + stage0 rpmbuild | S1 outputs only | `rockyBoot.*` (never shipped) |
   | **S2 "stdenv"** | a *store-only* root: tmpfs + `/nix/store` (= the sandbox's input closure) + 4 shims | S1 tools only (no nixpkgs, no stage0) | S2 outputs only | `rockyStdenv.*` (tools; never in final closures) |
   | **S3 "final"** | the same store-only root | the S2 stdenv | final (S3) outputs only | `rocky.*` |

   *Fixpoint check*: the stdenv package set is also built a fourth time by the
   S3 stdenv (`checks.stdenv-fixpoint`) and compared with S3 after normalising
   store hashes. Being identical shows that nothing of S0/S1 survives in the
   final binaries.

2. **Two purity properties, both enforced mechanically:**
   - **Closure purity (mandatory from S1 on):** every output's references are
     its own sibling outputs plus same-stage Rocky outputs. Enforced
     *inductively* with per-output `allowedReferences` (cheap, exact). A global
     `checks.rocky-closure` audits every `rocky.*` closure, and a
     nested-content scanner (adapted from `tools/rpm_purity.py`) catches
     store paths hidden in compressed data, so Nix sees every reference.
   - **Build purity (S2 and S3):** the input closure of every S2/S3 derivation
     contains no nixpkgs and no S0 path, only lock FODs (`builtin:fetchurl`).
     It is enforced **at evaluation time** by a string-context assertion in
     `mkRockyDerivation`, so no IFD and no build is needed.

3. **Recipe engine:** real `rpmbuild -bb` of the unmodified spec (rare,
   declared spec rewrites aside). The `%_prefix` macro family is redirected to
   an **install prefix P**: a synthetic store path at least as long as the
   longest output path. rpmbuild writes *transient* RPMs with uncompressed
   payloads; they are used only for their `%files` partition (`%doc`,
   `%license`, `%config`, `%ghost`, `%exclude`, `-f` lists and globs exactly as
   rpm implements them). Each subpackage's payload becomes one Nix output, and
   references are rewritten from P to the owning output, **length-preserving
   by slash padding** (`/nix/store/H-glibc-2.39-142.el10_2////lib64/libc.so.6`,
   spike 6). No `.rpm` is shipped.

4. **Cross-stage and late references by hash substitution.** Store names are
   stage-independent (`bash-5.2.26-6.el10` in every stage), so moving a
   reference from an earlier stage's build to the final one is a pure
   32-character hash substitution, as in Nix's own CA rewriting. That makes
   **late binding** possible. Example: glibc-common's `ldd` must reference
   `rocky.bash`, but bash is built after glibc. The raw output carries
   `/nix/store/eeee…-bash-5.2.26-6.el10/bin/bash`, and a cheap bind derivation
   substitutes the real hash.

5. **Cycles:** BuildRequires cycles are broken by stage (back edges are
   satisfied from S1/S2 builds; library back edges get a second pass, enforced
   by `disallowedRequisites`). Output cycles inside one SRPM are detected by
   the splitter, which prints the file and path behind each edge. The fix is
   then declared statically, either as a merge (`mergeOutputs`) or as a
   reference break (`dirOwner`, `noRef`).

6. **glibc in nix-native mode needs these deviations, measured in a real
   relocated rpmbuild (spike 9):**
   - a `config.site`, conditional on `$host_alias` (i686 → `lib`, x86_64 →
     `lib64`), that restores what glibc's configure does only for
     `prefix=/usr`: `libdir`, `libc_cv_slibdir`, `libc_cv_rtlddir`,
     `sysconfdir=/etc`, `localstatedir=/var`;
   - generic macro-level fixes that every package gets: a fold symlink
     `%{buildroot}/usr → P` created in `%__spec_install_pre`, and a
     check-files that treats `/usr/x` and `P/x` as the same file;
   - one spec rewrite: `--with-headers=%{_prefix}/include` → the
     kernel-headers path;
   - two nixpkgs-proven patches applied through `%__spec_prep_post`:
     `LOCALE_ARCHIVE` env var, and `ld.so.cache` moved to `$out/etc`.

   Locales, gconv modules, message catalogs and time zones are found through
   glibc's native `LOCPATH`/`GCONV_PATH`/`TEXTDOMAINDIR`/`TZDIR`.

7. **The glibc milestone is `rockyBoot.glibc` (S1).** It is the first
   relocated package, built in today's chroot with 224 outputs. It is verified
   against the official RPMs by relative file list, ABI (`dynsym`, versions,
   NEEDED, SONAME) and behaviour (store binaries run directly, programs
   compiled against it with the S1 wrapper). `rocky.glibc` (S3) is the same
   recipe one stdenv later.

---

## 1. Spikes (all in `spikes/` beside this file; outputs in `out/`)

| # | spike | result |
|---|---|---|
| 1 | `brgraph.py`: SRPM build graph of all 2217 SRPMs with the existing mock-like resolver (19 s) | **mock graph** (chroot_setup + BR, full Requires closure): 357 808 edges, mean 161 deps per SRPM, 295 self-loops, largest SCC **1120** SRPMs. **BR-only closure**: largest SCC 1101. **Direct BR providers only** (the Nix view: the runtime closure comes from references, the stdenv is implicit): 18 721 edges, mean 8.4, 33 self-loops (gcc, glibc, rust, golang, perl, python3.12, java, dotnet, llvm, make, automake, cmake, nss, gnupg2, …), largest SCC **926**, 1282 SRPMs acyclic. The mock buildsys alone (transaction 1) is 145 packages from **106 SRPMs** and already contains rust, rust-rpm-sequoia, systemd, krb5, openldap and gdb |
| 2 | `cycles.py`: classify every direct BR edge by the satisfying binary (doc/test/lang/lib/tool), recompute SCCs, greedy feedback-arc set (Eades) | SCC 926 → 891 without doc edges → 840 without doc and test → 756 without lang → **225 with library edges only**. FAS on the full direct graph: **771 back edges** (tool 400, lib 231, lang 93, doc 47, test 30), **265 distinct back-edge targets**, **337 SRPMs** with ≥1 back edge, **144** with a *library* back edge (the only ones that can need a second pass). Most-hit targets: systemd 34, git 26, python3.12 25, maven 19, texlive 16, kernel 15, coreutils 14, graphviz 13, curl 13 |
| 3 | reference-like closure (soname/interpreter Requires only, a proxy for Nix references) of candidate stdenvs | gcc+binutils+glibc-devel+make: **29 SRPMs** (binutils → elfutils-debuginfod → curl → krb5/openssl/nghttp2/…); + basic tools: 51; + rpm-build/debugedit/dwz/elfutils: **77** (rust-rpm-sequoia, gdb → python3.12, boost, icu, babeltrace, glib2); + perl/python3/m4/bison/flex/gettext/pkgconf: 83. With the full Requires closure (mock semantics): 77 / 104 / 161 |
| 4 | `reloc/`: `rpmbuild --rebuild which` in stage0-full with the relocation macros (P = fake store path) | Builds unchanged. `%files` partition is correct: `which` = `P/bin/which`, `P/share/{doc,licenses,info,man}`, `/etc/profile.d/which2.{sh,csh}`, **`/usr/lib/.build-id/2c/… -> ../../../../nix/store/…/bin/which`**; `which-debuginfo` = `/usr/lib/debug/nix/store/<P>/bin/which-….debug` + `.build-id` links; `which-debugsource` = `/usr/src/debug/…`. Problems found: **brp-compress compressed nothing** (it walks `./usr/share/man`, fix: `%__brp_compress … %{_prefix}`, the script takes `PREFIX=$1`); PT_INTERP still `/lib64/ld-linux-x86-64.so.2` (the compiler needs a wrapper). The macro files hard-code `/usr` 87 times: ~40 tool paths (`%__cc /usr/bin/cc`, …), 9 redhat hardening/annobin/package-note `-specs=/usr/lib/rpm/redhat/…`, ~8 data dirs (`%_sysusersdir`, `%_fontbasedir`, `%gopath`, `%rpmmacrodir` in fedora-misc, `%_oldincludedir`), the brp script paths, `%_install_script_path` |
| 5 | `xrefs.py`: every absolute FHS path compiled into or written in the 224 glibc payload trees, resolved to the owning subpackage (= the reference it would become after relocation) | With `/etc`, `/var`, `/run` classified as runtime-FHS: 11 nodes, 18 edges, one SCC **{glibc, glibc-devel}**. It comes only from `/usr/include/{sys,linux}` in **ld.so's retained DWARF**: the build-time paths of `sys/sdt.h` and the kernel headers, which become store paths of build inputs after relocation. Other edges: `libc.so.6`/`ldconfig` → `lib/locale/locale-archive` (**glibc-all-langpacks, 220 MB**), `locale`/`localedef` → locale-archive + `share/i18n/charmaps` (locale-source), `ldd` → `/lib/ld-linux.so.2` (glibc32). `libc.so.6` also holds `/bin/sh`, `/bin/csh`, `/usr/bin` (confstr), `/usr/share/zoneinfo` (tzdata, another SRPM), `/usr/lib64/gconv`, `/usr/libexec/getconf`, `/usr/share/locale` |
| 6 | `pad/`: insert 20 `/` after the store-path name in PT_INTERP and RUNPATH of a binary; write a padded path to a file | Kernel and ld.so resolve both, the program runs, and `nix-store -q --references` still lists glibc. **Slash padding is a valid length-preserving rewrite** |
| 7 | glibc sources | `glibc.spec` runs `../configure --prefix=%{_prefix}` with no `--libdir`/`--sysconfdir`. glibc's `sysdeps/unix/sysv/linux/x86_64/64/configure` sets `slibdir=rtlddir=/lib64` and `libdir=lib64` **only when the prefix is `/usr`**, and `sysdeps/gnu/configure` sets `sysconfdir=/etc` and `localstatedir=/var` likewise. A relocated prefix would silently give `$P/lib`, `$P/etc/nsswitch.conf` and so on. All of them are autoconf cache variables (`test -n "$libc_cv_slibdir" ||`), so a `CONFIG_SITE` file fixes them without editing the spec. `Makeconfig` uses `ifndef` for `zonedir`, `complocaledir`, `localedir`, `gconvdir`. The spec has 17 literal `/usr` lines (168 macro uses): in `%install`, `%{glibc_sysroot}/sbin/ldconfig`, `pushd …/usr/lib/locale`, `hardlink -c …/usr/lib/locale`, `mkdir …/usr/$d`, `rpm -ql kernel-headers \| grep ^/usr/include` (sysroot package, no bcond); in `%build`, `--with-headers=%{_prefix}/include` |
| 8 | rpm sources | `rpm.spec` has `%bcond_without sequoia` → **`--without sequoia` = internal OpenPGP, no Rust**, so a boot/tool rpm needs no rust. rpm's macro path is `confdir/{macros, macros.d/macros.*, platform/%{_target}/macros, fileattrs/*.attr, redhat/macros}` + `/etc/rpm/…` + `~/.rpmmacros`, with `confdir = $RPM_CONFIGDIR` if set, so a **composed config dir** (rpm + redhat-rpm-config + srpm-macros + el-nixos layer) works. Tool macros come from cmake `findutil()` over `$MYPATH` |
| 9 | `glibc/` (`out/reloc-glibc-final.sh`): relocated `rpmbuild -bb` of the unmodified glibc SRPM in today's glibc buildroot, P = `/nix/store/000…-glibc-2.39-142.el10_2-xxx…` (8 iterations, ~15 min each, findings in §8.3) | **Succeeds: 233 RPMs**, the same count as the FHS build. Needed: `config.site` (conditional on `$host_alias`, with `sysconfdir`/`localstatedir` as autoconf variables), the `%__spec_install_pre` fold symlink `%{buildroot}/usr → P`, one spec rewrite (`--with-headers`), and `_unpackaged_files_terminate_build 0`. The last one covers check-files seeing 18 926 files twice, as `/usr/x` (claimed: debuginfo 4250, debugsource 10 128, sysroot 3098, `.build-id` 1448) and as `P/x` (found): exactly the fold aliases, fixed properly by a canonicalising `%__check_files`. **Every subpackage's file list, mapped P → `/usr`, equals today's FHS build's** (`out/glibc-reloc-vs-fhs-filelist.diff`), except build-id link names (the binaries differ) and 2 extra dirs (`/usr/lib/debug/nix{,/store}`) per debuginfo package. brp-mangle-shebangs turned `P/bin/{ldd,sotruss,tzselect,xtrace,memusage}` into `#!/usr/bin/bash` and `mtrace` into `#!/usr/bin/sh`, which the splitter must bind (§6.4) |

---

## 2. Vocabulary and invariants

- **P** (install prefix): `"/nix/store/" + hash(out) + "-" + name + "-" + "x"·k`,
  with k chosen so that `len(P) >= len(path of every output)`. P never exists
  in the store. During a build it exists only as `%{buildroot}P` (and, when
  `%check` or `%install` must execute installed files, bind-mounted at P inside
  the bwrap namespace).
- **Output names**: subpackage `glibc` → `out`; `glibc-<x>` → `<x>`
  (`devel`, `common`, `langpack-en`, `all-langpacks`); a subpackage that does
  not start with `<srpm>-` keeps its full name (`libnsl`, `nss_db`,
  `compat-libpthread-nonshared`, `sysroot-x86_64-el10-glibc`); `-debuginfo` and
  `-debugsource` go to output `debug`. The list is static: `rpmsLock.bySrpm` +
  the known unshipped subpackages (per-package override, as `packages/glibc.nix`
  has today) + `debug`.
- **Store names**: `<srpm>-<version>-<release>[-<output>]`, the same in every
  stage (stage visible in `passthru.stage` and `$out/nix-support/el-nixos`).
  Equal names across stages are what make cross-stage rebinding a hash
  substitution.
- **Attributes**: `rocky.<binary-rpm-name>` (flat, like today's `rpms.*`:
  `rocky.glibc-devel`, `rocky.nss_db`) and `rocky.srpm.<srpm>` (the
  multi-output derivation, so `rocky.srpm.glibc.devel` and
  `rocky.glibc.devel` both work, the latter because `rocky.glibc` is the `out`
  output of that derivation). Merged outputs (§7) are aliases: if
  `glibc-common` were merged into `glibc`, then `rocky.glibc-common ==
  rocky.glibc`. `rockyBoot.*` and `rockyStdenv.*` mirror the same names.
- **Runtime-FHS paths** (stay absolute, never relocated): `/etc`, `/var`,
  `/run`, `/dev`, `/proc`, `/sys`, `/tmp`, and the two host-provided
  executables every Nix-capable Linux has: `/bin/sh` and `/usr/bin/env`.
  Literal FHS strings that do not derive from the prefix, such as
  `_CS_PATH "/bin:/usr/bin"` and `/usr/share/zoneinfo`, are left alone
  (spike 5 shows them as "owned by no subpackage").

---

## 3. Bootstrap sequence (Q6), the core of this design

### 3.1 What exists and what is wrong with reusing it as-is

S0 gives a faithful FHS toolchain (gcc 14.3.1 multilib, binutils 2.41, glibc
2.39, rpm 4.19.1.1, debugedit) whose *executables* are nixpkgs-linked, and
nixpkgs build tools at `/usr/bin`. Its outputs are FHS trees with
`PT_INTERP /lib64/…`. They cannot run on NixOS and cannot coexist. Nothing
compiled by S0 can be shipped as a relocated package directly, but everything
S0 can *build* can be built relocated, because the build happens in a chroot
and only the install prefix changes (spike 4).

### 3.2 The stdenv set (what has to exist before "normal" packages)

Defined from spikes 1 and 3, not by taste. The set is everything the rpmbuild
recipe engine and a C/C++ build run, plus the reference closure of those
tools:

```
toolchain   glibc gcc binutils kernel(headers-only) gmp mpfr libmpc (isl in-tree) zlib-ng zstd xz
core tools  bash coreutils sed grep gawk findutils diffutils patch tar gzip bzip2 cpio unzip zip
            file make which util-linux m4 bison flex pkgconf gettext texinfo
            autoconf automake libtool perl (+ the ~40 perl-* modules perl-interpreter needs)
            python3.12 (+ expat libffi mpdecimal openssl ncurses readline sqlite gdbm libxcrypt)
rpm engine  rpm (popt lua sqlite libarchive libxml2 acl attr libcap elfutils) debugedit dwz
            redhat-rpm-config rocky-release + the 13 *-srpm-macros
ref closure binutils/elfutils --with-debuginfod pulls curl openssl krb5 keyutils libverto
            nghttp2 libidn2 libunistring libpsl brotli e2fsprogs(libcom_err) json-c jansson
            pcre2 libselinux libsepol crypto-policies; rpm (sequoia) pulls rust-rpm-sequoia
```

That is **≈ 80 SRPMs** for a Rocky-faithful stdenv (spike 3: 77 with
rpm-build, 83 with perl/python), compared with the 106 of mock's
`chroot_setup_cmd` closure (spike 1), which in a Nix world is not needed as a
whole. gdb (`gdb-add-index`) and rust (`rpm-sequoia`) are the expensive
members, and both can be deferred (§3.4).

### 3.3 The stages in detail

**S1 "boot" (built in the S0 chroot).**
- *Root*: a new `stage0.mkRoot`-style layer **without the stage0 glibc in
  `/usr/include` and `/usr/lib64`**: compiler, binutils, rpm, debugedit and the
  nixpkgs tools only (all nixpkgs-linked, so they do not need FHS libraries).
  This root makes "silently linked against stage0 FHS libc" impossible.
- *Compiler*: the stage0 gcc behind a wrapper (`/usr/bin/{cc,gcc,c++,g++,cpp}`
  in a small layer on top) that passes `--sysroot=$SYSROOT`, where
  `$SYSROOT` is a per-derivation symlink farm (`usr/include`, `usr/lib64`)
  over the *relocated* S1 glibc-devel/glibc/kernel-headers and the declared
  inputs. It also passes `-Wl,-dynamic-linker=<S1 glibc>/lib64/ld-linux-x86-64.so.2`,
  `-Wl,-rpath,<lib dir>` for each input with libraries, and
  `-ffile-prefix-map=$SYSROOT=/` plus `-ffile-prefix-map=<input>=/usr` for each
  input. As a result DWARF and `__FILE__` show Rocky's `/usr/include/…`
  instead of store paths (this removes the glibc↔glibc-devel cycle of spike 5
  and improves debuginfo parity). The very first S1 package, glibc, is
  special: its build uses no libc (it builds its own), so it needs only the
  kernel-headers path.
- *Engine*: the existing stage0 rpmbuild at `/usr/bin/rpmbuild`, stage0-full
  macros, plus the el-nixos **relocation layer** `macros.el-nixos-reloc`
  (§5) and the splitter (§6) after the build.
- *Deviations allowed* (S1 never ships): bconds that cut the dependency
  fan-out, recorded per package in `bootstrap/s1.nix`. Examples:
  `binutils --without debuginfod`, `rpm --without sequoia` (spike 8) and
  `--without plugins`, `python3.12 --without tests`, `--nocheck` everywhere,
  docs off where a doc tool is missing. This is where nixpkgs keeps
  helping (perl, python, bison and other build tools still come from the S0
  root), but only as *build tools*. Every S1 output is checked by
  `allowedReferences` = S1 outputs.
- *Order* (each in BuildRequires order inside the S1 set; the set is acyclic
  once the boot bconds are applied, and that is checked in eval, §10.3):
  `kernel-headers → glibc → zlib-ng, xz, zstd, bzip2 → gmp, mpfr, libmpc →
  binutils → gcc (C, C++; Rocky's profiledbootstrap kept, it is what makes
  cc1 link libstdc++ statically) → bash, coreutils, … → perl → python3.12 →
  rpm (--without sequoia), popt, lua, sqlite, libarchive, elfutils, debugedit,
  dwz → redhat-rpm-config + macros (noarch, trivially relocated) → bubblewrap`.
- *Shebangs*: S1 packages built before their interpreter (glibc's
  `ldd`/`sotruss`/`tzselect` need bash, `mtrace` needs perl) get **late
  binding**: the splitter maps `#!/usr/bin/bash` to
  `/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-bash-5.2.26-6.el10/bin/bash`, and
  `rockyBoot.glibc-common` is the bind derivation that substitutes S1 bash's
  hash (§7.3). Packages built after bash/perl/python get their shebangs
  rewritten directly (the interpreter is an input).

**S2 "stdenv" (store-only root, S1 tools).**
- *Root*: `lib/chroot.sh` unchanged, with a **shim layer** of five entries:
  `/bin/sh → <S1 bash>/bin/bash`, `/usr/bin/env → <S1 coreutils>`,
  `/usr/lib/rpm → <rpm config env>/lib/rpm` (only so that redhat-rpm-config's
  literal `/usr/lib/rpm/redhat/*` scripts and `-specs=` files resolve without
  rewriting 9 macros), `/etc/{passwd,group,hosts,nsswitch.conf}` (the stage0
  ones), and an empty `/usr/lib/sysimage/rpm`. `/nix/store` is the sandbox's
  store, i.e. exactly the input closure. `/usr/bin`, `/usr/include` and
  `/usr/lib64` do **not** exist, so a spec or configure script that hard-codes
  them fails at build time instead of silently producing a broken package.
  This is the generic hard-coded-`/usr` detector.
- *Runner and builder*: `derivation { builder = "${rockyBoot.bash}/bin/bash"; … }`
  (no nixpkgs stdenv); bubblewrap, coreutils and python3 for the splitter and
  scanner come from `rockyBoot`; sources come from `builtin:fetchurl` FODs over
  the lock (the same sha256 as `lib/fetch-srpm.nix`). Its input closure is
  therefore S1 + FODs only, asserted in eval (§9.2).
- *Engine*: `rockyBoot.rpm` (relocated, `RPM_CONFIGDIR` → a composed
  `rpmConfigEnv` = `buildEnv` of rpm's `lib/rpm` + redhat-rpm-config +
  srpm-macros + `macros.el-nixos-{tools,reloc}`). `macros.el-nixos-tools` is
  generated from the stage's tools (`%__cc`, `%__make`, `%__tar`, … → S1
  store paths), which replaces the ~40 hard-coded tool macros of spike 4.
- *Compiler*: `rockyBoot.gcc` with the same wrapper semantics, now as a small
  bash script interpreted by S1 bash (§4.1).
- *Content*: the full stdenv set, **unmodified Rocky configuration** (no boot
  bconds, `%check` where feasible), including gdb and, if wanted, rust
  (§3.4). Back edges *inside* the stdenv set (binutils → elfutils-debuginfod →
  curl → krb5 → … → gcc) are built from S1 inputs, and their outputs must not
  reference S1 (`allowedReferences`). If one does, it gets a second S2 pass
  (§10.3).

**S3 "final" (= `rocky.*`).**
- Same root and runner, with S2 tools.
- **Runtime libraries are S3's own.** The S3 wrapper points
  `-dynamic-linker`, `-B`, `-isystem` and `-L` at the S3 glibc and S3 gcc
  runtime outputs (libgcc, libstdc++), not at the libraries the S2 compiler
  was built with. Otherwise every C++ program's closure would contain S2's
  libstdc++. Order inside S3: glibc (wrapper on S2 runtime; glibc needs no
  libc) → gcc (target libraries compiled against S3 glibc; the host programs
  link libstdc++ statically under Rocky's bootstrap, so the compiler has no
  S2 reference) → switch the wrapper to S3 runtime libraries → everything
  else.
- Every one of the 2217 SRPMs builds here; the stdenv set is rebuilt here too,
  so `rocky.bash`, `rocky.coreutils`, `rocky.glibc` and the rest are S3.

**Fixpoint check (`checks.stdenv-fixpoint`).** Build the stdenv set again
with the S3 stdenv ("S4", never exposed). For every output, compare S3 and S4
after replacing each `/nix/store/<hash>-<name>` with `<name>`, which is
length-preserving, so ELF stays comparable. They must be bit-identical except
for known non-determinism (ar member dates, already documented). If they are,
the outputs are a fixpoint of the Rocky toolchain: S0/nixpkgs influence
reached S1 and S2 and stopped there. If they differ, the report names the
files and the S3 tools that differ. The remedy is to promote S4 and make
`rocky.*` = S4, at the cost of one more stdenv-sized build.

### 3.4 What is rebuilt when (the bill)

| change | rebuilds |
|---|---|
| nixpkgs pin | S0 → all of S1 → S2 → S3 (the whole world; as today, everything hangs off S0). Mitigation: CA derivations (§9.4) would cut off at S2 if the S2 outputs are bit-identical, which is the fixpoint property |
| a stdenv-set SRPM update | its S1 build only if `bootstrap/s1.nix` lists it, then S2 and everything in S3 (it is in the stdenv) |
| a leaf SRPM update | that SRPM in S3 + reverse dependencies |
| lock regeneration | only SRPMs whose sha256 changed, plus reverse dependencies |

Cost: the stdenv set is ≈80 SRPMs × 3 builds (S1, S2, S3) + 1 for the
fixpoint. gcc dominates: Rocky's gcc.spec with profiledbootstrap and all
languages is the long pole (hours). S1 gcc may drop non-C/C++ languages; S2
and S3 must not. **Deferred members**: gdb (needed only for `gdb-add-index`,
which only affects `-debuginfo` outputs; `%_include_gdb_index 0` until S2 has
gdb, recorded as a stage deviation) and rust (needed only for
rpm-sequoia; the S2/S3 build tool is `rpm --without sequoia`). The *shipped*
`rocky.rpm` is built with sequoia once `rocky.rust` exists (rust: S1 from
the S0 chroot with nixpkgs rustc as the previous version, then S2/S3 from
that, the same self-loop pattern as gcc).

### 3.5 How glibc gets rebuilt by the final stdenv

`rockyBoot.glibc` (S1, stage0 gcc) → `rockyStdenv.glibc` (S2, S1 gcc) →
`rocky.glibc` (S3, S2 gcc) → (S4 in the fixpoint check). Same recipe
(`packages/glibc/nix.nix`), same outputs and verification at every stage. Only
the stage function changes the compiler, the engine and the allowed
references. S3 glibc's scripts are late-bound to `rocky.bash`/`rocky.perl`
(built after it in S3).

---

## 4. Toolchain and stdenv mechanics (Q5)

### 4.1 Compiler wrapper (cc-wrapper equivalent)

Semantics are copied from nixpkgs' cc-wrapper/bintools-wrapper, with Rocky
tools and inputs:

| concern | how |
|---|---|
| headers of buildInputs | `-isystem <in>/include` in input order, after the libc's (S1: through the composed `--sysroot`) |
| libraries | `-L<in>/lib64` (and `/lib` if present) |
| dynamic linker | `-Wl,-dynamic-linker=<glibc>/lib64/ld-linux-x86-64.so.2` (`/lib/ld-linux.so.2` from glibc32 for `-m32`) |
| RUNPATH | `-Wl,-rpath,<dir>` for every `-L` dir *whose libraries are actually linked*. Done at link time (not by patchelf afterwards), so ld lays out `.dynstr`/`.dynamic` itself; a post-build ELF check requires every `DT_NEEDED` to resolve through RUNPATH to an allowed reference, else the build fails (this catches a library picked up from an unexpected dir) |
| self RUNPATH | `-Wl,-rpath,<P>/lib64` (rewritten to the owning output by the splitter, so `libfoo.so.1` in `out` and `foo-bin` in `bin` find each other) |
| reproducible DWARF | `-ffile-prefix-map=<each input>=/usr` (debugedit already maps the build dir to `/usr/src/debug`) |
| `-m32` / multilib | wrapper picks the `glibc32` output for `-m32`; gcc's own multilib dirs are already relocated inside gcc's output |
| specs files | redhat-rpm-config's `-specs=/usr/lib/rpm/redhat/redhat-hardened-cc1` keeps working through the `/usr/lib/rpm` shim (S2/S3) or the real FHS file (S1) |

Reusing nixpkgs' `wrapCCWith`/`wrapBintoolsWith` is *possible* (they are
parameterised by `cc`, `bintools`, `libc`, `coreutils`, `gnugrep`, `shell`).
The wrapper scripts are build-time only and the scanner proves they leave no
reference. But their *derivation* uses nixpkgs' `stdenvNoCC` and setup.sh,
which breaks S2/S3 build purity. **Decision**: S1 may use nixpkgs'
cc-wrapper *code* (it runs in S0 anyway); S2/S3 use an ~150-line el-nixos
wrapper with the same flag semantics, interpreted by the stage's Rocky bash.
The setup-hook concept is replaced by the rpm macro layer: rpmbuild, not
setup.sh, drives the build.

### 4.2 rpm, rpmbuild and redhat-rpm-config as relocated tools

- **rpm**: S1 = Rocky rpm.spec built relocated in the S0 chroot with
  `--without sequoia --without plugins` (spike 8). `MYPATH` points cmake's
  `findutil()` at the S1 tool dirs, so the generated `lib/rpm/macros` names
  S1 store paths. `RPM_CONFIGDIR` selects the composed config dir per stage.
  `%_dbpath` points at a throwaway rpmdb in `$TMPDIR` (rpmbuild only needs it
  for `%{?rpm -q …}`-style probes, see glibc's sysroot quirk §8.3).
- **redhat-rpm-config + srpm-macros + rocky-release (`macros.dist`)**: noarch
  data packages. Relocated, their files land in `<out>/lib/rpm/{redhat,macros.d}`.
  The union is a `buildEnv` (`rpmConfigEnv`), the only union directory the
  engine needs. `%_rpmmacrodir` for *packages* is `%{_prefix}/lib/rpm/macros.d`
  (spike 4), so a package's own rpm macros go to its output and an
  `rpmConfigEnv` that includes it can use them (python-rpm-macros,
  systemd-rpm-macros, …).
- **debuginfo**: Rocky's find-debuginfo/debugedit/dwz run as in Rocky. They
  write `/usr/lib/debug/<P>/…` and `.build-id` links (spike 4). The splitter
  moves `-debuginfo`/`-debugsource` payloads into the single `debug` output
  as `debug/lib/debug/.build-id/xx/yyyy.debug` (the nixpkgs
  `separateDebugInfo` convention, found by gdb via `NIX_DEBUG_INFO_DIRS`) +
  `debug/src/debug/…`. The main package's `/usr/lib/.build-id/…` compat
  links are dropped (`%_build_id_links none` would also do; kept for the FHS
  twin, see §9.3).
- **brp scripts**: run unchanged, with three overrides:
  `%__brp_compress /usr/lib/rpm/brp-compress %{_prefix}` (spike 4);
  `brp-mangle-shebangs` stays (it normalises `#!/bin/` → `#!/usr/bin/`) and
  the splitter then binds `/usr/bin/<x>` interpreters to store paths
  (§6.4); `check-rpaths`: `QA_RPATHS` masks absolute store RUNPATHs (they
  are the mechanism, not a defect). `brp-strip*` and `brp-python-bytecompile`
  need nothing (bytecode embeds `P/...` source paths, rewritten like any text).
- **`%check`**: off in S1 (`--nocheck`). On in S3 by default where
  the S2 stdenv can run it (store-only root, `P` bind-mounted when tests run
  installed binaries). Per-package `check = false` with a reason when the
  testsuite needs things the sandbox cannot give (glibc: nested namespaces,
  valgrind; today's `--nocheck` reason carries over). `%check` never changes
  outputs, so it may also run as a separate check derivation.
- **Separate debug outputs**: yes, one `debug` output per SRPM (Rocky's
  per-subpackage `-debuginfo` split exists only for repo sizing). It is
  excluded from `allowedReferences` checks *of others* (nothing may reference
  `debug`), and `debug` may reference only its siblings.

---

## 5. Macro relocation (Q1)

`macros.el-nixos-reloc` (loaded last in `rpmConfigEnv`; in S1 loaded with `--load`
because the S0 macro dirs are store layers). The exact set, verified by
`rpm --eval` in spike 4:

```
%_prefix            <P>
%_exec_prefix       %{_prefix}
%_usr               %{_prefix}          # specs use %{_usr} as "/usr"
%_bindir            %{_prefix}/bin
%_sbindir           %{_prefix}/sbin     # RHEL 10 keeps sbin (filesystem-3.18); not merged into bin
%_libdir            %{_prefix}/lib64    # = %{_prefix}/%{_lib}
%_libexecdir        %{_prefix}/libexec
%_datadir           %{_prefix}/share    (%_datarootdir follows)
%_includedir        %{_prefix}/include
%_oldincludedir     %{_prefix}/include  # platform macro hard-codes /usr/include
%_infodir           %{_datadir}/info
%_mandir            %{_datadir}/man
%_docdir/%_defaultdocdir %{_datadir}/doc   %_defaultlicensedir %{_datadir}/licenses
%_usrsrc            %{_prefix}/src
%_fmoddir           %{_libdir}/gfortran/modules
%_rpmmacrodir       %{_prefix}/lib/rpm/macros.d      # where *packages* install macros
%rpmmacrodir        %{_rpmmacrodir}                  # fedora-misc-srpm hard-codes it
%_sysusersdir       %{_prefix}/lib/sysusers.d
%_unitdir %_userunitdir %_presetdir %_tmpfilesdir %_udevrulesdir %_modulesloaddir
%_sysctldir %_binfmtdir %_environmentdir %_journalcatalogdir  -> %{_prefix}/lib/...
%_pam_moduledir     %{_libdir}/security
%_fontbasedir       %{_datadir}/fonts
%_fontconfig_templatedir %{_datadir}/fontconfig/conf.avail
%gopath             %{_datadir}/gocode
%perl_vendorlib     %{_datadir}/perl5/vendor_perl    # otherwise perl -V answers perl's own store path
%perl_vendorarch    %{_libdir}/perl5/vendor_perl
%python3_sitelib / %python3_sitearch: python-srpm-macros computes them with
                    sysconfig vars base=platbase=%{_prefix}, so they follow the prefix
%lua_libdir %lua_pkgdir   -> %{_libdir}/lua/%{lua_version}, %{_datadir}/lua/%{lua_version}
--- stays FHS (runtime state and configuration) ---
%_sysconfdir        /etc
%_localstatedir     /var
%_sharedstatedir    /var/lib
%_rundir            /run
%_initddir          /etc/rc.d/init.d
%_pam_confdir       /etc/pam.d
--- the build tool's own, not relocated ---
%_rpmconfigdir      the engine's config dir (S1: /usr/lib/rpm; S2+: the /usr/lib/rpm shim)
--- tools (generated per stage, S2+) ---
%__cc %__cxx %__cpp %__ld %__as %__ar %__strip %__objdump %__make %__tar %__gzip … -> store paths
%__brp_compress     %{_rpmconfigdir}/brp-compress %{_prefix}
--- generic relocation plumbing (spike 9) ---
%__spec_install_pre %{___build_pre}\
    %{__rm} -rf "%{buildroot}"\
    %{__mkdir_p} "%{dirname:%{buildroot}}"\
    %{__mkdir} "%{buildroot}"\
    ln -s <P without leading /> "%{buildroot}/usr"; mkdir -p "%{buildroot}<P>"
%__check_files      el-nixos-check-files %{buildroot}     # /usr/x and P/x are the same file
%_build_id_links    compat (kept; the splitter drops lib/.build-id from runtime outputs)
```

These go in a macro file. `rpmbuild --define` drops everything after a raw
newline in the value (verified), so the multi-line overrides cannot be
passed as `--define`.

**/etc, /var, /run at runtime.** Programs are compiled with `/etc` and
`/var` and read them at runtime. Files the spec installs into
`%{buildroot}/etc` (rpm `%config`) are moved by the splitter into
`<output>/etc/…` as defaults (as nixpkgs does), `/var` content into
`<output>/var/…`. The `%config`/`%ghost`/mode/owner metadata goes into
`<output>/nix-support/rpm-files.json`, for a later NixOS module or image
builder. `%ghost` files have no content and are only recorded. Scriptlets
(`%post` and the rest) are recorded in `nix-support/rpm-scripts.json` and not
run (they modify the system: ldconfig, iconvconfig, alternatives, …). Their
Nix equivalents are either nothing (an ld.so.cache is unnecessary with
RUNPATH) or per-package union generators (§8).

**Hard-coded `/usr` in specs**: three generic layers, then per-package.
1. **Fail loudly at build time**: the S2/S3 root has no `/usr/{bin,include,lib64}`
   (S1: the composed sysroot hides FHS libc). A hard-coded build-time `/usr`
   (`--with-headers=/usr/include`, `/usr/bin/foo` in a Makefile) fails.
2. **Fold at install time, with a warning**: payload paths under `/usr/…`
   (spec installed to `%{buildroot}/usr/x` and listed `/usr/x` in `%files`)
   are mapped like `P/x`, `/bin`, `/sbin`, `/lib64` after usrmove. The splitter
   reports every folded path in `nix-support/el-nixos-folded`. References to
   folded paths inside files (text: exact; binary: only if the string is
   `/usr/x`, which is shorter than any store path, so impossible
   length-preserving) are **errors** for binaries and rewrites for text.
3. **Per-package override** (`packages/<srpm>.nix`): `specRewrites = [ { from;
   to; count = 1; } ]` (literal, each must match exactly `count` times;
   e.g. glibc's `--with-headers`), `defines`, `configSite` lines, `prepPatches`
   (applied by `%__spec_prep_post`, i.e. at the end of `%prep`, without
   touching the spec's patch list), `bconds`, `dirOwner`, `noRef`,
   `mergeOutputs`, `lateRefs`, `check`.

---

## 6. Output splitting (Q2)

### 6.1 Pipeline (one derivation per SRPM, outputs = subpackages + `debug`)

```
rpmbuild -bb (relocation macros, %_binary_payload w0.ufdio: uncompressed, fast)
  -> transient RPMS/*/*.rpm  (never copied to $out)
  -> for each RPM: NAME -> output (static map), rpm2cpio | cpio into $TMP/split/<output>
       path P/x                      -> <output>/x
       /etc/x, /var/x                -> <output>/etc/x, <output>/var/x  (defaults; runtime reads /etc)
       /usr/lib/debug, /usr/src/debug-> debug/lib/debug, debug/src/debug
       /usr/lib/.build-id            -> dropped
       /usr/x, /bin/x, /lib64/x …    -> <output>/x  (fold, reported)
  -> ownership map: relative path -> output (files, symlinks, dirs owned by exactly one output)
  -> rewrite P occurrences in every file (§6.2)
  -> shebang binding, nested-reference scan, output-cycle check, ELF NEEDED-resolution check
  -> copy to $out, $devel, … ; RPM headers -> <output>/nix-support/rpm-{header,files,scripts}.json
```

### 6.2 Reference rewriting P → output

For each occurrence of P followed by `/rest`, find the longest prefix of
`rest` in the ownership map. That gives target output o, and the occurrence
becomes `o-path` + `/`·(len(P) − len(o-path)) + `/rest`:
- **ELF, archives, any binary, and symlink targets**: slash padding (spike
  6), so the length is unchanged and section offsets and C string lengths
  (`sizeof` tables such as ld.so's `system_dirs_len`) stay valid.
- **Text files** (shebangs, `.pc`, `.la`, linker scripts like `libc.so`,
  `*.cmake`, scripts): exact rewrite without padding (cosmetic).
- **Bare P or a directory spanning several outputs** (e.g. `P/lib64` from
  `ld.so`'s search path, `P/share/locale`): resolved by `dirOwner` (default:
  the output that owns most files below it; for `lib64` it is `out`, i.e.
  where `libc.so.6` is). **If the string is the bare prefix itself** (Python's
  `sys.prefix`-style "everything is below P"), the splitter fails with
  "prefix-relative package split across outputs: merge them or declare
  dirOwner". Such packages must keep the outputs that share the prefix
  together (python3 + python3-libs is the expected case).
- `.debug` files: rewritten too (DWARF strings are in string tables, and
  slash padding keeps offsets).

Alternatives considered:
- **Per-directory macro→output mapping** (`%_includedir` = `$dev/include`…)
  breaks for glibc immediately. `glibc` and `glibc-devel` share `%_libdir`
  (`libc.so.6` vs `libc.so`/`libc_nonshared.a`/`crt1.o`), and so do
  most `-libs`/`-devel` pairs. rpm's `%files` partition is per file, not
  per directory.
- **Install-with-placeholders** (`builtins.placeholder` style): the same
  rewrite with uglier strings in build logs. Nothing gained over a
  real-looking P.
- **Equal-length output names**: impossible with Nix's store naming (`out`
  has no suffix). Slash padding gives the same property for free.

### 6.3 Concrete glibc mapping (spike 5)

Output `out` (`glibc`): `lib64/{libc.so.6,ld-linux-x86-64.so.2,…}`,
`sbin/{ldconfig,iconvconfig}`, `libexec/getconf`, `lib64/gconv` (the 15
modules glibc itself ships), `etc/{ld.so.conf,rpc}`. Cross-output
compiled-in references after relocation:

| from (file) | string | owner | decision |
|---|---|---|---|
| `libc.so.6`, `ldconfig` | `P/lib/locale/locale-archive` | all-langpacks | **noRef** (it would pull 220 MB into every closure): rewritten to `out`'s own (non-existent) `lib/locale/locale-archive`; archives are found via `LOCALE_ARCHIVE` (patch) and locale dirs via `LOCPATH` (native) |
| `ld.so` | `P/lib64/` (system search dir) | dir: out, devel, static, nss-devel, gconv-extra, libnsl, nss_* | `dirOwner lib64 = out` |
| `libc.so.6` | `P/lib64/gconv`, `…/gconv-modules.cache` | out (+gconv-extra) | `dirOwner = out`; extras via `GCONV_PATH` |
| `libc.so.6` | `P/share/locale` (catalogs) | langpacks (dir) | `dirOwner = common` (`locale.alias` is there); catalogs via `TEXTDOMAINDIR`/LOCPATH-like profile (§8) |
| `libc.so.6` | `P/libexec/getconf` | out | self |
| `locale`, `localedef` | `P/share/i18n/charmaps`, `…/locales` | locale-source | real reference common → locale-source; acyclic, kept (or noRef if common's closure must stay small; open question for the reviewer) |
| `ldd` (common) | `/lib/ld-linux.so.2` | glibc32 | `glibc32`'s path; acyclic |
| `ld.so` DWARF | `/usr/include/{sys,linux}` | (build inputs) | gone with `-ffile-prefix-map` (§4.1) |
| `libc.so.6` | `/usr/share/zoneinfo`, `/bin/sh`, `/usr/bin` (confstr) | not prefix-derived | stay FHS; `TZDIR` is native |
| headers, `libc.a`, `.mo` | `/etc/*`, `/var/*` | runtime-FHS | stay |

The result is acyclic (spike 5 graph minus the DWARF edge), so **no merge is
needed for glibc**.

### 6.4 Shebangs and interpreters

After brp-mangle-shebangs, interpreters are `/usr/bin/<x>`. The splitter
maps `<x>` through the stage's interpreter table (`bash sh perl python3
python3.12 lua tclsh …` → store paths of the declared inputs), or produces an
`eeee` late-binding placeholder when the interpreter package is built later
(§7.3). An unknown interpreter is an error. `#!/bin/sh` and `#!/usr/bin/env x`
stay (host-provided); `env x` is allowed only for non-shipped scripts unless
the override says otherwise, because on NixOS it would find the user's x.

---

## 7. Reference cycles (Q3)

### 7.1 Between outputs of one SRPM

Nix rejects cycles between outputs of a derivation. The splitter computes
the output graph (which output's files contain which sibling hashes, with the
file and the string) *before* copying to `$out`. A cycle fails the build with
every edge listed and three suggested fixes, all static (eval-time) overrides:
- `dirOwner` (most cycles come from shared directories, spike 5),
- `noRef` (a path compiled in for convenience whose target lives in a fat
  sibling, like locale-archive above): rewrite to a self path or FHS,
- `mergeOutputs = [ [ "glibc" "glibc-common" ] ]`: one Nix output named after
  the first. The other names become aliases (`rocky.glibc-common` → the merged
  output); `nix-support/rpm-*.json` keeps the per-subpackage metadata so
  parity still compares per RPM.

Strongly connected components are merged only on declaration, never
automatically, because a merge changes closures. The failure message gives
the SCC.

### 7.2 Between SRPMs: BuildRequires cycles

See §10.3 (stage-shifted back edges + library second pass).

### 7.3 Between SRPMs: runtime references against the build order (late binding)

A reference from A to B where B build-depends on A (glibc-common's `ldd` →
bash; glibc's `memusage` → glibc-utils' own libraries is intra-SRPM, fine):
1. The splitter rewrites the build-time interpreter (the previous stage's
   bash, same store name) to `/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-bash-5.2.26-6.el10/…`.
   This is exact-length because the name is stage-independent (§2).
2. The raw output therefore has no reference to B, so there is no derivation
   cycle.
3. `bindLate { drv = A; output = "common"; refs = { bash = rocky.bash; }; }`
   copies the output and substitutes `eeee…` with B's hash, a pure hash
   substitution valid in any file type. `rocky.glibc-common` = this bound
   output.
4. The purity scanner forbids `eeee…` in anything reachable from `rocky.*`,
   and `disallowedRequisites` on every consumer includes the raw outputs that
   have late refs.

Only outputs with late refs are bound. `rocky.glibc` (`out`, the libraries)
is never rebound, so bash's reference to it is final and stable.

---

## 8. Union directories at runtime (Q4)

### 8.1 Principle

No mutable shared directory exists, so the union of "modules from several
packages" is made by Nix composition. Each case uses the mechanism the
upstream software already supports:

| union | mechanism (no patch unless noted) |
|---|---|
| shared libraries | RUNPATH (link time); no ld.so.cache needed |
| locales | glibc-langpack-xx ship `lib/locale/<loc>/LC_*` dirs → `LOCPATH=<langpack>/lib/locale[:…]`; glibc-all-langpacks' archive → `LOCALE_ARCHIVE` (**patch 1**, nixpkgs' `nix-locale-archive.patch`, ~20 lines; also makes setuid programs ignore it, as nixpkgs does) |
| gconv modules | `out` contains glibc's own modules + cache. `glibc-gconv-extra`'s modules via `GCONV_PATH=<gconv-extra>/lib64/gconv` (native, honoured for non-setuid). A `rocky.glibcGconvAll` buildEnv runs `iconvconfig` over both → a merged dir with one cache (the Nix form of gconv-extra's `%post`) |
| message catalogs | `TEXTDOMAINDIR` is per-domain in gettext; glibc's own `libc.mo` are found through `LANGUAGE`/LOCPATH-style search only under `localedir` → `buildEnv` profile (`share/locale`) + `NLSPATH`/`TEXTDOMAINDIR` in wrappers; low priority |
| NSS modules | `/etc/nsswitch.conf` (runtime FHS) + dlopen → glibc's own `lib64` (relocated system dir); third-party modules (sss, systemd) via nscd/nsncd on NixOS, as with nixpkgs glibc |
| ld.so.cache | **patch 2** (nixpkgs' `dont-use-system-ld-so-cache.patch`): cache path `<out>/etc/ld.so.cache`, which is never generated. Otherwise a Rocky host's `/etc/ld.so.cache` would inject host libraries into store programs for any soname not found via RUNPATH (dlopen of bare sonames from objects without RUNPATH). `/etc/ld.so.conf` is shipped in `out/etc` only as a default |
| time zones | `TZDIR` (native); compiled default `/usr/share/zoneinfo` stays FHS (tzdata is another SRPM and would create a build cycle) |
| man/info/pkgconfig/aclocal/cmake | `buildEnv`/profiles; `PKG_CONFIG_PATH`/`ACLOCAL_PATH`/`CMAKE_PREFIX_PATH` built by the S3 wrapper from `buildInputs` (the setup-hook role) |
| python site-packages, perl @INC, lua, gi typelibs, plugin dirs | per-ecosystem `buildEnv` + env var (`PYTHONPATH`/site dirs via `.pth`, `PERL5LIB`, …), the nixpkgs pattern. Packaged per ecosystem when the first such SRPM is reached |
| rpm macros (build time) | `rpmConfigEnv` (§4.2) |

### 8.2 Where glibc differs from nixpkgs' glibc (comparison)

nixpkgs: single prefix per output (`out`, `bin`, `dev`, `static`, `getent`),
`--sysconfdir=/etc`, ld.so.cache moved to `$out/etc`, `LOCALE_ARCHIVE`
patch, gconv in `$out/lib/gconv`, rtld search path = `$out/lib` (no FHS dirs),
no `/etc/ld.so.conf` processing at runtime. Ours: the same runtime
semantics, Rocky's subpackage granularity (224 outputs) and layout
(`lib64`, `sbin`), only the two patches above, and every other path decided
by `config.site` + `dirOwner`/`noRef`.

### 8.3 glibc build quirks under relocation (measured, spike 9)

Each item was hit in a real relocated `rpmbuild -bb` of the glibc SRPM in
today's glibc buildroot (8 iterations, ~15 min each):

- **configure/compile**: both builds (i686 for glibc32 and x86_64)
  configure and compile with `--prefix=P`. The `config.site` must be
  **conditional on `$host_alias`**. The i686 build (`--host=i686-linux-gnu`)
  needs `libdir=${exec_prefix}/lib`, `libc_cv_slibdir=libc_cv_rtlddir=P/lib`;
  forcing lib64 for both put 32-bit `sotruss-lib.so` into `P/lib64/audit`.
  The 32-bit ld.so then gets `-dynamic-linker=P/lib/ld-linux.so.2`, as
  Rocky's `/lib/ld-linux.so.2`.
- **`libc_cv_sysconfdir` is not enough**: the cache variable is only
  consulted inside the `prefix=/usr` branch. `make install` wrote
  `P/etc/rpc` and the spec's `echo … > %{glibc_sysroot}/etc/ld.so.conf`
  failed. `config.site` must set the autoconf variables `sysconfdir=/etc` and
  `localstatedir=/var` themselves.
- **`%install` assumes `/usr` inside the buildroot**: `mkdir -p
  %{glibc_sysroot}/usr/$d` + `ln -s usr/$d %{glibc_sysroot}/$d` (usrmove),
  the i686 pruning `rm -rf … usr/bin …; rm usr/lib/libc_malloc_debug.so`
  (relative to the buildroot), `%{glibc_sysroot}/sbin/ldconfig -N -r …`,
  `hardlink -c %{glibc_sysroot}/usr/lib/locale`. A generic fix works without
  editing the spec: a **fold symlink `%{buildroot}/usr → nix/store/<P>`**,
  created by redefining `%__spec_install_pre`. With it, the spec's own
  usrmove links (`bin → usr/bin`) resolve into P, the pruning and `ldconfig`
  steps pass, and the generated langpack file lists contain P paths. Two
  pitfalls found: (a) the platform macro's `%__spec_install_pre` is what
  removes and recreates the buildroot, so the override must repeat its
  `%{__rm} -rf / %{__mkdir_p} / %{__mkdir}` lines before the `ln -s`;
  (b) `rpmbuild --define` silently drops everything after a raw newline in
  the value, so multi-line overrides go into a macro file (`--load`, or
  `macros.el-nixos-reloc` in S2+), or use `\`-escaped newlines (verified
  with `rpm --eval`).
- `rpm -ql kernel-headers | grep ^/usr/include` (sysroot subpackage, not
  shipped): works in S1 (the S0 rpmdb has kernel-headers). In S2/S3 the
  rpmdb is empty, so the result is an empty sysroot package (harmless, not
  shipped) or a declared skip.

---

## 9. Enforcement, verification, reproducibility (Q7)

### 9.1 Closure purity (per output, inductive)

`mkRockyDerivation` (all stages ≥ S1) sets, with `__structuredAttrs`,
`outputChecks.<o>.allowedReferences = [ <sibling outputs except debug> ] ++
<declared runtime inputs of the same stage>` and
`outputChecks.<o>.disallowedRequisites = <late-ref raw outputs>`. Base case:
glibc has no inputs of its own stage, so its outputs may reference only each
other. Induction: if every same-stage input output references only
same-stage outputs, so does every closure. The check is *exact* because the
sandbox's `/nix/store` contains only the input closure: the Nix scanner can
see every possible reference except those hidden in compressed data.
`allowedRequisites` over the whole set is avoided because listing every
`rocky.*` output would make each derivation depend on all of them.

**Hidden references**: the build-time scanner (`tools/rpm_purity.py`
refactored into `tools/store_refs.py` with the same decompression engine:
gzip/xz/bzip2/zstd members, ELF `.gnu_debugdata`, compressed sections) runs
on the split outputs. Every `/nix/store/<hash>-` it finds, nested or not,
must be an allowed reference. Nested hits are written uncompressed to
`<o>/nix-support/nested-references`, so Nix registers them as references
(otherwise a gzip'ed man page or a MiniDebugInfo blob could name a path
missing from the closure). `eeee…` placeholders are forbidden in bound and
final outputs. Hashes of S0/nixpkgs paths are forbidden everywhere ≥ S1 (the
scanner is given that list: the S0 root's closure, which is in its input
closure in S1).

**Global audit** (`checks.rocky-closure`): `exportReferencesGraph` of all
`rocky.*` outputs. Every path in the union of closures must be a `rocky.*`
output (the check gets the expected outPaths as a JSON file). It also reports
closure sizes, e.g. "glibc: 1 path, 9 MB; glibc-common: …".

### 9.2 Build purity (S2, S3), at evaluation time

`mkRockyDerivation` collects `builtins.getContext` of every string attribute
(builder, args, env, structured attrs) and asserts that each context element
is (a) an output of the previous or same stage's set, (b) a lock FOD
(`builtin:fetchurl`), or (c) a file of this repo (`tools/*.py`, macro files).
nixpkgs and `stage0` derivations fail evaluation with a clear message. This
is IFD-free and runs in `nix flake check --no-build` and nix-eval-jobs.

### 9.3 Parity with official RPMs under relocation

Relocation changes every ELF layout (a longer `.interp`, a new
`DT_RUNPATH`, a longer `.dynstr`), so today's byte-level loaded-section
comparison cannot apply directly. Two layers keep the guarantee:

1. **FHS twin** (exists): the same SRPM in the same stage built by today's
   `buildSrpm` (FHS, `.rpm`) remains the bit-level anchor against Rocky
   (`checks.glibc-parity`, `-abi`, `-runtime` keep running; S1's twin is
   today's S0 build, S3's twin is an FHS build with the S2 stdenv in an FHS
   root).
2. **Relocated vs official** (`mkNixParityCheck`, a new mode of
   `tools/rpm-parity.py`):
   - *File list*: for each output, the relative file list
     (`nix-support/rpm-files.json` + the tree) equals the official RPM's
     list with `/usr` → `` and `/etc` → `etc`, modes and file flags from the
     recorded headers; `.build-id` and debug entries are excluded by rule.
   - *Non-ELF bytes*: equal after normalising `/nix/store/<hash>-<name>[/]+`
     → `/usr/` (and `eeee` → real), i.e. every locale, header, `.mo`,
     script and gconv data file.
   - *ELF*: dynsym with versions, verdef/verneed, NEEDED, SONAME, GNU
     properties, stapsdt count, section list, sizes of code sections; and
     **`.text`/`.rodata`/`.data` bytes after relocation normalisation**
     (disassemble with relocation-aware diff or compare against the FHS
     twin linked at the same addresses). Expected differences:
     `.interp`, `.dynstr`, `.dynamic`, the string bytes of relocated paths.
   - *Behaviour*: today's `glibc-runtime` script, run with **store binaries
     directly** (no chroot, `/nix` visible), env `LOCPATH`/`GCONV_PATH`, and
     programs compiled with the stage's wrapper against `glibc-devel`/`-static`.
     The report must match the official RPMs' report (from today's RPM-only
     root) line for line, apart from paths.
   - *ABI* (`tools/abi-compare.py`): runs unchanged on the trees (it compares
     symbols and headers, not paths); headers byte for byte.

### 9.4 Reproducibility

- Same as today: `SOURCE_DATE_EPOCH` from the changelog, fixed buildhost,
  `%_smp_build_ncpus` from `NIX_BUILD_CORES`, logs in a separate output
  (`logs`, store hashes nuked), the sandbox. Transient RPMs are never output,
  so BUILDTIME/COOKIE/header noise disappears entirely. File mtimes are
  normalised by Nix.
- Static archive member dates (ar) remain the one known non-determinism. In
  nix-native mode the splitter rewrites ar member headers to
  `SOURCE_DATE_EPOCH`/uid 0. This is a deviation from Rocky's bytes, but
  parity ignores member headers already and Nix wants determinism.
- `nix build --rebuild` per output: with logs separate, `out` is now compared
  (§DESIGN "Reproducibility" explains why today's check stops at `logs`).
  `checks.reproducible-<srpm>` builds the derivation twice with different
  `NIX_BUILD_CORES` and compares all outputs except `logs`.
- **CA derivations (optional, later)**: the fixpoint property (S3 = S4
  normalised) is exactly what content addressing needs for early cut-off.
  With `__contentAddressed = true` on the stdenv set, a nixpkgs pin bump
  that changes S0/S1 but not S2 output bytes would stop rebuilding at S2.
  Determinate Nix 2.36 supports it as an experimental feature. Not required
  for the design.

---

## 10. Scaling to 2217 SRPMs (Q8)

### 10.1 Per-package files

`packages/<srpm>.nix` only when needed; the default is the generic recipe.
Fields: `outputs` (extra unshipped subpackages), `mergeOutputs`, `dirOwner`,
`noRef`, `lateRefs`, `specRewrites`, `prepPatches`, `configSite`,
`defines`, `bconds` (per stage), `check`, `extraInputs`, `parityAllow`
(`tools/parity/<srpm>.json`, as today). Expected: most leaf C packages need
nothing; the toolchain, interpreters (python, perl: prefix-relative), systemd
(many dir macros) and the Java/Go/Rust ecosystems need overrides.

### 10.2 BuildRequires → inputs (static, from the lock)

The generator (`tools/update-lock.py`) writes `lock/rocky-10.2/inputs.json`:
for every SRPM, its BuildRequires resolved **to direct providers only**
(binary name → SRPM + output), using the resolver's provider-choice rules
(already validated 260/260 against dnf5), without Requires closure and
without the mock buildsys. Nix reads it with `fromJSON`, so evaluation stays
static and IFD-free. The implicit stdenv (compiler, binutils, glibc-devel,
make, coreutils, rpm engine, redhat-rpm-config) is not listed. Runtime
closures come from references. Rich/file deps are resolved by the generator
(file deps through `deps.json` files + usrmove, as the resolver does).
Arch-conditional and `%generate_buildrequires` cases are reported by the
generator and fixed per package with `extraInputs`.

Input wiring: each BR provider output is a build input. Its `include`,
`lib64`, `lib64/pkgconfig`, `share/aclocal`, `bin` are offered through the
wrapper/env (`-isystem`, `-L`/`-rpath`, `PKG_CONFIG_PATH`, `ACLOCAL_PATH`,
`PATH`). `-devel` outputs propagate the outputs they reference (the
reference graph is known only after the build, so propagation is declared
from the lock: `-devel` Requires on `<name>-libs`/`<name>` of the same SRPM,
and `pkgconfig(...)` Requires of `.pc` files, which `deps.json` already has).

### 10.3 Build-order cycles (spikes 1–2)

The direct-BR graph has a 926-SRPM SCC. Cycle breaking:
1. **S3 order** = the greedy feedback-arc order (spike 2 gives 771 back
   edges over 265 targets). The generator computes it deterministically and
   writes it to `lock/…/order.json`, reviewed like any lock change.
2. A back edge X → Y (Y later in the order) is satisfied by **Y from the
   previous stage** when Y is in the stdenv set (S2), else by
   **`rockyBoot2.Y`**: Y built once in the S2 environment *without* its
   own back-edge BRs (boot bconds, `--nocheck`, docs off; spike 2: removing
   doc+test edges alone shrinks the SCC from 926 to 840, and lib-only leaves
   225). This "bootN" layer is the per-package `bconds.boot`, the Fedora
   `%bcond bootstrap` idea, in data.
3. **Library back edges** (144 SRPMs) may produce references into
   `rockyBoot2.Y`. These are forbidden by `disallowedRequisites` (= all
   rockyBoot2 outputs) on every `rocky.*` output, so such an X fails and gets
   `pass2 = true`: X is rebuilt with `rocky.Y` (the final Y, built from the
   pass-1 X). Tool, doc and test back edges (≈ 600 of 771) never need pass 2,
   since build-only inputs leave no reference (scanner-enforced).
4. **Self-loops** (33 in the direct graph: gcc, glibc, rust, golang, java,
   dotnet, llvm, perl, python3.x, make, automake, cmake, nss, gnupg2…)
   are the same pattern with Y = X. The previous version is `rockyBoot.X` (S1)
   for the stdenv set; for the others it is X built in the S0 chroot
   with nixpkgs' previous version as the BR (rust from nixpkgs rustc, go from
   nixpkgs go, java from nixpkgs jdk), relocated, closure-checked, exposed as
   `rockyBoot.X`. dotnet and similar SRPMs that bundle prebuilt binaries are
   reviewed case by case.
5. **Eval-time acyclicity check**: since each stage's input wiring is
   static, the Nix-level graph is a DAG by construction. A `checks.order` test
   recomputes from `inputs.json` + `order.json` + `bconds.boot` that every
   back edge has a provider in an earlier layer, and fails with the cycle
   otherwise.

### 10.4 CI

`hydraJobs.rocky.<binary-name>`, `.rockyBoot.*`, `.rockyStdenv.*`, checks.
`tools/build-jobs.sh` already runs nix-eval-jobs with IFD off and builds
only what is missing. Keep `--force-recurse`. For 2217 multi-output
derivations, evaluation stays cheap (the lock is ~3 MB of JSON; one attrset
per SRPM). Builds need `requiredSystemFeatures = [ "big-parallel" ]` for the
≈ 30 big SRPMs (gcc, glibc, llvm, rust, kernel, firefox-class), listed in
overrides.

---

## 11. Glibc milestone: ordered implementation plan (Q9)

Goal: `rockyBoot.glibc` with 224 outputs (+ `debug`), relocated, closure =
only its own outputs, verified against the official RPMs by relative path,
ABI and behaviour. Reuse first: `lib/chroot.sh`, `lib/default.nix`
(`mkBuildroot`, the `buildSrpm` skeleton), `bootstrap/` (S0 root,
`mkRoot`, kernel-headers build, `glibcBuildDeps`, `texinfo71`),
`packages/glibc.nix` (subpackage list, shipped/unshipped,
`glibc-sanity.sh`, `glibc-runtime/`), `tools/rpm_purity.py` (scan engine),
`tools/rpm-parity.py`, `tools/abi-compare.py`.

1. **`lib/reloc/macros.nix`**: the macro set of §5 as data → a macro file
   (`--load` in S1, `macros.el-nixos-reloc` in `rpmConfigEnv` in S2+). Test: `checks.reloc-macros`
   = spike 4's `rpm --eval` table as a golden file.
2. **`lib/reloc/prefix.nix`**: P from the static output list (max output
   path length; the hash part is `out`'s, taken from `$out` at build time).
3. **`tools/nix-split.py`** (stdlib only): RPM → outputs (§6.1), ownership
   map, P rewriting with slash padding (§6.2), shebang binding + `eeee`
   placeholders (§6.4/§7.3), output-cycle detection with edge report (§7.1),
   ar header normalisation, `nix-support/rpm-*.json`. Unit tests with tiny
   fixtures as `checks.nix-split-selftest-*` (a cycle must fail, a padded
   ELF must run, a gz'ed file with a hidden ref must be reported).
4. **`tools/store_refs.py`**: refactor of `rpm_purity.py`'s scanner to trees
   with an allowed-hash list + `nested-references` writer. Keep
   `rpm_purity.py` as a thin wrapper so the RPM pipeline stays byte-identical.
5. **`lib/default.nix: buildSrpmNix`**: the `buildSrpm` skeleton +
   relocation macros loaded from a macro file (not `--define`: raw newlines
   are dropped) + `CONFIG_SITE` (exported; redhat-rpm-config passes
   `CONFIG_SITE=${CONFIG_SITE:-NONE}` through) + `specRewrites` +
   `%__spec_prep_post` patches + `%__spec_install_pre` = platform value +
   fold symlink `%{buildroot}/usr → P` + a canonicalising `%__check_files`
   (`/usr/x` ≡ `P/x`) + split + scan + `outputChecks`. Outputs from the
   static list. Spike 9 already shows that this produces the right `%files`
   partition for all 233 glibc subpackages.
6. **`bootstrap/s1-root.nix`**: S0 root without stage0 libc in
   `/usr/{include,lib64}` (glibc's build needs none: it uses the kernel
   headers and builds its own libc). The wrapper layer (`--sysroot` farm,
   dynamic linker, rpath, prefix maps) comes in step 9, when the first
   package that *links* against S1 glibc needs it.
7. **`packages/glibc/nix.nix`**: `configSite` (spike 9 values, `$host_alias`-conditional),
   `specRewrites` (`--with-headers`), `prepPatches` (nix-locale-archive,
   ld.so.cache), `dirOwner`/`noRef` per §6.3, `lateRefs` (bash, perl for
   common/utils), output names from `rpmsLock.bySrpm.glibc` + the 3
   unshipped. Expose `rockyBoot.glibc` / `rockyBoot.glibc-<x>`.
8. **Verification (`checks.nix-glibc-*`)**:
   - `nix-glibc-closure`: every output's closure ⊆ glibc's outputs; sizes.
   - `nix-glibc-files`: relative file lists vs the 221 official RPMs.
   - `nix-glibc-abi`: `abi-compare.py` on the trees vs official payloads
     (headers bytes, dynsyms, versions, NEEDED, SONAME).
   - `nix-glibc-bytes`: non-ELF bytes equal after path normalisation.
   - `nix-glibc-runtime`: `glibc-runtime/test.sh` adapted to call store
     binaries directly (`$glibc/lib64/ld-linux-x86-64.so.2 --list`,
     `$common/bin/locale` with `LOCPATH`, iconv with `GCONV_PATH`,
     getent with the sandbox's `/etc`), compared with today's
     official-RPM report.
9. **First consumers** (proves composability): `rockyBoot.zlib-ng`,
   `rockyBoot.bash` linked against `rockyBoot.glibc` with the S1 wrapper,
   then bind `rockyBoot.glibc-common` (ldd → S1 bash), then `which` as the
   smallest end-to-end package (spike 4 recipe, now with RUNPATH). They run
   on the host from the store, and a `buildEnv`/`mkShell` with
   `rockyBoot.{bash,which,glibc-common}` works.
10. Then continue the S1 order of §3.3, followed by S2 and S3 (glibc
    rebuilt twice more with the same recipe).

### Risks

| risk | mitigation |
|---|---|
| slash padding breaks software that compares compiled-in paths with `realpath()` results (Python `sys.prefix`, some plugin loaders) | because P is synthetic, *every* binary reference to P is padded, including references within one output (text files are rewritten exactly). Fallback per package: `mergeOutputs` plus prefix-relative detection (§6.2). Measure on python3 early in the S1 order |
| glibc's `%install` has more hard-coded `/usr`//`sbin` than the fold symlinks cover | resolved for glibc in spike 9 (fold symlink + config.site; 233 RPMs). For other specs: `specRewrites` with exact-count checks |
| the fold symlink makes files reachable as both `/usr/x` and `P/x` (check-files, find-debuginfo's `/usr/lib/debug/nix/store/<P>` layout) | canonicalising `%__check_files`; the splitter maps both spellings to one relative path and fails on a true duplicate |
| gcc relocation (multilib dirs, `-print-file-name`, specs, LTO plugin in `lib/bfd-plugins`) | gcc keeps everything below its prefix by design (`--prefix=$P`, gcc is relocatable via `GCC_EXEC_PREFIX` logic); test with today's `tests/toolchain.sh` adapted to store paths |
| 224 outputs in one derivation (glibc langpacks) | Nix has no output limit; if evaluation or the UI suffers, langpacks can be one extra derivation that splits the transient RPMs of the same build (still static) |
| debuginfo with relocated paths (`/usr/lib/debug/nix/store/<P>/…`) | the splitter keys on `.build-id` only; gdb finds `debug/lib/debug/.build-id` via `NIX_DEBUG_INFO_DIRS` |
| nixpkgs pin bump rebuilds the world | inherent to an S0 seed; CA derivations (§9.4) as a later optimisation; S0 already pins nixpkgs via `flake.lock` |
| rust/rpm-sequoia and gdb in the faithful stdenv | deferred (§3.4): the build-tool rpm is `--without sequoia`; `%_include_gdb_index 0` until gdb exists (affects only `debug`) |
| ELF parity cannot be byte-level after relocation | FHS twin build stays the bit-level anchor; relocated parity compares ABI, normalised non-ELF bytes, normalised code |
