#!/usr/bin/env python3
"""Find store paths in files, DWARF-aware (design §2.8, experiment E1).

  storescan.py [--self P]... [--input P]... [--inputs-file F] [--debug-only]
               [--summary] PATH...

Walks PATHs (files or directories; symlinks are not followed) and reports

  full   <file> <section> <path>      a /nix/store/<hash> whose hash is not one
                                      of --self (any foreign store path)
  piece  <file> <section> <offset> <input>
                                      an 8-byte window of an --input hash that
                                      is not part of a full occurrence of it
                                      (gcc store-by-pieces, split strings)

ELF files are scanned per section, with SHF_COMPRESSED sections (zlib; zstd
through compression.zstd or the zstd tool), .zdebug_* and the xz-compressed
.gnu_debugdata decoded first.  --debug-only restricts ELF scanning to .debug_*,
.zdebug_*, .gnu_debugdata and .gnu_debugaltlink sections (DWARF) and skips
other files.  Exit status: 0 nothing found, 1 findings, 2 usage error.
Stdlib only; run with python3 -I.
"""
import argparse
import lzma
import os
import re
import shutil
import struct
import subprocess
import sys
import zlib

STORE = b"/nix/store/"
HASH_CHARS = b"0123456789abcdfghijklmnpqrsvwxyz"
FULL_RE = re.compile(re.escape(STORE) + rb"([" + HASH_CHARS + rb"]{32})(-[A-Za-z0-9+._?=-]*)?")
RUN_RE = re.compile(rb"[" + HASH_CHARS + rb"]{8,}")
SHF_COMPRESSED = 0x800
DEBUG_PREFIXES = (".debug_", ".zdebug_", ".gnu_debugdata", ".gnu_debugaltlink")


def hash_of(path):
    p = os.path.realpath(path) if not path.startswith("/nix/store/") else path
    if not p.startswith("/nix/store/"):
        raise SystemExit(f"storescan: not a store path: {path}")
    return p[len("/nix/store/"):][:32].encode()


def zstd_decompress(data):
    try:
        from compression import zstd  # Python >= 3.14
        return zstd.decompress(data)
    except ImportError:
        pass
    exe = shutil.which("zstd")
    if not exe:
        raise RuntimeError("zstd-compressed section and no zstd decoder")
    return subprocess.run([exe, "-dc"], input=data, capture_output=True, check=True).stdout


def elf_sections(data):
    """[(name, flags, bytes)] of an ELF file; compressed sections decoded."""
    cls, enc = data[4], data[5]
    if enc != 1:
        return None  # big-endian: not on x86_64
    if cls == 2:
        shoff, = struct.unpack_from("<Q", data, 0x28)
        shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x3A)
        fmt, chfmt = "<IIQQQQIIQQ", "<IIQQ"
    elif cls == 1:
        shoff, = struct.unpack_from("<I", data, 0x20)
        shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x2E)
        fmt, chfmt = "<IIIIIIIIII", "<III"
    else:
        return None
    if shoff == 0 or shnum == 0 or shoff + shnum * shentsize > len(data):
        return []
    hdrs = []
    for i in range(shnum):
        f = struct.unpack_from(fmt, data, shoff + i * shentsize)
        name, typ, flags, _addr, off, size = f[0], f[1], f[2], f[3], f[4], f[5]
        hdrs.append((name, typ, flags, off, size))
    stroff, strsize = hdrs[shstrndx][3], hdrs[shstrndx][4]
    strtab = data[stroff:stroff + strsize]
    out = []
    for name, typ, flags, off, size in hdrs:
        if typ == 8:  # SHT_NOBITS
            continue
        nm = strtab[name:strtab.find(b"\0", name)].decode("latin-1")
        body = data[off:off + size]
        try:
            if flags & SHF_COMPRESSED:
                chsize = struct.calcsize(chfmt)
                chtype = struct.unpack_from(chfmt, body, 0)[0]
                payload = body[chsize:]
                body = zlib.decompress(payload) if chtype == 1 else zstd_decompress(payload)
            elif nm.startswith(".zdebug") and body[:4] == b"ZLIB":
                body = zlib.decompress(body[12:])
        except Exception as e:  # report, keep the raw bytes
            print(f"warning: {nm}: cannot decompress: {e}", file=sys.stderr)
        out.append((nm, flags, body))
    return out


class Scanner:
    def __init__(self, selfs, inputs, debug_only):
        self.selfs = selfs
        self.inputs = {h: p for h, p in inputs.items() if h not in selfs}
        self.windows = {}
        for h in self.inputs:
            for k in range(0, 32 - 8 + 1):
                self.windows.setdefault(h[k:k + 8], set()).add(h)
        self.debug_only = debug_only
        self.findings = []

    def scan_blob(self, rel, section, blob):
        for m in FULL_RE.finditer(blob):
            if m.group(1) not in self.selfs:
                self.findings.append(("full", rel, section, m.group(0).decode("latin-1")))
        if not self.windows:
            return
        for m in RUN_RE.finditer(blob):
            run = m.group(0)
            covered = set()
            for h in self.inputs:
                i = run.find(h)
                while i >= 0:
                    covered.update(range(i, i + 32))
                    i = run.find(h, i + 1)
            for i in range(len(run) - 7):
                hs = self.windows.get(run[i:i + 8])
                if hs and i not in covered:
                    for h in hs:
                        self.findings.append(("piece", rel, section,
                                              f"{m.start() + i:#x} {self.inputs[h]}"))
                    break  # one finding per run is enough

    def scan_elf(self, rel, data, depth=0):
        secs = elf_sections(data)
        if secs is None:
            return False
        for nm, _flags, body in secs:
            if self.debug_only and not nm.startswith(DEBUG_PREFIXES):
                continue
            if nm == ".gnu_debugdata":
                try:
                    inner = lzma.decompress(body)
                except lzma.LZMAError:
                    inner = b""
                if inner[:4] == b"\x7fELF" and depth < 2:
                    self.scan_elf(f"{rel}!.gnu_debugdata", inner, depth + 1)
                    continue
            self.scan_blob(rel, nm, body)
        return True

    def scan_file(self, path, rel):
        with open(path, "rb") as f:
            data = f.read()
        if data[:4] == b"\x7fELF" and self.scan_elf(rel, data):
            return
        if not self.debug_only:
            self.scan_blob(rel, "-", data)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--self", action="append", default=[], help="allowed store path (own outputs)")
    ap.add_argument("--input", action="append", default=[], help="store path whose pieces are searched")
    ap.add_argument("--inputs-file", help="file with one --input per line")
    ap.add_argument("--debug-only", action="store_true", help="DWARF sections of ELF files only")
    ap.add_argument("--summary", action="store_true", help="per-file counts instead of every finding")
    ap.add_argument("paths", nargs="+")
    a = ap.parse_args()
    inputs = list(a.input)
    if a.inputs_file:
        with open(a.inputs_file) as f:
            inputs += [l.strip() for l in f if l.strip()]
    selfs = {hash_of(p) for p in a.self}
    sc = Scanner(selfs, {hash_of(p): p for p in inputs}, a.debug_only)
    nfiles = 0
    for root in a.paths:
        if os.path.isfile(root) and not os.path.islink(root):
            sc.scan_file(root, root)
            nfiles += 1
            continue
        for dp, dns, fns in os.walk(root):
            dns.sort()
            for fn in sorted(fns):
                p = os.path.join(dp, fn)
                if os.path.islink(p) or not os.path.isfile(p):
                    continue
                sc.scan_file(p, os.path.relpath(p, root))
                nfiles += 1
    if a.summary:
        counts = {}
        for kind, rel, sec, what in sc.findings:
            key = (kind, rel, sec, what.split()[-1] if kind == "piece" else what.split("/")[3][:60])
            counts[key] = counts.get(key, 0) + 1
        for (kind, rel, sec, what), n in sorted(counts.items()):
            print(f"{kind}\t{n}\t{rel}\t{sec}\t{what}")
    else:
        for f in sc.findings:
            print("\t".join(f))
    nfull = sum(1 for f in sc.findings if f[0] == "full")
    npiece = len(sc.findings) - nfull
    print(f"storescan: {nfiles} files, {nfull} foreign full store paths, {npiece} pieced input windows")
    return 1 if sc.findings else 0


if __name__ == "__main__":
    sys.exit(main())
