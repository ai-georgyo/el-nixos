# el-nixos cc-wrapper hook (lib/rocky/cc/add-prefix-map.sh), installed as
# nix-support/cc-wrapper-hook: nixpkgs' cc-wrapper.sh sources it right before
# it runs the compiler, with the arrays extraBefore, params and extraAfter in
# scope (and `set -eu`, PATH = coreutils + grep).  Design §5.1, experiment E1.
#
# 1. -ffile-prefix-map=<root>=/usr for the gcc prefix and for every store
#    path root that a compiled file name can start with, so that DWARF file
#    names and __FILE__ read /usr/include/..., /usr/lib/gcc/... as on Rocky
#    and no input store path ends up in what the compiler writes:
#    a. every root in NIX_ROCKY_MAP_ROOTS (whitespace-separated; the
#       wrapper's setup hook map-roots.sh puts every input of a stdenv build
#       there, and anyone may add more): the declared inputs, whatever way a
#       header of theirs is reached (-include, #include "/nix/store/...");
#    b. every store directory named as an include directory (-I -iquote
#       -isystem -idirafter -cxx-isystem, joined or separate; whether the
#       wrapper, a setup hook, pkg-config or the build system put it there),
#       every -include/-imacros file and every source file in the store;
#    c. for a system include directory (-isystem -idirafter -cxx-isystem):
#       the roots that the symlinks under its root resolve to.  gcc names a
#       header found in a system directory by its realpath whenever that is
#       shorter (-fcanonical-system-headers, libcpp maybe_shorter_path), so a
#       symlink farm (cp -rs, lndir, symlinkJoin, buildEnv) would put its
#       targets' store paths into the DWARF.  Store paths are immutable:
#       each root is walked once per build and the result cached in
#       $TMPDIR/.rocky-cc-linkroots/<root name> (no cache without a writable
#       TMPDIR).  Writable roots (the build's own outputs) are not walked.
#    A path in an FHS-in-store tree (<root>/usr/include...) maps <root>/usr;
#    those maps come after the plain <root> ones: gcc applies the last
#    matching map.
# 2. -frandom-seed=* injected through the environment (nixpkgs'
#    reproducible-builds.sh puts -frandom-seed=<out hash part> into
#    NIX_CFLAGS_COMPILE; under Rocky's -grecord-gcc-switches it lands in
#    DW_AT_producer) is dropped.  A -frandom-seed the build passes itself
#    (params) is kept: Rocky's compiler would see it too.
#
# The maps go first (extraBefore), so maps the build passes itself win where
# they overlap.  gcc records neither the maps nor include flags in
# DW_AT_producer.  Nothing is added without a non-flag argument (`gcc -v`,
# `gcc --version`, `gcc -print-file-name=...`: configure probes stay
# byte-identical).

rockyMaps=("-ffile-prefix-map=@gcc@=/usr")
rockyUsrMaps=()
declare -A rockyMapped=([@gcc@]=1) rockyWalked=()

# rockyAddMap PATH: map the store root of PATH (<root>/usr for a path in an
# FHS-in-store tree's usr/include)
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

# rockyLinkKeys ROOT: prints, NUL-separated, one path per store root (or
# <root>/usr/include) that a symlink under ROOT (or ROOT itself) resolves to
rockyLinkKeys() {
    local r=$1 f k i
    local -a links=() targets=()
    local -A seen=()
    [[ ! -L $r ]] || links+=("$r")
    shopt -s globstar dotglob nullglob
    for f in "$r"/**; do
        if [[ -L $f ]]; then links+=("$f"); fi
    done
    for ((i = 0; i < ${#links[@]}; i += 1000)); do
        mapfile -d '' -O "${#targets[@]}" targets < <(realpath -zqe -- "${links[@]:i:1000}" || true)
    done
    for f in ${targets[@]+"${targets[@]}"}; do
        [[ $f == @storeDir@/?* ]] || continue
        k=${f#@storeDir@/}
        k=@storeDir@/${k%%/*}
        if [[ $f == "$k"/usr/include || $f == "$k"/usr/include/* ]]; then k=$k/usr/include; fi
        [[ -n ${seen[$k]:-} ]] || { seen[$k]=1; printf '%s\0' "$k"; }
    done
}

# rockyAddLinkTargets DIR: DIR is a system include directory (1c)
rockyAddLinkTargets() {
    local d=$1 n r cache k
    local -a keys=()
    [[ $d == @storeDir@/?* ]] || return 0
    n=${d#@storeDir@/}
    n=${n%%/*}
    r=@storeDir@/$n
    [[ -z ${rockyWalked[$r]:-} && $r != @gcc@ && -e $r && ! -w $r ]] || return 0
    rockyWalked[$r]=1
    cache=
    if [[ -n ${TMPDIR:-} && -d $TMPDIR && -w $TMPDIR ]]; then
        cache=$TMPDIR/.rocky-cc-linkroots/$n
    fi
    if [[ -n $cache && -f $cache ]]; then
        mapfile -d '' keys < "$cache"
    else
        mapfile -d '' keys < <(rockyLinkKeys "$r")
        if [[ -n $cache ]]; then
            # atomic: parallel compiles may walk the same root at once
            if mkdir -p "${cache%/*}" 2>/dev/null &&
                { printf '%s\0' ${keys[@]+"${keys[@]}"} > "$cache.$$"; } 2>/dev/null; then
                mv -f "$cache.$$" "$cache" 2>/dev/null || :
            fi
        fi
    fi
    for k in ${keys[@]+"${keys[@]}"}; do rockyAddMap "$k"; done
}

rockyScanArgs() {
    local prev= p
    for p in "$@"; do
        case $prev in
            -I | -iquote | -include | -imacros) rockyAddMap "$p" ;;
            -isystem | -idirafter | -cxx-isystem) rockyAddMap "$p"; rockyAddLinkTargets "$p" ;;
        esac
        case $p in
            -I?*) rockyAddMap "${p:2}" ;;
            -iquote?*) rockyAddMap "${p:7}" ;;
            -isystem?*) rockyAddMap "${p:8}"; rockyAddLinkTargets "${p:8}" ;;
            -idirafter?*) rockyAddMap "${p:10}"; rockyAddLinkTargets "${p:10}" ;;
            -cxx-isystem?*) rockyAddMap "${p:12}"; rockyAddLinkTargets "${p:12}" ;;
            -include?*) rockyAddMap "${p:8}" ;;
            -imacros?*) rockyAddMap "${p:8}" ;;
            # a source file in the store (not an output named by -o)
            @storeDir@/*.[cCsSi] | @storeDir@/*.cc | @storeDir@/*.cp | @storeDir@/*.cxx | \
            @storeDir@/*.cpp | @storeDir@/*.c++ | @storeDir@/*.ii | @storeDir@/*.h | \
            @storeDir@/*.hh | @storeDir@/*.hpp | @storeDir@/*.sx)
                [[ $prev == -o ]] || rockyAddMap "$p" ;;
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
    for rockyR in ${NIX_ROCKY_MAP_ROOTS-}; do
        rockyAddMap "$rockyR"
        if [[ -d $rockyR/usr/include ]]; then rockyAddMap "$rockyR/usr/include"; fi
    done
    rockyScanArgs ${extraBefore+"${extraBefore[@]}"} ${params+"${params[@]}"} ${extraAfter+"${extraAfter[@]}"}
    extraBefore=("${rockyMaps[@]}" ${rockyUsrMaps[@]+"${rockyUsrMaps[@]}"} ${extraBefore+"${extraBefore[@]}"})
fi

unset -f rockyAddMap rockyLinkKeys rockyAddLinkTargets rockyScanArgs rockyDropSeed
unset -v rockyMaps rockyUsrMaps rockyMapped rockyWalked rockyR
