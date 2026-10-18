# Nix-native foundation: hand-off notes

Collected from the foundation work packages (branches nn/<id>, merged in c700802): interface notes, cross-package requests and open issues. The next work packages (WP6 mkRpmPackage/stage, WP7 glibc, WP8 kernel-headers, WP9 parity, WP10 attrs/docs, WP11 late-bind) must address or explicitly reject each request.


## cc (nn/cc)

### Summary
Both parts are done and pass. WP4: the S1 cc-wrapper is built and checks.nn-cc-toolchain passes (121 PASS, 0 FAIL). WP0a/E1: the relocated glibc built through the wrapper references only itself, and no input store path is left anywhere in it.

What exists (lib/rocky/cc/wrap.nix, exposed as nn.cc):
- `nn.cc.wrap { libc }` wraps copies of the stage0 gcc 14.3.1 and binutils 2.41 with nixpkgs wrapCCWith/wrapBintoolsWith. libc is { out, dev }: lib = dev, libdir /lib64/, incdir /include, dynamic linker out/lib64/ld-linux-x86-64.so.2, -m32 loader out/lib/ld-linux.so.2.
- `nn.cc.stage0Libc` is a relocated copy of the stage0 glibc plus Rocky's kernel-headers; `nn.cc.stage0 = nn.cc.wrap { libc = stage0Libc }`.
- The §5.1 overrides are in place:
  - empty cc-cflags-before, no default hardening flags;
  - --enable-new-dtags;
  - self rpath goes to $out/lib64 (lib64-rpath.sh, appended to the setup hook);
  - add-prefix-map.sh as the cc-wrapper-hook: -ffile-prefix-map=<root>=/usr for the gcc copy and every store include root, <root>/usr for trees laid out as usr/include inside a store path, and it drops -frandom-seed coming from the environment.
- Additions beyond the task:
  - m32-libc.sh: with -m32, crt files and libc.so now come from <libc>/lib. Without it, -m32 programs failed to link, because gcc never looks in ../lib for a -B dir by itself.
  - The gcc copy's libstdc++ and libquadmath get RUNPATH $ORIGIN so they find libgcc_s.
  - Extra names: x86_64-redhat-linux-gcc/g++/c++, plus links to the unwrapped gcc-ar/gcc-nm/gcc-ranlib/gcov.
  - Bug fixed: the output of a multi-output libc has outputSpecified = true, so getDev returned out; the adapter now sets it false.
- `nn.cc.storescan` (storescan.py) finds store paths in files, full and in pieces, and decodes compressed debug sections.
- `nn.cc.rpmConfig.{config,flags}` gives Rocky's %build_cflags/%build_ldflags as evaluated by the stage0 rpm, with annobin off.

checks.nn-cc-toolchain covers three setups:
- A, normal stdenv environment: C, C++, shared lib, -m32, -static and -flto programs build and run. PT_INTERP is the store loader, only DT_RUNPATH (no DT_RPATH), self rpath is $out/lib64. No store path in any DWARF, no -frandom-seed in DW_AT_producer, line tables say /usr/include and /usr/lib/gcc/x86_64-redhat-linux/14/include, and __FILE__ is mapped.
- B, wrapper called from PATH with an empty environment and Rocky's flags: gcc, cc, g++, c++, cpp, x86_64-redhat-linux-gcc, ar, gcc-ar, nm, as and ld all work. Output is PIE with BIND_NOW and RELRO, and the DWARF has no store paths.
- C, libc split into out/dev like the relocated glibc will be: same assertions.

E1 (`nn.cc.e1.glibc` / `nn.cc.e1.report`, results in E1.md):
- This is the spike glibc-reloc.nix built through nn.cc.stage0, with %_usrsrc set to /usr/src as the design says.
- Final store path /nix/store/n4y4826bjr22vq2c0yibdnbslmqqdivz-glibc-2.39-142.el10_2. `nix-store -q --references` lists only itself.
- storescan found 0 foreign full paths and 0 pieces of input hashes in 14,255 files. For comparison, the spike output had 727 hits in 727 files.
- ld.so's .debug_str and .debug_line_str are identical to the milestone-1 FHS build's, DW_AT_producer included, and no producer string has -frandom-seed.
- The hook shape from §5.1 needs no change.

### Interface notes
Using it:
- `nn.cc.wrap { libc = <multi-output glibc, or { out; dev; }>; name ? "rocky-s1"; }` returns a nixpkgs cc-wrapper derivation; its passthru has bintools, libc (the adapter) and cc (the gcc copy).
- `nn.cc.libcAdapter` is exported for WP7.
- `nn.cc.stage0Libc` is already adapted; `.out` and `.dev` are the same tree.
- The wrapper works from PATH with no NIX_* variables: everything it needs (libc and gcc flags, dynamic linker, prefix maps, the -m32 dirs) comes from its own nix-support files, so the tool shim only has to put $wrapper/bin on PATH or link it into the /usr/bin view.
- Setup-hook behaviour only applies inside a stdenv build: the self rpath $out/lib64 is added through NIX_LDFLAGS, and NIX_NO_SELF_RPATH / NIX_DONT_SET_RPATH have to be derivation attributes.

Behaviour later work packages should expect:
- With a split glibc, programs get RUNPATH $dev/lib64 (it holds the libc.so script but no .so.N) and gcc's lib/gcc/x86_64-redhat-linux/14 dir, because ld-wrapper adds every -L dir that contains a lib<x>.so. Neither is useful at runtime; Phase E's RUNPATH recompute should drop them. libc.so.6 is expected to come from the relocated loader's system dir <glibc>/lib64.
- The stage0 gcc has no no-sys-dirs patch yet, so /usr/local/include, /usr/include, /lib64 and /usr/lib64 stay in its default search. In the tool shim, /usr/include is the declared-input view and gcc searches it before the -idirafter libc include.
- With the stage0Libc loader, a program linked with --as-needed against libstdc++ cannot find libm.so.6 (the loader only searches the FHS dirs). This does not happen with a relocated glibc.
- The hook maps every store root named by -I/-iquote/-isystem/-idirafter, including the derivation's own outputs, not only inputs as the design text says. That gives Rocky-identical DWARF when headers are reached through the $out alias of the view.
- `nn.cc.rpmConfig.flags` holds Rocky's evaluated flags with -specs paths pointing at a store copy; WP2's rpmConfig should replace it.

### Requested changes elsewhere
- WP5 (rocky-partition, Phase E): drop the RUNPATH entries the ld-wrapper adds for -L dirs that hold only lib<x>.so scripts or links, e.g. $dev/lib64 and <gcc>/lib/gcc/x86_64-redhat-linux/14.
- WP6/WP3 (mkRpmPackage, tool shim): put nn.cc.wrap {libc}/bin first on PATH (or in the /usr/bin view). Set NIX_NO_SELF_RPATH / NIX_DONT_SET_RPATH as derivation attributes, not as exports. Consider strictDeps, so nixpkgs tool -dev include dirs stop reaching NIX_CFLAGS_COMPILE (E1 saw 30 of them).

### Open issues (implementer)
- No `nix build --rebuild` reproducibility check was run on the E1 glibc or on the wrapper.
- E1 used the spike recipe (rpm config copied from stage0, --with-headers substitution, nixpkgs tools in PATH whose -dev include dirs reach the build through the cc-wrapper setup hook), not mkRpmPackage or the declared-input view. With the prefix map, those undeclared headers would also show up as /usr/include in DWARF.
- Not done yet: the stage0 gcc copy without the no-sys-dirs patch (gcc¹, §5.2), and the libm lookup limit with the stage0Libc loader (documented in wrap.nix and in the check).
- Only stage0Libc and a split version of it were tested as libc. The wrapper has not been tried against WP7's real relocated glibc.

### Remaining after review/fix
- Interface: inside a stdenv build the wrapper's setup hook fills NIX_ROCKY_MAP_ROOTS from all inputs. WP6 (mkRpmPackage) must keep the declared inputs as stdenv deps (or add them to NIX_ROCKY_MAP_ROOTS) and let the variable pass through bwrap and rpmbuild (it is exported).
- The symlink-target walk skips writable roots. If the declared-input view is bind-mounted at $out (prefixView), headers reached through that farm are covered only because their targets are declared inputs in NIX_ROCKY_MAP_ROOTS, not by the walk.
- NIX_ENFORCE_PURITY is now forced off in both wrappers by default (enforcePurity = false). In mkShell use on a non-Rocky host, nixpkgs' /usr filtering no longer applies. The stage0 gcc has no no-sys-dirs patch anyway (§5.2).
- E1 still uses the spike recipe (stdenv tool inputs, hoisted farm), not mkRpmPackage and the declared-input view. The wrapper has not been tried against WP7's real relocated glibc.
- Carried over from the original report, not addressed here: RUNPATH entries for -L dirs that hold only scripts (Phase E), and the libm lookup limit of the stage0Libc loader.


## shim (nn/shim)

### Summary
WP3 (tool shim) and WP0b (E2) are done. The worktree started at 8b6e4a9, so it was first fast-forwarded to 3b7cc06; nn/shim = 3b7cc06 + 2 commits.

1. The tool shim: lib/rocky/tool-shim.sh, lib/rocky/mkview.py and lib/rocky/parts/toolShim.nix, exposed as `nn.toolShim` (call it as `${nn.toolShim} [--[no-]prefix-view] -- cmd...`).
   - Namespace: bwrap with its own tmpfs root; /nix, $NIX_BUILD_TOP (plus $TMPDIR and $PWD when they are outside it) bound; the sandbox's /etc, /proc and /dev; a fresh tmpfs /tmp; SIGPIPE reset to default (`env --default-signal=PIPE`, as in lib/chroot.sh).
   - /usr/bin holds symlinks to the PATH tools (first wins), sbin -> bin.
   - /usr/{include,lib,lib64,libexec,share} come from the inputs in `rockyViewInputs` (read from the environment or from $NIX_ATTRS_JSON_FILE). They are read-only overlayfs mounts of the inputs' directories (first input wins; a single input is a plain bind). Collisions are written to a report file.
   - /bin and /sbin -> usr/bin. /usr/lib/rpm = RPM_CONFIG_DIR, if set.
   - ROCKY_PREFIX_VIEW=1 mounts the same view read-only on a tmpfs over $out. $out must be empty before and is checked to be empty after.
   - My first version was a symlink farm. glibc's configure rejected it: it refuses a symlinked $prefix/include/scsi. That is why the input directories are now overlays.

2. `checks.nn-shim` passes in a real sandbox. It covers:
   - /usr/bin/rpmbuild --version (stage0 rpm 4.19.1.1), rpm reading its config from /usr/lib/rpm, and /bin/true, /sbin/true, /usr/sbin/true running.
   - Only declared inputs visible: an undeclared store path that is in the sandbox does not show up under /usr.
   - First wins plus the collision report; FHS-style store inputs (usr/ layout) are used.
   - Real directories and files under /usr, which is read-only.
   - The $out alias exists during the command and is gone after, $out is empty after, and a non-empty $out is refused.
   - With RPM_CONFIG_DIR unset, nothing is mounted at /usr/lib/rpm.
   - Exit status passes through.

3. E2 result: prefixView should default to true. Details are in docs/research/nix-native/experiments/E2.md.
   - glibc was built from the unmodified spec: `--with-headers=%{_prefix}/include` resolves through the alias, with no spec substitution.
   - Against the build without the view:
     - file lists are identical (17042 entries each);
     - 12582 files identical, 1414 differ only in build-ids, 16 only in the own store hash;
     - 8 files differ only in non-loaded DWARF sections, and nothing in code or data differs.
   - Those 8 DWARF differences are include-directory names that now point under $out, where no file exists. So the cc-wrapper must also map `-ffile-prefix-map=$out=/usr` while rpmbuild runs.
   - which, xz, gzip, sed, m4 and expat: all 12 builds succeeded, with and without the view, and the outputs are identical apart from build-ids.
   - A synthetic positive-control spec (lib/rocky/e2/probe) reaches a dependency only through %{_includedir}. The view makes it work, and the reference scan flags the leaked $out path in its debug info.
   - Control: the build without the view matches the earlier spike glibc build (nncpaslng...); every difference is DWARF and comes from the gcc random seed.

4. Side findings, which also went into requestedChangesElsewhere:
   - macros.d files are overridden by platform/x86_64-linux/macros (measured).
   - `rpmbuild --load` is dropped when `--target` re-reads the configuration.
   - config.site must end with exit status 0, or autoconf ≥ 2.70 refuses to load it.
   - Store RUNPATHs need QA_RPATHS=0x0002.
   - Specs call /sbin/ldconfig and gpgv2, so both must be on PATH.
   - nixpkgs libraries used with the stage0 libc pull in nixpkgs glibc's libdl/libpthread stubs, and the program then fails to start.

### Interface notes
nn.toolShim is an executable store path: `${nn.toolShim} [--no-prefix-view|--prefix-view] -- CMD...`.
Environment it reads:
- rockyViewInputs: declared input store paths, separated by whitespace or ':'. With __structuredAttrs, the list attribute `rockyViewInputs` is read from $NIX_ATTRS_JSON_FILE. An input with an FHS layout contributes <p>/usr/<dir>.
- RPM_CONFIG_DIR: optional, bound read-only at /usr/lib/rpm; it hides any lib/rpm the inputs provide, and that masking is reported.
- ROCKY_PREFIX_VIEW=1: needs $out to be missing or empty; afterwards $out exists and is empty.
- ROCKY_VIEW / ROCKY_VIEW_COLLISIONS: override the view directory (default $NIX_BUILD_TOP/rocky-view) and the collision report (default $NIX_BUILD_TOP/rocky-view-collisions.txt; tab-separated: kind, rel, winner, loser).
The environment, including PATH, is passed through unchanged; to record FHS interpreter paths, run `env PATH=/usr/bin ...` inside.
nn.toolShim.mk { runCommand bash bubblewrap coreutils python3 } rebuilds the shim over other tools for later stages.
nn.toolShim.mkview is the path of mkview.py; nn.toolShim.e2.* holds the experiment attributes (glibc, small SRPMs, probe, macroPrecedence, rpmConfig, ccw, reloc).

### Requested changes elsewhere
- WP4 (cc-wrapper / E1 hook): when prefixView is on, add -ffile-prefix-map=$out=/usr (and keep the per-input <input>=/usr maps) for the duration of rpmbuild. This is safe because the shim guarantees nothing but the view lives under $out then. Without it, glibc DWARF (including ld.so's retained DWARF) names $out/include/{linux,asm-generic,sys,selinux}, which no file backs.
- WP2 (rpm config): rpm 4.19 reads platform/x86_64-linux/macros after macros.d/, and the platform file redefines %_prefix %_exec_prefix %_bindir %_libdir %_includedir %_sysconfdir ... %__spec_install_pre %__os_install_post %__spec_install_post. So design §1.2's macros.d/macros.zz-nix-reloc would be silently overridden (measured: nn.toolShim.e2.macroPrecedence). Use redhat/macros (read after the platform file), /etc/rpm/macros.* or --define. Also `rpmbuild --load` is dropped when --target re-reads the configuration.
- WP2 (config.site, design §1.3): the script must end with exit status 0, e.g. a trailing ':'. autoconf >= 2.70 aborts with 'failed to load site script' when the last `test ... && x=...` did not match; seen with which.
- WP2/WP6: store RUNPATHs make redhat check-rpaths fail with 0x0002 'invalid'; set QA_RPATHS to include 0x0002. Design §5.5 says this is not needed, which is wrong. Specs and macros call /sbin/ldconfig (brp-ldconfig) and gpgv2 (%gpgverify), so both must be on PATH; the shim then provides /sbin/ldconfig.
- WP6 (mkRpmPackage): run rpmbuild as `${nn.toolShim} -- rpmbuild ...` with rockyViewInputs = all declared input outputs, RPM_CONFIG_DIR = the per-build config and ROCKY_PREFIX_VIEW = prefixView (default 1). The shim needs $out empty or absent before rpmbuild.
- WP5 (partitioner): report $out/<rel> references that exist in the view but not in the outputs as compiled-in view leaks; lib/rocky/e2/compare.py (scan_refs) is a working prototype. Note DWARF names directories and files separately, so a file-granular check is needed.
- Design doc §5.4: the view's include/lib/... are overlayfs mounts (real directories), not a symlink farm; §1.5 should say so (glibc's configure checks `test -L $prefix/include/{net,scsi}`).

### Open issues (implementer)
- Not done: a rebuild with E1's prefix map to confirm that -ffile-prefix-map=$out=/usr removes the 8 DWARF-only differences; partitioning the E2 outputs into per-subpackage outputs (WP5).
- E2 used stage0 gcc without no-sys-dirs, so gcc's built-in /usr/include and ld's /usr/lib64 search also saw the view (no effect measured). The S1 gcc changes this.
- Library inputs in E2 were nixpkgs stand-ins (readline, acl, libselinux, ...); acl and libselinux needed RUNPATH-patched copies to work with the stage0 libc.
- The reference scan works at directory granularity for DWARF: $out/include/sys (sdt.h) shows as 'backed' because glibc ships include/sys. The partitioner (WP5) cannot rely on existence checks alone for view leaks.
- Kept-failed build directories from debugging remain under /nix/var/nix/builds (owned by the daemon; not removed).

### Remaining after review/fix
- Not re-run: nn.toolShim.e2.macroPrecedence (finding 4). Its code is unchanged, but it uses the modified shim.
- Not verified: whether -ffile-prefix-map=$out=/usr (WP4) also removes the DWARF-only and krb5 LTO-suffix differences.
- requestedChangesElsewhere, WP6: enforce the library rule. Every declared view input that ships shared libraries must also be a cc-wrapper input. Optionally set ROCKY_PREFIX_VIEW_DIRS='include libexec share' for packages that need no lib dirs through %{_libdir}.
- requestedChangesElsewhere, WP5: add a NEEDED-resolution guard. Resolve every DT_NEEDED against RUNPATH/RPATH ($ORIGIN expanded) plus the loader's dirs, and fail on any unresolved soname. Prototype: scan_needed in lib/rocky/e2/compare.py.
- requestedChangesElsewhere, WP4/WP6: the self-RPATH must be the own %{_libdir} = $out/lib64 (after the partition, the owning output's lib64). The nixpkgs ld-wrapper adds $out/lib, which leaves xz, expat and krb5 binaries unable to find their own libraries outside the build. glibc's NIX_DONT_SET_RPATH=1 likewise leaves memusagestat and makedb without a RUNPATH for libgd/libpng/libz/libselinux.
- requestedChangesElsewhere, design/WP6: a %_prefix store name that contains %{name} breaks specs that rewrite paths by package name. Example: krb5's libsdocdir `sed s,krb5,krb5-libs,g` needs a per-package fix.
- Still standing from the first report: WP4 should map -ffile-prefix-map=$out=/usr while rpmbuild runs.
- Not investigated: one flaky failure of `%autosetup -S git_am` in krb5 ('invalid object … git write-tree failed'). The identical derivation passed on the next attempt.
- Kept-failed build directories from krb5 iterations and the krb5 --rebuild remain under /nix/var/nix/builds (owned by the daemon).


## partition (nn/partition)

### Summary
I implemented tools/rocky-partition, the in-build partitioner of design §2. It is a Python stdlib package: entry script tools/rocky-partition/rocky-partition plus the package tools/rocky-partition/rocky_partition/. It covers phases A–I:
- **A, B (canon, materialise):** canon mapping, including /etc and /var, debug paths, dropped build-id links and layout output paths. Files are moved or copied out of BUILDROOT. Ownership comes from the transient RPM headers, read with the plan's `rpm -qp --qf` using `:shescape` tokens; header-only RPMs work.
- **C (symlinks):** relative within an output, absolute across outputs.
- **D (scan and text):** full reference scan, nested/compressed scan reusing the decoders of rpm_purity.py, store-by-pieces scan, and Requires-gated text rewriting.
- **E (RUNPATH):** recomputed from DT_NEEDED and written with the plan's patchelf.
- **F (stubs):** Requires-gated forwarding stubs, created only if the output graph stays acyclic.
- **G (hidden references):** written to nix-support/hidden-references.
- **H (graph):** the output graph as Nix scans it, Tarjan SCC with merge suggestions, and the lateBind L* check.
- **I (metadata):** nix-support/rpm/<subpkg>.json, rpm-name, generated setup hooks, rocky-stubs, rocky-late.json, and the decision log rocky-report.json. Other outputs' paths are scrubbed from the report and metadata so they create no Nix edges.
- **Dev mode:** `--replay <tree> --remap OLD=NEW` remaps raw bytes, pieced windows, symlinks and re-encodes compressed members.

The plan.json v1 schema for WP6 is in tools/rocky-partition/PLAN.md: every key, defaults, patterns, error codes and remedies, and a structuredAttrs example. A `__structuredAttrs` attrs file with the plan under `rockyPlan` is accepted directly.

**Tests:**
- **checks.nn-partition-selftest:** 12 synthetic-tree cases, using real rpmbuild headers and compiled ELF fixtures. They cover the foo/foo-libs/-devel/-common split, a self-cycle, search paths, a text cycle, dangling/foreign/union references, pieced references, prefix-relative references, late binding, undeclared/missing/unclaimed files, replay, layout plus docs, and plan errors.
- **checks.nn-partition-replay:** the [NF-S3] glibc build tree, rebuilt with the tree kept through tools/rocky-partition/tests/{reloc-tree,trees,stage0-cc}.nix, replayed into the real 224 outputs (223 subpackage outputs, glibc32 merged into out, plus debug). Result: 0 errors, no cycles, nothing of the old prefix left, and Nix accepted the outputs.
- **File lists vs the old [NF-S5] split:** identical except the build-id links the design drops and the /etc and /var files that S5 lacked.
- **Overrides:** glibc needs §11.5 plus 6 explained entries, in tools/rocky-partition/tests/glibc-overrides.nix.

**E3** (docs/research/nix-native/experiments/E3.md): I built relocated trees of xz, expat, libxcrypt, ncurses and krb5 with the spike recipe, using nixpkgs cc and nixpkgs build dependencies.
- RUNPATH recompute removed every foo/foo-libs override.
- xz, expat and libxcrypt need no override at all.
- ncurses had 325 errors and needs 3 entries; the key one is choosing ncurses-base as the prefix subpackage, with no merge.
- krb5 had 1476 errors, almost all from the unshipped krb5-tests copy of the build tree. It needs 4 entries, one of them `mergeOutputs [krb5-libs libkadm5 krb5-server]`, because kadmind runs `$out/sbin/kdb5_util`.
- No gated stub was needed in any SRPM, glibc included.

Eleven rule changes (R1–R11) came from these measurements and are all implemented: pieced windows need 6 hash bytes; -devel lib/include references are rewritten to the -devel output itself; unused pkg-config prefix variables are acked; ld.so `$LIB` tokens are part of a path; standard top-level dirs filled by several outputs count as prefix-relative; debug build-id links are followed; debug is outside L*; references in documentation are never errors; `#!/bin/sh` and `#!/usr/bin/env` are runtime FHS; prefixRelativeOk is broadened; layout header paths are mapped.

Making the trees also exposed several build hazards; they are listed for WP2/WP6.

### Interface notes
Invocation: `python3 -I ${self.partitionTool}/rocky-partition --plan "$NIX_ATTRS_JSON_FILE"`. The task's `python3 -I -m rocky_partition` with PYTHONPATH cannot work, because -I ignores PYTHONPATH and the cwd (I checked this). The entry script puts its own directory on sys.path; `PYTHONPATH=tools/rocky-partition python3 -m rocky_partition` still works without -I for development.

self.partitionTool is a plain source store path (lib.fileset.toSource of rocky-partition + rocky_partition/, no derivation), so it is an allowed build input in every stage. self.partitionTool.trees.{glibc,e3.*} are the test build trees.

Plan: with `__structuredAttrs = true`, set `rockyPlan = { ... }`; output paths are read from the attrs file's `outputs`. Required keys: subpackages (non-debug rpm name -> output, after merges; debuginfo goes to debugOutput automatically), buildroot (kept with --noclean), rpmsDir (header-only RPMs are enough), rpm (+ rpmConfigDir for the FHS stage0 rpm), and patchelf (needed only if a RUNPATH changes). P must equal outputs[prefixOutput]. Set unmanagedOutputs = ["logs"]. requires is optional (computed from the headers with the unique-provider rule if absent). `@out@` substitution works in systemLibDirs, inputLibDirs and allowedStorePaths.

Run it before fixupPhase, with strip, patchELF, moveLib64, moveSbin, moveDocs and gzipMan off. Exit codes: 0 ok, 1 errors (report in $out/nix-support/rocky-report.json, findings on stderr), 2 plan/tool error.

New plan key not in design §8.1: prefixRelativeOk. Full schema and error codes are in tools/rocky-partition/PLAN.md; the glibc entries are in tools/rocky-partition/tests/glibc-overrides.nix.

### Requested changes elsewhere
- WP2 (lib/rocky/config.site, design §1.3): the script must end with `true`. autoconf >= 2.70 aborts with 'failed to load site script' when its last `test ... && ...` is false; seen on xz, expat, libxcrypt and krb5.
- WP2 (rpm macros, design §5.5 is wrong here): brp check-rpaths flags every absolute RUNPATH outside /usr/lib* and /lib* as 'invalid' (0x0002) and fails the build. That includes every store path and the Rocky toolchain's own self-rpath. Set QA_RPATHS=0x0002 (or %__brp_check_rpaths %{nil}).
- WP2 (fold-usr / check-files): specs that delete every non-directory of the buildroot (libxcrypt `find %{buildroot} -not -type d -delete`) also delete the BUILDROOT/usr fold link, and libxcrypt redefines __spec_install_post, so a fold hook there never runs. check-files must also map a real BUILDROOT/usr to the prefix; rocky-partition already reads both forms.
- WP2/WP6 spec hazard: krb5's `%(echo %{_pkgdocdir} | sed s,krb5,krb5-libs,g)` also rewrites the prefix's store name. The spec-hazards lint should flag sed edits of macro-expanded paths that use the package name.
- WP6 (mkRpmPackage, overrides.nix §8.1): add the `prefixRelativeOk` key (output pattern list; acks prefix-relative, union and dangling references of matching files) and pass the plan keys documented in tools/rocky-partition/PLAN.md. Invoke `python3 -I ${partitionTool}/rocky-partition --plan $NIX_ATTRS_JSON_FILE`, not `-m`. Keep BUILDROOT (--noclean) and RPMS; headers alone are enough.
- WP1 (prefix rule §3.1): for ncurses the eponymous rule gives 325 errors; prefixSubpackage = ncurses-base (it owns the terminfo/tabset data that libtinfo compiles in and references nothing) gives 0 with 2 more entries. Consider preferring such a data subpackage, or record the override in packages/ncurses.
- WP7 (packages/glibc overrides): add to the §11.5 entries, each explained in tools/rocky-partition/tests/glibc-overrides.nix: danglingOk libx32 and lib/gconv; prefixRelativeOk + opaqueRefs for benchtests and sysroot_x86_64_el10_glibc; opaqueRefs common:bin/locale and common:bin/localedef.
- WP0d/E4: in the relocated glibc, store-by-pieces references in loaded sections are only in ld.so, ldconfig, locale, localedef and the sysroot's ld.so. The non-prefix ones are common:bin/locale, common:bin/localedef and sysroot.
- Design doc owner (docs/nix-native-design.md §2.5/§2.8): add rules R1–R11 from E3.md, especially R2 (-devel lib/include text rewritten to the -devel output itself despite decision #7), R5 ($LIB tokens) and the documentation rule.

### Open issues (implementer)
- No behaviour test of partitioned outputs: the glibc replay and E3 outputs were checked structurally and by Nix (no cycles), but no program from them was run.
- checks.nn-partition-replay builds its own copy of the glibc [NF-S3] tree (~20 min, big-parallel), and its outputs keep the S3 spike's leaked inputs: out references glibc-build-deps-hoisted, rocky-stage0-gcc-shim and rpm-kernel-headers (the E1 DWARF issue; allowedStorePaths is left null, so these are only reported). Because hydraJobs includes all checks, CI will build this tree.
- References to layout prefixes ($X/... where X is not the prefix output) are not classified; only P references are. The krb5 `layout._sbindir` remedy was not tried on a real tree.
- lateBind/lateReferrers handling is verified only for the partition-side L* check; the bind derivation (WP11) does not exist yet. In the glibc replay, lateReferrers.common minimal_langpack matched nothing, and only some langpacks reference common.
- E3 trees were built with nixpkgs cc and nixpkgs libraries, not the Rocky toolchain, so their RUNPATHs name nixpkgs paths (kept as inputs). Toolchain workarounds (gcc14, a fips.h shim, compile_et, gpg names) are documented in E3.md.
- The tool dies with BrokenPipe if its stderr is closed early (seen only when piped through `head`; not an issue in a Nix build).

### Remaining after review/fix
- No behaviour test of the partitioned outputs. The libxcrypt FIPS self-check was confirmed by recomputing the HMAC, not by running the library in FIPS mode.
- FIPS embedded-HMAC detection (.rodata1, .note.fdo.integrity) and the gnutls INI .hmac form are based on reading the Rocky 10.2 specs. No openssl, libgcrypt, gnutls or nettle tree was built, so integrity-runpath is exercised only by the selftest.
- Only one meson SRPM (pixman) and no cmake SRPM were measured. cmake config files (lib64/cmake/*, which use ${_IMPORT_PREFIX}) were not examined.
- Branch nn/partition-fix was also set to the same commit as nn/partition.
- Request for the WP2/WP6 spec-hazards lint, from reading the spec (not built): gnutls %install strips paths in its .hmac with sed s^$RPM_BUILD_ROOT/usr^^, which matches nothing in a relocated build, so the BUILDROOT path stays in the file.
- Request for WP6 (mkRpmPackage): pass the new plan key integrityOk alongside noPatchelf; both are documented in tools/rocky-partition/PLAN.md.
- Request for WP7 (packages/glibc overrides): add danglingOk lib/libmemusage.so; the explanation is in tools/rocky-partition/tests/glibc-overrides.nix.


## glibc (nn/glibc)

### Summary
WP0d is complete and committed on nn/glibc in two commits on top of 3b7cc06. The worktree started at 8b6e4a9, so I fast-forwarded it to 3b7cc06 first.

1. **Nix patches.** packages/glibc/nix-patches/{ld-so-cache,locale-archive,ld-preload}.patch are nixpkgs' (26f4107e) dont-use-system-ld-so-cache, nix-locale-archive and dont-use-system-ld-so-preload patches, rebased onto Rocky glibc-2.39-142.el10_2 after its %prep. The changes are the same as nixpkgs; the context is now exact, so they apply with --fuzz=0. The originals applied only with fuzz 2 and offsets up to 875 lines.
   - P1 builds the cache and conf paths from PREFIX ($prefix/etc/ld.so.cache and ld.so.conf), not SYSCONFDIR.
   - P2 reads the LOCALE_ARCHIVE_2_27 and LOCALE_ARCHIVE env vars. It keeps nixpkgs' two host fallbacks (/run/current-system/sw/... and /usr/lib/locale/locale-archive); this is documented in the patch header.
   - P3 renames the preload file to /etc/ld-nix.so.preload.
   - packages/glibc/prep.nix runs `rpmbuild -rp` in stage0.buildrootFull, then each patch with --dry-run --fuzz=0, then all of them in order, then greps for their effects. checks.nn-glibc-prep (lib/rocky/checks/glibc-prep.nix) takes the patch list from default.nix's nixPatches.
   - With keepTree = true, prep.nix also outputs the unpatched tree, which is how the patches were rebased.
2. **glibc.site and overrides.** packages/glibc/glibc.site sets libc_cv_slibdir, rtlddir, complocaledir and rootsbindir below the store prefix; it falls back to computing el_nixos_lib itself if the generic config.site has not set it. packages/glibc/default.nix is the overrides draft using the §8.1 field names in §11.5 form. Additions beyond the design draft:
   - opaqueRefs from E4.
   - lateReferrers taken from packages/glibc/late-referrers.nix, which is generated.
   - lateBind.benchtests plus a python3 entry in fhsAllowlist, because the benchtests scripts have #!/usr/bin/python3 shebangs.
3. **E4 (experiments/E4.md).** The S5 split (223 outputs, glibc32 merged into out) and S3 were still in the store, so nothing was rebuilt.
   - fragscan.py gives only false positives on split outputs: it matches `/nix/store/` and `-glibc-2.39-142.el10_2` windows in ordinary full `$out` references. I wrote a hash-based scanner instead; it is embedded in E4.md.
   - Every split-hash window (1113 in S5, 2199 in S3) is inside `-frandom-seed=nncpaslng9` in .debug_str. There are none in loaded sections.
   - The real store-by-pieces cases are 7 truncated copies of the prefix (`/nix/store/<full hash>-glibc-2.39-142.el10_`, with the rest built in code). S5 and S3 have the same 7. The hash is whole, so Nix sees the edge; only the path behind it is opaque.
   - opaqueRefs (outputs other than out): common/bin/locale (→ lib/locale), common/bin/localedef (→ share/i18n), static/lib64/libc.a (dl-load.o), and the sysroot's ld-linux-x86-64.so.2 and libc.a (→ lib64/).
   - lateReferrers come from Nix's registered references: common ← 138 of the 206 langpack_* outputs (LC_CTYPE symlinks to C.utf8); nss_db ← nss_devel; utils and benchtests ← nothing. The reference graph has no cycles.
4. **E5 (experiments/E5.md).** Passing `env 'user-defined-trusted-dirs=…' rpmbuild -bc` on the unmodified spec in the stage0 glibc buildroot gives both the 64-bit and 32-bit ld.so the libgccForGlibc lib64 and lib dirs as system dirs. A second -bc, relocated (store %_prefix, glibc.site, the three patches applied after %prep, trusted dirs from env), confirms in the built loaders:
   - the glibc.site layout;
   - the cache at $P/etc/ld.so.cache (`ldconfig -p` opens it there);
   - /etc/ld-nix.so.preload;
   - LOCALE_ARCHIVE_2_27 compiled into libc.so;
   - system dirs = own lib dir + $L/lib64 + $L/lib.

   One problem for WP6: with `__structuredAttrs`, stdenv's setup.sh exports `env` entries with `declare -x` and aborts on the hyphenated name. A make-level unit test shows env and srcdir configparms both work, and configparms overrides env.
5. **libgccForGlibc.** bootstrap/nn/libgcc-for-glibc.nix, exposed as nn.libgccForGlibc via lib/rocky/parts/libgccForGlibc.nix, copies the stage0 gcc's libgcc_s.so.1 (64-bit to lib64, 32-bit to lib). It runs `patchelf --remove-rpath` (a no-op here: there is no RPATH and the bytes stay identical) and sets allowedReferences = [ ]. checks.nn-libgcc-for-glibc confirms its closure is only itself, with no store-path strings, no RPATH/RUNPATH, SONAME libgcc_s.so.1, and ELF64/ELF32 in the right dirs.

### Interface notes
nn.libgccForGlibc is a derivation with lib64/libgcc_s.so.1 and lib/libgcc_s.so.1 and passthru { rockyStage = "s0"; src }. bootstrap/nn/libgcc-for-glibc.nix takes { bootPkgs, src, lib64 ? "usr/lib64", lib32 ? "usr/lib", version, stage ? "s0" }; for S3, pass gcc¹'s libgcc output with lib64 = "lib64" and lib32 = "lib". packages/glibc/default.nix is `{ lib, stage, rocky }: attrs` and expects stage.name, stage.pkgs.kernel-headers, stage.glibcBuildDeps and stage.libgccForGlibc. Its opaqueRefs use a draft format: a list of "<output>/<rel>" strings with output names after merges (sysroot = sysroot_x86_64_el10_glibc). lateReferrers is { <late output> = [ sibling outputs ]; } with explicit names, no globs. packages/glibc/prep.nix takes { bootPkgs, lib, stage0, patches, keepTree ? false }.

### Requested changes elsewhere
- WP6 (lib/rocky/mk-rpm-package.nix / overrides.nix): override `env` keys that are not shell identifiers (e.g. user-defined-trusted-dirs) must not be copied into the derivation's structured `env`; pass them as `env 'NAME=VALUE' rpmbuild ...` (e.g. from a separate structured attr read as a bash associative array). Evidence: E5 part 2.
- WP5 (rocky-partition Phase G): detect pieced refs by hash: (a) a full $out hash not followed by the complete store name = truncated copy, needs an ack outside out; (b) 8-byte windows of the hash outside full hashes = split hash, needs hidden-references plus an ack. Scan static archive members too (libc.a dl-load.o). Path-window detection gives false positives on every normal $out reference. Evidence: E4.
- WP4: keep the reproducible-builds random-seed hook off; it is the only source of split hashes (-frandom-seed=<10 hash chars> in .debug_str).

### Open issues (implementer)
- WP6 has to add the rpmbuild command-line route for env names that are not shell identifiers (`user-defined-trusted-dirs`); until then, building default.nix as a __structuredAttrs derivation env fails at setup.sh. The configparms route via prepScript is a verified alternative if WP6 prefers it.
- The opaqueRefs entry format ("output/rel" strings) is my draft; WP5/WP6 still have to fix the schema.
- P2 keeps nixpkgs' host fallbacks (/run/current-system/sw/lib/locale/locale-archive, /usr/lib/locale/locale-archive). Dropping them would be a deliberate deviation from nixpkgs; I left it as a decision for later.
- Not run: P2 locale-archive behaviour at runtime and a pthread_cancel test with libgccForGlibc in a /usr-free sandbox (WP9 runtime check). E5 shows only the compiled-in system dirs and strings.
- E4 covers the S5 split, which was built with the reproducible-builds random-seed hook and has no debug output; S3's lib/debug was scanned as a proxy for the debug output. It should be rescanned once the real WP7 build exists.

### Remaining after review/fix
- WP6 (lib/rocky/mk-rpm-package.nix, overrides.nix): override `env` keys that are not shell identifiers (user-defined-trusted-dirs) must be passed as `env 'k=v' rpmbuild` and kept out of the structured derivation env, and overrides.nix should assert that at eval time. Otherwise glibc should switch to the configparms prepScript fallback documented in packages/glibc/default.nix. These are not my files, so this stays a request.
- WP6/WP11: confirm that lateBind exempts the raw late outputs' unresolved NEEDED (§2.6 step 4) and their FHS shebangs in S3, and decide what S3a's stage.glibcBuildDeps provides. If lateBind does not exempt them, the S1-only allowUnresolvedNeeded and fhsAllowlist conditions in default.nix must also cover S3.
- Still open from the original report: the opaqueRefs format is a draft (WP5/WP6 to settle); the P2 host locale-archive fallbacks are a decision left for later; the P2 runtime behaviour and a pthread_cancel test with libgccForGlibc were not run (WP9); E4 should be rescanned on the real WP7 build.
- Not re-run here: the E5 rpmbuild -bc builds themselves. Their drvs are unchanged and their outputs were already in the store, so only instantiation was checked.


## lock (nn/lock)

### Summary
WP1 is done. All three lock files exist for every one of the 2217 SRPMs, and checks.nn-order passes.

subpackages.json: there is one small derivation per SRPM, nn.lockgen.subpackages.<srpm>, in lib/rocky/parts/lockgen.nix with helper scripts in lib/rocky/lockgen/. Each runs `rpmspec -q` with --srpm, --builtrpms and --rpms (target x86_64) on the exact locked SRPM. It runs as mockbuild inside stage0-full (stage0 rpm 4.19.1.1, redhat-rpm-config, the *-srpm-macros and rocky-release), plus the *-rpm-macros packages the same stage0 macro builds produce. The output is a JSON file; rpmspec failures are recorded in it rather than failing the build. tools/lock_subpackages.py does one `nix eval` of nn.lockgen.paths and one `nix build --stdin --keep-going --cores 6 --max-jobs 2`, then folds the results into the lock. Because each result is an ordinary cached derivation, reruns are incremental. Options: --seed, --all, --stale, names, --no-build. The collector also derives three things from the official filelists.xml and rpms.json bySrpm: the prefix (eponymous > -libs > most /usr files > first), a shipped flag per name, and the lists shippedMissing and notBuilt. Debug names are excluded from `names` and listed under `debug`.
- Full run: 2217/2217 ok, 0 rpmspec failures, 0 build failures, in about 50 minutes.
- Totals: 7805 subpackages, 6707 shipped, 1098 unshipped. glibc has 224 subpackages with 3 unshipped, as the design says; krb5 gets prefix krb5-libs.
- Prefix rule counts: eponymous 1960, most-/usr-files 252, -libs 4, first 1.
- 200 of the 6907 official binary RPMs are not produced by the x86_64 spec parse. Causes: langpacks 149, javadoc/java variants 44, noarch packages built on other arches' builders 6, gcc-toolset 1.
- A rerun with --no-build gives a byte-identical file.

Two bugs found and fixed during the run (the first ~480 results were thrown away and the run restarted):
1. `%forgemeta -v` prints to stdout, which corrupted the first result line. Result lines now carry a LOCKGEN marker.
2. `--define dist` drops the .git<commit> prefix that %forgemeta adds. ksc parsed as 1.12-7.el10 instead of the locked 1.12-7.git869a25c.el10. The query now defines %distcore instead, and every release matches the lock.

builddeps.json (tools/lock_builddeps.py): the direct providers of each BuildRequire, using the resolver from resolve-buildrequires.py in the mock model. Conditionals whose condition is false ask for nothing. 222 SRPMs have BuildRequires nothing in the three repos provides (gi-docgen, python3-dbusmock, …); these are listed per SRPM. Providers are tagged tool, lib, macro or other from the official filelists (helper tools/lock_filelists.py, matched by pkgid). The BR-only model gave the same inputs for all 2217 SRPMs.

order.json (tools/lock_order.py): build graph with edge classes (doc/test/lang/lib/macro/tool), iterative Tarjan, a deterministic Eades feedback-arc set inside each cycle, a dependencies-first index and levels, bootTargets, secondPass and selfLoops. It reproduces the spike's 18721 edges, the 926-SRPM cycle and the 33 self-loops. Back edges: 773 (spike 771). Second pass: 152 (exactly the spike's 144 when only name patterns decide `lib`).

checks.nn-order (lib/rocky/checks/order.nix) recomputes the graph from builddeps.json and checks the order independently: the graph minus back edges is acyclic, every back edge's target is listed, and every SRPM with a library back edge is in secondPass. Six tampered copies were each rejected.

update-lock.py now writes builddeps.json and order.json after the repodata refresh and refreshes subpackages.json (flags --no-derived and --derived-only). It has a generic get_repodata(kind), and its --self-test also runs the new helpers' self-tests. rpmvercmp is unchanged.

Commands, numbers and findings are in docs/research/nix-native/experiments/lock.md.

### Interface notes
readLock "subpackages.json" gives .srpms.<srpm> with these fields:
- evr
- names: spec order, debug packages excluded
- debug: debuginfo/debugsource names
- noarch
- shipped: { name = bool }
- prefix
- prefixRule
- optional: usrFiles, notBuilt, notBuiltUnknown, shippedMissing, exclusiveArch, excludeArch

The file also has `failed` and `coverage` at top level (failed is currently empty). An exclusiveArch value starting with '%' (e.g. '%{rust_arches}') means unknown.

readLock "builddeps.json" gives:
- .srpms.<srpm> = { buildRequires = { "<BR>" = [rpm names]; }; inputs = [rpm names]; unresolved? }
- .providers.<rpm> = { srpm; arch; tags = subset of [lib macro tool], or [other]; }

readLock "order.json" gives:
- .srpms.<srpm> = { index; level; needs = { <srpm> = [classes]; }; back = [srpms]; scc?; }
- top level: sccs, bootTargets, secondPass, selfLoops, stats

nn.lockgen exposes subpackages.<srpm> (drv), paths, seed and buildroot.

Regeneration: `python3 -I tools/update-lock.py [--derived-only]`, then `python3 -I tools/lock_subpackages.py --stale` (requires nix, run from the repo root).

### Requested changes elsewhere
- lib/default.nix buildSrpm, and any future rpmbuild call (WP6 mkRpmPackage, WP2 rpm config): set the release with `--define 'distcore <dist>'` (or %distcore in the macro file), not `--define 'dist <dist>'`. rocky-release's macros.dist builds %dist from %{?distprefix…}%{distcore}; overriding %dist drops the .git<commit> prefix that %forgemeta adds, so forge-based SRPMs get the wrong Release (ksc: 1.12-7.el10 instead of 1.12-7.git869a25c.el10). Design §1.2's `%dist .el10_2` in macros.nix-reloc has the same problem.
- flake.nix: add an app for tools/lock_subpackages.py, like update-lock (pyApp "lock_subpackages"). It needs nix on PATH and must run from the repo root.
- Optional: hydraJobs could include nn.lockgen.subpackages so build-jobs.sh can warm them.

### Open issues (implementer)
- The lockgen buildroot has only stage0's macro set: no javapackages-tools, rust-srpm-macros, perl/cmake/meson macros. That causes all 200 shippedMissing names and the 10 unexpanded %{rust_arches} ExclusiveArch values. Only default bconds are used; the per-package bcond overrides of design §8.1 are not modelled.
- The /usr-files prefix rule is mechanical and sometimes picks an odd subpackage: antlr -> antlr-javadoc, cmocka -> libcmocka-devel. Those packages need a prefixSubpackage override when they are packaged.
- order.json is purely graph-driven: the feedback-arc set places gcc at level 3, so 29 of gcc's needs become back edges. The stdenv set is not pinned to an earlier stage yet.
- 222 SRPMs have BuildRequires nothing in BaseOS/AppStream/CRB provides (build-only packages Rocky does not publish). They are listed per SRPM, not resolved.
- Not run: a full update-lock.py run with a fresh repodata download. Only --derived-only and the filelists download path were exercised.

### Remaining after review/fix
- 190 BuildRequire occurrences (119 distinct, 154 SRPMs) remain unresolved. They are build-only packages outside the lock, or virtual provides (pkgconfig(...), files) of unshipped subpackages, which cannot be known without building them. Unshipped providers are matched by name plus the SRPM's EVR only.
- The lockgen buildroot still lacks javapackages, perl, cmake and meson macros, so 200 shippedMissing names remain. Only default bconds are used.
- Prefix picks among several libraries are still mechanical (ding-libs -> libpath_utils, wayland -> libwayland-client) and may need prefixSubpackage overrides.
- After lock_subpackages.py changes subpackages.json, run update-lock.py --derived-only to refresh builddeps/order. The tool prints this reminder; it does not regenerate them automatically.
- Still requested elsewhere, as before: use %distcore instead of %dist in buildSrpm and future rpmbuild calls, and add a flake app for lock_subpackages.py.


## rpmconfig (nn/rpmconfig)

### Summary
WP2 is done and committed on nn/rpmconfig. The worktree started at 8b6e4a9, so I reset it to the assigned base 3b7cc06 before starting. checks.nn-rpm-config builds green on the committed tree: 126 assertions passed, 0 failed (result /nix/store/mv09rj2rf6nzpji21abla98m2iyrb7d6-nn-rpm-config).

What was added:
- lib/rocky/rpm/macros.nix-reloc: the relocation macro template with @PREFIX@ @BUILDTOP@ @NCPUS@ @DIST@. I checked every decision against the actual stage0 macro files (rpm 4.19.1.1 macros/platform/redhat, redhat-rpm-config, 13 *-srpm-macros, rocky-release macros.dist). The deviations from the design are listed at the top of the file.
- lib/rocky/rpm/nix-scripts/:
  - fold-usr BR P: makes BR/usr a relative link to the prefix; a real BR/usr is merged in first; a conflict, a wrong usr link or a non-absolute prefix is an error; idempotent; P=/usr does nothing.
  - check-files BR P: rpm's check-files with BR/usr/x treated as BR/P/x on both sides.
  - prep-hooks DIR: applies $NIX_PREP_PATCHES with patch -p1 --forward, then runs the file $NIX_PREP_SCRIPT with bash -e.
  - instantiate: the per-build helper (described under interfaceNotes).
- lib/rocky/rpm/config.nix, exposed as nn.rpmConfig through lib/rocky/parts/rpmConfig.nix. It is a buildable derivation that is also callable as rpmConfig { rpm ? stage0.rpm, macroPkgs ? [ ], extraMacroDirs ? [ ], baseMacroPkgs ? stage0's redhat-rpm-config + 13 srpm-macros + rocky-release }. It copies rpm's lib/rpm (FHS usr/lib/rpm or relocated lib/rpm), every macro package's lib/rpm, the extra macro dirs (into macros.d) and nix/. Two sources giving the same file with different contents is an error, and text files must contain no /nix/store.
- lib/rocky/config.site per §1.3: picks lib or lib64 from the host and exports $el_nixos_lib.
- lib/rocky/checks/rpm-config.nix and lib/rocky/rpm/tests/.

Design errors I found and fixed:
1. The macro file cannot go in macros.d. rpm reads platform/x86_64-linux/macros and redhat/macros after macros.d, and they set %_prefix back to /usr, %__brp_compress back to no-prefix and %_binary_payload back to w19.zstdio. The check includes this as a negative control. Instead, instantiate appends the substituted file to the config's redhat/macros, the last macro file inside the config dir.
2. %__spec_prep_post ran prep-hooks after %{___build_post}, which ends in `exit ${RPM_EC}`, so they never ran. They now run before it.
3. %__spec_install_pre had dropped redhat's %{?_auto_set_build_flags:%{set_build_flags}}. It is kept.
4. A fixed `%dist .el10_2` is wrong for 1906 of 2217 SRPMs, which are .el10. The file now sets %distcore per build from distOf, which keeps %distprefix/%distsuffix/~bootstrap working; an empty --dist leaves .el10.
5. %_rpmconfigdir is no longer redefined. It stays %{getconfdir}, so rpm still works from a store config via RPM_CONFIGDIR.
6. %_dbpath is pinned to /usr/lib/sysimage/rpm. Otherwise it follows %_usr into $out.
7. `%_annotated_build 0` is dropped. redhat-rpm-config only tests whether it is defined, so 0 changed nothing. Emptying %_annobin_gcc_plugin, as stage0 does, is kept.

The check runs in a plain bwrap shim (/usr/bin = stage0 rpm, nixpkgs bootstrap tools and stage0's static ldconfig; /usr/lib/rpm = the instantiated config). It covers:
- rpm --eval of 59 macros against exact values, including _libdir, _sysconfdir=/etc, __perl, _rpmconfigdir, dist .el10_2/.el10/~bootstrap, _dbpath, the systemd dirs via a stand-in macro file, and a relocated macro package.
- The multi-line hooks, %optflags (non-empty, -O2, hardened specs, x86-64-v3, no annobin), %build_ldflags and %configure.
- The macro path order and the macros.d negative control.
- A full macro audit: 613 macros, 117 change, none newly pointing into /usr apart from tool and rpm paths.
- Unit tests for fold-usr (plain, rm -rf'd buildroot with a real usr, conflict, foreign link, /usr), check-files, prep-hooks, instantiate and config.site.
- rpmbuild -bb of nntest.spec and nntest-rmrf.spec with %_prefix=/nix/store/000…0-nn-rpm-config-test-1.0. Both build, the RPM file lists contain $P/bin, $P/lib64 and $P/share paths, /etc stays FHS, the rm -rf case logs its merge, and nothing is reported unpackaged.

Results and details are in docs/research/nix-native/experiments/rpmconfig.md.

### Interface notes
Per build (WP6 mkRpmPackage):
  sh ${rpmConfig}/nix/instantiate $NIX_BUILD_TOP/rpmconfig --prefix $out --buildtop $NIX_BUILD_TOP --ncpus $NIX_BUILD_CORES [--dist <distOf srpm>] [--macro-dir DIR]...
This creates a writable copy of the config, copies $NIX_RPM_MACRO_DIRS (colon/space separated macros.d dirs) and --macro-dir into macros.d (a differing file of the same name is an error), substitutes the placeholders, appends the result to redhat/macros, and creates $NIX_BUILD_TOP/tmp. %_topdir is $NIX_BUILD_TOP/rpmbuild.

WP3 tool shim: bind the instantiated copy at /usr/lib/rpm. The helper scripts use #!/usr/bin/bash or #!/usr/bin/sh, so the view must provide bash/sh, plus patch, find, sed, diff, mktemp and mv. brp-ldconfig needs /sbin/ldconfig in the view; nixpkgs' patched ldconfig fails with -r BUILDROOT, Rocky's static one works.

CONFIG_SITE: use rpmConfig.configSite (lib/rocky/config.site) first, then the package fragment, which can use $el_nixos_lib.

The uninstantiated rpmConfig is plain Rocky configuration, usable for rpm -qp and rpmspec -q (WP1 lock generator). Used outside the shim with RPM_CONFIGDIR, rpm prints "cannot open /usr/lib/rpm/rpmrc" because redhat/rpmrc includes that literal path and the rpmrc data goes missing, so read headers in the shim.

prep-hooks takes NIX_PREP_SCRIPT as a file path, not inline text.

Every rpmConfig instance also carries passthru configSite, rpm and instantiate ("nix/instantiate"); the default nn.rpmConfig additionally exposes stage0MacroPkgs.

### Requested changes elsewhere
- docs/nix-native-design.md §1.2: update for the fixes in lib/rocky/rpm/macros.nix-reloc: load-last via redhat/macros instead of macros.d, prep-hooks before ___build_post, set_build_flags kept, %distcore @DIST@ instead of %dist .el10_2, no %_rpmconfigdir override, %_dbpath pinned, %_annotated_build dropped.
- WP6 mkRpmPackage: pass --dist from lib/srpm.nix distOf <srpm> to instantiate, and keep a buildSrpm-like per-package `--define` path for single-line values only.
- WP3 tool shim: the view must contain a working /sbin/ldconfig (Rocky's) for brp-ldconfig, and bash at /usr/bin/bash for the nix/ helper scripts.

### Open issues (implementer)
- No real SRPM (glibc or a small one) has been built with this config yet. That needs the WP3 shim and WP6 mkRpmPackage.
- find-debuginfo through the BUILDROOT/usr fold link is not exercised: the test specs disable debuginfo.
- systemd-rpm-macros and rust-srpm-macros are not in stage0. Only a stand-in file shows that the systemd directory macros follow %_prefix. Generators from later macro packages (perl-generators, python-rpm-generators) are unverified against relocated file names.
- %__kmod_path ^/lib/modules is literal. It only matters once the kernel is relocated.
- `%{load:...}` from a macro file was not tried; the config appends the file to redhat/macros instead.

### Remaining after review/fix
- No real SRPM has been built with this config yet. That needs the WP3 shim and WP6 mkRpmPackage.
- find-debuginfo through the BUILDROOT/usr fold link is still not exercised.
- Requested elsewhere: WP6 mkRpmPackage must run rpmbuild with SOURCE_DATE_EPOCH unset (env -u SOURCE_DATE_EPOCH), otherwise the stdenv's 1980 value wins over the changelog date. It must also make awk available where instantiate runs, which the Nix builder already provides.
- Requested elsewhere: docs/nix-native-design.md §1.2 should say: systemd-rpm-macros' directory macros are literal /usr and are overridden conditionally in macros.nix-reloc; %__smp_use_ncpus is redefined instead of %_smp_build_ncpus; SOURCE_DATE_EPOCH must be unset for rpmbuild. This is on top of the earlier requested updates: redhat/macros placement, prep-hooks order, set_build_flags, %distcore, no %_rpmconfigdir, %_dbpath, %_annotated_build.
- Generators from later macro packages (perl-generators, python-rpm-generators) are still unverified against relocated file names. rust-srpm-macros is not checked.


## purity (nn/purity)

### Summary
WP16 is done: the build-purity check runs at evaluation time, and E6 has been run. Note: the worktree started at 8b6e4a9, not the stated base 3b7cc06. I fast-forwarded it to 3b7cc06 (3b7cc06 descends from 8b6e4a9), so nn/purity is 3b7cc06 plus one commit.

What nn.purity provides (lib/rocky/purity.nix, exposed by lib/rocky/parts/purity.nix):
- assertBuildPure stage x: returns x, or throws a report.
- check stage drv: does nothing unless stage.buildPure is true; then it guards drvPath and each output's drvPath.
- violations / report: the raw list of problems and the formatted text.
- forStage stage: builds a checker with a per-stage memo.
- drvSet drvs: builds allowedBuildDrvs.
- allowedSourcesFor, allowedSources, drvPathOf.

How it works:
- It runs builtins.getContext over every string, list and attrset in drvAttrs (path values are checked by prefix). Disallowed* attributes are skipped by default.
- It looks inside the stage's stdenv, stdenvNoCC, stdenv.cc and cc.bintools ("transparent" derivations). Their results are memoized per drvPath. Any other derivation that looks like a nixpkgs stdenv or wrapper is also looked into, at most 2 levels deep, so a nixpkgs stdenv is reported down to its real inputs.
- A derivation must be in stage.allowedBuildDrvs (keyed by drvPath) or be a lock FOD (an output hash that matches an SRPM sha256 in the lock; the lazy drvPath map for string-only references costs about 0.75 s once per evaluation).
- A plain source must be a path under lib/rocky/allowed-sources.nix (nixpkgs stdenv/generic, cc-wrapper, bintools-wrapper, wrapper-common, setup-hooks, the expand-response-params C source, and the repo). A copied file in the context is identified by hashing the same-named files under those roots, lazily.
- The error names each offending store path with its shortest attribute chain, e.g. `e6-hello.stdenv > e6-stdenv.defaultNativeBuildInputs[14] > e6-gcc-wrapper-15.3.0.expandResponseParams`.
- `check` guards only drvPath, never outPath, and drvPathOf reads the drvPath from the outPath context. Without this, an allowedBuildDrvs that contains the stage's own packages would make evaluation loop forever.

E6 result (docs/research/nix-native/experiments/E6.md):
- Setup: nixpkgs wrapCCWith/wrapBintoolsWith over a generic stdenvNoCC (built from nixpkgs pkgs/stdenv/generic) whose tools are 18 restaged copies of nixpkgs outputs.
- With only stdenvNoCC overridden, the check flags exactly four nixpkgs derivations: runtimeShell (bash-5.3p9), coreutils-9.11, gnugrep-3.12 and expand-response-params. Each appears in both wrappers, 18 chains in total.
- That set matches the wrappers' inputDrvs from `nix derivation show` exactly.
- With those four overridden, the report is empty.
- Both variants build and run a C hello program.
- Removing wrapper-common from the allowed sources makes utils.bash and darwin-sdk-setup.bash fail, so that root is needed. The design's list in §7.3 doesn't include it.

Cost, for 2200 trivial packages (CPU time):

| mode | time |
|---|---|
| no check | 1.81–1.86 s |
| check with a shared checker (stage.purityChecker) | 2.16–2.22 s (about 0.16 ms per package) |
| check with a separate checker per package | 5.56–5.71 s |

checks.nn-purity (lib/rocky/checks/purity.nix): 33 evaluation-time tests, positive and negative. The results go into the env of a trivial runCommand, which fails and prints the failures if any test fails. The check depends only on stdenv and bash, not on any test derivation. passthru.e6 exposes the fixture: tools, naive/full, stages, hello, checked, violations, report, scale.

### Interface notes
nn.purity = { assertBuildPure stage drvOrAttrs; check stage drv; violations stage x -> [ { kind = "derivation"|"source"|"path"; key; chain; } ]; report stage x -> string ("" when pure); forStage stage -> { violations report assertBuildPure check memoKeys }; drvSet drvs -> { <drvPath> = name; }; drvPathOf drv; allowedSources; allowedSourcesFor stage; defaultRoots; }.

Stage attributes read:
- allowedBuildDrvs (set keyed by drvPath)
- buildPure (check does nothing unless true)
- name
- stdenv, stdenvNoCC, transparent (extra derivations to look inside)
- extraAllowedSources (paths or store-path strings)
- allowLockFods (default true)
- purityIgnoreAttrs (default [ "disallowedReferences" "disallowedRequisites" ])
- fetch (default: the lock's lib/sources.nix)
- purityChecker (shared memo; set it to `purity.forStage <stage>` once per stage)

Build allowedBuildDrvs with `purity.drvSet`, or from the outPath context. Never build it from `.drvPath` of checked derivations, or evaluation recurses forever. `check` guards only drvPath (and outputs' drvPath), so dependents that interpolate outPath never force the check; each package is checked when its own drvPath is evaluated (nix build, nix-eval-jobs).

### Requested changes elsewhere
- WP6 mkStage (lib/rocky/stage.nix): set `purityChecker = nn.purity.forStage <the stage fixpoint>` once per stage. Without it the check costs about 1.7 ms per package instead of 0.16 ms. Also: build allowedBuildDrvs with `nn.purity.drvSet` (never from `.drvPath` of checked drvs), expose `stdenv` and `stdenvNoCC` on the stage, and set `buildPure = true` for S3/S4.
- WP6 mkRpmPackage: wrap results with `nn.purity.check stage drv` (design §11.1). Put `out` first in outputs; E6 hit a builtins.derivation whose first output (lib) became the default outPath.
- WP4 cc-wrapper (lib/rocky/cc/wrap.nix): from S2 on, pass runtimeShell, coreutils, gnugrep and expand-response-params explicitly to wrapCCWith and wrapBintoolsWith. E6 shows these are the only nixpkgs derivations those wrappers pull in.
- docs/nix-native-design.md §7.3: add pkgs/build-support/wrapper-common (utils.bash, darwin-sdk-setup.bash) and pkgs/by-name/ex/expand-response-params to the allowed-sources list (already in lib/rocky/allowed-sources.nix).

### Open issues (implementer)
- Not exercised with real mkRpmPackage/mkStage derivations, because WP6 doesn't exist yet. The S3 allowedBuildDrvs wiring is untested.
- Building expand-response-params from the nixpkgs C source with the stage stdenv isn't covered. E6 re-exports the nixpkgs binary as a stand-in.
- Store paths whose string context was stripped (unsafeDiscardStringContext) can't be detected by design.
- disallowedReferences/disallowedRequisites are skipped by default, but Nix still realises their context as inputDrvs. Design §7.1 puts S0/S1/S2 derivations in disallowedRequisites, which places them in the S3 sandbox.
- Looking into derivations that only look like a nixpkgs stdenv or wrapper (not stage seeds) isn't memoized and goes at most 2 levels deep. This only happens on the way to an error.

### Remaining after review/fix
- Still not tested with real mkRpmPackage/mkStage derivations (WP6), so the S3 allowedBuildDrvs wiring is unverified. The requestedChangesElsewhere from the original report still apply.
- Filtered or renamed source copies cannot be traced to their origin without IFD. They are now documented as needing stage.extraAllowedSources (store-path strings).
- nn/purity and nn/purity-fix both point at commit 0b69862 (1c4f7ed plus the fix commit). Files: lib/rocky/purity.nix, lib/rocky/checks/purity.nix, docs/research/nix-native/experiments/E6.md.


## names (nn/names)

### Summary
WP6a is done and committed on nn/names (based on 3b7cc06; the worktree started at 8b6e4a9, so I fast-forwarded it to 3b7cc06 first). It adds three sets of pure Nix functions, exposed as nn.names, nn.overrides and nn.unions, plus the check checks.nn-names.

nn.names (lib/rocky/names.nix and parts/names.nix):
- outputName, outputsFor, storeName and defaultPrefix follow design §2.12/§3.1.
- Two refinements, measured on the lock: a short name that is not a shell identifier (e.g. 100dpi) falls back to the full sanitized name. So does a reserved one (src, system, all, debug, logs, out, name, meta, ...), because it would shadow a derivation attribute or a setup.sh variable.
- A merge group that contains the prefix subpackage is always `out`.
- The part loads lock/rocky-10.2/subpackages.json when it exists (bare or wrapped format). Otherwise it uses lib/rocky/tests/<srpm>-subpackages.json, and failing that it derives the list from rpms.json bySrpm.
- glibc (fixture checked against rpms.json + the 3 unshipped): 224 subpackages give 225 outputs (223 + debug + logs), with glibc32 merged into out. rpmOutputs has 224 entries, 221 of them shipped.
- The 223 names are identical to those of the nixpkgs-faithful split spike that was actually built (/nix/store/vyg5nzdi2vsvs21pc493mwhpkpv6j0ls-glibc-2.39-142.el10_2.drv).
- Over all 2198 lock SRPMs: 11303 outputs, 0 failures, 2 collision fallbacks (perl-lib/perl-libs), 12 non-identifier/reserved fallbacks. 264 SRPMs have no eponymous or -libs subpackage and need the subpackages.json prefix.

nn.overrides (lib/rocky/overrides.nix):
- The §8.1 schema with all 25 fields, nested records and defaults.
- It collects all errors at once; each names the file and the key path (e.g. unknown key `lateBind.common.interp`).
- Cross-field rules: merge groups have 2+ members and are disjoint; runtimeSearchPaths values must be in the unions table; lateReferrers keys must be lateBind outputs; defines/layout keys must be macro names; defines values must be single-line.
- The loader imports packages/<srpm>/default.nix ({ lib, stage, rocky } style, callPackage-like argument passing) or returns the defaults.
- Every field is documented in packages/README-overrides.md, and the check verifies that.

nn.unions (lib/rocky/unions.nix): the 15 variables of §4.1, each with dirs, kind (list/single), sep and when (build/run). It also provides forRel, json and profileScript.

checks.nn-names: 37 eval-time tests plus 1 build-time test (bash runs profileScript on a fake root). It built green: /nix/store/wqy3w4bjb8y6ci14vyyg6dk9dg4dyh93-nn-names. A mutation test (removing "src" from the reserved list) made 2 tests fail, so the check is not vacuous; reverting it gave the same green output path.

The experiment record is docs/research/nix-native/experiments/names.md.

### Interface notes
Interfaces as committed:

nn.names (pure):
- outputName { srpm, subpkg, prefix } -> string.
- outputsFor { srpm, sub, mergeOutputs ? [], prefixSubpackage ? null }, where sub = { names; prefix?; shipped?; debug? }.
  - Returns { outputs; rpmOutputs; shippedRpmOutputs; unshipped; merged; prefix }.
  - outputs: "out" first, the rest sorted, then "debug" (unless sub.debug == false and there are no *-debuginfo names), then "logs".
  - rpmOutputs: every subpackage, unshipped ones included (glibc32 = "out"); use it for plan.json.
  - shippedRpmOutputs: what rocky.rpm.* should alias.
  - unshipped: { name = output }, for passthru.unshipped.
  - merged: { member = representative }.
  - Problems (no prefix, bad merge, unresolvable collision) throw one error listing all of them.
- outputsForSrpm { srpm, mergeOutputs?, prefixSubpackage? }: the same over subpackagesFor srpm.
- subpackagesFor srpm: the lock entry, else the fixture, else fromRpms (shipped only, marked fromRpms = true).
- subpackages: the lock file or {}.
- storeName { srpm, version, release, output ? "out" }: applies lib/store-name.nix sanitization.
- Also exported: sanitize, isIdentifier, isDebugName, reserved, fullName, defaultPrefix.

nn.overrides:
- overridesFor { stage, rocky ? {} } srpm. Curried, so mkRpmPackage can bind `overridesFor { inherit stage rocky; }` and call it with srpm, as in §11.1.
- load { srpm, stage, rocky?, dir?, name? }.
- validate file attrs: returns defaults-filled attrs, or throws.
- errors file attrs: returns the list of messages.
- Also: defaults, schema, fileFor srpm, types.
- Override files get only the arguments they name, out of { lib, stage, rocky }.

nn.unions:
- table.<VAR> = { dirs; kind = list|single; sep; when; doc }.
- Also: vars, forRel rel, json (for plan.json), profileScript root (sh).
- Hook contract for the partitioner (stated in the unions.nix header), per output o and each VAR whose `when` includes "build", for each existing dir in order:
  - list: addToSearchPath VAR "$o/rel"
  - single: export VAR="${VAR:-$o/rel}"

### Requested changes elsewhere
- WP1 (lock generator): emit subpackages.json as { <srpm> = { names; prefix; shipped = { <name> = bool; }; }; } (a wrapper key `subpackages` is also accepted). Optionally add `debug = false` for SRPMs that build no debuginfo, so outputsFor omits the debug output.
- WP6 (mkRpmPackage/stage): use names.outputsFor(...).rpmOutputs for plan.json (it includes unshipped subpackages) and shippedRpmOutputs for rocky.rpm.* aliases. Get overrides via `overrides.overridesFor { inherit stage rocky; } srpm`.
- WP5 (partitioner): read plan.json's union table from nn.unions.json and follow the hook-line contract in the lib/rocky/unions.nix header.
- docs/nix-native-design.md §2.12: mention the reserved-name / non-identifier fallback (e.g. rust-src would otherwise become output `src`, i.e. $src).

### Open issues (implementer)
- lock/rocky-10.2/subpackages.json (WP1) does not exist yet, so the check's 'lock entry = fixture' test is skipped (it says so in its output) and glibc uses the fixture. Once WP1 lands, the check compares names, prefix and unshipped set and fails on a mismatch.
- Two refinements of the §2.12 rule are not literally in the design: non-identifier names and reserved names fall back to the full sanitized name, and a full name that is still invalid gets a leading '_'. Measured impact on the 10.2 lock: 12 subpackages. They are documented in names.nix, README-overrides.md and the experiment record; the design text could be updated to match.
- opaqueRefs element semantics (output-relative globs of files carrying pieced refs) and the lateReferrers glob syntax are only typed as strings here. The partitioner (WP5) owns their meaning.
- The prefix rule's third tier (most /usr files in the official filelists) is not implemented here; per §3.1 that belongs to the lock generator. Without subpackages.json, the 264 SRPMs that have no eponymous or -libs subpackage need prefixSubpackage.

### Remaining after review/fix
- WP1's lock/rocky-10.2/subpackages.json is not committed here because WP1 owns it. Until it lands, nn.names.subpackagesFor / outputsForSrpm work only for glibc (via the fixture) and throw for every other SRPM. This is intentional; subpackagesOrRpms is the lenient escape hatch.
- lib/rocky/tests/names-overrides/ is not on the literal owned-file list, so the orchestrator should approve it.
- Requests to other work packages:
- WP6 (mkRpmPackage): switch off the multiple-outputs.sh hooks (moveToDev = false, propagatedBuildOutputs = "", setOutputFlags = false, drop _multioutDocs from preFixupHooks); call overrides.checkOutputs file overrides outs; use outputsFor rpmOutputs (it now includes debug packages -> debug) and shippedRpmOutputs.
- WP5 (partitioner hooks): follow the extended hook contract in the unions.nix header (provider / yieldsTo; hookScript is the reference implementation).
- WP1: keep `debug` as a list. names.nix now reads that format, and the old request for a bool `debug` is withdrawn.
- Design doc: §2.12 still lacks the reserved/non-identifier fallback, and §4.1/§4.2 could state the LOCPATH-yields-to-LOCALE_ARCHIVE rule. Both are for the design owner; I did not edit them.
- Work is on branch nn/names (and nn/names-fix) at 59c1671. The experiment record is docs/research/nix-native/experiments/names-fix.md.
