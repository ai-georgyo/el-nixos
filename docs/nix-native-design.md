# el-nixos nix-native: Rocky specs → composable, relocated Nix store paths

**Final synthesized design** (base: *nixpkgs-faithful*, the winner of 2 of 3 judges;
grafts from *spec-generic* and *bootstrap-purity*; every judge-reported fatal flaw
addressed in §0.3). Project `el-nixos`, branch `glibc-bootstrap`, Rocky 10.2.

Evidence labels: **[NF-Sx]** = nixpkgs-faithful spikes
(`docs/research/nix-native/spikes-nixpkgs-faithful/`), **[SG-…]** = spec-generic spikes
(`docs/research/nix-native/spikes-spec-generic/`), **[BP-n]** = bootstrap-purity spikes
(`docs/research/nix-native/spikes-bootstrap-purity/`), **[F-n]** = new measurements made for this
synthesis (`docs/research/nix-native/`). The repository was not modified.

**Revision 2 (2026-10-18, after the foundation work packages, merge c700802).**
Every design correction measured by the foundation work packages is folded
in below, in place, marked **Correction [ref]** (the earlier text was wrong)
or **Update [ref]** (a measured result or refinement; the earlier text still
holds). Corrections from experiments override the original text. Nothing
here is new measurement except **[D-1]**. Additional evidence labels:

* **[E1]…[E6]**: `docs/research/nix-native/experiments/E1.md` … `E6.md`
  (the §9 experiments);
* **[RC-n]**: `experiments/rpmconfig.md`, finding *n* of "Macro decisions
  re-verified";
* **[LK]**: `experiments/lock.md` (WP1); **[NM]**, **[NM-fix]**:
  `experiments/names.md`, `names-fix.md` (WP6a);
* **[R1]…[R16]**: the partition rule changes of `experiments/E3.md`
  (implemented in `tools/rocky-partition`, schema in
  `tools/rocky-partition/PLAN.md`);
* **[HO-x]**: `docs/research/nix-native/foundation-handoff.md`, section *x*
  (cc, shim, partition, glibc, lock, rpmconfig, purity, names);
* **[D-1]**: measured while writing revision 2: `lib/rocky/config.site` as
  committed in b9fdc83, run with `prefix=/nix/store/x runstatedir=/run`,
  exits 1 (§1.3).

The changelog is §14. The user/developer guide is `docs/nix-native.md`.

---------------------------------------------------------------------------

## 0. Decisions

### 0.1 The design on one page

```
rocky.<srpm>            one plain multi-output derivation per SRPM (mkRpmPackage)
  outputs (static)      one per subpackage, from lock/rocky-10.2/subpackages.json (rpmspec -q,
                        computed by the lock generator) minus static merges; names nixpkgs-style:
                        prefix subpackage -> out, -devel -> dev, -libs -> lib, all debug -> debug,
                        <srpm>-X -> X, others verbatim; [^A-Za-z0-9_] -> _
  compile prefix        %_prefix = $out  (a REAL output path, known before the build; no placeholder,
                        so binaries are never rewritten)
  build env             nixpkgs generic stdenv + nixpkgs cc-wrapper/bintools-wrapper (sources reused,
                        instantiated over Rocky-built tools from S2 on), rpmbuild -bb --nodeps inside
                        a bwrap "tool shim": /usr = view of DECLARED inputs only (read-only overlayfs
                        dirs, not a symlink farm [E2]), $out = the same view (self-prefix alias),
                        /usr/lib/rpm = assembled rpm config (relocation macros appended to its
                        redhat/macros [RC-1]); rpmbuild runs with SOURCE_DATE_EPOCH unset [RC-12]
  partition             rocky-partition (Python), in the same derivation, after rpmbuild:
                        transient RPM headers -> move files into outputs -> fix symlinks -> rewrite
                        TEXT refs -> recompute RUNPATH from DT_NEEDED -> Requires-gated forwarding
                        stubs for remaining binary refs -> hidden/pieced-ref registration ->
                        output graph + SCC check -> metadata, setup hooks
  fixup                 nixpkgs patchShebangs --host; no strip (rpm did it), no moveLib64/moveSbin
  enforcement           outputChecks.<o>.allowedRequisites (inductive), nested/compressed reference
                        scan, eval-time build-purity assertion (S3), global closure audit
  late binding          rocky.<srpm> exposes "bound" outputs: a cheap copy derivation that rebinds
                        shebangs/symlinks/text/RUNPATH of a late set (+ its transitive sibling
                        referrers) to packages built later (bash, perl, gd ...); ELF contents never
```

User-facing: `rocky.glibc` (multi-output; `rocky.glibc.dev`, `rocky.glibc.common`,
`rocky.glibc.langpack_de`), `rocky.rpm."glibc-devel"` (alias by RPM name),
store paths `/nix/store/<h>-glibc-2.39-142.el10_2[-<output>]/{bin,sbin,lib64,include,share,…}`,
composable with `buildInputs`, `buildEnv`, `mkShell`; final closures contain only
Rocky-built outputs.

### 0.2 Contradictions between the designs, resolved

| # | question | nixpkgs-faithful | spec-generic | bootstrap-purity | **decision** | reason |
|---|---|---|---|---|---|---|
| 1 | how references survive moves | compile with `$out`, move, never rewrite binaries | placeholder P, slash-padded binary rewrite + fragment heuristics | placeholder P, slash-padded whole-P rewrite | **compile with `$out`, never rewrite ELF contents** | gcc store-by-pieces is real in Rocky glibc ([SG], re-measured [F-2]: ld.so, ldconfig, localedef, locale carry 32-byte vector chunks holding `/nix/store/<partial hash>`); any P rewrite can silently corrupt them; spec-generic's own report still has a leftover fragment; padding is user-visible in `ld.so --list` |
| 2 | build-time view of deps | `/usr/bin` farm only, no `/usr/include`/`/usr/lib64` | full FHS chroot of stage outputs, P ≡ `/usr` | store-only root, no `/usr` | **shim `/usr` = view of declared inputs only (Correction [E2]: read-only overlayfs of the inputs' dirs, `bin` alone a symlink farm); same view mounted read-only at `$out` during rpmbuild** | keeps "deps only via declared inputs" (faithful/purity) and gains spec-generic's "build env through target macros works unmodified" (~4 % of specs, glibc's `--with-headers=%{_prefix}/include`); no rpmdb needed |
| 3 | rpmbuild and partition: one or two derivations | one | two (rpmbuild, link) | one | **one** | with no-rewrite, the compile prefix must be an output of the compiling derivation; dev loop mitigated (§11.4) |
| 4 | output names | nixpkgs (`dev`, `lib`, `out`) | suffix verbatim (`devel`) | suffix verbatim | **nixpkgs for out/dev/lib/debug, suffix otherwise** + `rocky.rpm.<rpmname>` aliases | `lib.getDev`, `multiple-outputs.sh`, cc-wrapper `chooseDevOutputs` work unchanged (judge 3) |
| 5 | subpackage list | `bySrpm` + hand list | `rpmspec -q` (8/20 SRPMs build unpublished `-static`) | `bySrpm` + known | **`rpmspec -q` in the lock generator** | static, no IFD, no hand list |
| 6 | cross-output binary refs into non-prefix outputs | error → layout/merge/search path | rewrite (or silently to self for unions) | dirOwner/noRef declarations | **automatic: RUNPATH recompute (libs) + Requires-gated forwarding stubs (files/dirs, only if acyclic) + search paths; error only when none applies** | fixes judge 2/3 genericity flaw (`foo`/`foo-libs`, `-common` data) without rewriting and without silent breakage |
| 7 | union dirs | search paths, explicit | union rule, rewrite to self | dirOwner | **search paths + explicit acks; never rewrite to self** | silent dangling paths rejected (judge 1) |
| 8 | late binding | copy + patchShebangs on named outputs | separate link parts | hash substitution of late outputs only | **bind derivation over late set ∪ transitive sibling referrers; rewrites text, symlinks, RUNPATH only; ELF-content refs into the late set are a build error** | fixes both judges' flaw (langpacks → common keep raw common in closure) |
| 9 | wrapper | nixpkgs cc-wrapper | view + specs fragment + patchelf | own 150-line wrapper | **nixpkgs cc-wrapper/bintools-wrapper sources in every stage**, instantiated over Rocky stdenvNoCC from S2 on; eval-time assertion catches leaking nixpkgs derivations | spiked end-to-end [NF-S2,S3,S6]; nixpkgs-composition native |
| 10 | stages | B0,R1–R4,final | stage 1–3 | S0–S3 (+S4 check) | **S0 (exists), S1 boot toolchain, S2 boot tools, S3 final (glibc → gcc → switch → all), S4 fixpoint check** | merges faithful's toolchain staging with purity's build-pure final stage |
| 11 | FHS strings in outputs | fail | report | fail (S2/S3 build env) | **shebangs fail unless bound/allowlisted; other FHS strings reported, strict mode per package** | thousands of legitimate FHS literals (`_CS_PATH`, `/etc/…`) at 2200-SRPM scale |
| 12 | glibc patches | P1 ld.so.cache, P2 LOCALE_ARCHIVE (P3 optional) | cache + preload (+ archive optional) | cache + archive | **P1 + P2 + P3 (`/etc/ld.so.preload` → `/etc/ld-nix.so.preload`)** | P3 has the same justification as P1 (a host file injecting host DSOs into Rocky processes); same names as nixpkgs for NixOS interop |
| 13 | DWARF store paths | `-ffile-prefix-map` (unspiked) | n/a | prefix map | **`-ffile-prefix-map=<root>=/usr` for every input (`NIX_ROCKY_MAP_ROOTS`), every store path on the command line, the symlink targets of store system include dirs, the own outputs incl. `$out` while the view is mounted, and the gcc prefix; reproducible-builds hook OFF** (Update [E1], [E2] #2) | [F-1]: S3 leaked `-frandom-seed=nncpaslng9` into DW_AT_producer; E1 validates the map |
| 14 | build order at scale | stages + bconds | stages | FAS `order.json`, second pass for library back edges | **bootstrap-purity's FAS + `checks.order`** | quantified (926 → 225 library-only SCC, 144 SRPMs need a second pass); Update [LK]: with unshipped providers the largest SCC is 949, 782 back edges, 150 second-pass SRPMs (`checks.nn-order`) |

Revision-2 notes on this table:

* #1 holds: E1 rebuilt the relocated glibc through the S1 wrapper with the
  prefix map; it references only itself and is bit-reproducible
  (`nix build --rebuild`) [E1]. E4 found no split-hash pieces in loaded
  sections; the store-by-pieces strings are 7 truncated copies of the prefix
  whose hash is whole [E4] (§2.8).
* #2: Correction [E2] #1: glibc's configure refuses a symlinked
  `$prefix/include/{net,scsi}`, so the view's `include lib lib64 libexec
  share` are read-only overlayfs mounts (first input on top; one input =
  plain bind). E2 confirmed `prefixView = true` as the default: glibc
  builds from the unmodified spec (no `--with-headers` substitution), file
  lists identical, 0 differing loaded sections, 8 DWARF-only files [E2].
* #4: Update [NM]: names that are not shell identifiers (`100dpi`) or are
  reserved (`src`, `system`, `all`, `debug`, …) fall back to the full
  sanitized subpackage name (§2.12).
* #5: Update [LK]: `rpmspec -q --builtrpms` (a `%package` without `%files`
  is not built) with `%distcore`, not `%dist`, for all 2217 SRPMs.
* #6: Update [E3]: the RUNPATH recompute removed every `foo`/`foo-libs`
  override (xz, ncurses, krb5); the gated forwarding stubs were created
  **0 times** in xz, expat, libxcrypt, ncurses, krb5, pixman and the glibc
  replay. The rule stays (tested by `checks.nn-partition-selftest`); the
  `-common` data class was solved by the prefix choice (ncurses → base), not
  by stubs.

### 0.3 Every fatal flaw / gap raised by a judge, and its fix

| flaw (judge) | fix in this design | where |
|---|---|---|
| memusagestat/makedb NEED libgd/libpng/libz/libselinux, no RUNPATH (`NIX_DONT_SET_RPATH=1` for all of glibc) (J1) | generic RUNPATH recompute pass for every ELF except `noPatchelf` globs (glibc: ld.so, libc, libs in system dir); unresolved NEEDED of not-yet-Rocky libs → `lateBind` of the `utils`/`nss_db` outputs (+ referrers) | §2.6, §2.9, §4.6 |
| lateShebangs vs langpacks → common symlinks (J1, J3 for BP) | bind derivation covers transitive sibling referrers; only text/symlink/RUNPATH rewriting | §2.9 |
| DWARF prefix-map not spiked; S3 closure pulls stage0/nixpkgs (J1) | E1 experiment as WP0a; hard enforcement by allowedRequisites + nested scan; random-seed hook off | §5.1, §9 |
| prefix-relative software split across outputs (gcc driver/cc1, python, perl) (J1 all designs) | bare-prefix and union-dir references from non-prefix outputs are errors (BP rule); exe-relative lookups covered by forwarding stubs when acyclic, else merge; known class listed (gcc, python3.12, perl, ruby, …) | §2.7, §8.1 |
| every compiled-in ref into a non-main output = manual work (J2, J3) | RUNPATH recompute + Requires-gated forwarding stubs (automatic, acyclic only) | §2.6–2.7 |
| SRPMs without eponymous subpackage (krb5) (J2) | prefix subpackage chosen by rule (eponymous > `-libs` > most `/usr` files in official filelists), named `out` | §3.1 |
| unpublished subpackages / hand lists (J2) | `subpackages.json` from `rpmspec -q` | §3.2 |
| no `/usr` view → per-package substitutions (J2) | declared-input `/usr` view + `$out` self-prefix alias | §1.5 |
| build purity enforced only at the end (J3) | eval-time string-context assertion in S3/S4 | §7.3 |
| two libgcc_s copies; glibc → previous-stage libgcc pulls previous glibc (J3 + own finding) | `libgcc-for-glibc`: RUNPATH-stripped copy of the previous stage's `libgcc_s.so.1` (references nothing); loader dedups by soname | §4.5 |
| pieced (store-by-pieces) references hide edges from Nix's scanner | scan in loaded sections for windows holding ≥ 6 bytes of the prefix *hash* (Correction [R1], [E4]: path windows give false positives on every ordinary `$out` reference); hidden references registered via `nix-support/hidden-references`; acks (`opaqueRefs`) for non-prefix outputs. Measured on glibc: the hash is always whole, so nothing is hidden from Nix; only the path behind 5 pieces outside `out` is opaque [E4] | §2.8 |
| (revision 2) a library reached only through the view links and runs inside the shim but fails outside it [E2] | library rule: every declared view input that ships shared libraries is also a cc-wrapper input (WP6), plus the NEEDED guard in the partitioner (`unresolved-needed`) | §1.5, §2.6 |
| (revision 2) RUNPATH recompute invalidates FIPS integrity data [E3] | fipscheck `.hmac` companions verified and recomputed; embedded HMACs refuse the patch (`integrity-runpath`, ack `integrityOk`) [R14] | §2.6 |


### 0.4 Decisions on the open questions (2026-10-18, project defaults)

1. **M1 = `rockyBoot.s1.glibc`**: built by the stage0 gcc, verified against the
   official RPMs, closure = own outputs + the RPATH-stripped `libgccForGlibc`
   (named S1 exception). The strictly Rocky-only closure is **M2** (`rocky.glibc`, S3a).
2. **Nix-side patches stay minimal**: glibc P1/P2/P3 and gcc `no-sys-dirs`, each a
   named, allowlisted parity difference. Anything else needs a documented reason.
3. **Output names**: nixpkgs-style `out`/`dev`/`lib`/`debug`, suffix otherwise,
   plus `rocky.rpm."<rpm-name>"` aliases.
4. **Unshipped subpackages** (glibc32, sysroot, `-static`) are real outputs of the
   derivation; `rpm.*` aliases exist only for shipped RPMs; unshipped ones are
   reachable as outputs of `rocky.<srpm>` and flagged in `passthru.unshipped`.
5. **/etc, /var, scriptlets**: recorded as metadata only; NixOS modules / image
   tooling that materialise them are out of scope for M1/M2.
6. **libc message catalogs** untranslated unless composed via profiles (as nixpkgs).

Open decision recorded in revision 2 (not yet taken): P2 keeps nixpkgs' two
host fallbacks for the locale archive (`/run/current-system/sw/lib/locale/locale-archive`,
`/usr/lib/locale/locale-archive`); dropping them would deviate from nixpkgs
[HO-glibc] (§4.3).

---------------------------------------------------------------------------

## 1. Macro relocation (Q1)

### 1.1 Facts the macro file rests on

* [NF-S1]/[SG macro audit, 652 macros]: overriding `%_prefix` moves `_exec_prefix
  _bindir _sbindir _libdir _libexecdir _datadir _includedir _infodir _mandir
  _defaultdocdir`, **not** `_sysconfdir _localstatedir _sharedstatedir _rundir
  _oldincludedir _sysusersdir _usrsrc _rpmconfigdir _rpmmacrodir _rpmluadir
  _fontbasedir`; and it wrongly moves `__perl` (`%{_bindir}/perl`) and
  `__plugindir` (`%{_libdir}/rpm-plugins`, used by `%__transaction_*`).
* Tool macros (`__make __awk __cp __find_debuginfo __python3 …`) and
  redhat-rpm-config script/spec references are literal `/usr/bin/…`,
  `/usr/lib/rpm/…` (87 literal `/usr` in the macro files [BP-4]).
* `rpmbuild --define` drops everything after a raw newline [BP-9] → multi-line
  overrides go into a macro *file*.
* `brp-compress` takes the prefix as `$1` (default `/usr`); with the fold
  symlink it already works ([F-3]: S3's `share/info/*.gz` exist), passing
  `%{_prefix}` makes it independent of the symlink.
* **Correction [E2] #4, [RC-1]: macro load order.** rpm 4.19's macro path is
  `macros : macros.d/macros.* : platform/%{_target}/macros : fileattrs/*.attr
  : redhat/macros : /etc/rpm/macros.* : …`. The platform file redefines
  `%_prefix %_exec_prefix %_bindir %_libdir %_includedir %_sysconfdir …
  %__spec_install_pre %__os_install_post %__spec_install_post`, and
  redhat/macros redefines `%__spec_install_pre`, `%__brp_compress`,
  `%_binary_payload`, `%_annobin_gcc_plugin`. A file in `macros.d/` is read
  but loses to both (measured: `nn.toolShim.e2.macroPrecedence`, negative
  control in `checks.nn-rpm-config`).
* **[E2] #4:** `rpmbuild --load FILE` is dropped when `--target` re-reads the
  configuration (seen with sed).
* **[RC-5]:** `%_rpmconfigdir` is `%{getconfdir}` (`/usr/lib/rpm` in the shim,
  `$RPM_CONFIGDIR` outside); it must not be redefined.
* **Correction [RC-8]: systemd-rpm-macros does not derive its directories
  from `%_prefix`.** Rocky's `macros.systemd` (257-23.el10_2.2.rocky.0.1) has
  21 literal `/usr` directory macros (`%_unitdir /usr/lib/systemd/system`, …).
* **[RC-12]: `SOURCE_DATE_EPOCH`.** rpm sets it from the changelog only when it
  is unset; the Nix stdenv exports `315532800`, which then wins (BUILDTIME and
  mtimes 1980). A macro file cannot unset it: rpmbuild must run with
  `env -u SOURCE_DATE_EPOCH`.
* **[LK], [RC-4]: `%dist`.** A fixed `%dist .el10_2` is wrong for 1906 of 2217
  SRPMs (`.el10`); overriding `%dist` at all drops `%forgemeta`'s
  `.git<commit>` `%distprefix` (ksc: `1.12-7.el10` instead of
  `1.12-7.git869a25c.el10`). Set `%distcore` (per SRPM, from
  `lib/srpm.nix distOf`).

### 1.2 `lib/rocky/rpm/macros.nix-reloc` (appended to the instantiated config's `redhat/macros`)

**Correction [RC-1], [E2] #4:** not installed in `macros.d/` (it would be
overridden, §1.1). `${rpmConfig}/nix/instantiate DIR --prefix $out --buildtop
$NIX_BUILD_TOP --ncpus $NIX_BUILD_CORES [--dist <distOf srpm>] [--macro-dir
D]…` makes a writable copy of the rpm config, copies `$NIX_RPM_MACRO_DIRS` and
`--macro-dir` into `macros.d` (a differing same-named file is an error),
substitutes `@PREFIX@`, `@BUILDTOP@`, `@NCPUS@`, `@DIST@` (empty `--dist`
drops the `%distcore` line, leaving `.el10`), keeps `# @@if <path>` blocks
only when `<path>` exists in the config, and **appends** the result to the
config's `redhat/macros`, the last macro file inside the config dir [RC].
The committed file (`lib/rocky/rpm/macros.nix-reloc`, its header lists every
deviation) is authoritative; the block below is its current content,
abbreviated.

```
# ---- install / compile prefix: the derivation's main output ----------------
%_prefix                 @PREFIX@
%_exec_prefix            %{_prefix}
%_usr                    %{_prefix}
%_prefix_rel             %{lua:print((rpm.expand('%{_prefix}'):gsub('^/+', '')))}
%_lib                    lib64
# derived (unchanged definitions, listed for clarity):
#   _bindir _sbindir _libdir _libexecdir _datadir _includedir _infodir _mandir
#   _defaultdocdir _docdir _defaultlicensedir _licensedir
%_oldincludedir          %{_includedir}
%_sysusersdir            %{_prefix}/lib/sysusers.d
%_rpmmacrodir            %{_prefix}/lib/rpm/macros.d
%rpmmacrodir             %{_rpmmacrodir}
%_rpmluadir              %{_prefix}/lib/rpm/lua
%_fontbasedir            %{_datadir}/fonts
%_fontconfig_templatedir %{_datadir}/fontconfig/conf.avail
%_pam_moduledir          %{_libdir}/security
%gopath                  %{_datadir}/gocode
# Correction [RC-8]: systemd-rpm-macros' 21 directory macros are literal /usr in
# Rocky; overridden only when macros.d/macros.systemd is in the config (without
# it Rocky leaves %_unitdir undefined and specs test %{?_unitdir}):
# @@if macros.d/macros.systemd
%_systemd_util_dir       %{_prefix}/lib/systemd
%_unitdir                %{_prefix}/lib/systemd/system
%_udevrulesdir           %{_prefix}/lib/udev/rules.d
%_tmpfilesdir            %{_prefix}/lib/tmpfiles.d
%_user_tmpfilesdir       %{_datadir}/user-tmpfiles.d
#   ... (21 in total; scriptlet bodies such as %systemd_post keep /usr: run-time paths)
# @@endif

# ---- runtime FHS: stays FHS (defaults installed into <output>/etc etc.) ------
%_sysconfdir             /etc
%_localstatedir          /var
%_sharedstatedir         /var/lib
%_rundir                 /run
%_runstatedir            /run
%_initddir               %{_sysconfdir}/rc.d/init.d
%_pam_confdir            %{_sysconfdir}/pam.d
%_usrsrc                 /usr/src
#   (debugedit maps comp dirs to %_usrsrc/debug/<nvra>; FHS keeps store paths out
#    of DWARF; sources land in the debug output under src/debug)
%_dbpath                 /usr/lib/sysimage/rpm      # [RC-6]: would follow %_usr into $out

# ---- engine/tool macros that must NOT follow the prefix ---------------------
# (%_rpmconfigdir is NOT redefined [RC-5]: it stays %{getconfdir})
%__perl                  /usr/bin/perl
%__plugindir             /usr/lib64/rpm-plugins
%_buildshell             /bin/sh

# ---- build plumbing ----------------------------------------------------------
%_topdir                 @BUILDTOP@/rpmbuild
%_tmppath                @BUILDTOP@/tmp
# [RC-11]: rpm's %__smp_use_ncpus with %{getncpus} -> @NCPUS@ (keeps %_smp_ncpus_max,
# %constrain_build and %_smp_build_nthreads working; a fixed %_smp_build_ncpus did not)
%__smp_use_ncpus() ...
%_binary_payload         w0.ufdio
%_source_payload         w0.ufdio
%distcore                @DIST@                     # Correction [RC-4], [LK]: not %dist
%_buildhost              el-nixos.localdomain
# effective only with SOURCE_DATE_EPOCH unset in rpmbuild's environment [RC-12]
%source_date_epoch_from_changelog   1
%use_source_date_epoch_as_buildtime 1
%clamp_mtime_to_source_date_epoch   1
%__brp_compress          %{_rpmconfigdir}/brp-compress %{_prefix}
%__check_files           %{_rpmconfigdir}/nix/check-files %{buildroot} %{_prefix}
# Correction [RC-2]: prep-hooks BEFORE %{___build_post}, which ends in `exit $RPM_EC`
%__spec_prep_post        %{_rpmconfigdir}/nix/prep-hooks "%{_builddir}/%{?buildsubdir}"\
%{___build_post}
%__spec_install_pre      %{___build_pre}\
    [ "$RPM_BUILD_ROOT" != "/" ] && rm -rf "${RPM_BUILD_ROOT}"\
    mkdir -p "`dirname "$RPM_BUILD_ROOT"`"\
    mkdir "$RPM_BUILD_ROOT"\
    %{_rpmconfigdir}/nix/fold-usr "$RPM_BUILD_ROOT" "%{_prefix}"\
    %{?_auto_set_build_flags:%{set_build_flags}}\
%{nil}
# Correction [RC-3]: set_build_flags kept (redhat-rpm-config has it)
%__spec_install_post     %{_rpmconfigdir}/nix/fold-usr "$RPM_BUILD_ROOT" "%{_prefix}"\
    %{?__debug_package:%{__debug_install_post}}\
    %{__arch_install_post}\
    %{__os_install_post}\
%{nil}
# annobin: no plugin until the stage has a Rocky annobin for its gcc (as stage0)
# Correction [RC-7]: `%_annotated_build 0` dropped (redhat-rpm-config tests definedness only)
%_annobin_gcc_plugin     %{nil}
```

Per-package `defines` are appended as `--define` (single-line values only).

Update [RC-9], [RC-10]: the audit confirms the `%__perl` pin is needed
(perl-srpm-macros: `%{_bindir}/perl`), `%_fontbasedir`,
`%_fontconfig_templatedir`, `%gopath` overrides are needed (literal in
fonts-/go-srpm-macros), and the dependency generators' path regexes
(`%__pkgconfig_path`, `%__desktop_path`, …) follow the prefix. Not verified:
generators of macro packages that are not in stage0 (perl-, python-rpm-generators,
rust-srpm-macros); `%__kmod_path ^/lib/modules` is literal (kernel only).

**Correction [E2] #5, [E3] hazard 2, [HO-shim]: `QA_RPATHS`.** redhat's
`check-rpaths` (`%__arch_install_post`) calls every absolute RUNPATH outside
`/lib*`, `/usr/lib*` "invalid" (0x0002) and fails the build: every store
RUNPATH, and the Rocky toolchain's own self-rpath. rpmbuild needs
`QA_RPATHS=0x0002` in its environment (or `%__brp_check_rpaths %{nil}`). The
experiment trees set it as env; `macros.nix-reloc` does not, so WP6 must
(§5.5 corrected).

Helper scripts in `/usr/lib/rpm/nix/` (part of the rpm config derivation,
`lib/rocky/rpm/nix-scripts/`):

* **`fold-usr BR P`** (graft of [SG realias] + [NF-S3] relative link): `mkdir -p
  $BR$P`; if `$BR/usr` is a real directory (spec did `rm -rf %buildroot`, 6.3 % of
  specs [SG scan]) merge it into `$BR$P` (error on same-path conflicts), then
  `ln -s "${P#/}" "$BR/usr"` (relative: absolute links dangle inside BUILDROOT
  [NF-S3 #2]). `/etc`, `/var` stay real BUILDROOT dirs (glibc's i686 cleanup
  deletes `etc var`; a link would break the later `echo > etc/ld.so.conf`
  [NF-S3]). Usrmerge top-level links (`/bin`, `/sbin`, `/lib64`) are *not*
  created; specs that create them (glibc usrmove dance) do so through `usr`.
* **`check-files BR P`**: rpm's check-files with both sides canonicalised
  (`$BR$P/x` ≡ `$BR/usr/x`; the `usr` link itself excluded) ([NF-S3]
  check-files-nix; [BP-9] measured 18 926 false "unpackaged" entries without it).
  The check stays on (`_unpackaged_files_terminate_build 1`).
  Update [E3] hazard 4: specs that delete every non-directory of the
  buildroot (libxcrypt `find %{buildroot} -not -type d -delete`) also delete
  the fold link, and libxcrypt redefines `__spec_install_post`, so the
  second fold never runs; find-debuginfo then writes a real `BR/usr`. The
  committed `check-files` maps on-disk `BR/usr/x` to `BR/P/x` whether `usr`
  is a link or a real directory, and the partitioner reads both forms.
* **`prep-hooks DIR`**: applies `$NIX_PREP_PATCHES` (`patch -p1 --forward`,
  a patch that does not apply is an error) and runs the **file**
  `$NIX_PREP_SCRIPT` (`bash -e`) in the unpacked source — Nix-side patches
  without editing the spec's patch list (Update [RC]: `NIX_PREP_SCRIPT` is a
  path, not inline text).
* **`instantiate`**: the per-build helper described above.

The scripts use `#!/usr/bin/bash` / `#!/usr/bin/sh`, so the shim's view must
provide bash and sh, plus patch, find, sed, diff, mktemp, mv; brp-ldconfig
needs Rocky's (static) `/sbin/ldconfig`: nixpkgs' patched ldconfig fails with
`-r BUILDROOT` [HO-rpmconfig], [E3] hazard 3.

### 1.3 `CONFIG_SITE` (generic, `lib/rocky/config.site`)

Host-aware because glibc (and every multilib spec) configures i686 and x86_64
in one `%build` [NF-S3 #3, BP-9]; `sysconfdir`/`localstatedir` must be set as
autoconf variables, not cache vars [BP-9].

```sh
# el-nixos: give store prefixes the defaults distros give /usr
case "$prefix" in /nix/store/*)
  case "${host_alias:-${build_alias:-x86_64}}" in
    x86_64*|aarch64*|ppc64*|s390x*) el_nixos_lib=lib64 ;;
    *) el_nixos_lib=lib ;;
  esac
  test "$libdir"         = '${exec_prefix}/lib' && libdir='${exec_prefix}/'$el_nixos_lib
  test "$sysconfdir"     = '${prefix}/etc'      && sysconfdir=/etc
  test "$localstatedir"  = '${prefix}/var'      && localstatedir=/var
  test "$sharedstatedir" = '${prefix}/com'      && sharedstatedir=/var/lib
  test "$runstatedir"    = '${localstatedir}/run' && runstatedir=/run
  ;;
esac
true    # Correction [E2] #3, [E3] hazard 1: the script must end with status 0
```

**Correction [E2] #3, [E3] hazard 1:** autoconf ≥ 2.70 aborts with "failed to
load site script" when the site script's exit status is non-zero; when the
last `test … && …` does not match, the status is 1 and configure stops
(seen on which, xz, expat, libxcrypt, krb5; glibc's old configure does not
check, so [NF-S3] never saw it). The script must end with `true` (or `:`).
**Status [D-1]:** `lib/rocky/config.site` as committed in b9fdc83 still ends
with the `case`; run with `prefix=/nix/store/x runstatedir=/run` it exits 1.
The fix is pending (WP2/WP6 owner). The file also exports `$el_nixos_lib`
for the per-package fragments [RC].

Per-package fragments are appended (`CONFIG_SITE` is a list). glibc's
(`packages/glibc/glibc.site`, [NF-S3] + [SG] `rootsbindir`; Update [HO-glibc]:
it computes `el_nixos_lib` itself when the generic file has not set it;
[E5] part 4 verified `slibdir`/`rtlddir` = `$P/lib64` (x86_64) and `$P/lib`
(i686), `complocaledir` = `$P/lib/locale`, `rootsbindir` = `$P/sbin`,
`sysconfdir` = `/etc` in the spec's own `%build`):

```sh
case "$prefix" in /nix/store/*)
  libc_cv_slibdir=$prefix/$el_nixos_lib
  libc_cv_rtlddir=$prefix/$el_nixos_lib
  libc_cv_complocaledir=$prefix/lib/locale
  libc_cv_rootsbindir=$prefix/sbin ;;
esac
```

### 1.4 What stays FHS at runtime

Compiled in, unchanged from Rocky: `/etc/*` (nsswitch.conf, hosts, resolv.conf,
localtime, gai.conf, passwd…), `/var/*`, `/run/*`, `/proc`, `/sys`, `/dev`,
`/tmp`, `/bin/sh`, `/usr/bin/env` (both exist on NixOS and every FHS host).
Files a spec installs under `/etc`, `/var`, `/run` go to `<output>/etc|var|run`
(defaults, nixpkgs-style); `%config(noreplace)`, `%ghost`, `%attr`, `%caps`,
owners and setuid bits are recorded in `nix-support/rpm/<subpkg>.json` for
NixOS modules / image builders (the store cannot represent them).

Moved to the store: everything `/usr`, the ELF interpreter, `/usr/lib/rpm`,
glibc's ld.so.cache (P1; Update [E5]: `$P/etc/ld.so.cache`, `ldconfig -p`
opens it there), default `TZDIR` (= `$glibc/share/zoneinfo`, dangling, acked;
`TZDIR` env from profiles/NixOS). The preload file (P3) stays in `/etc` under
another name, `/etc/ld-nix.so.preload` [E5].

### 1.5 Build-time view and hard-coded `/usr` in specs

Three classes:

1. **`$RPM_BUILD_ROOT/usr/…` in `%install`/`%files`** (3.6 % / 1.6 % of specs [SG
   scan]; glibc's usrmove links, `hardlink …/usr/lib/locale`, sysroot) — generic:
   `fold-usr` makes `BUILDROOT/usr` → `BUILDROOT/$out`; the partitioner folds
   `/usr/x → x` [NF-S3, SG, BP-9 all confirmed on glibc].
2. **Build environment reached through FHS paths or target macros**
   (`/usr/bin/perl`, `/bin/true`, `-I/usr/include/foo`, `-I%{_includedir}/foo`,
   `--with-headers=%{_prefix}/include`, `%{_bindir}/python3` used as a tool;
   0.9 % + 3.2 % of specs [SG scan]) — generic: the **tool shim** (§5.4) provides
   * `/usr` = a view of the derivation's *declared* inputs: `bin` (and `sbin`
     → `bin`) is a symlink farm of the PATH tools; every input output's
     `include lib lib64 libexec share` is a **read-only overlayfs** of those
     input directories (first input on top, one input = a bind; collisions
     reported) — Correction [E2] #1: a symlink farm was rejected by glibc's
     configure (`test -L $prefix/include/{net,scsi}`); `/bin`, `/sbin` →
     `/usr/bin`,
   * `/usr/lib/rpm` = the assembled rpm config,
   * **self-prefix alias**: the same view mounted read-only at `$out` (a tmpfs
     over `$out`) while rpmbuild runs (`ROCKY_PREFIX_VIEW=1`; `$out` must be
     empty or absent before and is checked empty after), so
     `%{_includedir}/foo` used as "where my build deps live" resolves into inputs
     (spec-generic's P ≡ `/usr` trick, adapted to a real output path). The
     namespace ends with rpmbuild; `$out` is empty again when the partitioner
     fills it. `ROCKY_PREFIX_VIEW_DIRS` limits which input dirs the alias shows
     (default all; `bin` always) [E2].
   Nothing outside declared inputs is visible (no stage0 root, no nixpkgs `-devel`).
   **Correction [E2]:** "anything compiled in that pointed into the view is
   caught as a dangling reference" was too strong. A header reached through
   the alias is recorded in DWARF as `$out/include/...` (glibc: 8 DWARF-only
   files, `$out/include/{linux,asm-generic,sys,selinux}`; krb5:
   `$out/include/et`); one of them (`include/sys`) looks "backed" at
   directory granularity because glibc ships `include/sys/`, so a
   file-granular check is needed. A **library** reached only through the view
   (`-L%{_libdir}` via the alias, or ld's built-in `SEARCH_DIR("=/usr/lib64")`,
   which no-sys-dirs does not remove) links, runs inside the shim, and fails
   outside it (rc 127) without leaving any `$out` string. Hence, as
   conditions of the default:
   1. the view is real directories (done, `checks.nn-shim`);
   2. while rpmbuild runs, the cc-wrapper maps `-ffile-prefix-map=$out=/usr`
      (safe: nothing but the view lives under `$out` then). The wrapper's
      hook maps every store root named by `-I`/`-isystem`/…, the build's own
      outputs included [HO-cc]; a rebuild confirming that the 8 DWARF-only
      differences disappear has **not** been run;
   3. **library rule** (WP6): every declared view input that ships shared
      libraries is also a cc-wrapper input (its real `-L` then precedes ld's
      built-in dirs and lands in RUNPATH);
   4. **NEEDED guard** (WP5, implemented as `unresolved-needed`): every
      `DT_NEEDED` must resolve against RUNPATH (`$ORIGIN` expanded), siblings,
      inputs or the libc system dirs.
   Decision gate **E2: passed, `prefixView = true` by default** [E2]: glibc
   builds from the unmodified spec (`--with-headers=%{_prefix}/include`
   through the alias), identical file lists (17042), 0 differing loaded
   sections; krb5 builds unmodified (`source %{_libdir}/tclConfig.sh`,
   `-I%{_includedir}/et`), where the no-view build needs a substitution;
   which, xz, gzip, sed, m4, expat identical apart from build-ids (weak
   evidence: none of them needs the alias). Fallback per package:
   `prefixView = false` + `specSubstitutions` (the [NF-S3] way).
   Tools specs and macros call by FHS name must be on PATH: `/sbin/ldconfig`
   (brp-ldconfig), `gpgv2` (`%gpgverify`), `getconf` (krb5) [E2] #6.
3. **FHS paths that leak into outputs** — detected:
   * shebangs: nixpkgs `patchShebangs --host` against `HOST_PATH` (runtime
     inputs); interpreters not yet Rocky-built → `lateBind` (§2.9) or
     `fhsAllowlist` (bootstrap only);
   * other FHS literals in ELF/text: reported in `nix-support/rocky-report.json`
     (`/usr/`, `/lib64/`, `/bin/` not on the runtime allowlist); `strictFhs = true`
     per package turns them into errors.
   * The static lint (`tools/spec-hazards.py`, from [SG spec-scan]) produces the
     per-package worklist; the build is the real detector.
4. **Specs that edit macro-expanded paths** (Update [E2] #9, [E3] hazards 5, 8,
   9): the store prefix contains the package name and the BUILDROOT path
   is `$RPM_BUILD_ROOT$P/…`, not `$RPM_BUILD_ROOT/usr/…`:
   * krb5 `%define libsdocdir %(echo %{_pkgdocdir} | sed -e s,krb5,krb5-libs,g)`
     also rewrites `/nix/store/<h>-krb5-1.21.3-…`, so `%install` fails
     (per-package fix, e.g. `s,krb5$,krb5-libs,`);
   * gnutls (from reading the spec, not built) strips the buildroot from its
     `.hmac` with `sed "s^$RPM_BUILD_ROOT/usr^^"`, which matches nothing
     relocated, so the BUILDROOT path stays in the file;
   * `%__meson` must be `meson` from PATH, not `%{_bindir}/meson`
     (= `$P/bin/meson` relocated) — seen with nixpkgs' meson for pixman.
   The spec-hazards lint should flag sed edits of macro-expanded paths that
   use the package name or `$RPM_BUILD_ROOT/usr` (requested of WP2/WP6).

---------------------------------------------------------------------------

## 2. Output splitting (Q2)

### 2.1 Inputs to the partitioner

`tools/rocky-partition/` (Python ≥3.11 package, stdlib only). **Correction
[HO-partition]:** run as `python3 -I ${partitionTool}/rocky-partition --plan
"$NIX_ATTRS_JSON_FILE"`, not `python -I -m rocky_partition`: `-I` ignores
`PYTHONPATH` and the cwd; the entry script puts its own directory on
`sys.path`. `partitionTool` is a plain source store path (no derivation), so
it is an allowed build input in every stage (listed in
`stage.extraAllowedSources`, §7.3). Exit 0 ok, 1 errors (report in
`$out/nix-support/rocky-report.json`), 2 plan/tool error. Run before
`fixupPhase` with strip, patchELF, moveLib64, moveSbin, moveDocs, gzipMan off.
The full plan schema (every key, default, error code, remedy) is
`tools/rocky-partition/PLAN.md`; it supersedes the key list below where they
differ.

* `BUILDROOT` after `%install` + brp scripts + find-debuginfo (`rpmbuild -bb
  --noclean`).
* `RPMS/*/*.rpm` (transient, uncompressed payload): per RPM, the header tags
  `NAME`, `FILENAMES`, `FILEFLAGS`, `FILEMODES`, `FILELINKTOS`, `FILEINODES`,
  `FILEDIGESTS`, `FILEUSERNAME`, `FILEGROUPNAME`, `FILECAPS`, `REQUIRENAME/FLAGS/VERSION`,
  `PROVIDENAME/…`, scriptlets, triggers, file triggers (read with `rpm -qp
  --qf` in the shim; the payload itself is not used — the BUILDROOT has the
  bytes).
* `plan.json` written by Nix (`passAsFile`): subpackage → output map, output
  paths (`$out`, `$dev`, …), `prefixOutput = "out"`, `mergeOutputs`, `layout`,
  `runtimeSearchPaths`, `unionDirs`, `danglingOk`, `opaqueRefs`, `forward`
  policy, `lateBind`, `noPatchelf`, `fhsAllowlist`, `allowUnresolvedNeeded`,
  input library dirs (`inputLibDirs`, from runtime inputs' `lib64`/`lib`),
  allowed store hashes (own outputs + runtime closure of inputs), the
  per-subpackage *unique-provider Requires* (resolved at eval time from
  `deps.json.gz`, [SG] rule: a virtual provided by several subpackages, e.g.
  `glibc-langpack`, does not count).
  Update [HO-partition], PLAN.md: with `__structuredAttrs` the plan is the
  attribute `rockyPlan` and output paths come from the attrs file's
  `outputs`. Required: `subpackages` (non-debug rpm name → output after
  merges; debuginfo goes to `debugOutput` automatically), `buildroot`
  (`--noclean`), `rpmsDir` (header-only RPMs suffice), `rpm` (+
  `rpmConfigDir` for the FHS stage0 rpm), `patchelf` (needed only when a
  RUNPATH changes). Keys not in the original list: `prefixRelativeOk`
  [R10], `integrityOk` [R14], `systemLibDirs` (the stage libc's system dirs;
  glibc itself `["@out@/lib64", "@out@/lib"]`), `allowedStorePaths` (null =
  report only), `unmanagedOutputs` (`["logs"]`), `debugOutput`, `searchPaths`,
  `requires` (optional: computed from the headers with the unique-provider
  rule when absent), `failOnError`, `copy`, `storeDir`. `@name@` is
  substituted in `systemLibDirs`, `inputLibDirs`, `allowedStorePaths`. The
  search-path table comes from `nn.unions.json` (§4.1) [HO-names].

### 2.2 Phase A — map paths to outputs

`canon(path) -> (output, rel)` for each header file name of subpackage *s*
(output `o(s)` after merges; all `*-debuginfo`, `*-debugsource` → `debug`):

| header path | destination |
|---|---|
| `$out/x`, `/usr/x` | `o(s)/x` |
| `/bin/x`, `/sbin/x`, `/lib64/x`, `/lib/x` (usrmerge spellings) | `o(s)/bin/x` … |
| `/etc/x`, `/var/x`, `/run/x` | `o(s)/etc/x` … (+ metadata) |
| `/usr/lib/debug/x` | `debug/lib/debug/x` (nixpkgs layout; `.build-id/xx/*.debug` kept) |
| `/usr/src/debug/x` | `debug/src/debug/x` |
| `/usr/lib/.build-id/…` in non-debug subpackages | dropped (recorded) — they only exist for FHS debuginfo lookup; Nix uses `debug/lib/debug/.build-id` via `NIX_DEBUG_INFO_DIRS` |
| other absolute (`/boot`, `/opt`) | `o(s)/<path without leading />` + report |
| `$X/x` for another output X (a `layout` build) | `o(s)/x` (Update [R11]) |

Update [R6]: debug `.build-id` links that point to a dropped
`usr/lib/.build-id` link are followed to the binary (glibc: 708
`symlink-dangling` otherwise). Update [R16]: in the debug output, path names
mirror the prefix (`lib/debug/<P>/…`); metadata keeps a debug file's `rel`
exact.

### 2.3 Phase B — materialise

1. Ownership map `rel → {(output, flags)}` incl. `%dir` and implied parents.
2. Move each file from `BUILDROOT` (through the `usr` link) to `$o/rel`; a file
   owned by several outputs is copied into each; hard links inside one output
   kept, across outputs broken into copies; `%ghost` not materialised; modes
   kept modulo Nix canonicalisation (setuid/setgid, owners → metadata).
3. Files left in `BUILDROOT` that no RPM claims → error (rpm's check already ran;
   this catches fold mistakes).

### 2.4 Phase C — symlinks

Resolve each link target in the *rpm namespace* (where `/usr` ≡ `$out`; relative
targets against the link's canonical directory; build-id-style
`../../../../nix/store/<P>/…` targets [NF-S5] fold too), `canon()` the result:
same output → relative link; other output X → absolute `$X/rel`; FHS runtime
target (`/etc/…`) → unchanged; owner none → `dangling` report (error unless
`danglingOk`).

### 2.5 Phase D — reference scan and text rewriting

For every regular file of every output: classify (ELF, `ar` archive, text,
compressed — gzip/xz/zstd/bzip2 members, ELF `.gnu_debugdata` and compressed
sections are decoded for scanning only, decoders from `tools/rpm_purity.py`),
then find occurrences of `$out` followed by `/rel` (path charset
`[A-Za-z0-9._+@%-/]`, up to NUL/space/quote/colon). Let *Y* be the file's
output, *X* the owner of `rel`:

| case | text file | ELF / archive / other binary |
|---|---|---|
| 1. `rel` owned by `out` (or `rel` is a dir and `out` owns it) | keep (edge Y→out) | keep |
| 2. `rel` single owner X ≠ out | **rewrite** `$out/rel` → `$X/rel` (any length; `.pc`, `.la`, `.cmake`, GNU ld scripts, scripts, desktop/service files) | → Phase F/G (RUNPATH or forwarding stub) |
| 3. `rel` is a union dir (several owners) | ack required in `unionDirs` (with mechanism) else error | same |
| 4. `rel` exists nowhere | `danglingOk` / `runtimeSearchPaths` else error (catches view leaks, zoneinfo) | same |
| 5. bare `$out` (no `/rel`) or `$out/` prefix of a union | Y = out: report "prefix-relative" (info) ; Y ≠ out: **error** "prefix-relative software split across outputs" → merge [BP rule] | same |
| 6. text reference to X that Y does not (uniquely) Require | keep as `$out/rel` + report (e.g. `ldd`'s `RTLDLIST` naming the 32-bit loader must not drag `glibc32` into `glibc-common`) | n/a |
| 7. other store hash | must be in the allowed set (own outputs, runtime input closure), else error (stage0/nixpkgs leak) | same |

Text rewriting happens **before** the graph check, so rewritten references are
what Nix sees. Example [NF-S5]: `dev/lib64/libc.so` = `GROUP ( $out/lib64/libc.so.6
$dev/lib64/libc_nonshared.a AS_NEEDED ( $out/lib64/ld-linux-x86-64.so.2 ) )`.

#### 2.5.1 Rule refinements measured by E3 (all implemented, [E3], PLAN.md)

The table above as first implemented gave errors that needed overrides in
every autotools SRPM measured (xz and expat for their `.pc` files alone) and a
merge for pixman. These refinements changed that; they override the table
where they differ:

| rule | change to the table above | evidence |
|---|---|---|
| R2 (`union-self`) | **Correction of case 3 / decision #7 for lib dirs:** text in a non-prefix output Y that owns part of a `lib64`/`lib`/`include` union is rewritten to `$Y/...` (a `-devel` `.pc` `libdir` names where `-lfoo` finds `libfoo.so`, i.e. `$dev/lib64`). Restricted to lib/include: for `share` it was wrong (ncurses6-config) | every `-devel` `.pc` of xz, expat, libxcrypt, ncurses |
| R3 | a pkg-config variable whose value is the bare prefix is acked when neither it nor a variable derived from it is used by another line (also an unused variable naming a top-level dir) | `prefix=`/`exec_prefix=` of all measured `.pc` files |
| R4 | a reference to a *standard top-level* dir that several outputs fill (`$out/bin`, `$out/lib64`, `$out/share`) is case 5 (prefix-relative), not case 3 | glibc's 32-bit ld.so names `$out/lib` |
| R5, R13 | ld.so dynamic string tokens (`$LIB`, `${PLATFORM}`, also `\$LIB`) are part of a path; the native `lib64` expansion decides; an expansion not owned by the output the reference points into is a `dangling` error (ack `danglingOk` with that expansion) | glibc memusage/xtrace `$out/\$LIB/libmemusage.so`: the 64-bit one is in `utils`, the 32-bit one would have been out's: `danglingOk = [ "lib/libmemusage.so" ]` |
| R8 | references from documentation trees (`share/doc`, `share/man`, `share/info`, `share/gtk-doc`, `share/help`) are recorded (Nix still sees the edge) but never errors | krb5 admin guide prose |
| R9 | `#!/bin/sh` and `#!/usr/bin/env` are runtime FHS (§1.4), not `fhs-shebang` warnings | krb5-tests |
| R10 | **new ack for case 5** (§8.1 had none): `prefixRelativeOk` (output patterns) acks prefix-relative, union and dangling references of matching files | krb5-tests (copied build tree), `*-config` scripts, glibc benchtests and sysroot |
| R12 (`pc-expanded`) | pkg-config files of a non-prefix output: prefix-derived variables (`libdir=${prefix}/lib64`, as meson and cmake write them) are expanded in their definitions and `${prefix}` aliases in other lines, then R2 applies | pixman (meson): 1 error whose only remedy was a merge → 0 |

Not covered by measurement: cmake config files (`lib64/cmake/*`,
`${_IMPORT_PREFIX}`), only one meson SRPM, no cmake SRPM [E3].

Update [E2], [HO-shim]: compiled-in references into the view (`$out/<rel>`
that exists in the view but not in any output) are case 4 (`dangling`). DWARF
names directories and files separately, so detecting them needs file
granularity (prototype `scan_refs` in `lib/rocky/e2/compare.py`); whether
`rocky-partition` classifies DWARF references at file granularity is not
recorded in the hand-off.

### 2.6 Phase E — RUNPATH recompute (the `foo`/`foo-libs` fix)

For every dynamic ELF not matching `noPatchelf` and not static:

1. `needed = DT_NEEDED`; `old = DT_RUNPATH or DT_RPATH`.
2. For each soname, provider search: (a) the file's own output lib dirs
   (`lib64`, `lib`, and subdirs that `old` named under `$out`, re-mapped);
   (b) sibling outputs containing the soname (unique; prefer one Y Requires);
   (c) `inputLibDirs` and the input store paths already in `old`; (d) sonames
   provided by the stage's libc in its system dir → no entry.
3. `new` = ordered unique dirs (keeping `$ORIGIN` entries). If `new == old`,
   untouched; else `patchelf --set-rpath new --force-rpath`-free (DT_RUNPATH;
   Rocky ld has no new-dtags [NF-S2] → `--enable-new-dtags` in bintools-wrapper
   makes link-time entries RUNPATH too).
4. Unresolved soname → error, unless listed in `allowUnresolvedNeeded` (bootstrap
   stages) or the output is in `lateBind` with that library (§2.9).

This also replaces nixpkgs' `patchelf --shrink-rpath` (unused dirs, e.g.
`$dev/lib64` from `-L`, are dropped) and fixes memusagestat (NEEDED libgd,
RUNPATH empty under `NIX_DONT_SET_RPATH=1` — verified with `readelf` on the
[NF-S3] output [F-3]). patchelf may relayout when the string grows; parity
compares ELF semantically (§7.4), nixpkgs does this everywhere.

Update [E3]: measured — xz's `$out/lib:<glibc>/lib:<gcc-lib>/lib` became
`$lib/lib64:<glibc>/lib`; RUNPATHs recomputed: xz 5, expat 2, libxcrypt 2,
ncurses 19, krb5 37, pixman 1; 0 `unresolved-needed`, 0 `ambiguous-needed`.
[HO-cc]: with a split libc the ld-wrapper adds `$dev/lib64` (libc.so script
only) and gcc's `lib/gcc/x86_64-redhat-linux/14` to RUNPATH (every `-L` dir
holding a `lib<x>.so`); this phase drops them. [E2] #10, [HO-shim]: the
self-rpath must be the own `%{_libdir}` = `$out/lib64` (after the partition:
the owning output's `lib64`); nixpkgs' ld-wrapper adds `$out/lib`, which left
xz, expat and krb5 binaries unable to find their own libraries. `nn.cc`
appends `lib64-rpath.sh` to the wrapper's setup hook for this (§5.1).

**Update [R14]: FIPS integrity data.** patchelf changes bytes that FIPS
self-checks cover. A fipscheck companion (`<dir>/fipscheck/<name>.hmac`,
`<dir>/.<name>.hmac`, key `orboDeJITITejsirpADONivirpUkvarP`) that verifies
against its target before this phase is recomputed after it
(`integrity-rehashed`; libxcrypt: both shipped `.hmac` files recomputed,
checked independently with `openssl dgst`). A file with an embedded HMAC
(ELF section `.rodata1`: openssl `fips.so`; `.note.fdo.integrity`:
libgcrypt) or an unverifiable companion (gnutls' INI form) is not patched:
`integrity-runpath` error; remedies `noPatchelf` with a link-time RUNPATH, or
`integrityOk`. Only libxcrypt was built; the openssl/libgcrypt/gnutls/nettle
forms come from reading the Rocky 10.2 specs.

### 2.7 Phase F — forwarding stubs (binary refs into another output)

For an ELF/binary reference `$out/rel` with `rel` owned by X ≠ out (case 2) that
Phase E did not make moot:

1. if `rel` matches `runtimeSearchPaths` → leave (compiled-in default dangles;
   X's setup hook exports the variable), edge none;
2. else if (Y Requires X uniquely, or Y == X) **and** adding edges `out→X`
   keeps the output graph acyclic → create stub `$out/rel → $X/rel` (absolute
   symlink; for a directory `rel`, one directory symlink) and record it in
   `nix-support/rocky-stubs`;
3. else → **error** listing file, string, owner and the three remedies:
   `layout` (compile that macro as X's path), `mergeOutputs`, or
   `runtimeSearchPaths`.

Covers exe-relative lookups too (python's `$out/lib64/python3.12` when
stdlib lives in `-libs`) whenever acyclic. Y == X with X ≠ out (a `-libs`
library referencing its own plugin dir by the prefix path) is a cycle by
construction → layout or merge; the diagnostic says so.

Update [R15]: a stub for a directory serves the references to files below it
(anchors processed shallowest first). Update [E3]: **no stub was created** in
any measured SRPM or the glibc replay; every compiled-in reference into a
non-prefix output was either Y == X (would cycle: ncurses-base's
`share/tabset`, krb5-server's `sbin/kdb5_util`) or went away with the prefix
choice. Remaining override classes from E3: prefix choice (§3.1), acks for
files that print install dirs and copied build trees, search paths / union
acks for data and plugin dirs, and a merge where programs of a non-prefix
output run each other by compiled-in prefix path (krb5:
`mergeOutputs = [ [ "krb5-libs" "libkadm5" "krb5-server" ] ]`; the
`layout._sbindir = "server"` alternative was not tried and §2.7's validity
rule forbids it there).

`layout` (per-package, from [NF]): `layout = { _datadir = "common"; }` →
`--define "_datadir $common/share"`; valid only when the official filelists say
the whole macro dir belongs to X (the lock tool `tools/layout-suggest.py`
proposes them from repodata `filelists.xml`).

### 2.8 Phase G — hidden and pieced references

* **Pieced references** [SG discovery, F-2]: scan loaded sections (`.rodata`,
  `.data`, `.text`) of each ELF for 8-byte windows of `$out` not covered by a
  full occurrence. Measured on the [NF-S3] glibc: `ld.so` 57 windows in `.rodata`
  (32-byte chunks `\0…/nix/store/nncpaslng931r…`), `ldconfig` 57 (`   /nix/store/…`
  in a fixed field), `localedef` 63, `locale` similar; `libc.so.6` none outside
  full strings. Because nothing is rewritten, these bytes are correct; the
  risk is only that Nix's 32-char hash scanner misses an edge, or that the
  `rel` behind a piece is unknown. Rule: in the prefix output: allowed (listed
  in the report); in any other output Y: the partitioner writes the full `$out`
  path into `$Y/nix-support/hidden-references` (so Nix registers Y→out) and the
  package must ack it in `opaqueRefs` (a behaviour test is expected).
* **Correction [E4], [R1]: detect by hash, not by path windows.** `fragscan.py`
  (8-byte windows of the *path*) reports false positives in every non-prefix
  output: `/nix/sto…` and `…-glibc-2.39-142.el10_2` windows occur in every
  ordinary full `$out/...` reference. [F-2]'s "57 pieced windows in ld.so"
  are mostly that effect. Two real classes, per target hash H:
  * **truncated copy**: H in full, not followed by the whole store name
    (gcc stored `/nix/store/<hash>-glibc-2.39-142.el10_` as a 64-byte
    `.rodata` chunk and built the tail with `movabs` immediates or an
    overlapping chunk). Nix sees the edge; only the `rel` behind it is opaque;
  * **split hash**: an 8-byte window of H outside every full H — what Nix's
    scanner would miss (hidden edge).
  The implemented detector [R1] counts 8-byte windows of P that hold **≥ 6
  bytes of its hash**, in loaded sections of ELF files, outside full
  occurrences (windows of the name alone matched `.note.package` in xz and
  closed a false cycle lib↔out). This catches both classes in ELF files.
* **Measured on glibc [E4]** (S5 split and S3, identical): no split hash in
  any loaded section of any output; all 1113 (S5) / 2199 (S3) split-hash
  windows are the `-frandom-seed=nncpaslng9` string in `.debug_str`
  (nixpkgs' reproducible-builds hook, off in §5.1). Exactly 7 truncated
  copies: `out` ld.so and ldconfig (allowed), and outside `out`:
  `common/bin/locale` (→ `lib/locale/…`), `common/bin/localedef`
  (→ `share/i18n/{locales,charmaps}`), `static/lib64/libc.a` (member
  `dl-load.o`, → `lib64/`), the sysroot's `ld-linux-x86-64.so.2` and
  `libc.a` (→ `lib64/`). The hash is whole in all of them ("measured for
  this build, not guaranteed"), so `hidden-references` are not needed for
  correctness; registering them is harmless.
* E4 asks that static archive members be scanned too (`libc.a`'s
  `dl-load.o`). PLAN.md describes the window scan as "in loaded sections of
  ELF files", and the replay's override set acks no `static` file: archive
  members are apparently not scanned for pieces yet (open, WP5). Nix still
  registers static → out from the whole hash.
* **`opaqueRefs` entry format: open.** PLAN.md (implemented) uses output
  patterns `"<output>"` / `"<output>:<rel glob>"` (`"common:bin/locale"`);
  the glibc override draft (`packages/glibc/default.nix`) uses
  `"<output>/<rel>"` strings. WP6 must settle one form (PLAN.md's is the one
  the tool reads) [HO-glibc], [HO-names].
* **Compressed/nested references** (gzip'ed man pages, `.gnu_debugdata`): same
  file, `hidden-references`, as in bootstrap-purity's nested-references.

### 2.9 Phase H — graph, cycles, late binding plan

Edges = Nix's own test (output A contains B's hash part) over final contents +
`hidden-references`. Tarjan SCC (§3). For `lateBind` outputs, compute
`L* = L ∪ {Y | Y →* L}` over sibling outputs (e.g. `common` → all langpacks; `nss_db`
→ `nss_devel`), and require: no ELF *content* in `L*` references `L` (only
symlinks, text, RUNPATH) — else error. Written to `nix-support/rocky-late.json`.

Update [R7]: `debug` and unmanaged outputs are not part of `L*` (they may
reference siblings and are not rebound). Update [E4]: glibc's measured
reference graph (Nix's registered references of the S5 split, symlinks
included) has no cycle: `out` ← benchtests common dev nss_db nss_devel static
sysroot utils; `common` ← **138 of the 206** `langpack_*` outputs (LC_CTYPE,
LC_NUMERIC, LC_NAME symlinks to `C.utf8`; six reference `common` only through
LC_NUMERIC/LC_NAME); `dev`, `static` ← sysroot; `nss_db`, `nss_hesiod` ←
nss_devel; `utils`, `benchtests` ← nothing. The design draft's
`[ "minimal_langpack" "langpack_*" ]` is a superset (70 extra bound copies;
`minimal_langpack` is empty); the exact list is the generated
`packages/glibc/late-referrers.nix`.

### 2.10 Phase I — metadata and hooks

Every output gets `nix-support/rpm/<subpkg>.json` (file list with flags/modes/
owners/caps/digests, Requires/Provides, scriptlets, triggers), `nix-support/rpm-name`,
and, if it contributes to a search path, a generated `nix-support/setup-hook`
(e.g. `langpack_de`: `addToSearchPath LOCPATH $langpack_de/lib/locale`). The
whole decision log goes to `$out/nix-support/rocky-report.json` (edges with
evidence, stubs, rewrites, RUNPATH changes, FHS literals, pieced refs). The
build log goes to a `logs` output (as today).

Update [HO-partition], [NM-fix]: in the report and metadata, other outputs'
paths are written as `$name` and P as `/usr` (except a debug file's exact
`rel`), so they create no Nix edges. Setup-hook lines follow the contract in
the header of `lib/rocky/unions.nix` (`provider` / `yieldsTo`, reference
implementation `nn.unions.hookScript`): e.g. a langpack's `LOCPATH` line is
guarded by `[ -n "${LOCALE_ARCHIVE-}" ] ||`, and an archive's
`LOCALE_ARCHIVE` line is followed by `unset LOCPATH` (§4.1). Whether the
partitioner's hook generator already emits the `provider`/`yieldsTo` forms
is a WP5 follow-up request [HO-names].

### 2.11 Options compared (task item 2)

| option | ELF refs | text | names | verdict |
|---|---|---|---|---|
| equal-length names + byte rewrite | fixable except pieces | fixable | padded | rejected (pieces, UX) |
| placeholder P + slash padding | breaks on pieces [SG, F-2]; padding visible | fixable | normal | rejected |
| per-dir macro → output (`layout`) | correct by construction for wholly-owned dirs | correct | normal | per-package override, suggested from filelists |
| **prefix = `out` + move + text rewrite + RUNPATH recompute + gated stubs** | correct, detected otherwise | rewritten | normal | **default** |

### 2.12 Output names and attributes

* Outputs from `subpackages.json` (§3.2) minus merges, plus `debug` if any
  debuginfo is built, plus `logs`.
* Rule: prefix subpackage → `out`; `<srpm>-devel` → `dev`; `<srpm>-libs` → `lib`;
  debuginfo/debugsource → `debug`; `<srpm>-X` → `X`; other names verbatim; then
  `[^A-Za-z0-9_] → _` ([NF-S0]: setup.sh needs identifier names; Nix itself
  accepts 230 outputs). Collisions after mapping → both fall back to the full
  sanitized subpackage name (eval-time assert).
* **Update [NM]: reserved and non-identifier names.** A short name that is not
  a shell identifier (`xorg-x11-fonts-100dpi` → `100dpi`) or is reserved
  (`out debug logs all args builder drvAttrs drvPath env inputDerivation meta
  name outPath outputName outputSpecified outputs override overrideAttrs
  overrideDerivation passthru patches phases pname prefix raw shell src srcs
  stdenv system type version`: it would shadow a derivation attribute or a
  setup.sh variable; `rust-src` would otherwise become `$src`) also falls back
  to the full sanitized name; a full name that is still invalid gets a
  leading `_`. A merge group containing the prefix subpackage is always
  `out`. Measured over the 2198 SRPMs with shipped subpackages: 11303
  outputs, 2 collision fallbacks (`perl_lib`, `perl_libs`), 12
  non-identifier/reserved fallbacks, 0 failures. glibc: 224 subpackages →
  225 outputs (223 + debug + logs; `glibc32` merged into `out`), the 223
  names identical to the built [NF-S5] spike.
* Update [NM], [E6]: output order is `out` first, the rest sorted, then
  `debug` (when `subpackages.json` lists debug packages), then `logs`
  (E6: a derivation whose first output was `lib` made `lib` the default
  outPath). `nn.names.outputsFor` returns `rpmOutputs` (every subpackage incl.
  unshipped, debug ones → `debug`; for plan.json) and `shippedRpmOutputs`
  (what `rocky.rpm.*` aliases). Update [LK]: one name, `rubygem-racc`, is
  built by two SRPMs (ruby unshipped, rubygem-racc shipped); the alias takes
  the shipped one (`duplicateNames` in subpackages.json).
* Update [NM-fix]: nixpkgs' `multiple-outputs.sh` would move `share/doc`,
  `share/man`, `include`, `lib/pkgconfig`, … between outputs named
  `dev`/`doc`/`bin`/`lib` and add propagated inputs; mkRpmPackage switches its
  hooks off (`moveToDev = false`, `propagatedBuildOutputs = ""`,
  `setOutputFlags = false`, drop `_multioutDocs` from `preFixupHooks`; there is
  no `dontMoveDocs` in nixpkgs 26f4107).
* Store names: `<srpm>-<version>-<release>[-<output>]`, stage-independent.
* Attrs: `rocky.<srpm>` (multi-output, bound outputs where `lateBind` applies);
  `rocky.<srpm>.raw` (the rpmbuild derivation); `rocky.rpm.<rpm-name>` → output;
  `passthru.rpmOutputs = { "glibc-devel" = "dev"; "glibc-common" = "common"; … }`;
  merged names alias the representative. Same shape per stage:
  `rockyBoot.s1.*`, `rockyBoot.s2.*`.

---------------------------------------------------------------------------

## 3. Reference cycles, merges, prefix choice (Q3)

### 3.1 Prefix subpackage

The prefix subpackage gets `%_prefix` and is named `out` (nixpkgs needs `out`).
Rule (lock generator, `subpackages.json.prefix`): eponymous subpackage > `<srpm>-libs` >
the subpackage owning most `/usr` files in the official filelists. Override:
`prefixSubpackage`. (krb5 → `krb5-libs` = `out`; `rocky.rpm."krb5-libs" == rocky.krb5.out`.)

**Update [LK]: the implemented rule** (`tools/lock_subpackages.py`
`choose_prefix`), refined because the plain "most /usr files" tier picked 23
test/doc/devel subpackages (python3.12 → `python3-test`, postgresql16 →
`postgresql-docs`, mariadb10.11 → `mariadb-test`): eponymous > `<srpm>-libs`
> the same two for the SRPM name without its version (`stem`: python3.12 →
python3, postgresql16 → postgresql) > most `/usr` files among shipped names
that are not -test(s)/-testsuite/-doc(s)/-javadoc/-apidoc/-manual/-example(s)/
-demo(s)/-devel/-static/-headers > the same allowing -devel/-static/-headers
> allowing all > first. Counts over 2217 SRPMs: eponymous 1960, usr-files 248,
`-libs` 4, `stem` 4, first 1. Choices among several libraries stay
mechanical (ding-libs → libpath_utils, wayland → libwayland-client) and may
need `prefixSubpackage` when packaged.

**Update [E3]: data subpackages.** For ncurses the eponymous prefix gives 325
errors (compiled terminfo entries name `$out/share/tabset`, libtinfo compiles
in `$out/share/terminfo`, both owned by ncurses-base: Y == X cycles);
`prefixSubpackage = "ncurses-base"` (it owns the data and references nothing)
plus `TERMINFO_DIRS` and one `prefixRelativeOk` for the `*-config` scripts
gives 0, with no merge. Proposal (not implemented in the lock generator):
before "eponymous", prefer a subpackage that owns a directory compiled into
the `-libs` subpackage and references no sibling. Until then the override
goes into `packages/ncurses`.

### 3.2 Static subpackage list

`lock/rocky-10.2/subpackages.json` = per SRPM: `rpmspec -q --qf '%{NAME}\n'
--target x86_64 --define 'dist .el10_2'` with the stage0 rpm + Rocky macros
(+ the package's `bconds` override), the prefix choice, and `shipped` (∈ `rpms.json`
bySrpm). Unshipped ones (glibc's `glibc32`, `sysroot-x86_64-el10-glibc`,
`compat-libpthread-nonshared`; 8/20 SRPMs' `-static` [SG]) become outputs too
(they are cheap and keep `%files` processing honest). Debuginfo subpackages are
not listed (they all map to `debug`). An output built but not declared, or
declared but not built → build error.

**Update [LK]: as built.** One small derivation per SRPM
(`nn.lockgen.subpackages.<srpm>`) runs `rpmspec -q --srpm`, `--builtrpms` (a
`%package` without `%files` is not built: krb5's `krb5`) and `--rpms` on the
locked SRPM in stage0-full (+ the stage0 `*-rpm-macros` and `macros.rust-srpm`
extracted from the locked rust SRPM), defining **`%distcore`, not `%dist`**
(Correction: `--define dist` dropped `%forgemeta`'s `.git<commit>`; ksc
parsed as `1.12-7.el10`, the lock says `1.12-7.git869a25c.el10`). Result
lines carry a `LOCKGEN` marker (`%forgemeta -v` prints to stdout). Full run:
2217/2217 ok; 7805 subpackages, 6707 shipped, 1098 unshipped; glibc 224 with
3 unshipped. Per entry: `names` (spec order, debug excluded), `debug` (a
list), `noarch`, `shipped`, `prefix`, `prefixRule`, optional `usrFiles`,
`notBuilt`, `shippedMissing`, `exclusiveArch`, `excludeArch`; `lockgen` (the
query's drv hash, so `--stale` detects machinery changes). Limits: 200 of the
6907 official binary RPMs are not produced by the x86_64 parse
(`shippedMissing`: 149 langpack fonts, 44 javadoc/java variants from
javapackages macros not in the lockgen buildroot, 6 noarch built on other
arches, 1 gcc-toolset); only default bconds are modelled (the `bconds`
override of §8.1 is not applied yet). Regeneration: `python3 -I
tools/lock_subpackages.py --stale`, then `python3 -I tools/update-lock.py
--derived-only`.

### 3.3 Cycles

* Detection: the partitioner (Phase H) before Nix does, with evidence per edge
  (file, string/hash, case) and the suggested `mergeOutputs` (SCC members).
* Resolution is static: `mergeOutputs = [ [ "glibc" "glibc32" ] ]` (first =
  representative). Merged subpackages share one output; RPM-name attrs alias it;
  per-subpackage metadata kept. Merges no longer needed are reported.
* Kinds of merge: **cycle** (Nix forbids), **functional** (compiled-in path of
  another subpackage that no stub can serve: glibc32's 32-bit `libc.so.6` names
  `$out/lib/ld-linux.so.2` [NF-S5]), **prefix-relative** (case 5).
* The RPM Requires graph is never used as the closure graph (80 binary SCCs,
  largest 212; 53 SRPMs with intra-SRPM Requires cycles [SG req-graph]); only
  Requires-*gated* references are. glibc's measured reference graph has **no
  cycle** [NF-S3b, NF-S5]: all → out, langpacks → common, nss_devel → nss_db/
  nss_hesiod, sysroot → dev/static (re-measured, Update [E4]; the
  partitioner's replay of the [NF-S3] tree into the 224 outputs with the
  override set of `tools/rocky-partition/tests/glibc-overrides.nix`: 0 errors, no
  cycles, Nix accepted the outputs, `checks.nn-partition-replay` [HO-partition]).
* Update [E3]: the one merge E3 needed was krb5's
  `[ "krb5-libs" "libkadm5" "krb5-server" ]` (kadmind/kpropd run
  `$out/sbin/kdb5_util`/`kprop`, which are krb5-server's; merging only
  krb5-server into out cycles with libkadm5).
* Cross-SRPM reference cycles (freetype ↔ harfbuzz style) cannot be expressed
  between derivations: handled by build-order stages + `lateBind` of the
  referencing output (§8.3).

---------------------------------------------------------------------------

## 4. Union directories and glibc (Q4)

### 4.1 Principle

A compiled-in directory names one output. Unions become (as in nixpkgs):
(1) env search paths exported by setup hooks at build time and by profiles/
wrappers at run time; (2) `buildEnv` profiles (`rocky.lib.mkProfile` = `buildEnv`
+ `etc/profile.d/rocky.sh` exporting the union variables, plus "trigger
emulation" hooks: `iconvconfig`, `glib-compile-schemas`, `update-mime-database`
… run in the profile's `postBuild`); (3) plugin dirs: host default + host env var,
else `makeWrapper`, else layout/merge. Build-time hooks extend nixpkgs' for `lib64`
(`lib64/pkgconfig`, `lib64/cmake`).

Table (`lib/rocky/unions.nix`, consumed by the partitioner's hook generator):
`PKG_CONFIG_PATH`, `ACLOCAL_PATH`, `XDG_DATA_DIRS`, `GI_TYPELIB_PATH`, `PERL5LIB`,
python `.pth`/`PYTHONPATH`, `MANPATH`, `INFOPATH`, `TERMINFO_DIRS`, `GCONV_PATH`,
`LOCPATH`, `LOCALE_ARCHIVE`, `I18NPATH`, `TZDIR`, `NIX_DEBUG_INFO_DIRS`.

Update [NM], [NM-fix]: each entry is `{ dirs; kind = list|single; sep; when =
[build run]; provider; yieldsTo; doc }` (`nn.unions.table`), with `json` for
plan.json, `profileScript root` for profiles and `hookScript o` as the
reference implementation of the hook contract (header of `unions.nix`).
`PYTHONPATH` covers python3.12 only (python3.14 modules must not be on it).
`I18NPATH` is build + run.

**Correction [NM-fix] §2: LOCPATH yields to LOCALE_ARCHIVE.** glibc reads the
locale archive only when `LOCPATH` is unset (measured with nixpkgs glibc
2.42: `LOCALE_ARCHIVE` + any `LOCPATH` → "Cannot set LC_CTYPE to default
locale"). So `LOCPATH` has `provider = "*/LC_CTYPE"` (only directory-format
locales count; a `lib/locale` holding only `locale-archive` is not an entry)
and `yieldsTo = [ "LOCALE_ARCHIVE" ]`: a profile root that provides the
archive unsets `LOCPATH`; in build hooks `LOCPATH` lines are guarded and the
`LOCALE_ARCHIVE` line is followed by `unset LOCPATH`, independent of hook
order. The archive of `all_langpacks` holds every locale, so it wins.

### 4.2 glibc

| union | Rocky | nixpkgs glibc | **here** | evidence |
|---|---|---|---|---|
| rtld system dirs | `/lib64:/usr/lib64` + `/etc/ld.so.cache` | `$out/lib`, cache patched | `$glibc/lib64` (from `slibdir`), `libgcc-for-glibc/lib64` (trusted dir), RUNPATH for the rest; **P1** | [NF-S4] `system_dirs[0]=$G/lib64/` |
| `ldconfig`, `/etc/ld.so.conf` | maintains cache | reads `$out/etc` | Rocky's ldconfig; P1 makes cache `$glibc/etc/ld.so.cache` → inert on Nix | |
| NSS modules | system dirs | files/dns in libc dir; nscd/nsncd | files/dns/compat in `out` (= system dir); `nss_db`, `nss_hesiod`, `libnsl` via profile `LD_LIBRARY_PATH` or host nscd | |
| locales (dirs: langpacks, minimal; `C.utf8` in common) | `/usr/lib/locale` | archive + `LOCALE_ARCHIVE` | default `$glibc/lib/locale`; **`LOCPATH`** (upstream) from each langpack's setup hook/profile, **never set where an archive is provided** (Correction [NM-fix]) | [NF-S6] de_DE via LOCPATH ok; [SG] en_US ok; [NM-fix] LOCPATH hides the archive |
| `locale-archive` (`all_langpacks`, 224 MB) | same dir | `LOCALE_ARCHIVE` | **P2** (`LOCALE_ARCHIVE_2_27`, `LOCALE_ARCHIVE`), `runtimeSearchPaths` (no stub: not uniquely Required) | [NF-S6] fails without P2 |
| message catalogs (`share/locale`) | `/usr/share/locale` | `$out/share/locale` | default `$glibc/share/locale`; libc's own domain untranslated unless composed (`TEXTDOMAINDIR` for programs) | accepted |
| `share/i18n` (locale-source) | compiled in | `$out/share/i18n` | default dangles; **`I18NPATH`** from `locale_source`'s hook | [NF-S5] |
| gconv (`lib64/gconv` in out + `gconv_extra`) | one dir + cache | one dir | default `$glibc/lib64/gconv`; **`GCONV_PATH`** from `gconv_extra`'s hook; profiles may run `iconvconfig` | [NF-S6] IBM1364 ok with GCONV_PATH |
| `gconv-modules.cache` (`%ghost`, `%post`) | scriptlet | — | not generated; parse fallback (measured equivalent in `checks.glibc-runtime`) | |
| `TZDIR` | `/usr/share/zoneinfo` | `$out/share/zoneinfo` | default `$glibc/share/zoneinfo` (dangling, `danglingOk`); profiles/NixOS set `TZDIR=$tzdata/share/zoneinfo`; `/etc/localtime` stays FHS (`TZDEFAULT` from sysconfdir) | |
| `libgcc_s.so.1` (dlopen for `pthread_cancel`, `backtrace`) | `/lib64` | `user-defined-trusted-dirs=${xgcc libgcc}/lib` | **`user-defined-trusted-dirs=$libgccForGlibc/lib64:$libgccForGlibc/lib`** (§4.5), passed as `env 'user-defined-trusted-dirs=…' rpmbuild` (§4.4) | [NF-S4,S6] abort without; [E5] both loaders get both dirs as system dirs |
| `/etc/ld.so.preload` | | `/etc/ld-nix.so.preload` | **P3** same | [E5] string in both loaders |

Update [E5] part 4 (spec's own `%build`, store prefix P, `$L` =
`libgccForGlibc`): `ld.so --list-diagnostics` shows `path.system_dirs` =
`$P/lib64/`, `$L/lib64/`, `$L/lib/` (x86_64) and `$P/lib/`, `$L/lib64/`,
`$L/lib/` (i686); `path.rtld` = `$P/lib64/ld-linux-x86-64.so.2` /
`$P/lib/ld-linux.so.2`; `path.sysconfdir` reports `$P/etc` (the nixpkgs
patch's dl-diagnostics change) while the configured `sysconfdir` stays
`/etc`. A 32-bit loader skips the 64-bit `libgcc_s` (wrong ELF class) and vice
versa. Not run yet: P2 locale-archive behaviour at run time and a
`pthread_cancel` test with `libgccForGlibc` in a `/usr`-free sandbox (WP9).

### 4.3 Nix-side glibc patches (`packages/glibc/nix-patches/`, via `prep-hooks`)

Update [HO-glibc]: the three patches are nixpkgs' (26f4107e)
`dont-use-system-ld-so-cache`, `nix-locale-archive` and
`dont-use-system-ld-so-preload`, rebased onto Rocky glibc-2.39-142.el10_2
after its `%prep`: same changes, exact context, they apply with `--fuzz=0`
(the originals needed fuzz 2 and offsets up to 875 lines).
`checks.nn-glibc-prep` (`packages/glibc/prep.nix`) runs `rpmbuild -rp`, then
each patch with `--dry-run --fuzz=0`, then all in order, then greps for
their effects, taking the list from `packages/glibc/default.nix`'s
`nixPatches`.

* **P1 `ld-so-cache.patch`** (required): `LD_SO_CACHE` = `"$prefix/etc/ld.so.cache"`.
  With `sysconfdir=/etc` the relocated ld.so would otherwise consult the host
  cache first and load the host's libc on a Debian host. (Alternative
  `sysconfdir=$out/etc` rejected: `TZDEFAULT` and the spec's `etc` cleanup.)
  [NF-S3/S4] verified as sed; the patch file is the nixpkgs one rebased.
  Update [HO-glibc]: P1 builds both the cache and the conf path from `PREFIX`
  (`$prefix/etc/ld.so.cache`, `$prefix/etc/ld.so.conf`), not `SYSCONFDIR`.
* **P2 `locale-archive.patch`** (nixpkgs `nix-locale-archive.patch`): env
  `LOCALE_ARCHIVE_2_27`, `LOCALE_ARCHIVE` (via `secure_getenv`: ignored for
  setuid programs). Update [HO-glibc]: it keeps nixpkgs' two host fallbacks,
  `/run/current-system/sw/lib/locale/locale-archive` and
  `/usr/lib/locale/locale-archive`, before the compiled-in
  `$prefix/lib/locale/locale-archive`; dropping them is an open decision
  (§0.4). [E5]: `LOCALE_ARCHIVE_2_27` is compiled into `libc.so`.
* **P3 `ld-preload.patch`** (nixpkgs): `/etc/ld.so.preload` → `/etc/ld-nix.so.preload`.

They are applied by `%__spec_prep_post`, never added to the spec's patch list;
parity allowlists their effects by name. Nothing else (no `NIX_ETC_*`, no
CS_PATH change).

### 4.4 Build-tree quirks (measured, generic or glibc override)

host-aware `CONFIG_SITE` + `glibc.site`; `NIX_NO_SELF_RPATH = "1"` and
`NIX_DONT_SET_RPATH = "1"` as **derivation attributes** (ld.so DT_RPATH assert
[NF-S3 #4]); real `lib64` dirs in inputs [NF-S3 #5]; `--with-headers` resolved by
the self-prefix alias (E2) or substitution; `rpm -ql kernel-headers` in the
sysroot subpackage yields nothing without an rpmdb (unshipped, accepted).

Update [E2]: `--with-headers=%{_prefix}/include` resolves through the alias
(configure: `checking for symlinks in $P/include... ok`); no substitution.

**Correction [E5] part 2: non-identifier env keys.** `user-defined-trusted-dirs`
is a make variable that glibc's `elf/Makefile` takes from the environment;
[E5] part 1 shows it crosses rpmbuild → `%build` (bash) → `env … make -r` →
sub-makes with the unmodified spec, for both builds (x86_64 and glibc32). But
with `__structuredAttrs`, nixpkgs' setup.sh exports structured `env` entries
with `declare -x`, which aborts on the hyphenated name (`not a valid
identifier`) before the build starts. So §8.1's "hyphenated make vars via
`env`" cannot be implemented by copying the override's `env` into the
derivation's `env`: mkRpmPackage must keep keys that are not shell
identifiers out of the structured `env` and pass them as `env 'NAME=VALUE'
rpmbuild …` (e.g. from a separate structured attribute read as a bash
associative array, or `bwrap --setenv`); identifier keys
(`NIX_NO_SELF_RPATH`, `NIX_DONT_SET_RPATH`) stay derivation attributes.
`overrides.nix` should assert the route. Verified fallback with the same
result: `prepScript = "echo 'user-defined-trusted-dirs=…' > configparms"` in
the source dir (part 3; `configparms` wins over the environment; the build
dir's is deleted by `build()`).

### 4.5 libgcc for glibc

`rocky.<stage>.libgccForGlibc` = `runCommand "libgcc-s-<gccevr>"`: copy
`libgcc_s.so.1` (64 + 32-bit) from the previous stage's gcc `libgcc` output,
`patchelf --remove-rpath`, `allowedReferences = [ ]`. libgcc_s NEEDs `libc.so.6`,
which is always already loaded when glibc dlopens it, so no RUNPATH is needed;
the copy references nothing, so it adds no previous-stage glibc to the final
closure (the naïve trusted dir to `gcc.libgcc` would). If a program already
loaded a newer libgcc_s via its RUNPATH, the loader reuses it by soname.
Source per stage: S1 → stage0 gcc's libgcc_s (bootstrap exception, named);
S3 → gcc¹ (S1, SRPM-built) libgcc.

Update [HO-glibc]: implemented as `bootstrap/nn/libgcc-for-glibc.nix`, exposed
as `nn.libgccForGlibc` (`{ bootPkgs, src, lib64 ? "usr/lib64", lib32 ?
"usr/lib", version, stage ? "s0" }`; for S3 pass gcc¹'s libgcc output with
`lib64 = "lib64"; lib32 = "lib";`), passthru `rockyStage = "s0"`. On the
stage0 copy `patchelf --remove-rpath` is a no-op (no RPATH; bytes identical).
`checks.nn-libgcc-for-glibc`: closure only itself, no store-path strings, no
RPATH/RUNPATH, SONAME `libgcc_s.so.1`, ELF64 in `lib64`, ELF32 in `lib`.

### 4.6 glibc outputs that need later packages

`utils` (memusagestat → libgd, libpng, libz) and `nss_db` (makedb → libselinux):
in S1 those libs are nixpkgs-built (`stage0.glibcBuildDeps`) → raw outputs keep
NEEDED unresolved (`allowUnresolvedNeeded`, S1 only); `lateBind.utils.libs = [
"gd" "libpng" "zlib-ng" ]`, `lateBind.nss_db.libs = [ "libselinux" ]` produce the
bound outputs once Rocky builds exist (S3). `common`/`utils` shebangs
(`#!/usr/bin/bash` in ldd/sotruss/tzselect/xtrace/memusage; mtrace perl [BP-9])
→ `lateBind.common.interpreters = [ "bash" ]`, `utils = [ "bash" "perl" ]`.
Update [HO-glibc]: `benchtests` scripts have `#!/usr/bin/python3` (and bash)
shebangs → `lateBind.benchtests.interpreters = [ "bash" "python3" ]` and an
S1 `fhsAllowlist` entry. Open (WP6/WP11): that in S3 `lateBind` exempts the raw
late outputs' unresolved NEEDED (§2.6 step 4) *and* their FHS shebangs, and
what S3a's `stage.glibcBuildDeps` provides (gd, libpng, libselinux are not
Rocky-built before S3d); otherwise the S1-only `allowUnresolvedNeeded` and
`fhsAllowlist` conditions must also cover S3.

---------------------------------------------------------------------------

## 5. Toolchain and stdenv (Q5)

### 5.1 cc-wrapper / bintools-wrapper (nixpkgs sources, every stage)

From [NF-S2] (unmodified `wrapCCWith`/`wrapBintoolsWith` drove the stage0 Rocky-
source gcc 14.3.1 / binutils 2.41; [NF-S3] built all of glibc through them):

* `libc` adapter: `glibc // { lib = glibc.dev; dev = glibc.dev; out = glibc.out;
  libdir = "/lib64/"; incdir = "/include"; }` (crt*.o, `libc.so` script and
  `libc_nonshared.a` are in `-devel` [NF-S6]); `nix-support/dynamic-linker` =
  `$glibc/lib64/ld-linux-x86-64.so.2`, `dynamic-linker-m32` = `$glibc/lib/ld-linux.so.2`.
* `cc-cflags-before` empty (no frame-pointer flags); `NIX_HARDENING_ENABLE=""`
  (hardening = redhat-rpm-config's `%optflags`/`%build_ldflags`); **no
  `reproducible-builds.sh` hook** ([F-1]: S3's DWARF carried `-frandom-seed=
  nncpaslng9`); `--enable-new-dtags` in `ldflags-before`.
* **`-ffile-prefix-map=<p>=/usr`** for every `-isystem`/`-idirafter` input root and
  the gcc prefix (cc-wrapper extension in `lib/rocky/cc/add-prefix-map.sh`, a
  `cc-wrapper` `extraBuildCommands` hook) → DWARF/`__FILE__` Rocky-identical and
  free of input store paths ([NF-S3]: ld.so's retained DWARF named kernel-headers,
  build-deps, gcc include). Validated by **E1**.
  **Correction [E1] review fix 1:** mapping only the roots named by
  `-isystem`/`-idirafter` is not enough: gcc names a header found in a system
  include dir by its realpath when that is shorter, so a symlink-farm include
  root leaks its targets' store paths (the first E1 pass depended on a
  3-character margin). The hook (`nix-support/cc-wrapper-hook`) now maps
  (a) every input, from `NIX_ROCKY_MAP_ROOTS`, which the wrapper's setup hook
  (`map-roots.sh`) fills with every dependency of the stdenv build, propagated
  ones included; (b) every store root named by `-I -iquote -isystem -idirafter
  -cxx-isystem`, the build's own outputs included; (c) the store roots the
  symlinks of named store system include dirs resolve to (cached per build,
  writable roots not walked); (d) store files named by `-include`/`-imacros`
  and store source files; `<root>/usr=/usr` after the plain maps for FHS-in-store
  trees. Cost ~2 ms per compile warm. It drops `-frandom-seed=*` coming from the
  environment (a seed the build passes itself is kept).
  **Result [E1]: PASS.** The relocated glibc built through `nn.cc.stage0`
  references only itself; 0 foreign full paths and 0 pieced input windows in
  14 254 files; ld.so `.debug_str`/`.debug_line_str` identical to the
  milestone-1 FHS build; no `-frandom-seed` in any producer; `nix build
  --rebuild` bit-identical (after moving the rpmbuild log out of `$out`).
  Limit: the map cannot tell which input a header came from, so DWARF is no
  evidence of build purity; that stays with the view and §7.3.
  Interface [HO-cc]: mkRpmPackage must keep the declared inputs as stdenv deps
  (or add them to `NIX_ROCKY_MAP_ROOTS`) and let the variable pass through
  bwrap and rpmbuild; with `prefixView`, `-ffile-prefix-map=$out=/usr` is
  required while rpmbuild runs ([E2] #2, §1.5).
* self-rpath `lib64` instead of `lib` (preHook overriding `_addRpathPrefix`).
  Update [HO-cc]: implemented as `lib64-rpath.sh`, appended to the wrapper's
  setup hook; it applies only inside a stdenv build (through `NIX_LDFLAGS`).
* gcc must be a copy/relocated build, not a symlink farm [NF-S2]; GNU ld
  scripts in the toolchain must name store paths (true by construction for
  relocated Rocky gcc/glibc via §2.5).
* Update [HO-cc], as built (`lib/rocky/cc/wrap.nix`, `nn.cc.wrap { libc; name ?
  "rocky-s1"; }`, `checks.nn-cc-toolchain`: 148 PASS, 0 FAIL, `--rebuild`
  identical [E1]): `m32-libc.sh` makes `-m32` take crt files and `libc.so`
  from `<libc>/lib` (gcc never looks in `../lib` for a `-B` dir; without it
  `-m32` programs did not link); the gcc copy's libstdc++ and libquadmath get
  RUNPATH `$ORIGIN`; extra names `x86_64-redhat-linux-gcc/g++/c++` and links to
  the unwrapped gcc-ar/gcc-nm/gcc-ranlib/gcov; the libc adapter sets
  `outputSpecified = false` (otherwise `getDev` returned `out`);
  `NIX_ENFORCE_PURITY` is forced off (`enforcePurity = false`), so nixpkgs'
  `/usr` filtering does not apply in `mkShell` use (the stage0 gcc has no
  no-sys-dirs patch either). The wrapper works from PATH with no `NIX_*`
  variables (everything comes from its `nix-support` files), so the shim only
  has to put `$wrapper/bin` first on PATH or into the `/usr/bin` view.
  Suggested: `strictDeps`, so nixpkgs tool `-dev` include dirs stop reaching
  `NIX_CFLAGS_COMPILE` (E1 saw 30). Known limit: with the `stage0Libc` loader,
  a program linked `--as-needed` against libstdc++ cannot find `libm.so.6`
  (the loader searches only FHS dirs); not the case with a relocated glibc.
* From S2 on the wrapper derivations are instantiated with `stdenvNoCC =
  rocky.<stage>.stdenvNoCC`, `runtimeShell`/`coreutils`/`gnugrep` = Rocky's,
  `expand-response-params` compiled by the Rocky stdenv from nixpkgs' C source.
  nixpkgs contributes *source files* only (setup.sh, wrapper scripts, hooks);
  the eval-time assertion (§7.3) proves no nixpkgs derivation remains.
  **Update [E6]:** with only `stdenvNoCC` overridden, the wrappers still pull
  exactly four nixpkgs derivations through their `callPackage` defaults:
  `runtimeShell` (bash-5.3p9, `bashNonInteractive`), `coreutils`, `gnugrep`,
  `expand-response-params` (18 chains, = the wrappers' inputDrvs from `nix
  derivation show`). Passing those four explicitly makes the report empty and
  the composition still builds and runs a C program. `nn.cc.wrap` must pass
  them from S2 on.

### 5.2 Rocky gcc in the Nix world

Relocated Rocky gcc (S1 on) gets one Nix patch, `packages/gcc/nix-patches/no-sys-dirs.patch`
(from nixpkgs): no `/usr/include`, `/usr/lib64`, `/lib64` default search dirs,
so a Rocky gcc in `mkShell` on a non-Rocky host never sees host headers/libs.
gcc's split (`gcc`, `cpp`, `gcc-c++`, `libgcc`, `libstdc++`, …) is
prefix-relative (driver finds `cc1` under `libexec/gcc/<triple>/14/` — union
of gcc/cpp/gcc-c++) → `mergeOutputs = [ [ "gcc" "cpp" "gcc-c++" "gcc-gfortran" … ] ]`,
runtime libs (`libgcc`, `libstdc++`, `libgomp`, …) stay separate outputs.

### 5.3 stdenv

`rocky.<stage>.stdenv = import "${nixpkgs}/pkgs/stdenv/generic" { … }`:
`initialPath` = the stage's coreutils findutils diffutils sed grep gawk tar gzip
bzip2 xz zstd make bash patch file; `shell` = bash; `cc` as §5.1;
`extraNativeBuildInputs` = patchelf (nixpkgs source built by the previous Rocky
stage; build tool only); `allowedRequisites` = its own components (nixpkgs pattern).
Fixup settings for mkRpmPackage: `dontStrip`, `dontPatchELF` (Phase E replaces
it), `dontMoveLib64`, `dontMoveSbin`, `dontMoveDocs`, `dontGzipMan`;
`patchShebangs --host` on. Update [NM-fix]: nixpkgs 26f4107 has no
`dontMoveDocs`; the `multiple-outputs.sh` hooks are switched off as listed in
§2.12. Setup hooks from nixpkgs: `multiple-outputs.sh`,
`patch-shebangs.sh`, `audit-tmpdir.sh`; Rocky: `lib64-paths.sh` (pkg-config/cmake
`lib64`), `rocky-rpm-macros.sh` (collects `lib/rpm/macros.d` of macro-package
inputs into `NIX_RPM_MACRO_DIRS`).

### 5.4 rpmbuild in that world: the tool shim (`lib/rocky/tool-shim.sh`)

bwrap, mechanism from `lib/chroot.sh` and [NF-S3] (sandbox root is read-only →
own root): new root tmpfs; bind `/nix`, `$NIX_BUILD_TOP`, sandbox `/etc`, `/proc`,
`/dev`, tmpfs `/tmp`; `/usr` = view (§1.5) built in `$NIX_BUILD_TOP/view` by
`lib/rocky/mkview.py` from `PATH` + `$rockyViewInputs`; `/bin`, `/sbin`, `/usr/sbin`
→ `/usr/bin`; `/usr/lib/rpm` = rpm config; `$out` ← view (if `prefixView`).

Update [E2], [HO-shim], as built (`nn.toolShim`, `checks.nn-shim`): call as
`${nn.toolShim} [--prefix-view|--no-prefix-view] -- CMD…`. Reads
`rockyViewInputs` (whitespace/`:` separated, or the list attribute from
`$NIX_ATTRS_JSON_FILE`; an FHS-layout input contributes `<p>/usr/<dir>`),
`RPM_CONFIG_DIR` (bound read-only at `/usr/lib/rpm`, masking any input's
`lib/rpm`, reported), `ROCKY_PREFIX_VIEW`, `ROCKY_PREFIX_VIEW_DIRS`,
`ROCKY_VIEW_COLLISIONS` (tab-separated report: kind, rel, winner, loser).
Correction of the text above: each call plans its own view in `mktemp -d
$NIX_BUILD_TOP/rocky-view.XXXXXX` and removes it at the end (a shared
`$NIX_BUILD_TOP/view` let a nested call empty the outer `/usr/bin`); the
include/lib dirs are overlayfs, not symlinks (§1.5); `ROCKY_PREFIX_VIEW` and
`ROCKY_VIEW_COLLISIONS` are unset inside, so nested calls do not re-alias;
`PWD=/`; `$TMPDIR` and `$PWD` are bound when outside the build top; SIGPIPE
is reset to default; coreutils by absolute path. The environment, PATH
included, is passed through unchanged. `nn.toolShim.mk { runCommand bash
bubblewrap coreutils python3 }` rebuilds it over later stages' tools.
`PATH` inside: store PATH, except packages below the interpreters (glibc, gcc,
bash, perl, python, coreutils in S1–S3) get `PATH=/usr/bin` so configure records
FHS interpreter paths that patchShebangs/lateBind later bind ([NF-S3]: no nixpkgs
bash/perl path in any output although configure saw them).

### 5.5 rpm and its configuration

* rpm engine: S1 = stage0 rpm 4.19.1.1 (FHS, reached as `/usr/bin/rpmbuild`
  through the view); S2 builds Rocky `rpm` with `--without sequoia --without
  plugins` ([BP-8]: Rust-free) by mkRpmPackage; S3 uses that; the shipped
  `rocky.rpm` gains sequoia once `rocky.rust` exists. Always reached as
  `/usr/bin/rpmbuild` with `RPM_CONFIGDIR=/usr/lib/rpm`.
  Update [RC]: rpm used outside the shim with `RPM_CONFIGDIR=<config>` prints
  `cannot open /usr/lib/rpm/rpmrc` (redhat/rpmrc includes that literal path)
  and loses the rpmrc data; `rpm --eval`/`-qp` still work, but headers should
  be read inside the shim (§2.1). Correction [RC-13]: the config's
  `/nix/store` guard allows the store paths of the rpm and of the macro
  packages themselves (a relocated rpm's `platform/*/macros` names its own
  `$out`) and rejects any other.
* `lib/rocky/rpm/config.nix` → `rpmConfig { rpm, macroPkgs, extraMacroDirs }`: copy of
  rpm's `lib/rpm` (or `usr/lib/rpm` for stage0) + `redhat-rpm-config` + every
  `*-srpm-macros`/`*-rpm-macros` input's `lib/rpm/macros.d` (relocated packages
  install them there via `%_rpmmacrodir`) + `rocky-release` `macros.dist` +
  `nix/macros.nix-reloc` (template, appended to `redhat/macros` by
  `nix/instantiate`, Correction §1.2) + `nix/` scripts. Two sources giving the
  same file with different contents is an error. As built:
  `lib/rocky/rpm/config.nix`, `rpmConfig { rpm ? stage0.rpm, macroPkgs ? [ ],
  extraMacroDirs ? [ ], baseMacroPkgs ? <stage0 set> }`, default instance
  `nn.rpmConfig` (passthru `configSite`, `rpm`, `instantiate`;
  `checks.nn-rpm-config`: 160 ok, 0 FAIL, `--rebuild` identical [RC]). Macro packages are ordinary
  `nativeBuildInputs`; the config is assembled per build from
  `NIX_RPM_MACRO_DIRS` (cheap copy), so adding a macro package rebuilds nothing else.
* brp scripts run as Rocky runs them (`%__os_install_post`): strip,
  strip-static-archive, compress (`%{_prefix}`), mangle-shebangs (→ FHS; Nix binds
  later), python-bytecompile, `check-rpaths`, `check-buildroot`.
  **Correction [E2] #5, [E3] hazard 2:** `check-rpaths` rates every store
  RUNPATH 0x0002 "invalid" and fails the build; **`QA_RPATHS=0x0002` is
  needed** in rpmbuild's environment (the original text "accepted;
  `QA_RPATHS` not needed" was wrong). brp-ldconfig runs `/sbin/ldconfig -N -r
  BUILDROOT`, which needs Rocky's static ldconfig in the view (nixpkgs' fails
  with "Can't open cache file directory") [RC].
* Update [RC-12]: rpmbuild runs with `SOURCE_DATE_EPOCH` unset (`env -u`), so
  `%source_date_epoch_from_changelog` takes effect (BUILDTIME = changelog
  date; with the stdenv's value it is 1980).
* debuginfo: Rocky's find-debuginfo + dwz + gdb-add-index (gdb as a build tool
  from S2; S1 uses nixpkgs gdb, build-time only); all debug subpackages → one
  `debug` output (`lib/debug/.build-id/xx/….debug`, `src/debug`); `debug` may
  reference `out` (DWARF), never the reverse (checked). Not exercised yet:
  find-debuginfo through the `BUILDROOT/usr` fold link (the WP2 test specs
  disable debuginfo; E1/E2 used the spike recipe) [RC].
* `%check`: `doCheck` (default false in S1/S2, true in S3 where it passes;
  per-package reason otherwise) maps to omitting `--nocheck`; runs in the shim.

### 5.6 Build inputs

`nativeBuildInputs`/`buildInputs` = `builddeps.json` (§8.2) mapped to
`rocky.<stage>.rpm.<name>`; tools → native, `-devel`/libs → host, macro
packages → native. `propagatedBuildInputs` of `dev` outputs = the `-devel`
subpackage's Requires mapped to outputs (static, from `deps.json.gz`; e.g.
glibc-devel → kernel-headers dev, libxcrypt-devel).

---------------------------------------------------------------------------

## 6. Bootstrap (Q6)

| stage | stdenv / cc | builds (all mkRpmPackage, relocated, split) | output closure rule | build purity |
|---|---|---|---|---|
| **S0** (exists) | FHS chroot; nixpkgs-built Rocky-source gcc/binutils/glibc; stage0 rpm | bootstrap files | — | — |
| **S1 boot toolchain** (`rockyBoot.s1`) | nixpkgs `stdenvNoCC` tools; cc = wrapper(stage0 gcc *copy*, stage0 binutils, libc = stage0 glibc for glibc¹, then **glibc¹**) | kernel-headers, **glibc¹ (milestone M1)**, macro packages (noarch: redhat-rpm-config, *-srpm-macros, rocky-release), gmp, mpfr, libmpc, isl (in gcc.spec), zlib-ng, zstd, xz, **binutils¹** (`--without debuginfod`), **gcc¹** (no-sys-dirs) | S1 outputs + named exceptions (`libgccForGlibc` from stage0, `allowUnresolvedNeeded`) | not asserted |
| **S2 boot tools** (`rockyBoot.s2`) | cc = wrapper(gcc¹, binutils¹, glibc¹); tools from S2 as they appear, nixpkgs fallback for the rest | stdenv set (~80 SRPMs [BP-1/3]): bash coreutils sed grep gawk findutils diffutils patch tar gzip bzip2 cpio file make which util-linux m4 bison flex pkgconf gettext texinfo autoconf automake libtool perl(+modules) python3.12(+deps) rpm (`--without sequoia`) popt lua sqlite libarchive libxml2 acl attr libcap elfutils debugedit dwz gdb-minimal bubblewrap patchelf(nixpkgs src) + reference closure (openssl curl krb5 …) | S1 ∪ S2 outputs | not asserted (nixpkgs fallback tools allowed, listed) |
| **S3 final** (`rocky.*`) | S3a: stdenv(S2 tools), cc = wrapper(gcc¹, binutils¹, glibc¹) → **glibc** ; S3b: cc libc = rocky.glibc → **gcc**, binutils, gmp/mpfr/libmpc/…; S3c: cc = wrapper(rocky.gcc, rocky.binutils, rocky.glibc) → the stdenv set again; **`rocky.stdenv`** = generic stdenv over S3c; S3d: everything else with `rocky.stdenv` | all 2217 SRPMs | **S3 outputs only** (+ `libgccForGlibc` from gcc¹, references nothing) | **asserted at eval time**: direct inputs ∈ S2 ∪ S3 ∪ lock FODs ∪ allowed source files |
| **S4 check** (`checks.stdenv-fixpoint`) | `rocky.stdenv` | glibc, gcc, binutils, stdenv set rebuilt | — | — |

Rules:

* Each stage uses only the previous stage and itself; transitions assert
  `passthru.rockyStage` of gcc, binutils, glibc, coreutils, bash, patchelf
  (`isBuiltBy` predicates, nixpkgs pattern).
* **Fixpoint criterion**: S4 ≡ S3 for the stdenv set after store-hash
  normalisation (the existing `nukeStore` sed, length-preserving), identical
  bytes except documented ar dates; if not, S4 is promoted to S3c and the check
  repeats. gcc's own internal 3-stage bootstrap already makes gcc S3 compile itself.
* glibc is rebuilt by the final toolchain *path* once in S3a (by gcc¹ = Rocky
  SRPM-built gcc) — the nixpkgs pattern (glibc built by the previous stage's
  compiler); S4 shows whether a glibc built by `rocky.gcc` differs (expected: no
  loaded-section difference beyond store paths; else glibc moves to S3c).
* Rebuild bill: nixpkgs bump → S0–S3; stdenv-set SRPM bump → S2 member + S3; leaf
  bump → itself + reverse deps.
* Update [E2] #7, S1 hazard: nixpkgs libraries linked into programs that use
  the stage0 libc 2.39 pull in nixpkgs glibc 2.42's `libdl.so.2`/
  `libpthread.so.0` through their RUNPATH; those need
  `GLIBC_ABI_DT_X86_64_PLT`, so the program does not start (sed run by
  help2man; krb5 configure's libss test). E2 used RUNPATH-patched copies;
  `stage0.glibcBuildDeps`' version check would not catch it. S1 library
  inputs must be stage0-libc-safe or Rocky-built.
* Update [LK]: `order.json` is purely graph-driven: the feedback-arc set puts
  gcc at level 3, so 28 of gcc's needs are back edges; pinning the stdenv set
  to an earlier stage is not done yet.

---------------------------------------------------------------------------

## 7. Enforcement and verification (Q7)

1. **Output closure (Nix-enforced, inductive)**: `__structuredAttrs = true;
   outputChecks.<o>.allowedRequisites = siblings(o) − {debug, logs} ∪ runtime-
   input outputs' closures (eval-time, from `passthru`) ∪ stage exceptions`;
   `disallowedRequisites` = every S0/S1/S2 derivation and every raw output that a
   bound output replaces (in S3). `debug` may reference siblings; nothing may
   reference `debug`/`logs`.
   Update [E6]: `stdenv.mkDerivation` maps `disallowedRequisites` (and
   `allowedReferences`/`allowedRequisites`, `outputChecks` under structured
   attrs) through `unsafeDerivationToUntrackedOutpath`, so listing S0/S1/S2
   derivations there puts nothing into the S3 sandbox; only a raw
   `builtins.derivation` would realise them (the purity check flags that).
2. **Nested scan** (Phase D/G, `tools/rocky-partition/scan.py`, decoders from
   `rpm_purity.py`): every `/nix/store/<hash>` string, also compressed and pieced,
   must be allowed; hidden ones registered via `nix-support/hidden-references`.
3. **Build purity (S3/S4)**: `lib/rocky/purity.nix` → `assertBuildPure stage
   attrs`: `builtins.getContext` over all string attrs (and `drvAttrs` of the
   stdenv/cc-wrapper derivations); every derivation in the context must be in
   `stage.allowedBuildDrvs` (a set keyed by `drvPath` of S2 ∪ S3 packages, lock
   FODs); plain sources only from `lib/rocky/allowed-sources.nix` (nixpkgs
   `pkgs/stdenv/generic`, `pkgs/build-support/{cc,bintools}-wrapper`,
   `pkgs/build-support/setup-hooks`, repo files). No IFD; runs under
   nix-eval-jobs.
   **Correction [E6]:** the allowed sources also need
   `pkgs/build-support/wrapper-common` (`utils.bash`, `darwin-sdk-setup.bash`,
   substituted by both wrappers' postFixup; without it the full E6 stage
   fails) and `pkgs/by-name/ex/expand-response-params` (the C source §5.1
   compiles); both are in `lib/rocky/allowed-sources.nix`.
   **Update [E6], [HO-purity], as built** (`nn.purity`, `checks.nn-purity`: 42
   eval-time tests): `assertBuildPure`, `check stage drv` (no-op unless
   `stage.buildPure`; guards only `drvPath` and each output's `drvPath`,
   never `outPath`, so dependents do not force it), `violations`, `report`,
   `forStage`, `drvSet`. It looks into the stage's `stdenv`, `stdenvNoCC`,
   `stdenv.cc`, `cc.bintools` (memoised per drvPath). Lock FODs are allowed
   by output hash. Rules for the stage (WP6): set `purityChecker =
   nn.purity.forStage <stage>` once per stage (shared memo: ≈0.16 ms per
   package vs ≈1.7 ms per package; 2200 trivial packages 2.2 s vs 1.8 s
   unchecked); build `allowedBuildDrvs` with `nn.purity.drvSet` (it
   registers every output's drvPath, so `raw // { dev = bound.dev; }` is
   allowed through any output), never from `.drvPath` of checked derivations
   (infinite recursion); a `.drvPath` string in a build input is a
   `drv-closure` violation (it puts the whole .drv closure in the sandbox).
   Limits: context-free store paths (`unsafeDiscardStringContext`) are
   invisible; filtered or renamed source copies (`lib.fileset.toSource`,
   `builtins.path { filter }`, e.g. `partitionTool`) cannot be traced without
   IFD and go into `stage.extraAllowedSources` as store-path strings. Not yet
   exercised with real mkRpmPackage/mkStage derivations.
4. **Global audit** `checks.rocky-closure`: `exportReferencesGraph` over all
   `rocky.*` outputs: every path in every closure must carry `rockyStage = "s3"`
   (by name map) or be `libgccForGlibc`.
5. **Parity vs official RPMs** (relocated front end `tools/nn-parity.py`, reusing
   `rpm-parity.py` comparators and `abi-compare.py`):
   * per subpackage: relative file set (official `/usr/x` ↔ `<o>/x`, `/etc/x` ↔
     `<o>/etc/x`, ignoring `.build-id`, dirs, `%ghost`), modes, symlink targets
     (normalised `$X/rel` ↔ `/usr/rel`), `%config/%doc/%license` flags,
     Requires/Provides from the transient headers — [SG] already reached 221/221;
   * content: bytes equal for files without store paths; text equal after mapping
     each output path → `/usr`; ELF: dynsym + versions, SONAME, NEEDED, GNU
     properties, section list, loaded-section bytes after store-path
     normalisation (displacement-normalised disassembly where string lengths
     shift — method used today for memusagestat); `abi-compare.py` with a path
     map: glibc must stay "0 unexpected, no allowlist" (709 DSOs, 3541 members,
     480 headers);
   * the FHS twin build (existing `packageSets.glibc`) stays the bit-level anchor.
6. **Behaviour** (`checks.nn-glibc-runtime`, from `packages/glibc-runtime` +
   [NF-S4/S6] + [SG test.nix]): in a plain sandbox (no `/usr`, no `/lib64`): ld.so
   `--list-diagnostics`/`--help`, programs compiled by the S1 wrapper against
   `glibc.dev` (dynamic, `-static`, `-m32` via `glibc32`→merged `out`), locales
   via `LOCPATH`/`LOCALE_ARCHIVE` (885 locales), iconv via `GCONV_PATH` (1180
   charsets), NSS, `getconf`, `pthread_cancel` (libgcc trusted dir); report
   compared with the official-RPM root (existing chroot runner) after path
   normalisation. Update [HO-partition], [HO-glibc]: no program from a
   partitioned output has been run yet (the glibc replay and E3 outputs were
   checked structurally and by Nix only); P2 at run time and `pthread_cancel`
   with `libgccForGlibc` are WP9's.
7. **Reproducibility**: `nix build --rebuild` per SRPM (CI sample + glibc),
   SOURCE_DATE_EPOCH macros, no random seed, deterministic patchelf/partition,
   transient RPMs not outputs, ar dates as documented today.
   Update [E1], [E2], [RC]: the E1 glibc, the E2 `which` view build,
   `checks.nn-cc-toolchain` and `checks.nn-rpm-config` pass `--rebuild` once
   the rpmbuild log (random `rpm-tmp.*` names, make interleaving) stays out of
   `$out` (it goes to `nix log`; WP6 should do the same, the `logs` output
   then holds only deterministic content). krb5 is not bit-reproducible: its
   shipped `config.log` differs in LTO temp names [E2]. The SOURCE_DATE_EPOCH
   macros need `env -u SOURCE_DATE_EPOCH` (§5.5).
8. **Checks that exist** (revision 2): `checks.nn-cc-toolchain`, `nn-shim`,
   `nn-partition-selftest`, `nn-partition-replay`, `nn-rpm-config`,
   `nn-glibc-prep`, `nn-libgcc-for-glibc`, `nn-order`, `nn-purity`, `nn-names`.
   `nn-partition-replay` builds its own [NF-S3] glibc tree (~20 min,
   big-parallel) and, through `hydraJobs.checks`, runs in CI.

---------------------------------------------------------------------------

## 8. Scaling to ~2200 SRPMs (Q8)

### 8.1 Per-package overrides `packages/<srpm>/default.nix` (optional; typed)

```nix
{ lib, stage, rocky }: {
  # recipe
  defines = { };                  bconds = { with = [ ]; without = [ ]; };
  configSite = null;              # extra CONFIG_SITE fragment
  nixPatches = [ ];  prepScript = "";
  specSubstitutions = [ ];        # [ { from; to; count; } ] exact count asserted
  env = { };                      # incl. hyphenated make vars via `env`
  doCheck = false;  prefixView = true;  strictFhs = false;
  inputs = { add = [ ]; addNative = [ ]; drop = [ ]; };
  stage = null;                   # bootstrap placement for low packages
  # outputs
  prefixSubpackage = null;  mergeOutputs = [ ];  layout = { };
  runtimeSearchPaths = { };  unionDirs = { };  danglingOk = [ ];
  opaqueRefs = [ ];  forward = { deny = [ ]; };
  noPatchelf = [ ];  allowUnresolvedNeeded = [ ];  fhsAllowlist = { };
  lateBind = { };                 # { <output> = { interpreters = [..]; libs = [..]; }; }
  lateReferrers = { };            # { <late output> = [ sibling outputs referencing it ]; } (verified by the build)
}
```

Validated by `lib/rocky/overrides.nix` (unknown keys → eval error). Default: no
file. Expected volume: 14.1 % of specs have hazards handled generically, 1.6 %
need a look [SG scan]; 0/20 relocated builds broke [SG]; known merge class
"prefix-relative": gcc, python3.12, perl, ruby, lua, tcl, guile, llvm/clang, rust,
golang, java (one merge each).

Update [NM], [NM-fix], as built (`nn.overrides`, field reference
`packages/README-overrides.md`, `checks.nn-names`): the 25 fields above with
nested records and defaults; all errors of a file reported at once, each
naming the file and key path; cross-field rules (merge groups ≥ 2 members and
disjoint; `runtimeSearchPaths` values ∈ the unions table; `lateReferrers`
keys ∈ `lateBind`; `defines`/`layout` keys are macro names; `defines` values
single-line; output-relative path and glob shapes). `overridesFor { inherit
stage rocky; } srpm` loads `packages/<srpm>/default.nix` passing only the
arguments it names; `checkOutputs file overrides outs` cross-checks output
names against `nn.names.outputsFor`.

Changes still to make to the schema (requested of WP6, not yet in
`overrides.nix`):

* **`prefixRelativeOk`** [R10] (output patterns; acks prefix-relative, union
  and dangling references of matching files) and **`integrityOk`** [R14]
  (output patterns; acks `integrity-runpath`): partitioner plan keys with no
  override field yet.
* **`env`** (Correction [E5]): "hyphenated make vars via `env`" stays the
  field's meaning, but keys that are not shell identifiers must take the
  `env 'k=v' rpmbuild` route (§4.4), never the structured derivation `env`;
  `overrides.nix` should assert that.
* **`opaqueRefs`** format (§2.8): PLAN.md's `"<output>[:<rel glob>]"` vs the
  glibc draft's `"<output>/<rel>"`.
* `bconds` is not applied by the lock generator yet (§3.2).

### 8.2 BuildRequires → inputs (static)

`tools/update-lock.py` gains (all outside Nix eval, committed):

* `subpackages.json` (§3.2);
* `builddeps.json`: per SRPM the *direct* providers of each BuildRequire
  (resolver of `resolve-buildrequires.py`, 260/260 vs dnf5; file and rich deps;
  `install_weak_deps=0`), tagged tool/lib/macro from file lists;
* `order.json`: SRPM build graph (direct BR providers: 18 721 edges, largest SCC
  926 [BP-1]), edge classes (doc/test/lang/lib/tool), Eades feedback-arc set
  (771 back edges, 265 targets, 144 SRPMs with library back edges [BP-2]).

Update [LK], as built: producers `tools/lock_builddeps.py`,
`tools/lock_order.py` (both also run by `update-lock.py`; `--derived-only`,
`--no-derived`) and `tools/lock_subpackages.py` (needs nix). builddeps: 23 347
BuildRequires → 21 443 direct inputs; providers tagged tool/lib/macro/other
from the official filelists (matched by pkgid); 132 BuildRequires are
provided only by **unshipped** subpackages of in-lock SRPMs (gdb →
`libipt-devel`, gcc → `glibc32`, …), now resolved against subpackages.json
(98 unshipped providers); **190 occurrences (119 distinct, 154 SRPMs) stay
unresolved** (build-only packages outside the lock, or virtual provides of
unshipped subpackages). order (with the unshipped providers): 18 797 edges,
33 self-loops, largest SCC 949, 782 back edges, 286 boot targets, 150
second-pass SRPMs, 66 levels; deterministic. `checks.nn-order` recomputes the
graph from builddeps.json and requires equality of every derived list (six
tampered copies rejected). Interfaces: `readLock "builddeps.json"` →
`.srpms.<srpm> = { buildRequires; inputs; unresolved? }`, `.providers.<rpm> =
{ srpm; arch; tags; }`; `readLock "order.json"` → `.srpms.<srpm> = { index;
level; needs; back; scc?; }` + `sccs bootTargets secondPass selfLoops stats`.

### 8.3 Build-order cycles

Back edges are satisfied from an earlier stage (S2 stdenv set) or from
`rockyBoot.s2b.<X>` (built with Fedora `%bcond bootstrap`/doc/test off).
Library back edges (144 SRPMs; Update [LK]: 150 with unshipped providers) would put an S2 output in an S3 closure →
`disallowedRequisites` fails → second pass (`rocky.<X>` built again against
the final provider; generated, not hand-written). Self-loops (33: gcc, rust,
golang, java, …) use the previous-stage build (`rockyBoot.s2.<X>`, or nixpkgs'
binary seed inside S0 for rust/go/java, never in closures). Cross-SRPM
*reference* cycles use `lateBind`. `checks.order` verifies the graph after
back-edge removal is acyclic and every back edge has a provider.

### 8.4 Evaluation and CI

Plain derivations; `hydraJobs.nixNative.<stage>.<srpm>` + checks;
`tools/build-jobs.sh` unchanged (nix-eval-jobs, `--check-cache-status`, IFD off).
~2200 derivations / ~7000 outputs: outputs are a static list, lock parsed once.
`big-parallel` for ~30 large SRPMs.

---------------------------------------------------------------------------

## 9. Step 0: cheap experiments (run first, each ≤ 1 h)

| id | question | experiment | decides |
|---|---|---|---|
| **E1** | does `-ffile-prefix-map` remove all input store paths from DWARF incl. ld.so's retained DWARF? | rebuild [NF-S3] `glibc-reloc.nix` with the prefix-map hook and without the random-seed hook; `nix-store -q --references` must be self only; `fragscan.py` on debug files | WP4 hook shape |
| **E2** | do the declared-input `/usr` view and the `$out` self-prefix alias keep builds identical and avoid substitutions? | glibc with `prefixView` and without `--with-headers` substitution; plus which, xz, gzip, sed, m4, expat (from [SG] reloc-spike) built with/without view; compare relative file lists + partition report (no new dangling refs) | default of `prefixView` |
| **E3** | do RUNPATH recompute + gated stubs remove the need for overrides in `foo`/`foo-libs`/`-common` SRPMs? | partition xz (xz/xz-libs), expat, libxcrypt, ncurses (ncurses-base terminfo), krb5 (no eponymous) with the prototype; count errors needing overrides | rule set of §2.6–2.7 |
| **E4** | pieced references: what is hidden from Nix in non-prefix outputs? | run `docs/research/nix-native/fragscan.py` over [NF-S5] split outputs; list outputs ≠ out with fragments | `opaqueRefs` acks for glibc |
| **E5** | does `user-defined-trusted-dirs` reach glibc's make through `env`? | `env 'user-defined-trusted-dirs=…' rpmbuild -bp/-bc` up to `elf/`; `ld.so --list-diagnostics` shows the extra system dir | WP7 mechanism (fallback: `configparms` via `prep-hooks`) |
| **E6** | nixpkgs `wrapCCWith` with a non-nixpkgs `stdenvNoCC` | instantiate wrappers with `stdenvNoCC` = a generic stdenv over stage0 tools; `assertBuildPure` must flag exactly the expected derivations | WP16 |

**Results (revision 2; records in `docs/research/nix-native/experiments/`):**

| id | verdict | consequence (where folded in) |
|---|---|---|
| E1 | **PASS**: relocated glibc through `nn.cc.stage0` references only itself, 0 foreign/pieced input paths in 14 254 files, ld.so DWARF identical to the FHS build, `--rebuild` identical; the hook had to map every input, named store roots and symlink-farm targets (review fix) | §0.2 #13, §5.1 |
| E2 | **`prefixView = true`** under four conditions: overlayfs view (done), `-ffile-prefix-map=$out=/usr` during rpmbuild, library rule, NEEDED guard; glibc and krb5 build unmodified specs; side findings: macro load order, config.site status, `QA_RPATHS`, `/sbin/ldconfig`/`gpgv2`/`getconf`, S1 libdl hazard, package name in `$out` | §1.1–1.5, §5.4, §5.5, §6 |
| E3 | RUNPATH recompute removes all `foo`/`foo-libs` overrides; stubs created 0 times; xz, expat, libxcrypt, pixman need no override, ncurses 3 entries (prefix = base), krb5 4 (one merge); rules R1–R16; FIPS integrity (R14) | §2.2, §2.5.1, §2.6–2.8, §3.1 |
| E4 | `fragscan.py` gives only false positives on split outputs; hash-based scan: no split hash in loaded sections (all are `-frandom-seed`), 7 truncated copies with whole hash, 5 outside `out` → `opaqueRefs`; `lateReferrers`: common ← 138 langpacks, nss_db ← nss_devel | §2.8, §2.9, §11.5 |
| E5 | `env 'user-defined-trusted-dirs=…' rpmbuild` reaches make with the unmodified spec (both loaders get both dirs); structured `env` aborts on non-identifier names; `configparms` fallback works | §4.2, §4.4, §8.1 |
| E6 | wrappers over a stage `stdenvNoCC` leak exactly runtimeShell, coreutils, gnugrep, expand-response-params; the assertion flags exactly those (= Nix's inputDrvs); allowed sources need `wrapper-common`; ≈0.16 ms/package with a shared checker | §5.1, §7.3 |

Note on E4's method: E4 did not run `fragscan.py` as planned but a hash-based
scanner (`piecescan.py`, embedded in E4.md), because `fragscan.py`'s path
windows only produce false positives on split outputs.

Already measured for this synthesis:
* **[F-1]** sysroot `libm.so.6` DW_AT_producer contains `-frandom-seed=nncpaslng9`
  (nixpkgs reproducible-builds hook) → hook off.
* **[F-2]** `fragscan.py`/`fragsec.py` over the [NF-S3] relocated glibc: ld.so
  `.rodata` 7 full + 57 pieced windows (`\0\0\0…/nix/store/nncpaslng931r…`
  32-byte chunks, 15 with partial hashes), ldconfig 10 full + 57 pieced (fixed
  field padded with spaces), localedef 6 + 63, libc.so.6 16 full / 0 pieced.
  Confirms store-by-pieces in exactly the binaries spec-generic named; with
  no-rewrite they are correct bytes, so the only duties are edge registration and
  acks (§2.8). Correction [E4]: the window counts are mostly false positives of
  path windows (every full `$out` reference contains them) plus the
  `-frandom-seed` string; the real pieces are truncated copies of the prefix
  with the hash whole (§2.8).
* **[F-3]** [NF-S3] `bin/memusagestat`: NEEDED libgd/libpng16/libz/libm/libc, no
  RPATH/RUNPATH; `share/info/*.gz` present (brp-compress worked through the fold
  link).

---------------------------------------------------------------------------

## 10. File layout (new files; nothing existing is removed)

```
lib/rocky/
  default.nix               # exports: mkStage, mkRpmPackage, rpmConfig, toolShim, purity, names
  names.nix                 # outputName, storeName, rpmOutputs   (pure functions)
  overrides.nix             # schema + validation, loads packages/<srpm>/default.nix
  mk-rpm-package.nix        # the derivation (§11.1)
  stage.nix                 # mkStage (§11.2)
  late-bind.nix             # bind derivation (§11.3)
  purity.nix                # assertBuildPure, allowedBuildDrvs
  allowed-sources.nix
  unions.nix                # search-path table for hook generation
  config.site
  tool-shim.sh  mkview.py
  cc/ wrap.nix  add-prefix-map.sh  lib64-rpath.sh
  rpm/ config.nix  macros.nix-reloc  nix-scripts/{fold-usr,check-files,prep-hooks}
  hooks/ lib64-paths.sh  rocky-rpm-macros.sh
tools/rocky-partition/      # python package: __main__, headers.py, canon.py, materialise.py,
                            # symlinks.py, scan.py (nested+pieced), rewrite.py, runpath.py,
                            # stubs.py, graph.py, late.py, metadata.py, hooks.py, report.py
  tests/                    # synthetic trees (like parity-selftest-*)
tools/nn-parity.py          # relocated parity front end (rpm-parity comparators, abi-compare map)
tools/layout-suggest.py  tools/spec-hazards.py
tools/update-lock.py        # + subpackages.json, builddeps.json, order.json
bootstrap/nn/
  s1.nix  s2.nix  s3.nix    # stage definitions (mkStage calls)
  libgcc-for-glibc.nix
packages/glibc/
  default.nix               # overrides (§11.5); existing packages/glibc.nix stays (FHS twin)
  glibc.site
  nix-patches/{ld-so-cache,locale-archive,ld-preload}.patch
packages/kernel-headers/default.nix
packages/gcc/nix-patches/no-sys-dirs.patch      (S1, later)
lock/rocky-10.2/{subpackages,builddeps,order}.json
docs/nix-native.md
```

Flake: `legacyPackages.x86_64-linux.rockyBoot.s1.<srpm>`, `.s2`, `rocky` (S3) once
it exists; `checks.nn-*`; `hydraJobs.nixNative`.

Update (revision 2), what exists after the foundation merge (c700802):

```
lib/rocky/default.nix       # plug-in layout: parts/<name>.nix -> legacyPackages.<sys>.nn.<name>,
                            #   checks/<name>.nix -> checks.<sys>.nn-* (args: bootPkgs lib nixpkgsSrc
                            #   lock rpmsLock readLock release fetch stage0 repo self)
lib/rocky/parts/            # cc toolShim partitionTool rpmConfig libgccForGlibc lockgen purity names
                            # overrides unions
lib/rocky/checks/           # cc shim partition rpm-config glibc-prep order purity names
lib/rocky/cc/               # wrap.nix add-prefix-map.sh map-roots.sh lib64-rpath.sh m32-libc.sh
                            # no-purity.sh storescan.py rpm-config.nix stage0-libc-split.nix e1/
lib/rocky/rpm/              # config.nix macros.nix-reloc nix-scripts/{fold-usr,check-files,prep-hooks,
                            # instantiate} tests/
lib/rocky/lockgen/          # rpmspec-query.sh raw2json.py
lib/rocky/e2/               # E2 experiment code (compare.py: scan_refs, scan_needed prototypes)
lib/rocky/{names,overrides,unions,purity,allowed-sources}.nix  config.site  tool-shim.sh  mkview.py
tools/rocky-partition/      # entry script rocky-partition + package rocky_partition/, PLAN.md, tests/
tools/lock_{subpackages,builddeps,order,filelists}.py
bootstrap/nn/libgcc-for-glibc.nix
packages/glibc/{default.nix,glibc.site,late-referrers.nix,prep.nix,nix-patches/*.patch}
packages/README-overrides.md
lock/rocky-10.2/{subpackages,builddeps,order}.json
```

Not yet written (WP6–WP11): `mk-rpm-package.nix`, `stage.nix`,
`late-bind.nix`, `hooks/`, `bootstrap/nn/s{1,2,3}.nix`,
`packages/kernel-headers/default.nix`, `tools/nn-parity.py`,
`tools/layout-suggest.py`, `tools/spec-hazards.py`. `default.nix` already
exposes `rockyBoot = nn.rockyBoot or { }` and `hydraJobs.nixNative`.

---------------------------------------------------------------------------

## 11. Nix interfaces

### 11.1 `mkRpmPackage`

```nix
# lib/rocky/mk-rpm-package.nix
{ lib, nixpkgsSrc, lock, names, overridesFor, rpmConfig, toolShim, partitionTool, purity }:
stage:                                    # from mkStage
{ srpm, overrides ? overridesFor srpm }:  # srpm = lock name
let
  sub   = lock.subpackages.${srpm};       # { names, prefix, shipped }
  outs  = names.outputsFor { inherit srpm sub; inherit (overrides) mergeOutputs prefixSubpackage; };
  # outs = { outputs = [ "out" "dev" … "debug" "logs" ]; rpmOutputs = { "glibc-devel" = "dev"; … }; }
  deps  = stage.resolveBuildDeps srpm overrides.inputs;   # { native; host; runtime; macro; }
  attrs = {
    pname = srpm; version = "${e.version}-${e.release}";  # store name <srpm>-<v>-<r>[-<o>]
    outputs = outs.outputs;
    src = stage.fetch.fetchSrpm srpm;
    nativeBuildInputs = deps.native ++ deps.macro ++ [ stage.tools.bubblewrap stage.tools.python3 ];
    buildInputs = deps.host;
    __structuredAttrs = true;
    rockyPlan = { … };                    # becomes plan.json (§2.1)
    NIX_NO_SELF_RPATH = overrides.env.NIX_NO_SELF_RPATH or null; …
    dontStrip = true; dontPatchELF = true; dontMoveLib64 = true; dontMoveSbin = true;
    dontMoveDocs = true; dontGzipMan = true;
    unpackPhase    = "bsdtar -xf $src -C $NIX_BUILD_TOP/rpmbuild/SOURCES";  # + specSubstitutions
    configurePhase = "write macros, CONFIG_SITE, prep hooks, view";
    buildPhase     = "${toolShim} -- rpmbuild -bb --nodeps --noclean ${checkFlag} --target x86_64 SPECS/${srpm}.spec";
    installPhase   = "python -I -m rocky_partition --plan $NIX_ATTRS_JSON_FILE";  # Correction: see below
    outputChecks   = stage.outputChecksFor outs deps;
    passthru = { rockyStage = stage.name; inherit srpm; inherit (outs) rpmOutputs; overrides = overrides; };
  };
in purity.check stage (stage.stdenv.mkDerivation attrs)   # no-op unless stage.buildPure
```

Result exposed as `stage.pkgs.<srpm>` = `lateBind.wrap raw` when `lateBind != {}`,
else the raw derivation.

**Corrections to the sketch above (revision 2)**, each from the cited record;
WP6 owns the real file:

* `installPhase`: `python3 -I ${partitionTool}/rocky-partition --plan
  "$NIX_ATTRS_JSON_FILE"` (not `-m`) [HO-partition]; `rockyPlan` keys per
  PLAN.md; `subpackages` from `outs.rpmOutputs` minus debug names,
  `unmanagedOutputs = [ "logs" ]`.
* `configurePhase`: `sh ${rpmConfig}/nix/instantiate $NIX_BUILD_TOP/rpmconfig
  --prefix $out --buildtop $NIX_BUILD_TOP --ncpus $NIX_BUILD_CORES --dist
  <distOf srpm>` [RC]; `CONFIG_SITE = "${rpmConfig.configSite} <fragment>"`.
* `buildPhase`: `env -u SOURCE_DATE_EPOCH QA_RPATHS=0x0002 <non-identifier
  env keys as 'k=v'> ${toolShim} -- rpmbuild …` with `rockyViewInputs` = all
  declared input outputs, `RPM_CONFIG_DIR` = the instantiated config,
  `ROCKY_PREFIX_VIEW = prefixView` (default 1), `$out` empty or absent
  before ([RC-12], [E2] #5, [E5], [HO-shim]); `nn.cc.wrap { libc }/bin`
  first on PATH; `/sbin/ldconfig` (Rocky's) and `gpgv2` on PATH; rpmbuild
  output to the Nix log, not `$out` ([E1] review fix 3).
* `NIX_NO_SELF_RPATH` / `NIX_DONT_SET_RPATH` as derivation attributes, not
  exports [HO-cc]; non-identifier `env` keys never in the structured `env`
  [E5].
* `nativeBuildInputs`/`buildInputs`: declared inputs stay stdenv deps (so
  `NIX_ROCKY_MAP_ROOTS` covers them) [HO-cc]; library rule: every declared
  view input that ships shared libraries is also a cc-wrapper input [E2].
* `multiple-outputs.sh` hooks off (§2.12) [NM-fix]; `out` first in
  `outputs` [E6]; `passthru.rpmOutputs = outs.shippedRpmOutputs` for aliases,
  `passthru.unshipped = outs.unshipped` [NM].
* `overrides`: `overridesFor { inherit stage rocky; } srpm` and
  `overrides.checkOutputs file overrides outs` [NM].

### 11.2 `mkStage`

```nix
mkStage = { name, prev ? null, stdenv, ccFor ? (libc: …), tools, rpm, macroPkgs,
            buildPure ? false, exceptions ? [ ], packages }:   # packages: srpm list or "all"
  # returns a fixpoint:
  { inherit name stdenv buildPure; pkgs = { <srpm> = drv; };
    rpm = { <rpm-name> = output; };       # from rpmOutputs of every pkg
    resolveBuildDeps; outputChecksFor; allowedBuildDrvs; fetch; tools; }
```

Update [HO-purity], [E6]: the stage also carries `stdenvNoCC`,
`purityChecker = nn.purity.forStage <stage>` (shared memo),
`allowedBuildDrvs` built with `nn.purity.drvSet`, `extraAllowedSources`
(e.g. `"${partitionTool}"`), `buildPure = true` for S3/S4, and (glibc)
`libgccForGlibc`, `glibcBuildDeps`. `rpm` aliases use `shippedRpmOutputs`;
for a name built by two SRPMs, the shipped one (`duplicateNames`) [LK].

### 11.3 `lateBind`

```nix
lateBind.wrap = raw: { binds }:          # binds: { <output> = { interpreters; libs; }; }
  # one derivation, outputs = L* (from raw's nix-support/rocky-late.json is NOT read at eval:
  # L* is computed at eval from overrides.lateBind + the static referrer list
  # overrides.lateReferrers, which the partitioner VERIFIES (error if incomplete))
  # builder: cp -a raw.<o> -> $o for o in L*; rewrite raw hashes -> bound hashes in symlinks
  # and text (equal length); patchShebangs against interpreters; patchelf --set-rpath for libs;
  # refuses ELF contents referencing raw L outputs.
  # result: raw // { <o> = bound.<o> for o in L*; raw = raw; }
```

Note: `lateReferrers` keeps eval independent of build results; for glibc it is
`common → [ langpack_* glibc_minimal_langpack … ]` generated once from
`subpackages.json` + the partition report and committed in the override (the
build fails if it is incomplete — static, verified, like `mergeOutputs`).
Update [E4]: the generated list (`packages/glibc/late-referrers.nix`, from
Nix's registered references of the S5 split) is `common` ← 138 explicit
`langpack_*` names (not `minimal_langpack`, which is empty), `nss_db` ←
`nss_devel`, `utils`/`benchtests` ← nothing. The bind derivation (WP11) does
not exist yet; only the partition-side L* check is verified [HO-partition].

### 11.4 Developer loop

`rocky.<srpm>.raw.overrideAttrs { keepBuildTree = true; }` adds a `buildtree`
output (BUILDROOT + RPMS, debug only); `tools/rocky-partition --replay <tree>
--remap <old-out>=<new-out>` re-runs the partition against a new set of output
paths using a same-length hash remap of the *development copy* (as [NF-S5] did)
— never used for shipped outputs.
Update [HO-partition], PLAN.md: implemented; `--replay TREE` reads
`TREE/BUILDROOT`, `TREE/RPMS`, `TREE/prefix` and copies files; the remap
covers path names (the debug tree mirrors the prefix), raw bytes, pieced
windows, symlink targets and whole-file compressed members, and recomputes
verified fipscheck `.hmac` files; embedded HMACs do not survive it
(`integrity-replay`). The kept trees used by the checks come from
`tools/rocky-partition/tests/{reloc-tree,trees,stage0-cc}.nix`.

### 11.5 `packages/glibc/default.nix` (S1 form)

```nix
{ lib, stage, rocky }: {
  configSite = ./glibc.site;
  nixPatches = [ ./nix-patches/ld-so-cache.patch ./nix-patches/locale-archive.patch
                 ./nix-patches/ld-preload.patch ];
  env = { NIX_NO_SELF_RPATH = "1"; NIX_DONT_SET_RPATH = "1";
          "user-defined-trusted-dirs" = "${stage.libgccForGlibc}/lib64:${stage.libgccForGlibc}/lib"; };
  inputs.add = [ stage.pkgs.kernel-headers stage.glibcBuildDeps ];  # S1: hoisted stage0 deps
  # specSubstitutions only if E2 says prefixView is not enough:
  # [ { from = "--with-headers=%{_prefix}/include"; to = "--with-headers=%{rocky_kernel_headers}/include"; count = 1; } ]
  mergeOutputs = [ [ "glibc" "glibc32" ] ];
  runtimeSearchPaths = { "lib/locale/locale-archive" = "LOCALE_ARCHIVE";
    "lib/locale" = "LOCPATH"; "share/i18n" = "I18NPATH"; "lib64/gconv" = "GCONV_PATH"; };
  unionDirs = { "lib64" = "rtld system dir; other outputs via RUNPATH";
                "lib/locale" = "LOCPATH"; "share/locale" = "TEXTDOMAINDIR/profile"; };
  danglingOk = [ "share/zoneinfo" ];
  opaqueRefs = [ ];             # filled from E4
  noPatchelf = [ "lib64/ld-linux-x86-64.so.2" "lib/ld-linux.so.2" "lib64/lib*.so*" "lib/lib*.so*"
                 "x86_64-redhat-linux/sys-root/**" ];
  allowUnresolvedNeeded = lib.optionals (stage.name == "s1") [ "libgd.so.3" "libpng16.so.16" "libz.so.1" "libselinux.so.1" ];
  lateBind = { common.interpreters = [ "bash" ]; utils = { interpreters = [ "bash" "perl" ]; libs = [ "gd" "libpng" "zlib-ng" ]; };
               nss_db.libs = [ "libselinux" ]; };     # active from S3 (S1: FHS shebangs allowlisted)
  lateReferrers = { common = [ "minimal_langpack" "langpack_*" ];   # LC_CTYPE etc. -> C.utf8
                    nss_db = [ "nss_devel" ]; utils = [ ]; };
  fhsAllowlist = lib.optionalAttrs (stage.name == "s1") { "#!/usr/bin/bash" = "late-bound in S3"; "#!/usr/bin/sh" = "mtrace"; };
  doCheck = false;
}
```

Update (revision 2): the committed draft is `packages/glibc/default.nix`
[HO-glibc]. Differences from the sketch above, with evidence:

* `user-defined-trusted-dirs` stays in `env`, but must reach rpmbuild as
  `env 'k=v' rpmbuild` ([E5], §4.4); fallback `prepScript` writing
  `configparms` is documented in the file;
* no `specSubstitutions` ([E2]: the alias resolves `--with-headers`);
* `opaqueRefs` from [E4]: `common/bin/locale`, `common/bin/localedef`,
  `static/lib64/libc.a`, the sysroot's `ld-linux-x86-64.so.2` and `libc.a`
  (draft format `"<output>/<rel>"`, see §2.8);
* `lateReferrers = import ./late-referrers.nix` (generated, [E4]);
* `lateBind.benchtests.interpreters = [ "bash" "python3" ]` and an S1
  `fhsAllowlist` entry for `#!/usr/bin/python3`.

The replay check needed further entries
(`tools/rocky-partition/tests/glibc-overrides.nix`, each explained there)
[HO-partition], [E3]: `danglingOk` `libx32` (ldd's RTLDLIST names the never
built x32 loader), `lib/gconv` (32-bit libc names its gconv dir, Rocky ships
no 32-bit modules), `lib/libmemusage.so` ([R13]); `prefixRelativeOk` +
`opaqueRefs` for `benchtests` (glibc's test support links in a table of bare
`$out`, `$out/bin`, …) and `sysroot_x86_64_el10_glibc` (the cross sysroot's
ld.so is not run from there); `systemLibDirs = [ "@out@/lib64" "@out@/lib" ]`.
These are requested of WP7 and need the `prefixRelativeOk` override field
(§8.1).

---------------------------------------------------------------------------

## 12. glibc milestone plan (Q9)

**M1** = `rockyBoot.s1.glibc`: relocated, 223 subpackage outputs (224 subpackages, glibc32
merged into out, + debug, logs), working from the store, verified (relative file
lists 221/221 shipped, ABI identical, behaviour report equal), closure = own
outputs + `libgccForGlibc` (stage0-derived, named S1 exception).
**M2** = `rocky.glibc` (S3a) after S1 gcc¹ and the S2 tool set; closure only S3.

Work packages (parallelisable; `deps` = must finish first):

| WP | title | deps | content / done when |
|---|---|---|---|
| WP0a | E1 DWARF prefix map | — | §9 E1 result + hook script |
| WP0b | E2 build view | — | §9 E2 result; `prefixView` default decided |
| WP0c | E3 RUNPATH/stub rules | — | §9 E3 counts; rule tweaks fed to WP5 |
| WP0d | E4/E5 glibc pieced refs + trusted dirs | — | `opaqueRefs` list; trusted-dir mechanism |
| WP1 | lock: subpackages/builddeps/order | — | `update-lock.py` emits the 3 JSON files; `checks.order` stub |
| WP2 | rpm config + macro file + nix scripts | — | `rpmConfig` derivation; test: `rpm --eval` of every §1.2 macro in the shim; `fold-usr`/`check-files` unit tests |
| WP3 | tool shim + view | WP0b | `tool-shim.sh`, `mkview.py`; test drv: `/usr/bin/rpmbuild --version`, `/bin/true`, only declared inputs visible, `$out` alias |
| WP4 | S1 cc-wrapper | WP0a | `lib/rocky/cc/wrap.nix` over stage0 gcc copy; `tests/toolchain.sh` rewritten for store paths (C, C++, -m32, -static, -flto, PT_INTERP, RUNPATH, no input paths in DWARF) |
| WP5 | rocky-partition | — (rules from WP0c/d) | phases A–I; self-tests on synthetic trees; replay on [NF-S3] tree reproduces the [NF-S5] 223-output split with no errors |
| WP6 | mkRpmPackage + names + overrides + stage | WP1, WP2, WP3, WP5 (interfaces) | builds `which`, `xz` in S1; outputs, outputChecks, report |
| WP7 | glibc override + libgcc-for-glibc | WP4, WP6, WP0d | `rockyBoot.s1.glibc` builds; no cycles; closure rule passes |
| WP8 | kernel-headers relocated | WP6 | `rockyBoot.s1.kernel-headers` (`$dev/include`), from the existing headers-only kernel build recipe |
| WP9 | relocated parity + runtime checks | WP7 (code can start on [NF-S5] outputs) | `checks.nn-glibc-{files,abi,content,closure,runtime}` green |
| WP10 | attrs, hydraJobs, docs | WP7 | `rockyBoot.s1.*`, `rockyBoot.s1.rpm.*`, `docs/nix-native.md` |
| WP11 | late-bind derivation | WP5, WP6 | `lateBind.wrap`; test with glibc `common` + langpacks bound to a dummy bash |
| WP16 | build-purity assertion | E6 | `purity.nix`; negative test (nixpkgs drv in context → eval error) |

Ordering: WP0a–d, WP1, WP2, WP5, WP16 start at once; WP3 after WP0b; WP4
after WP0a; WP6 after WP1/2/3/5; WP7/WP8 after WP6 (+WP4); WP9 code in
parallel, green after WP7; WP10/WP11 last for M1. Then M2: S1 rest (gmp…gcc¹),
S2 set, S3a.

**Status after the foundation merge (c700802), from [HO-*]:**

| WP | status | where |
|---|---|---|
| WP0a (E1) | done, PASS | `nn.cc.e1.*`, [E1] |
| WP0b (E2) | done, `prefixView = true` | `nn.toolShim.e2.*`, [E2] |
| WP0c (E3) | done, R1–R16 | `nn.partitionTool.trees.e3.*`, [E3] |
| WP0d (E4/E5) | done | [E4], [E5], `packages/glibc/` |
| WP1 | done (`checks.nn-order`) | `lock/rocky-10.2/*.json`, `nn.lockgen`, [LK] |
| WP2 | done (`checks.nn-rpm-config`); config.site status bug open ([D-1]) | `nn.rpmConfig`, [RC] |
| WP3 | done (`checks.nn-shim`) | `nn.toolShim` |
| WP4 | done (`checks.nn-cc-toolchain`) | `nn.cc` |
| WP5 | done (`checks.nn-partition-selftest`, `nn-partition-replay`) | `nn.partitionTool`, PLAN.md |
| WP6a (names, overrides schema, unions) | done (`checks.nn-names`) | `nn.names`, `nn.overrides`, `nn.unions` |
| WP16 (E6) | done (`checks.nn-purity`) | `nn.purity`, [E6] |
| WP6 (mkRpmPackage, mkStage), WP7, WP8, WP9, WP10, WP11 | not started at c700802 | — |

The cross-package requests addressed to WP6/WP7/WP9/WP11 are collected in
`docs/research/nix-native/foundation-handoff.md`; the design-level ones are
folded into the sections above.

**Status at M1 (branch `nn/m1`; records `experiments/wp6.md`, `wp7.md`,
`wp8.md`, `m1.md`):**

| WP | status | where |
|---|---|---|
| WP6 | done (`checks.nn-s1-smoke`): which, xz, zlib-ng, gzip in S1 | `nn.mkRpmPackage`, `nn.mkStage`, `bootstrap/nn/s1.nix` |
| WP7 | done: `rockyBoot.s1.glibc` (225 outputs, closure = siblings + `libgccForGlibc`), `checks.nn-glibc-smoke` | `packages/glibc/default.nix` |
| WP8 | done (`checks.nn-kernel-headers`): kernel SRPM headers-only as a mkStage variant; headers at **`$out/include`** (the names rule makes the prefix subpackage `out`; supersedes `$dev/include` in the table above) | `packages/kernel-headers/` |
| WP9 | done: `checks.nn-glibc-{files,abi,content,closure,runtime}` pass on the real M1 build | `tools/nn-parity.py`, `tools/parity/nn-glibc-*.json`, `packages/glibc-nn-runtime` |
| WP10 | done: `rockyBoot.s1.<srpm>`, `rockyBoot.s1.rpm.<rpm-name>`, `hydraJobs.nixNative`, `docs/nix-native.md` | `lib/rocky/parts/rockyBoot.nix`, `flake.nix` |
| WP11 | done (`checks.nn-late-bind`, `nn-late-bind-unit`); wired into mkRpmPackage (`mkStage { lateBindFor; lateBindPkgs; interpreterPkgs; }`), inactive in S1, tested on the real glibc (`checks.nn-glibc-late-bind`) | `nn.lateBind` |

Not done for M2: the rest of S1 (macro packages, gmp … gcc¹), S2, S3a;
profiles (`mkProfile`); `keepBuildTree`; `tools/layout-suggest.py`,
`tools/spec-hazards.py`.

---------------------------------------------------------------------------

## 13. Risks

| risk | mitigation |
|---|---|
| many SRPMs still need `layout`/merges (binary refs into non-prefix outputs that are cyclic or not Required) | E3 measures; `layout-suggest` from filelists; merges are cheap and static |
| self-prefix alias changes build results (configure finds deps under `$prefix`) | E2 gate; dangling-reference detection; per-package `prefixView = false` |
| pieced references in non-prefix outputs hide edges or rels | §2.8 registration + acks + behaviour tests |
| patchelf relayout for RUNPATH growth | semantic ELF parity; `noPatchelf` for loader/libc; prefer `layout _libdir` for hot cases |
| nixpkgs wrapper defaults drag nixpkgs derivations into S3 | eval-time `assertBuildPure` (E6) |
| interpreter/library late binding misses referrers | `lateReferrers` verified at build time; ELF-content refs into late outputs are errors |
| scriptlets/file triggers don't run | profiles' trigger emulation; metadata for NixOS modules |
| setuid/owners/caps not representable | recorded in metadata (as today's layers) |
| 224 outputs in one derivation | fine ([NF-S0]: 230 outputs build); langpacks could be a separate rpmbuild-free split later |
| bootstrap cost (~80 SRPMs × 3) | caching; CA derivations later to cut rebuilds after nixpkgs bumps |
| rust/gdb in the reference closure of the stdenv set | `rpm --without sequoia`, `binutils --without debuginfod`, gdb-minimal as build tool |
| (rev. 2) a library reached only through the view works in the build and fails outside it, with no `$out` string [E2] | library rule in mkRpmPackage; NEEDED guard (`unresolved-needed`) |
| (rev. 2) specs that edit macro-expanded paths with the package name or `$RPM_BUILD_ROOT/usr` (krb5, gnutls) [E2], [E3] | spec-hazards lint; per-package `specSubstitutions`/`prepScript` |
| (rev. 2) RUNPATH recompute vs FIPS self-checks (openssl, libgcrypt, gnutls not built yet) [E3] | R14: recompute fipscheck `.hmac`, refuse embedded HMACs; `noPatchelf` + link-time RUNPATH or `integrityOk` |
| (rev. 2) the `/usr`-files prefix rule picks odd subpackages among several libraries [LK] | refined rule; `prefixSubpackage` override when packaged |
| (rev. 2) DWARF names view headers by `$out` path; DWARF is no proof of build purity once inputs are mapped [E1], [E2] | `-ffile-prefix-map=$out=/usr` during rpmbuild (rebuild check not run yet); purity via view + §7.3 |
| (rev. 2) cmake config files (`${_IMPORT_PREFIX}`) and other meson/cmake specifics not measured [E3] | measure on the first cmake SRPM |

---------------------------------------------------------------------------

## 14. Changelog

**M1 review fixes (branch `nn/m1`, `experiments/m1.md` "Review fixes";
they supersede the integration notes below where they differ):**

* §5.1: `--disable-new-dtags` is every mkRpmPackage build's default
  (`env.NIX_LDFLAGS_BEFORE`), not glibc's: the wrapper's new dtags changed
  `DT_BIND_NOW` and `$ORIGIN` DT_RPATH in every package (xz's liblzma too).
  The wrapper keeps `--enable-new-dtags` for ordinary consumers; phase E
  writes store dirs as DT_RUNPATH (also an unchanged DT_RPATH holding an
  input dir), Rocky's own `$ORIGIN`/package-dir RPATHs keep their tag.
* §2.6: `patchelf --remove-rpath` leaves the old string in `.dynstr`
  (the cc wrapper's gcc copy and libc dev output stayed references of every
  package after glibc¹); phase E overwrites it, and a dropped RUNPATH hash
  left anywhere in the file is a `foreign-store-path` error.
* §4.1: the generated setup hooks implement the `unions.nix` contract
  (`provider`, `yieldsTo`, run-time-only variables) for the generic table
  and for override `runtimeSearchPaths` alike (`searchPathRules` in the
  plan): `all_langpacks` exports `LOCALE_ARCHIVE` and unsets `LOCPATH`.
  `GCONV_PATH` is run time only: at build time it reached the foreign
  glibcs of the build, which loaded Rocky's 2.39 modules.
* §4.1/§4.2: the "locale aliases / composed by profiles" note below was
  wrong (libc reads its compiled-in `$out/...`, which no profile changes).
  New plan key `pullToPrefix`: glibc-common's `share/locale/locale.alias`
  and `lib/locale/C.utf8` move into `out` (common keeps symlinks; the other
  direction would close a cycle), so alias names resolve with directory
  locales and `C.UTF-8` needs no `LOCPATH`, also in archive mode.
* §5.6: -devel propagation is evaluation-time (`mkStage` `develClosure`,
  lock `develrequires.json` generated from `deps.json.gz`): a stage-built
  BuildRequire's cross-SRPM -devel/-headers/-static Requires are inputs too.
  The dev outputs' `propagated-build-inputs` stay sibling-only (a file
  reference would add e.g. kernel-headers to glibc.dev's closure).
* §11.1/§11.3: the bind derivation's outputs get `allowedReferences` /
  `allowedRequisites` (raw's, L* by name, + the binds' outputs /
  `rockyRequisites`), not only `disallowedRequisites`; `hydraJobs.nixNative`
  adds `<srpm>-bound` (a bound package's own drvPath is the raw build).
* §6 (S1): consumer-specific BuildRequire drops are the consumer's
  `inputs.drop` (glibc, which), never stage fallback entries.

**M1 integration notes (branch `nn/m1`, `experiments/m1.md`), measured on
the real `rockyBoot.s1.glibc`:**

* §5.1 (superseded: now every package's default, see the review fixes):
  the S1 ld wrapper's `--enable-new-dtags` changes Rocky's dynamic
  sections where no store rpath is wanted (`DT_BIND_NOW` → `DT_FLAGS`,
  gconv modules' `$ORIGIN` DT_RPATH → DT_RUNPATH); glibc's override restores
  the ld default with `NIX_LDFLAGS_BEFORE = --disable-new-dtags` (before the
  link's own arguments, so glibc's explicit new dtags for librt still win).
* §4.3: P2 inside libc calls `__libc_secure_getenv` (nixpkgs' public call
  added an interposable PLT slot to libc.so.6); the only deviation from
  nixpkgs' patch text.
* §4.1/§4.2 (superseded by the review fixes above: `pullToPrefix`):
  libc's locale aliases (`$out/share/locale/locale.alias`, compiled in) are
  in glibc-common; one archive name (`no_NO.ISO-8859-1`) depends on them:
  named parity difference `locale-alias`, composed by profiles like the
  libc catalogs (§0.4 #6).
* §11.1: late binding is applied only where the stage binds
  (`lateBindFor`); per-output `rockyRequisites` avoid an evaluation cycle
  between a bound package and the packages it binds to.
* §12: WP8's headers are at `$out/include`; §5.5: macro packages bring
  whole trees (redhat/ scripts, fileattrs), not only `macros.d` (WP8).

**Revision 2 (2026-10-18), after the foundation work packages (merge
c700802; hand-off `docs/research/nix-native/foundation-handoff.md`).**
Corrections (the earlier text was wrong):

* §1.1, §1.2: relocation macros are appended to the instantiated config's
  `redhat/macros`, not installed in `macros.d/` (platform file and
  redhat/macros are read later and win) [E2] #4, [RC-1]; `rpmbuild --load`
  is dropped with `--target` [E2].
* §1.2: `%distcore @DIST@` per SRPM instead of `%dist .el10_2` [RC-4], [LK];
  prep-hooks run before `%{___build_post}` [RC-2]; `set_build_flags` kept in
  `%__spec_install_pre` [RC-3]; `%_rpmconfigdir` not redefined [RC-5];
  `%_dbpath` pinned [RC-6]; `%_annotated_build 0` dropped [RC-7]; the 21
  systemd directory macros are literal `/usr` in Rocky and are overridden
  conditionally [RC-8]; `%__smp_use_ncpus` replaces `%_smp_build_ncpus`
  [RC-11].
* §1.1, §5.5, §11.1: rpmbuild runs with `SOURCE_DATE_EPOCH` unset [RC-12].
* §1.3: `config.site` must end with status 0 (`true`) [E2] #3, [E3]; the
  committed file still does not [D-1].
* §1.2, §5.5: `QA_RPATHS=0x0002` is needed (check-rpaths rejects store
  RUNPATHs) [E2] #5, [E3].
* §0.2 #2, §1.5, §5.4: the `/usr` view and the `$out` alias are read-only
  overlayfs directories, not a symlink farm; one view per shim call [E2].
* §1.5: "anything compiled in that pointed into the view is caught as
  dangling" was too strong: DWARF needs file granularity, libraries reached
  through the view need the library rule and the NEEDED guard [E2].
* §0.2 #13, §5.1: the prefix map covers every input (`NIX_ROCKY_MAP_ROOTS`),
  named store roots incl. the own outputs, symlink-farm targets, named store
  files, and `$out` while the view is mounted [E1], [E2] #2.
* §0.3, §2.8, §9 [F-2]: pieced references are detected by hash bytes
  (≥ 6 hash bytes per window), not by path windows; [F-2]'s counts were mostly
  false positives; glibc has 7 truncated copies with whole hashes and no
  split hash in loaded sections [E4], [R1].
* §2.1, §11.1: the partitioner is invoked as `python3 -I
  ${partitionTool}/rocky-partition --plan "$NIX_ATTRS_JSON_FILE"`
  [HO-partition].
* §2.5.1: R2 rewrites `-devel` lib/include text to the `-devel` output
  itself (refines decision #7 for lib dirs); R4 standard top-level dirs are
  prefix-relative; R5/R13 ld.so tokens; R8 documentation never errors; R9
  `#!/bin/sh`, `#!/usr/bin/env` runtime FHS; R10 `prefixRelativeOk`; R12
  meson/cmake `.pc` variables [E3].
* §4.1, §4.2: `LOCPATH` yields to `LOCALE_ARCHIVE` (glibc ignores the archive
  when `LOCPATH` is set); `LOCPATH` only for directory-format locales
  [NM-fix].
* §4.4, §8.1, §11.1: non-identifier env keys (`user-defined-trusted-dirs`)
  are passed as `env 'k=v' rpmbuild`, never in the structured derivation
  `env` (setup.sh `declare -x` aborts) [E5].
* §5.1: from S2 on, the wrappers need runtimeShell, coreutils, gnugrep and
  expand-response-params passed explicitly [E6]; §7.3: allowed sources add
  `pkgs/build-support/wrapper-common` and `pkgs/by-name/ex/expand-response-params`
  [E6].
* §5.3, §2.12: nixpkgs has no `dontMoveDocs`; the `multiple-outputs.sh` hooks
  are switched off explicitly [NM-fix].

Updates (measured results and refinements; the earlier text still holds):

* §0.2 notes, §9 results table: E1–E6 verdicts.
* §2.2: layout header paths [R11], debug build-id links followed [R6],
  debug names mirror the prefix [R16]; §2.6: E3 RUNPATH numbers, `-L` script
  dirs dropped, own-`lib64` self-rpath, FIPS integrity data [R14]; §2.7:
  directory stubs serve files below [R15], 0 stubs created in E3; §2.9:
  debug outside L* [R7], glibc's reference graph and `lateReferrers` [E4];
  §2.10: report scrubbing, hook contract with `provider`/`yieldsTo`.
* §2.12: reserved / non-identifier output names fall back to the full
  sanitized name; `out` first; `rpmOutputs` vs `shippedRpmOutputs`;
  `duplicateNames` [NM], [LK], [E6].
* §3.1: the implemented prefix rule (stem tier, test/doc/devel exclusion,
  counts) [LK] and the ncurses-base data-subpackage case [E3]; §3.2:
  subpackages.json as built [LK]; §3.3: krb5 merge [E3], replay without
  cycles [HO-partition].
* §4.2–§4.6: E5 loader diagnostics, nixpkgs patch provenance and fuzz 0,
  P1 conf path, P2 host fallbacks (open decision, §0.4), `libgccForGlibc` as
  built, `benchtests` late binding, open S3 lateBind exemption [HO-glibc].
* §5.1, §5.4, §5.5 (§5.2 unchanged): wrapper and shim interfaces as built
  [HO-cc], [HO-shim]; rpmrc warning outside the shim; rpm config store-path
  guard [RC-13]; find-debuginfo through the fold link not yet exercised.
* §6: S1 libdl/libpthread hazard with nixpkgs libraries [E2] #7; order.json
  not pinned [LK].
* §7.1: `disallowedRequisites` of mkDerivation carry no context [E6]; §7.3:
  purity interface and costs [E6]; §7.6: no partitioned program run yet;
  §7.7: reproducibility results; §7.8: list of existing checks.
* §8.1: overrides schema as built; pending fields `prefixRelativeOk`,
  `integrityOk`, the `env` route assertion, the `opaqueRefs` format; §8.2:
  lock numbers and interfaces [LK].
* §10: files that exist after c700802 and files still to write; §11:
  corrections to the mkRpmPackage sketch, mkStage additions, the generated
  `lateReferrers`, replay as built; §11.5: the committed glibc draft and the
  replay's extra entries; §12: work-package status; §13: new risks.

**Revision 1 (2026-10-18):** the synthesized design (nixpkgs-faithful base,
grafts from spec-generic and bootstrap-purity).
