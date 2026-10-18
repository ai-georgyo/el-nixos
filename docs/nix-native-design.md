# el-nixos nix-native: Rocky specs → composable, relocated Nix store paths

**Final synthesized design** (base: *nixpkgs-faithful*, the winner of 2 of 3 judges;
grafts from *spec-generic* and *bootstrap-purity*; every judge-reported fatal flaw
addressed in §0.3). Project `el-nixos`, branch `glibc-bootstrap`, Rocky 10.2.

Evidence labels: **[NF-Sx]** = nixpkgs-faithful spikes
(`docs/research/nix-native/spikes-nixpkgs-faithful/`), **[SG-…]** = spec-generic spikes
(`docs/research/nix-native/spikes-spec-generic/`), **[BP-n]** = bootstrap-purity spikes
(`docs/research/nix-native/spikes-bootstrap-purity/`), **[F-n]** = new measurements made for this
synthesis (`docs/research/nix-native/`). The repository was not modified.

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
                        a bwrap "tool shim": /usr = view of DECLARED inputs only, $out = the same view
                        (self-prefix alias), /usr/lib/rpm = assembled rpm config
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
| 2 | build-time view of deps | `/usr/bin` farm only, no `/usr/include`/`/usr/lib64` | full FHS chroot of stage outputs, P ≡ `/usr` | store-only root, no `/usr` | **shim `/usr` = symlink view of declared inputs only; same view bind-mounted at `$out` during rpmbuild** | keeps "deps only via declared inputs" (faithful/purity) and gains spec-generic's "build env through target macros works unmodified" (~4 % of specs, glibc's `--with-headers=%{_prefix}/include`); no rpmdb needed |
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
| 13 | DWARF store paths | `-ffile-prefix-map` (unspiked) | n/a | prefix map | **`-ffile-prefix-map=<input>=/usr` for every input + gcc prefix; reproducible-builds hook OFF** | [F-1]: S3 leaked `-frandom-seed=nncpaslng9` into DW_AT_producer; E1 validates the map |
| 14 | build order at scale | stages + bconds | stages | FAS `order.json`, second pass for library back edges | **bootstrap-purity's FAS + `checks.order`** | quantified (926 → 225 library-only SCC, 144 SRPMs need a second pass) |

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
| pieced (store-by-pieces) references hide edges from Nix's scanner | fragment scan in loaded sections; hidden references registered via `nix-support/hidden-references`; acks for non-prefix outputs | §2.8 |


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

### 1.2 `lib/rocky/rpm/macros.nix-reloc` (installed as `/usr/lib/rpm/macros.d/macros.zz-nix-reloc`)

`@PREFIX@`, `@BUILDTOP@`, `@NCPUS@` are substituted per build (`substituteAll`
at build time; `@PREFIX@` = `$out`).

```
# ---- install / compile prefix: the derivation's main output ----------------
%_prefix                 @PREFIX@
%_exec_prefix            %{_prefix}
%_usr                    %{_prefix}
%_prefix_rel             %(echo '%{_prefix}' | sed 's|^/||')
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
# systemd-rpm-macros already derive %_unitdir %_userunitdir %_presetdir
# %_udevrulesdir %_tmpfilesdir %_modprobedir from %{_prefix}/lib -> $out/lib/systemd/...
# (= nixpkgs layout; NixOS systemd.packages / services.udev.packages consume it)

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

# ---- engine/tool macros that must NOT follow the prefix ---------------------
%_rpmconfigdir           /usr/lib/rpm
%__perl                  /usr/bin/perl
%__plugindir             /usr/lib64/rpm-plugins
%_buildshell             /bin/sh

# ---- build plumbing ----------------------------------------------------------
%_topdir                 @BUILDTOP@/rpmbuild
%_tmppath                @BUILDTOP@/tmp
%_smp_build_ncpus        @NCPUS@
%_binary_payload         w0.ufdio
%_source_payload         w0.ufdio
%dist                    .el10_2
%_buildhost              el-nixos.localdomain
%source_date_epoch_from_changelog   1
%use_source_date_epoch_as_buildtime 1
%clamp_mtime_to_source_date_epoch   1
%__brp_compress          /usr/lib/rpm/brp-compress %{_prefix}
%__check_files           /usr/lib/rpm/nix/check-files %{buildroot} %{_prefix}
%__spec_prep_post        %{___build_post}\
  /usr/lib/rpm/nix/prep-hooks "%{_builddir}/%{?buildsubdir}"\
  %{nil}
%__spec_install_pre      %{___build_pre}\
  [ "$RPM_BUILD_ROOT" != "/" ] && rm -rf "${RPM_BUILD_ROOT}"\
  mkdir -p "$(dirname "$RPM_BUILD_ROOT")" && mkdir "$RPM_BUILD_ROOT"\
  /usr/lib/rpm/nix/fold-usr "$RPM_BUILD_ROOT" "%{_prefix}"\
  %{nil}
%__spec_install_post     /usr/lib/rpm/nix/fold-usr "$RPM_BUILD_ROOT" "%{_prefix}"\
  %{?__debug_package:%{__debug_install_post}}\
  %{__arch_install_post}\
  %{__os_install_post}\
  %{nil}
# annobin: off until the stage has a Rocky annobin for its gcc (as stage0 today)
%_annotated_build        0
%_annobin_gcc_plugin     %{nil}
```

Per-package `defines` are appended as `--define` (single-line values only).

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
* **`prep-hooks DIR`**: applies `$NIX_PREP_PATCHES` (`patch -p1`) and runs
  `$NIX_PREP_SCRIPT` in the unpacked source — Nix-side patches without editing
  the spec's patch list.

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
```

Per-package fragments are appended (`CONFIG_SITE` is a list). glibc's
(`packages/glibc/glibc.site`, [NF-S3] + [SG] `rootsbindir`):

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
glibc's ld.so.cache/preload (P1/P3), default `TZDIR` (= `$glibc/share/zoneinfo`,
dangling, acked; `TZDIR` env from profiles/NixOS).

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
   * `/usr` = a symlink view of the derivation's *declared* inputs (PATH tools
     → `bin`, `sbin`; every input output's `include lib lib64 libexec share`;
     first wins, collisions reported), `/bin`, `/sbin` → `/usr/bin`,
   * `/usr/lib/rpm` = the assembled rpm config,
   * **self-prefix alias**: the same view bind-mounted at `$out` while rpmbuild
     runs (`mkdir $out` in the sandbox, then `bwrap --ro-bind $view $out`), so
     `%{_includedir}/foo` used as "where my build deps live" resolves into inputs
     (spec-generic's P ≡ `/usr` trick, adapted to a real output path). The
     namespace ends with rpmbuild; `$out` is empty again when the partitioner
     fills it.
   Nothing outside declared inputs is visible (no stage0 root, no nixpkgs `-devel`).
   Anything compiled in that pointed into the view is caught by the partitioner
   as a *dangling* reference (§2.5 case 5) — never silently shipped.
   Decision gate: **E2** (§9) confirms on glibc and 6 small SRPMs; fallback is
   `prefixView = false` + `specSubstitutions` (the [NF-S3] way, already proven).
3. **FHS paths that leak into outputs** — detected:
   * shebangs: nixpkgs `patchShebangs --host` against `HOST_PATH` (runtime
     inputs); interpreters not yet Rocky-built → `lateBind` (§2.9) or
     `fhsAllowlist` (bootstrap only);
   * other FHS literals in ELF/text: reported in `nix-support/rocky-report.json`
     (`/usr/`, `/lib64/`, `/bin/` not on the runtime allowlist); `strictFhs = true`
     per package turns them into errors.
   * The static lint (`tools/spec-hazards.py`, from [SG spec-scan]) produces the
     per-package worklist; the build is the real detector.

---------------------------------------------------------------------------

## 2. Output splitting (Q2)

### 2.1 Inputs to the partitioner

`tools/rocky-partition/` (Python ≥3.11 package; run as `python -I -m rocky_partition`).

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
* **Compressed/nested references** (gzip'ed man pages, `.gnu_debugdata`): same
  file, `hidden-references`, as in bootstrap-purity's nested-references.

### 2.9 Phase H — graph, cycles, late binding plan

Edges = Nix's own test (output A contains B's hash part) over final contents +
`hidden-references`. Tarjan SCC (§3). For `lateBind` outputs, compute
`L* = L ∪ {Y | Y →* L}` over sibling outputs (e.g. `common` → all langpacks; `nss_db`
→ `nss_devel`), and require: no ELF *content* in `L*` references `L` (only
symlinks, text, RUNPATH) — else error. Written to `nix-support/rocky-late.json`.

### 2.10 Phase I — metadata and hooks

Every output gets `nix-support/rpm/<subpkg>.json` (file list with flags/modes/
owners/caps/digests, Requires/Provides, scriptlets, triggers), `nix-support/rpm-name`,
and, if it contributes to a search path, a generated `nix-support/setup-hook`
(e.g. `langpack_de`: `addToSearchPath LOCPATH $langpack_de/lib/locale`). The
whole decision log goes to `$out/nix-support/rocky-report.json` (edges with
evidence, stubs, rewrites, RUNPATH changes, FHS literals, pieced refs). The
build log goes to a `logs` output (as today).

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

### 3.2 Static subpackage list

`lock/rocky-10.2/subpackages.json` = per SRPM: `rpmspec -q --qf '%{NAME}\n'
--target x86_64 --define 'dist .el10_2'` with the stage0 rpm + Rocky macros
(+ the package's `bconds` override), the prefix choice, and `shipped` (∈ `rpms.json`
bySrpm). Unshipped ones (glibc's `glibc32`, `sysroot-x86_64-el10-glibc`,
`compat-libpthread-nonshared`; 8/20 SRPMs' `-static` [SG]) become outputs too
(they are cheap and keep `%files` processing honest). Debuginfo subpackages are
not listed (they all map to `debug`). An output built but not declared, or
declared but not built → build error.

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
  nss_hesiod, sysroot → dev/static.
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

### 4.2 glibc

| union | Rocky | nixpkgs glibc | **here** | evidence |
|---|---|---|---|---|
| rtld system dirs | `/lib64:/usr/lib64` + `/etc/ld.so.cache` | `$out/lib`, cache patched | `$glibc/lib64` (from `slibdir`), `libgcc-for-glibc/lib64` (trusted dir), RUNPATH for the rest; **P1** | [NF-S4] `system_dirs[0]=$G/lib64/` |
| `ldconfig`, `/etc/ld.so.conf` | maintains cache | reads `$out/etc` | Rocky's ldconfig; P1 makes cache `$glibc/etc/ld.so.cache` → inert on Nix | |
| NSS modules | system dirs | files/dns in libc dir; nscd/nsncd | files/dns/compat in `out` (= system dir); `nss_db`, `nss_hesiod`, `libnsl` via profile `LD_LIBRARY_PATH` or host nscd | |
| locales (dirs: langpacks, minimal; `C.utf8` in common) | `/usr/lib/locale` | archive + `LOCALE_ARCHIVE` | default `$glibc/lib/locale`; **`LOCPATH`** (upstream) from each langpack's setup hook/profile | [NF-S6] de_DE via LOCPATH ok; [SG] en_US ok |
| `locale-archive` (`all_langpacks`, 224 MB) | same dir | `LOCALE_ARCHIVE` | **P2** (`LOCALE_ARCHIVE_2_27`, `LOCALE_ARCHIVE`), `runtimeSearchPaths` (no stub: not uniquely Required) | [NF-S6] fails without P2 |
| message catalogs (`share/locale`) | `/usr/share/locale` | `$out/share/locale` | default `$glibc/share/locale`; libc's own domain untranslated unless composed (`TEXTDOMAINDIR` for programs) | accepted |
| `share/i18n` (locale-source) | compiled in | `$out/share/i18n` | default dangles; **`I18NPATH`** from `locale_source`'s hook | [NF-S5] |
| gconv (`lib64/gconv` in out + `gconv_extra`) | one dir + cache | one dir | default `$glibc/lib64/gconv`; **`GCONV_PATH`** from `gconv_extra`'s hook; profiles may run `iconvconfig` | [NF-S6] IBM1364 ok with GCONV_PATH |
| `gconv-modules.cache` (`%ghost`, `%post`) | scriptlet | — | not generated; parse fallback (measured equivalent in `checks.glibc-runtime`) | |
| `TZDIR` | `/usr/share/zoneinfo` | `$out/share/zoneinfo` | default `$glibc/share/zoneinfo` (dangling, `danglingOk`); profiles/NixOS set `TZDIR=$tzdata/share/zoneinfo`; `/etc/localtime` stays FHS (`TZDEFAULT` from sysconfdir) | |
| `libgcc_s.so.1` (dlopen for `pthread_cancel`, `backtrace`) | `/lib64` | `user-defined-trusted-dirs=${xgcc libgcc}/lib` | **`user-defined-trusted-dirs=$libgccForGlibc/lib64:$libgccForGlibc/lib`** (§4.5) | [NF-S4,S6] abort without |
| `/etc/ld.so.preload` | | `/etc/ld-nix.so.preload` | **P3** same | |

### 4.3 Nix-side glibc patches (`packages/glibc/nix-patches/`, via `prep-hooks`)

* **P1 `ld-so-cache.patch`** (required): `LD_SO_CACHE` = `"$prefix/etc/ld.so.cache"`.
  With `sysconfdir=/etc` the relocated ld.so would otherwise consult the host
  cache first and load the host's libc on a Debian host. (Alternative
  `sysconfdir=$out/etc` rejected: `TZDEFAULT` and the spec's `etc` cleanup.)
  [NF-S3/S4] verified as sed; the patch file is the nixpkgs one rebased.
* **P2 `locale-archive.patch`** (nixpkgs `nix-locale-archive.patch`): env
  `LOCALE_ARCHIVE_2_27`, `LOCALE_ARCHIVE`.
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

### 4.6 glibc outputs that need later packages

`utils` (memusagestat → libgd, libpng, libz) and `nss_db` (makedb → libselinux):
in S1 those libs are nixpkgs-built (`stage0.glibcBuildDeps`) → raw outputs keep
NEEDED unresolved (`allowUnresolvedNeeded`, S1 only); `lateBind.utils.libs = [
"gd" "libpng" "zlib-ng" ]`, `lateBind.nss_db.libs = [ "libselinux" ]` produce the
bound outputs once Rocky builds exist (S3). `common`/`utils` shebangs
(`#!/usr/bin/bash` in ldd/sotruss/tzselect/xtrace/memusage; mtrace perl [BP-9])
→ `lateBind.common.interpreters = [ "bash" ]`, `utils = [ "bash" "perl" ]`.

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
* self-rpath `lib64` instead of `lib` (preHook overriding `_addRpathPrefix`).
* gcc must be a copy/relocated build, not a symlink farm [NF-S2]; GNU ld
  scripts in the toolchain must name store paths (true by construction for
  relocated Rocky gcc/glibc via §2.5).
* From S2 on the wrapper derivations are instantiated with `stdenvNoCC =
  rocky.<stage>.stdenvNoCC`, `runtimeShell`/`coreutils`/`gnugrep` = Rocky's,
  `expand-response-params` compiled by the Rocky stdenv from nixpkgs' C source.
  nixpkgs contributes *source files* only (setup.sh, wrapper scripts, hooks);
  the eval-time assertion (§7.3) proves no nixpkgs derivation remains.

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
`patchShebangs --host` on. Setup hooks from nixpkgs: `multiple-outputs.sh`,
`patch-shebangs.sh`, `audit-tmpdir.sh`; Rocky: `lib64-paths.sh` (pkg-config/cmake
`lib64`), `rocky-rpm-macros.sh` (collects `lib/rpm/macros.d` of macro-package
inputs into `NIX_RPM_MACRO_DIRS`).

### 5.4 rpmbuild in that world: the tool shim (`lib/rocky/tool-shim.sh`)

bwrap, mechanism from `lib/chroot.sh` and [NF-S3] (sandbox root is read-only →
own root): new root tmpfs; bind `/nix`, `$NIX_BUILD_TOP`, sandbox `/etc`, `/proc`,
`/dev`, tmpfs `/tmp`; `/usr` = view (§1.5) built in `$NIX_BUILD_TOP/view` by
`lib/rocky/mkview.py` from `PATH` + `$rockyViewInputs`; `/bin`, `/sbin`, `/usr/sbin`
→ `/usr/bin`; `/usr/lib/rpm` = rpm config; `$out` ← view (if `prefixView`).
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
* `lib/rocky/rpm/config.nix` → `rpmConfig { rpm, macroPkgs, extraMacroDirs }`: copy of
  rpm's `lib/rpm` (or `usr/lib/rpm` for stage0) + `redhat-rpm-config` + every
  `*-srpm-macros`/`*-rpm-macros` input's `lib/rpm/macros.d` (relocated packages
  install them there via `%_rpmmacrodir`) + `rocky-release` `macros.dist` +
  `macros.zz-nix-reloc` + `nix/` scripts. Macro packages are ordinary
  `nativeBuildInputs`; the config is assembled per build from
  `NIX_RPM_MACRO_DIRS` (cheap copy), so adding a macro package rebuilds nothing else.
* brp scripts run as Rocky runs them (`%__os_install_post`): strip,
  strip-static-archive, compress (`%{_prefix}`), mangle-shebangs (→ FHS; Nix binds
  later), python-bytecompile, `check-rpaths` (store RUNPATH = non-standard =
  accepted; `QA_RPATHS` not needed), `check-buildroot`.
* debuginfo: Rocky's find-debuginfo + dwz + gdb-add-index (gdb as a build tool
  from S2; S1 uses nixpkgs gdb, build-time only); all debug subpackages → one
  `debug` output (`lib/debug/.build-id/xx/….debug`, `src/debug`); `debug` may
  reference `out` (DWARF), never the reverse (checked).
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

---------------------------------------------------------------------------

## 7. Enforcement and verification (Q7)

1. **Output closure (Nix-enforced, inductive)**: `__structuredAttrs = true;
   outputChecks.<o>.allowedRequisites = siblings(o) − {debug, logs} ∪ runtime-
   input outputs' closures (eval-time, from `passthru`) ∪ stage exceptions`;
   `disallowedRequisites` = every S0/S1/S2 derivation and every raw output that a
   bound output replaces (in S3). `debug` may reference siblings; nothing may
   reference `debug`/`logs`.
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
   normalisation.
7. **Reproducibility**: `nix build --rebuild` per SRPM (CI sample + glibc),
   SOURCE_DATE_EPOCH macros, no random seed, deterministic patchelf/partition,
   transient RPMs not outputs, ar dates as documented today.

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

### 8.2 BuildRequires → inputs (static)

`tools/update-lock.py` gains (all outside Nix eval, committed):

* `subpackages.json` (§3.2);
* `builddeps.json`: per SRPM the *direct* providers of each BuildRequire
  (resolver of `resolve-buildrequires.py`, 260/260 vs dnf5; file and rich deps;
  `install_weak_deps=0`), tagged tool/lib/macro from file lists;
* `order.json`: SRPM build graph (direct BR providers: 18 721 edges, largest SCC
  926 [BP-1]), edge classes (doc/test/lang/lib/tool), Eades feedback-arc set
  (771 back edges, 265 targets, 144 SRPMs with library back edges [BP-2]).

### 8.3 Build-order cycles

Back edges are satisfied from an earlier stage (S2 stdenv set) or from
`rockyBoot.s2b.<X>` (built with Fedora `%bcond bootstrap`/doc/test off).
Library back edges (144 SRPMs) would put an S2 output in an S3 closure →
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

Already measured for this synthesis:
* **[F-1]** sysroot `libm.so.6` DW_AT_producer contains `-frandom-seed=nncpaslng9`
  (nixpkgs reproducible-builds hook) → hook off.
* **[F-2]** `fragscan.py`/`fragsec.py` over the [NF-S3] relocated glibc: ld.so
  `.rodata` 7 full + 57 pieced windows (`\0\0\0…/nix/store/nncpaslng931r…`
  32-byte chunks, 15 with partial hashes), ldconfig 10 full + 57 pieced (fixed
  field padded with spaces), localedef 6 + 63, libc.so.6 16 full / 0 pieced.
  Confirms store-by-pieces in exactly the binaries spec-generic named; with
  no-rewrite they are correct bytes, so the only duties are edge registration and
  acks (§2.8).
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
    installPhase   = "python -I -m rocky_partition --plan $NIX_ATTRS_JSON_FILE";
    outputChecks   = stage.outputChecksFor outs deps;
    passthru = { rockyStage = stage.name; inherit srpm; inherit (outs) rpmOutputs; overrides = overrides; };
  };
in purity.check stage (stage.stdenv.mkDerivation attrs)   # no-op unless stage.buildPure
```

Result exposed as `stage.pkgs.<srpm>` = `lateBind.wrap raw` when `lateBind != {}`,
else the raw derivation.

### 11.2 `mkStage`

```nix
mkStage = { name, prev ? null, stdenv, ccFor ? (libc: …), tools, rpm, macroPkgs,
            buildPure ? false, exceptions ? [ ], packages }:   # packages: srpm list or "all"
  # returns a fixpoint:
  { inherit name stdenv buildPure; pkgs = { <srpm> = drv; };
    rpm = { <rpm-name> = output; };       # from rpmOutputs of every pkg
    resolveBuildDeps; outputChecksFor; allowedBuildDrvs; fetch; tools; }
```

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

### 11.4 Developer loop

`rocky.<srpm>.raw.overrideAttrs { keepBuildTree = true; }` adds a `buildtree`
output (BUILDROOT + RPMS, debug only); `tools/rocky-partition --replay <tree>
--remap <old-out>=<new-out>` re-runs the partition against a new set of output
paths using a same-length hash remap of the *development copy* (as [NF-S5] did)
— never used for shipped outputs.

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
