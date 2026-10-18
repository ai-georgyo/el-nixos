# shellcheck shell=bash
# tool shim: run a command (rpmbuild) in a namespace whose /usr is a view of
# the derivation's DECLARED inputs only (docs/nix-native-design.md §1.5,
# §5.4).  Installed by lib/rocky/parts/toolShim.nix as an executable with
# @bash@ @bwrap@ @coreutils@ @python3@ @mkview@ substituted:
#
#   ${nn.toolShim} [--[no-]prefix-view] -- CMD...
#
# Namespace (bubblewrap; the sandbox root is read-only, so bwrap's own tmpfs
# root, as in lib/chroot.sh):
#   /nix, $NIX_BUILD_TOP (and $TMPDIR, $PWD if outside it)   rw binds
#   /etc /proc /dev                                          sandbox's
#   /tmp                                                     fresh tmpfs
#   /usr       = the view, read-only (mkview.py):
#                  bin/     symlinks to the PATH tools (first wins); sbin -> bin
#                  include/ lib/ lib64/ libexec/ share/
#                           read-only overlayfs of the inputs' dirs (first wins;
#                           a single input: a bind) -- real directories and
#                           files, as an FHS /usr has
#   /bin /sbin -> usr/bin
#   /usr/lib/rpm = $RPM_CONFIG_DIR, if set (the assembled rpm config)
#   $out       = the same view again, read-only, if ROCKY_PREFIX_VIEW=1
#                ("self-prefix alias": %{_includedir}/foo used as "where my
#                build deps live" resolves into the inputs).  Mounted on a
#                tmpfs over $out, which must not exist or be an empty
#                directory; it is an empty directory afterwards (the alias
#                lives only in the namespace, which ends with CMD).
#                ROCKY_PREFIX_VIEW_DIRS limits which input dirs the alias
#                shows (bin/ always): e.g. "include share" keeps
#                -L%{_libdir} from resolving libraries into the view
#                (docs/research/nix-native/experiments/E2.md, library hazard).
#
# Environment:
#   rockyViewInputs      store paths of the declared inputs (whitespace/':'
#                        separated; with __structuredAttrs read from
#                        $NIX_ATTRS_JSON_FILE instead)
#   RPM_CONFIG_DIR       optional rpm config dir for /usr/lib/rpm
#   ROCKY_PREFIX_VIEW    1 = the view at $out as well (needs $out)
#   ROCKY_PREFIX_VIEW_DIRS  input dirs shown at $out (default: all of
#                        include lib lib64 libexec share)
#   ROCKY_VIEW_COLLISIONS  write the collision report to this file (else only
#                        a summary on stderr)
# The view is planned afresh on every call (PATH may have changed) in a
# directory of its own below the build top, removed when the call ends, so
# nested and concurrent calls do not disturb each other.  The environment is
# passed through unchanged (PATH stays the store PATH; callers wanting FHS
# interpreter paths recorded run `env PATH=/usr/bin ...`), except that
# ROCKY_PREFIX_VIEW and ROCKY_VIEW_COLLISIONS are unset inside: a nested
# call (its $out is the read-only alias) neither re-aliases nor overwrites
# the caller's report unless it asks for that itself.
set -euo pipefail

prefix_view=${ROCKY_PREFIX_VIEW:-0}
while [ $# -gt 0 ]; do
  case $1 in
    --no-prefix-view) prefix_view=0; shift ;;
    --prefix-view) prefix_view=1; shift ;;
    --) shift; break ;;
    *) echo "tool-shim: unknown option $1 (usage: tool-shim [--[no-]prefix-view] -- CMD...)" >&2; exit 2 ;;
  esac
done
[ $# -gt 0 ] || { echo "tool-shim: no command" >&2; exit 2; }

top=${NIX_BUILD_TOP:-${TMPDIR:-/tmp}}
alias_dirs=" ${ROCKY_PREFIX_VIEW_DIRS:-include lib lib64 libexec share} "
view=$(@coreutils@/bin/mktemp -d "$top/rocky-view.XXXXXX")
trap '@coreutils@/bin/rm -rf "$view"' EXIT

mkview_args=()
[ -n "${RPM_CONFIG_DIR:-}" ] && mkview_args+=(--mountpoint lib/rpm)
[ -n "${ROCKY_VIEW_COLLISIONS:-}" ] && mkview_args+=(--collisions "$ROCKY_VIEW_COLLISIONS")
@python3@ -I @mkview@ "$view" "${mkview_args[@]}"

# bwrap args (NUL-separated) mounting the view at $1, read-only when done
view_args() {
  local dst=$1 d line i
  local -a srcs
  printf '%s\0' --tmpfs "$dst" --ro-bind "$view/bin" "$dst/bin" --symlink bin "$dst/sbin"
  while IFS= read -r line; do
    IFS=$'\t' read -ra srcs <<< "$line"
    d=${srcs[0]}
    srcs=("${srcs[@]:1}")
    [ "$dst" = /usr ] || [[ $alias_dirs == *" $d "* ]] || continue
    if [ ${#srcs[@]} -eq 1 ]; then
      printf '%s\0' --ro-bind "${srcs[0]}" "$dst/$d"
    else
      # overlayfs: the first --overlay-src is the bottom layer, so the plan's
      # first-wins order goes in reversed
      for ((i = ${#srcs[@]} - 1; i >= 0; i--)); do printf '%s\0' --overlay-src "${srcs[i]}"; done
      printf '%s\0' --ro-overlay "$dst/$d"
    fi
  done < "$view/plan"
  if [ "$dst" = /usr ] && [ -n "${RPM_CONFIG_DIR:-}" ]; then
    printf '%s\0' --ro-bind "$RPM_CONFIG_DIR" /usr/lib/rpm
  fi
  printf '%s\0' --remount-ro "$dst"
}

args=(--die-with-parent
  --bind /nix /nix
  --perms 1777 --tmpfs /tmp
  --bind "$top" "$top")
# TMPDIR / the working directory, if they are not below the build top (and
# not /: binding it would undo the tmpfs root; --chdir / works as is)
for d in "${TMPDIR:-}" "$PWD"; do
  case $d in ""|/|"$top"|"$top"/*|/nix|/nix/*) ;; *) args+=(--bind "$d" "$d") ;; esac
done
args+=(--unsetenv ROCKY_PREFIX_VIEW --unsetenv ROCKY_VIEW_COLLISIONS
  --ro-bind /etc /etc --proc /proc --dev /dev
  --symlink usr/bin /bin --symlink usr/bin /sbin)
mapfile -d '' -O "${#args[@]}" args < <(view_args /usr)

if [ "$prefix_view" = 1 ]; then
  : "${out:?tool-shim: ROCKY_PREFIX_VIEW=1 needs \$out}"
  @coreutils@/bin/mkdir -p "$out"
  if [ -n "$(@coreutils@/bin/ls -A "$out")" ]; then
    echo "tool-shim: \$out ($out) must be empty for the self-prefix alias" >&2; exit 1
  fi
  mapfile -d '' -O "${#args[@]}" args < <(view_args "$out")
fi
args+=(--chdir "$PWD")

# The Nix sandbox starts builders with SIGPIPE ignored, and an ignored
# disposition survives exec; rpmbuild scriptlets (`... | head`) need the
# default (lib/chroot.sh, chroot__bwrap).
set +e
@coreutils@/bin/env --default-signal=PIPE @bwrap@ "${args[@]}" -- "$@"
rc=$?
set -e

if [ "$prefix_view" = 1 ] && [ -n "$(@coreutils@/bin/ls -A "$out")" ]; then
  echo "tool-shim: \$out ($out) is not empty after the command (wrote through the alias?)" >&2
  [ $rc -ne 0 ] || rc=1
fi
exit $rc
