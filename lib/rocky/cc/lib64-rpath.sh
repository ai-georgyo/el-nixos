
# el-nixos (lib/rocky/cc/lib64-rpath.sh), appended to the bintools-wrapper's
# setup hook: the "self rpath" goes to $out/lib64 (Rocky's %_lib), not $out/lib.
# setup.sh defines _addRpathPrefix, sources the setup hooks of the inputs and
# only then calls `_addRpathPrefix "$out"`, so this definition is the one used.
# NIX_NO_SELF_RPATH=1 (a derivation attribute, read at setup time) still
# disables it (glibc: ld.so must not get DT_RPATH/DT_RUNPATH).
_addRpathPrefix() {
    if [ "${NIX_NO_SELF_RPATH:-0}" != 1 ]; then
        export NIX_LDFLAGS="-rpath $1/lib64 ${NIX_LDFLAGS-}"
    fi
}
