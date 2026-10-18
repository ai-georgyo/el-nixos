
# el-nixos (lib/rocky/cc/no-purity.sh), appended to the cc- and the
# bintools-wrapper's nix-support/utils.bash, which every wrapper script
# sources before it parses its arguments.  stdenv's setup.sh exports
# NIX_ENFORCE_PURITY=1 and Nix sets NIX_STORE, so inside any stdenv build
# (mkRpmPackage runs rpmbuild in one, the environment passes through bwrap)
# the wrappers would silently drop -I/-isystem/-L/-rpath outside the store,
# the build dir and /tmp.  In the tool shim /usr is the view of the declared
# inputs: pkg-config output (-I/usr/include/glib-2.0) and a spec's
# -L/usr/lib64 must reach gcc and ld.  (wrap { enforcePurity = true; } keeps
# nixpkgs' behaviour.)  The exported value also reaches the ld-wrapper that
# gcc's collect2 runs.
NIX_ENFORCE_PURITY=0
