# el-nixos design

Goal: build Rocky Linux (first glibc, later all of BaseOS + AppStream) from the
official Rocky **source RPMs** with Nix. nixpkgs may be used to *bootstrap*;
shipped packages must not reference nixpkgs.

Target: Rocky Linux **10.2**, `x86_64` (RHEL 10 baseline is x86-64-v3).

## Mechanism preference

1. Plain derivations (no IFD, no dynamic derivations, no recursive-nix).  <- we use this
2. Dynamic derivations
3. recursive-nix

We stay at (1) by making the whole graph **static**: a generator reads Rocky
repodata (which already contains each SRPM's sha256 and BuildRequires, and each
binary RPM's `sourcerpm`/provides) and writes JSON lockfiles that Nix reads with
`builtins.fromJSON`. Nothing in evaluation depends on a build result.

## Layout

```
flake.nix               inputs: nixpkgs (bootstrap only); packages/checks/apps
default.nix             entry: { bootPkgs, release, kernelHeadersRpm } -> package set
lock/rocky-<rel>/       generated lockfiles (see "Lock format")
tools/update-lock.py    generator (run via `nix run .#update-lock`)
tools/resolve-buildrequires.py   mock-like BuildRequires closure
tools/rpm-parity.py, tools/parity/*.json   parity/purity checker + allowlists
lib/                    generic machinery (fetch, chroot, rpmbuild, rpm->tree, parity)
bootstrap/              stage0: FHS buildroot (toolchain from Rocky tarballs, rpm, nixpkgs tools)
packages/               per-SRPM build options / overrides (glibc.nix, kernel-headers.nix)
docs/                   design + per-component docs + research notes
```

## Lock format (`lock/rocky-<rel>/srpms.json`)

```json
{
  "release": "10.2",
  "dist": ".el10_2",
  "mirrors": ["https://dl.rockylinux.org/pub/rocky/10.2",
              "https://dl.rockylinux.org/vault/rocky/10.2"],
  "srpms": {
    "<srpm name>": {
      "epoch": 0, "version": "2.39", "release": "142.el10_2",
      "repo": "BaseOS",                       // BaseOS | AppStream | CRB
      "path": "Packages/g/glibc-2.39-142.el10_2.src.rpm",
      "sha256": "<hex>", "size": 21569653,
      "buildRequires": ["binutils >= 2.30", "gcc >= 7.2.1", "..."]
    }
  }
}
```

SRPM URL = `<mirror>/<repo>/source/tree/<path>` (try every mirror; the release
dir moves to vault when the next minor ships). Only the newest EVR per name is
kept (real rpmvercmp, incl. `~`/`^`; ties go to the first repo in
BaseOS, AppStream, CRB order). Keys are sorted.

Beside it (the generator's docstring is the reference for both):

- `rpms.json` — official binary RPMs, x86_64 + noarch (the Rocky 10 x86_64
  repos are not multilib: no i686 at all), newest EVR per `name.arch`:
  `{format, release, arches, mirrors, repodata: {<repo>/<tree>: {revision,
  primary, timestamp}}, rpms: {"<name>.<arch>": {name, arch, epoch, version,
  release, repo, path, sha256, size, srpm, sourcerpm}}, bySrpm: {<srpm>:
  ["<name>.<arch>", ...]}}`. `srpm` is the SRPM name, `sourcerpm` the file
  name. One entry per line. URL = `<mirror>/<repo>/x86_64/os/<path>`.
- `deps.json.gz` — NOT read by Nix. Per `name.arch`: `evr, repo, srpm,
  provides, requires, conflicts, obsoletes, recommends, suggests,
  supplements, enhances` (dep strings like the BuildRequires above; rich deps
  verbatim) and `files` (the file subset primary.xml carries). `rpmlib(...)`
  and kernel symbol-version deps (`kernel(...)`, `ksym(...)`) are dropped.
  gzip with mtime 0, so it is byte-reproducible.

Sizes for 10.2: srpms.json 1.3 MB (2217 SRPMs), rpms.json 2.7 MB (6907
binaries), deps.json.gz 0.9 MB (7.8 MB raw). `nix eval .#lock.release` takes
~0.05 s; rpms.json is parsed only when `officialRpms` is touched.

Regenerate with `nix run .#update-lock` from the repo root (downloads
repomd.xml + primary.xml.gz for each repo's source and x86_64 trees, verifies
them against repomd's sha256, caches them in `.cache/repodata/`).

### Nix attrs (legacyPackages.x86_64-linux)

- `lock`, `rpmsLock` — the parsed lockfiles.
- `sources.<srpm>` — the SRPM as a FOD (`lib/fetch-srpm.nix`).
- `officialRpms.<name>` / `officialRpms."<name>.<arch>"` — official binary
  RPM as a FOD (`lib/fetch-rpm.nix`), for verification comparisons only.
- `fetchSrpm name`, `fetchRpm "<name>.<arch>"` — the underlying functions.

Store names map `^`/`~` (legal in RPM file names) to `_`.

### BuildRequires resolution

`nix run .#resolve-buildrequires -- <srpm> [--format md|json|text]
[--recursive]` emulates mock rocky-10: transaction 1 installs the
`chroot_setup_cmd` list (Rocky's comps has no buildsys-build group), and
transaction 2 installs the SRPM's BuildRequires, both with
`install_weak_deps=0`. It matched real dnf5 exactly for 260 of 260 sampled
SRPMs (150 of them held out from tuning); see `docs/research/glibc-buildroot-closure.md`.

## Build model

Every SRPM is built by **real `rpmbuild --rebuild`** inside an FHS chroot that
is assembled inside the normal Nix sandbox using an unprivileged user+mount
namespace (`bwrap` or `unshare`; verified to work in the sandbox and on the
nixbuild.net remote builders). This mirrors what mock does.

- `buildroot` derivation: an FHS root tree (`/usr`, `/etc`, rpmdb, ...).
- `buildSrpm { name, buildroot, rpmbuildArgs, defines }` derivation:
  copies/overlays the buildroot to a writable root, runs
  `rpmbuild --rebuild` on the fetched SRPM as an unprivileged `mockbuild`
  user (uid 1000) with `%_topdir /builddir/build`, deterministic macros
  (`SOURCE_DATE_EPOCH`, `%_buildhost`, `%use_source_date_epoch_as_buildtime`,
  `%clamp_mtime_to_source_date_epoch`), `%_smp_mflags` from
  `NIX_BUILD_CORES`, and `%dist` from the lock. Outputs: `out` =
  `RPMS/<arch>/*.rpm`, `SRPMS/`; `logs` = build/srpm logs, file list, purity
  report. **Every build ends with a byte-level purity scan** of its binary
  RPMs (`tools/rpm_purity.py`: headers, payload files, symlink targets, and
  inside compressed members, ELF MiniDebugInfo and compressed ELF sections);
  any `/nix/store` fails the build — this is how "does not depend on
  nixpkgs" is *enforced*.
- `rpmTree` derivation: one binary RPM extracted (rpm2cpio | cpio) to an FHS
  tree, with `allowedReferences = [ ]` (which by itself only catches store
  paths of the derivation's input closure, see Verification).
- Package set attrs (`legacyPackages.x86_64-linux`): `srpm.<srpm>` (the
  rpmbuild result) and `rpms.<binary rpm name>` (the extracted tree), both
  static from the lock (`rpmsLock.bySrpm`); per-SRPM extras under
  `packageSets.<srpm>`; the bootstrap under `stage0.*` (its own `srpm.*`,
  `rpms.*`, `tests.*`). Today: `srpm.glibc`, `rpms.<221+3 glibc
  subpackages>`, `stage0.kernelHeadersBuild` / `stage0.rpms.kernel-headers`.
- Flake outputs: `packages.x86_64-linux.{glibc, glibc-rpms, kernel-headers,
  kernel-headers-rpms}`; `checks.x86_64-linux.*` = stage0 acceptance tests +
  parity checks (`glibc-parity`, `kernel-headers-parity`, tool self-tests …)
  + `glibc-purity`, `glibc-sanity`, `glibc-abi`, `glibc-runtime`;
  `hydraJobs` = packages, checks, `srpm.*`, `rpms.*` and stage0's, for
  `nix run .#build-jobs` (nix-eval-jobs, below).

### Reproducibility

`buildSrpm` sets `SOURCE_DATE_EPOCH` from the changelog
(`%source_date_epoch_from_changelog`, `%use_source_date_epoch_as_buildtime`,
`%clamp_mtime_to_source_date_epoch`), a fixed `%_buildhost`, and uses Nix's
sandbox. Measured with `nix build --rebuild` on glibc (233 RPMs) and which:
every RPM is bit-identical across rebuilds **except** RPMs containing static
archives (glibc-static, glibc-devel, glibc32, sysroot-x86_64-el10-glibc):
GNU ar writes the wall-clock time into each member header (glibc's
Makerules run `ar cruv`; binutils is configured like Rocky's,
`--enable-deterministic-archives=no`, and ar ignores `SOURCE_DATE_EPOCH`).
Rocky's own archives carry wall-clock dates too, and rpm-parity ignores
member headers. The build logs are a separate output (`logs`): parallel
`make` output and `rpm-tmp.*` names are never reproducible. Nix's
`--rebuild` therefore always reports "may not be deterministic" — and stops
at the first differing output (`logs` sorts before `out`), so it never
compares `out`. To check the RPMs, rebuild with `nix build --rebuild
--keep-failed` and `cmp` the kept build directory's
`builddir/build/RPMS/*/*.rpm` with `$out/RPMS` (glibc, 2026-10-18: 230 of
234 files identical, the 4 differing ones are exactly the archive-carrying
RPMs; which: all identical).

### Stages

- **stage0** (`bootstrap/`, [stage0.md](stage0.md)): an FHS buildroot whose
  *toolchain* is built from **Rocky's own source tarballs** (binutils 2.41,
  multilib gcc 14.3.1 with Rocky's configure options and defaults, a stage0
  glibc 2.39 as the system libc), compiled by nixpkgs' compiler, plus Rocky's
  rpm 4.19.1.1 and debugedit 5.1 built with FHS paths. Everything else
  (bash, coreutils, make, perl, python3, gawk, …) is nixpkgs at FHS paths
  (`/usr/bin/...` symlinks); `/nix/store` is visible read-only inside the
  chroot. rpm's config dir is `/usr/lib/rpm` and it reads
  `/usr/lib/rpm/macros.d`, so Rocky's macro packages work unmodified; they
  are themselves built from their SRPMs in stage0 (two passes) and installed
  into the buildroot ("stage0-full"). stage0 builds use `--nodeps` (the
  nixpkgs tools are not in the rpmdb). Annobin is off (no plugin for the
  stage0 gcc yet).
- **stage1+** (later): buildroots made only of Rocky RPMs we built, installed
  with `rpm --root`; `/nix/store` is NOT visible inside the chroot, so
  leakage is impossible by construction; BuildRequires checked for real.
  `checks.glibc-runtime` already assembles such roots (Rocky RPMs only,
  scriptlets on). Known limits of the layer machinery for that stage
  (non-root file owners, modes the store cannot represent) are listed in
  [stage0.md](stage0.md) "Known gaps".

## Verification

- **Purity**: `buildSrpm` runs `tools/rpm_purity.py` on every build — a
  byte-level search for `/nix/store` in every header, payload file and
  symlink target of every binary RPM (debuginfo included), also inside
  gzip/xz/bzip2/zstd members, ELF `.gnu_debugdata` and compressed ELF
  sections; any hit fails the build, so nothing that depends on a package
  (its `rpmTree`s, checks, other buildroots) can exist with a leak. The
  parity tool runs the same scanner (cannot be allowlisted). `buildSrpm` and
  `rpmTree` also keep `allowedReferences = [ ]`, but Nix's reference
  scanner only knows the hashes of a derivation's *input closure* (for
  `rpmTree`: rpm, cpio, stdenv — not the nixpkgs perl/python/… that the
  stage0 chroot exposes) and cannot look into compressed data, so on its own
  it is not a purity check (`checks.glibc-purity` = all 224 glibc trees
  built, i.e. their builds passed the scan). Negative tests:
  `parity-selftest-purity{,-nested}`, `purity-selftest-{plain,nested}`.
- **Parity** ([parity.md](parity.md)): `mkParityCheck` compares our RPMs with
  the official ones from `rpms.json` (headers, deps, scriptlets, file lists
  and attributes, content digests; for every differing ELF file the
  properties, the dynamic symbols with versions, the bytes of every loaded
  section and the segments; static archives member by member) and fails on
  any difference not declared, with a reason, in `tools/parity/*.json`
  (`default.json` for any rebuild, `stage0.json` for stage0 hacks, one file
  per SRPM).
- **ABI cross-check** (`checks.glibc-abi`, `tools/abi-compare.py`): the same
  questions answered independently with GNU binutils (`readelf --dyn-syms`,
  `-V`, `-d`; `nm`/`ar` per archive member; header bytes) for all 221
  shipped glibc subpackages, no allowlist.
- **Runtime** (`checks.glibc-runtime`): roots made only of RPMs (no
  `/nix/store` inside), one with our glibc and one with the official one,
  same behaviour report.
- **Evaluation**: plain derivations only; `nix run .#build-jobs` evaluates
  all of `hydraJobs` with `allow-import-from-derivation = false` (as does
  `nix flake check --no-build --option allow-import-from-derivation false`).

## Building everything (CI)

`nix run .#build-jobs [-- --workers N] [-- NIX-BUILD-ARGS]`
(`tools/build-jobs.sh`): `nix-eval-jobs --flake .#hydraJobs
--check-cache-status --force-recurse` with IFD disabled, skips every job
whose outputs are already local or substitutable, builds the rest with one
`nix build --keep-going --stdin`, and prints a summary (evaluation errors,
local / cached / built / failed). nix-eval-jobs and jq come from the pinned
nixpkgs.

## Status

Milestone 1 = Rocky `glibc` SRPM built in stage0, binary RPMs whose contents
have no nixpkgs references, and whose file lists / provides / requires match
the official Rocky binary RPMs as closely as possible (differences documented).
**Done**: see [glibc.md](glibc.md) (233 RPMs, all 221 shipped NEVRAs equal
to the official ones, the build's purity scan finds no `/nix/store`,
`glibc-parity` passes against all 221 official RPMs with only the documented
differences, `glibc-abi` finds the ABI identical, `glibc-runtime` finds the
behaviour identical in RPM-only roots; open items in glibc.md "Known
differences / open issues"). Rocky
kernel-headers are built from the kernel SRPM and used in the glibc
buildroot ([kernel-headers.md](kernel-headers.md)).
