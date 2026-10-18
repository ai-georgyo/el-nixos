# Kernel UAPI headers as an FHS tree ($out/usr/include/{linux,asm,asm-generic,...}).
#
# Default: nixpkgs' linuxHeaders (plain `make headers_install` output, no
# store references).  Any other FHS tree with usr/include can be passed to
# bootstrap/ as `kernelHeaders` (e.g. Rocky's kernel-headers built from the
# kernel SRPM once that track lands).
{ pkgs, headers ? pkgs.linuxHeaders }:
pkgs.runCommand "stage0-kernel-headers-${headers.version or "unknown"}" { } ''
  mkdir -p $out/usr
  cp -r --no-preserve=mode ${headers}/include $out/usr/include
  # headers_install output must not point back into the store
  if grep -rl /nix/store $out; then echo "store references in kernel headers" >&2; exit 1; fi
''
