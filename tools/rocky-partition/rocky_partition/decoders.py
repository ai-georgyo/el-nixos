"""Decoders for nested data (scan only, never rewritten).

Copied from tools/rpm_purity.py (the build-time purity scanner) so that the
partitioner's store copy is self-contained (lib/rocky/parts/partitionTool.nix
ships only tools/rocky-partition): compressed members (gzip, xz, bzip2, zstd,
zlib), ELF .gnu_debugdata and SHF_COMPRESSED sections, ar members.
"""
import bz2
import lzma
import shutil
import struct
import subprocess
import zlib

MAX_DEPTH = 4
MAX_INFLATE = 4 << 30  # refuse to inflate a single member beyond 4 GiB (fail closed)


class DecodeError(Exception):
    pass


def _zstd_module():
    try:
        from compression import zstd  # Python >= 3.14
        return zstd
    except ImportError:
        return None


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
            raise DecodeError("nested data inflates beyond %d bytes" % MAX_INFLATE)
        out.append(c)
    return b"".join(out)


_ZLIB_TYPE = type(zlib.decompressobj())


def _iter_decompressor(make, data):
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
        else:
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
        if not data.strip(b"\0"):
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
                raise DecodeError("zstd data but neither compression.zstd nor `zstd` available")
            p = subprocess.run([exe, "-dcq"], input=data, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            if p.returncode != 0:
                return None
            if len(p.stdout) > MAX_INFLATE:
                raise DecodeError("nested data inflates beyond %d bytes" % MAX_INFLATE)
            return p.stdout
    except (OSError, EOFError, ValueError, zlib.error, lzma.LZMAError):
        return None
    raise ValueError(kind)


def elf_inner(d):
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


def ar_members(d):
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


def nested_blobs(data, depth=0):
    """Yield (where, bytes) for every decoded layer hidden inside `data`
    (not `data` itself): decompressed members, ELF compressed sections, ar
    members' nested layers. `where` names the nesting chain."""
    if depth >= MAX_DEPTH:
        return
    kind = compression_of(data[:16])
    inner = []
    if kind:
        out = decompress(kind, data)
        if out is not None:
            inner.append((kind, out))
    elif data[:4] == b"\x7fELF":
        inner.extend(elf_inner(data))
    elif data[:8] == b"!<arch>\n":
        for mname, body in ar_members(data):
            for where, blob in nested_blobs(body, depth + 1):
                yield "(%s)>%s" % (mname, where), blob
        return
    for label, out in inner:
        yield label, out
        for where, blob in nested_blobs(out, depth + 1):
            yield "%s>%s" % (label, where), blob


def recompress(kind, data):
    """Re-encode `data` like a member of `kind` (replay remap only; the bytes
    differ from the original encoder's)."""
    if kind == "gzip":
        import gzip
        return gzip.compress(data, compresslevel=9, mtime=0)
    if kind == "xz":
        return lzma.compress(data)
    if kind == "bzip2":
        return bz2.compress(data, 9)
    if kind == "zstd":
        z = _zstd_module()
        if z is not None:
            return z.compress(data)
        exe = shutil.which("zstd")
        if not exe:
            return None
        return subprocess.run([exe, "-q", "-19", "-c"], input=data, stdout=subprocess.PIPE, check=True).stdout
    return None
