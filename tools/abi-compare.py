#!/usr/bin/env python3
"""abi-compare: compare the ABI of extracted package trees with binutils.

Usage:
  abi-compare.py --pair NAME OURS_DIR OFFICIAL_DIR [--pair ...]
                 [--allow FILE] [--out DIR]

An independent cross-check of rpm-parity's built-in ELF reader: everything
here comes from GNU binutils (`readelf`, `nm`, `ar` in PATH).  For each pair
of trees (one package: our payload vs the official payload):

  ELF shared objects / executables (any regular ELF file not ET_REL):
    abi.dynsym     `readelf --dyn-syms -W`: name@version, type, binding,
                   visibility, defined/undefined (section class), size --
                   addresses are layout, not ABI, and are left out
    abi.versions   `readelf -V -W`: version definitions, needed versions and
                   the symbol version table (addresses/offsets stripped)
    abi.dynamic    `readelf -d -W`: NEEDED, SONAME, RPATH, RUNPATH, FLAGS,
                   FLAGS_1, VERDEFNUM, VERNEEDNUM, ...
  relocatable objects (crt1.o, ...) and static archives:
    abi.members    `ar t`: member names in order
    abi.symbols    `nm -A -g -P`: every external symbol of every member
                   (defined with type, and undefined), values left out
  headers:
    abi.header     every file under /usr/include: byte-identical (sha256)
  files of these kinds present on one side only: abi.only-ours / abi.only-official

Differences are matched against the allowlist (JSON: {"allow": [{"id": glob
or [globs], "packages": glob, "reason": "..."}]}).  Exit 0 = PASS, 1 = FAIL
(unexpected differences), 2 = error.  report.txt / report.json in --out.
"""
import argparse
import difflib
import fnmatch
import hashlib
import json
import os
import re
import subprocess
import sys

ADDR_TAGS_KEEP = {"NEEDED", "SONAME", "RPATH", "RUNPATH", "FLAGS", "FLAGS_1", "BIND_NOW", "TEXTREL",
                  "SYMBOLIC", "VERDEFNUM", "VERNEEDNUM", "AUXILIARY", "FILTER", "AUDIT", "DEPAUDIT"}


def run(*cmd):
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode != 0:  # (nm's "no symbols" notes go to stderr with status 0)
        raise RuntimeError("%s failed: %s" % (" ".join(cmd), p.stderr.decode(errors="replace")[:500]))
    return p.stdout.decode("utf-8", "replace")


def elf_type(path):
    with open(path, "rb") as f:
        h = f.read(18)
    if h[:4] != b"\x7fELF":
        return None
    return int.from_bytes(h[16:18], "little" if h[5] == 1 else "big")


def dynsyms(path):
    out = []
    for line in run("readelf", "--dyn-syms", "-W", path).splitlines():
        m = re.match(r"\s*\d+:\s+[0-9a-f]+\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s*(.*)$", line)
        if not m:
            continue
        size, typ, bind, vis, ndx, name = m.groups()
        name = re.sub(r" \(\d+\)$", "", name.strip())
        if not name and typ == "NOTYPE" and ndx == "UND":
            continue  # entry 0
        cls = ndx if ndx in ("UND", "ABS", "COM") else "DEF"
        out.append("%s %s %s %s %s %s" % (name, typ, bind, vis, cls, size))
    return sorted(out)


def versions(path):
    out = []
    for line in run("readelf", "-V", "-W", path).splitlines():
        line = re.sub(r"Addr: 0x[0-9a-f]+\s*", "", line)
        line = re.sub(r"Offset: 0x[0-9a-f]+\s*", "", line)
        line = re.sub(r"^\s*0x[0-9a-f]+:\s*", "  ", line)  # entry offsets inside the section
        if line.strip():
            out.append(line.rstrip())
    return out


def dynamic(path):
    out = []
    for line in run("readelf", "-d", "-W", path).splitlines():
        m = re.match(r"\s*0x[0-9a-f]+\s+\((\w+)\)\s+(.*)$", line)
        if m and m.group(1) in ADDR_TAGS_KEEP:
            out.append("%s %s" % (m.group(1), m.group(2).strip()))
    return out


def ar_members(path):
    return run("ar", "t", path).splitlines()


def ext_symbols(path):
    out = []
    for line in run("nm", "-A", "-g", "-P", path).splitlines():
        # "archive[member]: name type value size" / "file: name type ..."
        m = re.match(r"(.*?): (\S+) (\S)(?: \S+)?(?: \S+)?$", line.rstrip())
        if not m:
            continue
        where, name, typ = m.groups()
        where = re.sub(r"^.*\[(.*)\]$", r"\1", where) if "[" in where else ""
        out.append("%s %s %s" % (where, name, "U" if typ == "U" else typ))
    return sorted(out)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def classify(root):
    """relpath -> kind for the files this tool compares"""
    kinds = {}
    for d, dirs, files in os.walk(root):
        dirs.sort()
        for fn in files:
            p = os.path.join(d, fn)
            if os.path.islink(p) or not os.path.isfile(p):
                continue
            rel = "/" + os.path.relpath(p, root)
            if rel.startswith("/usr/lib/debug/"):
                continue
            t = elf_type(p)
            if t is not None:
                kinds[rel] = "rel" if t == 1 else "elf"
                continue
            with open(p, "rb") as f:
                if f.read(8) == b"!<arch>\n":
                    kinds[rel] = "ar"
                    continue
            if rel.startswith("/usr/include/"):
                kinds[rel] = "header"
    return kinds


class Allow:
    def __init__(self, paths):
        self.rules = []
        for p in paths:
            with open(p) as f:
                for r in json.load(f).get("allow", []):
                    if "id" not in r or "reason" not in r:
                        raise SystemExit("abi-compare: %s: rule needs id and reason" % p)
                    self.rules.append(dict(r, _hits=0))

    def match(self, pkg, did):
        for r in self.rules:
            ids = [r["id"]] if isinstance(r["id"], str) else r["id"]
            if any(fnmatch.fnmatchcase(did, i) for i in ids) and fnmatch.fnmatchcase(pkg, r.get("packages", "*")):
                r["_hits"] += 1
                return r
        return None


def compare_pair(name, ours, off, allow, stats):
    diffs = []

    def diff(did, a, b):
        ud = list(difflib.unified_diff(b, a, "official", "ours", lineterm="", n=1)) \
            if isinstance(a, list) and isinstance(b, list) else None
        r = allow.match(name, did)
        diffs.append({"id": did, "allowed": r is not None, "reason": r["reason"] if r else None,
                      "diff": ud[:200] if ud else None, "ours": None if ud else a, "official": None if ud else b})

    ko, kf = classify(ours), classify(off)
    for p in sorted(set(ko) - set(kf)):
        diff("abi.only-ours:" + p, ko[p], None)
    for p in sorted(set(kf) - set(ko)):
        diff("abi.only-official:" + p, None, kf[p])
    for p in sorted(set(ko) & set(kf)):
        a, b = os.path.join(ours, p[1:]), os.path.join(off, p[1:])
        k = ko[p] if ko[p] == kf[p] else None
        if k is None:
            diff("abi.kind:" + p, ko[p], kf[p])
            continue
        stats[k] = stats.get(k, 0) + 1
        if k == "elf":
            for fact, fn in (("dynsym", dynsyms), ("versions", versions), ("dynamic", dynamic)):
                va, vb = fn(a), fn(b)
                if fact == "dynsym":
                    stats["dynsyms"] = stats.get("dynsyms", 0) + len(va)
                if va != vb:
                    diff("abi.%s:%s" % (fact, p), va, vb)
        elif k in ("rel", "ar"):
            if k == "ar":
                ma, mb = ar_members(a), ar_members(b)
                stats["ar_members"] = stats.get("ar_members", 0) + len(ma)
                if ma != mb:
                    diff("abi.members:" + p, ma, mb)
            sa, sb = ext_symbols(a), ext_symbols(b)
            stats["static_symbols"] = stats.get("static_symbols", 0) + len(sa)
            if sa != sb:
                diff("abi.symbols:" + p, sa, sb)
        elif k == "header":
            if sha256(a) != sha256(b):
                diff("abi.header:" + p, sha256(a)[:16], sha256(b)[:16])
    return diffs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pair", nargs=3, action="append", metavar=("NAME", "OURS", "OFFICIAL"), required=True)
    ap.add_argument("--allow", action="append", default=[])
    ap.add_argument("--out", default=".")
    a = ap.parse_args()
    allow = Allow(a.allow)
    stats, report = {"packages": 0}, []
    for name, ours, off in a.pair:
        for d in (ours, off):
            if not os.path.isdir(d):
                raise SystemExit("abi-compare: not a directory: %s" % d)
        stats["packages"] += 1
        for d in compare_pair(name, ours, off, allow, stats):
            report.append(dict(d, package=name))
    unexpected = [d for d in report if not d["allowed"]]
    unused = [r for r in allow.rules if not r["_hits"]]
    compared = stats.get("elf", 0) + stats.get("rel", 0) + stats.get("ar", 0) + stats.get("header", 0)
    if compared == 0:
        print("abi-compare: nothing compared", file=sys.stderr)
        return 2
    os.makedirs(a.out, exist_ok=True)
    status = "FAIL" if unexpected or unused else "PASS"
    with open(os.path.join(a.out, "report.json"), "w") as f:
        json.dump({"status": status, "stats": stats, "differences": report,
                   "unused_rules": [r["id"] for r in unused]}, f, indent=1, sort_keys=True)
    L = ["abi-compare: %s" % status,
         "packages %(packages)d; ELF DSOs/executables %(elf)d (%(dynsyms)d dynamic symbols); "
         "relocatable objects %(rel)d; static archives %(ar)d (%(ar_members)d members); "
         "external symbols of objects/archives %(static_symbols)d; headers %(header)d" % (
             {k: stats.get(k, 0) for k in ("packages", "elf", "dynsyms", "rel", "ar", "ar_members",
                                            "static_symbols", "header")}),
         "differences: %d unexpected, %d allowed; %d unused allowlist rule(s)" % (
             len(unexpected), len(report) - len(unexpected), len(unused)), ""]
    for d in report:
        L.append("%s %s: %s%s" % ("ALLOWED" if d["allowed"] else "UNEXPECTED", d["package"], d["id"],
                                  " -- " + d["reason"] if d["allowed"] else ""))
        for line in (d["diff"] or [])[:60]:
            L.append("    " + line)
        if d["diff"] is None:
            L.append("    ours: %s / official: %s" % (d["ours"], d["official"]))
    for r in unused:
        L.append("UNUSED allowlist rule: %s" % r["id"])
    with open(os.path.join(a.out, "report.txt"), "w") as f:
        f.write("\n".join(L) + "\n")
    print("\n".join(L[:3] + [x for x in L[4:] if x.startswith(("UNEXPECTED", "UNUSED", "    "))][:300]),
          file=sys.stderr)
    return 1 if status == "FAIL" else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RuntimeError as e:
        print("abi-compare: error: %s" % e, file=sys.stderr)
        sys.exit(2)
