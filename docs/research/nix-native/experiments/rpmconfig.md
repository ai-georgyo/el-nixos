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
# CONFIG_SITE="${rpmConfig.configSite} <package fragment>"
```

## Macro decisions re-verified against the stage0 macro files

Method: `grep` of every §1.2 macro name over rpm's `macros`,
`platform/x86_64-linux/macros`, `redhat/macros`, all `macros.d/*`, plus a full
audit in `checks.nn-rpm-config`: every non-parametric macro of `rpm --showrc`
(613) expanded with the plain Rocky config and with the instantiated
relocation config (one `rpm --eval '%{lua: ...}'` each), 117 differ
(`$out/macro-audit.tsv`). Every changed value that now points into `/usr` is
listed in `$out/macro-audit-usr.tsv` (empty except tool/rpm paths).

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
8. **systemd-rpm-macros is not in stage0** (nor rust-srpm-macros). A stand-in
   macro file with systemd's definitions (`lib/rocky/rpm/tests/macros.d`)
   shows `%_unitdir` … `%_modprobedir` follow `%_prefix` as the design says.
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

Note for the partitioner: rpm used outside the shim with
`RPM_CONFIGDIR=<config>` prints `cannot open /usr/lib/rpm/rpmrc at
<config>/redhat/rpmrc:1` (redhat/rpmrc has `include: /usr/lib/rpm/rpmrc`);
`rpm --eval`/`-qp` still work, but rpmrc data (per-arch optflags) is missing,
so headers should be read in the shim as §2.1 says.

## checks.nn-rpm-config

```
git add -A
nix build -L --cores 6 --max-jobs 2 --no-link --print-out-paths .#checks.x86_64-linux.nn-rpm-config
# -> /nix/store/mv09rj2rf6nzpji21abla98m2iyrb7d6-nn-rpm-config
#    results.txt: 126 ok, 0 FAIL
```

Shim used by the check: plain bwrap, `/usr/bin` = stage0 rpm + nixpkgs
bootstrap tools + stage0 glibc's static `ldconfig` (brp-ldconfig runs
`/sbin/ldconfig -N -r BUILDROOT`; nixpkgs' patched ldconfig fails there with
"Can't open cache file directory"), `/usr/lib/rpm` = instantiated config,
prefix `P=/nix/store/000…0-nn-rpm-config-test-1.0`.

Covered:

* instantiation: placeholders gone, relative prefix rejected, a differing
  macro file from `$NIX_RPM_MACRO_DIRS` rejected, a new one picked up;
* macro path order + the macros.d negative control;
* 59 macros with exact expected values (all of §1.2 incl. `_libdir`,
  `_sysconfdir=/etc`, `__perl`, `_rpmconfigdir`, `dist .el10_2`, `_dbpath`,
  systemd dirs), `%__check_files`, the multi-line hooks (fold-usr first in
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
  no "Installed (but unpackaged)" anywhere.

Not run / not covered: a real SRPM (glibc) through this config (needs WP3's
shim + WP6); `find-debuginfo` through the fold link (the test specs disable
debuginfo); the `$out` self-prefix alias (WP3).
