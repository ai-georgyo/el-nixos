# Libraries whose behaviour ends up as BYTES in every RPM the stage0 rpmbuild
# writes, built from Rocky's own SRPM sources (tarball + every patch of the
# spec) with nixpkgs' recipes:
#
#   zstd 1.5.5-9.el10   librpmio compresses the payload (%_binary_payload
#                       w19.zstdio).  zstd's output is a function of the
#                       library version + parameters only; nixpkgs' 1.5.7
#                       produced different compressed bytes for identical
#                       payloads (209 of 219 glibc RPMs differed in nothing
#                       else; recompressing the same cpio with 1.5.5 -19
#                       reproduces Rocky's payload byte for byte).
#   file 5.45-9.el10    librpmbuild's libmagic writes the FILECLASS header
#                       strings (nixpkgs' 5.47 says "dynamically linked" for
#                       ld.so and appends ", original size modulo 2^32 N" to
#                       gzip descriptions).  The compiled magic database comes
#                       from the same patched sources, as on Rocky.
#   elfutils (nixpkgs)  only re-linked against this zstd (rpm loads libelf/libdw,
#                       which link libzstd: one process, one libzstd.so.1).
#
# These run OUTSIDE the shipped packages (they are part of the build tool,
# like rpm itself); nothing of them is copied into an RPM.
{ pkgs, unpackSrpm }:
let
  zstdSrpm = unpackSrpm "zstd";
  fileSrpm = unpackSrpm "file";
  ze = zstdSrpm.lockEntry;
  fe = fileSrpm.lockEntry;

  # like zstd.spec: the upstream Makefiles, `make -C lib lib-mt` (only the
  # library is needed: rpm links libzstd)
  zstd = pkgs.stdenv.mkDerivation {
    pname = "stage0-zstd";
    version = "${ze.version}-${ze.release}";
    src = "${zstdSrpm}/zstd-${ze.version}.tar.gz";
    # zstd.spec: Patch1 (pzstd man page, %if with pzstd -- default on), Patch2
    patches = map (p: "${zstdSrpm}/${p}") [ "pzstd.1.patch" "bti.patch" ];
    dontConfigure = true;
    enableParallelBuilding = true;
    buildPhase = ''
      runHook preBuild
      make -C lib lib-mt -j$NIX_BUILD_CORES PREFIX=$out LIBDIR=$out/lib
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      make -C lib install-pc install-includes install-shared PREFIX=$out LIBDIR=$out/lib
      runHook postInstall
    '';
    passthru.lockEntry = ze;
  };

  file = pkgs.file.overrideAttrs (o: {
    pname = "stage0-file";
    version = "${fe.version}-${fe.release}";
    src = "${fileSrpm}/file-${fe.version}.tar.gz";
    # file.spec: %autosetup -p1 over Patch0..Patch7 (there is no Patch5)
    patches = map (p: "${fileSrpm}/${p}") [
      "file-localmagic.patch"
      "file-4.17-rpm-name.patch"
      "file-5.04-volume_key.patch"
      "file-5.45-readelf-limit-revert.patch"
      "file-5.45-time-t.patch"
      "file-5.47-erofs-magic.patch"
      "file-5.47-python.patch"
    ];
    # file-localmagic.patch edits src/Makefile.am (MAGIC = /etc/magic:...);
    # file.spec runs autoreconf -fi
    nativeBuildInputs = (o.nativeBuildInputs or [ ]) ++ [ pkgs.autoreconfHook ];
    configureFlags = (o.configureFlags or [ ]) ++ [ "--enable-fsect-man5" "--disable-rpath" ];
    doCheck = false;
    passthru = (o.passthru or { }) // { lockEntry = fe; };
  });

  elfutils = (pkgs.elfutils.override { inherit zstd; enableDebuginfod = false; }).overrideAttrs (o: {
    pname = "stage0-elfutils";
    nativeBuildInputs = (o.nativeBuildInputs or [ ]) ++ [ pkgs.pkg-config ];
    doCheck = false;
    doInstallCheck = false;
  });
in
{
  inherit zstd file elfutils;
}
