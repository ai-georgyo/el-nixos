"""Byte-level reference scanning (design §2.5, §2.8): full prefix
references, other store paths, store-by-pieces windows, Nix-style hash
search for the output graph."""
import re

from .decoders import compression_of

HASH_RUN = re.compile(rb"[0-9a-df-np-sv-z]{32,}")
# path characters, plus ld.so's dynamic string tokens ($LIB, ${PLATFORM}, also
# shell-escaped \$LIB as in glibc's memusage/xtrace scripts)
TOKEN = rb"\\?\$\{?(?:LIB|PLATFORM)\}?"
PATH_TAIL = rb"((?:[A-Za-z0-9._+@%/-]|" + TOKEN + rb")*)"
TOKEN_RE = re.compile(TOKEN.decode())
WINDOW = 8


def prefix_re(prefix_b):
    return re.compile(re.escape(prefix_b) + PATH_TAIL)


def store_re(store_dirs):
    alts = b"|".join(re.escape(d.encode()) for d in store_dirs)
    return re.compile(rb"(?:" + alts + rb")/([0-9a-df-np-sv-z]{32})-")


def kind_of(data):
    head = data[:16]
    if head[:4] == b"\x7fELF":
        return "elf"
    if head[:8] == b"!<arch>\n":
        return "ar"
    c = compression_of(head)
    if c:
        return "compressed:" + c
    if b"\0" not in data:
        return "text"
    return "binary"


def prefix_refs(data, rx):
    """-> [(start, end, tail)] for every full occurrence of the prefix"""
    return [(m.start(), m.end(), m.group(1).decode("utf-8", "surrogateescape")) for m in rx.finditer(data)]


MIN_HASH = 6


def windows(prefix_b, hash_start):
    """8-byte windows of the prefix holding at least MIN_HASH bytes of its
    hash part (windows of the store dir or the name alone match unrelated
    strings: another store path with the same first hash character, the
    package name in .note.package)"""
    out = []
    for k in range(max(0, hash_start - WINDOW + MIN_HASH), min(hash_start + 32 - MIN_HASH, len(prefix_b) - WINDOW) + 1):
        out.append((k, prefix_b[k:k + WINDOW]))
    return out


def pieced(data, prefix_b, hash_start, full, ranges=None):
    """offsets of prefix windows not inside a full occurrence (store by
    pieces), restricted to `ranges` [(name, off, size)] if given.
    -> {section name: count}"""
    covered = [(s, s + len(prefix_b)) for s, _e, _t in full]
    hits = {}
    seen = set()
    for _k, w in windows(prefix_b, hash_start):
        i = data.find(w)
        while i >= 0:
            if i not in seen and not any(a <= i and i + WINDOW <= b for a, b in covered):
                sec = None
                if ranges is None:
                    sec = "-"
                else:
                    for n, o, s in ranges:
                        if o <= i < o + s:
                            sec = n
                            break
                if sec is not None:
                    seen.add(i)
                    hits[sec] = hits.get(sec, 0) + 1
            i = data.find(w, i + 1)
    return hits


def hashes_in(data, wanted):
    """Nix's reference test: which of the `wanted` 32-char hashes occur
    (anywhere, also without the store dir) -> set"""
    found = set()
    for m in HASH_RUN.finditer(data):
        run = m.group(0)
        if len(run) == 32:
            if run in wanted:
                found.add(run)
        else:
            for i in range(len(run) - 31):
                h = run[i:i + 32]
                if h in wanted:
                    found.add(h)
    return found


def shebang(data):
    if not data.startswith(b"#!"):
        return None
    line = data[2:data.find(b"\n") if b"\n" in data else 256].strip()
    return line.split()[0].decode("utf-8", "replace") if line else None
