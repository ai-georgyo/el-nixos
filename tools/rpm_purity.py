#!/usr/bin/env python3
"""rpm_purity: find '/nix/store' anywhere in RPMs.

Usage:
  rpm_purity.py [--json FILE] [--quiet] PATH...

PATHs are .rpm files or directories (searched recursively for *.rpm).

Searched (all byte-level, so it does not depend on what Nix's reference
scanner knows about):
  * every string / binary value of the main header (signature header too)
  * every payload member (file contents) and symlink target
  * INSIDE compressed payload members: gzip, xz, bzip2 and zstd data is
    decompressed and searched again (man/info pages, .tar.gz, ...)
  * inside ELF files (also archive members): the xz-compressed MiniDebugInfo
    (.gnu_debugdata, itself an ELF) and SHF_COMPRESSED sections (zlib/zstd)
Nesting is followed up to MAX_DEPTH levels.  Data that looks compressed but
does not decompress is only searched raw.

Exit status: 0 = clean, 1 = '/nix/store' found, 2 = error.

This module is also imported by rpm-parity.py (same scanner) and is run by
lib/default.nix buildSrpm on every build, so a nixpkgs reference in any
binary RPM fails the build that produced it.  Python 3 stdlib only (zstd: the
stdlib module on Python >= 3.14, else the `zstd` binary).
"""
import argparse
import bz2
import gzip
import json
import lzma
import os
import shutil
import struct
import subprocess
import sys
import zlib

STORE = b"/nix/store"
MAX_DEPTH = 4
MAX_INFLATE = 4 << 30  # refuse to inflate a single member beyond 4 GiB (fail closed)

TAG_PAYLOADFORMAT, TAG_PAYLOADCOMPRESSOR = 1124, 1125


class ToolError(Exception):
    pass


# --------------------------------------------------------------------------- rpm reading
def _cstr(store, off):
    end = store.index(b"\0", off)
    return store[off:end].decode("utf-8", "surrogateescape"), end + 1


def read_header(f, pad8):
    """Read one rpm header structure; return {tag: value} (regions skipped)."""
    intro = f.read(16)
    if len(intro) != 16 or intro[:3] != b"\x8e\xad\xe8":
        raise ToolError("bad header magic")
    nindex, hsize = struct.unpack(">II", intro[8:16])
    index = f.read(16 * nindex)
    store = f.read(hsize)
    if len(index) != 16 * nindex or len(store) != hsize:
        raise ToolError("truncated header")
    if pad8:
        f.read((8 - hsize % 8) % 8)
    tags = {}
    for i in range(nindex):
        tag, typ, off, cnt = struct.unpack_from(">IIiI", index, 16 * i)
        if tag in (61, 62, 63, 64):
            continue
        if typ == 6:  # STRING
            tags[tag] = _cstr(store, off)[0]
        elif typ in (8, 9):  # STRING_ARRAY, I18NSTRING
            out = []
            for _ in range(cnt):
                s, off = _cstr(store, off)
                out.append(s)
            tags[tag] = out
        elif typ in (1, 2):  # CHAR, INT8
            tags[tag] = list(store[off:off + cnt])
        elif typ == 3:
            tags[tag] = list(struct.unpack_from(">%dH" % cnt, store, off))
        elif typ == 4:
            tags[tag] = list(struct.unpack_from(">%dI" % cnt, store, off))
        elif typ == 5:
            tags[tag] = list(struct.unpack_from(">%dQ" % cnt, store, off))
        elif typ == 7:  # BIN
            tags[tag] = bytes(store[off:off + cnt])
        else:
            tags[tag] = None
    return tags


def read_rpm_headers(path):
    """-> (signature tags, main tags, payload offset)"""
    with open(path, "rb") as f:
        lead = f.read(96)
        if len(lead) != 96 or lead[:4] != b"\xed\xab\xee\xdb":
            raise ToolError("%s: not an rpm (bad lead)" % path)
        sig = read_header(f, pad8=True)
        main = read_header(f, pad8=False)
        return sig, main, f.tell()


def _zstd_module():
    try:
        from compression import zstd  # Python >= 3.14
        return zstd
    except ImportError:
        return None


def open_payload(path, offset, comp, fmt="cpio"):
    """-> (binary stream of the uncompressed payload, [things to close])"""
    if fmt != "cpio":
        raise ToolError("%s: unsupported payload format %s" % (path, fmt))
    f = open(path, "rb")
    f.seek(offset)
    if comp == "gzip":
        return gzip.GzipFile(fileobj=f), [f]
    if comp == "bzip2":
        return bz2.BZ2File(f), [f]
    if comp in ("xz", "lzma"):
        return lzma.LZMAFile(f), [f]
    if comp == "zstd":
        z = _zstd_module()
        if z is not None:
            return z.ZstdFile(f), [f]
        exe = shutil.which("zstd")
        if not exe:
            raise ToolError("zstd payload but neither compression.zstd nor `zstd` available")
        p = subprocess.Popen([exe, "-dcq"], stdin=f, stdout=subprocess.PIPE)
        return p.stdout, [f, p]
    raise ToolError("%s: unsupported payload compressor %s" % (path, comp))


def close_all(closers):
    for c in closers:
        if isinstance(c, subprocess.Popen):
            c.stdout.close()
            c.wait()
        else:
            c.close()


class Reader:
    def __init__(self, raw):
        self.raw = raw

    def read(self, n):
        out = bytearray()
        while len(out) < n:
            b = self.raw.read(n - len(out))
            if not b:
                break
            out += b
        return bytes(out)

    def exact(self, n):
        b = self.read(n)
        if len(b) != n:
            raise ToolError("truncated payload")
        return b


def cpio_entries(raw):
    """Yield (path, mode, size, rd) for each entry of a newc cpio stream.
    The consumer reads the entry's data with rd(n) (returns b"" at the end);
    unread data is skipped before the next entry."""
    r = Reader(raw)
    while True:
        h = r.exact(110)
        magic = h[:6]
        if magic == b"07070X":
            raise ToolError("rpm 'stripped' cpio payload (large files) is not supported")
        if magic not in (b"070701", b"070702"):
            raise ToolError("bad cpio magic %r" % magic)
        fields = [int(h[6 + 8 * i:14 + 8 * i], 16) for i in range(13)]
        mode, size, namesize = fields[1], fields[6], fields[11]
        name = r.exact(namesize)[:-1].decode("utf-8", "surrogateescape")
        r.exact((4 - (110 + namesize) % 4) % 4)
        if name == "TRAILER!!!":
            return
        state = {"left": size}

        def rd(n, state=state):
            n = min(n, state["left"])
            b = r.exact(n)
            state["left"] -= n
            return b

        path = name[1:] if name.startswith("./") else ("/" + name if not name.startswith("/") else name)
        yield path, mode, size, rd
        while state["left"]:
            rd(1 << 20)
        r.exact((4 - size % 4) % 4)


# --------------------------------------------------------------------------- scanning
class StoreCounter:
    """Count '/nix/store' occurrences in a stream of chunks (matches that span
    chunk boundaries are found exactly once); keep the context of the first."""

    def __init__(self):
        self.count, self.ctx, self.tail = 0, None, b""

    def feed(self, chunk):
        win = self.tail + chunk
        i = win.find(STORE)
        while i >= 0:
            if i + len(STORE) > len(self.tail):  # not already counted in the previous window
                self.count += 1
                if self.ctx is None:
                    self.ctx = win[max(0, i - 40):i + 80]
            i = win.find(STORE, i + 1)
        self.tail = win[-(len(STORE) - 1):]

    def context(self):
        return self.ctx.decode("utf-8", "replace") if self.ctx else ""


def count_store(data):
    c = StoreCounter()
    c.feed(data)
    return c.count, c.context()


def is_interesting(head):
    """True if nested_hits() may find something in data starting with `head`
    (compressed data, ELF, ar archive)."""
    return compression_of(head) is not None or head[:4] == b"\x7fELF" or head[:8] == b"!<arch>\n"


def compression_of(head):
    if head[:2] == b"\x1f\x8b":
        return "gzip"
    if head[:6] == b"\xfd7zXZ\x00":
        return "xz"
    if head[:3] == b"BZh" and len(head) >= 10 and head[3:4].isdigit() and head[4:10] == b"\x31\x41\x59\x26\x53\x59":
        return "bzip2"
    if head[:4] == b"\x28\xb5\x2f\xfd":
        return "zstd"
    return None


def _bounded(chunks):
    out, n = [], 0
    for c in chunks:
        n += len(c)
        if n > MAX_INFLATE:
            raise ToolError("nested data inflates beyond %d bytes" % MAX_INFLATE)
        out.append(c)
    return b"".join(out)


_ZLIB_TYPE = type(zlib.decompressobj())


def _iter_decompressor(make, data):
    """Feed `data` to successive decompressor objects (multi-member gzip,
    concatenated xz/zstd frames), yielding the output in bounded chunks.
    Truncated input ends the iteration (what was decoded is kept)."""
    step = 1 << 24
    while data:
        d = make()
        if isinstance(d, _ZLIB_TYPE):
            buf = data
            while True:
                out = d.decompress(buf, step)
                if out:
                    yield out
                buf = d.unconsumed_tail
                if d.eof:
                    break
                if not buf and not out:
                    return
            data = d.unused_data
        else:  # lzma / bz2 / zstd decompressor objects
            out = d.decompress(data, step)
            while True:
                if out:
                    yield out
                if d.eof:
                    break
                if d.needs_input:
                    return
                out = d.decompress(b"", step)
            data = d.unused_data
        if not data.strip(b"\0"):  # gzip members may be followed by zero padding
            return


def decompress(kind, data):
    """Decompress gzip/xz/bzip2/zstd/zlib bytes; None if it is not valid."""
    try:
        if kind == "gzip":
            return _bounded(_iter_decompressor(lambda: zlib.decompressobj(16 + zlib.MAX_WBITS), data))
        if kind == "zlib":
            return _bounded(_iter_decompressor(lambda: zlib.decompressobj(), data))
        if kind == "xz":
            return _bounded(_iter_decompressor(lambda: lzma.LZMADecompressor(), data))
        if kind == "bzip2":
            return _bounded(_iter_decompressor(lambda: bz2.BZ2Decompressor(), data))
        if kind == "zstd":
            z = _zstd_module()
            if z is not None:
                return _bounded(_iter_decompressor(lambda: z.ZstdDecompressor(), data))
            exe = shutil.which("zstd")
            if not exe:
                raise ToolError("zstd data but neither compression.zstd nor `zstd` available")
            p = subprocess.run([exe, "-dcq"], input=data, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            if p.returncode != 0:
                return None
            if len(p.stdout) > MAX_INFLATE:
                raise ToolError("nested data inflates beyond %d bytes" % MAX_INFLATE)
            return p.stdout
    except (OSError, EOFError, ValueError, zlib.error, lzma.LZMAError):
        return None
    raise ValueError(kind)


def _elf_inner(d):
    """Yield (label, bytes) of the compressed parts of an ELF file, already
    decompressed: .gnu_debugdata (xz) and SHF_COMPRESSED sections."""
    try:
        cls, enc = d[4], d[5]
        e = "<" if enc == 1 else ">"
        is64 = cls == 2
        if is64:
            shoff, = struct.unpack_from(e + "Q", d, 0x28)
            shes, shn, shstrndx = struct.unpack_from(e + "HHH", d, 0x3a)
        else:
            shoff, = struct.unpack_from(e + "I", d, 0x20)
            shes, shn, shstrndx = struct.unpack_from(e + "HHH", d, 0x2e)
        if not shoff:
            return
        if shn == 0:
            shn = struct.unpack_from(e + ("Q" if is64 else "I"), d, shoff + (32 if is64 else 20))[0]
        if shstrndx == 0xffff:
            shstrndx = struct.unpack_from(e + "I", d, shoff + (40 if is64 else 24))[0]
        shdrs = []
        for i in range(shn):
            o = shoff + i * shes
            if is64:
                nm, st, sf, _sa, so, ss = struct.unpack_from(e + "IIQQQQ", d, o)
            else:
                nm, st, sf, _sa, so, ss = struct.unpack_from(e + "IIIIII", d, o)
            shdrs.append((nm, st, sf, so, ss))
        stro = shdrs[shstrndx][3] if shstrndx < len(shdrs) else None
    except (struct.error, IndexError):
        return
    for nm, st, sf, so, ss in shdrs:
        if st == 8 or not ss:  # NOBITS
            continue
        name = ""
        if stro is not None:
            end = d.find(b"\0", stro + nm)
            name = d[stro + nm:end].decode("ascii", "replace") if end >= 0 else ""
        body = d[so:so + ss]
        if name == ".gnu_debugdata":
            out = decompress("xz", body)
            if out is not None:
                yield ".gnu_debugdata", out
        elif sf & 0x800:  # SHF_COMPRESSED: Elf_Chdr + data
            try:
                ctype = struct.unpack_from(e + "I", body, 0)[0]
            except struct.error:
                continue
            hdr = 24 if is64 else 12
            kind = {1: "zlib", 2: "zstd"}.get(ctype)
            if kind:
                out = decompress(kind, body[hdr:])
                if out is not None:
                    yield "%s(%s)" % (name, kind), out


def _ar_members(d):
    p, longnames = 8, b""
    while p + 60 <= len(d):
        h = d[p:p + 60]
        name = h[:16].decode("latin-1").rstrip()
        try:
            size = int(h[48:58].decode("ascii").strip() or 0)
        except ValueError:
            return
        body = d[p + 60:p + 60 + size]
        p += 60 + size + (size & 1)
        if name == "//":
            longnames = body
            continue
        if name in ("/", "/SYM64/"):
            continue
        if name.startswith("/") and name[1:].isdigit():
            o = int(name[1:])
            end = longnames.find(b"\n", o)
            name = longnames[o:end if end >= 0 else None].decode("latin-1")
        yield name.rstrip("/"), body


def nested_hits(data, depth=0):
    """Store-path hits hidden inside `data` (NOT counting matches in the raw
    bytes themselves, which the caller already scanned).
    -> [(where, count, context)]; `where` names the nesting chain."""
    hits = []
    if depth >= MAX_DEPTH:
        return hits
    kind = compression_of(data[:16])
    inner = []
    if kind:
        out = decompress(kind, data)
        if out is not None:
            inner.append((kind, out))
    elif data[:4] == b"\x7fELF":
        inner.extend(_elf_inner(data))
    elif data[:8] == b"!<arch>\n":
        for mname, body in _ar_members(data):
            for where, n, ctx in nested_hits(body, depth + 1):
                hits.append(("(%s)>%s" % (mname, where), n, ctx))
        return hits
    for label, out in inner:
        n, ctx = count_store(out)
        if n:
            hits.append((label, n, ctx))
        for where, m, c in nested_hits(out, depth + 1):
            hits.append(("%s>%s" % (label, where), m, c))
    return hits


def scan_member(rd, first_chunk_size=1 << 20):
    """Scan one cpio member read through rd(); -> list of hit dicts (without
    path).  Data is buffered only when it may contain nested data."""
    c = StoreCounter()
    buf, head = None, None
    while True:
        chunk = rd(first_chunk_size)
        if not chunk:
            break
        if head is None:
            head = chunk[:16]
            if is_interesting(head):
                buf = bytearray()
        c.feed(chunk)
        if buf is not None:
            buf += chunk
    out = []
    if c.count:
        out.append({"where": "payload", "count": c.count, "context": c.context()})
    if buf is not None:
        for where, n, ctx in nested_hits(bytes(buf)):
            out.append({"where": "payload>" + where, "count": n, "context": ctx})
    return out


def header_hits(tags, label):
    hits = []
    for tag, val in tags.items():
        vals = val if isinstance(val, list) else [val]
        for x in vals:
            if isinstance(x, str) and "/nix/store" in x:
                i = x.find("/nix/store")
                hits.append({"where": label, "path": "tag %d" % tag, "context": x[max(0, i - 40):i + 80]})
            elif isinstance(x, bytes) and STORE in x:
                hits.append({"where": label, "path": "tag %d" % tag, "context": "<binary>"})
    return hits


def scan_rpm(path):
    """-> list of hits {where, path, count?, context} for one rpm file."""
    sig, main, off = read_rpm_headers(path)
    hits = header_hits(sig, "signature header") + header_hits(main, "header")
    comp = main.get(TAG_PAYLOADCOMPRESSOR) or "gzip"
    fmt = main.get(TAG_PAYLOADFORMAT) or "cpio"
    raw, closers = open_payload(path, off, comp, fmt)
    try:
        for p, mode, size, rd in cpio_entries(raw):
            if (mode & 0o170000) == 0o120000:
                tgt = rd(size)
                if STORE in tgt:
                    hits.append({"where": "symlink", "path": p, "context": tgt.decode("utf-8", "replace")})
                continue
            if (mode & 0o170000) != 0o100000 or size == 0:
                continue
            for h in scan_member(rd):
                hits.append(dict(h, path=p))
    finally:
        close_all(closers)
    return hits


def collect(paths):
    out = []
    for p in paths:
        if os.path.isdir(p):
            for root, dirs, files in os.walk(p):
                dirs.sort()
                out.extend(os.path.join(root, f) for f in sorted(files) if f.endswith(".rpm"))
        elif os.path.isfile(p):
            out.append(p)
        else:
            raise ToolError("no such file or directory: %s" % p)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description="Fail on any /nix/store string in RPMs (nested compression included).")
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--json", help="write {rpm: [hits]} here")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args(argv)
    files = collect(a.paths)
    if not files:
        raise ToolError("no RPMs found in %s" % " ".join(a.paths))
    report, total = {}, 0
    for f in files:
        hits = scan_rpm(f)
        report[f] = hits
        total += len(hits)
        for h in hits[:50]:
            print("rpm-purity: %s: %s %s x%s: %s" % (os.path.basename(f), h["where"], h["path"],
                                                     h.get("count", 1), h["context"][:160]), file=sys.stderr)
    if a.json:
        with open(a.json, "w") as fh:
            json.dump(report, fh, indent=1, sort_keys=True)
            fh.write("\n")
    if not a.quiet or total:
        print("rpm-purity: %d RPM(s) scanned, %d with /nix/store, %d hit(s)%s" % (
            len(files), sum(1 for v in report.values() if v), total,
            "" if total else " -- clean"), file=sys.stderr)
    return 1 if total else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ToolError as e:
        print("rpm-purity: error: %s" % e, file=sys.stderr)
        sys.exit(2)
