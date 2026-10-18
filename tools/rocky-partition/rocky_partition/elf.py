"""Minimal ELF reader: what the partitioner needs (class, type, sections,
PT_INTERP, DT_NEEDED/RPATH/RUNPATH/SONAME and the file offset of the
RUNPATH string). Read-only; RUNPATH changes go through patchelf."""
import struct

ET_REL, ET_EXEC, ET_DYN = 1, 2, 3
PT_DYNAMIC, PT_INTERP, PT_LOAD = 2, 3, 1
DT_NULL, DT_NEEDED, DT_STRTAB, DT_STRSZ, DT_SONAME, DT_RPATH, DT_RUNPATH = 0, 1, 5, 10, 14, 15, 29
SHF_ALLOC = 0x2
SHT_NOBITS, SHT_DYNAMIC = 8, 6


class Elf:
    __slots__ = ("cls", "etype", "machine", "sections", "phdrs", "interp", "needed", "rpath", "runpath",
                 "soname", "rpath_spans", "dynamic")

    def alloc_ranges(self):
        """file ranges of loaded (SHF_ALLOC, not NOBITS) sections, by name"""
        return [(n, o, s) for n, t, f, o, s in self.sections if f & SHF_ALLOC and t != SHT_NOBITS and s]


def is_elf(head):
    return head[:4] == b"\x7fELF"


def parse(d):
    """-> Elf or None (not ELF / unparseable)"""
    if len(d) < 52 or d[:4] != b"\x7fELF" or d[4] not in (1, 2) or d[5] not in (1, 2):
        return None
    try:
        return _parse(d)
    except (struct.error, IndexError, ValueError):
        return None


def _parse(d):
    e = "<" if d[5] == 1 else ">"
    is64 = d[4] == 2
    x = Elf()
    x.cls = 64 if is64 else 32
    if is64:
        etype, machine = struct.unpack_from(e + "HH", d, 16)
        phoff, shoff = struct.unpack_from(e + "QQ", d, 0x20)
        phes, phn, shes, shn, shstrndx = struct.unpack_from(e + "HHHHH", d, 0x36)
    else:
        etype, machine = struct.unpack_from(e + "HH", d, 16)
        phoff, shoff = struct.unpack_from(e + "II", d, 0x1c)
        phes, phn, shes, shn, shstrndx = struct.unpack_from(e + "HHHHH", d, 0x2a)
    x.etype, x.machine = etype, machine
    # program headers
    x.phdrs = []
    for i in range(phn if phoff else 0):
        o = phoff + i * phes
        if is64:
            pt, _pf, po, pv, _pp, pfs, pms, _pa = struct.unpack_from(e + "IIQQQQQQ", d, o)
        else:
            pt, po, pv, _pp, pfs, pms, _pf, _pa = struct.unpack_from(e + "IIIIIIII", d, o)
        x.phdrs.append((pt, po, pv, pfs, pms))
    # section headers
    x.sections = []
    if shoff:
        if shn == 0:
            shn = struct.unpack_from(e + ("Q" if is64 else "I"), d, shoff + (32 if is64 else 20))[0]
        if shstrndx == 0xffff:
            shstrndx = struct.unpack_from(e + "I", d, shoff + (40 if is64 else 24))[0]
        raw = []
        for i in range(shn):
            o = shoff + i * shes
            if is64:
                nm, st, sf, _sa, so, ss, sl = struct.unpack_from(e + "IIQQQQI", d, o)
            else:
                nm, st, sf, _sa, so, ss, sl = struct.unpack_from(e + "IIIIIII", d, o)
            raw.append((nm, st, sf, so, ss, sl))
        stro = raw[shstrndx][3] if shstrndx < len(raw) else None
        for nm, st, sf, so, ss, sl in raw:
            name = ""
            if stro is not None:
                end = d.find(b"\0", stro + nm)
                name = d[stro + nm:end].decode("ascii", "replace") if end >= 0 else ""
            x.sections.append((name, st, sf, so, ss))
        dyn_sec = [(so, ss, sl) for (nm, st, sf, so, ss, sl) in raw if st == SHT_DYNAMIC]
    else:
        dyn_sec = []
    x.interp = None
    for pt, po, pv, pfs, pms in x.phdrs:
        if pt == PT_INTERP:
            x.interp = d[po:po + pfs].split(b"\0", 1)[0].decode("utf-8", "surrogateescape")
    # dynamic section: prefer the section table, else PT_DYNAMIC
    x.dynamic = False
    x.needed, x.rpath, x.runpath, x.soname, x.rpath_spans = [], None, None, None, []
    dyn_off = dyn_size = None
    strtab_off = None
    if dyn_sec:
        dyn_off, dyn_size, link = dyn_sec[0]
        if link < len(raw):
            strtab_off = raw[link][3]
    else:
        for pt, po, pv, pfs, pms in x.phdrs:
            if pt == PT_DYNAMIC:
                dyn_off, dyn_size = po, pfs
    if dyn_off is None:
        return x
    x.dynamic = True
    ent = 16 if is64 else 8
    fmt = e + ("qQ" if is64 else "iI")
    entries = []
    for i in range(dyn_size // ent):
        tag, val = struct.unpack_from(fmt, d, dyn_off + i * ent)
        if tag == DT_NULL:
            break
        entries.append((tag, val))
    if strtab_off is None:
        vaddr = next((v for t, v in entries if t == DT_STRTAB), None)
        if vaddr is not None:
            for pt, po, pv, pfs, pms in x.phdrs:
                if pt == PT_LOAD and pv <= vaddr < pv + pfs:
                    strtab_off = po + (vaddr - pv)
    if strtab_off is None:
        return x

    def s(off):
        a = strtab_off + off
        b = d.index(b"\0", a)
        return d[a:b].decode("utf-8", "surrogateescape"), a, b

    for tag, val in entries:
        if tag == DT_NEEDED:
            x.needed.append(s(val)[0])
        elif tag == DT_SONAME:
            x.soname = s(val)[0]
        elif tag in (DT_RPATH, DT_RUNPATH):
            v, a, b = s(val)
            if tag == DT_RPATH:
                x.rpath = v
            else:
                x.runpath = v
            x.rpath_spans.append((a, b))
    return x


def elf_class(path):
    try:
        with open(path, "rb") as f:
            h = f.read(20)
    except OSError:
        return None
    if h[:4] != b"\x7fELF":
        return None
    return 64 if h[4] == 2 else 32
