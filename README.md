# el-nixos: Rocky Linux built from its source RPMs with Nix

This flake rebuilds **Rocky Linux 10.2** (x86_64, x86-64-v3) from the
official Rocky **source RPMs**. Each package goes through a real
`rpmbuild --rebuild`, run inside an FHS chroot that is assembled in the normal
Nix sandbox (bubblewrap + overlayfs in an unprivileged user namespace, the way
mock works). Every build is a plain derivation: no IFD, no dynamic derivations,
no recursive-nix. The package graph comes from JSON lockfiles generated from
Rocky's repodata.

nixpkgs is used **only to bootstrap** (stage0). Shipped packages must not
reference it. This is enforced: every binary RPM's payload is extracted into
an `rpmTree` derivation with `allowedReferences = [ ]`. On top of that, a
parity checker compares every RPM we build with the official Rocky RPM and
fails on any `/nix/store` string.

## Status

**Milestone 1 is done.** `glibc-2.39-142.el10_2` builds from the unmodified
Rocky SRPM:

* It produces 233 binary RPMs: the 221 that Rocky ships, 3 more that the spec
  builds but Rocky does not publish, and 9 debug packages. Every NEVRA equals
  the official one.
* All 224 non-debug payload trees build with `allowedReferences = [ ]`
  (`checks.glibc-purity`).
* `checks.glibc-parity` compares all 221 official RPMs. It passes, and the
  only differences are the ones listed in `tools/parity/*.json`, each with
  its reason: build host/time/vendor identity, build-id-dependent bytes,
  annobin notes (stage0 has no annobin plugin), libmagic text, and the 3
  unpublished subpackages. For details see [docs/glibc.md](docs/glibc.md)
  ("Parity with the official RPMs").
* The kernel headers come from Rocky's own kernel SRPM, built headers-only
  (`kernel-headers-6.12.0-211.66.1.el10_2`). They are installed into the glibc
  buildroot with rpm, and `checks.kernel-headers-parity` passes: all 1015
  common files are byte-identical. See
  [docs/kernel-headers.md](docs/kernel-headers.md).

## Quick start

```sh
# glibc: the rpmbuild result (RPMS/{x86_64,noarch}/*.rpm, SRPMS/, logs/build.log)
nix build .#glibc-rpms
# the main glibc RPM's payload as a tree
nix build .#glibc
# Rocky kernel-headers (tree / rpmbuild result)
nix build .#kernel-headers .#kernel-headers-rpms

# checks
nix build .#checks.x86_64-linux.glibc-purity          # 224 rpmTrees, allowedReferences = [ ]
nix build .#checks.x86_64-linux.glibc-parity          # vs the 221 official RPMs; fails on unexpected diffs
nix build .#checks.x86_64-linux.glibc-parity.report   # never fails; read result/report.md
nix build .#checks.x86_64-linux.glibc-sanity          # configure results, ELF facts, NEVRs
nix build .#checks.x86_64-linux.kernel-headers-parity
nix flake check --no-build                            # evaluates everything
```

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

## Layout

```
flake.nix               outputs (packages, checks, apps); nixpkgs input = bootstrap only
default.nix             the package set: lock, sources, officialRpms, stage0, srpm, rpms, packageSets, parity
lock/rocky-10.2/        generated lockfiles: srpms.json (SRPMs + BuildRequires), rpms.json (official binaries), deps.json.gz
lib/                    generic machinery
  fetch-srpm.nix, fetch-rpm.nix, sources.nix, srpm.nix   lock-driven fetchers (FODs), unpackSrpm, distOf
  chroot.sh, default.nix                                 chroot runner, mkBuildroot, buildSrpm, rpmTree, runInBuildroot
  parity.nix                                             mkParityCheck (tools/rpm-parity.py as a derivation)
bootstrap/              stage0: FHS toolchain from Rocky tarballs (binutils, gcc, glibc), rpm 4.19 + debugedit,
                        root layer, macro packages, kernel-headers wiring, glibc build deps, makeinfo 7.1
packages/               per-SRPM recipes: glibc.nix (+ glibc-sanity.sh), kernel-headers.nix
tools/                  update-lock.py, resolve-buildrequires.py, rpm-parity.py, parity/*.json (allowlists)
docs/                   DESIGN.md (contract), stage0.md, glibc.md, kernel-headers.md, parity.md, research/
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

## Next steps toward BaseOS

1. **Annobin.** Build Rocky's annobin SRPM in stage0 against the stage0 gcc's
   plugin headers, then drop the `_annotated_build 0` /
   `_annobin_gcc_plugin %{nil}` hack. This removes the annobin rules from
   `stage0.json`.
2. **The rest of the glibc buildroot from Rocky SRPMs.** The glibc build
   still takes gd, libpng, zlib, libselinux, audit and libcap headers and
   libraries from nixpkgs, along with the build tools (python, perl, gawk,
   gettext, ...). Next is building the Rocky SRPMs of the toolchain
   (binutils, gcc, rpm, ...) and of these libraries in stage0.
3. **stage1.** Use buildroots made only of Rocky RPMs we built, installed with
   `rpm --root` and real dependency checks, with no `/nix/store` in the
   chroot. Rebuild glibc there; the stage0/stage1 difference should then
   disappear from the parity report.
4. **Scale out.** Walk BaseOS in BuildRequires order, using the lock
   (`srpms.json` already carries every SRPM's BuildRequires) and the mock-like
   resolver. Each SRPM gets a `packages/<srpm>.nix` only when it needs
   options, and a parity allowlist only for justified differences.
