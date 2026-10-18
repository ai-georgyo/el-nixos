
# el-nixos (lib/rocky/cc/map-roots.sh), appended to the cc-wrapper's setup
# hook: every input of the build (all dependency kinds, propagated ones
# included) goes into NIX_ROCKY_MAP_ROOTS, which add-prefix-map.sh maps to
# /usr (design §5.1: "-ffile-prefix-map=<input>=/usr for every input").
# Exported: rpmbuild, its scriptlets and the tool shim inherit it.
rockyAddMapRoot() {
    case " ${NIX_ROCKY_MAP_ROOTS-} " in
        *" $1 "*) ;;
        *) export NIX_ROCKY_MAP_ROOTS="${NIX_ROCKY_MAP_ROOTS:+$NIX_ROCKY_MAP_ROOTS }$1" ;;
    esac
}
addEnvHooks -1 rockyAddMapRoot
addEnvHooks 0 rockyAddMapRoot
addEnvHooks 1 rockyAddMapRoot
