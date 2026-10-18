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
flake.nix               inputs: nixpkgs (bootstrap only)
default.nix             entry: { bootPkgs, release } -> package set
lock/rocky-<rel>/       generated lockfiles (see "Lock format")
tools/update-lock.py    generator (run via `nix run .#update-lock`)
lib/                    generic machinery (fetch, chroot, rpmbuild, rpm->tree)
bootstrap/              stage0: FHS buildroot synthesized from nixpkgs
packages/               per-SRPM build options / overrides (e.g. glibc.nix)
docs/                   design + research notes
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
  `NIX_BUILD_CORES`, and `%dist` from the lock. Output:
  `$out/RPMS/<arch>/*.rpm`, `$out/SRPMS/`, `$out/logs/`.
- `rpmTree` derivation: one binary RPM extracted (rpm2cpio | cpio) to an FHS
  tree; uses `allowedReferences = [ ]` so any `/nix/store` reference fails the
  build — this is how "does not depend on nixpkgs" is *enforced*.
- Package set attrs: `rocky.srpm.<srpm>` (the rpmbuild result) and
  `rocky.rpms.<binary rpm name>` (the extracted tree), both static from the lock
  (`rpmsLock.bySrpm`); per-SRPM extras under `rocky.packageSets.<srpm>`.

### Stages

- **stage0** (`bootstrap/`): FHS buildroot made from nixpkgs (nixos-26.05,
  gcc14 to match RHEL 10's GCC 14). nixpkgs tools are exposed at FHS paths
  (`/usr/bin/...`), `/nix/store` is visible read-only inside the chroot. rpm is
  arranged so its config dir is `/usr/lib/rpm` and it reads
  `/usr/lib/rpm/macros.d`, so Rocky's macro packages (redhat-rpm-config,
  rocky-release's `macros.dist`, python-rpm-macros, ...) work unmodified.
  Rocky macro packages are themselves built from their SRPMs in stage0 and
  installed into the stage0 buildroot. stage0 builds use `--nodeps` (the
  nixpkgs tools are not in the rpmdb).
- **stage1+** (later): buildroots made only of Rocky RPMs we built, installed
  with `rpm --root`; `/nix/store` is NOT visible inside the chroot, so
  leakage is impossible by construction; BuildRequires checked for real.

Milestone 1 = Rocky `glibc` SRPM built in stage0, binary RPMs whose contents
have no nixpkgs references, and whose file lists / provides / requires match
the official Rocky binary RPMs as closely as possible (differences documented).
Status: built — see [glibc.md](glibc.md).
