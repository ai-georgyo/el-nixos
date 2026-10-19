# WP7: rockyBoot.s1.glibc (milestone M1)

Branch `nn/wp7`, built on `nn/wp8` (4604871, which is on `nn/wp6` abca219).
Design: `docs/nix-native-design.md` §0.4.1, §4, §11.5, §12 WP7.

## What exists

| file | role |
|---|---|
| `packages/glibc/default.nix` | the final S1 override set (§11.5 + E4 + partition replay), header documents every entry's evidence |
| `packages/glibc/{glibc.site,nix-patches/*.patch,late-referrers.nix}` | unchanged from WP0d |
| `lib/rocky/checks/glibc-smoke.nix` | `checks.nn-glibc-smoke`, the M1 acceptance test |
| `lib/rocky/overrides.nix`, `lib/rocky/stage.nix`, `packages/README-overrides.md` | new override field `inputs.addBuildOnly` |
| `lib/rocky/cc/wrap.nix` | `libcAdapter` takes `headers` (more include roots); `-m32` with a split libc also searches `<out>/include` |
| `bootstrap/nn/s1.nix` | `glibc1Libc` brings kernel-headers as include root; `nn.stages.s1.{glibc1Libc,ccGlibc1}` exposed |

## The override set (packages/glibc/default.nix)

| field | value | evidence |
|---|---|---|
| `configSite` | `glibc.site` (slibdir, rtlddir, complocaledir, rootsbindir below the prefix) | WP0d, E5 |
| `nixPatches` | P1 ld-so-cache, P2 locale-archive, P3 ld-preload (applied by `%__spec_prep_post`, `--fuzz=0`) | `checks.nn-glibc-prep` |
| `env` | `NIX_NO_SELF_RPATH = "1"`, `NIX_DONT_SET_RPATH = "1"` (structured `env`: derivation attributes); `user-defined-trusted-dirs = <libgccForGlibc>/lib64:<libgccForGlibc>/lib` (not an identifier: mkRpmPackage passes it only as `env 'k=v' rpmbuild`) | E5, WP6 |
| `inputs.addBuildOnly` | `kernel-headers` (relocated, WP8), `glibcBuildDeps` (hoisted stage0 gd/png/z/selinux/audit/cap/sdt.h) | new field, below |
| `mergeOutputs` | `[ [ glibc glibc32 ] ]` (functional merge) | §3.3 |
| `runtimeSearchPaths` | locale-archive → LOCALE_ARCHIVE, lib/locale → LOCPATH, share/i18n → I18NPATH, lib64/gconv → GCONV_PATH | §4.2 |
| `unionDirs` | lib64, lib/locale, share/locale | §4.2 |
| `danglingOk` | share/zoneinfo, libx32, lib/gconv, lib/libmemusage.so | §4.2 + replay |
| `prefixRelativeOk` | benchtests, sysroot_x86_64_el10_glibc | replay |
| `opaqueRefs` | common:bin/locale, common:bin/localedef, static:lib64/libc.a, benchtests, sysroot_x86_64_el10_glibc | E4 + replay (see the E4 rescan below) |
| `noPatchelf` | the loaders, lib64/lib\*.so\*, lib/lib\*.so\*, the sysroot | §11.5 |
| `allowUnresolvedNeeded` (S1 only) | libgd.so.3 libpng16.so.16 libz.so.1 libselinux.so.1 | §4.6 |
| `fhsAllowlist` (S1 only) | `#!/usr/bin/bash`, `#!/usr/bin/sh` (mtrace), `#!/usr/bin/python3` (benchtests) | §4.6 |
| `lateBind` / `lateReferrers` | common (bash), utils (bash perl; gd libpng zlib-ng), nss_db (libselinux), benchtests (bash python3); referrers from E4 — declared, inactive in S1 (WP11 owns the bind derivation) | §4.6, E4 |

## Decisions

* **kernel-headers is build-only for glibc** (new override field
  `inputs.addBuildOnly`: a host input — cc-wrapper input, `/usr` view, so
  `--with-headers=%{_prefix}/include` still resolves through the `$out`
  alias — that is never a runtime input, even when Rocky-built). WP8 made
  kernel-headers a Rocky-built `inputs.add` entry, which put it into glibc's
  `allowedReferences`/`allowedStorePaths`, i.e. an accidental reference would
  no longer fail (WP8 open issue 1). M1's rule is "closure = own outputs +
  libgccForGlibc", so it is now build-only, and outputChecks /
  `foreign-store-path` reject any reference again. Measured: no glibc output
  references kernel-headers.
* **Consumers get the kernel headers from the toolchain, not from
  glibc.dev.** Rocky's glibc-devel Requires kernel-headers, and nixpkgs links
  linuxHeaders into glibc's dev; here the dev output stays self-contained in
  the closure sense and `nn.cc.libcAdapter { out; dev; headers = [ kernel-headers ]; }`
  appends `-idirafter <kernel-headers>/include` to the wrapper's libc flags
  (after the libc's own include dir, as in Rocky's merged /usr/include).
  `nn.stages.s1.glibc1Libc` / `ccGlibc1` do this; `nn.cc.wrap { libc =
  rockyBoot.s1.glibc; }` alone compiles programs that need no linux/ asm/
  headers (hello world). Without kernel headers glibc's own `<errno.h>`
  fails (`linux/errno.h`). Design §5.6 (dev propagates kernel-headers) is
  therefore not followed for glibc; a `buildInputs = [ glibc.dev ]`
  consumer outside the wrapper would need kernel-headers explicitly.
* **`opaqueRefs` keeps the E4/replay entries that this build does not need**
  (static libc.a, benchtests, sysroot): the rescan below finds pieced
  references only in common's locale/localedef. They are acks of known
  classes (static dl-load.o, test support, cross sysroot) that a rebuild with
  another gcc (S3a) may produce again; every pieced reference is registered in
  `hidden-references` with or without ack.

## Fixes on the way

1. **`-m32` with a split libc** (lib/rocky/cc/wrap.nix): glibc32 is merged
   into `out`, which holds `include/gnu/stubs-32.h` and
   `gnu/lib-names-32.h`; the wrapper only searched dev's include, so every
   `-m32` compile failed (`gnu/stubs-32.h: No such file`). The m32 hook now
   also adds `-idirafter <out>/include` when out ≠ dev (through the existing
   `@libcOutB@` substitution, so wrappers over an unsplit libc — every S1
   package's `nn.cc.stage0` — are unchanged derivations).
   `checks.nn-cc-toolchain` (whose part C wrapper is split) re-run: passes.
2. **`inputs.addBuildOnly`** (overrides.nix schema, stage.nix
   resolveBuildDeps, README-overrides.md): see Decisions.
3. **`libcAdapter` `headers`** (wrap.nix): see Decisions. Empty for every
   existing wrapper (unchanged derivations; which/xz/zlib-ng/gzip and
   kernel-headers stay cached).

No partition, shim or mkRpmPackage bug was found: with the final override
set the first build of the final derivation passed.

## Results (real builds)

`nix build -L --cores 8 --max-jobs 2`, local sandbox.

| item | result |
|---|---|
| `rockyBoot.s1.glibc` | **built**, `out` = `/nix/store/xl44f3c01wdqzkj0wq8w14sy7677m67c-glibc-2.39-142.el10_2` |
| build time | 683 s wall for the derivation: rpmbuild 9 min 43 s (`%prep` … `%install`, find-debuginfo, both x86_64 and i686 builds), partition + fixup + shebang gate ≈ 1.5 min, rest registration of 225 outputs |
| outputs | **225** = 224 subpackages − 1 (glibc32 merged into out) + debug + logs; = `names.outputsFor`; partition: 233 subpackages (224 + 9 debuginfo/debugsource → debug) |
| partition report | **0 errors**, 3 warnings (`not-required`: the unshipped sysroot's `libc.so`/`libm.a` ld scripts name `$out/lib64/libc_nonshared.a`, `libm-2.39.a`, `libmvec.a`, which live in dev/static that the sysroot does not Require: kept as `$out/...`, as in the replay), 409 info (309 prefix-relative acked: benchtests/sysroot; 16 dangling acked; 10 binary-ref with runtimeSearchPaths; 4 unresolved-needed allowed; 2 pieced; 10 fhs-shebang allowed) |
| shebang gate | 0 unbound, 10 allowed (ldd sotruss tzselect memusage xtrace glibc-bench-compare `#!/usr/bin/bash`, mtrace `#!/usr/bin/sh`, 3 benchtests `#!/usr/bin/python3`) |
| outputChecks | pass (allowedReferences = allowedRequisites = siblings + libgccForGlibc for every managed output) |
| `checks.nn-glibc-smoke` | **passes**: 17 eval + 29 build assertions, `/nix/store/xai04630mkzg2wzykxiappjcvxnfgwv6-nn-glibc-smoke` (below) |
| `nix build --rebuild` (all outputs) | **passes**: exit 0, all 225 outputs (logs and debug included) bit-identical to the first build |

### Closures (from `nn-glibc-smoke`, exportReferencesGraph)

| output | closure paths | closure size | own NAR |
|---|---|---|---|
| out | 2 (out, libgccForGlibc) | 17.3 MiB | 16.9 MiB |
| dev | 3 | 19.9 MiB | 2.5 MiB |
| common | 3 | 18.4 MiB | 1.1 MiB |
| utils | 3 | 17.5 MiB | 0.1 MiB |
| static | 3 | 27.4 MiB | 10.0 MiB |
| langpack_de | 1 | 23.2 MiB | 23.2 MiB |
| all_langpacks | 1 | 442.7 MiB | 442.7 MiB |
| minimal_langpack | 1 | 0.0 MiB | 0.0 MiB |
| debug | 10 | 131.7 MiB | 84.8 MiB |

All 224 outputs together (debug included): 1521.1 MiB NAR; libgccForGlibc
0.4 MiB. Outputs referencing libgccForGlibc directly: out (ld.so's trusted
dirs), static (libc.a's dl-load.o), sysroot (its ld.so copy). Every
closure ⊆ glibc's outputs + libgccForGlibc; the output reference graph is
acyclic.

### nn-glibc-smoke assertions

* eval: output count/names/order, glibc32 → out, unshipped set, structured
  env (NIX_NO_SELF_RPATH, NIX_DONT_SET_RPATH) vs. command-line env
  (user-defined-trusted-dirs = libgcc lib64:lib), P1–P3, CONFIG_SITE,
  allowedReferences/allowedRequisites = siblings + libgccForGlibc, plan
  allowedStorePaths = [libgccForGlibc] and no inputLibDirs, kernel-headers
  in the view but not allowed, systemLibDirs, lateBind/lateReferrers,
  S1 exceptions, rockyStage.
* report 0 errors, no cycle; closures as above.
* nested scan of all 224 outputs + logs: 14 738 files, 1 664 symlinks,
  11 454 ELF files (sections decoded, compressed debug sections and
  `.gnu_debugdata`), 10 010 ar members, 254 gzip/xz/bzip2/zstd files decoded:
  **0** foreign full store paths, **0** 8-byte pieces of the 44 build inputs'
  hashes (gcc/binutils copies and the wrappers, stage0 libc tree,
  glibcBuildDeps, kernel-headers, rpm, rpm config, shim, every nixpkgs base
  tool).
* in the check sandbox (no /usr, no /lib64): hello built by
  `nn.cc.wrap { libc = rockyBoot.s1.glibc }` runs (PT_INTERP = out's loader,
  no DT_RPATH); with `ccGlibc1`: linux/errno/ioctl headers (RHEL 10 kernel
  6.12), `pthread_cancel` (libgcc_s.so.1 loaded from libgccForGlibc/lib64,
  `LD_DEBUG=libs`), de_DE via `LOCPATH=<langpack_de>/lib/locale`, fr_FR via
  `LOCALE_ARCHIVE` and via `LOCALE_ARCHIVE_2_27` (P2, all_langpacks'
  archive), langpack_de's generated LOCPATH setup hook, `-static`, `-m32`
  (out/lib/ld-linux.so.2), C++.
* `ld.so --list-diagnostics`: `path.prefix` = out, `path.rtld` =
  out/lib64/ld-linux-x86-64.so.2, `path.system_dirs` = `out/lib64/`,
  `libgccForGlibc/lib64/`, `libgccForGlibc/lib/`; `path.sysconfdir` =
  `out/etc` (P1's change of that diagnostics line; libc keeps `/etc/localtime`,
  `/etc/nsswitch.conf`); `ldconfig -p` reads `out/etc/ld.so.cache` (P1);
  `LOCALE_ARCHIVE_2_27` in libc.so.6 (P2); `/etc/ld-nix.so.preload` and no
  `/etc/ld.so.preload` in ld.so (P3); ld.so without RPATH/RUNPATH.
* `getconf GNU_LIBC_VERSION` = glibc 2.39, `iconv` UTF-8 → ISO-8859-1
  through the default gconv dir, memusagestat NEEDs libgd with no RUNPATH
  outside out (glibcBuildDeps never leak).

### E4 rescan on the real build (WP0d open issue)

Hash-based scan (`$out`'s hash not followed by the full store name =
truncated copy; 8-byte windows of the hash outside full occurrences = split
hash), all outputs, static archive members included:

* truncated copies: `common:bin/locale`, `common:bin/localedef` (one each;
  the partitioner's `pieced` info lists the same two and registered them in
  hidden-references). None in out, static (libc.a's dl-load.o), or the
  sysroot this time (E4 found 7 in the S5/S3 spike builds).
* split-hash windows: **none** anywhere (the random-seed hook is off, E1).

## Hand-off requests: addressed / rejected

| from | request | status |
|---|---|---|
| partition | danglingOk libx32, lib/gconv; prefixRelativeOk + opaqueRefs benchtests, sysroot; opaqueRefs common:bin/locale, localedef | done |
| partition | danglingOk lib/libmemusage.so | done |
| glibc (WP0d) | opaqueRefs format | PLAN.md output patterns used directly (`common:bin/locale`) |
| glibc (WP0d) | P2 runtime behaviour, pthread_cancel with libgccForGlibc in a /usr-free sandbox (was WP9's) | done in nn-glibc-smoke (WP9's full runtime/parity checks still open) |
| glibc (WP0d) | rescan E4 on the real build | done (above) |
| glibc (WP0d) | P2 host locale-archive fallbacks | kept as nixpkgs has them (decision unchanged; not WP7's to change) |
| glibc (WP0d) | lateBind exemptions in S3 | answered by WP6 (partitioner exempts lateBind outputs); S3 not built |
| cc | wrapper not tried against the real relocated glibc | done: hello, C++, -static, -m32, pthread programs; found and fixed the -m32 include bug |
| cc | programs get RUNPATH $dev/lib64 with a split libc | observed behaviour of the wrapper for consumers; Phase E fixes it inside mkRpmPackage builds; not changed |
| WP8 | glibc may now reference kernel-headers (allowed) | rejected for M1: kernel-headers is build-only (`inputs.addBuildOnly`); outputs reference it nowhere |
| WP6 | packages/glibc/default.nix lacks the replay entries | done |
| design §5.6 | glibc-devel propagates kernel-headers | not followed (closure rule); the toolchain adds the headers |
| design §12 | "223 subpackage outputs, verified against the official RPMs (file lists 221/221, ABI, behaviour report)" | outputs/closure/behaviour smoke done here; the file-list/ABI/content parity against the official RPMs is WP9 (not run) |

## Open

* Parity against the official RPMs (file lists, ABI, content) is WP9's
  `checks.nn-glibc-{files,abi,content,closure,runtime}`; not run here.
* `nn.stages.s1Glibc1` (S1 packages on glibc¹) evaluates; not built. Its
  view still gets glibc.dev only (`libcDevFor`), kernel headers only through
  the wrapper's `-idirafter`; a package that looks for `/usr/include/linux`
  by path would need kernel-headers in its view.
* The sysroot's ld scripts keep `$out/lib64/libc_nonshared.a` etc. (warnings
  above): the unshipped sysroot is not usable as a cross sysroot as is.
* The S1 exceptions (FHS shebangs, unresolved NEEDED of memusagestat and
  makedb) remain until lateBind (WP11) and S3.
