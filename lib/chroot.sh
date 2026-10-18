# shellcheck shell=bash
# chroot runner: run commands in an FHS root assembled from read-only layers
# (store paths) inside the Nix build sandbox, mock-style, without privileges.
#
# Mechanism: unprivileged user+mount namespace via bubblewrap; the root is an
# overlayfs whose lower layers are the buildroot layers (bottom -> top) and
# whose upper dir lives in $TMPDIR, so "making the root writable" costs
# nothing.  Store files appear owned by nobody (their owner is not mapped), so
# the upper dir is pre-seeded with a writable copy of every *directory* of the
# merged lower view, and with full copies of the small mutable-state trees
# (etc, var, usr/lib/sysimage) that tools rewrite in place (rpmdb, ...).
#
# Every namespace maps exactly one uid (nested user namespaces are not
# permitted on the builders), so work is split into phases that share the
# same upper dir: "root" phases (uid 0: rpm installs, setup) and "build"
# phases (uid 1000 mockbuild: rpmbuild).  Files the root phase creates are
# really owned by the sandbox uid and so show up as mockbuild in build phases.
#
# Required in PATH (outside the chroot): bwrap, coreutils, findutils, gnugrep.
#
# API (all paths absolute):
#   chroot_setup STATE LAYER...      prepare STATE/{upper,work}; layers bottom->top
#   chroot_exec  [opts] -- CMD...    run CMD with the merged root as /
#   chroot_tools [opts] -- CMD...    run CMD *outside* the root (nixpkgs world,
#                                    /nix/store visible) with the merged root
#                                    mounted rw at $BUILDROOT (STATE/mnt) -- e.g.
#                                    the stage0 rpm doing `rpm --root $BUILDROOT -i`
#   chroot_layer_out STATE OUT       write the delta (upper minus seeding) to OUT
#                                    as a new layer; fails on deletions/whiteouts
# opts:
#   --root              uid/gid 0 with all capabilities in the namespace (default)
#   --user UID GID      run as UID:GID (e.g. --user 1000 135)
#   --store             bind /nix/store read-only (stage0 only; later stages
#                       must not see the store -- leakage impossible by construction)
#   --bind SRC DST      read-write bind mount (DST inside the root)
#   --ro-bind SRC DST   read-only bind mount
#   --setenv VAR VAL    extra environment (env is cleared otherwise)
#   --hostname NAME     hostname inside (default: localhost)
#   --chdir DIR         working directory inside (default: /)

chroot__state=""
chroot__layers=()

chroot__lowers() {
  local l
  for l in "${chroot__layers[@]}"; do printf '%s\0%s\0' --overlay-src "$l"; done
}

# bwrap args mounting the merged read-only view of the lowers at $1
# (--ro-overlay needs >= 2 sources; a single layer is just bind-mounted)
chroot__merged_ro() {
  if [ "${#chroot__layers[@]}" -eq 1 ]; then
    printf '%s\0%s\0%s\0' --ro-bind "${chroot__layers[0]}" "$1"
  else
    chroot__lowers
    printf '%s\0%s\0' --ro-overlay "$1"
  fi
}

# An overlay's upper/work dirs stay "in use" until the previous namespace's
# superblock is torn down, which the kernel may finish only after that bwrap
# exited.
# (Observed on the builders: the 2nd overlay mount on the same upper/work,
# right after the 1st bwrap exited, fails with "Device or resource busy".)
# overlayfs locks only the upper and work *directory inodes*, so before each
# rw mount we move the upper's entries into a fresh directory (renames, cheap)
# and use a fresh work dir: a lingering superblock can never conflict.
chroot__n=0
chroot__fresh_dirs() {
  local st=$chroot__state
  chroot__n=$((chroot__n + 1))
  local new=$st/upper.$chroot__n
  mkdir "$new"
  chmod --reference="$st/upper" "$new"
  find "$st/upper" -mindepth 1 -maxdepth 1 -exec mv -t "$new" {} +
  rmdir "$st/upper"
  mv "$new" "$st/upper"
  # old work dirs contain an overlay-made 000 dir; remove best-effort
  chmod -R u+rwx "$st/work" 2>/dev/null || true
  rm -rf "$st/work" 2>/dev/null || mv "$st/work" "$st/work.old.$chroot__n"
  mkdir "$st/work"
}
chroot__bwrap() { bwrap "$@"; }

# run "bash -c SCRIPT _ ARGS..." with the merged read-only lower view at STATE/merged
chroot__in_merged() {
  local -a ro
  mapfile -d '' ro < <(chroot__merged_ro "$chroot__state/merged")
  chroot__bwrap --unshare-user --bind / / "${ro[@]}" bash -c "$@"
}

chroot_setup() {
  chroot__state=$1; shift
  chroot__layers=("$@")
  local st=$chroot__state
  mkdir -p "$st/upper" "$st/work" "$st/merged"
  # One pass over the merged lower view:
  #  - writable directory skeleton (store dirs are 0555 -> make them u+w)
  #  - eager copies of the trees that tools rewrite in place
  chroot__in_merged '
    set -euo pipefail
    m=$1 up=$2
    find "$m" -mindepth 1 -type d -printf "%m %P\0" > "$up/../dirs.list"
    while IFS= read -r -d "" line; do
      mode=${line%% *}; path=${line#* }
      mkdir -p "$up/$path"
      chmod "$(printf "%o" $(( 0$mode | 0200 )))" "$up/$path"
    done < "$up/../dirs.list"
    for d in etc var usr/lib/sysimage; do
      if [ -d "$m/$d" ] && [ ! -L "$m/$d" ]; then
        cp -a --no-preserve=ownership "$m/$d/." "$up/$d/"
        chmod -R u+w "$up/$d"
      fi
    done
  ' _ "$st/merged" "$st/upper"
  # remember what we seeded, to compute layer deltas later
  (cd "$st/upper" && find . -mindepth 1 -printf '%P\0') > "$st/seeded.list"
}

# parse common opts into chroot__args (bwrap args) and chroot__cmd
chroot__parse() {
  chroot__args=(); chroot__env=(); chroot__cmd=()
  chroot__uid=0; chroot__gid=0; chroot__host=localhost; chroot__cwd=/; chroot__store=0
  local -a binds=()
  while [ $# -gt 0 ]; do
    case $1 in
      --root) chroot__uid=0; chroot__gid=0; shift ;;
      --user) chroot__uid=$2; chroot__gid=$3; shift 3 ;;
      --store) chroot__store=1; shift ;;
      --bind) binds+=(--bind "$2" "$3"); shift 3 ;;
      --ro-bind) binds+=(--ro-bind "$2" "$3"); shift 3 ;;
      --setenv) chroot__env+=(--setenv "$2" "$3"); shift 3 ;;
      --hostname) chroot__host=$2; shift 2 ;;
      --chdir) chroot__cwd=$2; shift 2 ;;
      --) shift; break ;;
      *) echo "chroot: unknown option $1" >&2; return 1 ;;
    esac
  done
  chroot__cmd=("$@")
  chroot__args=(--unshare-user --uid "$chroot__uid" --gid "$chroot__gid"
    --unshare-pid --unshare-ipc --unshare-uts --unshare-net --unshare-cgroup-try
    --hostname "$chroot__host" --die-with-parent)
  if [ "$chroot__uid" = 0 ]; then chroot__args+=(--cap-add ALL); fi
  chroot__binds=("${binds[@]}")
}

chroot__env_default() {
  # mock's environment
  printf '%s\0' --clearenv \
    --setenv PATH /usr/bin:/bin:/usr/sbin:/sbin --setenv HOME "${1:-/root}" \
    --setenv TERM vt100 --setenv SHELL /bin/bash --setenv LANG C.UTF-8 \
    --setenv HOSTNAME "$chroot__host" --setenv TZ UTC
}

chroot_exec() {
  chroot__parse "$@" || return 1
  chroot__fresh_dirs
  local st=$chroot__state home=/root
  [ "$chroot__uid" != 0 ] && home=/builddir
  local -a lowers envs
  mapfile -d '' lowers < <(chroot__lowers)
  mapfile -d '' envs < <(chroot__env_default "$home")
  local -a store=()
  [ "$chroot__store" = 1 ] && store=(--ro-bind /nix/store /nix/store)
  chroot__bwrap "${chroot__args[@]}" \
    "${lowers[@]}" --overlay "$st/upper" "$st/work" / \
    "${store[@]}" \
    --proc /proc --dev /dev --perms 1777 --tmpfs /dev/shm \
    --perms 1777 --tmpfs /tmp --perms 1777 --tmpfs /var/tmp \
    "${chroot__binds[@]}" \
    "${envs[@]}" "${chroot__env[@]}" \
    --chdir "$chroot__cwd" \
    "${chroot__cmd[@]}"
}

chroot_tools() {
  chroot__parse "$@" || return 1
  chroot__fresh_dirs
  local st=$chroot__state
  local -a lowers
  mapfile -d '' lowers < <(chroot__lowers)
  mkdir -p "$st/mnt"
  # the outer sandbox filesystem (nixpkgs tools, $TMPDIR, $out) stays as is;
  # the merged root appears rw at $BUILDROOT (= STATE/mnt)
  chroot__bwrap "${chroot__args[@]}" --bind / / \
    "${lowers[@]}" --overlay "$st/upper" "$st/work" "$st/mnt" \
    --proc "$st/mnt/proc" --dev "$st/mnt/dev" \
    "${chroot__binds[@]}" "${chroot__env[@]}" --setenv BUILDROOT "$st/mnt" \
    --chdir "$chroot__cwd" \
    "${chroot__cmd[@]}"
}

chroot_layer_out() {
  local st=$1 out=$2
  local up=$st/upper
  # overlayfs whiteouts (char 0/0) / opaque dirs mean the layer deletes lower
  # content -- cannot be represented as a store-path layer
  local wh
  wh=$(find "$up" -type c -print -quit)
  if [ -n "$wh" ]; then
    echo "chroot_layer_out: layer deletes files from lower layers (whiteout at ${wh#"$up"}); unsupported" >&2
    return 1
  fi
  if command -v getfattr >/dev/null; then
    if getfattr -R --absolute-names -n user.overlay.opaque "$up" 2>/dev/null | grep -q opaque; then
      echo "chroot_layer_out: opaque directory in upper layer; unsupported" >&2
      return 1
    fi
  fi
  # mount points bwrap may have created
  rmdir "$up/nix/store" "$up/nix" 2>/dev/null || true
  # rpmdb: all data must be checkpointed into rpmdb.sqlite; drop wal/shm so
  # layers never combine one layer's db with another layer's WAL
  local db=$up/usr/lib/sysimage/rpm
  if [ -s "$db/rpmdb.sqlite-wal" ]; then
    echo "chroot_layer_out: rpmdb has an un-checkpointed WAL" >&2; return 1
  fi
  rm -f "$db/rpmdb.sqlite-wal" "$db/rpmdb.sqlite-shm"
  # drop seeded files that are byte-identical to the lower view
  chroot__in_merged '
      cd "$1"
      while IFS= read -r -d "" p; do
        if [ -f "$p" ] && [ ! -L "$p" ] && [ -f "$2/$p" ] && cmp -s "$p" "$2/$p"; then rm -f "$p"; fi
        if [ -L "$p" ] && [ -L "$2/$p" ] && [ "$(readlink "$p")" = "$(readlink "$2/$p")" ]; then rm -f "$p"; fi
      done < "$3"
    ' _ "$up" "$st/merged" "$st/seeded.list"
  # drop empty seeded directories (deepest first)
  local p
  while IFS= read -r -d '' p; do
    rmdir "$up/$p" 2>/dev/null || true
  done < <(sort -z -r "$st/seeded.list")
  mkdir -p "$out"
  cp -a --no-preserve=ownership "$up/." "$out/"
}
