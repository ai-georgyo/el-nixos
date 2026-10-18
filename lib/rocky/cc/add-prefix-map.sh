# el-nixos cc-wrapper hook (lib/rocky/cc/add-prefix-map.sh), installed as
# nix-support/cc-wrapper-hook: nixpkgs' cc-wrapper.sh sources it right before
# it runs the compiler, with the arrays extraBefore, params and extraAfter in
# scope (and `set -eu`).  Design §5.1, experiment E1.
#
# 1. -ffile-prefix-map=<root>=/usr for the gcc prefix and for every store
#    directory named as an include directory (-I -iquote -isystem -idirafter
#    -cxx-isystem, joined or separate; whether the wrapper, a setup hook,
#    pkg-config or the build system put it there).  DWARF file names and
#    __FILE__ then read /usr/include/..., /usr/lib/gcc/... as on Rocky, and no
#    input store path ends up in what the compiler writes.  An FHS-in-store
#    tree (<root>/usr/include) maps <root>/usr.  Those maps come after the
#    plain <root> ones: gcc applies the last matching map.
# 2. -frandom-seed=* injected through the environment (nixpkgs'
#    reproducible-builds.sh puts -frandom-seed=<out hash part> into
#    NIX_CFLAGS_COMPILE; under Rocky's -grecord-gcc-switches it lands in
#    DW_AT_producer) is dropped.  A -frandom-seed the build passes itself
#    (params) is kept: Rocky's compiler would see it too.
#
# The maps go first (extraBefore), so maps the build passes itself win where
# they overlap.  Nothing is added without a non-flag argument (`gcc -v`,
# `gcc --version`: configure probes stay byte-identical).

rockyMaps=("-ffile-prefix-map=@gcc@=/usr")
rockyUsrMaps=()
declare -A rockyMapped=([@gcc@]=1)

rockyAddMap() {
    local d=$1 r
    [[ $d == @storeDir@/?* ]] || return 0
    r=${d#@storeDir@/}
    r=@storeDir@/${r%%/*}
    if [[ $d == "$r"/usr/include || $d == "$r"/usr/include/* ]]; then
        r=$r/usr
    fi
    [[ -z ${rockyMapped[$r]:-} ]] || return 0
    rockyMapped[$r]=1
    if [[ $r == */usr ]]; then
        rockyUsrMaps+=("-ffile-prefix-map=$r=/usr")
    else
        rockyMaps+=("-ffile-prefix-map=$r=/usr")
    fi
}

rockyScanIncludes() {
    local prev= p
    for p in "$@"; do
        case $prev in
            -I | -iquote | -isystem | -idirafter | -cxx-isystem) rockyAddMap "$p" ;;
        esac
        case $p in
            -I?*) rockyAddMap "${p:2}" ;;
            -iquote?*) rockyAddMap "${p:7}" ;;
            -isystem?*) rockyAddMap "${p:8}" ;;
            -idirafter?*) rockyAddMap "${p:10}" ;;
            -cxx-isystem?*) rockyAddMap "${p:12}" ;;
        esac
        prev=$p
    done
}

rockyDropSeed() {
    local -n rockyArr=$1
    local -a kept=()
    local x
    for x in ${rockyArr[@]+"${rockyArr[@]}"}; do
        [[ $x == -frandom-seed=* ]] || kept+=("$x")
    done
    rockyArr=(${kept[@]+"${kept[@]}"})
}

rockyDropSeed extraBefore
rockyDropSeed extraAfter

if [[ "${nonFlagArgs:-0}" = 1 && "${cc1:-0}" != 1 ]]; then
    rockyScanIncludes ${extraBefore+"${extraBefore[@]}"} ${params+"${params[@]}"} ${extraAfter+"${extraAfter[@]}"}
    extraBefore=("${rockyMaps[@]}" ${rockyUsrMaps[@]+"${rockyUsrMaps[@]}"} ${extraBefore+"${extraBefore[@]}"})
fi

unset -f rockyAddMap rockyScanIncludes rockyDropSeed
unset -v rockyMaps rockyUsrMaps rockyMapped
