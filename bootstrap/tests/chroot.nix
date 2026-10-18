# Tests of the chroot runner / layer machinery (lib/chroot.sh, mkBuildroot).
# Cheap: tiny layers, or one small official RPM installed on the stage0 root.
{ pkgs, lib', buildroot, officialRpms ? null }:
let
  inherit (pkgs) lib;
  runner = with pkgs; [ bubblewrap coreutils findutils gnugrep gnused gawk diffutils attr cpio bash ];
  L1 = pkgs.runCommand "chroot-test-l1" { } ''
    mkdir -p $out/usr/share/doc/foo $out/usr/share/doc/bar $out/etc
    echo old > $out/usr/share/doc/foo/README
    echo bar > $out/usr/share/doc/bar/README
  '';
  L2 = pkgs.runCommand "chroot-test-l2" { } "mkdir -p $out/etc; echo x > $out/etc/x";

  # A root phase that changes the root, then chroot_layer_out.
  #   expect = "refuse": the layer would delete/move lower content, which a
  #   store-path layer cannot represent -- chroot_layer_out must fail;
  #   expect = "accept": it must succeed (and `check` runs on the layer).
  layerOut = { name, script, expect, check ? "" }:
    pkgs.runCommand "stage0-test-chroot-${name}" { nativeBuildInputs = runner; } ''
      set -euo pipefail
      source ${lib'.chrootLib}
      chroot_setup $TMPDIR/st ${L1} ${L2}
      chroot_tools --root -- bash ${pkgs.writeText "${name}.sh" script}
      if chroot_layer_out $TMPDIR/st $TMPDIR/layer 2> $TMPDIR/err; then rc=0; else rc=$?; fi
      cat $TMPDIR/err
      mkdir -p $out
      ${if expect == "refuse" then ''
        [ $rc -ne 0 ] || { echo "chroot_layer_out ACCEPTED a layer that deletes lower content" >&2; exit 1; }
        cp $TMPDIR/err $out/refused.txt
      '' else ''
        [ $rc -eq 0 ] || { echo "chroot_layer_out refused a valid layer" >&2; exit 1; }
        layer=$TMPDIR/layer
        ${check}
        (cd $layer && find . | sort) > $out/layer.txt
      ''}
    '';

  # mkBuildroot + check on the resulting layer
  installs = { name, rpm, check }:
    let
      layer = lib'.mkBuildroot { name = "test-${name}"; base = buildroot; rpms = [ rpm ]; };
    in
    pkgs.runCommand "stage0-test-chroot-${name}" { } ''
      set -euo pipefail
      layer=${layer}
      ${check}
      mkdir $out; (cd $layer && find . | sort) > $out/layer.txt
    '';
in
{
  # a lower directory removed and recreated -> opaque dir in the upper layer
  # (the old check never fired under pipefail; the deleted README came back)
  chrootOpaque = layerOut {
    name = "opaque"; expect = "refuse";
    script = ''cd "$BUILDROOT/usr/share/doc"; rm -r foo; mkdir foo; echo new > foo/NEW'';
  };
  # a lower file deleted -> whiteout
  chrootWhiteout = layerOut {
    name = "whiteout"; expect = "refuse";
    script = ''rm "$BUILDROOT/usr/share/doc/bar/README"'';
  };
  # adding/replacing files is fine; a mode-0000 file (setup's /etc/shadow)
  # must not stop the unprivileged copy-out; symlinks to lower dirs work
  chrootAccept = layerOut {
    name = "accept"; expect = "accept";
    script = ''
      echo new > "$BUILDROOT/usr/share/doc/foo/NEW"
      echo changed > "$BUILDROOT/etc/x"
      echo secret > "$BUILDROOT/etc/gshadow"; chmod 0000 "$BUILDROOT/etc/gshadow"
      mkdir -p "$BUILDROOT/var/locked"; echo y > "$BUILDROOT/var/locked/f"; chmod 0000 "$BUILDROOT/var/locked/f" "$BUILDROOT/var/locked"
    '';
    check = ''
      [ "$(cat $layer/usr/share/doc/foo/NEW)" = new ]
      [ "$(cat $layer/etc/x)" = changed ]
      [ "$(cat $layer/etc/gshadow)" = secret ]
      [ "$(cat $layer/var/locked/f)" = y ]
      [ ! -e $layer/usr/share/doc/foo/README ]   # unchanged lower file: not in the layer
    '';
  };
} // lib.optionalAttrs (officialRpms != null) {
  # Rocky's libgcc installs /lib64/libgcc_s-*.so.1 through the usrmerge
  # symlink /lib64 -> usr/lib64 of the (store) base layer.  rpm refuses to
  # follow a directory symlink owned by nobody ("cpio: Unsafe symlink"), so
  # chroot_setup seeds such symlinks into the upper dir.
  chrootUsrmerge = installs {
    name = "usrmerge"; rpm = officialRpms."libgcc.x86_64";
    check = ''
      ls $layer/usr/lib64/libgcc_s-*.so.1
      [ ! -e $layer/lib64 ] && [ ! -L $layer/lib64 ]   # the seeded symlink is not part of the layer
    '';
  };
  # Rocky's setup ships /etc/shadow and /etc/gshadow with mode 0000
  chrootUnreadable = installs {
    name = "unreadable"; rpm = officialRpms."setup.noarch";
    check = ''
      ls -l $layer/etc/gshadow* $layer/etc/shadow*
      [ -r $layer/etc/gshadow ]
    '';
  };
}
