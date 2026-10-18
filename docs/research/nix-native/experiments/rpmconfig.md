# WP2 rpmconfig: rpm config derivation, relocation macros, nix helper scripts, config.site

Work package WP2 of `docs/nix-native-design.md` (§1.1–§1.4, §5.5, §12).
Rocky 10.2, stage0 rpm 4.19.1.1-23.el10, stage0's macro packages
(redhat-rpm-config, 13 `*-srpm-macros`, rocky-release).

## What exists now

| file | role |
|---|---|
| `lib/rocky/rpm/macros.nix-reloc` | relocation macro template (`@PREFIX@ @BUILDTOP@ @NCPUS@ @DIST@`); deviations from §1.2 listed at its top |
| `lib/rocky/rpm/nix-scripts/fold-usr` | `fold-usr BR P`: `BR/usr -> ${P#/}` (relative), merges a real `BR/usr` into `BR/P`, conflicts are errors, idempotent, `P=/usr` no-op |
| `lib/rocky/rpm/nix-scripts/check-files` | `check-files BR P`: rpm's check-files with `BR/usr/x` ≡ `BR/P/x` on both sides, the `usr` link excluded |
| `lib/rocky/rpm/nix-scripts/prep-hooks` | `prep-hooks DIR`: `$NIX_PREP_PATCHES` (`patch -p1 --forward`, failure = error), then `$NIX_PREP_SCRIPT` (a file, `bash -e`) |
| `lib/rocky/rpm/nix-scripts/instantiate` | per-build helper: writable copy of the config, `--macro-dir`/`$NIX_RPM_MACRO_DIRS` → `macros.d`, placeholders substituted, result appended to `redhat/macros` |
| `lib/rocky/rpm/config.nix` | `rpmConfig { rpm ? stage0.rpm, macroPkgs ? [ ], extraMacroDirs ? [ ], baseMacroPkgs ? stage0's set }` |
| `lib/rocky/parts/rpmConfig.nix` | `nn.rpmConfig` (default instance, also callable; `.configSite`) |
| `lib/rocky/config.site` | §1.3, host-aware `lib`/`lib64`, sets `$el_nixos_lib` for per-package fragments |
| `lib/rocky/checks/rpm-config.nix`, `lib/rocky/rpm/tests/` | `checks.nn-rpm-config` |

Per-build use (for WP6 mkRpmPackage / WP3 tool shim):

```sh
sh $rpmConfig/nix/instantiate $NIX_BUILD_TOP/rpmconfig \
  --prefix $out --buildtop $NIX_BUILD_TOP --ncpus $NIX_BUILD_CORES --dist .el10_2   # distOf srpm
# shim: --ro-bind $NIX_BUILD_TOP/rpmconfig /usr/lib/rpm
# rpmbuild with SOURCE_DATE_EPOCH unset (env -u), else stdenv's 1980 value wins
# CONFIG_SITE="${rpmConfig.configSite} <package fragment>"
```

## Macro decisions re-verified against the stage0 macro files

Method: `grep` of every §1.2 macro name over rpm's `macros`,
`platform/x86_64-linux/macros`, `redhat/macros`, all `macros.d/*`, plus a full
audit in `checks.nn-rpm-config`: every non-parametric macro of `rpm --showrc`
(658 with Rocky's systemd-rpm-macros added; 613 before) expanded with the
plain Rocky config and with the instantiated relocation config (one
`rpm --eval '%{lua: ...}'` each), 129 differ (`$out/macro-audit.tsv`). Every
changed value that now points into `/usr` is listed in
`$out/macro-audit-usr.tsv` (empty except tool/rpm paths). Every relocated
value that still starts with `/usr/` is listed in `$out/macro-usr-left.tsv`
(13: `%__plugindir` and the 9 `%__transaction_*` plugins, `%_rpmconfigdir`,
`%getconfdir`, `%_usrsrc`; all intended).

Findings that changed the design (all in the header of `macros.nix-reloc`):

1. **Load order (design bug).** rpm 4.19's macro path (measured,
   `rpm --showrc`): `macros : macros.d/macros.* : platform/%{_target}/macros :
   fileattrs/*.attr : redhat/macros : /etc/rpm/...`. The platform file defines
   `%_prefix /usr`, `%_exec_prefix`, `%_oldincludedir /usr/include`,
   `%__spec_install_pre`, `%__brp_compress`, `%__os_install_post`;
   redhat/macros defines `%__spec_install_pre`, `%__brp_compress` (without
   `%{_prefix}`), `%_binary_payload w19.zstdio`, `%_annobin_gcc_plugin`,
   `%source_date_epoch_from_changelog`. A `macros.d/macros.zz-nix-reloc`
   loses to all of them. Negative control in the check, same file in macros.d:
   `%_prefix` = `/usr`, `%__brp_compress` = `/usr/lib/rpm/brp-compress`,
   `%_binary_payload` = `w19.zstdio`. Fix: `instantiate` appends the
   substituted file to the config's `redhat/macros` (last macro file inside
   the config dir; RPM_VENDOR=redhat for stage0 and Rocky's rpm.spec).
   (`%{load:...}` from a macro file was not tried: appending needs no
   assumption about how rpm treats non-definition lines in macro files.)
2. **`%__spec_prep_post` order (design bug).** `%{___build_post}` ends in
   `exit ${RPM_EC}`; the design put prep-hooks after it, so they never ran.
   Now before it (the script runs with `sh -e`, so `RPM_EC` is still the
   status of %prep). Verified by nntest.spec: `%build` fails unless the patch
   was applied and the script ran.
3. **`%__spec_install_pre` lost `%{?_auto_set_build_flags:%{set_build_flags}}`**
   (redhat/macros has it, `_auto_set_build_flags 1`): kept; check asserts
   `CFLAGS="${CFLAGS:-` in the expansion.
4. **`%dist .el10_2` is wrong for most SRPMs**: lock/rocky-10.2/srpms.json
   releases are `.el10` 1906, `.el10_2` 274, `.el10_0` 20, `.el10_1` 17.
   `lib/srpm.nix distOf` already computes the per-SRPM tag. Now
   `%distcore @DIST@` (macros.dist builds `%dist` from `%distcore`, keeping
   `%distprefix`/`%distsuffix`/`~bootstrap`); empty `--dist` keeps `.el10`.
   Checked: `.el10_2`, `.el10` (no --dist), `.el10_2~bootstrap` with
   `with_bootstrap`.
5. **`%_rpmconfigdir` not redefined**: it is `%{getconfdir}`, `/usr/lib/rpm`
   in the shim (asserted) and `$RPM_CONFIGDIR` outside it (asserted), never
   prefix-derived. A literal would break `rpm -qp` with a store config.
6. **`%_dbpath` added**: rpm's `%{_usr}/lib/sysimage/rpm` follows `%_usr`.
7. **`%_annotated_build 0` dropped**: redhat-rpm-config tests
   `%{?_annotated_build:...}` (definedness), so `0` is a no-op; emptying
   `%_annobin_gcc_plugin` is what stage0's `macros.stage0` does. Audit: the
   only flag change vs the Rocky config is the removed
   `-specs=/usr/lib/rpm/redhat/redhat-annobin-cc1` (as in M1), plus
   `-I$P/lib64/gfortran/modules` in FFLAGS (`%_fmoddir` follows `%_libdir`).
8. **systemd-rpm-macros does not derive its directories from `%_prefix`
   (design bug; the first version of this WP got it wrong too).** It is not
   in stage0 (nor rust-srpm-macros). The first version tested a hand-written
   stand-in with `%{_prefix}/lib/systemd/...`, i.e. the design's assumption.
   Rocky's real `macros.systemd` (systemd-rpm-macros-257-23.el10_2.2.rocky.0.1,
   the locked RPM, sha256 `4a63bbcb…5e8`) has 21 literal directory macros
   (`%_systemd_util_dir /usr/lib/systemd`, `%_unitdir /usr/lib/systemd/system`,
   … `%_user_tmpfilesdir /usr/share/user-tmpfiles.d`; systemd's meson
   substitutes them). With it, the first version gave `%_unitdir` =
   `/usr/lib/systemd/system` (reproduced by the reviewer). Fix: macros.nix-reloc
   overrides all 21 (`%{_prefix}/lib/systemd/...`, `%{_prefix}/lib/udev/...`,
   `%{_datadir}/user-tmpfiles.d`) in a `# @@if macros.d/macros.systemd` block
   that `instantiate` keeps only when that file is in the instantiated config:
   without systemd-rpm-macros Rocky leaves `%_unitdir` undefined, and specs
   test `%{?_unitdir}`. The scriptlet macros (`%systemd_post` →
   `/usr/lib/systemd/systemd-update-helper`) are run-time paths on the
   installed system and stay. The check now unpacks the locked RPM
   (`fetch.fetchRpm "systemd-rpm-macros.noarch"`, test data only), asserts the
   Rocky values are literal `/usr`, all 21 relocated values, and `undefined`
   for a config without it.
9. `%__perl` pin confirmed needed: perl-srpm-macros has `%__perl %{_bindir}/perl`.
   `%__python3` is literal `/usr/bin/python%{python3_pkgversion}` (no pin needed).
   `%_fontbasedir`, `%_fontconfig_templatedir`, `%gopath` are literal
   `/usr/share/...` in fonts-/go-srpm-macros: the design's overrides are needed.
10. The audit shows the dependency generators' path regexes follow the prefix
    (`%__pkgconfig_path`, `%__desktop_path`, `%__metainfo_path`,
    `%__sysusers_path`, `%__rpm_macro_path`, `%__rpm_lua_path`,
    `%__docdir_path`), so auto Provides/Requires match relocated file names.
    Literal ones left: `%__debuginfo_path ^/usr/lib/debug/` (find-debuginfo
    writes `/usr/lib/debug` names, still matches) and `%__kmod_path ^/lib/modules`
    (kernel; not relevant before the kernel is relocated). Generators of later
    macro packages (perl-, python-generators) are not in stage0: unverified.
11. **`%_smp_build_ncpus @NCPUS@` (design) bypassed `%_smp_ncpus_max`** and left
    `%_smp_build_nthreads` at the host's CPU count (reviewer: `--ncpus 3` with
    `_smp_ncpus_max 2` gave `3 2`, nthreads 16). Now macros.nix-reloc redefines
    rpm's `%__smp_use_ncpus` verbatim except `%{getncpus %{?1}}` → `@NCPUS@`.
    Asserted: ncpus/nthreads `3 3`; with `_smp_ncpus_max 2` → `2 2`;
    `%{constrain_build -c 1}` → 1; exported `RPM_BUILD_NCPUS=5` → `5 5`.
    `instantiate --ncpus 0` now counts as 1 (as M1's buildSrpm; make rejects
    `-j0`), asserted.
12. **`%source_date_epoch_from_changelog` has no effect under Nix**: rpm sets
    `SOURCE_DATE_EPOCH` from the changelog only when it is unset, and the Nix
    stdenv exports `315532800`. A macro file cannot unset the variable, so the
    caller (WP6) must run rpmbuild with `env -u SOURCE_DATE_EPOCH` (M1's chroot
    has a clean environment). Asserted both ways: nntest built with it unset
    has BUILDTIME `1792281600` (its changelog date, 2026-10-18 00:00 UTC) and
    no FILEMTIMES after it; nntest-rmrf built with the stdenv value has
    BUILDTIME `315532800`.
13. **rpmConfig's `/nix/store` guard rejected a relocated rpm** (its
    `platform/*/macros` has `%_prefix <its $out>`, as rpm's installplatform
    writes it). The guard now allows the store paths of the rpm and of the
    macro packages themselves and rejects any other. Asserted in the check:
    `rpmConfig { rpm = <stage0 rpm's lib/rpm copied to $out/lib/rpm, %_prefix
    $out>; }` builds, and once instantiated `%_prefix`/`%_libdir` are the
    build's prefix. By hand (not in the check, it is a failing build):
    `rpmConfig { extraMacroDirs = [ <dir with "%nn_foreign ${hello}/bin/hello"> ]; }`
    fails with `rpm config: macros.d/macros.nn-foreign names /nix/store/2y3s…`.

Note for the partitioner: rpm used outside the shim with
`RPM_CONFIGDIR=<config>` prints `cannot open /usr/lib/rpm/rpmrc at
<config>/redhat/rpmrc:1` (redhat/rpmrc has `include: /usr/lib/rpm/rpmrc`);
`rpm --eval`/`-qp` still work, but rpmrc data (per-arch optflags) is missing,
so headers should be read in the shim as §2.1 says.

## checks.nn-rpm-config

```
git add -A
nix build -L --cores 6 --max-jobs 2 --no-link --print-out-paths .#checks.x86_64-linux.nn-rpm-config
# first version (bbfada3): /nix/store/mv09rj2rf6nzpji21abla98m2iyrb7d6-nn-rpm-config, 126 ok
# after the review fixes:   /nix/store/hvfi0llq1jxib6cicqrx62yb9jnvyhjc-nn-rpm-config
#    results.txt: 160 ok, 0 FAIL
nix build --rebuild -L --cores 6 --max-jobs 2 --no-link .#checks.x86_64-linux.nn-rpm-config
# -> passes (bit-identical); the first version differed only in the random
#    rpm-tmp.XXXXXX names in the copied rpmbuild logs, now normalised
```

Shim used by the check: plain bwrap, `/usr/bin` = stage0 rpm + nixpkgs
bootstrap tools + stage0 glibc's static `ldconfig` (brp-ldconfig runs
`/sbin/ldconfig -N -r BUILDROOT`; nixpkgs' patched ldconfig fails there with
"Can't open cache file directory"), `/usr/lib/rpm` = instantiated config,
prefix `P=/nix/store/000…0-nn-rpm-config-test-1.0`.

Covered:

* instantiation: placeholders gone, relative prefix rejected, a differing
  macro file from `$NIX_RPM_MACRO_DIRS` rejected, a new one picked up,
  `--ncpus 0` → 1, a relocated rpm accepted and overridden;
* Rocky's systemd-rpm-macros (item 8), the `%_smp_*` cap (item 11);
* macro path order + the macros.d negative control;
* 75 macros with exact expected values (all of §1.2 incl. `_libdir`,
  `_sysconfdir=/etc`, `__perl`, `_rpmconfigdir`, `dist .el10_2`, `_dbpath`,
  the 21 systemd dirs from the real macros.systemd, an extraMacroDirs macro),
  `%__check_files`, the multi-line hooks (fold-usr first in
  `%__spec_install_post`, set_build_flags kept, prep-hooks before `exit`),
  `%optflags` (non-empty, `-O2`, hardened specs, `-march=x86-64-v3`, no annobin),
  `%build_ldflags`, `%configure` (`--libdir=$P/lib64 --sysconfdir=/etc
  --localstatedir=/var`), a relocated macro package (`lib/rpm/macros.d`);
* fold-usr: plain (link, prefix dir, `/usr/x` resolves, idempotent), rm -rf'd
  buildroot with a real `usr` (overlapping dirs, dotfile, symlink kept, `etc`
  untouched), conflict (error naming `/usr/bin/x`, prefix file untouched),
  foreign `usr` link rejected, `P=/usr` no-op;
* check-files: mixed `/usr` / prefix spellings and dirs → no output; a real
  unpackaged file and an unpackaged `/etc` file reported once each; rpm's own
  check-files reports 4 false entries on the same tree;
* prep-hooks: no-op, patch + script, a patch that does not apply fails;
* config.site: x86_64 → lib64, i686 → lib, no host → lib64, `/usr` prefix
  untouched, explicit values kept, `$el_nixos_lib` exported;
* `rpmbuild -bb --target x86_64` of `nntest.spec` and `nntest-rmrf.spec`:
  both build; nntest's file list is
  `/etc/nntest.conf $P/bin/nntest $P/lib64/nntest $P/lib64/nntest/data.txt
  $P/share/nntest/README /usr/share/nntest/file.txt` (the last one named
  literally in %files; check-files accepted it), `%config` flag `cn`,
  BUILDHOST `el-nixos.localdomain`, uncompressed payload; nntest-rmrf (`rm -rf
  %{buildroot}`, installs via real `BR/usr` and via the prefix) logs the merge
  and lists `$P/bin/nntest-rmrf $P/lib64/nntest-rmrf.txt $P/share/nntest-rmrf/{,from-prefix,from-usr}`;
  no "Installed (but unpackaged)" anywhere; BUILDTIME per item 12.

Not run / not covered: a real SRPM (glibc) through this config (needs WP3's
shim + WP6); `find-debuginfo` through the fold link (the test specs disable
debuginfo); the `$out` self-prefix alias (WP3).
