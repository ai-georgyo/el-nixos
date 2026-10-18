# Rocky 10 RPM build-toolchain compatibility (stage0 research)

Scope: what `rpmbuild --rebuild` of a Rocky Linux 10.2 SRPM (first target:
`glibc-2.39-142.el10_2`) needs from the toolchain, and how nixpkgs
(nixos-26.05: gcc14 = 14.4.0, binutils 2.46, rpm 4.20.1, debugedit 5.2,
dwz 0.16, gdb 17.2, elfutils 0.194) compares to what Rocky used.

Sources studied (sha256 matched the lock / repodata):

| SRPM | sha256 (prefix) |
|---|---|
| redhat-rpm-config-295-1.el10.rocky.0.2 | 84768fa1… |
| rpm-4.19.1.1-23.el10 | 39fd7987… |
| package-notes-0.5-13.el10 | 998ed918… |
| python-rpm-macros-3.12-11.el10 | 7999d8ca… |
| python-rpm-generators-14-12.el10 | fde62b2d… |
| perl-generators-1.16-7.el10, perl-srpm-macros-1-57.el10 | fd4a8c38…, c2eb6d0c… |
| kernel-srpm-macros-1.0-27.el10 | 9775b411… |
| debugedit-5.1-8.el10 | 7a3ab1c9… |
| rocky-release-10.2-1.2.el10, efi-rpm-macros-6-7.el10.rocky.0.1, annobin-13.02-2.el10 | 6dda257e…, b7f8099d…, 581963df… |

Ground truth: the official `glibc-2.39-142.el10_2.x86_64.rpm` header
(`RPMVERSION=4.19.1.1`, payload `zstd/19`, `FILEDIGESTALGO=8`, `PLATFORM=x86_64-redhat-linux-gnu`)
and ELF files extracted from it.

File references below are `<srpm>:<file>:<line>`. "rrc" means redhat-rpm-config
and "rpm" means the rpm-4.19.1.1 tarball inside the rpm SRPM.

---

## 0. Summary and recommendations

1. **Build Rocky's own rpm 4.19.1.1 (all 33 `%patchlist` patches) in stage0. Do not
   use nixpkgs rpm 4.20.1.** As shipped, nixpkgs rpm can't be used here. It is built with
   vendor `vendor` (it reads `/usr/lib/rpm/vendor/macros`, not `redhat/macros`).
   It ships no `platform/` directory, so `%_prefix`/`%_libdir` fall back to its
   own store path and `/lib`. It hard-codes nixpkgs store paths for `%__strip`, `%__objdump`,
   `%__cc` (a gcc-15 wrapper), `%__tar` and so on. Its `%_host` is `x86_64-vendor-linux`.
   It turns `%patchN` into a hard error, uses a different `%builddir` and buildroot layout,
   re-enables sysusers, and drops Rocky's `%_use_weak_usergroup_deps` and
   `%_dbpath`. Section 5 has the details and a CMake recipe. Later stages rebuild
   rpm from the same SRPM anyway, so stage0 uses the same source.
2. **Flags:** nixpkgs gcc 14.4.0 and binutils 2.46 accept every flag in the
   RHEL 10 x86_64 set (tested: hardened specs, `-march=x86-64-v3`, `-mtls-dialect=gnu2`,
   `-fcf-protection`, `-fstack-clash-protection`, `_FORTIFY_SOURCE=3`, LTO,
   `-Wno-complain-wrong-lang`, `-z pack-relative-relocs`, `--error-rwx-segments`,
   package notes). The one thing missing is the **annobin plugin**. Turn it off with
   `--define '_annotated_build 0' --define '_annobin_gcc_plugin %{nil}'`. Do **not** use
   `--undefine` together with `--target`, because rpmbuild drops undefines when it reloads the config for each target (section 2.3).
   Use **gcc14, not the default nixpkgs gcc (15.3)**. GCC 15 defaults to C23 and
   would break many el10 specs. `-Wno-complain-wrong-lang` needs GCC >= 14.
3. **gcc and binutils *defaults* differ from Rocky, and this matters for glibc.** Rocky gcc
   is configured with `--enable-linker-build-id --with-linker-hash-style=gnu
   --with-arch_64=x86-64-v3 --enable-cet --enable-plugin`, without default PIE.
   nixpkgs unwrapped gcc14 has *no* build-id, the linker default hash style is
   `both`, it has `--enable-default-pie` and `--disable-multilib`, its dynamic linker
   is baked to nixpkgs glibc, and its native header dir is nixpkgs glibc-dev.
   glibc does not pass `--build-id` itself, and Rocky sets
   `%_missing_build_ids_terminate_build 1`, so **without a build-id default the
   glibc build fails in find-debuginfo**. Without `--hash-style=gnu`, glibc-common and glibc-utils
   lose `rtld(GNU_HASH)` from their Requires. Stage0 has to bring these defaults back,
   either with a gcc driver shim or specs file or by rebuilding gcc14 with those configure flags (section 2.5).
4. **BRPs:** all the scripts work with stock GNU tools. `check-rpaths` *fails the build*
   on any `/nix/store/...` RPATH or RUNPATH (it treats one as an "invalid rpath", badness 0x2), which makes it a useful
   tripwire. `check-buildroot` only looks for the `$RPM_BUILD_ROOT` string, so it ignores `/nix/store`.
   `brp-mangle-shebangs` leaves `#!/nix/store/...` shebangs **untouched and silent**, so
   stage0 `PATH` must resolve `bash`, `perl` and `python3` to `/usr/bin/*` (section 3).
   `%__os_install_post` *unconditionally* expands `%{__os_install_post_python}`, so
   python-srpm-macros (or a stub definition) is mandatory.
5. **Debuginfo:** Rocky uses debugedit **5.1-8** and nixpkgs has **5.2**. 5.2 starts
   processing static `.ar` archives (rewriting source paths in `libc.a` and the like and collecting their sources),
   which changes `glibc-static` and `glibc-debugsource`. Build Rocky's debugedit 5.1
   in stage0 (small autotools package), or at least pass `--no-ar-files`. dwz 0.16 is the same version on both sides.
   gdb-add-index comes from gdb 17.2 instead of 16.3, so `.gdb_index` output may differ slightly.
6. **Dependency generators:** for glibc parity, rpm's own `elf.attr`, `script.attr`
   and `libsymlink.attr` (rrc) are what matter. python3-rpm-generators and perl-generators do not change
   glibc's dependencies (checked against the official Requires), but
   `pythonname.attr` matches *every* file (`^/`) and needs
   `%_rpmluadir/fedora/srpm/python.lua`. Either install both or neither.

---

## 1. How rpm finds its configuration (and why vendor and platform matter)

`rpm:lib/rpmrc.c:456-480` (`setDefaults`):

```
rcfiles   = <confdir>/rpmrc : <confdir>/<RPM_VENDOR>/rpmrc : /etc/rpmrc : ~/.rpmrc
macrofiles= <confdir>/macros : <confdir>/macros.d/macros.* :
            <confdir>/platform/%{_target}/macros : <confdir>/fileattrs/*.attr :
            <confdir>/<RPM_VENDOR>/macros : /etc/rpm/macros.* : /etc/rpm/macros :
            /etc/rpm/%{_target}/macros : ~/.rpmmacros
```

* Rocky builds rpm with `-DRPM_VENDOR=redhat` (`rpm.spec` `%build`), so
  `/usr/lib/rpm/redhat/{rpmrc,macros}` (rrc) are loaded **after**
  `macros.d/*` and the platform file. That is why rrc can redefine
  `%__os_install_post` and other macros.
* `<confdir>` = `RPM_CONFIGDIR` env or compiled `/usr/lib/rpm`
  (`rpm:rpmio/rpmfileutil.c:484`).
* **x86_64 sub-arch auto-detection:** rpm 4.19/4.20 detect `x86_64_v2/v3/v4`
  from the CPU and load `platform/x86_64_v3-linux/macros` (seen with `strace` on
  this host). rpmrc's `buildarchtranslate` maps the *package* arch back to
  `x86_64`. Rocky's `installplatform` creates platform dirs for every
  `arch_canon` (`rpm:installplatform:14`). If the detected dir is missing,
  `%_arch`, `%_lib` and `%_libdir` silently fall back to defaults (`%_libdir`=/usr/lib on 4.19,
  the rpm store path on nixpkgs 4.20). nixbuild.net builders may detect `x86_64_v4`.
  **Always pass `--target x86_64`.** It forces `platform/x86_64-linux` (verified:
  without it `%_arch` is undefined and `%_libdir` is wrong; with it `%_libdir=/usr/lib64`). mock does the same.
* nixpkgs rpm 4.20.1 (`/nix/store/bdydmc07…-rpm-4.20.1`): compiled vendor is
  `vendor`, there is **no `lib/rpm/platform/` at all**, `%_prefix`/`%_usr` are its own
  store path, and `%_host` is `x86_64-vendor-linux`.

The scratch eval harness used for every expansion in this document is
`/tmp/claude-60514/-run-host-home-ai-shammas-Code-el-nixos/dadc2aad-80ad-416a-b238-b2a3e0de53b8/scratchpad/research-toolchain/eval.sh`.
It runs nixpkgs rpm with `RPM_CONFIGDIR` pointed at a tree containing Rocky's rrc
macros/rpmrc (vendor symlinked to redhat), a platform file rendered from rpm-4.19's
`platform.in`, and the macros.d files listed in section 7. Its `%optflags` matches
the official glibc RPM's `OPTFLAGS` header **byte for byte**.

## 2. Effective build flags, x86_64, `%rhel 10`

### 2.1 Expansions (with `--target x86_64`, name=glibc)

```
%optflags (= RPM header OPTFLAGS of official glibc):
 -O2 -flto=auto -ffat-lto-objects -fexceptions -g -grecord-gcc-switches -pipe -Wall
 -Wno-complain-wrong-lang -Werror=format-security -Wp,-U_FORTIFY_SOURCE,-D_FORTIFY_SOURCE=3
 -Wp,-D_GLIBCXX_ASSERTIONS -specs=/usr/lib/rpm/redhat/redhat-hardened-cc1 -fstack-protector-strong
 -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1  -m64 -march=x86-64-v3 -mtune=generic
 -fasynchronous-unwind-tables -fstack-clash-protection -fcf-protection -mtls-dialect=gnu2

%build_cflags / %build_cxxflags / %__global_cflags: same as %optflags minus
  -Wno-complain-wrong-lang (it is emitted only when __build_for_lang_any; rrc:macros:419,440-442)
%build_fflags: %optflags (without -Werror=format-security) + -I/usr/lib64/gfortran/modules

%build_ldflags (= %__global_ldflags):
 -Wl,-z,relro -Wl,--as-needed  -Wl,-z,pack-relative-relocs -Wl,-z,now
 -specs=/usr/lib/rpm/redhat/redhat-hardened-ld -specs=/usr/lib/rpm/redhat/redhat-hardened-ld-errors
 -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1  -Wl,--build-id=sha1
 -specs=/usr/lib/rpm/redhat/redhat-package-notes
```

Where each part comes from:

| Piece | Defined at | Value on el10 x86_64 | gcc 14.4 / binutils 2.46 | stage0 action |
|---|---|---|---|---|
| `optflags: x86_64` | rrc:rpmrc:8 | `%{__global_compiler_flags} -m64 %{__cflags_arch_x86_64} %__cflags_arch_x86_64_common` | — | none |
| `-march=x86-64-v3` | rrc:macros:148-149 (`%[0%{?rhel} > 9 ? "-v3"]`) | needs `%rhel 10` (rocky-release `macros.dist`) | gcc >= 11, OK | define `%rhel 10` |
| `-mtune=generic -fasynchronous-unwind-tables -fstack-clash-protection -fcf-protection` | rrc:macros:152 | | gcc >= 8, OK; binutils emits IBT/SHSTK property (tested) | none |
| `-mtls-dialect=gnu2` | rrc:macros:152 (gcc only) | | OK (TLSDESC; runtime glibc support) | none |
| frame pointers | rrc:macros:367-369 | `%_include_frame_pointers` = `0 \|\| 010 >= 11` → off on el10 | — | none |
| `-O2 %{?_lto_cflags} -fexceptions -g -grecord-gcc-switches -pipe` | rrc:macros:418 | | OK | none |
| `_lto_cflags` | rrc:macros:397-399 | `-flto=auto -ffat-lto-objects` | OK. nixpkgs binutils-unwrapped has **no `lib/bfd-plugins`**, so for parity with Rocky's `ar`/`nm`, add `/usr/lib/bfd-plugins/liblto_plugin.so` → gcc's `liblto_plugin.so` | add the symlink (not needed for glibc) |
| `-Wall -Wno-complain-wrong-lang -Werror=format-security` | rrc:macros:419 | `%build_type_safety_c 3` (rrc:412) adds nothing | `-Wno-complain-wrong-lang` is **GCC 14+** | use gcc14 |
| `_FORTIFY_SOURCE` | rrc:macros:407-408 | `-Wp,-U_FORTIFY_SOURCE,-D_FORTIFY_SOURCE=3` | level 3 needs gcc >= 12, OK | none |
| `-Wp,-D_GLIBCXX_ASSERTIONS` | rrc:macros:420 | | OK | none |
| `_hardened_build` | rrc:macros:324-344 | 1 → cflags `-specs=redhat-hardened-cc1 -fstack-protector-strong`; ldflags `-Wl,-z,now -specs=redhat-hardened-ld -specs=redhat-hardened-ld-errors` | spec syntax is upstream GCC, works (tested: PIE, BIND_NOW) | none. Note nixpkgs gcc is `--enable-default-pie`, so PIE also shows up where Rocky's specs would not add it (`-r`, `-fno-pic`...) |
| `redhat-hardened-cc1` | rrc:redhat-hardened-cc1 | adds `-fPIE` unless `-r/-fpic/-fPIC/-fpie/-fPIE/-fno-pic` | OK | none |
| `redhat-hardened-ld` | rrc:redhat-hardened-ld | `-pie` unless `-static/-shared/-r` | OK | none |
| `redhat-hardened-ld-errors` | rrc:redhat-hardened-ld-errors, macros:331-335 | `-Wl,--error-rwx-segments -Wl,--error-execstack` unless `-fuse-ld*` | needs binutils >= 2.42 upstream (Rocky backports to 2.41); 2.46 OK | none |
| `-z pack-relative-relocs` | rrc:macros:386-387 | DT_RELR | binutils >= 2.38; binaries then need `GLIBC_ABI_DT_RELR` (glibc >= 2.36) | none |
| `-Wl,--build-id=sha1` | rrc:macros:416 | | OK | none (this covers only packages that use `%build_ldflags`, see section 2.5) |
| `_annotated_build` / annobin | rrc:macros:351-360 | `-specs=redhat-annobin-cc1` in cflags, and in ldflags when LTO is on | **nixpkgs has no annobin package.** Tested: `fatal error: inaccessible plugin file …/plugin/annobin.so` | disable (section 2.3) |
| `redhat-annobin-cc1` | rrc:redhat-annobin-cc1 (a copy of `…select-annobin-built-plugin`, swapped by the `redhat-annobin-plugin-select.sh` trigger, rrc spec:206-217) | `%{!-fno-use-annobin:%{!iplugindir*:%:find-plugindir()} -fplugin=annobin}` | `find-plugindir` is an upstream spec function | — |
| package notes | package-notes:macros.package-notes-srpm:15-29; rrc:macros:82,106-112 | `-specs=/usr/lib/rpm/redhat/redhat-package-notes` → `--package-metadata={"type":"rpm",…,"osCpe":"cpe:/o:rocky:rocky:10::baseos"}` | needs binutils >= 2.39; tested, writes the `FDO_PACKAGING_METADATA` note | build package-notes-srpm-macros. Its `%build` reads `/usr/lib/system-release-cpe` (rocky-release); needs `RPM_PACKAGE_*`/`RPM_ARCH` env, which rpmbuild sets |
| `-Wl,--as-needed`, `-Wl,-z,relro` | rrc:macros:82,383 | | OK | none |
| `%_ld_strict_symbol_defs` | rrc:macros:377-378 | off | — | — |

The opt-out knobs are `%undefine _hardened_build`, `%define _fortify_level 2`,
`%global _lto_cflags %{nil}` and `%undefine _package_note_flags`
(rrc buildflags.md:199-380). Note that rrc **tests most of these by definedness**
(`%{?_hardened_build:…}`, `%{?_annotated_build:…}`), so `%define X 0` does
**not** disable `_hardened_build` or `_annotated_build`. You must undefine them or override what they expand to.

### 2.2 What glibc actually uses

`glibc.spec:81` does `%undefine _auto_set_build_flags`, so `CFLAGS` and `LDFLAGS` are
never exported and `%build_ldflags` is unused. **glibc gets no hardened-ld specs, no
package notes and no `--build-id` from rpm.** The official `libc.so.6` has no FDO
packaging note, which confirms this. `glibc.spec:1225-1310` filters `%build_cflags` through
allow-lists:

* CC (main build only): `-march=x86-64-v3 -mtune=generic`. CC (all): `-m64`.
* CFLAGS: `-O2 -Wall -Wp,-D_GLIBCXX_ASSERTIONS -fasynchronous-unwind-tables
  -fstack-clash-protection -g -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1`.
* So **glibc never sees** `-flto`, `_FORTIFY_SOURCE`, `-fcf-protection`,
  `-mtls-dialect=gnu2` or the hardened specs. It configures `--enable-cet`,
  `--enable-stack-protector=strong`, `--enable-fortify-source` and `--enable-bind-now` itself.
  It also uses `--with-rtld-early-cflags=-march=x86-64` and
  `LDFLAGS.so/LDFLAGS-rtld=-Wl,--hash-style=both` (glibc.spec:1350-1386).
* `glibc.spec:1315-1322`: when `0%{?_annotated_build} > 0`,
  `BuildFlagsNonshared="-fplugin=annobin -fplugin-arg-annobin-disable -Wa,--generate-missing-build-notes=yes"`
  is passed as `--with-nonshared-cflags`. This is a **direct `-fplugin=annobin`**, so it needs the
  plugin regardless of the specs file. `ASFLAGS="-g -Wa,--generate-missing-build-notes=yes"` is
  passed unconditionally (glibc.spec:1327-1329). That gas option is upstream (2.46 lists it),
  so it is OK.
* Official ELF results: `libc.so.6` and `ld.so` carry `.annobin.notes`,
  `.gnu.build.attributes` and `.comment = "GCC: (GNU) 14.3.1 20251022 (Red Hat 14.3.1-4)"`.
  `/usr/bin/locale` has **only `.gnu.hash`** (gcc default `--hash-style=gnu`), plus
  `.gnu_debugdata` (minidebuginfo), `.relr.dyn` and build-ids everywhere. The
  x86 ISA-needed property is `x86-64-v3`.

### 2.3 Disabling annobin cleanly (stage0)

Pass both:

```
--define '_annotated_build 0' --define '_annobin_gcc_plugin %{nil}'
```

* `_annobin_gcc_plugin %{nil}` empties `%_annotation_plugin`, which removes
  `-specs=…annobin-cc1` from cflags and ldflags (rrc:macros:352-357).
* `_annotated_build 0` makes glibc's `%if 0%{?_annotated_build} > 0` false, so there is no
  `-fplugin=annobin` in `BuildFlagsNonshared`.
* Verified with `--target x86_64`. `%_find_debuginfo_extra_opts` still expands to
  `--remove-section .gnu.build.attributes`, which does nothing when the section is absent.
* **Pitfall:** `rpmbuild --target X --undefine Y` **does not work**. With
  `--target`, rpmbuild calls `rpmFreeMacros(); rpmReadConfigFiles(rcfile, target)`
  (`rpm:tools/rpmbuild.c:574-580`). The reload restores CLI `--define`s from
  `rpmCLIMacroContext` but not `--undefine`s (`rpm:lib/poptALL.c:124-128`
  just pops the live context). This was reproduced with `rpm --target x86_64 --undefine _annotated_build --eval`,
  which still gave `1`. Macro *files* cannot `%undefine` either.
* Effect: the `OPTFLAGS` header and `DW_AT_producer` lose the annobin spec, and there are no
  `.annobin.notes` or `.gnu.build.attributes`. Document this as a known diff. Annobin parity returns once the
  stage1 gcc is built from the gcc SRPM, which builds `gcc-plugin-annobin` itself
  (`gcc.spec:921-929`). An alternative is building annobin-13.02 in stage0 with
  `--without clangplugin --without llvmplugin --without annocheck --without tests`
  (annobin.spec:15-34). Its plugin dir is `gcc --print-file-name=plugin`, a read-only
  store path, so it would also need `-iplugindir=`. Not worth it for milestone 1.

### 2.4 Other macro facts that matter

* `%_binary_payload w19.zstdio` (rrc:macros:316). This is **zstd level 19, single-threaded**
  (not `w19T8`). The official header shows `zstd/19`. `%_source_payload` is unset, so SRPMs use
  gzip/9 (the official SRPMs show `gzip 9`).
* `%_source_filedigest_algorithm 8`, `%_binary_filedigest_algorithm 8` (SHA-256), rrc:312-313.
* `%source_date_epoch_from_changelog 1`, `%clamp_mtime_to_source_date_epoch 1`
  (rrc:22-23), `%use_source_date_epoch_as_buildtime 0` (rpm default; we
  override it to 1 for reproducibility, which is a documented difference), and `%_changelog_trimage` 2 years.
* `%_enable_debug_packages 1`, `%_include_minidebuginfo 1`, `%_include_gdb_index 1`,
  `%_debugsource_packages 1`, `%_debuginfo_subpackages 1` (rrc:25-29);
  `%_missing_build_ids_terminate_build 1` (rrc:309).
* `%__cc gcc`, `%__cxx g++`, `%__cpp gcc -E` (rrc:32-46). Other tool macros
  (`%__strip %__objdump %__ar %__as %__ld %__tar %__patch …`) come from rpm's
  `macros`, so they are whatever rpm's CMake `findutil` found (`rpm:CMakeLists.txt:55-140`).
* `%__spec_install_pre` (rrc:250-255) runs `%set_build_flags` in `%install` too.
* `%configure` (rrc:213-240) replaces `config.guess` and `config.sub` with
  `/usr/lib/rpm/redhat/config.*` and patches `ltmain.sh`. When LTO is on it also patches `configure` scripts.

### 2.5 gcc and binutils *built-in defaults* (not macros), Rocky vs nixpkgs

| Default | Rocky gcc 14.3.1-4.4 / binutils 2.41-63 | nixpkgs gcc 14.4.0 (unwrapped) / binutils 2.46 | Impact |
|---|---|---|---|
| linker build-id | `--enable-linker-build-id` (gcc.spec:1440) | none (`-dumpspecs` has no build-id) | **glibc links without `--build-id`, so find-debuginfo `--strict-build-id` fails the build.** Must fix. |
| hash style | `--with-linker-hash-style=gnu` (gcc.spec:1473); binutils `--enable-default-hash-style=gnu` | ld default `both` | glibc executables get `.hash` too, which drops `rtld(GNU_HASH)` from Requires (official glibc-common/-utils have it). Must fix. |
| default -march (64-bit) | `--with-arch_64=x86-64-v3` (gcc.spec:1540) | x86-64 | Code built without rpm flags differs |
| default PIE | no (specs add it) | `--enable-default-pie` | Minor |
| CET | `--enable-cet` | not configured | `-fcf-protection` still works (tested) |
| multilib | yes (glibc32 build: `CC="gcc -m32"`, glibc.spec:1389-1395) | `--disable-multilib` | **glibc32 build needs a multilib gcc** (glibc track) |
| dynamic linker | `/lib64/ld-linux-x86-64.so.2` | `/nix/store/…glibc-2.42-100/lib64/ld-linux-x86-64.so.2` | glibc passes its own `-dynamic-linker`; other packages leak (caught only by `allowedReferences`) |
| system headers | `/usr/include` | `--with-native-system-header-dir=…glibc-2.42-100-dev/include` | The stage0 compiler sees nixpkgs glibc headers unless overridden (glibc itself uses `-nostdinc`) |
| target triple | `x86_64-redhat-linux` | `x86_64-unknown-linux-gnu` | `gcc -dumpmachine`, plugin and include dirs differ |
| `.comment` | `GCC: (GNU) 14.3.1 20251022 (Red Hat 14.3.1-4)` | `GCC: (GNU) 14.4.0` | Expected diff |
| ld `-z separate-code` | binutils.spec `enable_separate_code 0` | on by default | Layout differs for non-glibc packages (official glibc has 4 LOAD segments anyway) |
| ld new-dtags | off on RHEL (binutils.spec:49-56) | nixpkgs default | RPATH vs RUNPATH for packages with rpaths |
| gas build notes | `--enable-generate-build-notes=no` | `no` | Same |

Ways to restore the first two (cheapest first):

* A stage0 FHS `/usr/bin/gcc`/`g++`/`cc` shim (a plain script, not the nixpkgs
  cc-wrapper) that **prepends** `-Wl,--build-id=sha1 -Wl,--hash-style=gnu`. Prepending lets
  glibc's own `-Wl,--hash-style=both` win for `.so`/rtld, because the last option wins.
  The shim can also add `-Wl,-dynamic-linker=/lib64/ld-linux-x86-64.so.2` and
  `-idirafter`/`-B` for the FHS glibc when needed.
* Or a full specs file (from `gcc -dumpspecs`, edited) passed by the shim with `-specs=`.
* Or rebuild gcc14 with `--enable-linker-build-id --with-linker-hash-style=gnu`
  (and multilib) through an override. This is costly but the cleanest.

## 3. `%__os_install_post` and the BRP scripts

Order on el10 (rrc:macros:261-301 plus python-srpm-macros:94-99; evaluated):

```
%__spec_install_post =
  %{?__debug_package:%{__debug_install_post}}     # find-debuginfo (glibc wraps it)
  /usr/lib/rpm/check-buildroot                    # %__arch_install_post (rrc:261)
  /usr/lib/rpm/redhat/brp-ldconfig                # glibc: %undefine __brp_ldconfig (glibc.spec:620)
  /usr/lib/rpm/brp-compress
  [brp-strip %{__strip}; brp-strip-comment-note %{__strip} %{__objdump}]   # only if no debug package
  /usr/lib/rpm/redhat/brp-strip-lto %{__strip}
  /usr/lib/rpm/brp-strip-static-archive %{__strip}
  /usr/lib/rpm/check-rpaths
  /usr/lib/rpm/redhat/brp-mangle-shebangs
  /usr/lib/rpm/brp-remove-la-files
  %{__os_install_post_python}:                    # python-srpm-macros; NOT optional (rrc:294)
     /usr/lib/rpm/redhat/brp-python-rpm-in-distinfo
     env [-u SOURCE_DATE_EPOCH] /usr/lib/rpm/redhat/brp-python-bytecompile "" "1" "0" "-jN"
     [brp-fix-pyc-reproducibility, only if %py_reproducible_pyc_path]
     /usr/lib/rpm/redhat/brp-python-hardlink
```

rrc replaces rpm's platform `%__os_install_post` (rpm:platform.in:79-86), which drops
`brp-elfperms`. Build scripts run with `/bin/sh -e`, so if `%__os_install_post_python`
is undefined its literal text fails the build. Install python-srpm-macros, or
define `__os_install_post_python %{nil}`.

| Script (package) | External tools | `/nix/store` behaviour |
|---|---|---|
| check-buildroot (rpm) | find, xargs, grep -F, mktemp | Only greps for the literal `$RPM_BUILD_ROOT`, so store strings pass. Skip with `QA_SKIP_BUILD_ROOT` |
| brp-ldconfig (rrc) | `/sbin/ldconfig -N -r $RPM_BUILD_ROOT` | stage0 uses nixpkgs ldconfig (glibc disables this step) |
| brp-compress (rpm) | gzip -9 -n, gunzip, bunzip2, unxz, unzstd, find, sed, awk, ls | n/a. Takes `%{?_prefix}` as argument in rpm's version; rrc's call passes none and defaults to /usr |
| brp-strip (rpm) | file, sed, grep, xargs, `%__strip -g` | `%__strip` must be `/usr/bin/strip` (nixpkgs rpm bakes a gcc-15-wrapper strip) |
| brp-strip-comment-note (rpm) | file, `%__objdump -h`, `%__strip -R .comment [-R .note]` | Only executables, and only without debuginfo |
| brp-strip-lto (rrc) | **eu-elfclassify** (elfutils), `%__strip -p -R .gnu.lto_* …` | — |
| brp-strip-static-archive (rpm) | file, `%__strip -g` | — |
| check-rpaths / check-rpaths-worker (rpm) | bash, readelf -W -d, grep -E, sed, awk, expr | **`/nix/store/...` RPATH/RUNPATH = badness 2 ("invalid"), which ERRORs and fails the build** (worker:117-141 only accepts `/lib*`, `/usr/lib*`, `/usr/libexec`, `/usr/local/lib*`, `$ORIGIN`). This is a free leak tripwire. Don't set `QA_RPATHS` globally. It does not catch PT_INTERP leaks |
| brp-mangle-shebangs (rrc) | bash, find, `file -N --mime-type`, **grep -P** (PCRE; nixpkgs gnugrep has it), sed, stat, touch, chmod | `#!/nix/store/…` starts with `/` but not `/usr/bin` or `/bin`, so it hits **`continue` (lines 129-137) and is left as-is, silently**. `script.attr` then generates `Requires: /nix/store/…/bash`. Stage0 `PATH` must find bash, perl and python3 at `/usr/bin` so configure scripts (`AC_PATH_PROG(BASH_SHELL)` in glibc gives `ldd`, `sotruss`… shebangs) record FHS paths. Official `ldd` is `#!/usr/bin/bash` |
| brp-remove-la-files (rpm) | find, grep, xargs, rm | — |
| brp-python-bytecompile (python-rpm-macros) | `/usr/bin/python3` **only if** `.py` files exist under `/usr/lib*/python3.X` (`_python_bytecompile_extra 0`) | Not triggered by glibc |
| brp-python-hardlink, brp-python-rpm-in-distinfo | find, cmp/ln, sed | — |
| check-files (rpm, `%__check_files`) | find, sort, comm | — |

## 4. Debuginfo

* rpm's `%__debug_install_post` (rpm:macros.in:153-165) runs
  `%{__find_debuginfo} -jN --strict-build-id [-n] -m -i [--build-id-seed] --unique-debug-suffix
  "-%{VERSION}-%{RELEASE}.%{_arch}" --unique-debug-src-base "%{name}-%{VERSION}-%{RELEASE}.%{_arch}"
  %{?_find_debuginfo_dwz_opts} %{?_find_debuginfo_opts} -S debugsourcefiles.list "%{_builddir}/%{?buildsubdir}"`.
  `%__find_debuginfo` is `/usr/bin/find-debuginfo`, found at CMake time (rpm:CMakeLists.txt:288).
  Rocky also adds `/usr/lib/rpm/find-debuginfo.sh` as a symlink (rpm.spec install).
* rrc adds `--remove-section .gnu.build.attributes` (rrc:360) and dwz options
  `--run-dwz --dwz-low-mem-die-limit 10000000 --dwz-max-die-limit 110000000`
  (rrc:macros.dwz:19-39). `%_build_id_links compat`, `%_unique_build_ids 1`,
  `%_unique_debug_names 1` and `%_unique_debug_srcs 1` are rpm defaults (macros.in:524-550).
* **glibc** wraps it with `bash wrap-find-debuginfo.sh <sysroot> /usr/lib64/ld-linux-x86-64.so.2 <original>`
  (glibc.spec:307-318), and sets `_no_recompute_build_ids 1` and `%undefine _unique_build_ids` (glibc.spec:336-337).
  The wrapper calls `debugedit` (PATH, falling back to `/usr/lib/rpm/debugedit`), `objcopy --merge-notes`,
  `objcopy --add-section`, `strip -w -K …`, `nm --format=posix`, `objcopy --strip-symbols` and
  **`dwz` directly**.
* Tools find-debuginfo needs: bash, debugedit and sepdebugcrcfix (debugedit),
  eu-strip (elfutils), readelf/objcopy/nm (binutils), **gdb-add-index** (gdb;
  rpm-build Requires `/usr/bin/gdb-add-index`), dwz, xz (minidebuginfo), cpio,
  file, gawk, sort, find, xargs, sed, grep, stat.
* Versions:

| | Rocky | nixpkgs | Notes |
|---|---|---|---|
| debugedit | 5.1-8.el10 (+5 patches: binutils-tools override, writable-file check, skip_mini fix, `.debug_str_offsets`) | 5.2 | **5.2 processes `.a` archives** (source-path rewrite and collection, `process_ar` when `ar` supports `O`). Rocky's `glibc-static` `.a` members would keep `/builddir/build/BUILD/…` comp_dirs and the debugsource list would differ. 5.2 has `--no-ar-files`. nixpkgs `find-debuginfo` has a `#!/nix/store/…bash` shebang (fine in stage0) |
| dwz | 0.16-1.el10 | 0.16 | Same |
| gdb (gdb-add-index) | 16.3-3.1.el10_2 (gdb-minimal) | 17.2 | `.gdb_index` contents may differ |
| elfutils (eu-strip, libdw) | 0.194-2.el10.rocky.0.1 | 0.194 | Same upstream |
| xz (minidebuginfo) | 5.6.2 | 5.8.x | Compressed bytes may differ |

  Recommendation: build debugedit 5.1-8 from the Rocky SRPM in stage0
  (autotools; deps: elfutils libelf/libdw, xxhash, help2man optional). Configure it with
  `READELF=readelf OBJCOPY=objcopy NM=nm`, otherwise the binutils-override patch
  bakes store paths. Fallback: nixpkgs 5.2 plus `--define '_find_debuginfo_opts --no-ar-files'`.
* Build IDs must exist on every ELF (`--strict-build-id`). This is the reason for the gcc
  default in section 2.5.

## 5. rpm 4.19.1.1 (Rocky) vs 4.20.1 (nixpkgs)

| Area | 4.19.1.1-23.el10 | 4.20.1 | Matters for |
|---|---|---|---|
| `%patchN` | Deprecation warning (rpm:build/parsePrep.c:452) | **Error** "`%patchN is obsolete, use %patch N`" (string in librpmbuild) | Any el10 spec still using `%patch0`. glibc uses `%autosetup -p1` plus Lua patchgit, so it is fine either way |
| build dir | `%_builddir`=`%{_topdir}/BUILD`, `%buildroot`=`%{_topdir}/BUILDROOT/%{NAME}-%{VERSION}-%{RELEASE}.%{_arch}` | per-package `%{builddir}`=`%{_builddir}/%{NAME}-%{VERSION}-build`, buildroot inside it, `%_buildrootdir` gone | Specs that `cd %{_builddir}`; debugedit base dir; log diffs |
| sysusers | `%__systemd_sysusers` commented out (rpm-4.18.92-disable-sysusers.patch) | Enabled | Auto `user()`/`group()` handling |
| weak user/group deps | `%_use_weak_usergroup_deps 1` (rpm-4.18.90-weak-user-group.patch) | Unset | Requires vs Recommends on `user()`/`group()` |
| `%_dbpath` | `%{_usr}/lib/sysimage/rpm` (rpm-4.17.x-rpm_dbpath.patch) | `/var/lib/rpm` | Buildroot rpmdb location |
| `CONFIG_SITE` | Forced to `NONE` in build scripts (rpm-4.18.x-siteconfig.patch) | Not set | autoconf `config.site` leakage |
| spec-local fileattrs `%_local_file_attrs` | Backported (0002-Add-support-for-spec-local-file-attributes…patch) | Native | — |
| elf.attr | `elfdeps --provides/--requires` | `--multifile` protocol | Should give the same output |
| sysusers.attr | Simple | Adds `__sysusers_dependencies` (`m` lines produce user()/group()) | Extra deps |
| `%autosetup`/`%autopatch` | No `-C`, no `-q` | `-C`, `-q`, warns on empty range | — |
| `%bcond` | — | `bcond_override_default` | — |
| SCM macros | — | Set `GIT_*_DATE` from SOURCE_DATE_EPOCH | — |
| BuildSystem | — | Declarative `BuildSystem:` | Not used by el10 |
| crypto | rpm-sequoia, PQC/multisig patches (`rpm-4.19.x-pqc-*.patch`, needs rpm-sequoia >= 1.9.0) | rpm-sequoia 1.10.0 | Signing only |
| header | `RPMVERSION 4.19.1.1` | `4.20.1` | Byte-level parity |
| `--nodeps` | Skips BuildRequires/BuildConflicts checks, including dynamic ones; output deps are still generated | Same | stage0 |
| `LANG` in scriptlets | `C.UTF-8` (`ENABLE_CUTF8`) | `C.UTF-8` | Same |
| Lua | 5.4 (`find_package(Lua 5.2)`) | 5.4.7 | glibc runs `dofile(%_sourcedir/patch-git.lua)` at parse time |

**Recommendation: build Rocky rpm 4.19.1.1 in stage0** (own derivation, not a
nixpkgs override). Apply the `%patchlist` in rpm.spec:128-179 order with `-p1`, and configure the same
way as rpm.spec `%build`:

```
cmake -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_SHAREDSTATEDIR:PATH=/var/lib \
      -DCMAKE_INSTALL_SYSCONFDIR=/etc -DCMAKE_INSTALL_LOCALSTATEDIR=/var \
      -DRPM_VENDOR=redhat -DWITH_SEQUOIA=ON -DENABLE_BDB_RO=ON \
      -DENABLE_TESTSUITE=OFF -DENABLE_PYTHON=OFF -DENABLE_PLUGINS=OFF \
      -DWITH_SELINUX=OFF -DWITH_DBUS=OFF -DWITH_AUDIT=OFF -DWITH_FAPOLICYD=OFF \
      -DWITH_IMAEVM=OFF -DWITH_FSVERITY=OFF
# install with DESTDIR=$out (installplatform then writes platform/<every arch_canon>-linux/macros)
```

* rpm's `findutil()` (rpm:CMakeLists.txt:55-73) searches `$MYPATH`, then
  `/usr/local/bin:/usr/bin:/bin:…`, and **falls back to `/usr/bin/<tool>`** when nothing is found. In
  the Nix sandbox none of these exist, so leaving `MYPATH` unset gives exactly the
  FHS paths Rocky has. You can also pass `-D__STRIP=/usr/bin/strip -D__OBJDUMP=/usr/bin/objdump …`
  explicitly. Set `-D__FIND_DEBUGINFO=/usr/bin/find-debuginfo`, because `find_program` would fail in the sandbox anyway.
* nixpkgs build deps: cmake, pkg-config, lua5_4, popt, zlib, bzip2, xz, zstd,
  libarchive, sqlite, file (libmagic), elfutils, libcap, acl, readline,
  gettext, rpm-sequoia, and gcc's libgomp (OpenMP). The binaries reference `/nix/store`,
  which is fine in stage0 (store visible). The rpmdb is created with
  `rpmdb --initdb --dbpath /usr/lib/sysimage/rpm`.
* Plus the `find-debuginfo.sh` symlink and the empty dirs `macros.d`, `lua` and `fileattrs`.

If nixpkgs rpm 4.20 is used anyway, the minimum overrides are: `RPM_CONFIGDIR=/usr/lib/rpm`
with `/usr/lib/rpm/vendor -> redhat`; a hand-made `platform/x86_64{,_v2,_v3,_v4}-linux/macros`;
redefinitions of `%_prefix %_exec_prefix %_libdir %_localstatedir %_host* %__strip %__objdump %__ar
%__as %__ld %__tar %__patch %__gzip %__xz %__zstd %__bzip2 %__cat %__cp %__mv %__rm %__ln %__mkdir
%__install %__chmod %__chown %__id %__file %__grep %__sed %__awk %__make`; `%_dbpath`;
`%_use_weak_usergroup_deps 1`; and accepting the `%patchN`/builddir differences. That is more fragile than building 4.19.

## 6. Dependency generators

Generators from **rpm itself** (rpm-build ships `/usr/lib/rpm/fileattrs/*`; Rocky's
rpm.spec deletes `perl*` and `python*` attrs, rpm.spec install "These live in
perl-generators and python-rpm-generators now"):

| attr | Generator | External tool | glibc relevance |
|---|---|---|---|
| elf.attr | `elfdeps --provides/--requires` (sonames, `name(VER)(64bit)`, `rtld(GNU_HASH)` when GNU hash and no SysV hash, rpm:tools/elfdeps.c:311) | libelf | **Key**: provides/requires of all glibc packages |
| script.attr | `script.req` (shebang interpreter) | sed | `/usr/bin/bash`, `/usr/bin/perl`, `/usr/bin/python3` (glibc-utils, glibc-benchtests) |
| pkgconfig.attr | `pkgconfigdeps.sh` | `/usr/bin/pkg-config` | glibc ships no `.pc` |
| debuginfo.attr | Lua (build-id provides) | — | debuginfo packages |
| rpm_macro.attr, rpm_lua.attr | `rpm_macros_provides.sh`, Lua | — | — |
| sysusers.attr, usergroup.attr | Lua | — | — |
| desktop, metainfo, font, ocaml | sh, fc-query, ocamlobjinfo | — | — |

Generators from **Rocky packages**:

| attr | Package (source) | Notes |
|---|---|---|
| libsymlink.attr | redhat-rpm-config | `lib*.so` dev symlinks get a soname Requires (rrc:libsymlink.attr), which matters for glibc-devel |
| python.attr, pythondist.attr, pythonname.attr | python3-rpm-generators (python-rpm-generators 14-12.el10) | Pulled in officially through python3-devel's `(python3-rpm-generators if rpm-build)`. `pythonname.attr` path is `^/` and does `require 'fedora.srpm.python'` (needs python-srpm-macros' `python.lua`). `pythondistdeps.py` needs python3 and python3-packaging. Adds nothing for glibc (no files in `/usr/lib*/python3.X`) |
| perl.attr, perllib.attr, perltest.attr, perlcompat.attr | perl-generators 1.16-7.el10 | Not in the glibc official buildroot. glibc-utils' `mtrace` only yields `/usr/bin/perl` through script.attr. Don't install it for glibc |
| kmod.attr | kernel-srpm-macros 1.0-27.el10 | `/lib/modules` only |
| kabi, modalias, provided_ksyms, required_ksyms | kernel-rpm-macros (same SRPM) | kernel only |
| glibc.attr (+ `/usr/lib/rpm/glibc.req`) | glibc-devel (built by us) | Only when `%glibc_autorequires`. The official glibc packages carry no `glibc >= …` generated deps |

Checked against the official glibc requires (repodata): `glibc-common` → `/usr/bin/bash, rtld(GNU_HASH)`;
`glibc-utils` → `/usr/bin/{bash,perl,sh}, libgd.so.3()(64bit), …, ld-linux-x86-64.so.2(GLIBC_PRIVATE)(64bit)`;
`glibc-benchtests` → `/usr/bin/python3, libm.so.6(GLIBC_2.39)(64bit)…`. All of these come
from elf.attr and script.attr. `%global __filter_GLIBC_PRIVATE 1` (glibc.spec:472) is a
**no-op** in rpm 4.19: the mechanism was removed (rpm ChangeLog "Remove support for
redundant %_filter_GLIBC_PRIVATE mechanism"), and the official package does carry `GLIBC_PRIVATE` requires.
`%__provides_exclude ^libc_malloc_debug\.so.*$` is honoured by rpm's rpmfc.

For glibc parity, stage0 needs rpm's fileattrs plus rrc's libsymlink.attr. Install
python3-rpm-generators only together with python-srpm-macros' Lua. Skip perl-generators.

## 7. Macro packages: redhat-rpm-config Requires on el10

From the binary repodata (`redhat-rpm-config-295-1.el10.rocky.0.2.noarch`, rrc spec:91-133):

| Requires | Provided by (binary) | Source RPM | Repo | Needed by stage0 glibc? |
|---|---|---|---|---|
| efi-srpm-macros | efi-srpm-macros-6-7.el10.rocky.0.1 | efi-rpm-macros-6-7.el10.rocky.0.1 | AppStream (src: BaseOS) | no |
| fonts-srpm-macros | fonts-srpm-macros-2.0.5-18.el10 | fonts-rpm-macros-2.0.5-18.el10 | AppStream | no |
| forge-srpm-macros | forge-srpm-macros-0.4.0-6.el10 | forge-srpm-macros-0.4.0-6.el10 | AppStream | no |
| go-srpm-macros | go-srpm-macros-3.8.0-1.el10 | go-rpm-macros-3.8.0-1.el10 | AppStream | no |
| kernel-srpm-macros >= 1.0-12 | kernel-srpm-macros-1.0-27.el10 | kernel-srpm-macros-1.0-27.el10 | AppStream | no (in lock) |
| lua-srpm-macros | lua-srpm-macros-1-15.el10 | lua-rpm-macros-1-15.el10 | AppStream | no |
| ocaml-srpm-macros | ocaml-srpm-macros-10-4.el10 | ocaml-srpm-macros-10-4.el10 | AppStream | no (in lock) |
| openblas-srpm-macros | openblas-srpm-macros-2-19.el10 | openblas-srpm-macros-2-19.el10 | AppStream | no (in lock) |
| perl-srpm-macros | perl-srpm-macros-1-57.el10 | perl-srpm-macros-1-57.el10 | AppStream | no (in lock) |
| python-srpm-macros >= 3.11-7 | python-srpm-macros-3.12-11.el10 | python-rpm-macros-3.12-11.el10 | AppStream | **yes** (`%__os_install_post_python`) |
| qt6-srpm-macros | qt6-srpm-macros-6.10.1-1.el10 | **qt6-6.10.1-1.el10** (the whole Qt 6) | AppStream | no |
| rust-srpm-macros | rust-toolset-srpm-macros-1.92.0-2.el10_2 (Provides rust-srpm-macros) | **rust-1.92.0-2.el10_2** (the whole Rust toolchain) | AppStream | no |
| package-notes-srpm-macros | package-notes-srpm-macros-0.5-13.el10 | package-notes-0.5-13.el10 | AppStream | defines `%_package_note_*`; unused by glibc (no `%set_build_flags`), needed for parity elsewhere. **Not in lock yet** |
| pyproject-srpm-macros | pyproject-srpm-macros-1.18.5-1.el10 | pyproject-rpm-macros-1.18.5-1.el10 | AppStream | no (in lock) |
| rpm >= 4.11.0 | rpm-4.19.1.1-23.el10 | rpm-4.19.1.1-23.el10 | BaseOS | yes |
| dwz >= 0.4 | dwz-0.16-1.el10 | dwz-0.16-1.el10 | AppStream | yes (tool) |
| zip | zip-3.0-45.el10 | zip-3.0-45.el10 | BaseOS | no |
| (annobin-plugin-gcc if gcc) | annobin-plugin-gcc-13.02-2.el10 | annobin-13.02-2.el10 | AppStream | disabled in stage0 |
| (gcc-plugin-annobin if gcc) | gcc-plugin-annobin-14.3.1-4.4.el10 | gcc-14.3.1-4.4.el10 | AppStream | disabled in stage0 |
| coreutils | coreutils-9.5-8.el10_2.1 | coreutils | BaseOS | tool |
| /usr/bin/{find,xargs} | findutils-4.10.0-5.el10 | findutils | BaseOS | tool |
| /usr/bin/file | file-5.45-9.el10 | file | BaseOS | tool |
| /usr/bin/grep | grep-3.11-10.el10 | grep | BaseOS | tool |
| /usr/bin/sed | sed-4.9-5.el10 | sed | BaseOS | tool |
| /bin/sh, /usr/bin/bash | bash-5.2.26-6.el10 | bash | BaseOS | tool |

Not required by rrc but needed for a correct el10 macro set: **rocky-release**
10.2-1.2.el10 (`macros.dist`: `%rhel 10`, `%el10 1`, `%distcore .el10`, `%dist`,
`%dist_vendor`…, rocky-release.spec:251-272; and `/etc/system-release-cpe` =
`cpe:/o:rocky:rocky:10::baseos`, which package-notes reads). Also python3-rpm-macros and
python-rpm-macros (same SRPM, pulled by python3-devel), and systemd-rpm-macros
(systemd-257-23.el10_2.x.rocky.0.1, BaseOS; for `%_unitdir`; not used by glibc).

rpm-build-4.19.1.1-23.el10 Requires (the tool layer stage0 has to provide at FHS paths):
bash, binutils (2.41-63.el10), bzip2, cpio, **debugedit >= 0.3** (5.1-8.el10),
diffutils, **elfutils >= 0.128** (0.194-2.el10.rocky.0.1), file, findutils,
gawk, grep, gzip, patch >= 2.5 (2.7.6-26.el10; nixpkgs 2.8), **pkgconfig**
(pkgconf-pkg-config 2.1.0-3.el10), sed, tar, unzip, xz, zstd,
**`/usr/bin/gdb-add-index`** (gdb-minimal 16.3-3.1.el10_2), system-rpm-config (rrc).

stage0 with `--nodeps` doesn't need the heavy ones (qt6 and rust sources). Stage1+ installs
the buildroot with real dependency checks, so it either needs those SRPMs built or a
documented `--nodeps` install of redhat-rpm-config. **This is a stage1 planning issue.**

## 8. Concrete stage0 settings for `rpmbuild --rebuild glibc…src.rpm`

Files in the stage0 FHS root:

```
/usr/lib/rpm/                 Rocky rpm 4.19.1.1 (macros, rpmrc, platform/*, fileattrs/*, brp-*, check-*, elfdeps, rpmdeps, …)
/usr/lib/rpm/redhat/          rrc: macros rpmrc brp-* config.* dist.sh find-* gpgverify redhat-hardened-* redhat-annobin-* redhat-package-notes
/usr/lib/rpm/macros.d/        rrc macros.* ; macros.dist (rocky-release) ; macros.python-srpm macros.python macros.python3 macros.pybytecompile ;
                              macros.package-notes-srpm ; (optional) macros.kernel-srpm macros.perl-srpm …
/usr/lib/rpm/fileattrs/       rpm's + rrc libsymlink.attr
/usr/lib/rpm/lua/fedora/      rrc common.lua ; srpm/python.lua (python-srpm-macros)
/usr/bin/{find-debuginfo,debugedit,sepdebugcrcfix,dwz,gdb-add-index,gdb,eu-strip,eu-elfclassify,readelf,objcopy,nm,strip,objdump,ar,as,ld,
          file,grep,sed,gawk,cpio,xz,zstd,gzip,bzip2,patch,tar,unzip,pkg-config,bash,sh,perl,python3,…}
/sbin/ldconfig, /etc/passwd (root, mockbuild), /etc/group, /etc/system-release-cpe
```

Command (mirrors mock):

```
rpmbuild --rebuild --nodeps --target x86_64 \
  --define '_topdir /builddir/build' \
  --define 'dist .el10_2' \
  --define '_annotated_build 0' --define '_annobin_gcc_plugin %{nil}' \
  --define 'use_source_date_epoch_as_buildtime 1' --define '_buildhost <fixed>' \
  [--define '_find_debuginfo_opts --no-ar-files'   # only if nixpkgs debugedit 5.2]
  glibc-2.39-142.el10_2.src.rpm
```

plus the gcc shim from section 2.5 (`--build-id`, `--hash-style=gnu`, FHS dynamic linker), and
`PATH=/usr/bin:/usr/sbin` only. Also `RPM_BUILD_NCPUS`/`%_smp_ncpus_max` from `NIX_BUILD_CORES`.

## 9. Open items and risks

* The build host CPU must support x86-64-v3: glibc's main build is `-march=x86-64-v3` and it
  runs freshly built programs (localedef, tests). The libraries are marked
  `x86 ISA needed: x86-64-v3`, so ld.so refuses to load them on older CPUs. Check the nixbuild.net
  machine types.
* glibc32 (`-m32`) needs a multilib stage0 gcc (nixpkgs gcc14 is `--disable-multilib`).
* `brp-ldconfig` under nixpkgs `ldconfig -N -r` in other packages: not yet verified
  (glibc disables this step).
* `.gdb_index` and minidebuginfo (xz) bytes will likely differ from Rocky. They are cosmetic.
* The `OPTFLAGS` header and `DW_AT_producer` differ while annobin is disabled.
* nixpkgs libmagic (file 5.47) vs Rocky (5.45) could classify edge-case files
  differently in rpmfc/brp scripts. The ELF and script regexes are robust.
