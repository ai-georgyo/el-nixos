# el-nixos: Rocky Linux built from its source RPMs with Nix

This flake rebuilds **Rocky Linux 10.2** (x86_64, x86-64-v3) from the
official Rocky **source RPMs**. Each package goes through a real
`rpmbuild --rebuild`, run inside an FHS chroot that is assembled in the normal
Nix sandbox (bubblewrap + overlayfs in an unprivileged user namespace, the way
mock works). Every build is a plain derivation: no IFD, no dynamic derivations,
no recursive-nix. The package graph comes from JSON lockfiles generated from
Rocky's repodata.

nixpkgs is used **only to bootstrap** (stage0). Shipped packages must not
reference it. This is enforced by every `buildSrpm`: its last step searches
each binary RPM it produced byte by byte for `/nix/store` — headers, payload
files, symlink targets, and inside compressed members, ELF MiniDebugInfo and
compressed ELF sections (`tools/rpm_purity.py`) — and fails the build on any
hit. (`allowedReferences = [ ]` on the build and on the `rpmTree`s is kept,
but Nix only detects hashes of a derivation's input closure, so on its own
it would miss e.g. a nixpkgs perl path from the buildroot.) On top of that, a
parity checker compares every RPM we build with the official Rocky RPM.

## Status

**Milestone 1 is done.** `glibc-2.39-142.el10_2` builds from the unmodified
Rocky SRPM:

* It produces 233 binary RPMs: the 221 that Rocky ships, 3 more that the spec
  builds but Rocky does not publish, and 9 debug packages. Every NEVRA equals
  the official one.
* No `/nix/store` anywhere in the 233 RPMs, debuginfo and nested
  compression included (the build's purity scan); all 224 non-debug payload
  trees build (`checks.glibc-purity`).
* `checks.glibc-parity` compares all 221 official RPMs, including every
  dynamic symbol and version and the bytes of every loaded ELF section (and
  every member of the static archives). It passes, and the only differences
  are the ones listed in `tools/parity/*.json`, each with its reason: build
  host/time/vendor identity, build-id-dependent and debug bytes, annobin
  notes (stage0 has no annobin plugin), memusagestat's copy-relocation
  layout (nixpkgs' libgd at link time), and the 3 unpublished subpackages.
  211 of the 221 payloads are byte-identical to Rocky's, compressed. See
  [docs/glibc.md](docs/glibc.md) ("Parity with the official RPMs" and
  "Known differences / open issues").
* `checks.glibc-abi` cross-checks the ABI with GNU binutils: dynamic
  symbols and versions of all 709 DSOs/executables, symbols of all 3541
  archive members, all 480 headers — identical, no allowlist.
* `checks.glibc-runtime`: in roots made only of RPMs (no `/nix/store`
  inside), our glibc behaves exactly like the official one — a ~1550-line
  report (loader, locales, iconv, NSS, utilities, programs compiled against
  our glibc-devel/-static, 32-bit) and all 885 locales are identical.
* The kernel headers come from Rocky's own kernel SRPM, built headers-only
  (`kernel-headers-6.12.0-211.66.1.el10_2`). They are installed into the glibc
  buildroot with rpm, and `checks.kernel-headers-parity` passes: all 1015
  common files are byte-identical. See
  [docs/kernel-headers.md](docs/kernel-headers.md).

### Nix-native packages (milestone M1 of the current direction)

The same SRPMs are also built as **relocated, composable Nix store paths**:
one derivation per SRPM, one Nix output per RPM subpackage, rpmbuild as the
spec engine, nothing under `/usr` (design:
[docs/nix-native-design.md](docs/nix-native-design.md); guide:
[docs/nix-native.md](docs/nix-native.md)). **M1 is reached:**
`rockyBoot.s1.glibc` (225 outputs: `out`, `dev`, `common`, `langpack_de`, …)
is built by the stage0 gcc through the S1 toolchain; its closure is its own
outputs plus one RUNPATH-free `libgcc_s` copy, and
`checks.nn-glibc-{files,abi,content,closure,runtime}` pass against the 221
official RPMs (every remaining difference is a named allowlist rule: the
three Nix-side glibc patches, store-by-pieces code, the stage0 annobin gap,
locale aliases). Stage S1 also has which, xz, zlib-ng, gzip and the kernel
headers. Attributes: `rockyBoot.s1.<srpm>`, `rockyBoot.s1.rpm."<rpm-name>"`,
`hydraJobs.nixNative`; machinery under `legacyPackages.x86_64-linux.nn`.

```sh
nix build -L '.#rockyBoot.s1.glibc^*'                     # all 225 outputs
nix build -L '.#rockyBoot.s1.rpm."glibc-devel"'           # by RPM name (= glibc.dev)
nix build -L .#checks.x86_64-linux.nn-glibc-runtime       # behaviour without /usr vs the official RPMs
```

## Quick start

```sh
# glibc: the rpmbuild result (RPMS/{x86_64,noarch}/*.rpm, SRPMS/; .#glibc-rpms^logs: build.log, purity.json)
nix build .#glibc-rpms
# the main glibc RPM's payload as a tree
nix build .#glibc
# Rocky kernel-headers (tree / rpmbuild result)
nix build .#kernel-headers .#kernel-headers-rpms

# checks
nix build .#checks.x86_64-linux.glibc-purity          # all 224 rpmTrees (the purity scan ran in the build)
nix build .#checks.x86_64-linux.glibc-parity          # vs the 221 official RPMs; fails on unexpected diffs
nix build .#checks.x86_64-linux.glibc-parity.report   # never fails; read result/report.md
nix build .#checks.x86_64-linux.glibc-abi             # binutils ABI comparison vs official
nix build .#checks.x86_64-linux.glibc-runtime         # RPM-only roots: our glibc vs official, same behaviour
nix build .#checks.x86_64-linux.glibc-sanity          # configure results, ELF facts, NEVRs
nix build .#checks.x86_64-linux.kernel-headers-parity
nix flake check                                       # builds every check
nix flake check --no-build --option allow-import-from-derivation false   # evaluation only, IFD forbidden

# everything (hydraJobs) that is neither built nor substitutable, via nix-eval-jobs
nix run .#build-jobs -- --workers 4                   # --dry-run: only report; -- ARGS: passed to nix build
```

`nix run .#build-jobs` (`tools/build-jobs.sh`) runs `nix-eval-jobs --flake
.#hydraJobs --check-cache-status --force-recurse` (nix-eval-jobs from the
pinned nixpkgs, import-from-derivation disabled, so it doubles as the
IFD-free evaluation check), drops every job whose outputs are already in the
local store or in a binary cache, builds the remaining derivations with one
`nix build --keep-going --no-link --stdin`, and prints a summary (jobs,
evaluation errors, local, cached, built, failed). `hydraJobs` holds the
packages, the checks, `srpm.*`, `rpms.*` and the stage0 toolchain,
buildroots and package builds. Options: `--flake REF`, `--attr ATTR`,
`--workers N`, `--max-memory-size MiB`, `--dry-run`, `--jobs-file FILE`.

Cost: the first build of the stage0 toolchain takes roughly 30 to 60 minutes
of builder time (gcc dominates). After that, the glibc `rpmbuild` takes about
10 minutes on 16 CPUs and the kernel-headers build a few minutes. Remote
builders with 2 CPUs are several times slower.

Other entry points:

* `nix run .#update-lock`: regenerate `lock/rocky-10.2/` from Rocky repodata.
* `nix run .#resolve-buildrequires -- <srpm>`: mock-like BuildRequires
  closure.
* `nix run .#rpm-parity -- --ours DIR --official RPM... --out DIR`: the parity
  tool on its own.
* `nix run .#build-jobs`: build everything not yet built or cached (above).

## Layout

```
flake.nix               outputs (packages, checks, hydraJobs, apps); nixpkgs input = bootstrap only
default.nix             the package set: lock, sources, officialRpms, stage0, srpm, rpms, packageSets, parity
lock/rocky-10.2/        generated lockfiles: srpms.json (SRPMs + BuildRequires), rpms.json (official binaries), deps.json.gz
lib/                    generic machinery (buildSrpm runs tools/rpm_purity.py on every build)
  fetch-srpm.nix, fetch-rpm.nix, sources.nix, srpm.nix   lock-driven fetchers (FODs), unpackSrpm, distOf
  chroot.sh, default.nix                                 chroot runner, mkBuildroot, buildSrpm, rpmTree, runInBuildroot
  parity.nix                                             mkParityCheck (tools/rpm-parity.py as a derivation)
bootstrap/              stage0: FHS toolchain from Rocky tarballs (binutils, gcc, glibc), rpm 4.19 + debugedit
                        (libzstd/libmagic from Rocky's sources), root layer, macro packages, kernel-headers
                        wiring, glibc build deps, makeinfo 7.1, tests/ (incl. the chroot layer machinery)
packages/               per-SRPM recipes: glibc.nix (+ glibc-sanity.sh, glibc-runtime/), kernel-headers.nix
tools/                  update-lock.py, resolve-buildrequires.py, rpm-parity.py, rpm_purity.py, abi-compare.py,
                        build-jobs.sh, parity/*.json (allowlists)
docs/                   DESIGN.md (contract), stage0.md, glibc.md, kernel-headers.md, parity.md, research/
lib/rocky/               Nix-native machinery (mkRpmPackage, mkStage, cc-wrapper, tool shim, rpm config,
                        purity, late binding; parts/ -> nn.<name>, checks/ -> checks.nn-*)
bootstrap/nn/           Nix-native stages (s1.nix), libgcc-for-glibc.nix
tools/rocky-partition/  the in-build partitioner (one output per subpackage); tools/nn-parity.py: relocated parity
```

## Documentation

* [docs/DESIGN.md](docs/DESIGN.md): goals, mechanism, lock format, build
  model, stages, verification.
* [docs/stage0.md](docs/stage0.md): the bootstrap buildroot and every stage0
  hack.
* [docs/glibc.md](docs/glibc.md): how glibc is built, its buildroot, all
  deviations from Rocky's build, and the results.
* [docs/kernel-headers.md](docs/kernel-headers.md): the headers-only kernel
  build.
* [docs/parity.md](docs/parity.md): the parity/purity checker and the
  allowlist format.
* [docs/nix-native.md](docs/nix-native.md) and
  [docs/nix-native-design.md](docs/nix-native-design.md): the relocated,
  Nix-native packages (current direction).

## Next steps toward BaseOS

1. **Annobin.** Build Rocky's annobin SRPM in stage0 against the stage0 gcc's
   plugin headers, then drop the `_annotated_build 0` /
   `_annobin_gcc_plugin %{nil}` hack. This removes the annobin rules from
   `stage0.json`.
2. **The rest of the glibc buildroot from Rocky SRPMs.** The glibc build
   still takes gd, libpng, zlib, libselinux, audit and libcap headers and
   libraries from nixpkgs (nixpkgs' libgd is what changes memusagestat's
   copy-relocation layout), along with the build tools (python, perl, gawk,
   gettext, ...). Next is building the Rocky SRPMs of the toolchain
   (binutils, gcc, rpm, ...) and of these libraries in stage0.
3. **stage1.** Use buildroots made only of Rocky RPMs we built, installed with
   `rpm --root` and real dependency checks, with no `/nix/store` in the
   chroot (`checks.glibc-runtime` already builds such roots). Rebuild glibc
   there; the stage0/stage1 difference should then disappear from the
   parity report. Open for that: non-root file owners and modes in layers
   ([docs/stage0.md](docs/stage0.md), "Known gaps").
4. **Scale out.** Walk BaseOS in BuildRequires order, using the lock
   (`srpms.json` already carries every SRPM's BuildRequires) and the mock-like
   resolver. Each SRPM gets a `packages/<srpm>.nix` only when it needs
   options, and a parity allowlist only for justified differences.
