#!/usr/bin/env python3
"""mkview: plan the tool shim's /usr -- a view of the declared inputs only.

Usage:
  mkview.py VIEW [--inputs "P1 P2 ..."] [--path PATH] [--collisions FILE]
            [--mountpoint REL]...

VIEW must not exist or be empty (the shim passes a fresh mktemp -d per call;
nothing is ever removed here, so a view a running namespace uses stays
intact); then (docs/nix-native-design.md §1.5):

  VIEW/bin/   a symlink to every executable entry of every PATH directory,
              first wins (PATH order = the shell's lookup order; shadowed
              names are recorded).  PATH directories named .../sbin land in
              bin/ as well: the view is usrmerged and sbin-merged.
  VIEW/plan   one line per input directory kind that exists in some input:
                <dir>\\t<src1>\\t<src2>...      (first wins = topmost)
              for dir in include lib lib64 libexec share.  The shim mounts
              each as a read-only overlayfs of its sources (a single source:
              a bind), so the view has REAL directories and files, as an FHS
              /usr has (glibc's configure refuses a symlinked
              $prefix/include/scsi; `test -L`, `find -type f`, `tar` all see
              what they would see on Rocky).
  VIEW/mnt/<dir>/...
              empty directories for --mountpoint REL (e.g. lib/rpm): added as
              the topmost source of <dir>, so the shim can bind there although
              the view is read-only.

Inputs come from --inputs, else the `rockyViewInputs` environment variable,
else `rockyViewInputs` in $NIX_ATTRS_JSON_FILE (__structuredAttrs: list
attributes are not exported to the environment).  Whitespace or ':'
separated.  An input laid out FHS-style (stage0 trees: <input>/usr/include)
contributes its usr/<dir>.

Collisions are written to --collisions as tab-separated lines
  <kind> <rel> <winner> <loser>
kind: file (two inputs, different files), file-vs-dir / dir-vs-file (the
winner's entry hides the other's whole subtree), mountpoint (hidden by a
--mountpoint), path-shadowed (a PATH name found again later; normal).
They are not errors (first wins); a summary goes to stderr.

Python 3 stdlib only; run with python3 -I.
"""
import argparse
import json
import os
import sys

INPUT_DIRS = ("include", "lib", "lib64", "libexec", "share")


def view_inputs(arg):
    if arg is not None:
        raw = arg
    elif os.environ.get("rockyViewInputs") is not None:
        raw = os.environ["rockyViewInputs"]
    elif os.environ.get("NIX_ATTRS_JSON_FILE"):
        with open(os.environ["NIX_ATTRS_JSON_FILE"]) as f:
            raw = json.load(f).get("rockyViewInputs", [])
    else:
        raw = ""
    if isinstance(raw, list):
        raw = " ".join(raw)
    return [p for p in raw.replace(":", " ").split() if p]


def path_tools(view, path, collisions):
    bindir = os.path.join(view, "bin")
    os.makedirs(bindir)
    seen = set()
    for d in path.split(":"):
        if not d or not os.path.isabs(d) or d in seen or not os.path.isdir(d):
            continue
        seen.add(d)
        for name in sorted(os.listdir(d)):
            s = os.path.join(d, name)
            if os.path.isdir(s) or not os.access(s, os.X_OK):
                continue
            dst = os.path.join(bindir, name)
            if os.path.lexists(dst):
                if os.path.realpath(dst) != os.path.realpath(s):
                    collisions.append(("path-shadowed", "bin/" + name, os.readlink(dst), s))
                continue
            os.symlink(s, dst)
    os.symlink("bin", os.path.join(view, "sbin"))


def plan_inputs(inputs):
    plan = {d: [] for d in INPUT_DIRS}
    for inp in inputs:
        for d in INPUT_DIRS:
            for base in (inp, os.path.join(inp, "usr")):
                src = os.path.join(base, d)
                if os.path.isdir(src):  # top-level dirs may be symlinks (lib64 -> usr/lib64)
                    src = os.path.realpath(src)
                    if src not in plan[d]:
                        plan[d].append(src)
                    break
    return plan


def entries(root):
    """rel -> ('d'|'f', path) for everything below root (symlinks are leaves)"""
    res = {}
    for dp, dns, fns in os.walk(root):
        for n in dns + fns:
            p = os.path.join(dp, n)
            rel = os.path.relpath(p, root)
            res[rel] = ("d" if os.path.isdir(p) and not os.path.islink(p) else "f", p)
    return res


def find_collisions(plan, collisions):
    """what overlayfs will hide (first source = topmost wins)"""
    for d, srcs in plan.items():
        if len(srcs) < 2:
            continue
        seen = {}
        for s in srcs:
            hidden = set()
            for rel, (kind, p) in sorted(entries(s).items()):
                if any(rel.startswith(h + "/") for h in hidden):
                    continue
                if rel not in seen:
                    seen[rel] = (kind, p)
                    continue
                wkind, wp = seen[rel]
                if kind == "d" and wkind == "d":
                    continue
                if kind == "f" and wkind == "f" and os.path.realpath(p) == os.path.realpath(wp):
                    continue
                k = "file" if kind == wkind else ("file-vs-dir" if wkind == "f" else "dir-vs-file")
                collisions.append((k, f"{d}/{rel}", wp, p))
                if kind == "d":
                    hidden.add(rel)


def mountpoints(view, plan, rels, collisions):
    for rel in rels:
        d, _, sub = rel.strip("/").partition("/")
        if d not in INPUT_DIRS or not sub:
            raise SystemExit(f"mkview: --mountpoint {rel}: must be <{'|'.join(INPUT_DIRS)}>/<path>")
        layer = os.path.join(view, "mnt", d)
        os.makedirs(os.path.join(layer, sub), exist_ok=True)
        for s in plan[d]:
            p = os.path.join(s, sub)
            if os.path.lexists(p):
                collisions.append(("mountpoint", rel, "(mount point)", p))
        if layer not in plan[d]:
            plan[d].insert(0, layer)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("view")
    ap.add_argument("--inputs", default=None)
    ap.add_argument("--path", default=None, help="default: $PATH")
    ap.add_argument("--collisions", default=None)
    ap.add_argument("--mountpoint", action="append", default=[])
    a = ap.parse_args()

    view = os.path.abspath(a.view)
    if os.path.lexists(view) and (not os.path.isdir(view) or os.listdir(view)):
        print(f"mkview: {view} exists and is not an empty directory", file=sys.stderr)
        return 2
    os.makedirs(view, exist_ok=True)
    collisions = []
    path_tools(view, a.path if a.path is not None else os.environ.get("PATH", ""), collisions)
    inputs = view_inputs(a.inputs)
    for inp in inputs:
        if not os.path.isdir(inp):
            print(f"mkview: input {inp} is not a directory", file=sys.stderr)
            return 2
    plan = plan_inputs(inputs)
    find_collisions(plan, collisions)
    mountpoints(view, plan, a.mountpoint, collisions)
    with open(os.path.join(view, "plan"), "w") as f:
        for d in INPUT_DIRS:
            if plan[d]:
                f.write("\t".join([d] + plan[d]) + "\n")

    if a.collisions:
        with open(a.collisions, "w") as f:
            for c in collisions:
                f.write("\t".join(c) + "\n")
    kinds = {}
    for c in collisions:
        kinds[c[0]] = kinds.get(c[0], 0) + 1
    if any(k != "path-shadowed" for k in kinds):
        summary = ", ".join(f"{n} {k}" for k, n in sorted(kinds.items()))
        print(f"mkview: {len(inputs)} inputs; collisions (first wins): {summary}"
              + (f" -> {a.collisions}" if a.collisions else ""), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
