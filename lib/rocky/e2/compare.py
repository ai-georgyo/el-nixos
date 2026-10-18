#!/usr/bin/env python3
"""e2-compare: compare relocated builds of one SRPM (E2: noview vs view).

Usage:
  compare.py OUTDIR A B [C...]

A, B, ... are payload trees (lib/rocky/e2/reloc.nix outputs: the whole rpm
payload under the store path, which is also the build's %_prefix).  A is the
reference; every other tree is compared against it.  Writes OUTDIR/report.txt
and OUTDIR/report.json.

1. file lists: relative paths (nix-support/ excluded); .build-id links are
   keyed by the file they resolve to (their names are build-ids, which hash
   the store path and so differ between any two builds)
2. contents of common files, classified:
     identical | modulo-hash        (own store hash -> eeee…)
     modulo-pieced-hash             (also partial-hash runs: gcc store-by-pieces)
     modulo-build-id                (ELF: build-id note / debuglink CRC / MiniDebugInfo,
                                     section by section, after the above)
     modulo-ar-dates                (ar member headers)
     DIFFERS                        (anything else: real differences)
   symlink targets after hash normalisation.
3. references to the own prefix "$P/rel" in every file (also inside gzip
   members, compressed ELF sections and MiniDebugInfo), resolved against the
   tree: backed | DANGLING-IN-VIEW (no file of the build, but the build's
   view -- nix-support/view-inputs -- has it: a compiled-in reference into
   the view) | dangling (nowhere); bare "$P".  And references to other store
   paths (inputs leaking into outputs), by name.

Python 3 stdlib only (+ the `zstd` binary for zstd-compressed sections, if
any); run with python3 -I.
"""
import gzip
import json
import lzma
import os
import re
import shutil
import struct
import subprocess
import sys
import zlib

E = b"e" * 32
PATHCH = rb"[A-Za-z0-9._+@%/-]"
BUILDID_RE = re.compile(r"^(.*/\.build-id/)[0-9a-f]{2}/[0-9a-f]{30,}(\.debug|\.\d+)?$")
MAX_LIST = 12


def hash_of(tree):
    return os.path.basename(tree.rstrip("/"))[:32].encode()


# --------------------------------------------------------------------------- tree walk
def walk(tree):
    """key -> ('f', mode, size, rel) | ('l', target) | ('d',).

    Keys are relative paths with the own store hash replaced by eeee… (find-
    debuginfo lays debug files out under lib/debug/<prefix>/...); .build-id
    links are keyed by their (normalised) target, .build-id/xx dirs dropped."""
    tree = os.path.realpath(tree)
    h = hash_of(tree).decode()
    out = {}
    for dp, dns, fns in os.walk(tree):
        rd = os.path.relpath(dp, tree)
        if rd == "nix-support" or rd.startswith("nix-support/"):
            dns[:] = []
            continue
        for n in dns + fns:
            p = os.path.join(dp, n)
            rel = os.path.normpath(os.path.join(rd, n))
            if rel == "nix-support":
                continue
            if re.search(r"/\.build-id/[0-9a-f]{2}$", rel) and not os.path.islink(p):
                continue
            key = rel.replace(h, E.decode())
            m = BUILDID_RE.match(rel)
            if m and os.path.islink(p):
                tgt = re.sub(r"[0-9a-f]{2}/[0-9a-f]{30,}", "<bid>", os.readlink(p).replace(h, E.decode()))
                key = f"{m.group(1)}<{tgt}>{m.group(2) or ''}"
            if os.path.islink(p):
                out[key] = ("l", os.readlink(p))
            elif os.path.isdir(p):
                out[key] = ("d",)
            else:
                st = os.lstat(p)
                out[key] = ("f", st.st_mode & 0o7777, st.st_size, rel)
    return out


# --------------------------------------------------------------------------- content compare
def runs(a, b):
    """differing byte runs of equal-length a, b (block-wise, then bytewise)."""
    res = []
    n, blk = len(a), 4096
    i = 0
    while i < n:
        j = min(n, i + blk)
        if a[i:j] != b[i:j]:
            k = i
            while k < j:
                if a[k] != b[k]:
                    s = k
                    while k < n and a[k] != b[k]:
                        k += 1
                    res.append((s, k))
                    if len(res) > 100000:
                        return res
                else:
                    k += 1
            i = max(j, k)
        else:
            i = j
    return res


def pieced_ok(a, b, ha, hb):
    """equal length; every differing run is the same slice of ha (in a) and hb (in b)."""
    if len(a) != len(b):
        return False
    for s, t in runs(a, b):
        seg_a, seg_b = a[s:t], b[s:t]
        L = t - s
        if L > 32:
            return False
        ok = False
        for k in range(0, 33 - L):
            if ha[k:k + L] == seg_a and hb[k:k + L] == seg_b:
                ok = True
                break
        if not ok:
            return False
    return True


def norm(x, h):
    # nixpkgs' reproducible-builds hook passes -frandom-seed=<first 10 chars of
    # $out's hash> ([F-1]); -grecord-gcc-switches puts it into DW_AT_producer
    return x.replace(h, E).replace(b"-frandom-seed=" + h[:10], b"-frandom-seed=" + E[:10])


def eq_hash(a, b, ha, hb):
    """'identical' | 'modulo-hash' | 'modulo-pieced-hash' | None"""
    if a == b:
        return "identical"
    if norm(a, ha) == norm(b, hb):
        return "modulo-hash"
    if pieced_ok(a, b, ha, hb):
        return "modulo-pieced-hash"
    return None


def zstd_d(data):
    try:
        import compression.zstd as z  # Python >= 3.14
        return z.decompress(data)
    except ImportError:
        exe = shutil.which("zstd")
        if not exe:
            return None
        r = subprocess.run([exe, "-dc"], input=data, capture_output=True)
        return r.stdout if r.returncode == 0 else None


class Elf:
    def __init__(self, data):
        self.d = data
        if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
            raise ValueError("not ELF64LE")
        (self.shoff,) = struct.unpack_from("<Q", data, 0x28)
        self.shentsize, self.shnum, self.shstrndx = struct.unpack_from("<HHH", data, 0x3A)
        self.secs = []
        for i in range(self.shnum):
            o = self.shoff + i * self.shentsize
            name, typ, flags, addr, off, size = struct.unpack_from("<IIQQQQ", data, o)
            self.secs.append([name, typ, flags, off, size])
        if self.shnum and self.shstrndx < self.shnum:
            _, _, _, so, ss = self.secs[self.shstrndx]
            strtab = data[so:so + ss]
            for s in self.secs:
                e = strtab.find(b"\0", s[0])
                s[0] = strtab[s[0]:e].decode("latin1")

    def sections(self):
        """[(name, type, bytes)] with SHF_COMPRESSED sections decompressed"""
        res = []
        for name, typ, flags, off, size in self.secs:
            if typ == 8:  # NOBITS
                res.append((name, typ, b""))
                continue
            b = self.d[off:off + size]
            if flags & 0x800 and len(b) >= 24:  # SHF_COMPRESSED
                (ch_type,) = struct.unpack_from("<I", b, 0)
                if ch_type == 1:
                    b = zlib.decompress(b[24:])
                elif ch_type == 2:
                    b = zstd_d(b[24:]) or b
            res.append((name, typ, b))
        return res

    def build_id(self):
        for name, typ, b in self.sections():
            if typ == 7 and len(b) >= 16:  # NOTE
                o = 0
                while o + 12 <= len(b):
                    nsz, dsz, nt = struct.unpack_from("<III", b, o)
                    n0 = o + 12
                    d0 = n0 + ((nsz + 3) & ~3)
                    if nt == 3 and b[n0:n0 + nsz] == b"GNU\0":
                        return b[d0:d0 + dsz]
                    o = d0 + ((dsz + 3) & ~3)
        return None


def cmp_elf(a, b, ha, hb, depth=0):
    """'modulo-build-id' or a reason string starting with 'DIFFERS'"""
    try:
        ea, eb = Elf(a), Elf(b)
    except (ValueError, struct.error, IndexError):
        return "DIFFERS (not comparable as ELF)"
    sa, sb = ea.sections(), eb.sections()
    if [(n, t) for n, t, _ in sa] != [(n, t) for n, t, _ in sb]:
        return "DIFFERS (section list)"
    ba, bb = ea.build_id(), eb.build_id()
    bad = []
    for (n, t, x), (_, _, y) in zip(sa, sb):
        if ba and bb:
            x, y = x.replace(ba, b"\0" * len(ba)), y.replace(bb, b"\0" * len(bb))
        if n == ".gnu_debuglink":
            x, y = x[:-4], y[:-4]
        if n == ".gnu_debugdata" and depth < 2:
            try:
                xa, ya = lzma.decompress(x), lzma.decompress(y)
            except lzma.LZMAError:
                bad.append(n)
                continue
            if eq_hash(xa, ya, ha, hb) is None:
                r = cmp_elf(xa, ya, ha, hb, depth + 1)
                if r.startswith("DIFFERS"):
                    bad.append(n + ":" + r)
            continue
        if eq_hash(x, y, ha, hb) is None:
            bad.append(n + strdiff(x, y, ha, hb))
    return "modulo-build-id" if not bad else "DIFFERS (sections: " + ", ".join(bad[:8]) + ")"


def strdiff(x, y, ha, hb):
    """for string-table-like sections: the strings only in one side (normalised)"""
    sx = set(s for s in norm(x, ha).split(b"\0") if len(s) >= 4)
    sy = set(s for s in norm(y, hb).split(b"\0") if len(s) >= 4)
    if not sx or not sy or (len(sx - sy) + len(sy - sx)) > 40:
        return ""
    show = lambda ss: "|".join(s.decode("latin1")[:120] for s in sorted(ss)[:4])
    return f" [-{show(sx - sy)} +{show(sy - sx)}]"


def ar_members(d):
    if not d.startswith(b"!<arch>\n"):
        return None
    o, res = 8, []
    while o + 60 <= len(d):
        h = d[o:o + 60]
        try:
            size = int(h[48:58].strip())
        except ValueError:
            return None
        res.append((h[0:16], h[28:48], d[o + 60:o + 60 + size]))  # name, uid/gid/mode, data (date dropped)
        o += 60 + size + (size & 1)
    return res


def cmp_content(a, b, ha, hb):
    r = eq_hash(a, b, ha, hb)
    if r:
        return r
    if a[:4] == b"\x7fELF" and b[:4] == b"\x7fELF":
        return cmp_elf(a, b, ha, hb)
    ma, mb = ar_members(a), ar_members(b)
    if ma is not None and mb is not None:
        if len(ma) != len(mb):
            return "DIFFERS (ar member count)"
        for (na, xa, da), (nb, xb, db) in zip(ma, mb):
            if na != nb or xa != xb:
                return "DIFFERS (ar member header)"
            if eq_hash(da, db, ha, hb) is None:
                r = cmp_elf(da, db, ha, hb) if da[:4] == b"\x7fELF" else "DIFFERS"
                if r.startswith("DIFFERS"):
                    return f"DIFFERS (ar member {na.strip().decode('latin1')}: {r})"
        return "modulo-ar-dates"
    if a[:2] == b"\x1f\x8b" and b[:2] == b"\x1f\x8b":
        try:
            r = cmp_content(gzip.decompress(a), gzip.decompress(b), ha, hb)
            return r if r.startswith("DIFFERS") else "gzip:" + r
        except (OSError, EOFError):
            pass
    rs = runs(a, b) if len(a) == len(b) else []
    detail = f"size {len(a)} vs {len(b)}" if len(a) != len(b) else f"{len(rs)} differing runs, first at {rs[0][0] if rs else '?'}"
    return "DIFFERS (" + detail + ")"


# --------------------------------------------------------------------------- reference scan
def payloads(data, depth=0):
    """the bytes to scan: raw + decompressed nested data (gzip, ELF compressed/debugdata)"""
    yield "raw", data
    if depth >= 2:
        return
    if data[:2] == b"\x1f\x8b":
        try:
            yield from ((f"gzip/{k}", v) for k, v in payloads(gzip.decompress(data), depth + 1))
        except (OSError, EOFError):
            pass
    elif data[:4] == b"\x7fELF":
        try:
            e = Elf(data)
            for (name, typ, flags, off, size), (_, _, b) in zip(e.secs, e.sections()):
                if flags & 0x800:
                    yield f"elf:{name}", b
                elif name == ".gnu_debugdata":
                    try:
                        yield from ((f"debugdata/{k}", v) for k, v in payloads(lzma.decompress(b), depth + 1))
                    except lzma.LZMAError:
                        pass
        except (ValueError, struct.error, IndexError):
            pass


def scan_refs(tree, view_inputs):
    tree = os.path.realpath(tree)
    h = hash_of(tree)
    prefix = tree.encode()
    own = re.compile(re.escape(prefix) + rb"(/" + PATHCH + rb"*)?")
    other = re.compile(rb"/nix/store/([a-z0-9]{32})-([A-Za-z0-9._+-]*)")
    refs = {}       # rel -> {"status", "files"}
    others = {}     # name -> files
    bare = set()

    def status(rel):
        if os.path.lexists(os.path.join(tree, rel)):
            return "backed"
        for vi in view_inputs:
            for base in (vi, os.path.join(vi, "usr")):
                if os.path.lexists(os.path.join(base, rel)):
                    return "DANGLING-IN-VIEW"
        if rel.startswith("bin/") or rel.startswith("sbin/"):
            # the view's bin/ is PATH: tools are reachable through any PATH dir
            for d in os.environ.get("E2_VIEW_PATH", "").split(":"):
                if d and os.path.lexists(os.path.join(d, rel.split("/", 1)[1])):
                    return "DANGLING-IN-VIEW"
        return "dangling"

    for dp, dns, fns in os.walk(tree):
        rd = os.path.relpath(dp, tree)
        if rd == "nix-support" or rd.startswith("nix-support/"):
            dns[:] = []
            continue
        for n in fns:
            p = os.path.join(dp, n)
            rel_f = os.path.normpath(os.path.join(rd, n))
            if os.path.islink(p):
                # a link names what it resolves to (relative targets too)
                t = os.path.normpath(os.path.join(dp, os.readlink(p)))
                datas = [("link", t.encode())] if t.startswith("/nix/store/") else []
            else:
                with open(p, "rb") as f:
                    data = f.read()
                datas = payloads(data)
            for where, data in datas:
                if b"/nix/store/" not in data:
                    continue
                for m in own.finditer(data):
                    rel = (m.group(1) or b"").decode("latin1").strip("/")
                    rel = os.path.normpath(rel) if rel else ""
                    if not rel or rel == ".":
                        bare.add(rel_f)
                        continue
                    r = refs.setdefault(rel, {"status": None, "files": []})
                    if r["status"] is None:
                        r["status"] = status(rel)
                    tag = rel_f if where == "raw" else f"{rel_f} [{where}]"
                    if len(r["files"]) < MAX_LIST and tag not in r["files"]:
                        r["files"].append(tag)
                for m in other.finditer(data):
                    if m.group(1) == h:
                        continue
                    nm = m.group(2).decode("latin1")
                    lst = others.setdefault(nm, [])
                    if len(lst) < MAX_LIST and rel_f not in lst:
                        lst.append(rel_f)
    return {"refs": refs, "bare": sorted(bare)[:MAX_LIST], "bare_count": len(bare), "others": others}


# --------------------------------------------------------------------------- main
def compare(a, b):
    ha, hb = hash_of(a), hash_of(b)
    wa, wb = walk(a), walk(b)
    only_a = sorted(set(wa) - set(wb))
    only_b = sorted(set(wb) - set(wa))
    classes, differs, kind_diff, link_diff, mode_diff = {}, [], [], [], []
    for k in sorted(set(wa) & set(wb)):
        x, y = wa[k], wb[k]
        if x[0] != y[0]:
            kind_diff.append(k)
            continue
        if x[0] == "l":
            bid = lambda t, h: re.sub(rb"[0-9a-f]{2}/[0-9a-f]{30,}", b"<bid>", norm(t.encode(), h))
            if bid(x[1], ha) != bid(y[1], hb):
                link_diff.append((k, x[1], y[1]))
            continue
        if x[0] != "f":
            continue
        if x[1] != y[1]:
            mode_diff.append((k, oct(x[1]), oct(y[1])))
        with open(os.path.join(a, x[3]), "rb") as f:
            da = f.read()
        with open(os.path.join(b, y[3]), "rb") as f:
            db = f.read()
        c = cmp_content(da, db, ha, hb)
        cls = c.split(" ")[0]
        classes[cls] = classes.get(cls, 0) + 1
        if cls == "DIFFERS":
            differs.append((k, c))
    return {"a": a, "b": b, "files_a": len(wa), "files_b": len(wb), "only_a": only_a, "only_b": only_b,
            "classes": classes, "differs": differs, "kind_diff": kind_diff, "link_diff": link_diff,
            "mode_diff": mode_diff}


def view_inputs_of(tree):
    p = os.path.join(tree, "nix-support", "view-inputs")
    if not os.path.exists(p):
        return []
    with open(p) as f:
        return [l.strip() for l in f if l.strip()]


def main():
    if len(sys.argv) < 4:
        print(__doc__, file=sys.stderr)
        return 2
    outdir, trees = sys.argv[1], [os.path.realpath(t) for t in sys.argv[2:]]
    os.makedirs(outdir, exist_ok=True)
    rep = {"trees": trees, "comparisons": [], "scans": {}}
    lines = []
    for t in trees:
        s = scan_refs(t, view_inputs_of(t))
        rep["scans"][t] = s
        st = {}
        for r in s["refs"].values():
            st[r["status"]] = st.get(r["status"], 0) + 1
        lines.append(f"== refs in {t}  (view inputs: {len(view_inputs_of(t))})")
        lines.append(f"   own-prefix rels: {len(s['refs'])} {json.dumps(st, sort_keys=True)}; bare-prefix files: {s['bare_count']}")
        for rel, r in sorted(s["refs"].items()):
            if r["status"] != "backed":
                lines.append(f"   {r['status']:16} $P/{rel}   <- {', '.join(r['files'][:4])}")
        for nm, fl in sorted(s["others"].items()):
            lines.append(f"   other store path  {nm}   <- {', '.join(fl[:4])}{' ...' if len(fl) > 4 else ''}")
    ref = trees[0]
    sa = rep["scans"][ref]
    for t in trees[1:]:
        c = compare(ref, t)
        rep["comparisons"].append(c)
        lines.append(f"== {os.path.basename(ref)}  vs  {os.path.basename(t)}")
        lines.append(f"   entries: {c['files_a']} vs {c['files_b']}; only in A: {len(c['only_a'])}; only in B: {len(c['only_b'])}")
        for k in c["only_a"][:40]:
            lines.append(f"   only A: {k}")
        for k in c["only_b"][:40]:
            lines.append(f"   only B: {k}")
        lines.append(f"   file contents: {json.dumps(c['classes'], sort_keys=True)}")
        for k, why in c["differs"][:60]:
            lines.append(f"   DIFFERS {k}: {why}")
        for k in c["kind_diff"][:20]:
            lines.append(f"   kind differs: {k}")
        for k, x, y in c["link_diff"][:20]:
            lines.append(f"   link differs: {k}: {x} vs {y}")
        for k, x, y in c["mode_diff"][:20]:
            lines.append(f"   mode differs: {k}: {x} vs {y}")
        sb = rep["scans"][t]
        new = sorted(set(r for r, v in sb["refs"].items() if v["status"] != "backed")
                     - set(r for r, v in sa["refs"].items() if v["status"] != "backed"))
        gone = sorted(set(r for r, v in sa["refs"].items() if v["status"] != "backed")
                      - set(r for r, v in sb["refs"].items() if v["status"] != "backed"))
        c["new_unbacked"], c["gone_unbacked"] = new, gone
        lines.append(f"   unbacked own-prefix refs new in B: {len(new)}; gone in B: {len(gone)}")
        for r in new[:60]:
            lines.append(f"     + {sb['refs'][r]['status']} $P/{r}  <- {', '.join(sb['refs'][r]['files'][:3])}")
        for r in gone[:30]:
            lines.append(f"     - $P/{r}")
        oth_new = sorted(set(sb["others"]) - set(sa["others"]))
        oth_gone = sorted(set(sa["others"]) - set(sb["others"]))
        lines.append(f"   other store paths new in B: {oth_new}; gone in B: {oth_gone}")
    with open(os.path.join(outdir, "report.json"), "w") as f:
        json.dump(rep, f, indent=1, sort_keys=True)
    with open(os.path.join(outdir, "report.txt"), "w") as f:
        f.write("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
