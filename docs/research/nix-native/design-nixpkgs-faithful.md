# Rocky SRPMs → composable Nix store paths — design "nixpkgs-faithful"

Designer: nixpkgs-faithful. Project: `el-nixos` (branch `glibc-bootstrap`), Rocky 10.2.
Angle: copy nixpkgs' conventions wherever they fit — multiple outputs with nixpkgs
output names, `pkgs/stdenv/generic` + `cc-wrapper` + `bintools-wrapper`, setup hooks,
`fixupPhase` (`patchShebangs`, `patchelf --shrink-rpath`), `allowedRequisites`,
a nixpkgs-style `stdenvStages` bootstrap with `isBuiltBy…` asserts — and use
`rpmbuild` only as the configure/build/install driver whose spec decides *what*
is built and *how the install tree is split*.

Spikes live in `scratchpad/nn-design-nixpkgs-faithful/spikes/` (all `--impure`
expressions over `builtins.getFlake "git+file://…/el-nixos"`; nothing in the
repository was modified). Their results are quoted inline as **[Sx]** and listed
at the end.

---------------------------------------------------------------------------

## 0. The design in one page

```
rocky.stdenv            = nixpkgs pkgs/stdenv/generic, instantiated with Rocky-built bash,
                          coreutils, … and cc = nixpkgs cc-wrapper(Rocky gcc,
                          bintools-wrapper(Rocky binutils, Rocky glibc))
rocky.mkRpmPackage      = rocky.stdenv.mkDerivation {
  outputs  (static)       one per binary subpackage, from rpms.json bySrpm (+ unshipped list),
                          nixpkgs names: <srpm> -> out, -devel -> dev, -static -> static,
                          -doc -> doc, -libs -> lib, all debuginfo/debugsource -> debug,
                          <srpm>-X -> X, others verbatim; [^A-Za-z0-9_] -> _
  unpackPhase             bsdtar the SRPM; apply spec substitutions (per-package, rare)
  configurePhase          write the relocation macro file + CONFIG_SITE + per-package env
  buildPhase              rpmbuild -bb --noclean --nodeps  (%_prefix = $out, transient
                          uncompressed RPMs), inside a "tool shim" namespace that only
                          adds /bin,/usr/bin,/sbin,/usr/sbin (symlinks to the declared
                          tools) and /usr/lib/rpm (the assembled rpm config) -- no
                          /usr/include, no /usr/lib64: headers/libs only via cc-wrapper
  installPhase            rocky-partition: the RPM headers' file lists move the BUILDROOT
                          into the outputs (/usr/X and $prefix/X -> X, /etc/X -> etc/X ...),
                          rewrite cross-output references in text files and symlinks,
                          refuse unrewritable ELF cross-output references, compute the
                          output reference graph and refuse cycles (with the merge to add)
  fixupPhase (nixpkgs)    patchShebangs --host, patchELF (shrink-rpath), no strip (rpm's
                          find-debuginfo already did Rocky's strip + debuginfo split),
                          propagated-build-inputs of dev outputs from RPM Requires
  checks                  outputChecks.allowedRequisites = own outputs + Rocky outputs of
                          declared runtime deps; byte-level /nix/store scan (rpm_purity
                          logic) that only allows Rocky output hashes
}
```

What changes for the user: `rocky.glibc` is a normal multi-output derivation
(`rocky.glibc.dev`, `rocky.glibc.common`, `rocky.glibc.langpack_en` …),
`rocky.rpm."glibc-devel"` is the same path by RPM name, and anything can be
composed with `buildInputs`, `buildEnv`, `mkShell` — the store paths are
`/nix/store/<hash>-glibc-2.39-142.el10_2[-<output>]/{bin,lib64,include,share,…}`.

Why this shape (one sentence each):

* **rpmbuild stays the recipe engine** — it alone interprets the spec (macros,
  Lua, `%autosetup`, bconds, the spec's own `%install` logic, brp scripts,
  find-debuginfo) and its `%files` partition is the ground truth for outputs.
* **cc-wrapper is the composition mechanism** — specs never learn where
  dependencies live; `gcc` finds headers/libs of buildInputs through
  `NIX_CFLAGS_COMPILE`/`NIX_LDFLAGS` exactly as in nixpkgs, and the ld-wrapper
  writes `PT_INTERP`/`RUNPATH` into store paths. Spike [S2] shows the unmodified
  nixpkgs wrappers drive the stage0 (Rocky-source) gcc 14.3.1/binutils 2.41, and
  spike [S3] shows rpmbuild building the whole glibc SRPM (i686 + x86_64,
  `-Werror`, 675 patches) through them, outside any FHS chroot.
* **The prefix is the main output; everything else is a move** — `%_prefix=$out`
  makes every compiled-in path a store path; subpackages are carved out after
  `%install`. Cross-output references are found by scanning (like Nix itself),
  rewritten where that is safe (text, symlinks) and otherwise turned into a
  per-package decision (merge outputs, retarget a macro, or a runtime search path).

---------------------------------------------------------------------------

## 1. Macro relocation

### 1.1 The macro file (written by `configurePhase`, passed with `--define`/`--macros`)

Evidence [S1]: in Rocky's macro set, overriding only `%_prefix` moves
`_exec_prefix _bindir _sbindir _libdir _libexecdir _datadir _includedir _infodir
_mandir _defaultdocdir`, but **not** `_sysconfdir _localstatedir _sharedstatedir
_rundir _oldincludedir _sysusersdir _usrsrc _rpmconfigdir _rpmmacrodir
_fontbasedir`, and it **wrongly moves `__perl`** (`%{_bindir}/perl` →
`$out/bin/perl`). All tool macros (`__make __awk __cp … __find_debuginfo
__python3`) are literal `/usr/bin/…` (rpm's configure baked them in), and all
redhat-rpm-config script/spec references are literal `/usr/lib/rpm/…`
(`-specs=/usr/lib/rpm/redhat/redhat-hardened-cc1`, `%__brp_*`).

| macro | value | why |
|---|---|---|
| `%_prefix`, `%_exec_prefix` | `$out` (the main output) | every derived install dir follows; compiled-in paths become store paths |
| `%_bindir %_sbindir %_libdir %_libexecdir %_datadir %_includedir %_infodir %_mandir %_defaultdocdir %_docdir %_licensedir` | derived (unchanged definitions) | keeps Rocky's relative layout (`lib64`, `libexec`, `share/doc/<pkg>`) so relative file lists equal Rocky's |
| `%_lib` | `lib64` (unchanged) | Rocky layout; nixpkgs uses `lib`, but parity by relative path wants `lib64` (cc-wrapper/bintools-wrapper take `libc.libdir = "/lib64/"`, [S2]) |
| `%_sysconfdir` | `/etc` | runtime config is the host's, as in nixpkgs `--sysconfdir=/etc`; files installed there land in `<output>/etc` (defaults), §1.3 |
| `%_localstatedir %_sharedstatedir %_rundir %_runstatedir` | `/var`, `/var/lib`, `/run`, `/run` | runtime state is FHS; installed skeletons go to `<output>/var`, `<output>/run` |
| `%_unitdir %_userunitdir %_presetdir %_udevrulesdir %_tmpfilesdir %_sysusersdir %_modprobedir` (systemd-rpm-macros, `%{_prefix}/lib/…`) | derived → `$out/lib/systemd/system` … | exactly nixpkgs' layout, so NixOS `systemd.packages` / `services.udev.packages` consume them |
| `%_sysusersdir` | `%{_prefix}/lib/sysusers.d` (redefine; Rocky has a literal `/usr/lib/sysusers.d`) | same |
| `%_oldincludedir` | `%{_includedir}` | literal `/usr/include` otherwise |
| `%_usrsrc` | `/usr/src` (unchanged) | debugedit rewrites DWARF comp dirs to `%_usrsrc/debug/<nvra>`; keeping it FHS keeps store paths out of DWARF (sources are shipped in the `debug` output under `src/debug`, gdb `set substitute-path`) |
| `%_rpmconfigdir` | `/usr/lib/rpm` for rpm itself (the tool shim mounts the assembled config there); **`%_rpmmacrodir %{_prefix}/lib/rpm/macros.d`, `%_rpmluadir %{_prefix}/lib/rpm/lua`** for packages that *install* macros | packages that ship macros (redhat-rpm-config, *-srpm-macros, python-rpm-macros, systemd-rpm-macros) install into their own output; the config assembler (§5.3) collects them |
| `%_fontbasedir %_fontconfig_templatedir` | `%{_datadir}/fonts`, `%{_datadir}/fontconfig/conf.avail` | literal `/usr/share` otherwise |
| `%_buildshell` | `/bin/sh` (shim) | |
| tool macros `__perl __python3 __lua …` | literal FHS (`/usr/bin/perl`, …) resolved through the shim | `__perl` must be redefined (it follows `%_bindir`) |
| `%_topdir %_tmppath %_builddir` | `$NIX_BUILD_TOP/rpmbuild…` | |
| `%dist %_buildhost %source_date_epoch_from_changelog %use_source_date_epoch_as_buildtime %clamp_mtime_to_source_date_epoch %_smp_build_ncpus` | as today in `buildSrpm` | reproducibility |
| `%_binary_payload` | `w0.ufdio` | RPMs are transient (only their headers' file lists are read); avoids zstd -19 over ~1.5 GB for glibc |
| `%__spec_install_pre` | Rocky's + `mkdir -p "%{buildroot}%{_prefix}"; ln -s "%{_prefix_rel}" "%{buildroot}/usr"` | **hard-coded `$RPM_BUILD_ROOT/usr/…` folds into the prefix** (§1.4) |
| `%__spec_prep_post` | `cd %{_builddir}/%{buildsubdir} && <nixPostPrep hooks>; %{___build_post}` | where Nix-side source patches go without editing the spec (§4.3); [S3] uses it for the glibc ld.so.cache patch |
| `%_annotated_build`, `%_annobin_gcc_plugin` | stage-dependent (annobin is a Rocky package; off until annobin is built for the stage's gcc) | as in stage0 today |

`%configure`-based packages need nothing else: `%configure` passes
`--prefix=%{_prefix} --libdir=%{_libdir} --sysconfdir=%{_sysconfdir}
--localstatedir=%{_localstatedir} …` explicitly. CMake (`%cmake`), meson
(`%meson`), `%py3_install`, `%make_install DESTDIR=` all take the same macros.

### 1.2 `CONFIG_SITE` for specs that call `./configure` themselves

Specs that run raw `../configure --prefix=%{_prefix}` (glibc does) get autoconf's
defaults for everything else: `libdir=$prefix/lib`, `sysconfdir=$prefix/etc`,
`localstatedir=$prefix/var`. Rocky gets FHS values here only because it passes
`--prefix=/usr` and autoconf/glibc special-case `/usr`. The Rocky stdenv exports
`CONFIG_SITE=<stdenv>/share/config.site` that does for store prefixes what
Fedora's `/usr/share/config.site` does for `/usr` [S3, `spikes/config.site`]:

```sh
case "$prefix" in /nix/store/*)
  case "${host_alias:-${build_alias:-x86_64}}" in   # multilib: i686 keeps lib
    x86_64*|aarch64*|ppc64*|s390x*) test "$libdir" = '${exec_prefix}/lib' && libdir='${exec_prefix}/lib64' ;;
  esac
  test "$sysconfdir"    = '${prefix}/etc' && sysconfdir=/etc
  test "$localstatedir" = '${prefix}/var' && localstatedir=/var
  test "$sharedstatedir" = '${prefix}/com' && sharedstatedir=/var/lib ;;
esac
```

It must be host-aware: glibc's spec configures twice (i686 for `glibc32`, x86_64)
in one `%build`, so plain environment variables cannot differ between the two
runs. [S3] hit exactly this: with `libc_cv_slibdir` exported globally the 32-bit
libraries landed in `lib64` and the spec's `rm usr/lib/libc_malloc_debug.so`
failed. Per-package cache variables go into a second site file (`CONFIG_SITE`
takes a list); glibc's ([S3] `spikes/glibc.site`) reproduces what
`sysdeps/gnu/configure` and `sysdeps/unix/sysv/linux/x86_64/64/configure` do
for `prefix=/usr`:

```sh
case "$prefix" in /nix/store/*) case "${host_alias:-${build_alias:-x86_64}}" in
  x86_64*) libc_cv_slibdir=$prefix/lib64 libc_cv_rtlddir=$prefix/lib64
           libc_cv_complocaledir=$prefix/lib/locale ;;
esac ;; esac
```

(Without it, relocated Rocky glibc would put `ld-linux-x86-64.so.2`/`libc.so.6`
in `$out/lib` — glibc only switches to `lib64` for `prefix=/usr` — and every
`%{_libdir}` line of `%files` would fail.)

### 1.3 What stays FHS at runtime

Compiled-in, unchanged from Rocky: `/etc/*` (nsswitch.conf, hosts, resolv.conf,
localtime, gai.conf, ld.so.preload, passwd …), `/var/*`, `/run/*`, `/proc`,
`/sys`, `/dev`, `/tmp`. Files a spec installs below `/etc` or `/var` become the
owning output's `etc/…`/`var/…` (defaults, like nixpkgs' `installFlags =
[ "sysconfdir=$(out)/etc" ]`); NixOS modules or the user copy/link them into
place; `%config(noreplace)`/`%ghost` flags are recorded in
`nix-support/rpm-files` for tooling that wants to materialise `/etc`.

Not FHS any more (all under the store): `/usr/*`, `/lib64/ld-linux-x86-64.so.2`
(PT_INTERP is `$glibc/lib64/ld-linux-x86-64.so.2`), `/usr/lib/rpm/*`,
`/usr/share/zoneinfo` (glibc's default `TZDIR` becomes
`$glibc/share/zoneinfo`, which is tzdata's — see §4.2).

The exceptions that need a source change are listed in §4.3 (ld.so.cache).

### 1.4 Hard-coded `/usr` in specs

Three classes, three mechanisms:

1. **`$RPM_BUILD_ROOT/usr/...` in `%install`** (very common: glibc lines 1438,
   1474, 1650 `hardlink -c %{glibc_sysroot}/usr/lib/locale`, `pushd
   %{glibc_sysroot}/usr/lib/locale`, the sysroot package's
   `$RPM_BUILD_ROOT//usr/x86_64-redhat-linux/sys-root`). Handled **generically**
   by the relative symlink `BUILDROOT/usr -> nix/store/<hash>-<name>` created in
   `%__spec_install_pre`: every such path resolves into the prefix; `%files`
   entries spelled `/usr/...` still find their files (rpm lstat's only the last
   component) and are folded `/usr/X -> X` by the partitioner. [S3]: glibc's
   `%install` runs unmodified with this (its own `mkdir -p
   $RPM_BUILD_ROOT/usr/$d; ln -s usr/$d $RPM_BUILD_ROOT/$d` usrmove dance works
   through it — an absolute symlink did not, the relative one does).
   `/etc`, `/var` are **not** symlinked: they stay real BUILDROOT directories
   (glibc's 32-bit cleanup `rm -rf etc var …` would delete such a link and the
   later `echo … > $RPM_BUILD_ROOT/etc/ld.so.conf` would fail — seen in an
   intermediate [S3] run).
2. **Literal FHS tool paths used at build time** (`LD_SHOW_AUXV=1 /bin/true`,
   `/usr/bin/make` from `%__make`, `#!/usr/bin/bash` in rpm's own scripts,
   `/usr/lib/rpm/redhat/redhat-hardened-cc1`): the **tool shim** namespace (§5.3)
   provides `/bin /usr/bin /sbin /usr/sbin` as symlinks to the declared tools and
   `/usr/lib/rpm` as the assembled rpm config — nothing else under `/usr`. No
   macro or spec has to be rewritten for these ([S3]: redhat-rpm-config,
   find-debuginfo, brp scripts and `/bin/true` all ran unmodified).
3. **Hard-coded FHS paths that leak into outputs** (configure records
   `/usr/bin/perl` in `mtrace`; a Makefile bakes `/usr/share/foo`; a spec does
   `--with-headers=%{_prefix}/include` meaning "where my *build dependencies*
   live"):
   * shebangs: nixpkgs `patchShebangs --host` in `fixupPhase` rewrites
     `#!/usr/bin/X` / `#!/usr/bin/env X` to `$dep/bin/X` from `HOST_PATH` (the
     runtime deps, i.e. RPM `Requires` mapped to buildInputs);
   * everything else is **detected**, not guessed: the post-partition scan
     reports every `/usr/`, `/lib64/`, `/bin/` string in ELF/text outputs that
     is not on the FHS-runtime allowlist (`/etc /var /run /proc /sys /dev /tmp
     /bin/sh`) and fails unless the package's override allowlists it or fixes it
     (`substituteInPlace`-style `specSubstitutions` or `postInstall`). nixpkgs
     works the same way (per-package substitutions), we only make the detection
     systematic;
   * `%{_prefix}`-as-dependency-location bugs surface as configure/build
     failures (glibc's `--with-headers=%{_prefix}/include`: configure would look
     for kernel headers in `$out/include`). Fixed per package with a spec
     substitution to a macro that names the dependency
     (`--with-headers=%{rocky_kernel_headers}/include`, [S3]).
   A lint (`rpmspec -P` with relocation + grep, [S1]: 1378 lines of glibc's
   expanded spec mention `/usr|/lib64|/bin`, almost all harmless patch commands)
   only produces a report; the build is the real detector.

---------------------------------------------------------------------------

## 2. Output splitting

### 2.1 Mechanism

`rpmbuild -bb --noclean` leaves the post-`%install`, post-brp BUILDROOT in place
and writes transient uncompressed RPMs whose headers carry the authoritative
`%files` partition. The partitioner (`tools/rocky-partition.py`, run in
`installPhase`) reads, per RPM, `[%{FILENAMES} %{FILEFLAGS:fflags}
%{FILEMODES:perms} %{FILELINKTOS} %{FILEINODES}]` ([S3] writes exactly these
lists to `nix-support/rpm-files/<subpkg>.txt`) and then:

1. maps each path to `(output, relpath)`: `$prefix/X → X`, `/usr/X → X`,
   `/etc/X → etc/X`, `/var/X → var/X`, `/run/X → run/X`, `/usr/lib/debug/X →`
   debug output `lib/debug/X`, `/usr/src/debug/X →` debug output `src/debug/X`;
   anything else (e.g. `/boot`, `/lib/firmware` literal) → same relative path in
   the owning output;
2. moves the file from BUILDROOT (resolving the `usr` link) into
   `$<output>/relpath`; files owned by two subpackages (rpm allows shared
   files, e.g. `%license`) are copied; hard links within one output are kept,
   hard links *across* outputs are broken into copies (Nix rejects them — nixpkgs
   glibc has the same workaround for `getconf`); `%dir` creates the directory;
   `%ghost` creates nothing but is recorded; mode bits are kept (owners cannot
   be represented — recorded in metadata);
3. fails on files left in BUILDROOT that no RPM claims (rpm's own
   "installed but unpackaged" check already ran) and on `/usr` content that
   bypassed the symlink;
4. writes `nix-support/rpm-files`, `nix-support/rpm-name`,
   `nix-support/rpm-requires|provides|scriptlets` (from the header) into every
   output — the data parity checks and NixOS-side tooling need;
5. rewrites/validates references (§2.3) and checks the reference graph (§3);
6. resolves every symlink in the FHS namespace rpm saw (a link at
   `/usr/lib/.build-id/00/x` with target `../../../../nix/store/<P>/lib64/gconv/IBM1132.so`
   is rpm's build-id link written *through* the prefix, [S5]) and re-targets it:
   relative within its output, absolute `$X/rel` across outputs.

rpm itself needs one more adaptation for the `usr` link: its unpackaged-files
check (`check-files`) lists the real `$prefix/X` paths while `%files` named
`/usr/X` → `%__check_files` is replaced by a 10-line wrapper that folds `/usr`
before comparing ([S3], `spikes/check-files-nix`). The check itself stays on.

### 2.2 Output names and attributes

* Static, from the lock: `rpmsLock.bySrpm.<srpm>` (+ per-package
  `unshippedSubpackages`, e.g. glibc's `glibc32`, `sysroot-x86_64-el10-glibc`,
  `compat-libpthread-nonshared`), minus merges (§3). Nothing at eval time depends
  on a build.
* Names follow nixpkgs so nixpkgs machinery works unchanged (`lib.getDev`,
  `lib.getLib`, `outputDev`, `separateDebugInfo`-style `debug`, `chooseDevOutputs`
  for buildInputs): main subpackage `<srpm>` → `out`; `<srpm>-devel` → `dev`;
  `<srpm>-libs` → `lib`; `<srpm>-static` → `static`; `<srpm>-doc` → `doc`;
  all `*-debuginfo` + `*-debugsource` → one `debug`; `<srpm>-<rest>` → `<rest>`;
  other names (`libnsl`, `nss_db`) verbatim; then `[^A-Za-z0-9_] → _`
  (nixpkgs' `setup.sh` uses `${!output}`; shell identifiers only. [S0]: Nix
  itself accepts 230 outputs and dashed names, but `$glibc-devel` is not
  addressable from bash). If an SRPM has no subpackage named after it, the
  first `bySrpm` entry becomes `out`.
* Store paths: `/nix/store/<hash>-glibc-2.39-142.el10_2` (out),
  `…-glibc-2.39-142.el10_2-dev`, `…-langpack_en`, `…-nss_db`.
* Attributes: `rocky.<srpm>` (the multi-output derivation, nixpkgs style:
  `rocky.glibc.dev`), `rocky.rpm.<rpm-name>` (by RPM name, the BuildRequires
  resolution target: `rocky.rpm."glibc-devel" == rocky.glibc.dev`), and
  `passthru.rpmOutputs = { "glibc-devel" = "dev"; … }`.

### 2.3 Keeping references correct when files move

After the move, the partitioner scans every output for the main output's path
(`$out`) followed by a path (`$out/<rel>`), resolves `<rel>` to the output that
now owns it (exact file, else the deepest directory with a single owner) and
acts by file kind. Evidence for how often each case happens comes from [S3b]
(the analysis of the relocated glibc build, §R).

| referencing file | referenced path moved to output X | action |
|---|---|---|
| text (scripts, `.pc`, `.la`, `.cmake`, linker scripts `libc.so`, desktop/service files, `%config` files) | yes | rewrite `$out/rel` → `$X/rel` (any length); ld scripts are text (glibc's `libc.so`: `GROUP ( $out/lib64/libc.so.6 $dev/lib64/libc_nonshared.a AS_NEEDED ( $out/lib64/ld-linux-x86-64.so.2 ) )` — `libc_nonshared.a` is in `-devel`, so the line gets one rewrite) |
| symlink (absolute or relative crossing outputs) | yes | retarget to `$X/rel` (absolute store path); relative links inside one output stay relative |
| ELF / other binary | yes, **equal length** | rewrite in place (never happens across differently named outputs, see below) |
| ELF / other binary | yes, different length | **error** with the options: retarget the macro at compile time (`layout`), merge X into out, or (for union directories) a runtime search path |
| any | `<rel>` is a directory with several owners (union) | left as is: compiled-in default for *one* of them; the rest is found through search paths (§4) |
| ELF / binary | `<rel>` is a file/dir that a runtime search path covers (declared per package: `runtimeSearchPaths = { "lib/locale/locale-archive" = "LOCALE_ARCHIVE"; "share/i18n" = "I18NPATH"; }`) | left as is (dangling default), the output gets the setup hook that sets the variable |
| text | `<rel>` moved to an output the referencing subpackage does not `Require` (RPM header) | left as is and reported (e.g. `ldd`'s `RTLDLIST` naming the 32-bit loader would otherwise drag `glibc32` into `glibc-common`'s closure) |
| any | `<rel>` exists in no output | reported (dangling compiled-in path; e.g. glibc's `$out/share/zoneinfo`) |

**Why no general binary rewriting.** Store paths of different outputs differ
in length (`…-el10_2` vs `…-el10_2-langpack_en`); shrinking an embedded C string
and NUL-padding breaks linker tail-merged strings (`SHF_MERGE|SHF_STRINGS`
sections share suffixes) and compile-time `sizeof` lengths (ld.so's
`system_dirs_len[]`). Equal-length rewriting (what Nix does for
content-addressed outputs) would need all output names padded to one width
(`…-dev__________`), which makes every store path ugly to save a rare case.
Rejected; the per-package `layout` override is the escape hatch:

```nix
# packages/foo.nix: compile foo's datadir as the -common output's path
layout = { _datadir = "common"; };     # => --define "_datadir $common/share"
```

The partitioner knows the target output paths at build time (`$common` is
set), so this is a plain `--define`. The `rocky-layout-suggest` tool (lock
generator side) proposes such layouts from the *official* binary RPM file
lists (repodata `filelists.xml`), e.g. "all of `%{_datadir}/foo` belongs to
`foo-common`".

The three options compared (task item 2):

| option | ELF refs | text refs | names | verdict |
|---|---|---|---|---|
| equal-length output names + byte rewrite | always fixable | fixable | padded, ugly | rejected (UX) |
| per-dir macro → output (`layout`) | correct by construction for dirs with one owner | correct | nixpkgs-style | used *selectively* (overrides), not as default: RPM splits are per file, not per dir |
| install with prefix = main output + move + rewrite text + detect ELF | detected | fixed | nixpkgs-style | **default** |
| install with placeholders (e.g. `/nix/store/eeee…-x`) then rewrite to final paths | same length problem as the first row unless names are padded | fixable | | no gain over using `$out` directly: Nix knows every output path before the build |

---------------------------------------------------------------------------

## 3. Reference cycles between subpackages

Nix refuses a multi-output derivation whose outputs reference each other in a
cycle (and inter-derivation cycles cannot be expressed at all). RPM allows
cycles (`glibc` Requires `glibc-common`, which Requires `glibc`); only *path
references* matter here, and they are fewer than `Requires`.

* **Detection at build time, before Nix does it**: the partitioner runs Nix's
  own test (does output A contain the hash part of output B?) over all outputs,
  plus the decompressed contents that Nix cannot see (gzip man pages, ELF
  `.gnu_debugdata`, the existing `rpm_purity.py` decoders), builds the graph,
  computes SCCs (Tarjan) and fails with the exact files that create each edge
  and the override to add.
* **Resolution is static** (eval time, per package):

  ```nix
  # packages/glibc.nix
  mergeOutputs = [ [ "glibc" "glibc-common" ] ];   # first = representative
  ```

  The merged subpackages share one output (the representative's name);
  `rocky.rpm."glibc-common"` and `passthru.rpmOutputs."glibc-common"` both point
  to it. Static, so no eval-time dependency on build results; the build-time
  check guarantees the list is sufficient, and reports merges that are no
  longer needed.
* A *dynamic* alternative (move an SCC's files into one output at build time,
  leave forwarding symlink outputs) was rejected: moving files between outputs
  changes their paths, which needs exactly the binary rewriting §2.3 rules out.
* `debug` never takes part (DWARF with `%_usrsrc=/usr/src` names no store path
  of the package; if it does, the scan reports it like any other edge).

For glibc the measured graph ([S3b], [S5]) has **no cycle**: every output
points at `out` (PT_INTERP, `.so` symlinks, ld scripts), `nss_devel` also at
`nss_db`/`nss_hesiod`, langpacks at `common`. glibc needs one merge for a
different reason — **functional merges**: the 32-bit libc (`glibc32`) has
`$out/lib/ld-linux.so.2` compiled in (spec configures both builds with the same
`--prefix`), so it must live in `out`: `mergeOutputs = [ [ "glibc" "glibc32" ] ]`.
The partitioner reports these as "binary reference to `$out/<rel>`, but `<rel>`
moved to output X", the same diagnostic as for layouts (§2.3).

---------------------------------------------------------------------------

## 4. Union directories at runtime

### 4.1 Principle

A compiled-in directory can name one output. Everything that is a *union* in
an FHS root (many packages drop files into one directory) becomes, as in
nixpkgs, one of:

1. **an environment search path set by setup hooks** (build time) and by
   profiles/wrappers (run time) — `PKG_CONFIG_PATH`, `ACLOCAL_PATH`,
   `XDG_DATA_DIRS`, `GI_TYPELIB_PATH`, `PYTHONPATH`/site-packages via
   `.pth`, `PERL5LIB`, `MANPATH`, `INFOPATH`, `GCONV_PATH`, `LOCPATH`,
   `LOCALE_ARCHIVE`, `NIX_PROFILES`-style `XDG_*`;
2. **a `buildEnv` profile** whose union directory is the one place that
   programs are pointed at (NixOS `/run/current-system/sw`, `nix profile`);
3. **plugin directories** (dlopen by directory): the plugin host's output
   gets the compiled-in default, plugins in other outputs are found through the
   host's env var if it has one, otherwise a `wrapProgram` with the variable
   (`makeWrapper`, nixpkgs style), otherwise a per-package `layout`/merge.

Each Rocky output that contributes to a union gets a `nix-support/setup-hook`
generated by the partitioner from the directories it ships and the package's
`runtimeSearchPaths` (e.g. `langpack_de` appends `$langpack_de/lib/locale` to
`LOCPATH`, `gconv_extra` its `lib64/gconv` to `GCONV_PATH`). Build-time unions
use nixpkgs' hooks, extended for `lib64` (nixpkgs' pkg-config hook scans
`lib/pkgconfig` and `share/pkgconfig` only; the Rocky stdenv adds
`lib64/pkgconfig`, `lib64/cmake`); `rocky.lib.mkProfile` = `buildEnv`
+ an `etc/profile.d/rocky.sh` exporting the runtime variables for the union.

### 4.2 glibc specifically

| union | Rocky (FHS) | nixpkgs glibc | this design |
|---|---|---|---|
| libraries / rtld search path | `/etc/ld.so.cache` + `/lib64:/usr/lib64` | cache path patched to `$out/etc/ld.so.cache` (non-existent), system dirs `$out/lib`, everything else via RUNPATH | system dirs `$glibc/lib64` (from the relocated `slibdir`/`libdir`); RUNPATH via bintools-wrapper; **ld.so.cache: patch P1** (§4.3) |
| `/etc/ld.so.conf`, `ldconfig` | maintains the cache | `ldconfig` reads `$out/etc/ld.so.conf` | keep Rocky's `ldconfig`; P1 makes it write/read `$glibc/etc/ld.so.cache` only — i.e. inert on a Nix system |
| NSS modules (`libnss_*.so.2`, dlopen by soname) | system dirs | files/dns in `$out/lib`; others via nscd/nsncd or `LD_LIBRARY_PATH` | `files`, `dns`, `compat` are in `glibc` (= in the rtld system dir, work); `nss_db`, `nss_hesiod`, `libnsl` are separate outputs: found via `LD_LIBRARY_PATH` set by the profile, or a host nscd/nsncd (NixOS) — same as nixpkgs |
| locales: `locale-archive` (`glibc-all-langpacks`), per-locale dirs (`glibc-langpack-*`, `glibc-minimal-langpack`), `C.utf8` (`glibc-common`) | `/usr/lib/locale` | `LOCALE_ARCHIVE`/`LOCALE_ARCHIVE_2_27` patch; C.UTF-8 in `$out/lib/locale` | compiled default `$glibc/lib/locale` (complocaledir); **`LOCPATH`** (upstream glibc, no patch) for langpack dirs — each langpack output's setup hook / the profile appends `$lp/lib/locale`; **patch P2** (`LOCALE_ARCHIVE`, nixpkgs' `nix-locale-archive.patch`) so `glibc-all-langpacks` and NixOS' `i18n.glibcLocales` archives work |
| message catalogs `share/locale/*/LC_MESSAGES/libc.mo` (langpacks, all-langpacks) | `/usr/share/locale` | `$out/share/locale` | compiled default `$glibc/share/locale` (empty: Rocky ships no `libc.mo` in `glibc`); libc has no env override for its own domain → libc's own messages stay untranslated in the split world (accepted; same practical result as nixpkgs). `glibc-common`'s programs (`ldd`, `locale`, …) are shell/ELF with the same limitation |
| `share/i18n` (charmaps, locale sources: `glibc-locale-source`) | compiled into `localedef`/`iconv`/`locale` | `$out/share/i18n` | compiled default `$glibc/share/i18n` (dangling, [S5]); **`I18NPATH`** (upstream) set by the `locale_source` output's setup hook |
| gconv modules (`lib64/gconv`: `glibc` has the common ones, `glibc-gconv-extra` the rest) + `gconv-modules.d/*.conf` | one dir + cache | one dir | default `$glibc/lib64/gconv`; **`GCONV_PATH`** (upstream) set by `gconv_extra`'s setup hook/profile to `$gconv_extra/lib64/gconv` (its `gconv-modules.d/gconv-modules-extra.conf` names modules relative to that dir) |
| `gconv-modules.cache` (`%ghost`, regenerated by `%post iconvconfig`) | `%post` | none | not generated (scriptlets do not run); glibc falls back to parsing `gconv-modules` — measured equivalent behaviour in `checks.glibc-runtime` today |
| `/usr/share/zoneinfo` (tzdata SRPM) | `TZDIR` default | `$out/share/zoneinfo` default, NixOS sets `TZDIR` | default `$glibc/share/zoneinfo` (dangling, reported); profile/NixOS set `TZDIR=$tzdata/share/zoneinfo`; `/etc/localtime` stays FHS (TZDEFAULT = `$(sysconfdir)/localtime` = `/etc/localtime`) |
| `libgcc_s.so.1` (dlopened by libc for `pthread_cancel`/`backtrace`) | `/lib64` (gcc's `libgcc` RPM) | `user-defined-trusted-dirs=${libgcc}/lib` (glibc references the *xgcc-stage* libgcc: measured, `nix-store -q --references glibc-2.42-100` → `xgcc-15.3.0-libgcc`) | same trick: `make user-defined-trusted-dirs=$libgcc/lib64` via the glibc override's env, pointing at the **previous stage's** Rocky `gcc.libgcc` output (§6). [S4] shows what happens without it |
| `/usr/libexec/getconf` | | | in `glibc` (`out`): compiled default correct |
| `/etc/ld.so.preload` | | patched to `/etc/ld-nix.so.preload` | keep Rocky's (optional patch P3, not needed for correctness) |

### 4.3 Justified Nix-side patches to Rocky glibc

Only where the FHS behaviour would make Rocky binaries load *host* files on a
non-Rocky machine, or where an upstream mechanism is missing:

* **P1 — ld.so.cache** (required): `sysdeps/generic/dl-cache.h`
  `LD_SO_CACHE` = `"$prefix/etc/ld.so.cache"`. With `sysconfdir=/etc` the
  relocated ld.so would read the host's cache before its own system dirs: on a
  Debian host `libc.so.6`'s soname resolves to Debian's libc → crash. Applied
  in [S3] as a one-line sed in `%__spec_prep_post` (`grep` in the log shows the
  new define). (Considered: `sysconfdir=$out/etc` for glibc instead — no patch,
  but glibc derives `TZDEFAULT` from sysconfdir, so `/etc/localtime` would be
  ignored; and glibc's `%install` cleanup deletes `$RPM_BUILD_ROOT/etc`.
  Rejected.)
* **P2 — `LOCALE_ARCHIVE`** (wanted): without it `glibc-all-langpacks` (the
  archive) is unusable from another output; `LOCPATH` covers per-locale dirs
  only (glibc ignores the archive when `LOCPATH` is set). Same env names as
  nixpkgs (`LOCALE_ARCHIVE_2_27`, `LOCALE_ARCHIVE`) so mixed nixpkgs/Rocky
  sessions on NixOS share one archive (format unchanged since 2.27).
* **P3 — ld.so.preload, getconf CS_PATH, `NIX_ETC_*` for nss_files** (nixpkgs
  has them): not adopted for the milestone; documented as optional.

They go into `packages/glibc/nix-patches/` and are applied from
`%__spec_prep_post` (never by editing the SRPM's patch list), so the SRPM and
its 675 patches stay untouched and the extra patches are visible in one place.
Parity treats their effects as allowlisted, named differences.

---------------------------------------------------------------------------

## 5. Toolchain and stdenv

### 5.1 cc-wrapper and bintools-wrapper: reused unmodified

[S2] wraps the stage0 gcc 14.3.1 (Rocky sources) and binutils 2.41 with
nixpkgs' `wrapCCWith` / `wrapBintoolsWith` at the pinned nixpkgs, libc = stage0
glibc. Needed adaptations, all as arguments/overrides, no fork:

* `libc.libdir = "/lib64/"`, `libc.incdir = "/include"` passthru (the wrappers
  read `libc.libdir or "/lib"`);
* `nix-support/dynamic-linker` overwritten in `postFixup` (bintools-wrapper
  hard-codes `${libc}/lib/ld-linux-x86-64.so.2`);
* `cc-cflags-before` emptied (nixpkgs adds `-fno-omit-frame-pointer
  -mno-omit-leaf-frame-pointer`; RHEL 10 builds without frame pointers);
* `defaultHardeningFlags = [ ]` / `NIX_HARDENING_ENABLE=""`: the hardening
  comes from redhat-rpm-config's `%optflags`/`%build_ldflags`, exactly Rocky's;
* no `reproducible-builds.sh` hook (it injects `-frandom-seed`): Rocky's flags
  only;
* GNU ld scripts of the wrapped toolchain must name store paths. In [S2] the
  stage0 gcc's `libgcc_s.so` (`GROUP ( /lib64/libgcc_s.so.1 libgcc.a )`) and
  glibc's `libc.so` (`/lib64/libc.so.6 /usr/lib64/libc_nonshared.a`) broke the
  link until rewritten — for Rocky-built (relocated) gcc and glibc they are
  correct by construction (`%_prefix` + §2.3 text rewriting);
* gcc must be a *copy* (or its own relocated build), not a symlink farm: gcc
  resolves its install prefix from its real executable path and would find the
  original tree's `libgcc_s.so` ([S2], first attempt);
* Rocky's split puts `crt*.o`, the `libc.so` ld script and `libc_nonshared.a`
  into `glibc-devel`, while the wrappers take `-B`/`-L` from `getLib libc`:
  the Rocky glibc derivation therefore exposes `passthru.lib = dev` for the
  wrappers (`libc = glibc // { lib = glibc.dev; }` in [S6]) and the
  dynamic-linker file names `out`'s loader. Outputs of dev builds then get
  `$dev/lib64` in RPATH, which `patchelf --shrink-rpath` drops (no `.so.N` there).

Result [S2]: `hello` with `PT_INTERP $libc/usr/lib64/ld-linux-x86-64.so.2`,
`NEEDED libc.so.6`, store-path RPATH, runs; `NIX_DEBUG=1` shows the wrapper
adds only `-dynamic-linker`, `-B$libc/…`, `-idirafter $libc/include`,
`-idirafter <gcc>/include-fixed`, `-B/-L <gcc>/lib{,64}`, the buildInputs'
`-isystem`/`-L`, and drops gcc's `-dynamic-linker /lib64/…` ("skipping impure
path"). The output's references: only the libc and the gcc lib dir (removed by
`patchelf --shrink-rpath` in the real fixupPhase when unused) — the wrapper
scripts, nixpkgs bash/coreutils/expand-response-params never appear in outputs.

Two Rocky-specific changes to nixpkgs defaults:

* Rocky's ld is configured without `--enable-new-dtags` → `-rpath` makes
  `DT_RPATH` ([S2] `readelf`: `RPATH`). The Rocky bintools-wrapper adds
  `--enable-new-dtags` to `ldflags-before` (nixpkgs semantics: `DT_RUNPATH`,
  overridable by `LD_LIBRARY_PATH`, per-object).
* `setup.sh`'s `_addRpathPrefix` adds `-rpath $out/lib` ("self rpath"); the
  Rocky stdenv adds `$out/lib64` instead (preHook overriding the function).
  It is applied *at setup time* — `NIX_NO_SELF_RPATH` must be a derivation
  attribute, not exported later: [S3] failed with "Inconsistency detected by
  ld.so: get-dynamic-info.h: 134: … `info[DT_RPATH] == NULL'" (the freshly
  linked ld.so carried the self-rpath) until `NIX_NO_SELF_RPATH = "1";
  NIX_DONT_SET_RPATH = "1";` were set on the derivation, exactly what nixpkgs'
  glibc does.

Can nixpkgs' wrappers be used and nixpkgs still be absent from output
closures? **Yes.** The wrapper derivations are build-time only. In the final
stdenv they are instantiated with `stdenvNoCC = rocky.stdenvNoCC`,
`runtimeShell = rocky bash`, `coreutils`/`gnugrep` = Rocky's, and
`expand-response-params` compiled by the Rocky stdenv from nixpkgs' C source,
so even the final stdenv's closure is Rocky-only (nixpkgs contributes *source
files*: setup.sh, the wrapper scripts, hooks — data, like the SRPM is data).

### 5.2 stdenv

`rocky.stdenv = import "${nixpkgs}/pkgs/stdenv/generic" { … }` with
`initialPath` = Rocky coreutils, findutils, diffutils, sed, grep, gawk, tar,
gzip, bzip2, xz, zstd, make, bash, patch, file (the BaseOS SRPMs),
`shell = rocky bash`, `cc` as above, `extraNativeBuildInputs` = patchelf (no
Rocky SRPM ships it: built from nixpkgs' source by the previous Rocky stage —
a build tool, never in an output closure), `allowedRequisites` = the Rocky
outputs it consists of (nixpkgs pattern). `mkDerivation` keeps all nixpkgs
features (`outputs`, `strictDeps`, `propagatedBuildInputs`, `passthru`,
`__structuredAttrs`, `outputChecks`).

Setup hooks used: nixpkgs' `multiple-outputs.sh` (output variables,
`propagated-build-inputs`), `patch-shebangs.sh`, `patchelf` shrink-rpath,
`move-docs` off (rpm placed docs), `strip` off (`dontStrip = true`: rpm's
find-debuginfo did Rocky's strip and created debuginfo), `audit-tmpdir` on,
pkg-config/`lib64` hook (Rocky-specific).

### 5.3 rpmbuild in that world

* **rpm itself**: stage0 rpm 4.19.1.1 (FHS-compiled, `/usr/lib/rpm`) in the
  bootstrap; from the first Rocky stage on, Rocky's `rpm` SRPM built *by
  mkRpmPackage* (relocated: its own files in `$rpm/lib/rpm`, its compiled-in
  `RPM_CONFIGDIR` default = `$rpm/lib/rpm`). Inside builds it is always reached
  as `/usr/bin/rpmbuild` with config at `/usr/lib/rpm` through the shim, so
  Rocky's macro files work verbatim.
* **rpm config** = a derivation assembling `/usr/lib/rpm` from rpm's own config
  dir + `redhat-rpm-config` + every `*-srpm-macros`/`*-rpm-macros` output that
  is a (native) build input (their `lib/rpm/macros.d/*`) + `rocky-release`'s
  `macros.dist` + `macros.nix` (§1.1). Macro packages become ordinary
  nativeBuildInputs; a setup hook appends their `lib/rpm/macros.d` to
  `NIX_RPM_MACRO_DIRS`, the shim assembles the union (no rebuild of anything).
  [S3] assembled it once by copying, which is the stage-0 shortcut.
* **tool shim** (`lib/tool-shim.sh`, a ~30-line bwrap wrapper; mechanism from
  `lib/chroot.sh`, verified in the sandbox): new root = tmpfs, bind `/nix`,
  `$NIX_BUILD_TOP`, `/etc` (sandbox's), `/proc`, `/dev`, tmpfs `/tmp`; create
  `/usr/bin` (= `/bin`, `/sbin`, `/usr/sbin`) as symlinks to every executable on
  the derivation's `PATH` (first wins) and `/usr/lib/rpm`. No `/usr/include`,
  no `/usr/lib64`: a spec cannot find a dependency except through the
  cc-wrapper/pkg-config search paths of declared inputs. `PATH` inside stays
  the store `PATH` (nixpkgs-normal) — **except** for packages below the
  interpreters in the bootstrap (glibc, gcc, bash itself), whose `PATH` is
  `/usr/bin:/bin` so configure records FHS interpreter paths (`PERL=/usr/bin/perl`)
  instead of *bootstrap-stage* store paths; those are then bound late (§5.6).
* **brp scripts** run as Rocky runs them (`%__os_install_post`): strip,
  `brp-strip-static-archive`, `brp-compress`, `brp-mangle-shebangs`,
  `brp-python-bytecompile`, `check-rpaths` (store RUNPATHs are
  "non-standard" = accepted), `check-buildroot`. Nix's fixupPhase only adds
  what rpm does not do: shebangs → store, RPATH shrink, setup hooks.
* **debuginfo**: Rocky's find-debuginfo + dwz + gdb-add-index, with
  `%_debuginfo_subpackages` as Rocky; all debuginfo/debugsource RPMs map to one
  `debug` output laid out as nixpkgs' (`$debug/lib/debug/.build-id/xx/….debug`),
  so `NIX_DEBUG_INFO_DIRS` / nixpkgs' gdb wrapper find it. glibc's
  `wrap-find-debuginfo.sh` keeps ld.so's DWARF in `out` as on Rocky.
  DWARF may name header paths of build inputs (kernel headers, gcc's include
  dir) → would put them into runtime closures (ld.so keeps DWARF!). The Rocky
  cc-wrapper therefore adds `-ffile-prefix-map=<input>=/usr` for gcc's own
  prefix and for each `-isystem` input (Rocky-identical DWARF paths, no store
  references); the reference scan enforces it.
* **%check**: `doCheck` maps to *not* passing `--nocheck`; default off for
  the bootstrap (glibc's is hours and needs nested namespaces), on per package.
  Runs inside the shim like `%build`.

### 5.4 What nixpkgs fixup must not do

`dontStrip`, `dontMoveSbin` (Rocky has `sbin`), `dontMoveLib64`
(`_moveLib64` would move `lib64` to `lib`!), `dontPatchELF` *only* for glibc
(ld.so/libc must not be patchelf'ed), `noAuditTmpdir` never.

### 5.5 Build dependency inputs

`buildInputs` / `nativeBuildInputs` of an SRPM = its BuildRequires resolved
against the lock (§8.2), each mapped to the providing output
(`rocky.rpm.<name>`). Tools (`/usr/bin/*`) → nativeBuildInputs, `-devel`
→ buildInputs (cc-wrapper's setup hook adds `-isystem $dev/include`, the
bintools hook `-L$lib/lib64`); macro packages → nativeBuildInputs (rpm config).

### 5.6 Late binding of interpreters for low packages

glibc's scripts (`ldd`, `sotruss`, `xtrace`, `tzselect`: bash; `mtrace`: perl)
cannot reference the final bash/perl, which are built *with* that glibc (an
inter-derivation cycle, not expressible). nixpkgs sets `BASH_SHELL=/bin/sh`
(measured: nixpkgs `glibc-2.42-47-bin/bin/ldd` starts with `#! /bin/sh`).
Here: the raw outputs keep FHS shebangs (`#!/usr/bin/bash`, allowlisted for
these packages only), and `lateShebangs = [ "common" "utils" ]` creates small
derivations `rocky.glibc.common` = copy of the raw `common` output with
`patchShebangs` against the final stdenv's bash/perl (the raw outputs stay
reachable as `rocky.glibc.raw.common`). Nothing inside glibc references these
two outputs' paths (checked by the partitioner's graph), so the copies are
self-consistent.

---------------------------------------------------------------------------

## 6. Bootstrap: from stage0 to a self-hosted Rocky stdenv

nixpkgs-style `stdenvStages` (list of functions prevStage → { stdenv, overrides }),
each stage asserting where its components come from (`isBuiltBy` predicates on
`passthru.rockyStage`):

| stage | stdenv (cc = wrapper(gcc, binutils, libc); tools) | builds (all with mkRpmPackage, relocated, per-subpackage outputs) |
|---|---|---|
| **B0** (exists) | — FHS stage0: gcc/binutils/glibc from Rocky tarballs by nixpkgs' gcc; rpm 4.19.1.1; macro packages; nixpkgs tools | the bootstrap files (like nixpkgs' bootstrap-tools) |
| **R1** | wrapper(stage0 gcc copy, stage0 binutils, **stage0 glibc**); nixpkgs tools in PATH; rpm config from stage0's macro RPM trees; tool shim | `kernel-headers` (relocated tree), **glibc¹**, `redhat-rpm-config` + macro packages (noarch, relocated) — [S3] is R1's glibc |
| **R2** | wrapper(stage0 gcc, stage0 binutils, **glibc¹**) (re-wrap like nixpkgs stage2) | gmp, mpfr, libmpc, zlib-ng, zstd, xz, (isl in gcc.spec), **binutils²**, **gcc²** (multilib, `libgcc`/`libstdc++`/… outputs), annobin² |
| **R3** | wrapper(**gcc²**, **binutils²**, glibc¹ with `user-defined-trusted-dirs = gcc².libgcc`) | **glibc³** (now built by Rocky's gcc), then gcc³, binutils³, gmp³ … against glibc³ |
| **R4** | wrapper(gcc³, binutils³, glibc³) | the stdenv tools from SRPMs: bash, coreutils, findutils, diffutils, sed, grep, gawk, make, patch, tar, gzip, bzip2, xz, zstd, file, cpio, perl, python3.12, rpm (relocated), debugedit, elfutils, dwz, gdb (gdb-add-index), bubblewrap (the shim), patchelf (nixpkgs source) |
| **final** | `rocky.stdenv` = generic stdenv over R4 packages; `allowedRequisites` = those outputs; `disallowedRequisites` = every B0/R1/R2 component | everything else; glibc for users = glibc³ (built by gcc², referencing gcc².libgcc as trusted dir — the nixpkgs pattern) |

Rules (as in nixpkgs' `pkgs/stdenv/linux/default.nix`):

* a stage only uses packages of the immediately previous stage, re-exporting
  what it keeps; each transition asserts `isBuiltByRockyCompiler` /
  `isFromBootstrapFiles` for gcc, binutils, glibc, coreutils, grep, patchelf;
* **fixpoint criterion**: rebuilding glibc and gcc with the final stdenv gives
  the same bytes in every loaded ELF section as their final-stage versions
  (glibc⁴ ≡ glibc³ modulo the store-path strings, compared with the existing
  rpm-parity loaded-section comparison after normalising store paths) — then
  the chain has converged, as `gcc`'s 3-stage bootstrap compare does;
* nothing from B0 or nixpkgs may be a requisite of any final output
  (`disallowedRequisites` on the final stdenv; enforced on every package by §7);
* glibc is rebuilt by the final toolchain in R3 (glibc³). If the fixpoint
  check fails, one more round (glibc built by gcc³) is added.

Cost: one glibc ≈ 10 min, one gcc (multilib, no profiledbootstrap) ≈ 15–30 min
on 16 CPUs; R1–R4 ≈ 60–120 builds, most small.

---------------------------------------------------------------------------

## 7. Enforcement and verification

1. **Nix-enforced closure rule** on every mkRpmPackage output
   (`__structuredAttrs` + `outputChecks.<o>.allowedRequisites`): own outputs ∪
   all outputs of the transitive *runtime* inputs (buildInputs,
   propagatedBuildInputs, late-binding targets), computed at eval time from
   `passthru`. Nix fails the build if an output's closure contains anything
   else — B0, nixpkgs, build-only tools (gcc, perl as a build tool) included.
   This is the store-native version of today's "no /nix/store in an RPM".
2. **Byte-level scan** (the existing `tools/rpm_purity.py` decoders, applied to
   output trees): every `/nix/store/<hash>` string, also inside gzip/xz/zstd/
   bzip2 members, ELF `.gnu_debugdata` and compressed sections, must belong to
   an allowed output — Nix's own scanner misses compressed references
   (e.g. a path in a gzip'ed man page or minidebuginfo).
3. **FHS scan** (§1.4): FHS absolute paths outside the runtime allowlist fail
   unless allowlisted per package with a reason.
4. **Parity adapted to relocation** (reuse `tools/rpm-parity.py`'s comparators,
   new front end over output trees + `nix-support/rpm-files`):
   * per subpackage: file set by relative path (`$out/lib64/x` ↔
     `/usr/lib64/x`, `$out/etc/x` ↔ `/etc/x`), modes, symlink targets
     (normalised `$X/rel` ↔ `/usr/rel`), `%config/%ghost/%doc` flags,
     Requires/Provides from the transient RPM headers vs official;
   * content: identical bytes for files without the prefix (locales, headers,
     `.mo`, info pages, most data); files that embed the prefix compared after
     replacing each output path by its FHS equivalent (text: must then be equal;
     ELF: dynamic symbols + versions, SONAME, NEEDED, GNU properties,
     section list, and loaded-section bytes after store-path normalisation —
     sections whose layout shifts because strings got longer are compared by
     displacement-normalised disassembly, the method already used for
     memusagestat);
   * `tools/abi-compare.py` unchanged except a path map — glibc's ABI
     (709 DSOs, 3541 archive members, 480 headers) must still be identical.
5. **Behaviour** (`checks.glibc-runtime` adapted): run the store binaries
   directly (no chroot): ld.so `--list-diagnostics`/`--help`, programs compiled
   by the Rocky stdenv against `glibc.dev`, locales via `LOCPATH`/
   `LOCALE_ARCHIVE`, iconv via `GCONV_PATH`, NSS, 32-bit (`glibc32` output via
   `-m32` multilib wrapper); compare the report with the official RPMs' root
   (existing chroot runner) after normalising paths. [S4] is the seed of it.
6. **Reproducibility**: `nix build --rebuild` per output (the logs move to a
   separate `logs` output again; ar member dates as documented today);
   transient RPMs are not outputs.

---------------------------------------------------------------------------

## 8. Scaling to ~2200 SRPMs

### 8.1 Per-package overrides (`packages/<srpm>.nix`, only when needed)

```nix
{ rocky, ... }: {
  specSubstitutions = [ [ "--with-headers=%{_prefix}/include" "--with-headers=%{rocky_kernel_headers}/include" ] ];
  configSite = ./glibc.site;               # extra CONFIG_SITE fragment
  env = { };                               # extra environment for rpmbuild
  defines = { _annotated_build = "0"; };   # extra rpm macros
  nixPatches = [ ./nix-patches/ld-so-cache.patch ./nix-patches/locale-archive.patch ];
  unshippedSubpackages = [ "glibc32" "sysroot-x86_64-el10-glibc" "compat-libpthread-nonshared" ];
  mergeOutputs = [ [ "glibc" "glibc32" ] ];  # §3: 32-bit loader path is $out/lib/ld-linux.so.2
  runtimeSearchPaths = { "lib/locale/locale-archive" = "LOCALE_ARCHIVE"; "lib/locale" = "LOCPATH";
                         "share/i18n" = "I18NPATH"; "lib64/gconv" = "GCONV_PATH"; };
  layout = { };                            # §2.3: macro -> output
  lateShebangs = [ "common" "utils" ];     # §5.6
  fhsAllowlist = { "#!/usr/bin/bash" = "late-bound"; };
  extraBuildInputs = [ ]; doCheck = false;
  dontPatchELF = true;
  stage = "R1";                            # bootstrap placement for low packages
}
```

Default: no file. A package without overrides is `mkRpmPackage { srpm =
"<name>"; }` generated from the lock.

### 8.2 BuildRequires → inputs (static, no IFD)

The lock generator already resolves BuildRequires mock-style
(`resolve-buildrequires.py`, 260/260 vs dnf5). Extend `update-lock` to emit
`lock/rocky-10.2/builddeps.json`: per SRPM the resolved *direct* binary
packages (provides resolution incl. file and rich deps, `install_weak_deps=0`),
each tagged tool/library/macro from its file list (`/usr/bin` → native,
`/usr/include` or `.so` → host, `/usr/lib/rpm/macros.d` → macro). Nix reads it
with `fromJSON` and maps names via `rpmsLock.rpms.<n>.srpm` + the output-name
rule to `rocky.<srpm>.<output>`. Runtime `Requires` of `-devel` subpackages
become `propagatedBuildInputs` of the `dev` output (glibc-devel → kernel-headers
dev; libxcrypt-devel), so headers that include other packages' headers work.

### 8.3 Build-order cycles

SRPM build graph SCCs are computed by the lock generator. Inside the stdenv
bootstrap they are broken by stages (§6). Elsewhere (python ↔ python-setuptools,
gcc ↔ annobin, systemd ↔ util-linux, perl modules) the standard Fedora answer
is used: build once with the previous stage's provider or with the spec's
`%bcond bootstrap`, recorded as `stage`/`defines` in the override; the lock
generator lists every SCC that still lacks such an annotation.

### 8.4 Evaluation and CI

All derivations are plain; `hydraJobs` = `rocky.<srpm>` for every lock SRPM
(each with its outputs) + checks; `tools/build-jobs.sh` unchanged
(nix-eval-jobs, `--check-cache-status`, IFD off). ~2200 derivations with ~7000
outputs: evaluation stays cheap because outputs are a static list per SRPM and
the lock is parsed once.

---------------------------------------------------------------------------

## 9. Implementation plan for the glibc milestone

Ordered; each step is a commit with a check.

1. **`lib/rpm-config.nix`** — assemble `/usr/lib/rpm` from stage0 `rpm` + the
   stage0 macro RPM trees (`stage0.rpms.*`) + `macros.nix`. (Reuse
   `bootstrap/default.nix` `fullRpms` list.) Check: `rpm --eval` of every macro
   in §1.1 inside the shim.
2. **`lib/tool-shim.sh`** + **`lib/config.site`** — the namespace wrapper
   (from [S3]) and the generic site file. Check: a test derivation runs
   `/bin/true`, `/usr/bin/rpmbuild --version`, and asserts `/usr/include` and
   `/usr/lib64` do not exist.
3. **`bootstrap/stdenv-r1.nix`** — the R1 stdenv: nixpkgs generic stdenv,
   `wrapCCWith`/`wrapBintoolsWith` around a *copied* stage0 gcc and binutils
   (ld scripts rewritten), libc = stage0 glibc (`libdir`/`incdir` passthru,
   `dynamic-linker` override, no frame-pointer/hardening/random-seed flags,
   `--enable-new-dtags`, `lib64` self-rpath hook). Reuse [S2]
   (`spikes/ccwrap.nix`). Check: the stage0 `tests/toolchain.sh` assertions
   rewritten for store paths (C, C++, `-m32`, `-static`, `-flto`, PT_INTERP,
   RUNPATH, no B0 path in DWARF with `-ffile-prefix-map`).
4. **`tools/rocky-partition.py`** — partition, metadata, text/symlink
   rewriting, ELF cross-output detection, reference graph + SCC check, FHS scan
   (reusing `analyze.py` from [S3b] and the decoders of `rpm_purity.py`).
   Unit tests on small synthetic trees (like `parity-selftest-*`).
5. **`lib/mk-rpm-package.nix`** — `mkRpmPackage { srpm, overrides }`: outputs
   from `rpmsLock.bySrpm` + overrides, naming rule, the phases of §0, the
   `outputChecks`. Replaces `buildSrpm` for relocated builds; `buildSrpm` and
   the chroot remain for B0 and for the RPM-parity reference builds.
6. **`packages/glibc.nix` (relocated)** — overrides of §8.1: spec substitution
   for kernel headers, `glibc.site`, P1 + P2 as `nixPatches`, `NIX_NO_SELF_RPATH`,
   `NIX_DONT_SET_RPATH`, `dontPatchELF`, `unshippedSubpackages`,
   `mergeOutputs = [ [ "glibc" "glibc32" ] ]` and `runtimeSearchPaths` (from
   [S3b]/[S5]: no cycles otherwise), `lateShebangs`, the `-ffile-prefix-map`
   wrapper rule (needed: [S3]'s ld.so DWARF named three foreign store paths), `user-defined-trusted-dirs` (R1: the
   stage0 gcc copy's lib64 — allowed only in R1), kernel-headers relocated
   (`packages/kernel-headers.nix` → `$out/include`, from the existing
   headers-only kernel build). Check: build succeeds, no cycles, closure rule.
7. **`checks.glibc-relocated-parity`** — new front end to rpm-parity over
   output trees (relative paths, normalised store paths), `abi-compare` with a
   path map (must stay "0 unexpected, no allowlist"), and
   **`checks.glibc-relocated-runtime`** — [S4] grown into the existing report
   (store binaries run directly vs official RPM root; locales via
   LOCPATH/LOCALE_ARCHIVE; iconv via GCONV_PATH; 32-bit).
8. **R2/R3** — gcc, binutils, gmp/mpfr/libmpc/zlib-ng/zstd/xz as mkRpmPackage
   in R2; glibc³ in R3; fixpoint comparison glibc³ vs glibc built by the R4
   stdenv. Milestone done when glibc³'s closure is `{glibc³ outputs,
   gcc².libgcc}` and the checks of step 7 pass for glibc³.
9. Then the R4 tool set and `rocky.stdenv`; then walk BaseOS with
   `builddeps.json`.

### Risks

| risk | mitigation |
|---|---|
| ELF cross-output references in many packages (data dirs in `-common`, helpers in `-libexec`) | measured per package by the partitioner; `layout` overrides suggested from official filelists; merges as last resort |
| `NIX_*` wrapper behaviour surprising specs (glibc needed `NIX_NO_SELF_RPATH` as an attribute) | wrapper flags are visible with `NIX_DEBUG=1`; R1 toolchain test; keep nixpkgs' glibc settings as the reference |
| DWARF/`__FILE__` naming input store paths → closure bloat or B0 leaks | `-ffile-prefix-map` in the Rocky cc-wrapper + allowedRequisites |
| specs depending on FHS layout in ways the `usr` symlink does not cover (`rm -rf $RPM_BUILD_ROOT/usr`, `find $RPM_BUILD_ROOT -type d` expecting real dirs) | build fails loudly; per-package substitution |
| rpm scriptlets (`%post`, file triggers) do not run | they only maintain caches (ld.so.cache, gconv cache, info dir, systemd reload); Nix has search paths/profiles instead; listed in metadata for NixOS modules |
| non-root owners/modes (`%attr(0700,root,root)`) | recorded in `nix-support/rpm-files`; the store cannot represent them (as today's layers) |
| glibc ↔ libgcc and interpreter cycles | trusted-dir to previous-stage `libgcc` (nixpkgs precedent), late shebang binding |
| `-m32` with the wrapper (glibc32, `gcc -m32`) | nixpkgs `dynamic-linker-m32` + `-B$libc/lib64/` resolving `../lib` for `-m32` worked for glibc's i686 build in [S3]; a `wrapCCMulti`-like 32-bit libc output (`glibc32`) for consumers |

---------------------------------------------------------------------------

## R. Spike results

All under `scratchpad/nn-design-nixpkgs-faithful/spikes/`, run on the local
Determinate Nix 2.36 daemon (16 CPUs), nixpkgs pinned `26f4107`.

**[S0] `manyout.nix`** — a derivation with 230 outputs, dashed output names
(`glibc-devel`, `compat-libpthread-nonshared`, …): builds in 4 s, store names
`…-glibc-2.39-142.el10_2-<output>`, cross-output reference registered. Dashed
names are only reachable via `printenv` (not `$name`) → nixpkgs' `setup.sh`
needs identifier-safe names → the `_` rule of §2.2.

**[S1] `macros.nix`** — `rpm --eval` in the existing stage0 glibc buildroot:
the table of §1.1 (which macros follow `%_prefix`, which are literal, `__perl`
following `%_bindir`), redhat-rpm-config's literal `/usr/lib/rpm/…`, and
`rpmspec -P glibc.spec` with `%_prefix=/nix/store/…`: 226 package names,
1378 lines mentioning `/usr|/lib64|/bin` (almost all `%autosetup`'s
`/usr/bin/patch`), the real hard-coded ones being `$RPM_BUILD_ROOT/usr/…` in
`%install`, `/bin/true`, `rpm -ql kernel-headers`, the sysroot prefix.

**[S2] `ccwrap.nix`** — unmodified nixpkgs `wrapCCWith`/`wrapBintoolsWith`
around a *copy* of the stage0 gcc 14.3.1 and binutils 2.41 (Rocky sources),
libc = stage0 glibc (FHS-in-store, `libdir`/`incdir` passthru,
`dynamic-linker` override, empty `cc-cflags-before`). `hello.c` (with
`<linux/version.h>`) compiles, links, runs; `NIX_DEBUG=1` flag list as in §5.1;
`RPATH` (not `RUNPATH`: Rocky ld has no new-dtags). Failures on the way, each a
design input: symlinked gcc tree → gcc used the original prefix's
`libgcc_s.so` ld script (`/lib64/libgcc_s.so.1`); FHS ld scripts in
`libc.so`/`libgcc_s.so` must be store paths.

**[S3] `glibc-reloc.nix`** — **the Rocky glibc SRPM built by rpmbuild outside
the FHS chroot, relocated** (`%_prefix=$out`), through the [S2] wrappers, tools
from the store PATH, the tool shim (bwrap: `/usr/bin`,`/bin`,`/sbin` symlink
farm + `/usr/lib/rpm`), `config.site` + `glibc.site`, the P1 sed in
`%__spec_prep_post`, `BUILDROOT/usr → prefix` in `%__spec_install_pre`, a
`/usr`-aware `%__check_files`, `--with-headers` spec substitution,
`NIX_NO_SELF_RPATH`/`NIX_DONT_SET_RPATH` on the derivation. Result:
`/nix/store/nncpaslng931rr3ipkb4zsh3a4vabvdq-glibc-2.39-142.el10_2` (700 MB:
prefix tree incl. debuginfo, `nix-support/rpm-files/*` of all **233** RPMs, the
build log). `%prep` (675 patches), both builds (i686 + x86_64, `-Werror`),
497 locales, locale-archive, benchtests, find-debuginfo/dwz, `%files` of every
subpackage: all pass. Configure: `libgd yes` (x86_64; `no` for i686, as on
Rocky), kernel headers ok, systemtap ok. Iterations that failed, in order, and
what they taught:
1. bwrap `--dev-bind / / --tmpfs /usr`: sandbox root is read-only → shim builds
   its own root (tmpfs + binds).
2. absolute `BUILDROOT/usr → /nix/store/…` link: dangling inside BUILDROOT;
   `mkdir -p $RPM_BUILD_ROOT/usr/bin` failed → relative link.
3. `libc_cv_slibdir` exported globally → the i686 build installed into `lib64`,
   spec's `rm usr/lib/libc_malloc_debug.so` failed → host-aware `config.site`.
4. ld.so got `DT_RPATH` from setup.sh's self-rpath ("Inconsistency detected by
   ld.so: get-dynamic-info.h: 134 … info[DT_RPATH] == NULL") →
   `NIX_NO_SELF_RPATH` must be a derivation attribute.
5. deps tree with a *symlinked* `lib64`: bintools setup hook only adds
   `-L$dep/lib64` for a real directory → `libgd no` → `memusage` missing →
   `%install` sed failed → outputs must have real `lib64` dirs (also never let
   nixpkgs' `_moveLib64` run).
6. sysroot package's literal `/usr/x86_64-redhat-linux/…` `%files` → rpm's
   `check-files` saw the real `$prefix/…` paths as unpackaged → `check-files`
   wrapper that folds `/usr` (generic).
Store references of the result (`nix-store -q --references`): itself +
`rpm-kernel-headers`, `glibc-build-deps-hoisted`, `rocky-stage0-gcc-shim` —
all from **DWARF in ld.so** (which glibc keeps) and in the debug files
(`…/include/linux`, `…/include/sys` (sdt.h), gcc's `include`) → the
`-ffile-prefix-map` rule of §5.3. No nixpkgs bash/perl path in any output
although configure recorded them (`checking for bash… /nix/store/…bash-5.3p9`):
`ldd`, `tzselect`, `sotruss` got `#!/usr/bin/bash` (brp-mangle-shebangs),
`mtrace` `#!/usr/bin/sh` + `exec perl` → late binding (§5.6).

**[S3b] `analyze.py`** over [S3]: per-file references to `$prefix/<rel>`
mapped to the owning subpackage. **No reference cycle between subpackages**
(the RPM `Requires` cycle glibc ↔ glibc-common is not a path cycle). ELF
references into other subpackages: `libc.so.6`, `ldconfig`, `locale`,
`localedef` → `lib/locale/locale-archive` (all-langpacks), `iconv`/`locale`/
`localedef` → `share/i18n/…` (locale-source), 32-bit `libc.so.6` → its own
`lib/ld-linux.so.2` (glibc32); text: `ldd` → `lib/ld-linux.so.2` (glibc32),
`libc.so` → `libc_nonshared.a` (devel); 228 relative symlinks crossing
subpackages (langpack `LC_CTYPE` → `glibc-common`'s `C.utf8`, devel `.so` →
main `.so.N`). Union directories referenced: `lib/locale` (208 providers),
`share/locale` (38), `lib64/gconv` (2), `lib64` (10).

**[S4] `runtime.nix`** — the [S3] glibc (single prefix) as the cc-wrapper libc:
`ld.so --list-diagnostics`: `path.prefix=$G`, `path.sysconfdir="/etc"`,
`system_dirs[0]=$G/lib64/`; `--help`: cache `$G/etc/ld.so.cache` (P1 works);
a test program runs; `LANG=C.UTF-8` and `de_DE.UTF-8` work (all in one
prefix); `getconf GNU_LIBC_VERSION` = `glibc 2.39`; `iconv -l` 1180 charsets;
`locale -a` 885; libc strings: `/etc/localtime`, `$G/lib64/gconv`,
`$G/lib/locale`, `$G/share/locale`, `$G/share/zoneinfo`.
**`pthread_cancel` aborts** ("libgcc_s.so.1 must be installed for
pthread_cancel to work") and works with `LD_LIBRARY_PATH=<gcc lib64>` → the
`user-defined-trusted-dirs` rule of §4.2. `ldd` fails in the sandbox: `/usr/bin/bash:
bad interpreter`.

**[S5] `split.nix` + `partition.py`** — the per-subpackage split, as the
in-build partition step would do it (the [S3] prefix hash is first rewritten
to the new `$out`, same length): **223 outputs** (224 subpackages = 221 shipped + 3 unshipped, glibc32 merged) (`out`, `dev`, `common`,
`static`, `utils`, `gconv_extra`, `all_langpacks`, `minimal_langpack`,
`langpack_*` ×~200, `nss_db`, `libnsl`, …), Nix accepts them (**no cycle**).
8286 files, 398 hard links kept, 235 cross-output symlinks retargeted, 737
relativised; text rewrites: `dev/lib64/libc.so` (→ `$dev/lib64/libc_nonshared.a`),
sysroot ld scripts. Output graph: everything → `out`; `nss_devel` → `nss_db`,
`nss_hesiod`; langpacks → `common` (C.utf8); `sysroot` → `dev`, `static`.
Sizes/references: `out` 18 MB, `dev` 3.4 MB (→ out), `common` 1.2 MB (→ out),
`gconv_extra` 9 MB (none), `langpack_de` 20 MB (none), `all_langpacks` 224 MB
(none), `static` 11 MB (→ out). First run without merges flagged the 32-bit
problem (32-bit `libc.so.6`/`ld-linux.so.2` name `$out/lib/ld-linux.so.2`, which
moved to `glibc32`): **`mergeOutputs = [ [ "glibc" "glibc32" ] ]`** is the
functional (not cycle) merge glibc needs. Also found: relative build-id links
that rpm wrote *through* the prefix (`../../../../nix/store/<P>/lib64/gconv/IBM1132.so`)
must be re-resolved per output; and `sbin/ldconfig` holds a **truncated** copy
of the prefix (`/nix/store/…-glibc-2.39-142.el10_` in a fixed-size field) — a
full-path byte rewrite misses it, Nix's hash scanner does not → the partitioner
scans by hash and never rewrites binaries.

**[S6] `runtime-split.nix`** — the split outputs used like nixpkgs packages:
cc-wrapper `libc = glibc // { lib = glibc.dev; }` (Rocky ships `crt*.o`,
`libc.so`, `libc_nonshared.a` in `-devel`, so the wrappers' `-B`/`-L` must
point at `dev`; the dynamic linker is in `out`). `dev/lib64/libc.so` =
`GROUP ( $out/lib64/libc.so.6 $dev/lib64/libc_nonshared.a AS_NEEDED ( $out/lib64/ld-linux-x86-64.so.2 ) )`.
Program compiled against `dev`, runs with `PT_INTERP $out/lib64/ld-linux-x86-64.so.2`.
Union directories behave exactly as §4.2 predicts:

| run | result |
|---|---|
| default | C locale; `ISO-8859-15` ok (in `out`); `IBM1364` FAIL (in `gconv_extra`) |
| `LANG=C.UTF-8` | `setlocale` NULL (C.utf8 is `common`'s) |
| `LANG=C.UTF-8 LOCPATH=$common/lib/locale` | ok |
| `LANG=de_DE.UTF-8 LOCPATH=$langpack_de/lib/locale` | ok (`locale -k LC_TIME`: Sonntag…) |
| `LANG=de_DE.UTF-8` (archive in `all_langpacks`, no P2) | NULL → P2 needed |
| `GCONV_PATH=$gconv_extra/lib64/gconv` | `IBM1364` ok |
| `pthread_cancel` | abort (libgcc_s) |
| `common`'s `ldd`/`getconf`/`iconv -l` | work (`iconv -l` 90 without gconv_extra vs 1180) |

The program's references: `out`, `dev` (RPATH entry, removed by
`patchelf --shrink-rpath` in the real fixupPhase), the R1 gcc (same).
