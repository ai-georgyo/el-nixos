# Rocky specs as Nix recipes: generic relocation and %files-driven outputs

Designer: **spec-generic**. Angle: run **unmodified** Rocky specs, generically,
for ~2200 SRPMs, with as few per-package overrides as possible.

All prototypes and their outputs live in
`/tmp/claude-60514/-run-host-home-ai-shammas-Code-el-nixos/dadc2aad-80ad-416a-b238-b2a3e0de53b8/scratchpad/nn-design-spec-generic/`:
`spikes/` holds `reloc.macros`, `config.site`, `glibc.config.site`, `check-files`, `realias`,
`reloc-spike.nix` (rpmbuild in the stage0 chroot, control vs relocated),
`analyze.py`, `split.py` + `split.nix` (the linker prototype), `test.nix`
(runtime test), `piece-test.*`, `macro-audit.*`, plus the saved reports
`spike-table.txt`, `glibc-analysis.txt`, `glibc-split-report.json` and
`runtime-report.txt`. Next to `spikes/` are `spec-scan.py` with `spec-scan.txt`/`.json`
(static scan of 2185 Rocky 10 specs) and `req-graph.py` (Requires-graph SCCs from the lock).
The repo was not modified.

## Summary

* **The recipe engine is unchanged.** Real `rpmbuild --rebuild` runs in the existing
  bwrap/overlayfs chroot. One macro file, a `CONFIG_SITE`, and two path aliases relocate
  `%_prefix` to a placeholder store path **P**. Nothing in the spec is edited.
  * Aliases: P → the buildroot's `/usr` inside the chroot, and `%buildroot/usr` → `%buildroot/P`.
  * The transient RPMs rpmbuild writes *are* the `%files` partition. A generic **linker**
    turns them into one Nix output per subpackage. It rewrites P to the owning output's
    store path padded with `/`, so the rewrite is length-preserving. It also fixes symlinks
    that cross outputs and sets ELF interpreter/RUNPATH from `DT_NEEDED`.
* **Hard references are gated by rpm `Requires`.** A reference becomes a hard edge only if
  the referencing subpackage Requires something that *only* the owner provides. Directories
  that several subpackages fill (locales, gconv, terminfo) are unions: they compose at
  runtime through upstream variables and profiles. A union directory's primary provider
  gets a weak edge, kept only while it stays acyclic. With these rules glibc has no
  reference cycle, and its main output's closure is itself.
* **Spike results:**
  * **24 real Rocky SRPMs** built with stock macros and relocated in the stage0 chroot.
    Relocation broke none of the 20 that build in stage0. The other 4 fail the same way
    without relocation: stage0 tool gaps, not relocation problems.
  * **glibc relocated:** all 233 RPMs build with **one 4-line per-package `config.site`**.
    It split into **224 outputs**. All 221 shipped subpackages have relative file lists
    identical to the official RPMs. The dynamic symbols and versions of libc/libm/ld.so/libresolv
    are identical too.
  * **Running from the store:** relocated glibc, which, xz, gzip, sed, m4 and diffutils run
    straight from `/nix/store` in a sandbox that has no `/usr` and no `/lib64`. A program
    compiled against `glibc-devel` runs with en_US via `LOCPATH`. Every closure contains
    only Rocky-built outputs.
* **Problems the spikes found, all solved generically:**
  * raw `configure` defaulting to `lib`, `$prefix/etc` → `CONFIG_SITE`;
  * specs that `rm -rf %buildroot` (6.3 %) → `realias`;
  * relative symlinks that cross subpackages → resolved in P-space;
  * built-but-unpublished subpackages (8 of 20 SRPMs) → `rpmspec -q` lockfile;
  * virtual provides (`glibc-langpack`) → only unique providers count;
  * union directories → union rule;
  * **gcc "store by pieces"**: `-march=x86-64-v3` splits compiled-in path literals into
    vector chunks → overlapped-tail and fragment handling, a distinctive P marker, and a
    fragment post-check.
* **Bootstrap:** stage 1 builds the core set relocated in today's stage0 chroot. Stage 2
  rebuilds everything in a chroot made **only** of stage-1 outputs, where nixpkgs is not
  visible. Stage 3 checks the fixpoint after normalizing hashes.

---

## 0. The idea in one page

The whole design rests on one observation. **rpm macros conflate two prefixes that are
both `/usr` on Rocky:**
* the prefix a package *installs into and compiles into itself* (`%_prefix`, `%_libdir`, ...);
* the prefix where the *build environment* lives (`%__python3`, `%{_bindir}/perl`,
  `--with-openssl=%{_prefix}`, `-I%{_includedir}/ncursesw`, `/usr/lib/rpm/...`).

Relocation must split the two without touching the spec. Four generic mechanisms and a
generic post-processor (the linker) do it:

1. **Placeholder prefix P.** `%_prefix`, and the handful of `/usr` macros that do not derive
   from it, are set to a placeholder store path `P = /nix/store/<H0>-<srpm>-<evr>-<pad>`.
   P is at least as long as every final output path of that SRPM. Everything the package
   compiles into itself names P.
2. **P is an alias of the buildroot's `/usr` inside the chroot.** `/nix/store` in the chroot
   is a tmpfs holding the input closure plus `P → /usr`. Every macro that is *really* about
   the build environment then still works as in mock (`%{_bindir}/python3`,
   `--with-foo=%{_prefix}`, `%__perl`). Every reference the build records through P can be
   resolved later.
3. **`%buildroot/usr` is a symlink to `%buildroot/P`.** Our `%__spec_install_pre` creates it,
   and `%__spec_install_post` re-establishes it when a spec `rm -rf`s its buildroot.
   Hard-coded `/usr` in `%install` and `%files` then lands in the relocated tree, as do the
   brp scripts, `find-debuginfo` and rpm's build-id links.
4. **`CONFIG_SITE`.** Raw `./configure` calls get the defaults distros give `/usr`
   (`libdir=$prefix/lib64`, `sysconfdir=/etc`, ...), only when `prefix = P`.
5. **The linker** splits the transient RPMs into Nix outputs. It rewrites P to the owner's
   path plus `/` padding (length-preserving, like Nix's own hash rewriting, but with no need
   for equal-length names). It resolves cross-output symlinks, sets the ELF interpreter and
   RUNPATH, and resolves shebangs and FHS text references against the package's inputs.

## 1. Macro relocation

### 1.1 Evidence: what follows `%_prefix` in Rocky's macro set

Spike `spikes/macro-audit.*` evaluated all 652 macros of the stage0-full
buildroot (rpm 4.19.1.1 + redhat-rpm-config 295 + all `*-srpm-macros`) with the
stock value and with only `%_prefix` changed:

* **46 macros follow `%_prefix`**: `_exec_prefix _bindir _sbindir _libdir
  _libexecdir _datadir _datarootdir _includedir _infodir _mandir
  _defaultdocdir _defaultlicensedir _metainfodir _iconsdir _fmoddir
  _swidtagdir bash_completions_dir fish_completions_dir zsh_completions_dir
  python_wheel_dir ocamldir _monodir`, the file-attr regexes
  (`__pkgconfig_path __desktop_path __metainfo_path __docdir_path`, which is
  right: they classify *packaged* paths), **and two build tools that must not
  move: `%__perl` (`%{_bindir}/perl`) and `%__plugindir`/`%__transaction_*`
  (rpm plugins)**.
* **161 `/usr` values do not follow it.** Almost all are build tools and must
  not move (`%__python3 /usr/bin/python3`, `%__make`, `%__cc`, every brp
  script, `-specs=/usr/lib/rpm/redhat/redhat-hardened-cc1`, `%_rpmconfigdir`,
  `%_dbpath`, `%_fileattrsdir`, `%__find_debuginfo`, ...). The few that are
  *install destinations* and must move: `%_usr %_usrsrc %_oldincludedir
  %_rpmmacrodir %rpmmacrodir %_rpmluadir %_sysusersdir %_fontbasedir
  %_fontconfig_templatedir %gopath`. (`%_unitdir`, `%_tmpfilesdir`,
  `%_userunitdir`, `%_presetdir` come from systemd-rpm-macros, which is not in the
  stage0 buildroot; they are expected to derive from `%{_prefix}` — to be
  re-audited with the same spike once it is installed.)
* `%python3_sitelib/sitearch` are computed by python sysconfig with
  `base=%{_prefix}` → follow. `%perl_vendorlib` etc. come from the *installed*
  perl's `Config` (expected `/usr/share/perl5/vendor_perl`; unverified in stage0,
  whose perl is nixpkgs') → do **not** follow, but the
  `%buildroot/usr` alias catches the install, and the `/usr/...` FHS reference
  in packaged files is resolved by the linker (§2.6).

### 1.2 The macro file (`/usr/lib/rpm/macros.d/macros.zz-el-nixos-reloc`)

```
%_prefix                %{_el_nixos_prefix}        # P, passed per SRPM
%_exec_prefix           %{_prefix}
%_usr                   %{_prefix}
%_usrsrc                %{_prefix}/src
%_oldincludedir         %{_prefix}/include
%_rpmmacrodir           %{_prefix}/lib/rpm/macros.d
%rpmmacrodir            %{_rpmmacrodir}
%_rpmluadir             %{_prefix}/lib/rpm/lua
%_sysusersdir           %{_prefix}/lib/sysusers.d
%_fontbasedir           %{_datadir}/fonts
%_fontconfig_templatedir %{_datadir}/fontconfig/conf.avail
%gopath                 %{_datadir}/gocode
# machine-local state: FHS at runtime
%_sysconfdir /etc
%_localstatedir /var
%_sharedstatedir /var/lib
%_rundir /run
# build tools stay where the build environment has them
%__perl /usr/bin/perl
%__plugindir /usr/lib64/rpm-plugins
# %buildroot/usr -> P alias, re-established after %install; check-files aware of it
%__spec_install_pre  ... mkdir -p $RPM_BUILD_ROOT/P; ln -s P $RPM_BUILD_ROOT/usr ...
%__spec_install_post /etc/el-nixos/realias "$RPM_BUILD_ROOT" "%{_prefix}" + stock body
%__check_files /etc/el-nixos/check-files %{buildroot} %{_prefix}
```

(Full text: `spikes/reloc.macros`.) What is *not* overridden matters as much:
`%_bindir` etc. are left to derive from `%_prefix` (so 3rd-party macro packages
that derive from them keep working); `%_lib` stays `lib64` (so relative paths
equal Rocky's: `/usr/lib64/libc.so.6` ↔ `$out/lib64/libc.so.6`, which keeps
specs, `%files`, parity and multilib (`lib` for `-m32`) unchanged — nixpkgs'
`lib` convention is not adopted); `%_rpmconfigdir` stays `/usr/lib/rpm` (it
names the *tool* directory; a package that installs into it — rpm,
redhat-rpm-config, the macro packages — goes through the `%buildroot/usr`
alias into P).

`%_build_id_links` stays `compat`, so rpm's own Provides and file lists stay
Rocky's. The linker drops `lib/.build-id` from non-debug outputs: those links only
serve rpm's debuginfo lookup, and nixpkgs uses `$debug/lib/debug/.build-id`.

### 1.3 Runtime FHS: what stays FHS

* `/etc`, `/var`, `/run` stay FHS **at runtime** (`%_sysconfdir /etc` is
  compiled in). Files a package installs there (config defaults,
  `%config(noreplace)`, `%ghost`, tmpfiles/sysusers drop-ins live under P and
  relocate) are put into the output at `$out/etc/...`, `$out/var/...` (the
  nixpkgs convention) and listed in `$out/nix-support/rocky-rpm.json`
  (`fhs: [{path, store, flags, mode, user, group}]`) so an image/module builder
  can install them (like NixOS `environment.etc`). Owners/modes the store
  cannot represent are only metadata there.
* `/bin/sh` (glibc's `system()`/`popen()`), `/dev`, `/proc`, `/sys`,
  `/etc/nsswitch.conf`, `/etc/resolv.conf`, `/etc/hosts`, `/etc/localtime`:
  FHS, like nixpkgs.
* Everything else that was `/usr` is relocated.

### 1.4 Hard-coded `/usr` in specs: detection and generic handling

| where | generic handling | measured |
|---|---|---|
| `%install` writes `%{buildroot}/usr/...`, `/lib64`, `/sbin` | `%buildroot/usr` → P alias (+ spec-created usrmove links resolve through it) | 3.6 % of specs (static scan of 2185 Rocky 10 specs); glibc: `mkdir -p %{glibc_sysroot}/usr/$d`, `hardlink -c .../usr/lib/locale`, `pushd .../usr/lib/locale`, glibc32's `rm -rf etc var usr/bin ...` all work unchanged (spike) |
| `rm -rf $RPM_BUILD_ROOT` at the start of `%install` (removes the alias) | `realias` in `%__spec_install_post` merges a real `%buildroot/usr` into P and restores the link before brp/find-debuginfo | 6.3 % of specs; `sed` hit it in the spike (find-debuginfo wrote a real `/usr/lib/debug`) |
| `find %{buildroot}/usr ...` (a symlink start point is not followed by GNU find) | none needed in practice; flagged by the static scan | 0 specs |
| `%files` names `/usr/...` literally | alias makes the file exist; the linker canonicalizes `/usr/X` ≡ `P/X` | 1.6 % of specs (+0.2 % `/lib*`) |
| raw `./configure` (not `%configure`) defaulting `libdir=lib`, `sysconfdir=$prefix/etc` | `CONFIG_SITE` (`spikes/config.site`) | 1.6 % of specs; glibc is one (spike v1 failed exactly here: libc.so.6 in `P/lib`, i686 and x86_64 libraries in one dir, `/etc` under P) |
| configure scripts that special-case `prefix=/usr` (glibc: `slibdir`, `rtlddir`, `complocaledir`, `rootsbindir`, `sysconfdir`) | per-package `config.site` fragment setting the package's own cache variables to what it picks for `/usr` (glibc: 4 lines, `spikes/glibc.config.site`) | glibc; expected rare |
| literal `--prefix=/usr`, `PREFIX=/usr`, `CMAKE_INSTALL_PREFIX=/usr` | the build compiles FHS paths in; the alias still makes the install land in P; the linker reports the FHS strings (text: resolved, binary: per-package override `prefix` macro substitution in `%prep` via a hook) | 0.9 % of specs |
| `%{_bindir}/python3`-style tool use, `-I%{_includedir}/x`, `--with-x=%{_prefix}` (build env through target macros) | P ≡ `/usr` alias in the chroot | 0.9 % / 3.2 % of specs (static) — would all break without the alias |
| sources that hard-code `/usr/...` at runtime (`which2.sh` aliases `/usr/bin/which`) | linker: *FHS self-references* in text files whose target is a file of the same SRPM are rewritten to the owning output; in binaries reported (cannot grow) — designed, not yet in the prototype linker | which (spike) |

**Automatic detection** = the linker's report (per SRPM, machine-readable,
part of the build output): every P occurrence classified
(`self`/`file`/`dir`/`split-dir`/`missing`/`dangling`/`soft-*`, context
`elf:.rodata`/`elf:RUNPATH`/`text`/`symlink`/`gzip`...), every remaining
`/usr/...` string (shebang/text/ELF), every foreign `/nix/store` string, every
unresolved `DT_NEEDED`. A per-package policy decides which classes fail the
build (default: P or a P fragment left anywhere, foreign store path, reference
cycle, built-but-undeclared subpackage → fail; FHS strings in binaries → warning listed in the
package's report).

---


## 2. Output splitting and reference rewriting

### 2.1 Derivation shape

Per SRPM, two kinds of plain derivations (nothing at eval time depends on a
build result; the per-SRPM data they need is static, §2.7):

```
rocky.rpmbuild.<srpm>        rpmbuild --rebuild in the chroot, relocated (P);
  out:  RPMS/<arch>/*.rpm      transient binary RPMs (zstd -3; never shipped)
        manifest.json          per subpackage: files+flags+modes, provides,
                               requires, P, report of the build-time checks
  logs: build.log ...
rocky.link.<srpm>[.<part>]   the linker; outputs: one per output group (a group is
                               one subpackage, or an SCC of subpackages merged, §3)
  inputs:  rpmbuild.<srpm>, the link outputs it references (static plan, §2.7)
```

By default an SRPM has **one** link derivation with all its groups as outputs
(the spike: glibc → one derivation, 224 outputs, ~30 s). It is cut into several
link derivations ("parts") only where late binding to another SRPM requires it,
e.g. glibc-common's `ldd` → Rocky bash, whose own rpmbuild needs glibc's libs
(§3.3); the cut is part of the static plan (`links.json`).

User-facing attributes (`legacyPackages.x86_64-linux.rocky`):

* `rocky.<rpm name>` → the output for that subpackage, e.g. `rocky.glibc-devel`,
  `rocky.libnsl`, `rocky.nss_db` (flat, rpm namespace — same names as today's
  `rpms.*`); `rocky.<srpm>` is also a derivation whose outputs are all its
  subpackages: `rocky.glibc.devel`, `rocky.glibc.langpack-en`,
  `rocky.glibc.out` (= the subpackage named like the SRPM).
* store names: `/nix/store/<h>-<srpm>-<evr>[-<output>]` where `<output>` is the
  subpackage name with the `<srpm>-` prefix stripped (`glibc-devel` →
  `devel`), the subpackage named like the SRPM is `out` (no suffix), others
  keep their full name (`libnsl`, `nss_db`). Output names are valid as-is for
  all 6907 Rocky binary names (checked against `[A-Za-z0-9+-._?=]+`).
* `rocky.<rpm name>.passthru`: `rpmName`, `srpm`, `evr`, `requires`,
  `provides`, `mergedWith` (if an SCC was merged).

Why two derivations instead of rpmbuild + split in one multi-output
derivation: (a) the link step must be able to reference outputs of *other*
SRPMs that are built *after* this SRPM's rpmbuild (glibc-common's `ldd` →
bash, while bash's rpmbuild needs glibc) — a derivation-level dependency of
the rpmbuild on bash would be a cycle, a separate link derivation is not
(§3.3); (b) the splitter/linker can change without rebuilding glibc;
(c) the transient RPMs are exactly what parity and buildroot rpmdbs need
(§5.1, §7).

### 2.2 The `%files` partition

rpmbuild already computes the partition, including everything that is hard to
reimplement: `%dir`, globbing, `%exclude`, `%ghost` (not in the payload),
`%config(noreplace)`, `%doc`/`%license` copying into `%_docdir`, `%lang`,
`-f filelist`, `%find_lang`, debuginfo/debugsource subpackages, the brp
scripts (strip, compress, mangle shebangs, python bytecompile), hard links,
modes. So the build runs `rpmbuild -bb` (with `%_binary_payload w3.zstdio`
for speed) and the linker extracts each RPM payload (`rpm2cpio | cpio`), plus
`rpm -qp --qf '[%{FILENAMES}\t%{FILEFLAGS:fflags}\t%{FILEMODES:perms}...]'`,
`--requires`, `--provides`. Path mapping into output `$o_k` of subpackage k:

| payload path | goes to | note |
|---|---|---|
| `P/<rel>` | `$o_k/<rel>` | the normal case |
| `/usr/<rel>` (named through the alias) | `$o_k/<rel>` | same file as `P/<rel>` |
| `/lib64/<x>`, `/bin`, `/sbin`, `/lib` | `$o_k/lib64/<x>` ... | usrmerge semantics |
| `/etc/...`, `/var/...`, `/run/...`, `/boot`, `/opt`, `/srv` | `$o_k/etc/...` | + `nix-support/rocky-rpm.json` `fhs[]` entry |
| `%ghost` | — | metadata only |
| `-debuginfo`, `-debugsource` | one `debug` output per SRPM (or not built) | `$debug/lib/debug/.build-id/xx/*.debug` like nixpkgs `separateDebugInfo`; sources at `$debug/src/debug/<n-v-r>` |
| `/usr/lib/.build-id/*` in non-debug packages | dropped | rpm-internal; parity normalizes it away already |

A file listed in two subpackages is copied into both outputs. A subpackage the
static list declares but the build did not produce yields an empty output
with `nix-support/rocky-rpm.json: {"built": false}` (arch-conditional
subpackages); a subpackage the build produced but the list does not declare
fails the link step ("static subpackage list out of date").

### 2.3 Rewriting P: owner resolution

For every occurrence of P in every file and symlink target (raw bytes; also
inside gzip members, re-compressed deterministically), take the following
path characters `[A-Za-z0-9._+-/@%~,=]*`, normalize (`//`, `/./`), and
resolve the longest match against the SRPM's ownership map (built from the
`%files` partition):

1. **file** owned by subpackages S: me ∈ S → me; else a hard edge to s ∈ S if
   me `Requires` something **only s provides** (rpm metadata of the transient
   RPMs: provides names, sonames, file requires); else **soft** → me.
   The "only" matters: glibc Requires the virtual `glibc-langpack`, which
   `glibc-all-langpacks` and 200 langpacks provide — a choice, not a target
   (first spike version picked all-langpacks and put 230 MB into glibc's closure).
2. **directory** (or a *missing* name below one, e.g.
   `share/locale/%L/LC_MESSAGES/%N`): me has content there → me; exactly one
   owner → as for files; **several owners → a union** (locale dirs, gconv,
   terminfo): rewritten to me and composed at runtime (§4) — except that if
   me uniquely Requires exactly one of the owners (its *primary* provider:
   ncurses-libs → ncurses-base's common terminals) a **weak** edge to it is
   added, but only if it does not close a cycle (decided after a dry pass over
   all files). In glibc the weak edge glibc → glibc-common (libc.so.6's
   `lib/locale`, `share/locale`) would close a cycle with glibc-common → ld.so
   and is dropped; that removes glibc's only cycle.
3. bare `P` (a compiled-in `prefix=`): me. Nothing matches (`dangling`, e.g.
   `share/zoneinfo`, owned by tzdata): me, soft, listed; per-package policy may
   map a dangling prefix to FHS instead (`/usr` + padding; only for stable
   formats such as zoneinfo).
4. **symlinks** — relative ones too. On an rpm system a relative link resolves
   in the shared `/usr`; split into store paths it does not: in the spike
   xz-devel's `lib64/liblzma.so -> liblzma.so.5.6.2` dangled (target in
   xz-libs), as did xz-lzma-compat's `bin/lzma -> xz` and 76 man links. Every
   symlink target is resolved in P-space; if the target belongs to another
   output it becomes an absolute link to that output (glibc: 235 such links,
   xz: 77). Same gating.

The replacement is `path(owner) + "/" * (len(P) − len(path(owner)))`. P is
sized so this is never negative: `P = /nix/store/<H0>-<srpm>-<evr>-<pad>`
with `|pad| ≥ m + 12`, m = the longest output name of that SRPM (static, from
the lock): for all 6907 Rocky binaries the output names are valid Nix output
names, the longest is 47 characters
(`google-noto-sans-tifinagh-agraw-imazighen-fonts`), p99 is 36; glibc's is 27
(`compat-libpthread-nonshared`). The padding sits right after the store path,
so every consumer sees a normal absolute path: the kernel (`PT_INTERP`),
ld.so (RUNPATH, system dirs), `open()`, shells. The visible effect is cosmetic:
`ldd` prints `…-glibc-2.39-142.el10_2//////////////////////////////////lib64/libc.so.6`
(spike output). Alternatives rejected: equal-length output names (no padding,
but store names like `glibc-2.39-142.el10_2-out________________`); per-directory
macro→output mapping (nixpkgs' `--libdir=$lib/lib --includedir=$dev/include`)
cannot express rpm partitions (glibc's `lib64` holds files of 9 subpackages);
NUL-padding of C strings (conda) breaks length-tagged strings and compiled
terminfo/`.mo`/`.pyc` tables, where `/`-padding keeps every byte count.

**Split strings ("store by pieces").** The relocated glibc build showed that
compiled-in paths are not always contiguous: gcc with Rocky's flags
(`-O2 -march=x86-64-v3`) inlines `strcpy`/`memcpy` of a constant path as
32-byte vector stores from constant-pool chunks plus an overlapping tail
chunk. A spike (`spikes/piece-test.*`, stage0 gcc 14 with `%optflags`) finds
such piecewise copies for path literals of 51 up to 400 characters (none at
600), so making P long enough to avoid it is not an option. In glibc,
ld.so's system-dir copy appears as `P` + `xxxxxxx/lib64/` (head chunks
adjacent, then the overlapping tail repeating the end of the padding),
libc.so.6's `TZDIR` as an isolated tail chunk `xxxxxxxxxxxxxxxxx/share/zoneinfo`,
and ldconfig carries a truncated head. A rewrite that only looks for whole P
corrupts these silently (the tail chunk overwrites the rewritten string's end
with stale bytes). The linker therefore:
* (a) whole `P` + path → resolved as above;
* (b) whole `P` + a run of padding characters + path → the overlapped tail of
  the same string: rel follows the run, the run is rewritten to the bytes the
  new string has at those positions (always `/`, because the last 12 bytes of
  P are padding in every replacement);
* (c) isolated fragments (≥ 8 bytes matching P at a unique offset — so H0
  and the padding must be a distinctive marker sequence with unique windows,
  not the spike's `000…`/`xxx…`, which collided with printf's zero-padding
  table in libc.so.6) are mapped byte-for-byte to *this output's* replacement
  at the same offsets. If the tail fragment of such a string names a file
  owned by another output, a forwarding symlink `$me/<rel> → $owner/<rel>` is
  added (rare; listed in `nix-support` so file-list parity ignores it);
* (d) post-check: no window of H0/padding may survive anywhere (also inside
  compressed data), otherwise the build fails.
Nix's own reference scanner only sees contiguous hashes; (a), (b) and the
forwarding symlinks guarantee that every *foreign* reference appears
contiguously, so closures are complete.

### 2.4 Contexts the rewrite must handle

| context | handling |
|---|---|
| C strings in `.rodata`/`.data` (gconv dir, locale dirs, ld.so system dirs, libexec helpers) | length-preserving rewrite |
| `PT_INTERP`, `DT_RUNPATH`/`DT_RPATH` strings containing P | rewritten in place, then recomputed (§2.5) |
| symlinks | absolute `P/...`, `/usr/...` and relative targets resolved in P-space; cross-output targets become absolute links (§2.3 item 4) |
| scripts, `.pc`, `.la`, linker scripts (`libc.so`: `GROUP ( P/lib64/libc.so.6 ... )`), cmake configs, `.desktop`, systemd units | same rewrite (text could take any length, but the same code path is used) |
| gzip'ed man/info pages | decompress → rewrite → `gzip -9 -n` equivalent (mtime 0) |
| compiled terminfo entries (ncurses-term: 300 files reference `P/share/tabset/*` of ncurses-base) | length-preserving rewrite keeps the string tables valid — a length-changing rewrite would corrupt them |
| `.pyc` | length-preserving rewrite keeps them valid; `co_filename` just carries padding (alternative: re-run `brp-python-bytecompile` in the link step) |
| static archives / object files (debug strings) | in-place rewrite (member sizes unchanged) |
| xz/zstd-compressed data, `.gnu_debugdata` MiniDebugInfo | decompress-rewrite-recompress for the known formats (the purity scanner already decompresses all of them); unknown compressed blobs → P found by the post-check → build fails, per-package override |
| Go/Rust binaries (length-prefixed strings) | length-preserving: fine |

### 2.5 ELF: interpreter and RUNPATH

* **Own SRPM**: references through P (glibc's own programs:
  `PT_INTERP = P/lib64/ld-linux-x86-64.so.2`) are rewritten like any string.
* **Other SRPMs** (normal packages): binaries linked by the Rocky gcc in the
  chroot get the dynamic linker from the toolchain (§5.2: link-time
  `-dynamic-linker <glibc out>/lib64/ld-linux-x86-64.so.2` from a specs
  fragment appended to `%build_ldflags`); anything linked another way that
  still says `/lib64/ld-linux-x86-64.so.2` is fixed with
  `patchelf --set-interpreter` (layout change accepted; counted in the report).
* **RUNPATH** is recomputed for every ELF from `DT_NEEDED`: each soname is
  looked up in (1) this SRPM's outputs, (2) the link inputs' `lib64`/`lib`
  dirs; sonames found next to the dynamic linker (glibc's `out/lib64`, ld.so's
  default search dir) need no entry; `$ORIGIN` entries are kept; the result is
  written with `patchelf --set-rpath` (DT_RUNPATH). This is
  `autoPatchelfHook`'s algorithm, but deterministic (input order) and driven by
  the same Requires gating (an unresolved soname fails unless the package is
  allowlisted — stage0 builds against nixpkgs `-devel` libraries, e.g.
  memusagestat's `libgd.so.3`, are the known case).
* libtool's RPATH `P/lib64` (relocated prefixes are not "system" dirs to
  libtool) is just replaced by the computed RUNPATH; redhat-rpm-config's
  `check-rpaths` accepts store paths (they are neither standard nor invalid).

### 2.6 References to other packages (FHS and P of dependencies)

The build environment shows dependencies at FHS paths (§5.1), so what a build
records about its dependencies is mostly FHS: `#!/usr/bin/perl`,
`BASH_SHELL=/usr/bin/bash`, `/usr/share/zoneinfo`. The linker resolves
`/usr/<rel>` references against (a) this SRPM's outputs ("FHS
self-reference", e.g. `which2.sh`'s alias to `/usr/bin/which`) and (b) the
link inputs (their manifests map relative paths to outputs). Text files
(shebangs included — this is `patchShebangs`) are rewritten to the store path
(any length); binary FHS strings cannot grow and stay FHS (reported, and an
allowlist per package says which are acceptable: `/bin/sh`, `/etc/*`,
`/usr/share/zoneinfo`). Dependency paths that reach the build as store paths
(`.pc`/`.cmake` files of dependencies that name their store prefix) are real
Nix references of the rpmbuild output already and are kept.

### 2.7 What must be static, and where it comes from

* subpackage list per SRPM: **not** `rpms.json` alone — 8 of the 20 spike
  SRPMs that built also build a subpackage Rocky does not publish
  (`bzip2-static`, `expat-static`, `gmp-static`, `lz4-static`,
  `ncurses-static`, `popt-static`, `xz-static`; glibc: 3). The lock generator
  runs `rpmspec -q --target x86_64 --qf '%{NAME}\n'` on every spec in the
  stage0-full buildroot (offline, like `update-lock`) and writes
  `lock/rocky-10.2/subpackages.json`; the linker fails on any built but
  undeclared subpackage (it did, on xz-static, in the spike).
* output groups (SCC merges): `lock/rocky-10.2/links.json` (generated, §3).
* link inputs of each group: same file; default (no entry yet) = the groups
  that the subpackage's rpm `Requires` resolve to (one level), from
  `deps.json.gz` converted at lock-generation time into a Nix-readable
  `requires.json` — static, and a superset of the hard references the Requires
  gate allows (rpm auto-generates sonames, interpreters and pkgconfig
  requires).
* buildroot contents: `lock/rocky-10.2/buildroots.json` from the existing
  mock-like resolver (§8.2).

## 3. Reference cycles between subpackages

### 3.1 Which graph

Nix forbids cycles between outputs (of one derivation or across derivations).
The graph that matters is the **hard-reference graph** produced by the
linker: an edge me→owner only for references that rpm's `Requires` of `me`
covers (§2.3), plus RUNPATH edges. It is *not* the rpm `Requires` graph,
which is far too cyclic to use as a closure (measured on the 10.2 lock,
`req-graph.py`):

* binary-level Requires graph: **80 SCCs**, the largest has **212 nodes**
  (glibc + its 200 langpacks + glibc-common, bash, ncurses-libs), 26 SCCs span
  several SRPMs (perl core: 57 binaries in 34 SRPMs; redhat-rpm-config ↔ the
  macro packages; coreutils → openssl-libs → ca-certificates → coreutils;
  freetype ↔ harfbuzz; mesa ↔ libglvnd);
* SRPM-level Requires graph: one SCC of **773 SRPMs** — "one derivation per
  SRPM with Requires as references" is impossible;
* inside SRPMs: 53 of the 1049 multi-binary SRPMs have an intra-SRPM Requires
  cycle (sizes: 45×2, 10×3, 1×4, 2×6, 1×21, 1×210).

Most of these cycles vanish at file level: `glibc`'s libc.so.6 mentions
`lib/locale` (langpacks) but does not Require any langpack, so the reference
is soft; ca-certificates → coreutils is a scriptlet dependency without file
references; openssl → ca-certificates goes through `/etc/pki` (FHS, never
rewritten). The spikes found **no file-level cycle** in the 20 relocated non-glibc SRPMs
and none in glibc once multi-owner directories are treated as unions (§2.3
item 2); before that rule glibc had exactly one (`glibc ⇄ glibc-common`:
libc.so.6 → `lib/locale`/`share/locale`, glibc-common → ld.so). Typical
hard edges: `-devel → -libs` (`.so` links, `.pc`), `-libs → -base` data
(ncurses-libs → ncurses-base's terminfo/tabset), `-compat → main` (symlinks),
langpacks → glibc-common, everything → glibc's ld.so.

### 3.2 Detection and merging

* The linker computes the hard-reference graph of the SRPM it links, runs
  Tarjan, and **fails** on an SCC that the static plan has not merged, printing
  the plan entry to add (Nix would otherwise fail later with a less useful
  "cycle detected in the references of output X from output Y").
* A merged group is **one output** (a true cycle such as libfreetype ⇄
  libharfbuzz cannot be two store paths at all). Its name is the
  lexicographically smallest member that is the SRPM's own name if present
  (`out`), else the member with the shortest name; the files of all members go
  into it.
* User-visible attributes: every member name still exists and points to the
  merged output (`rocky.harfbuzz` = `rocky.freetype` = `…-freetype-2.13.2-…`);
  `passthru.mergedWith = [ … ]`; the merge is listed in the package report.
  A merge never changes the file contents, only where they live.
* Cross-SRPM SCCs (freetype/harfbuzz) are one link derivation consuming two
  rpmbuild outputs — possible because link derivations are separate from
  rpmbuilds (§2.1).
* Plan file: `lock/rocky-10.2/links.json`
  `{ "<srpm>": { "merge": [["freetype","harfbuzz"]], "inputs": {"<group>": ["<group>", ...]} } }`,
  generated (`nix run .#update-links`) from the rpmbuild manifests + linker
  reports, committed like the other lockfiles, verified by every link build
  (a stale entry fails with a diff). Entries are needed only where the
  default (Requires-derived inputs, no merges) is wrong.

### 3.3 Ordering cycles that are not reference cycles

glibc-common's `ldd` has `#!/usr/bin/bash` and glibc-common Requires
`/usr/bin/bash`, so link(glibc-common) references link(bash); bash's rpmbuild
needs link(glibc) (libs) and link(glibc-devel). With per-group link
derivations this is a DAG:
`rpmbuild(glibc) → link(glibc, glibc-devel, …) → rpmbuild(bash) → link(bash) → link(glibc-common)`.
In one multi-output derivation per SRPM it would be a cycle. Where even the
group graph is cyclic across SRPMs after Requires gating, the plan drops the
back edge (the reference becomes soft/FHS and is reported).

## 4. Union directories at runtime; glibc specifics

### 4.1 The problem, generically

rpm assumes one shared `/usr`: a binary compiles in *one* directory
(`lib64/gconv`, `lib/locale`, `share/locale`, `lib64/sasl2`, `share/man`,
`lib64/pkgconfig`, `share/perl5/vendor_perl`, `lib64/python3.12/site-packages`,
`lib/rpm/macros.d`, gio/gtk/qt plugin dirs, `share/fontconfig/conf.avail`,
`lib/systemd/system`, …) and many packages drop files there, often with a
scriptlet that rebuilds a cache (`iconvconfig`, `ldconfig`,
`glib-compile-schemas`, `gtk-update-icon-cache`, `update-mime-database`,
`fc-cache`, `mandb`). After relocation the compiled-in directory is the
*referencing* package's own output (§2.3: directory references resolve to me
if I have content there, soft otherwise), so every package works standalone
with its own plugins/data and nothing else.

### 4.2 Composition mechanisms (layered, no package rebuilds)

1. **Upstream search-path variables** — preferred, no patches. A table
   (`lib/unions.nix`) maps union directories to the variables the software
   already honours: `lib64/gconv` → `GCONV_PATH`, `lib/locale` → `LOCPATH`,
   `share/man` → `MANPATH`, `share/info` → `INFOPATH`, `lib64/pkgconfig`
   `share/pkgconfig` → `PKG_CONFIG_PATH`, `share/aclocal` → `ACLOCAL_PATH`,
   `share/perl5*` → `PERL5LIB`, `lib*/python3.12/site-packages` →
   `PYTHONPATH`, `share` (XDG) → `XDG_DATA_DIRS`, `lib64/girepository-1.0` →
   `GI_TYPELIB_PATH`, `lib64/gio/modules` → `GIO_EXTRA_MODULES`,
   `lib64/qt6/plugins` → `QT_PLUGIN_PATH`, `lib64/sasl2` → `SASL_PATH`,
   `lib/rpm` → `RPM_CONFIGDIR`, `share/terminfo` → `TERMINFO_DIRS`, …
2. **`rocky.buildEnv { paths; }`** — a profile (symlink farm like nixpkgs
   `buildEnv`, rpm conflict semantics: identical files or directories merge,
   anything else is an error naming both packages) plus
   `etc/profile.d/rocky-paths.sh` / `nix-support/setup-hook` exporting the
   variables of 1. for the directories present, plus **profile hooks** that run
   the cache tools rpm's scriptlets/file triggers run (`iconvconfig --prefix`,
   `glib-compile-schemas`, …), declared once per tool, keyed by directory —
   the Nix equivalent of rpm's `%transfiletrigger`s. `mkShell` and NixOS-style
   modules use the same table. Rocky's scriptlets themselves are not executed
   (they target a mutable rpmdb system); they are kept in
   `nix-support/rocky-rpm.json` for image builders.
3. **Wrappers**, only where 1. does not exist and a program must see a union
   from its own Requires closure (e.g. a perl script that needs Required perl
   modules): `rocky.wrap` (a tiny compiled wrapper, built by the Rocky
   toolchain, so no nixpkgs in the closure) — a composition-time choice, not
   part of the package outputs.
4. **Per-package compiled-in defaults** via the soft-reference policy: for
   stable, host-provided data a package may map a dangling prefix to FHS
   (glibc: `share/zoneinfo` → `/usr/share/zoneinfo`).

### 4.3 glibc: what Rocky's glibc does relocated, compared with nixpkgs

| mechanism | nixpkgs glibc | relocated Rocky glibc (this design) |
|---|---|---|
| rtld system search dirs | `$out/lib` (prefix) | `slibdir`=`P/lib64` → `<glibc out>/lib64` (config.site cache var, rewrite) — same idea |
| `ld.so.cache` / `ld.so.conf` | patch `dont-use-system-ld-so-cache`: `PREFIX/etc/ld.so.cache` (absent) | **same patch, justified**: `sysconfdir` must stay `/etc` (spec writes `/etc/ld.so.conf`, `TZDEFAULT`=`$(sysconfdir)/localtime` must be `/etc/localtime`), so without it a relocated ld.so reads the *host's* `/etc/ld.so.cache` and can resolve a library missing from RUNPATH or a `dlopen`ed NSS module to a foreign build (other glibc, maybe newer symbol versions) |
| `/etc/ld.so.preload` | patch → `/etc/ld-nix.so.preload` | **same, justified** (host preload of foreign libraries into Rocky processes); one line |
| locales | patch `nix-locale-archive` (`LOCALE_ARCHIVE[_2_27]`) | Rocky langpacks ship per-locale **directories** (`lib/locale/<loc>/LC_*`), so upstream **`LOCPATH`** (colon-separated) composes langpacks with **no patch**; `C.UTF-8` is built into 2.39. The compiled default `P/lib/locale` → soft (glibc does not Require a specific langpack) → `<glibc out>/lib/locale` (absent). Only `glibc-all-langpacks` (a `locale-archive`) needs the archive path: optional patch = nixpkgs' `LOCALE_ARCHIVE` hunk without the `/run/current-system` fallback |
| message catalogs (`libc.mo`) | `$out/share/locale` (glibc ships them) | `share/locale` belongs to the langpacks (union) → libc's compiled `localedir` points at `<glibc out>/share/locale` (absent): libc's own messages are English unless a profile/patch provides them. libc honours no environment variable for its own text domain; accepted (no patch proposed) |
| gconv modules | `$out/lib/gconv` + cache | `P/lib64/gconv` → glibc main (owns the dir and most modules); `glibc-gconv-extra` modules + `gconv-modules.d/gconv-modules-extra.conf` via upstream `GCONV_PATH`; the shipped `gconv-modules.cache` is the spec's empty placeholder (Rocky's `%post` runs `iconvconfig`): the link step may run `iconvconfig --prefix` for glibc main itself (scriptlet emulation for one output) and the profile hook for unions |
| NSS modules | via nscd/nsncd on NixOS | files/dns are in libc; `nss_db`, `nss_hesiod`, systemd's and sssd's modules are found only through `LD_LIBRARY_PATH` or a profile + nscd-style daemon (composition level); a missing module is skipped silently by glibc, so standalone use is safe |
| `TZDIR` | `$out/share/zoneinfo` unless `TZDIR` | dangling (`tzdata` is another SRPM, not Required) → per-package policy: FHS fallback `/usr/share/zoneinfo` (+ upstream `TZDIR`) |
| `/etc/{nsswitch.conf,resolv.conf,hosts,gai.conf,localtime}` | FHS | FHS (hard-coded upstream or `sysconfdir=/etc`) |
| `_PATH_BSHELL` (`system`, `popen`) | `/bin/sh` | `/bin/sh` |
| `CS_PATH` | patched to NixOS paths | unchanged (`/bin:/usr/bin`) |
| `ldd`, `sotruss`, `xtrace`, `tzselect` shebangs | patched to stdenv bash | `#!/usr/bin/bash` → `<bash out>/bin/bash` by the link step once Rocky bash exists (§3.3); FHS before |
| `getconf` helpers, `RTLDLIST` in ldd | own paths | own paths via the rewrite |

So the justified Nix-side patches to Rocky's glibc are two (ld.so.cache /
ld.so.conf location, ld.so.preload), plus optionally `LOCALE_ARCHIVE`. They are
applied without editing the spec: per-package `nixPatches` are applied by a
`%__spec_prep_post` hook after `%prep` (a mechanism every package can use).

## 5. Toolchain and stdenv

### 5.1 The build environment is still an FHS chroot — made of Rocky outputs

rpmbuild, redhat-rpm-config, the brp scripts, `%configure`/`%cmake`/`%meson`,
specs with `/usr/bin/foo`, gcc's and ld's built-in search paths: all of it
assumes a `/usr` that contains the buildroot. Keeping the existing runner
(`lib/chroot.sh`: bwrap + overlayfs, single-uid phases) as the **build-tool
environment** is what makes unmodified specs possible. What changes is what
the layers contain:

* **view layer**: for every binary package of the SRPM's buildroot
  (`lock/…/buildroots.json`, §8.2), its link output projected into `/usr`
  (`$o/bin` → `/usr/bin`, `$o/lib64` → `/usr/lib64`, …; symlinks, directories
  merged; conflicts as rpm), its `fhs[]` files copied into `/etc`, `/var`
  (`setup`'s `/etc/passwd`, `rocky-release`'s `/etc/rpm/macros.dist`).
* **rpmdb layer**: `rpm --root R -i --justdb --nodeps --noscripts` of the
  transient RPMs relocated back (`--badreloc --relocate P=/usr`), so
  `rpm -q/-ql` answers like in mock (glibc's spec runs
  `rpm -ql kernel-headers`) and, from stage 1 on, BuildRequires are checked for
  real (no `--nodeps`).
* `/nix/store` inside the chroot: a tmpfs with read-only binds of exactly the
  closure of the view's outputs, plus the own `P → /usr` alias (the spike
  already does this: `--tmpfs /nix/store` + per-path `--ro-bind`). The
  nixpkgs runner tools (bwrap, python for the linker) live outside and are
  invisible inside, so a leak of nixpkgs into an output is impossible by
  construction from stage 1 on.

### 5.2 Compilers and finding buildInputs

Rocky's gcc and binutils, relocated, still search the **absolute** FHS
directories they were configured with — `NATIVE_SYSTEM_HEADER_DIR=/usr/include`,
`STANDARD_STARTFILE_PREFIX_{1,2}=/lib/ /usr/lib/` (+ `../lib64`), ld's
`SEARCH_DIR("=/usr/lib64")` (binutils is built `--with-sysroot=/`) — and their
own install dirs through `$prefix`, which the rewrite turns into their store
path. Inside the chroot `/usr` *is* the union of the buildInputs, so headers,
crt files, `.so` symlinks, `.pc` files, cmake configs are found exactly as in
mock: **the view replaces cc-wrapper's include/library logic**. What a
cc-wrapper additionally does is injected the redhat-rpm-config way:

* dynamic linker: a specs fragment
  `/usr/lib/rpm/el-nixos/nix-dynamic-linker` (generated per stage):
  `*link: + %{!static:%{!static-pie:%{!shared:%{!r:%{m32:-dynamic-linker <glibc>/lib/ld-linux.so.2;:-dynamic-linker <glibc>/lib64/ld-linux-x86-64.so.2}}}}}`,
  appended to `%build_ldflags` with the other `-specs=` that every
  `%set_build_flags`/`%configure`/`%cmake`/`%meson` build already receives.
  The interpreter exists inside the chroot, so configure test programs and
  `%check` run. Builds that ignore LDFLAGS are fixed by the link step
  (patchelf), and counted.
* RUNPATH: not injected at link time; computed by the link step from
  `DT_NEEDED` (§2.5) — precise, and independent of how the package links.
* nixpkgs' cc-wrapper/bintools-wrapper *can* wrap Rocky gcc/binutils/glibc
  (`wrapCCWith { cc = rocky.gcc; bintools = wrapBintoolsWith { bintools =
  rocky.binutils; libc = rocky.glibc; }; }`) for Nix-style builds and
  `rocky.mkShell`; outputs built with it reference only the Rocky glibc and
  libraries it injects (the wrapper scripts run at build time only), so
  output closures stay Rocky-only if `shell` is Rocky bash and every library
  is Rocky's. Not used for rpm builds.

### 5.3 rpmbuild, redhat-rpm-config, debuginfo tooling

They are ordinary Rocky packages in the view (rpm, rpm-build,
redhat-rpm-config, the `*-srpm-macros`, debugedit, elfutils, dwz, gdb-minimal,
python3 for brp-python-bytecompile). Two details:

* the relocated rpm's compiled-in configdir is its own output; the chroot sets
  `RPM_CONFIGDIR=/usr/lib/rpm` (honoured by rpm; already used outside the
  chroot today) so it reads the view's merged config dir with every package's
  `macros.d`;
* packages consumed as build environment keep their FHS self-references
  (`fhsSelfRefs = "keep"` for redhat-rpm-config & co.), so
  `-specs=/usr/lib/rpm/redhat/redhat-hardened-cc1` and therefore `OPTFLAGS`
  stay byte-identical to Rocky's.

brp scripts run unchanged (strip, `find-debuginfo` + dwz + gdb-add-index,
compress, mangle-shebangs, python bytecompile, `check-rpaths`,
`check-buildroot`). Debug info: rpm's `-debuginfo`/`-debugsource` subpackages
become one `debug` output per SRPM (`lib/debug/.build-id/xx/*.debug`, sources
in `src/debug`, DWARF names `/usr/src/debug/<n-v-r>`: gdb needs
`set substitute-path` or `NIX_DEBUG_INFO_DIRS` — documented), built by the
same link derivation, never in the closure of anything else. `%check`:
`--nocheck` in the main build (as today, it does not change outputs);
`rocky.check.<srpm>` = the same rpmbuild with checks, a separate optional
job (it needs the build tree, so it is a full second build).

### 5.4 setup hooks, patchShebangs

There are none in rpm builds: the spec is the recipe. `patchShebangs` is the
link step's FHS→store resolution of interpreter lines (§2.6). For
Nix-composed downstream builds, `rocky.<pkg>` outputs carry
`nix-support/setup-hook` only for the union variables of §4.2 (generated from
the table, e.g. `-devel` outputs with `lib64/pkgconfig` add to
`PKG_CONFIG_PATH`).

## 6. Bootstrap

The rule that drives everything: **a link output of stage *n* may only
reference link outputs of stage *n*** (checked, §7.1). Build environments may
use anything older.

| stage | build environment (chroot view) | what is built | outputs reference |
|---|---|---|---|
| **0** (exists) | stage0 FHS root: toolchain from Rocky tarballs, nixpkgs tools, stage0 rpm; `/nix/store` visible | — | — |
| **1** "relocated in stage0" | stage0 root + stage-1 link outputs built so far, overlaid into `/usr` (they win) | the **core set**: the runtime closure of mock's rocky-10 `chroot_setup_cmd` + gcc + make (113 SRPMs, 155 binaries by the Requires closure in the lock) plus their BuildRequires closure, in BuildRequires order (glibc, kernel-headers, binutils, gcc, then bash, coreutils, …, rpm, redhat-rpm-config) | stage-1 outputs only; anything only nixpkgs provides at that point → soft/FHS reference (text) or allowlisted unresolved `DT_NEEDED` (e.g. glibc-utils' memusagestat → libgd until gd is built) — reported, never a store reference |
| **2** | **only stage-1 link outputs** (view + rpmdb); `/nix/store` = their closure; no nixpkgs, no stage0 | the core set again, then everything else (BaseOS, AppStream) | stage-2 outputs only |
| **3** (check) | only stage-2 outputs | the core set | — |

Details:

* **glibc** is built three times: stage 1 (by the stage0 gcc, against stage0
  headers → as today), stage 2 (by the stage-1 Rocky gcc linked against the
  stage-1 glibc), stage 3 (by stage-2 gcc). Stage 2 is the shipped one.
* Within a stage, order follows the BuildRequires DAG; BuildRequires cycles
  (gcc ↔ glibc-devel, rpm ↔ rpm-build, python3 ↔ python3-devel tooling, …) are
  broken by taking the cyclic dependency from the previous stage (stage *n−1*
  output in the view) — still allowed, because only *references* are
  constrained, not build inputs. The plan is computed statically from
  `buildroots.json` (Tarjan on the SRPM BuildRequires graph; within an SCC a
  fixed order from a small checked-in list `bootstrap/order.json`).
* **Fixpoint criterion**: for the core set, stage-3 outputs equal stage-2
  outputs **after normalizing store hashes** (replace every
  `/nix/store/<32>-` by a constant, then compare every file; ELF compared with
  the parity tool's loaded-section view). Expected residues: archive member
  dates (known, docs/DESIGN.md), build-ids (they hash paths). A mismatch means
  a stage leak (something of stage 1 influences stage 2 beyond paths) and is
  investigated, not allowlisted.
* What is rebuilt when: a change to a package rebuilds its rpmbuild and link
  in every stage where it is used and everything downstream in that stage —
  normal Nix behaviour. The stage-2 set is the product; stage 1 and 3 are
  bootstrap/CI artifacts.

## 7. Enforcement and verification

### 7.1 Purity / closure enforcement

Three layers, from cheap to strong:

1. **Linker post-check (every link build)**: byte scan of every output file
   (with `tools/rpm_purity.py`'s nested decompression) for `/nix/store/`: each
   hash found must be one of this derivation's outputs or of an explicit
   *allowed set* = the link outputs it declares as inputs (passed as a file).
   Any other hash (nixpkgs, stage0, a previous stage, the placeholder P) fails
   the build with file + offset. This replaces today's "no `/nix/store` at all"
   rule with "only these store paths".
2. **`allowedReferences = outputs ++ declared inputs`** on each link
   derivation (Nix-level; catches anything the scanner and Nix agree on) and
   `disallowedRequisites = [ stage0 toolchain, the runner tools, nixpkgs stdenv ]`
   (short static list). (`allowedRequisites` with "all stage-2 outputs" is not
   usable: listing thousands of derivations would make them inputs.)
3. **Closure check per stage** (`checks.rocky-closure-<stage>`): a derivation
   with `exportReferencesGraph` over all link outputs of the stage verifies
   that every path in every closure is a link output of the same stage (by
   name pattern + membership in the stage's output list written at eval time
   as plain strings without context). This is the "only Rocky-built paths"
   proof the milestone asks for.

From stage 2 on, layer 1 is belt-and-braces: the chroot cannot see nixpkgs.

### 7.2 Parity with the official RPMs, adapted to relocation

The existing parity tool keeps working on the **transient RPMs** of
`rocky.rpmbuild.<srpm>` with a path normalization (P → `/usr`, length-changing
for text): file lists, modes, flags, Requires/Provides (rpm metadata is
unaffected except file paths and `/usr`-based file provides), scriptlets.
On the **link outputs**:

* **relative file lists**: official payload paths with `/usr/` stripped ↔
  output-relative paths (`/etc/x` ↔ `$o/etc/x`; `%ghost` and `.build-id`
  normalized) — must be equal per subpackage (merged groups: union).
* **content**: non-ELF files must be identical after replacing every
  `<output path>/+` by `/usr` in ours (and the 4-char vs. store-length
  difference is irrelevant for text); ELF: `DT_NEEDED`, `SONAME`, dynamic
  symbols with versions, verdef/verneed identical (`tools/abi-compare.py`
  unchanged); `INTERP`/`RUNPATH` checked to name the expected outputs; loaded
  section bytes are **expected to differ** (the compiled-in prefix strings
  are longer, so layouts shift) — compared after disassembly with addresses
  normalized, reported, not failing.
* **behaviour** (`checks.glibc-runtime-nix`): the existing ~1550-line report
  script, run once in the official RPM-only root (as today) and once with
  **store binaries directly** in the plain Nix sandbox (no `/usr`, no
  `/lib64`), environment from §4.2 (`LOCPATH`, `GCONV_PATH`), programs
  compiled against `rocky.glibc-devel` with the relocated gcc; outputs
  normalized for paths. All 885 locales via `LOCPATH` on the langpacks.

### 7.3 Reproducibility

P is a pure function of (srpm, evr, longest output name); the rewrite, padding
and patchelf are deterministic; gzip re-compression uses mtime 0 and fixed
level; extraction preserves rpm's clamped mtimes (the store resets them
anyway). The rpmbuild derivation keeps today's measures
(`SOURCE_DATE_EPOCH`, clamping, separate `logs` output); the known
non-determinism (ar member dates) carries over and would be fixed in the link
step (rewrite member dates to `SOURCE_DATE_EPOCH`) — a deviation from Rocky's
bytes that relocation already makes moot.

## 8. Scaling to ~2200 SRPMs

### 8.1 Per-package overrides: rare, typed, outside the spec

`packages/<srpm>.nix` exists only when needed; everything has a generic
default. Fields (all optional):

```nix
{
  unshipped = [ "glibc32" "sysroot-x86_64-el10-glibc" "compat-libpthread-nonshared" ];
  configSite = ./glibc.config.site;      # appended to the generic CONFIG_SITE
  nixPatches = [ ./glibc-ld-so-cache.patch ./glibc-ld-so-preload.patch ];  # after %prep
  defines = { _annotated_build = "0"; };  # stage0 only
  rpmbuildArgs = [ "--without" "sanitizers" ];
  hooks = { prepPost = ""; buildPre = ""; installPost = ""; };  # %__spec_*_{pre,post} snippets
  softRefs.fhsFallback = [ "share/zoneinfo" ];   # dangling prefix -> /usr/... instead of self
  fhsSelfRefs = "keep";                  # build-environment packages (redhat-rpm-config, ...)
  allowUnresolvedNeeded = [ "libgd.so.3" ];      # stage-1 only, with reason
  allowFhsInBinaries = [ "/usr/share/zoneinfo" ];
  check = false;
}
```

Spec text is never edited; every hook is an rpm macro the runner defines
(`%__spec_prep_post` etc. exist in rpm 4.19 for every section).

### 8.2 BuildRequires → build inputs

* `lock/rocky-10.2/buildroots.json` (generated by `update-lock`, using the
  existing mock-emulating resolver that matched dnf5 on 260/260 SRPMs): per
  SRPM, the exact binary package set mock would install (chroot_setup_cmd +
  BuildRequires, weak deps off). Nix maps each name to `rocky<stage>.<name>`
  (merged groups resolved via `links.json`); the view layer is built from
  them. Provides resolution (`pkgconfig(zlib)`, `/usr/bin/foo`, rich deps) is
  done by the resolver offline, not in Nix.
* `requires.json` (from `deps.json.gz`, generated): per binary package the
  groups its Requires resolve to → default link inputs.
* build order: SRPM DAG from `buildroots.json`; SCCs (bootstrap cycles) use
  the previous stage for back edges (§6).

### 8.3 Evaluation at scale

* ~2200 rpmbuild + ~6900 link outputs in ~2300 link derivations (most SRPMs
  have one group; 74 SRPMs have ≥10 subpackages, the largest 378: texlive —
  Nix handles hundreds of outputs per derivation; glibc's link derivation in
  the spike has 224 outputs).
* `hydraJobs.rocky.<srpm>` = link derivation (all outputs) and
  `hydraJobs.rocky-rpmbuild.<srpm>`; `tools/build-jobs.sh` and nix-eval-jobs
  work unchanged (no IFD; all data from JSON lockfiles).
* A failed rpmbuild only blocks its dependents; the linker report
  (`$out/nix-support/…report.json`) is collected by a `checks.reloc-report`
  aggregate (counts per class, per package) — the dashboard of how generic the
  generic path is.

### 8.4 How often will specs break? (evidence)

* **Static scan** of 2185 of the 2217 Rocky 10.2 specs (`spec-scan.py`; specs
  from CentOS Stream `c10s` / Rocky `r10` git; 32 could not be fetched):
  * 14.1 % of specs show at least one hazard that the generic mechanisms handle:
    `%buildroot/usr` writes 3.6 %, `rm -rf %buildroot` 6.3 %, literal `/usr` in
    `%files` 1.6 %, raw configure 1.6 %, build-environment tools or dependencies
    reached through target macros 0.9 % + 3.2 %.
  * **1.6 % (34 specs)** need a per-package look: a literal `--prefix=/usr`,
    `PREFIX=/usr` or `CMAKE_INSTALL_PREFIX=/usr` (0.9 %, mostly cockpit-* and
    `%make_install PREFIX=/usr`), or `sed` of `/usr/...` into sources (0.6 %).
    The list is in `spec-scan.json`.
  * Build-system mix, which tells where generic helpers pay off: `%configure`
    29.6 %, `%make_install` 34.7 %, meson 10.0 %, cmake 5.0 %, pyproject 9.8 %,
    perl 12.6 %, java 7.6 %, go 1.4 %, rust 1.5 %; `/etc` in `%files` 18.9 %;
    systemd units 13.2 %.
* **Build spikes** (Appendix A):
  * 24 SRPMs, each built twice in the same stage0 chroot (stock macros and relocated).
  * **Relocation broke 0 of the 20 that build in stage0.** The other 4 fail identically
  without relocation: bash's build-cc vs gcc 14, cpio, json-c with nixpkgs cmake 4, and
  libxcrypt needing fipshmac.
  * glibc needed one per-package `config.site`, because its configure special-cases
  `prefix=/usr`.
  * The generic machinery itself needed **three fixes** that the spikes surfaced:
  `realias`, symlinks that cross subpackages, and store-by-pieces handling.
  * Extrapolating: per-package relocation work should be in the low single-digit
  percent of SRPMs. Most per-package work will remain what it is today: missing
  build dependencies and bootstrap order.

## 9. Implementation plan for the glibc milestone

Goal of the milestone: `rocky.glibc.*` — the Rocky glibc SRPM, relocated, one
output per subpackage, working from the store on any Nix machine, verified
against the official RPMs. Everything reuses `lib/` and `bootstrap/`
(the chroot runner, `mkRoot`, `mkBuildroot`, the glibc buildroot, the
parity/ABI/purity tools); stage 1 (§6) for glibc means "rpmbuild in today's
glibc buildroot".

Ordered steps (each one a commit with its check):

1. **`lib/reloc/`** — the relocation kit as files: `macros.reloc` (§1.2),
   `config.site`, `check-files`, `realias`, `nix-dynamic-linker.specs.in`
   (from the spike, cleaned up). `lib/reloc.nix`: `placeholderFor { srpm; evr;
   outputNames; }` (P, padded to the longest output name).
2. **`lib/default.nix: buildSrpm`** gains `relocate ? null` (`{ P; configSite;
   nixPatches; hooks; }`): binds the kit into the chroot
   (`/usr/lib/rpm/macros.d/macros.zz-el-nixos-reloc`, `/etc/el-nixos/*`),
   sets `CONFIG_SITE`, `EL_NIXOS_PREFIX`, defines `_el_nixos_prefix`, makes
   `/nix/store` a tmpfs with read-only binds of the input closure + the
   `P → /usr` alias (spike: `--tmpfs /nix/store` + per-path `--ro-bind` +
   `--symlink /usr P`; `--tmp-overlay` on `/nix/store` does not work in the
   sandbox), `%_binary_payload w3.zstdio`, and skips the "no /nix/store"
   purity scan in favour of the "only P" scan (P may appear, nothing else).
   Output: `RPMS/`, `manifest.json` (rpm -qp dumps), `logs`.
   Existing non-relocated builds are unchanged (`relocate = null`).
3. **`tools/reloc-link.py`** — the linker (spike `split.py` + fixes):
   extraction, path mapping, owner resolution with Requires gating,
   length-preserving rewrite incl. gzip members, relative/FHS symlink
   resolution across outputs, ELF interp/RUNPATH via patchelf, FHS
   text resolution against inputs, `nix-support/rocky-rpm.json`, report,
   checks (P left, foreign hashes vs allowed set, cycles, undeclared
   subpackage). Unit fixtures like `parity-selftest-*`
   (`reloc-selftest-{padding,cycle,crosslink,gzip}`).
4. **`lib/link.nix: mkLink { rpmbuild; srpm; groups; inputs; interp; policy }`**
   — the multi-output link derivation (`outputs` from the static subpackage
   list, `allowedReferences = outputs ++ inputs`).
5. **`packages/glibc.nix`**: add `reloc = { build; link; outputs; }` next to the
   existing build (the RPM pipeline stays as the reference):
   * `configSite = ./glibc.config.site` (4 lines: `libc_cv_slibdir`,
     `libc_cv_rtlddir`, `libc_cv_complocaledir`, `libc_cv_rootsbindir`);
   * `nixPatches = [ ld-so-cache-prefix.patch ld-so-preload.patch ]`
     (ported from nixpkgs, applied by `%__spec_prep_post`);
   * `softRefs.fhsFallback = [ "share/zoneinfo" ]`;
   * `unshipped` as today (+ glibc's debug output);
   * `allowUnresolvedNeeded = [ libgd.so.3 libpng16.so.16 libz.so.1 libselinux.so.1 ]`
     (memusagestat, makedb link stage0's nixpkgs `-devel` libs — documented
     gap until those SRPMs are built relocated);
   * bash/perl shebangs (ldd, mtrace, …) stay FHS in this milestone (no Rocky
     bash/perl yet) — listed.
6. **Attributes**: `legacyPackages.x86_64-linux.rocky.glibc` (all outputs),
   `rocky.<rpm name>` for the 224 subpackages, `rocky.rpmbuild.glibc`;
   `packages.x86_64-linux.rocky-glibc`; `hydraJobs.rocky.*`.
7. **Checks**:
   * `checks.rocky-glibc-closure`: every output's closure ⊆ glibc's outputs
     (no nixpkgs, no stage0, no P) — `exportReferencesGraph`.
   * `checks.rocky-glibc-files`: per subpackage, relative file list == the
     official RPM's (`/usr` stripped, `.build-id` and `%ghost` normalized).
   * `checks.rocky-glibc-abi`: `tools/abi-compare.py` on output trees vs the
     official payloads (it compares relative paths already; needs a
     path-prefix option) — dynsyms, versions, NEEDED, SONAME, headers; INTERP
     and RUNPATH checked separately to point at `rocky.glibc`.
   * `checks.rocky-glibc-content`: non-ELF files equal after mapping output
     paths back to `/usr`.
   * `checks.rocky-glibc-runtime`: `packages/glibc-runtime/test.sh` adapted to
     run store binaries directly (env: `LOCPATH`, `GCONV_PATH`), compiled test
     programs against `rocky.glibc-devel`/`-static` (stage0 gcc driver with
     `-nostdinc -isystem … -B …` as in the spike, later the relocated gcc), the
     same report as the RPM-root run modulo paths; all 885 locales through
     `LOCPATH`; 32-bit via `rocky.glibc32`.
8. **Docs**: `docs/relocation.md` (this design, trimmed), glibc.md section.

Then toward BaseOS: build the core set relocated in stage 1 (§6) in
BuildRequires order with the generic path (the spike says most need no
override), generate `subpackages.json` (`rpmspec -q`), `requires.json`,
`buildroots.json`, `links.json`; then stage 2.

**Risks**

| risk | mitigation |
|---|---|
| a format with checksums/compression the rewrite cannot see (jar/zip, squashfs, xz blobs other than MiniDebugInfo, `.mo` hash tables are fine) | post-check fails the build on any P left; per-format decompress-rewrite-recompress added as found; per-package `fhsFallback` |
| P padding visible to software that compares paths textually (e.g. `realpath` vs compiled string) | canonical forms differ only by `/` runs; affected packages get a per-package `prefixPad = "front"` (pad with leading `/`) or a rewrite to the unpadded path where length allows (text) |
| `patchelf --set-interpreter/--set-rpath` relayouts ELF files that cannot take it | interpreter injected at link time for everything built with `%build_ldflags`; patchelf only for leftovers; RUNPATH rewritten in place when it fits (libtool's `P/lib64` reserve) |
| static subpackage lists from repodata miss built-but-unshipped subpackages (8 of 20 spike SRPMs: `-static`) | `subpackages.json` from `rpmspec -q` at lock time; the linker fails on undeclared subpackages |
| specs whose configure special-cases `prefix=/usr` (glibc-like) | per-package config.site fragments; detectable from the linker report (files under `P/lib` that Rocky ships in `lib64`) |
| link plan (`links.json`) is data derived from builds | it is optional (Requires-derived default), committed, verified on every link build; dynamic derivations would remove it |
| relocated rpm/redhat-rpm-config in the stage-2 chroot | `RPM_CONFIGDIR=/usr/lib/rpm` + `fhsSelfRefs = keep`; tested by rebuilding `which` and the macro packages in stage 2 first |
| not spiked: the stage-2 view layer (link outputs projected into `/usr`) and the rpmdb built with `rpm --justdb --badreloc --relocate P=/usr` from transient RPMs | first task of stage 2; fallback: install the transient RPMs relocated (`--badreloc --relocate P=/usr`) for real into the view layer, i.e. today's `mkBuildroot` with one extra flag |
| P marker | the spike used `0`×32 and `x`-padding; `0000…` collided with printf's zero table in libc.so.6 (false fragment hit) — use a pseudo-random base32 H0 and a de Bruijn-style padding with unique 8-byte windows |

## Appendix A: spike results

### A.1 Relocated rpmbuild of 24 Rocky SRPMs (`spikes/reloc-spike.nix`)

Same stage0 buildroot for both columns: stage0-full, plus a layer of nixpkgs
build tools (cmake, meson, ninja, autotools, help2man, gtest, ...) and the cmake/meson
rpm macros taken from the Rocky cmake/meson SRPMs. `--nocheck --nodeps`.
"Relocated" means `reloc.macros` + `config.site` + `realias` + the P → `/usr` alias.

How to read the "files" column:
* "via /usr alias" counts payload paths that the spec or rpm named through
  `%buildroot/usr`. Almost all of them are debuginfo/debugsource
  (`find-debuginfo` hard-codes `/usr/lib/debug` and `/usr/src/debug`), rpm's
  `/usr/lib/.build-id` links, and redhat-rpm-config's `%{_rpmconfigdir}` files.
* "FHS" counts `/etc` and `/var` files.

How to read the "P refs" column, which counts occurrences of P in the analysis pass
(before Requires gating):
* `file` is a file of another subpackage;
* `missing` is a name below an owned dir (e.g. debuginfo symlinks);
* `bare` is the prefix itself (`.pc` `prefix=`).

| SRPM | control | relocated | subpkgs | files: P / via /usr alias / FHS | P refs (kinds) | cross-subpkg edges (analysis pass, no gating; debuginfo omitted) | SCC |
|---|---|---|---|---|---|---|---|
| attr | ok | ok | 6 | 41 / 76 / 1 | 15 (bare 2, missing 4, self 4, self-dir 5) | – | 0 |
| bash | FAIL | FAIL | | | | | |
| bzip2 | ok | ok | 7 | 40 / 46 / 0 | 7 (missing 3, self 3, self-dir 1) | – | 0 |
| cpio | FAIL | FAIL | | | | | |
| diffutils | ok | ok | 3 | 50 / 164 / 0 | 12 (missing 4, self 4, self-dir 4) | – | 0 |
| expat | ok | ok | 5 | 27 / 45 / 0 | 8 (bare 2, missing 2, self 2, self-dir 2) | – | 0 |
| gmp | ok | ok | 7 | 26 / 767 / 0 | 12 (bare 4, missing 2, self 2, self-dir 4) | – | 0 |
| gzip | ok | ok | 3 | 33 / 77 / 2 | 2 (missing 1, self 1) | – | 0 |
| json-c | FAIL | FAIL | | | | | |
| libffi | ok | ok | 4 | 17 / 34 / 0 | 6 (bare 2, missing 1, self 1, self-dir 2) | – | 0 |
| libsepol | ok | ok | 7 | 62 / 206 / 0 | 15 (missing 7, self 7, self-dir 1) | – | 0 |
| libunistring | ok | ok | 4 | 61 / 846 / 0 | 2 (missing 1, self 1) | – | 0 |
| libxcrypt | FAIL | FAIL | | | | | |
| libyaml | ok | ok | 4 | 111 / 28 / 0 | 6 (bare 2, missing 1, self 1, self-dir 2) | – | 0 |
| lz4 | ok | ok | 7 | 25 / 48 / 0 | 5 (bare 1, missing 2, self 2) | – | 0 |
| m4 | ok | ok | 3 | 40 / 205 / 0 | 3 (missing 1, self 1, self-dir 1) | – | 0 |
| ncurses | ok | ok | 11 | 4005 / 485 / 1 | 449 (bare 28, dir 3, file 302, missing 21, self 23, self-dir 46, split-dir 26) | ncurses-term→ncurses-base; ncurses→ncurses-base; ncurses-devel→ncurses-base; ncurses-libs→ncurses-c++-libs | 0 |
| popt | ok | ok | 5 | 47 / 23 / 1 | 6 (bare 2, missing 1, self 1, self-dir 2) | – | 0 |
| redhat-rpm-config | ok | ok | 1 | 6 / 36 / 0 | 0 () | – | 0 |
| rocky-release | ok | ok | 4 | 109 / 0 / 112 | 89 (self 89) | – | 0 |
| sed | ok | ok | 3 | 52 / 76 / 0 | 3 (missing 1, self 1, self-dir 1) | – | 0 |
| which | ok | ok | 3 | 10 / 25 / 2 | 2 (missing 1, self 1) | – | 0 |
| xz | ok | ok | 9 | 234 / 247 / 2 | 16 (bare 2, dir 1, missing 5, self 5, self-dir 3) | xz-lzma-compat→xz | 0 |
| zlib-ng | ok | ok | 8 | 27 / 123 / 0 | 16 (bare 4, file 6, missing 2, self 2, self-dir 2) | zlib-ng-compat-devel→zlib-ng-compat,zlib-ng-compat-static; zlib-ng-devel→zlib-ng | 0 |

Totals over the 20 relocated builds:
* 674 P occurrences, by context: 308 binary (compiled terminfo), 209 symlink, 125 text,
  19 gzip, 13 `elf:.rodata`.
* 0 reference cycles.
* 0 foreign `/nix/store` strings. Nothing compiled in a nixpkgs path, although the stage0
  chroot's tools are nixpkgs.
* FHS strings left in payloads:
  * 524 in ELF, almost all DWARF (`/usr/src/debug`, `/usr/include/...`);
  * 30 shebangs (`#!/usr/bin/sh`, `/usr/bin/bash`);
  * text references to other packages' files, e.g. xzgrep → grep's `/usr/libexec/grepconf.sh`;
  * text self-references, e.g. which2.sh → `/usr/bin/which`.

  These are exactly the inputs to the linker's FHS resolution (§2.6).

Failures in **both** columns (stage0 environment, not relocation):
* bash: `mkbuiltins.c` with gcc 14 (`too many arguments to function`), build-cc issue;
* cpio: `%build` error;
* json-c: nixpkgs cmake 4 rejects `cmake_minimum_required`;
* libxcrypt: `fipshmac: command not found`.

Built but not in `rpms.json` (needs `subpackages.json`, §2.7): bzip2-static,
expat-static, gmp-static, lz4-static, ncurses-static, popt-static, xz-static.

### A.2 glibc relocated (`spikes/reloc-spike.nix -A glibc.reloc`)

* **v1**, with no `config.site`:
  * `%prep` and `%build` (i686 + x86_64) succeed with `%_prefix = P`;
  * `%install` fails at `echo … > %{glibc_sysroot}/etc/ld.so.conf`. Because the prefix is
    not `/usr`, glibc's configure put `sysconfdir` under P, put libc in `P/lib` (not `lib64`),
    and installed i686 and x86_64 into the same directory.
* **v3**, with generic `config.site` + glibc's 4 cache variables
  (`libc_cv_slibdir`, `libc_cv_rtlddir`, `libc_cv_complocaledir`, `libc_cv_rootsbindir`):
  * `rpmbuild --rebuild` succeeds: **233 RPMs**, the same set as the FHS build;
  * NEVRs unchanged; payload 272 MB at zstd -3; about 17 minutes on a shared 16-CPU builder.
* The glibc spec's own hard-coded `/usr` all worked through the alias:
  `mkdir -p …/usr/$d`, the usrmove links, glibc32's `rm -rf etc var usr/bin …`,
  `hardlink -c …/usr/lib/locale`, `pushd …/usr/lib/locale`, the langpack file lists.
  So did `%files`, the brp scripts, find-debuginfo, debugsource and the build-id links.
* Analysis: 18,443 payload paths (9,246 via P, 9,189 via the alias, almost all
  debuginfo/debugsource; 8 in `/etc`, `/var`). 2,416 P occurrences, by context:
  * 435 `PT_INTERP`;
  * 450 `.rodata`;
  * 1,432 symlinks;
  * 69 non-ELF binary (archive members);
  * 28 text.

### A.3 glibc split (`spikes/split.nix -A glibc`, `glibc-split-report.json`)

* **Outputs:** one multi-output derivation with **224 outputs**: the 221 shipped
  subpackages plus glibc32, sysroot and compat-libpthread-nonshared. It runs in about 30 s.
* **Rewrites:**
  * 455 files;
  * 724 symlinks, 235 of them redirected to another output;
  * 8 overlapped tails and 3 fragments (store by pieces);
  * 4 RUNPATHs;
  * 55 soft references, e.g. glibc-static → `lib64/gconv` union,
    glibc-common → `lib/locale/locale-archive` (all-langpacks, not Required).
* **No cycles.**
  * One weak union edge was dropped: glibc → glibc-common for `lib/locale`/`share/locale`.
    Without the union rule it would have formed the cycle glibc ⇄ glibc-common.
  * Admitted weak edges: glibc-benchtests → glibc in glibc; ncurses-libs → ncurses-base
    (terminfo) in ncurses.
* **Hard edges** go only "down":
  * glibc-common, -devel, -utils, -benchtests → glibc;
  * langpacks → glibc-common;
  * glibc main → nothing.
* **Leftovers and known gaps:**
  * One fragment is left, in `sysroot-x86_64-el10-glibc`'s copy of libc.so.6. It is reported,
    and needs the distinctive marker (§2.3 (c)).
  * Unresolved `DT_NEEDED`: `libgd.so.3`, `libpng16.so.16`, `libz.so.1`, `libselinux.so.1`
    (memusagestat, makedb: stage0 links nixpkgs `-devel` libraries; documented gap).
    The gconv helper libraries (`libGB.so` …) show up too, only because the prototype does
    not evaluate `$ORIGIN`.
* **Relative file lists vs the official RPMs:** all **221/221** shipped subpackages are
  identical. The comparison ignores directories, `%ghost` and `/usr/lib/.build-id`.
* **ABI:** `readelf --dyn-syms` (name, version, type, binding, visibility, size) and
  `readelf -V` are identical for libc.so.6 (3,162 symbol lines), libm.so.6, ld.so and
  libresolv.so.2.

### A.4 Running from the store (`spikes/test.nix`, `runtime-report.txt`)

Plain Nix sandbox, with no `/usr`, no `/lib64` and no chroot:
* **The dynamic linker:** `ld.so --version` works, and `ld.so --list` resolves libc
  through the padded system dir:
  `libc.so.6 => /nix/store/0myw…-glibc-2.39-142.el10_2//////////////////////////////////lib64/libc.so.6`.
* **Locales, iconv, NSS:**
  * `LOCPATH=<langpack-en>/lib/locale:<minimal-langpack>/lib/locale` with
    `LC_ALL=en_US.UTF-8`: `locale -k LC_NUMERIC` → `thousands_sep=","`;
  * `iconv` UTF-8→ISO-8859-1 works;
  * UTF-8→IBM037 fails without `GCONV_PATH` (the module is in gconv-extra, as designed)
    and works with `GCONV_PATH=<glibc>/lib64/gconv:<gconv-extra>/lib64/gconv`;
  * `getent passwd root` and `getconf GNU_LIBC_VERSION` work.
* **Other packages:** which, xz (RUNPATH → xz-libs output), gzip, sed, m4 and diffutils work.
* **ldd** fails with `/usr/bin/bash: bad interpreter`, as expected before Rocky bash exists.
  Run under a bash, it lists xz's libraries from their outputs.
* **Compiling against the relocated glibc:**
  * `hello.c`, compiled with the stage0 gcc driver against `glibc-devel`
    (`-nostdinc -isystem … -B<devel>/lib64/`, the `libc.so` linker script rewritten across
    outputs, `-Wl,--dynamic-linker=<glibc>/…`, `-static-libgcc`), runs and prints
    `1,234,567.89` in en_US;
  * `-static` against glibc-static works too;
  * a dynamic link needs `-static-libgcc` until gcc itself is relocated: the stage0 gcc's
    `libgcc_s.so` points at `/lib64`.
* **Closures** (`exportReferencesGraph`):
  * `glibc` = {glibc};
  * `glibc-common` = {glibc, glibc-common};
  * `glibc-langpack-en` = {glibc, common, langpack-en};
  * `xz` = {glibc, xz, xz-libs};
  * `which` = {glibc, which}.

  Only Rocky-built outputs, and no all-langpacks anywhere.

### A.5 Store by pieces (`spikes/piece-test.*`)

`strcpy`/`memcpy`/`return` of a path literal, compiled with Rocky's `%optflags`
(`-O2 -march=x86-64-v3 …`) by the stage0 gcc 14.3.1:
* For lengths 51 through 400 the object holds a separate piecewise copy: chunks whose
  16-byte head and 12-byte tail occur apart from the contiguous literal.
* At 600 it does not.

So any binary path rewriting must handle split chunks (§2.3).

### A.6 Requires graph of the 10.2 lock (`req-graph.py`)

* Binary level: 80 SCCs. The largest has 212 nodes (glibc and its langpacks, glibc-common,
  bash, ncurses-libs). 26 SCCs span several SRPMs.
* SRPM level: one SCC of 773 SRPMs.
* 53 of the 1,049 multi-binary SRPMs have an intra-SRPM Requires cycle.

### A.7 Macro audit (`spikes/macro-audit.*`)

652 macros, each evaluated with the stock `%_prefix` and with only `%_prefix` changed:
* 46 follow `%_prefix`. Two of them are build tools that must be pinned:
  `%__perl` and `%__plugindir`/`%__transaction_*`.
* 161 `/usr` values do not follow it. About 10 of those are install destinations that must
  be relocated explicitly (§1.1).
