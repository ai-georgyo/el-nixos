# el-nixos (lib/rocky/cc/ld-rpath-devel.sh), the bintools-wrapper's
# nix-support/ld-wrapper-hook: sourced by nixpkgs' ld-wrapper.sh after it
# added `-rpath DIR` for every -L directory holding a library named by -l
# (arrays extraAfter and libs in scope).
#
# Rocky's split puts the unversioned link (libfoo.so) into the -devel output
# and the soname (libfoo.so.N) into the -libs one: relocated, $dev/lib64/
# libfoo.so -> $lib/lib64/libfoo.so.N.  The wrapper's rule then gives the
# program RUNPATH $dev/lib64, which has no libfoo.so.N, and the program does
# not start ([WP6] nn-s1-smoke).  For every such link this adds the
# directory of its target (a store path) as well, right after.  mkRpmPackage
# builds recompute RUNPATH anyway (rocky-partition Phase E); this is for
# ordinary consumers (stdenv.mkDerivation / mkShell with buildInputs =
# [ xz.dev ]).  Nothing changes when the wrapper added no -rpath (e.g.
# NIX_DONT_SET_RPATH=1).
rockyRp=()
rockyI=0
declare -A rockySeen=()
while (( rockyI < ${#extraAfter[@]} )); do
    if [[ ${extraAfter[rockyI]} == -rpath ]] && (( rockyI + 1 < ${#extraAfter[@]} )); then
        rockySeen[${extraAfter[rockyI+1]}]=1
        rockyRp+=("${extraAfter[rockyI+1]}")
        rockyI=$((rockyI + 2))
    else
        rockyI=$((rockyI + 1))
    fi
done
for rockyD in ${rockyRp[@]+"${rockyRp[@]}"}; do
    for rockyF in ${libs[@]+"${!libs[@]}"}; do
        [[ -L $rockyD/$rockyF ]] || continue
        rockyT=$(readlink -f "$rockyD/$rockyF") || continue
        rockyT=${rockyT%/*}
        [[ $rockyT == "${NIX_STORE:-/nix/store}"/* && -z ${rockySeen[$rockyT]:-} ]] || continue
        rockySeen[$rockyT]=1
        extraAfter+=(-rpath "$rockyT")
    done
done
unset -v rockyRp rockyI rockySeen rockyD rockyF rockyT
