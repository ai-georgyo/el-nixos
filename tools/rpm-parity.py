#!/usr/bin/env python3
"""rpm-parity: compare RPMs we build against the official Rocky RPMs.

Usage:
  rpm-parity.py --ours PATH... --official PATH... [--allow FILE]... [--out DIR]
                [--name NAME] [--exclude REGEX]... [--keep REGEX]...
                [--excluded-official KEY]... [--no-default-allow]
                [--include-src] [--no-integrity] [--fail-on-unused]

PATHs are .rpm files or directories (searched recursively for *.rpm; source
RPMs are skipped unless --include-src). Packages are paired by NAME.ARCH.

Everything is done in pure Python (stdlib only): RPM headers are parsed
directly (lead + signature header + main header), the payload is decompressed
(zstd via the stdlib module if present, else the `zstd` binary; xz/gzip/bzip2
via the stdlib) and read as a newc cpio stream, and ELF files are parsed by a
small built-in ELF reader. No rpm/readelf is needed, so the tool behaves the
same everywhere (inside or outside a chroot, any rpm version).

For every pair it reports (each difference has a stable id, see docs/parity.md):
  * NEVR, every other header tag (generic: tags the tool does not know are
    compared too), OPTFLAGS as a token diff
  * file list: presence, mode, user, group, symlink target, file flags,
    verify flags, lang, caps, color, class (libmagic), rdev, hard-link count
  * provides/requires/conflicts/obsoletes/recommends/suggests/supplements/
    enhances/order (with scriptlet qualifiers such as (post))
  * scriptlets, triggers, file triggers, changelog
  * regular files in both: content identical? (header digests); differing
    files are classified elf / ar / other; text diffs for small "other" files;
    `ar` archives: member list; ELF files: type, NEEDED, INTERP, SONAME,
    RPATH/RUNPATH, .gnu.hash/.hash, BIND_NOW, PIE, TEXTREL, execstack, RELRO,
    build-id presence, GNU property notes (x86 feature/ISA), ABI tag,
    stapsdt note count, package note (FDO JSON), .comment, section list
  * purity: any '/nix/store' in OUR headers or payloads (hard failure that no
    allowlist can waive)
  * integrity: payload file digests are checked against the header digests

Allowlists (JSON) declare expected differences, see docs/parity.md.
tools/parity/default.json is always loaded unless --no-default-allow.
Exit status: 0 = PASS, 1 = FAIL (unexpected differences / purity), 2 = error.
"""
import argparse
import difflib
import fnmatch
import hashlib
import io
import json
import os
import re
import struct
import sys

TOOL_DIR = os.path.dirname(os.path.abspath(__file__))
ALLOW_DIR = os.path.join(TOOL_DIR, "parity")
sys.path.insert(0, TOOL_DIR)  # -I drops the script dir from sys.path
# rpm reading + the purity scanner (nested compression) are shared with the
# build-time check (lib/default.nix buildSrpm runs rpm_purity.py)
from rpm_purity import (STORE, ToolError, read_header, Reader, cpio_entries,  # noqa: E402
                        open_payload, close_all, StoreCounter, is_interesting, nested_hits)

# --------------------------------------------------------------------------- rpm tags
# from rpm's rpmtag.h (numbers are stable across rpm versions)
TAGS = {
    61: "HEADERIMAGE", 62: "HEADERSIGNATURES", 63: "HEADERIMMUTABLE", 64: "HEADERREGIONS",
    100: "HEADERI18NTABLE",
    1000: "NAME", 1001: "VERSION", 1002: "RELEASE", 1003: "EPOCH", 1004: "SUMMARY",
    1005: "DESCRIPTION", 1006: "BUILDTIME", 1007: "BUILDHOST", 1009: "SIZE",
    1010: "DISTRIBUTION", 1011: "VENDOR", 1014: "LICENSE", 1015: "PACKAGER", 1016: "GROUP",
    1018: "SOURCE", 1019: "PATCH", 1020: "URL", 1021: "OS", 1022: "ARCH",
    1023: "PREIN", 1024: "POSTIN", 1025: "PREUN", 1026: "POSTUN", 1027: "OLDFILENAMES",
    1028: "FILESIZES", 1029: "FILESTATES", 1030: "FILEMODES", 1031: "FILEUIDS",
    1032: "FILEGIDS", 1033: "FILERDEVS", 1034: "FILEMTIMES", 1035: "FILEDIGESTS",
    1036: "FILELINKTOS", 1037: "FILEFLAGS", 1039: "FILEUSERNAME", 1040: "FILEGROUPNAME",
    1044: "SOURCERPM", 1045: "FILEVERIFYFLAGS", 1046: "ARCHIVESIZE", 1047: "PROVIDENAME",
    1048: "REQUIREFLAGS", 1049: "REQUIRENAME", 1050: "REQUIREVERSION", 1051: "NOSOURCE",
    1052: "NOPATCH", 1053: "CONFLICTFLAGS", 1054: "CONFLICTNAME", 1055: "CONFLICTVERSION",
    1056: "DEFAULTPREFIX", 1057: "BUILDROOT", 1059: "EXCLUDEARCH", 1060: "EXCLUDEOS",
    1061: "EXCLUSIVEARCH", 1062: "EXCLUSIVEOS", 1064: "RPMVERSION",
    1065: "TRIGGERSCRIPTS", 1066: "TRIGGERNAME", 1067: "TRIGGERVERSION", 1068: "TRIGGERFLAGS",
    1069: "TRIGGERINDEX", 1079: "VERIFYSCRIPT", 1080: "CHANGELOGTIME", 1081: "CHANGELOGNAME",
    1082: "CHANGELOGTEXT", 1084: "PREREQ", 1085: "PREINPROG", 1086: "POSTINPROG",
    1087: "PREUNPROG", 1088: "POSTUNPROG", 1089: "BUILDARCHS", 1090: "OBSOLETENAME",
    1091: "VERIFYSCRIPTPROG", 1092: "TRIGGERSCRIPTPROG", 1094: "COOKIE", 1095: "FILEDEVICES",
    1096: "FILEINODES", 1097: "FILELANGS", 1098: "PREFIXES", 1106: "SOURCEPACKAGE",
    1112: "PROVIDEFLAGS", 1113: "PROVIDEVERSION", 1114: "OBSOLETEFLAGS",
    1115: "OBSOLETEVERSION", 1116: "DIRINDEXES", 1117: "BASENAMES", 1118: "DIRNAMES",
    1119: "ORIGDIRINDEXES", 1120: "ORIGBASENAMES", 1121: "ORIGDIRNAMES", 1122: "OPTFLAGS",
    1123: "DISTURL", 1124: "PAYLOADFORMAT", 1125: "PAYLOADCOMPRESSOR", 1126: "PAYLOADFLAGS",
    1131: "RHNPLATFORM", 1132: "PLATFORM", 1140: "FILECOLORS", 1141: "FILECLASS",
    1142: "CLASSDICT", 1143: "FILEDEPENDSX", 1144: "FILEDEPENDSN", 1145: "DEPENDSDICT",
    1146: "SOURCEPKGID", 1147: "FILECONTEXTS", 1151: "PRETRANS", 1152: "POSTTRANS",
    1153: "PRETRANSPROG", 1154: "POSTTRANSPROG", 1155: "DISTTAG", 1177: "FILEDIGESTALGOS",
    1186: "XATTRSDICT", 1187: "FILEXATTRSX", 1196: "NVRA",
    5000: "FILENAMES", 5008: "LONGFILESIZES", 5009: "LONGSIZE", 5010: "FILECAPS",
    5011: "FILEDIGESTALGO", 5012: "BUGURL", 5020: "PREINFLAGS", 5021: "POSTINFLAGS",
    5022: "PREUNFLAGS", 5023: "POSTUNFLAGS", 5024: "PRETRANSFLAGS", 5025: "POSTTRANSFLAGS",
    5026: "VERIFYSCRIPTFLAGS", 5027: "TRIGGERSCRIPTFLAGS", 5029: "COLLECTIONS",
    5030: "POLICYNAMES", 5031: "POLICYTYPES", 5032: "POLICYTYPESINDEXES", 5033: "POLICYFLAGS",
    5034: "VCS", 5035: "ORDERNAME", 5036: "ORDERVERSION", 5037: "ORDERFLAGS",
    5045: "FILENLINKS",
    5046: "RECOMMENDNAME", 5047: "RECOMMENDVERSION", 5048: "RECOMMENDFLAGS",
    5049: "SUGGESTNAME", 5050: "SUGGESTVERSION", 5051: "SUGGESTFLAGS",
    5052: "SUPPLEMENTNAME", 5053: "SUPPLEMENTVERSION", 5054: "SUPPLEMENTFLAGS",
    5055: "ENHANCENAME", 5056: "ENHANCEVERSION", 5057: "ENHANCEFLAGS", 5062: "ENCODING",
    5066: "FILETRIGGERSCRIPTS", 5067: "FILETRIGGERSCRIPTPROG", 5068: "FILETRIGGERSCRIPTFLAGS",
    5069: "FILETRIGGERNAME", 5070: "FILETRIGGERINDEX", 5071: "FILETRIGGERVERSION",
    5072: "FILETRIGGERFLAGS", 5076: "TRANSFILETRIGGERSCRIPTS",
    5077: "TRANSFILETRIGGERSCRIPTPROG", 5078: "TRANSFILETRIGGERSCRIPTFLAGS",
    5079: "TRANSFILETRIGGERNAME", 5080: "TRANSFILETRIGGERINDEX",
    5081: "TRANSFILETRIGGERVERSION", 5082: "TRANSFILETRIGGERFLAGS",
    5083: "REMOVEPATHPOSTFIXES", 5084: "FILETRIGGERPRIORITIES",
    5085: "TRANSFILETRIGGERPRIORITIES", 5090: "FILESIGNATURES", 5091: "FILESIGNATURELENGTH",
    5092: "PAYLOADDIGEST", 5093: "PAYLOADDIGESTALGO", 5096: "MODULARITYLABEL",
    5097: "PAYLOADDIGESTALT", 5098: "ARCHSUFFIX", 5099: "SPEC", 5100: "TRANSLATIONURL",
    5101: "UPSTREAMRELEASES", 5102: "SOURCELICENSE", 5103: "PREUNTRANS", 5104: "POSTUNTRANS",
    5105: "PREUNTRANSPROG", 5106: "POSTUNTRANSPROG", 5107: "PREUNTRANSFLAGS",
    5108: "POSTUNTRANSFLAGS", 5109: "SYSUSERS", 5110: "BUILDSYSTEM", 5111: "BUILDOPTION",
}
TAGNUM = {v: k for k, v in TAGS.items()}

DEPKINDS = [  # (report name, NAME tag, VERSION tag, FLAGS tag)
    ("provides", "PROVIDENAME", "PROVIDEVERSION", "PROVIDEFLAGS"),
    ("requires", "REQUIRENAME", "REQUIREVERSION", "REQUIREFLAGS"),
    ("conflicts", "CONFLICTNAME", "CONFLICTVERSION", "CONFLICTFLAGS"),
    ("obsoletes", "OBSOLETENAME", "OBSOLETEVERSION", "OBSOLETEFLAGS"),
    ("recommends", "RECOMMENDNAME", "RECOMMENDVERSION", "RECOMMENDFLAGS"),
    ("suggests", "SUGGESTNAME", "SUGGESTVERSION", "SUGGESTFLAGS"),
    ("supplements", "SUPPLEMENTNAME", "SUPPLEMENTVERSION", "SUPPLEMENTFLAGS"),
    ("enhances", "ENHANCENAME", "ENHANCEVERSION", "ENHANCEFLAGS"),
    ("order", "ORDERNAME", "ORDERVERSION", "ORDERFLAGS"),
]
SCRIPTS = [  # (report name, body, prog, flags)
    ("pretrans", "PRETRANS", "PRETRANSPROG", "PRETRANSFLAGS"),
    ("prein", "PREIN", "PREINPROG", "PREINFLAGS"),
    ("postin", "POSTIN", "POSTINPROG", "POSTINFLAGS"),
    ("preun", "PREUN", "PREUNPROG", "PREUNFLAGS"),
    ("postun", "POSTUN", "POSTUNPROG", "POSTUNFLAGS"),
    ("posttrans", "POSTTRANS", "POSTTRANSPROG", "POSTTRANSFLAGS"),
    ("preuntrans", "PREUNTRANS", "PREUNTRANSPROG", "PREUNTRANSFLAGS"),
    ("postuntrans", "POSTUNTRANS", "POSTUNTRANSPROG", "POSTUNTRANSFLAGS"),
    ("verify", "VERIFYSCRIPT", "VERIFYSCRIPTPROG", "VERIFYSCRIPTFLAGS"),
]
TRIGGERS = [  # (report name, prefix, has priorities)
    ("trigger", "TRIGGER", False),
    ("filetrigger", "FILETRIGGER", True),
    ("transfiletrigger", "TRANSFILETRIGGER", True),
]

# tags compared by dedicated code (or never compared: per-file, regions,
# signature-ish); everything else in the main header is compared generically
_handled = {
    "HEADERIMAGE", "HEADERSIGNATURES", "HEADERIMMUTABLE", "HEADERREGIONS", "HEADERI18NTABLE",
    "NAME", "VERSION", "RELEASE", "EPOCH",
    "OLDFILENAMES", "FILESIZES", "FILESTATES", "FILEMODES", "FILEUIDS", "FILEGIDS",
    "FILERDEVS", "FILEMTIMES", "FILEDIGESTS", "FILELINKTOS", "FILEFLAGS", "FILEUSERNAME",
    "FILEGROUPNAME", "FILEVERIFYFLAGS", "FILEDEVICES", "FILEINODES", "FILELANGS",
    "DIRINDEXES", "BASENAMES", "DIRNAMES", "ORIGDIRINDEXES", "ORIGBASENAMES", "ORIGDIRNAMES",
    "FILECOLORS", "FILECLASS", "CLASSDICT", "FILEDEPENDSX", "FILEDEPENDSN", "DEPENDSDICT",
    "FILECONTEXTS", "FILEDIGESTALGOS", "XATTRSDICT", "FILEXATTRSX", "LONGFILESIZES",
    "FILECAPS", "FILESIGNATURES", "FILESIGNATURELENGTH", "FILENLINKS",
    "CHANGELOGTIME", "CHANGELOGNAME", "CHANGELOGTEXT",
}
for _k, _n, _v, _f in DEPKINDS:
    _handled |= {_n, _v, _f}
for _k, _b, _p, _f in SCRIPTS:
    _handled |= {_b, _p, _f}
for _k, _p, _pri in TRIGGERS:
    _handled |= {_p + s for s in ("SCRIPTS", "SCRIPTPROG", "SCRIPTFLAGS", "NAME", "INDEX",
                                  "VERSION", "FLAGS", "PRIORITIES")}
HANDLED_TAGS = {TAGNUM[t] for t in _handled if t in TAGNUM}

# rpmds.h sense bits
SENSE_LESS, SENSE_GREATER, SENSE_EQUAL = 1 << 1, 1 << 2, 1 << 3
SENSE_QUAL = [  # qualifiers shown in dependency strings, like Requires(post)
    (1 << 7, "pretrans"), (1 << 9, "pre"), (1 << 10, "post"), (1 << 11, "preun"),
    (1 << 12, "postun"), (1 << 5, "posttrans"), (1 << 20, "preuntrans"),
    (1 << 21, "postuntrans"), (1 << 13, "verify"), (1 << 8, "interp"), (1 << 29, "meta"),
]
TRIGGER_TYPES = [(1 << 25, "prein"), (1 << 16, "in"), (1 << 17, "un"), (1 << 18, "postun")]
# rpmfiles.h file flags
FILEFLAG_LETTERS = [(1, "c"), (2, "d"), (8, "m"), (16, "n"), (32, "s"), (64, "g"),
                    (128, "l"), (256, "r"), (2048, "p"), (4096, "a")]
DIGEST_ALGOS = {1: "md5", 2: "sha1", 8: "sha256", 9: "sha384", 10: "sha512", 11: "sha224"}


# --------------------------------------------------------------------------- rpm reading
class Rpm:
    """Parsed RPM: header tags, derived file list, payload location."""

    def __init__(self, path):
        self.path = path
        with open(path, "rb") as f:
            lead = f.read(96)
            if len(lead) != 96 or lead[:4] != b"\xed\xab\xee\xdb":
                raise ToolError("%s: not an rpm (bad lead)" % path)
            self.sigtags = read_header(f, pad8=True)  # signature header: not compared (purity only)
            self.tags = read_header(f, pad8=False)
            self.payload_offset = f.tell()
        t = self.tags
        self.name = self.s("NAME")
        self.arch = self.s("ARCH")
        self.is_source = TAGNUM["SOURCEPACKAGE"] in t or TAGNUM["SOURCERPM"] not in t
        if self.is_source:
            self.arch = "src"
        self.key = "%s.%s" % (self.name, self.arch)
        epoch = self.v("EPOCH")
        self.nevr = "%s-%s%s-%s" % (self.name, "%d:" % epoch[0] if epoch else "",
                                   self.s("VERSION"), self.s("RELEASE"))
        self.nevra = "%s.%s" % (self.nevr, self.arch)
        self._files()

    def v(self, name, default=None):
        return self.tags.get(TAGNUM[name], default)

    def s(self, name):
        x = self.v(name)
        if isinstance(x, list):
            return x[0] if x else ""
        return x if x is not None else ""

    def _files(self):
        bn, dn, di = self.v("BASENAMES"), self.v("DIRNAMES"), self.v("DIRINDEXES")
        if bn is not None:
            paths = [dn[d] + b for b, d in zip(bn, di)]
        else:
            paths = list(self.v("OLDFILENAMES", []))
        n = len(paths)

        def col(name, default):
            x = self.v(name)
            return list(x) if x is not None and len(x) == n else [default] * n

        sizes = col("LONGFILESIZES", None)
        if sizes[0:1] == [None]:
            sizes = col("FILESIZES", 0)
        classdict = self.v("CLASSDICT", [])
        classes = [classdict[i] if i < len(classdict) else "" for i in col("FILECLASS", 0)] \
            if classdict else [""] * n
        self.digestalgo = DIGEST_ALGOS.get((self.v("FILEDIGESTALGO") or [1])[0], "md5")
        devs, inos = col("FILEDEVICES", 0), col("FILEINODES", 0)
        groups = {}
        for i in range(n):
            groups.setdefault((devs[i], inos[i]), []).append(i)
        modes = col("FILEMODES", 0)
        self.files = {}
        users, groupsn = col("FILEUSERNAME", ""), col("FILEGROUPNAME", "")
        links, flags = col("FILELINKTOS", ""), col("FILEFLAGS", 0)
        vflags, langs = col("FILEVERIFYFLAGS", 0xFFFFFFFF), col("FILELANGS", "")
        caps, colors = col("FILECAPS", ""), col("FILECOLORS", 0)
        rdevs, digests = col("FILERDEVS", 0), col("FILEDIGESTS", "")
        for i, p in enumerate(paths):
            g = groups[(devs[i], inos[i])]
            self.files[p] = {
                "mode": modes[i], "size": sizes[i], "user": users[i], "group": groupsn[i],
                "linkto": links[i], "flags": flags[i], "verifyflags": vflags[i],
                "lang": langs[i], "caps": caps[i], "color": colors[i], "class": classes[i],
                "rdev": rdevs[i], "digest": digests[i],
                "nlink": len(g) if (modes[i] & 0o170000) == 0o100000 else 1,
                "group_id": (devs[i], inos[i]),
            }

    def payload_stream(self):
        return open_payload(self.path, self.payload_offset, self.s("PAYLOADCOMPRESSOR") or "gzip",
                            self.s("PAYLOADFORMAT") or "cpio")


# --------------------------------------------------------------------------- ELF
X86_FEAT1 = [(1, "IBT"), (2, "SHSTK"), (4, "LAM_U48"), (8, "LAM_U57")]
X86_ISA = [(1, "x86-64-baseline"), (2, "x86-64-v2"), (4, "x86-64-v3"), (8, "x86-64-v4")]
X86_FEAT2 = [(1, "x86"), (2, "x87"), (4, "MMX"), (8, "XMM"), (0x10, "YMM"), (0x20, "ZMM"),
             (0x40, "FXSR"), (0x80, "XSAVE"), (0x100, "XSAVEOPT"), (0x200, "XSAVEC"),
             (0x400, "TMM"), (0x800, "MASK")]
GNU_PROPS = {
    0xc0000002: ("x86 feature", X86_FEAT1), 0xc0008002: ("x86 ISA needed", X86_ISA),
    0xc0010002: ("x86 ISA used", X86_ISA), 0xc0008001: ("x86 feature needed", X86_FEAT2),
    0xc0010001: ("x86 feature used", X86_FEAT2), 0xb0008000: ("1_needed", [(1, "indirect_extern_access")]),
}
ET = {0: "NONE", 1: "REL", 2: "EXEC", 3: "DYN", 4: "CORE"}


def _bits(v, table):
    names = [n for b, n in table if v & b]
    rest = v & ~sum(b for b, _ in table)
    if rest:
        names.append("0x%x" % rest)
    return ", ".join(names)


def parse_elf(data):
    """Return a dict of ELF facts (see docs/parity.md), or {"error": ...}."""
    try:
        return _parse_elf(data)
    except (struct.error, IndexError, ValueError) as e:
        return {"error": "unparseable ELF: %s" % e}


def _parse_elf(d):
    cls, enc = d[4], d[5]
    e = "<" if enc == 1 else ">"
    is64 = cls == 2
    if is64:
        (etype, mach, _v, _entry, phoff, shoff, _fl, _ehs, phes, phn, shes, shn,
         shstrndx) = struct.unpack_from(e + "HHIQQQIHHHHHH", d, 16)
    else:
        (etype, mach, _v, _entry, phoff, shoff, _fl, _ehs, phes, phn, shes, shn,
         shstrndx) = struct.unpack_from(e + "HHIIIIIHHHHHH", d, 16)
    facts = {"class": 64 if is64 else 32, "machine": mach, "type": ET.get(etype, str(etype))}
    phdrs = []
    for i in range(phn):
        o = phoff + i * phes
        if is64:
            pt, pf, poff, pva, _pa, pfs, pms, pal = struct.unpack_from(e + "IIQQQQQQ", d, o)
        else:
            pt, poff, pva, _pa, pfs, pms, pf, pal = struct.unpack_from(e + "IIIIIIII", d, o)
        phdrs.append((pt, pf, poff, pva, pfs, pms, pal))
    shdrs = []
    if shoff and shn:
        if shn == 0 and shoff:
            shn = struct.unpack_from(e + ("Q" if is64 else "I"), d, shoff + (32 if is64 else 20))[0]
        for i in range(shn):
            o = shoff + i * shes
            if is64:
                nm, st, sf, sa, so, ss, sl, si, sal, ses = struct.unpack_from(e + "IIQQQQIIQQ", d, o)
            else:
                nm, st, sf, sa, so, ss, sl, si, sal, ses = struct.unpack_from(e + "IIIIIIIIII", d, o)
            shdrs.append([nm, st, sf, sa, so, ss, sl, si, sal, ses, ""])
        if shstrndx < len(shdrs):
            stro = shdrs[shstrndx][4]
            for s in shdrs:
                end = d.index(b"\0", stro + s[0])
                s[10] = d[stro + s[0]:end].decode("ascii", "replace")
    secs = {s[10]: s for s in shdrs}
    facts["sections"] = sorted({s[10] for s in shdrs if s[10]})

    def vaddr2off(va):
        for pt, pf, poff, pva, pfs, pms, pal in phdrs:
            if pt == 1 and pva <= va < pva + pfs:
                return va - pva + poff
        for s in shdrs:  # relocatable / no segments
            if s[3] and s[3] <= va < s[3] + s[5] and s[1] != 8:
                return va - s[3] + s[4]
        return None

    interp = None
    facts["execstack"] = None
    facts["relro"] = False
    for pt, pf, poff, pva, pfs, pms, pal in phdrs:
        if pt == 3:
            interp = d[poff:poff + pfs].split(b"\0")[0].decode("utf-8", "replace")
        elif pt == 0x6474e551:  # PT_GNU_STACK
            facts["execstack"] = bool(pf & 1)
        elif pt == 0x6474e552:
            facts["relro"] = True
    facts["interp"] = interp

    # dynamic section
    dyn = []
    dsec = secs.get(".dynamic")
    if dsec is not None and dsec[1] == 6:
        doff, dsz = dsec[4], dsec[5]
    else:
        doff = dsz = None
        for pt, pf, poff, pva, pfs, pms, pal in phdrs:
            if pt == 2:
                doff, dsz = poff, pfs
    if doff is not None:
        ent = 16 if is64 else 8
        fmt = e + ("qQ" if is64 else "iI")
        for i in range(dsz // ent):
            tag, val = struct.unpack_from(fmt, d, doff + i * ent)
            if tag == 0:
                break
            dyn.append((tag, val))
    strtab = None
    for tag, val in dyn:
        if tag == 5:
            strtab = vaddr2off(val)
    if strtab is None and dsec is not None and dsec[6] < len(shdrs):
        strtab = shdrs[dsec[6]][4]

    def dstr(off):
        if strtab is None:
            return "?"
        end = d.index(b"\0", strtab + off)
        return d[strtab + off:end].decode("utf-8", "replace")

    tags = {t for t, _ in dyn}
    facts["dynamic"] = bool(dyn)
    facts["needed"] = [dstr(v) for t, v in dyn if t == 1]
    facts["soname"] = next((dstr(v) for t, v in dyn if t == 14), None)
    facts["rpath"] = next((dstr(v) for t, v in dyn if t == 15), None)
    facts["runpath"] = next((dstr(v) for t, v in dyn if t == 29), None)
    flags = next((v for t, v in dyn if t == 30), 0)
    flags1 = next((v for t, v in dyn if t == 0x6ffffffb), 0)
    facts["gnu_hash"] = 0x6ffffef5 in tags or ".gnu.hash" in secs
    facts["sysv_hash"] = 4 in tags or ".hash" in secs
    facts["bind_now"] = bool(24 in tags or flags & 0x8 or flags1 & 0x1)
    facts["pie"] = bool(flags1 & 0x08000000)
    facts["textrel"] = bool(22 in tags or flags & 0x4)
    facts["relr"] = 36 in tags

    # notes
    notes = []
    note_regions = [(s[4], s[5], s[8]) for s in shdrs if s[1] == 7]
    if not shdrs:
        note_regions = [(poff, pfs, pal) for pt, pf, poff, pva, pfs, pms, pal in phdrs if pt == 4]
    for off, size, align in note_regions:
        al = 8 if align == 8 else 4
        p, end = off, off + size
        while p + 12 <= end:
            namesz, descsz, ntype = struct.unpack_from(e + "III", d, p)
            p += 12
            name = d[p:p + namesz].rstrip(b"\0").decode("ascii", "replace")
            p += (namesz + 3) & ~3
            desc = d[p:p + descsz]
            p += (descsz + al - 1) & ~(al - 1)
            notes.append((name, ntype, desc))
    facts["build_id"] = None
    props, abi, pkgnote, stapsdt = [], None, None, 0
    for name, ntype, desc in notes:
        if name == "GNU" and ntype == 3:
            facts["build_id"] = desc.hex()
        elif name == "GNU" and ntype == 1 and len(desc) >= 16:
            os_, a, b, c = struct.unpack_from(e + "IIII", desc)
            abi = "%s %d.%d.%d" % ({0: "Linux", 1: "Hurd", 2: "Solaris", 3: "FreeBSD"}.get(os_, str(os_)), a, b, c)
        elif name == "GNU" and ntype == 5:
            q, pal = 0, 8 if is64 else 4
            while q + 8 <= len(desc):
                prt, prsz = struct.unpack_from(e + "II", desc, q)
                val = desc[q + 8:q + 8 + prsz]
                q += 8 + ((prsz + pal - 1) & ~(pal - 1))
                if prt in GNU_PROPS and prsz == 4:
                    label, table = GNU_PROPS[prt]
                    props.append("%s: %s" % (label, _bits(struct.unpack(e + "I", val)[0], table)))
                elif prt == 2:
                    props.append("no copy on protected")
                elif prt == 1:
                    props.append("stack size: 0x%x" % int.from_bytes(val, "little" if e == "<" else "big"))
                else:
                    props.append("property 0x%x: %s" % (prt, val.hex()))
        elif name == "stapsdt" and ntype == 3:
            stapsdt += 1
        elif name == "FDO" and ntype == 0xcafe1a7e:
            pkgnote = desc.rstrip(b"\0").decode("utf-8", "replace")
    facts["gnu_property"] = props
    facts["abi_tag"] = abi
    facts["package_note"] = pkgnote
    facts["stapsdt"] = stapsdt
    cs = secs.get(".comment")
    if cs is not None and cs[1] != 8:
        raw = d[cs[4]:cs[4] + cs[5]]
        facts["comment"] = sorted({x.decode("utf-8", "replace") for x in raw.split(b"\0") if x})
    else:
        facts["comment"] = []
    facts.update(_abi_facts(d, e, is64, etype, shdrs, phdrs))
    return facts


SHT = {1: "PROGBITS", 2: "SYMTAB", 3: "STRTAB", 4: "RELA", 5: "HASH", 6: "DYNAMIC", 7: "NOTE",
       8: "NOBITS", 9: "REL", 11: "DYNSYM", 14: "INIT_ARRAY", 15: "FINI_ARRAY",
       16: "PREINIT_ARRAY", 17: "GROUP", 18: "SYMTAB_SHNDX", 19: "RELR",
       0x6ffffff5: "GNU_ATTRIBUTES", 0x6ffffff6: "GNU_HASH", 0x6ffffffd: "VERDEF",
       0x6ffffffe: "VERNEED", 0x6fffffff: "VERSYM"}
PT = {0: "NULL", 1: "LOAD", 2: "DYNAMIC", 3: "INTERP", 4: "NOTE", 6: "PHDR", 7: "TLS",
      0x6474e550: "GNU_EH_FRAME", 0x6474e551: "GNU_STACK", 0x6474e552: "GNU_RELRO",
      0x6474e553: "GNU_PROPERTY", 0x6474e554: "GNU_SFRAME"}
STT = {0: "NOTYPE", 1: "OBJECT", 2: "FUNC", 3: "SECTION", 4: "FILE", 5: "COMMON", 6: "TLS", 10: "IFUNC"}
STB = {0: "LOCAL", 1: "GLOBAL", 2: "WEAK", 10: "UNIQUE"}
STV = ["DEFAULT", "INTERNAL", "HIDDEN", "PROTECTED"]


def _strz(d, off):
    end = d.index(b"\0", off)
    return d[off:end].decode("utf-8", "replace")


def _unique_names(names):
    """section names -> keys, duplicates (comdat .text.x, .group, ...) numbered #2, #3..."""
    seen, out = {}, []
    for n in names:
        seen[n] = seen.get(n, 0) + 1
        out.append(n if seen[n] == 1 else "%s#%d" % (n, seen[n]))
    return out


def _abi_facts(d, e, is64, etype, shdrs, phdrs):
    """Facts that decide ABI and generated code/data (docs/parity.md):
      dynsyms   .dynsym entries: name[@|@@version] type bind visibility section size
                (no values: addresses are layout, covered by `alloc`)
      verdef    version definitions (name [BASE] [< parents])
      verneed   needed versions (file:version [WEAK])
      alloc     {section: "TYPE flags=.. size=.. align=.. sha256"} for every SHF_ALLOC
                section except .note.gnu.build-id: the bytes the loader maps
      segments  program headers (type, offsets, sizes, flags, alignment)
      symbols   ET_REL only: non-local .symtab symbols (defined: type bind vis
                section size; undefined: UND)
      relocs    ET_REL only: {target section: "n=.. sha256"} over (offset, type,
                symbol or [section], addend) of relocations against SHF_ALLOC sections"""
    out = {}
    names = [s[10] for s in shdrs]
    keys = _unique_names(names)

    def secname(ndx):
        if ndx == 0:
            return "UND"
        if ndx == 0xfff1:
            return "ABS"
        if ndx == 0xfff2:
            return "COMMON"
        return names[ndx] if ndx < len(names) else "0x%x" % ndx

    def symbols(sec):
        so, ss, sl = sec[4], sec[5], sec[6]
        stro = shdrs[sl][4] if sl < len(shdrs) else None
        fmt = e + ("IBBHQQ" if is64 else "IIIBBH")
        ent = struct.calcsize(fmt)
        res = []
        for t in struct.iter_unpack(fmt, d[so:so + (ss // ent) * ent]):
            if is64:
                nm, info, other, shndx, val, size = t
            else:
                nm, val, size, info, other, shndx = t
            res.append((_strz(d, stro + nm) if stro is not None else "?", info & 0xf, info >> 4,
                        other & 3, shndx, val, size))
        return res

    # --- version definitions / needs
    vdefs, vneeds, defs, needs = {}, {}, [], []
    for s in shdrs:
        if s[1] not in (0x6ffffffd, 0x6ffffffe):
            continue
        stro = shdrs[s[6]][4] if s[6] < len(shdrs) else None
        if stro is None:
            continue
        o = s[4]
        for _ in range(s[7]):  # sh_info = number of entries
            if s[1] == 0x6ffffffd:
                _ver, flags, ndx, cnt, _h, aux, nxt = struct.unpack_from(e + "HHHHIII", d, o)
                vn, a = [], o + aux
                for _j in range(cnt):
                    vda_name, vda_next = struct.unpack_from(e + "II", d, a)
                    vn.append(_strz(d, stro + vda_name))
                    a += vda_next
                if vn:
                    vdefs[ndx] = vn[0]
                    defs.append(vn[0] + (" BASE" if flags & 1 else "") + (" WEAK" if flags & 2 else "")
                                + (" < " + ",".join(vn[1:]) if vn[1:] else ""))
            else:
                _ver, cnt, vfile, aux, nxt = struct.unpack_from(e + "HHIII", d, o)
                fname, a = _strz(d, stro + vfile), o + aux
                for _j in range(cnt):
                    _h, vflags, other, vna_name, vna_next = struct.unpack_from(e + "IHHII", d, a)
                    vname = _strz(d, stro + vna_name)
                    vneeds[other] = vname
                    needs.append("%s:%s%s" % (fname, vname, " WEAK" if vflags & 2 else ""))
                    a += vna_next
            if not nxt:
                break
            o += nxt
    out["verdef"] = sorted(defs)
    out["verneed"] = sorted(needs)

    # --- dynamic symbols
    dynsec = next((s for s in shdrs if s[1] == 11), None)
    versym = next((s for s in shdrs if s[1] == 0x6fffffff), None)
    dyn = []
    if dynsec is not None:
        syms = symbols(dynsec)
        vs = list(struct.unpack_from(e + "%dH" % (versym[5] // 2), d, versym[4])) if versym else []
        for i, (nm, typ, bind, vis, shndx, _val, size) in enumerate(syms):
            if i == 0:
                continue
            v = vs[i] if i < len(vs) else 1
            idx, hidden = v & 0x7fff, v & 0x8000
            if idx in vdefs and idx > 1:
                nm += ("@" if hidden else "@@") + vdefs[idx]
            elif idx in vneeds:
                nm += "@" + vneeds[idx]
            dyn.append("%s %s %s %s %s %d" % (nm, STT.get(typ, typ), STB.get(bind, bind), STV[vis],
                                              secname(shndx), size))
    out["dynsyms"] = sorted(dyn)

    # --- loaded bytes
    alloc = {}
    for s, k in zip(shdrs, keys):
        if not s[2] & 0x2 or s[10] == ".note.gnu.build-id":
            continue
        v = "%s flags=0x%x size=0x%x align=%d" % (SHT.get(s[1], "0x%x" % s[1]), s[2], s[5], s[8])
        if s[1] != 8:  # NOBITS: size only
            v += " " + hashlib.sha256(d[s[4]:s[4] + s[5]]).hexdigest()[:20]
        alloc[k] = v
    out["alloc"] = alloc
    out["segments"] = ["%s off=0x%x vaddr=0x%x filesz=0x%x memsz=0x%x flags=%s%s%s align=0x%x" % (
        PT.get(pt, "0x%x" % pt), poff, pva, pfs, pms, "R" if pf & 4 else "-", "W" if pf & 2 else "-",
        "X" if pf & 1 else "-", pal) for pt, pf, poff, pva, pfs, pms, pal in phdrs]

    # --- relocatable objects (crt files, archive members): symbols + relocations
    if etype == 1:
        symtab = next((s for s in shdrs if s[1] == 2), None)
        syms = symbols(symtab) if symtab is not None else []
        out["symbols"] = sorted(
            ("%s UND" % nm) if shndx == 0 else
            "%s %s %s %s %s %d" % (nm, STT.get(typ, typ), STB.get(bind, bind), STV[vis], secname(shndx), size)
            for nm, typ, bind, vis, shndx, _v, size in syms if bind != 0 and nm)
        relocs = {}
        for s in shdrs:
            if s[1] not in (4, 9) or s[7] >= len(shdrs) or not shdrs[s[7]][2] & 0x2:
                continue
            rsyms = syms if s[6] < len(shdrs) and shdrs[s[6]] is symtab else \
                (symbols(shdrs[s[6]]) if s[6] < len(shdrs) else [])
            rela = s[1] == 4
            fmt = e + (("QQq" if rela else "QQ") if is64 else ("IIi" if rela else "II"))
            ent = struct.calcsize(fmt)
            h, n = hashlib.sha256(), 0
            for t in struct.iter_unpack(fmt, d[s[4]:s[4] + (s[5] // ent) * ent]):
                off, info = t[0], t[1]
                si, rt = (info >> 32, info & 0xffffffff) if is64 else (info >> 8, info & 0xff)
                if si < len(rsyms):
                    nm, typ, _b, _v, shndx, _val, _sz = rsyms[si]
                    tgt = "[%s]" % secname(shndx) if typ == 3 else nm
                else:
                    tgt = "#%d" % si
                h.update(("%x %d %s %d\n" % (off, rt, tgt, t[2] if rela else 0)).encode())
                n += 1
            relocs[keys[s[7]]] = "n=%d %s" % (n, h.hexdigest()[:20])
        out["relocs"] = relocs
    return out


# props compared for ELF pairs (build_id compared for presence only)
ELF_PROPS = ["class", "machine", "type", "interp", "needed", "soname", "rpath", "runpath",
             "gnu_hash", "sysv_hash", "bind_now", "pie", "textrel", "relr", "execstack",
             "relro", "build_id", "gnu_property", "abi_tag", "stapsdt", "package_note",
             "comment", "sections"]


def parse_ar(data):
    """Static archive -> {"members": [names in order], "armap": [symbol names],
    "objects": {member key: ELF facts | {"digest": ...}}}; member keys are the
    names, duplicates numbered name#2, ...  Member header fields (date, uid,
    gid, mode) are deliberately ignored: metadata of the archiver."""
    if not data.startswith(b"!<arch>\n"):
        return None
    p, names, bodies, longnames, armap = 8, [], [], b"", []
    while p + 60 <= len(data):
        h = data[p:p + 60]
        name = h[:16].decode("latin-1").rstrip()
        size = int(h[48:58].decode("ascii").strip() or 0)
        body = data[p + 60:p + 60 + size]
        p += 60 + size + (size & 1)
        if name == "//":
            longnames = body
            continue
        if name in ("/", "/SYM64/"):
            w = 8 if name == "/SYM64/" else 4
            n = int.from_bytes(body[:w], "big")
            armap = [x.decode("latin-1") for x in body[w + n * w:].split(b"\0")[:n]]
            continue
        if name.startswith("/") and name[1:].isdigit():
            o = int(name[1:])
            name = longnames[o:longnames.index(b"\n", o)].decode("latin-1")
        names.append(name.rstrip("/"))
        bodies.append(body)
    objects = {}
    for k, body in zip(_unique_names(names), bodies):
        objects[k] = parse_elf(body) if body.startswith(b"\x7fELF") else \
            {"digest": hashlib.sha256(body).hexdigest()[:20]}
    return {"members": names, "armap": sorted(armap), "objects": objects}


def kind_of(head):
    if head.startswith(b"\x7fELF"):
        return "elf"
    if head.startswith(b"!<arch>\n"):
        return "ar"
    return "other"


# --------------------------------------------------------------------------- payload scan
def scan_payload(rpm, want, purity, integrity, keep_text_max=1 << 20):
    """Stream rpm's payload once.
    want: set of paths whose content facts are needed (kind, ELF facts, ar
    facts, small text).  purity: search every member for /nix/store, also
    inside compressed members, ELF .gnu_debugdata / compressed sections and
    archive members (rpm_purity.nested_hits).
    Returns (facts_by_group, purity_hits, integrity_errors, digests_verified)."""
    facts, hits, ierr, verified = {}, [], [], 0
    want_groups = {rpm.files[p]["group_id"] for p in want if p in rpm.files}
    raw, closers = rpm.payload_stream()
    try:
        for path, mode, size, rd in cpio_entries(raw):
            fe = rpm.files.get(path)
            if (mode & 0o170000) == 0o120000:  # symlink: data = target
                tgt = rd(size)
                if purity and STORE in tgt:
                    hits.append({"where": "symlink", "path": path,
                                 "context": tgt.decode("utf-8", "replace")})
                continue
            if (mode & 0o170000) != 0o100000 or size == 0:
                continue
            gid = fe["group_id"] if fe else None
            keep = gid in want_groups          # content facts wanted
            nest = False                       # buffered for the nested purity scan
            h = hashlib.new(rpm.digestalgo) if integrity and fe and fe["digest"] else None
            buf = bytearray() if keep else None
            head = None
            sc = StoreCounter() if purity else None
            while True:
                chunk = rd(1 << 20)
                if not chunk:
                    break
                if h:
                    h.update(chunk)
                if head is None:
                    head = chunk[:16]
                    if purity and is_interesting(head):
                        nest = True
                        if buf is None:
                            buf = bytearray()
                if sc:
                    sc.feed(chunk)
                if buf is not None:
                    if keep and not nest and kind_of(head) == "other" and len(buf) + len(chunk) > keep_text_max:
                        keep, buf = False, None
                        facts[gid] = {"kind": "other", "text": None}
                    else:
                        buf += chunk
            if sc and sc.count:
                hits.append({"where": "payload", "path": path, "count": sc.count, "context": sc.context()})
            data = bytes(buf) if buf is not None else None
            if nest:
                for where, n, ctx in nested_hits(data):
                    hits.append({"where": "payload>" + where, "path": path, "count": n, "context": ctx})
            if h:
                verified += 1
            if h and h.hexdigest() != fe["digest"]:
                ierr.append({"path": path, "header": fe["digest"], "payload": h.hexdigest()})
            if keep:
                k = kind_of(data[:8])
                f = {"kind": k}
                if k == "elf":
                    f["elf"] = parse_elf(data)
                elif k == "ar":
                    f["ar"] = parse_ar(data)
                elif len(data) <= keep_text_max:
                    try:
                        f["text"] = data.decode("utf-8")
                    except UnicodeDecodeError:
                        f["text"] = None
                else:
                    f["text"] = None
                facts[gid] = f
            elif gid in want_groups and gid not in facts:
                facts[gid] = {"kind": kind_of(head or b""), "text": None}
    finally:
        close_all(closers)
    return facts, hits, ierr, verified


def _tagname(tag):
    if isinstance(tag, tuple):
        return "signature tag %d" % tag[1]
    return TAGS.get(tag, "tag %d" % tag)


def header_purity(rpm):
    hits = []
    for tag, val in list(rpm.tags.items()) + [(("sig", t), v) for t, v in rpm.sigtags.items()]:
        vals = val if isinstance(val, list) else [val]
        for x in vals:
            if isinstance(x, str) and "/nix/store" in x:
                hits.append({"where": "header", "path": _tagname(tag),
                             "context": x[max(0, x.find("/nix/store") - 40):x.find("/nix/store") + 80]})
            elif isinstance(x, bytes) and STORE in x:
                hits.append({"where": "header", "path": _tagname(tag), "context": "<binary>"})
    return hits


# --------------------------------------------------------------------------- rendering
def render_dep(name, ver, flags):
    s = name
    if ver:
        op = ""
        if flags & SENSE_LESS:
            op += "<"
        if flags & SENSE_GREATER:
            op += ">"
        if flags & SENSE_EQUAL:
            op += "="
        s += " %s %s" % (op or "?", ver)
    q = [n for b, n in SENSE_QUAL if flags & b]
    if q:
        s += " (%s)" % ",".join(q)
    return s


def deps(rpm, kind):
    k = [x for x in DEPKINDS if x[0] == kind][0]
    names = rpm.v(k[1]) or []
    vers = rpm.v(k[2]) or [""] * len(names)
    flags = rpm.v(k[3]) or [0] * len(names)
    return [render_dep(n, v, f) for n, v, f in zip(names, vers, flags)]


def prog_str(p):
    if p is None:
        return ""
    return " ".join(p) if isinstance(p, list) else p


def scripts(rpm):
    out = {}
    for name, body, prog, flags in SCRIPTS:
        b, p, fl = rpm.v(body), rpm.v(prog), rpm.v(flags)
        if b is None and p is None:
            continue
        out[name] = "prog: %s\nflags: %s\n---\n%s" % (
            prog_str(p), fl[0] if isinstance(fl, list) and fl else 0, b if b is not None else "")
    return out


def triggers(rpm, kind):
    _, pre, has_pri = [x for x in TRIGGERS if x[0] == kind][0]
    sc = rpm.v(pre + "SCRIPTS") or []
    progs = rpm.v(pre + "SCRIPTPROG") or [""] * len(sc)
    sflags = rpm.v(pre + "SCRIPTFLAGS") or [0] * len(sc)
    names = rpm.v(pre + "NAME") or []
    vers = rpm.v(pre + "VERSION") or [""] * len(names)
    flags = rpm.v(pre + "FLAGS") or [0] * len(names)
    idx = rpm.v(pre + "INDEX") or [0] * len(names)
    pri = rpm.v(pre + "PRIORITIES") if has_pri else None
    conds = {}
    ttype = {}
    for n, v, f, i in zip(names, vers, flags, idx):
        conds.setdefault(i, []).append(render_dep(n, v, f & 0xF))
        ttype[i] = _bits(f, TRIGGER_TYPES).replace(", ", "+")
    out = {}
    for i, body in enumerate(sc):
        key = "%s%s: %s [prog %s%s]" % (kind, ttype.get(i, "?"), ", ".join(conds.get(i, [])),
                                       progs[i] if i < len(progs) else "",
                                       ", priority %d" % pri[i] if pri and i < len(pri) else "")
        out[key] = "flags: %s\n---\n%s" % (sflags[i] if i < len(sflags) else 0, body)
    return out


def changelog(rpm):
    t = rpm.v("CHANGELOGTIME") or []
    n = rpm.v("CHANGELOGNAME") or []
    x = rpm.v("CHANGELOGTEXT") or []
    return "\n".join("%s %s\n%s" % (a, b, c) for a, b, c in zip(t, n, x))


def fmt_flags(f):
    s = "".join(ch for b, ch in FILEFLAG_LETTERS if f & b)
    return s or "-"


def header_value(rpm, tag):
    v = rpm.tags.get(tag)
    if isinstance(v, bytes):
        return "<%d bytes sha256:%s>" % (len(v), hashlib.sha256(v).hexdigest()[:16])
    if isinstance(v, list) and len(v) == 1:
        return v[0]
    return v


# --------------------------------------------------------------------------- allowlists
class Rules:
    def __init__(self):
        self.allow, self.rewrite, self.options, self.sources = [], [], {}, []

    def load(self, path, seen=None, optional=False):
        """optional=True: rules never show up as 'unused' (used for default.json)."""
        seen = seen if seen is not None else set()
        real = os.path.realpath(path)
        if real in seen:
            return
        seen.add(real)
        with open(path) as f:
            data = json.load(f)
        for ext in data.get("extends", []):
            self.load(self._resolve(ext, os.path.dirname(path)), seen, optional)
        self.sources.append(path)
        for r in data.get("allow", []):
            if "id" not in r or "reason" not in r:
                raise ToolError("%s: allow rule needs 'id' and 'reason': %r" % (path, r))
            self.allow.append(dict(r, _src=os.path.basename(path), _hits=0,
                                   optional=r.get("optional", optional)))
        for r in data.get("rewrite", []):
            if not all(k in r for k in ("field", "pattern", "reason")):
                raise ToolError("%s: rewrite rule needs field/pattern/reason: %r" % (path, r))
            self.rewrite.append(dict(r, _src=os.path.basename(path), _hits=0, _re=re.compile(r["pattern"]),
                                     optional=r.get("optional", optional)))
        self.options.update(data.get("options", {}))

    @staticmethod
    def _resolve(name, base):
        cands = [name, os.path.join(base, name), os.path.join(base, name + ".json"),
                 os.path.join(ALLOW_DIR, name), os.path.join(ALLOW_DIR, name + ".json")]
        for c in cands:
            if os.path.isfile(c):
                return c
        raise ToolError("allowlist '%s' not found (looked in %s and %s)" % (name, base, ALLOW_DIR))

    @staticmethod
    def _pkg_match(rule, key):
        pk = rule.get("packages", "*")
        pk = [pk] if isinstance(pk, str) else pk
        return any(fnmatch.fnmatchcase(key, p) for p in pk)

    def apply_rewrites(self, key, field, side, value):
        if value is None:
            return value
        for r in self.rewrite:
            if r.get("side", "both") not in ("both", side):
                continue
            if not fnmatch.fnmatchcase(field, r["field"]) or not self._pkg_match(r, key):
                continue
            if isinstance(value, str):
                nv = r["_re"].sub(r.get("replace", ""), value)
            elif isinstance(value, list) and all(isinstance(x, str) for x in value):
                nv = [r["_re"].sub(r.get("replace", ""), x) for x in value]
                if r.get("drop_empty", True):
                    nv = [x for x in nv if x != ""]
            else:
                continue
            if nv != value:
                r["_hits"] += 1
                value = nv
        return value

    def match_allow(self, key, did, ours, official):
        for r in self.allow:
            ids = [r["id"]] if isinstance(r["id"], str) else r["id"]
            if not any(fnmatch.fnmatchcase(did, i) for i in ids) or not self._pkg_match(r, key):
                continue
            if "ours" in r and not re.search(r["ours"], json.dumps(ours)):
                continue
            if "official" in r and not re.search(r["official"], json.dumps(official)):
                continue
            r["_hits"] += 1
            return r
        return None


# --------------------------------------------------------------------------- comparison
BUILD_ID_RE = re.compile(r"^(/usr/lib(?:/debug)?/\.build-id)/[0-9a-f]{2}/[0-9a-f]{6,}((?:\.\d+)?(?:\.debug)?)$")
BUILD_ID_DIR_RE = re.compile(r"^/usr/lib(?:/debug)?/\.build-id/[0-9a-f]{2}$")
BUILD_ID_CLASS_RE = re.compile(r"BuildID\[(\w+)\]=[0-9a-f]+")


def normalized_files(rpm, normalize_build_id):
    """path -> file entry; build-id links keyed by their target instead of the
    (always different) build-id, build-id fan-out dirs dropped."""
    out = {}
    for p, fe in rpm.files.items():
        fe = dict(fe, class_=BUILD_ID_CLASS_RE.sub(r"BuildID[\1]=<id>", fe["class"]))
        if normalize_build_id:
            if BUILD_ID_DIR_RE.match(p):
                continue
            m = BUILD_ID_RE.match(p)
            if m and fe["linkto"]:
                q = "%s/<build-id>%s -> %s" % (m.group(1), m.group(2), fe["linkto"])
                fe["orig_path"] = p
                out[q] = fe
                continue
        fe["orig_path"] = p
        out[p] = fe
    return out


class PairResult:
    def __init__(self, key, rules):
        self.key, self.rules = key, rules
        self.diffs, self.purity, self.integrity = [], [], []
        self.stats = {}
        self.elf_rows = []
        self.normalized = []  # fields that differed but were made equal by rewrite rules

    def diff(self, did, ours, official, detail=None):
        r = self.rules.match_allow(self.key, did, ours, official)
        d = {"id": did, "ours": ours, "official": official, "allowed": r is not None}
        if r is not None:
            d["reason"] = r["reason"]
            d["rule"] = r["_src"]
        if detail:
            d["detail"] = detail
        self.diffs.append(d)

    def value(self, field, ours, official, did=None, detail=None):
        o = self.rules.apply_rewrites(self.key, field, "ours", ours)
        f = self.rules.apply_rewrites(self.key, field, "official", official)
        if o != f:
            self.diff(did or field, ours, official, detail)
            return False
        if ours != official:
            self.normalized.append({"id": did or field, "ours": ours, "official": official})
        return True

    def setdiff(self, field, ours, official):
        o = self.rules.apply_rewrites(self.key, field, "ours", list(ours))
        f = self.rules.apply_rewrites(self.key, field, "official", list(official))
        so, sf = set(o), set(f)
        if so == sf and set(ours) != set(official):
            self.normalized.append({"id": field, "ours": sorted(set(ours) - set(official)),
                                    "official": sorted(set(official) - set(ours))})
        for x in sorted(so - sf):
            self.diff("%s:+%s" % (field, x), x, None)
        for x in sorted(sf - so):
            self.diff("%s:-%s" % (field, x), None, x)


def compare_pair(ours, off, rules, opts):
    res = PairResult(ours.key, rules)
    k = ours.key
    # ---- header
    res.value("nevr", ours.nevr, off.nevr)
    for tag in sorted(set(ours.tags) | set(off.tags)):
        if tag in HANDLED_TAGS:
            continue
        name = TAGS.get(tag, "TAG%d" % tag)
        a, b = header_value(ours, tag), header_value(off, tag)
        detail = None
        if isinstance(a, str) and isinstance(b, str) and (" " in a or " " in b) and "\n" not in a + b:
            ta, tb = a.split(), b.split()
            if ta != tb:
                detail = {"tokens_only_ours": [t for t in ta if t not in tb],
                          "tokens_only_official": [t for t in tb if t not in ta]}
        if name == "PAYLOADDIGEST" and a != b and \
                header_value(ours, TAGNUM["PAYLOADDIGESTALT"]) == header_value(off, TAGNUM["PAYLOADDIGESTALT"]):
            # identical uncompressed payload (PAYLOADDIGESTALT), different
            # compressed bytes: the compressor itself differs
            res.value("payload.compressed", a, b, detail={
                "compressor": [ours.s("PAYLOADCOMPRESSOR"), off.s("PAYLOADCOMPRESSOR")],
                "flags": [ours.s("PAYLOADFLAGS"), off.s("PAYLOADFLAGS")]})
            continue
        res.value("header." + name, a, b, detail=detail)
    # ---- changelog
    res.value("changelog", changelog(ours), changelog(off))
    # ---- deps
    for kind, *_ in DEPKINDS:
        res.setdiff(kind, deps(ours, kind), deps(off, kind))
    # ---- scripts / triggers
    so, sf = scripts(ours), scripts(off)
    for n in sorted(set(so) | set(sf)):
        res.value("script." + n, so.get(n), sf.get(n))
    for kind, _, _ in TRIGGERS:
        to, tf = triggers(ours, kind), triggers(off, kind)
        for n in sorted(set(to) | set(tf)):
            res.value(n, to.get(n), tf.get(n))
    # ---- files
    nb = opts.get("normalize_build_id", True)
    fo, ff = normalized_files(ours, nb), normalized_files(off, nb)
    for p in sorted(set(fo) - set(ff)):
        res.diff("file.only-ours:" + p, fmt_file(fo[p]), None)
    for p in sorted(set(ff) - set(fo)):
        res.diff("file.only-official:" + p, None, fmt_file(ff[p]))
    common = sorted(set(fo) & set(ff))
    want_o, want_f, differing, identical = set(), set(), [], []
    for p in common:
        a, b = fo[p], ff[p]
        res.value("file.mode:" + p, "%o" % a["mode"], "%o" % b["mode"])
        for attr in ("user", "group", "linkto", "lang", "caps", "color", "rdev", "nlink"):
            res.value("file.%s:%s" % (attr, p), a[attr], b[attr])
        res.value("file.flags:" + p, fmt_flags(a["flags"]), fmt_flags(b["flags"]))
        res.value("file.verifyflags:" + p, "%x" % a["verifyflags"], "%x" % b["verifyflags"])
        res.value("file.class:" + p, a["class_"], b["class_"])
        if (a["mode"] & 0o170000) == 0o100000 and (b["mode"] & 0o170000) == 0o100000:
            if a["flags"] & 64 or b["flags"] & 64:  # ghost: no content
                continue
            if a["digest"] != b["digest"] or ours.digestalgo != off.digestalgo:
                differing.append(p)
            elif opts.get("deep"):
                identical.append(p)
            else:
                continue
            want_o.add(a["orig_path"])
            want_f.add(b["orig_path"])
    res.stats = {"files_ours": len(ours.files), "files_official": len(off.files),
                 "files_common": len(common),
                 "regular_common": sum(1 for p in common if (fo[p]["mode"] & 0o170000) == 0o100000
                                       and not (fo[p]["flags"] | ff[p]["flags"]) & 64),
                 "content_identical": 0, "content_differs": {"elf": 0, "ar": 0, "other": 0},
                 "elf_compared": 0, "ar_compared": 0}
    res.stats["content_identical"] = res.stats["regular_common"] - len(differing)
    # ---- payloads
    facts_o, hits, ierr, nver_o = scan_payload(ours, want_o, purity=True, integrity=opts["integrity"])
    res.purity = header_purity(ours) + hits
    res.integrity += [dict(e, side="ours") for e in ierr]
    facts_f, _, ierr, nver_f = scan_payload(off, want_f, purity=False, integrity=opts["integrity"])
    res.integrity += [dict(e, side="official") for e in ierr]
    res.stats["digests_verified"] = {"ours": nver_o, "official": nver_f}
    differing_set = set(differing)
    for p in differing + identical:
        same = p not in differing_set
        a, b = fo[p], ff[p]
        xa = facts_o.get(a["group_id"], {"kind": "other"})
        xb = facts_f.get(b["group_id"], {"kind": "other"})
        kind = xa["kind"] if xa["kind"] == xb["kind"] else "other"
        if not same:
            res.stats["content_differs"][kind] += 1
            detail = None
            if kind == "other" and xa.get("text") is not None and xb.get("text") is not None:
                ud = list(difflib.unified_diff(xb["text"].splitlines(), xa["text"].splitlines(),
                                               "official" + p, "ours" + p, lineterm="", n=2))
                detail = {"unified_diff": ud[:400], "truncated": len(ud) > 400}
            res.diff("content.%s:%s" % (kind, p), "%s %s" % (a["size"], a["digest"][:16]),
                     "%s %s" % (b["size"], b["digest"][:16]), detail)
        if kind == "elf":
            res.stats["elf_compared"] += 1
            ea, eb = xa.get("elf", {}), xb.get("elf", {})
            if not same:
                res.elf_rows.append({"path": p, "ours": summarize_elf(ea), "official": summarize_elf(eb)})
            compare_elf(res, p, ea, eb)
        elif kind == "ar":
            res.stats["ar_compared"] += 1
            compare_ar(res, p, xa.get("ar") or {}, xb.get("ar") or {})
    return res


def compare_elf(res, p, ea, eb):
    """All ELF facts of one file (or archive member `archive(member)`)."""
    if "error" in ea or "error" in eb:
        res.diff("elf.error:" + p, ea.get("error"), eb.get("error"))
        return
    for prop in ELF_PROPS:
        va, vb = ea.get(prop), eb.get(prop)
        if prop == "build_id":
            va, vb = va is not None, vb is not None
        if prop == "sections":
            res.setdiff("elf.section:" + p, va or [], vb or [])
            continue
        res.value("elf.%s:%s" % (prop, p), va, vb)
    # ABI: exported/imported symbols with versions, version definitions/needs
    for prop, did in (("dynsyms", "elf.dynsym"), ("verdef", "elf.verdef"), ("verneed", "elf.verneed"),
                      ("symbols", "elf.symbol")):
        res.setdiff("%s:%s" % (did, p), ea.get(prop) or [], eb.get(prop) or [])
    # generated code/data: every loaded section's bytes, the segment layout,
    # and (relocatable objects) the relocations against loaded sections
    for prop, did in (("alloc", "elf.alloc"), ("relocs", "elf.relocs")):
        da, db = ea.get(prop) or {}, eb.get(prop) or {}
        for k in sorted(set(da) | set(db)):
            res.value("%s:%s:%s" % (did, p, k), da.get(k), db.get(k))
    res.value("elf.segments:" + p, ea.get("segments"), eb.get("segments"))


def compare_ar(res, p, aa, ab):
    """Static archive: member order, armap symbols, each member's facts
    (ELF members: everything compare_elf compares; others: content digest)."""
    ma, mb = aa.get("members") or [], ab.get("members") or []
    if ma != mb:
        res.diff("ar.members:" + p, {"count": len(ma), "only": sorted(set(ma) - set(mb))[:50],
                                     "order_differs": sorted(ma) == sorted(mb)},
                 {"count": len(mb), "only": sorted(set(mb) - set(ma))[:50]})
    res.setdiff("ar.armap:" + p, aa.get("armap") or [], ab.get("armap") or [])
    oa, ob = aa.get("objects") or {}, ab.get("objects") or {}
    for k in sorted(set(oa) & set(ob)):
        xa, xb = oa[k], ob[k]
        q = "%s(%s)" % (p, k)
        if "digest" in xa or "digest" in xb:
            res.value("ar.member:" + q, xa.get("digest", "elf"), xb.get("digest", "elf"))
        else:
            compare_elf(res, q, xa, xb)


def summarize_elf(e):
    if not e:
        return {}
    if "error" in e:
        return e
    return {k: e.get(k) for k in ("type", "interp", "needed", "soname", "runpath", "rpath",
                                  "gnu_hash", "sysv_hash", "bind_now", "pie", "build_id",
                                  "gnu_property", "stapsdt", "package_note")} | {
        "has": [s for s in (".gnu_debugdata", ".gnu_debuglink", ".annobin.notes",
                            ".gnu.build.attributes", ".symtab", ".debug_info")
                if s in (e.get("sections") or [])]}


def fmt_file(fe):
    s = "%o %s:%s %s" % (fe["mode"], fe["user"], fe["group"], fmt_flags(fe["flags"]))
    if fe["linkto"]:
        s += " -> " + fe["linkto"]
    return s


def single_side(rpm, purity, integrity):
    """Only-ours package: still scanned for purity / integrity."""
    _, hits, ierr, _n = scan_payload(rpm, set(), purity=purity, integrity=integrity)
    return (header_purity(rpm) if purity else []) + hits, ierr


# --------------------------------------------------------------------------- report
def md_escape(s):
    return str(s).replace("|", "\\|").replace("\n", " ")


def short(v, n=200):
    s = v if isinstance(v, str) else json.dumps(v)
    return s if len(s) <= n else s[:n] + "…"


def write_md(report, path):
    L = []
    L.append("# RPM parity: %s — **%s**\n" % (report["name"], report["status"]))
    s = report["summary"]
    L.append("Compared %d package pair(s); %d unexpected difference(s), %d allowed; "
             "%d purity violation(s); %d integrity error(s).\n" % (
                 s["pairs"], s["unexpected"], s["allowed"], s["purity_violations"], s["integrity_errors"]))
    L.append("Allowlists: %s\n" % (", ".join("`%s`" % os.path.basename(x) for x in report["allowlists"]) or "none"))
    L.append("| package | NEVR (ours / official) | status | unexpected | allowed | files identical | differ elf/ar/other | purity |")
    L.append("|---|---|---|---|---|---|---|---|")
    for p in report["packages"]:
        st = p.get("stats", {})
        cd = st.get("content_differs", {})
        nevr = p["ours"]["nevr"] if p.get("ours") else "—"
        if p.get("official") and p.get("ours") and p["official"]["nevr"] != p["ours"]["nevr"]:
            nevr += " / " + p["official"]["nevr"]
        elif p.get("official") and not p.get("ours"):
            nevr = "— / " + p["official"]["nevr"]
        L.append("| %s | %s | %s | %d | %d | %s | %s | %s |" % (
            p["key"], nevr, p["status"], p["unexpected"], p["allowed"],
            "%d/%d" % (st["content_identical"], st["regular_common"]) if st else "—",
            "%d/%d/%d" % (cd.get("elf", 0), cd.get("ar", 0), cd.get("other", 0)) if st else "—",
            len(p.get("purity", [])) or "ok"))
    if s["only_ours"] or s["only_official"] or s["excluded"]:
        L.append("")
        L.append("Only ours: %s  " % (", ".join(s["only_ours"]) or "none"))
        L.append("Only official: %s  " % (", ".join(s["only_official"]) or "none"))
        if s["excluded"]:
            L.append("Excluded by filter: %s" % ", ".join(s["excluded"]))
    if report["unused_rules"]:
        L.append("\n<details><summary>%d allowlist rule(s) matched nothing</summary>\n" % len(report["unused_rules"]))
        for r in report["unused_rules"]:
            L.append("- `%s` (%s): %s" % (r["id"], r["file"], r["reason"]))
        L.append("\n</details>")
    for p in report["packages"]:
        L.append("\n## %s — %s\n" % (p["key"], p["status"]))
        if p.get("ours"):
            L.append("ours: `%s`  " % p["ours"]["file"])
        if p.get("official"):
            L.append("official: `%s`  " % p["official"]["file"])
        if p.get("purity"):
            L.append("\n**PURITY: `/nix/store` found (%d)**\n" % len(p["purity"]))
            for h in p["purity"][:50]:
                L.append("- %s `%s` ×%s: `%s`" % (h["where"], h["path"], h.get("count", 1),
                                                   md_escape(short(h["context"], 160))))
        if p.get("integrity"):
            L.append("\n**INTEGRITY: payload digest ≠ header digest**\n")
            for e in p["integrity"][:50]:
                L.append("- %s `%s`" % (e["side"], e["path"]))
        un = [d for d in p.get("differences", []) if not d["allowed"]]
        al = [d for d in p.get("differences", []) if d["allowed"]]
        if un:
            L.append("\n### Unexpected differences (%d)\n" % len(un))
            L.extend(md_diffs(un, False))
        if al:
            L.append("\n<details><summary>Allowed differences (%d)</summary>\n" % len(al))
            L.extend(md_diffs(al, True))
            L.append("\n</details>")
        if p.get("normalized"):
            L.append("\n<details><summary>Normalized by rewrite rules (%d)</summary>\n" % len(p["normalized"]))
            for d in p["normalized"][:500]:
                L.append("- `%s`: ours `%s` / official `%s`" % (md_escape(d["id"]), md_escape(short(d["ours"])),
                                                              md_escape(short(d["official"]))))
            L.append("\n</details>")
        if p.get("elf"):
            L.append("\n<details><summary>ELF files with differing content (%d)</summary>\n" % len(p["elf"]))
            L.append("| path | side | type | interp | needed | soname | gnu_hash/hash | now/pie | build-id | properties | stapsdt | sections of note |")
            L.append("|---|---|---|---|---|---|---|---|---|---|---|---|")
            for row in p["elf"][:300]:
                for side in ("ours", "official"):
                    e = row[side]
                    if "error" in e:
                        L.append("| %s | %s | %s |||||||||" % (row["path"], side, md_escape(e["error"])))
                        continue
                    L.append("| %s | %s | %s | %s | %s | %s | %s/%s | %s/%s | %s | %s | %s | %s |" % (
                        row["path"] if side == "ours" else "", side, e.get("type"), e.get("interp") or "",
                        md_escape(", ".join(e.get("needed") or [])), e.get("soname") or "",
                        int(bool(e.get("gnu_hash"))), int(bool(e.get("sysv_hash"))),
                        int(bool(e.get("bind_now"))), int(bool(e.get("pie"))),
                        "yes" if e.get("build_id") else "no",
                        md_escape("; ".join(e.get("gnu_property") or [])), e.get("stapsdt"),
                        " ".join(e.get("has") or [])))
            L.append("\n</details>")
    with open(path, "w") as f:
        f.write("\n".join(L) + "\n")


def md_diffs(diffs, allowed):
    L = []
    for d in diffs[:2000]:
        line = "- `%s`" % md_escape(d["id"])
        if d["ours"] is not None and d["official"] is not None:
            line += ": ours `%s` / official `%s`" % (md_escape(short(d["ours"])), md_escape(short(d["official"])))
        elif d["ours"] is not None and not d["id"].split(":")[0].endswith(("+", "only-ours")) and ":+" not in d["id"]:
            line += ": ours `%s` / official ∅" % md_escape(short(d["ours"]))
        elif d["official"] is not None and ":-" not in d["id"] and "only-official" not in d["id"]:
            line += ": ours ∅ / official `%s`" % md_escape(short(d["official"]))
        if allowed:
            line += " — _%s_ (%s)" % (md_escape(d.get("reason", "")), d.get("rule", ""))
        L.append(line)
        det = d.get("detail")
        if det and "tokens_only_ours" in det:
            L.append("  - tokens only ours: `%s`; only official: `%s`" % (
                md_escape(" ".join(det["tokens_only_ours"]) or "∅"),
                md_escape(" ".join(det["tokens_only_official"]) or "∅")))
        if det and det.get("unified_diff") and not allowed:
            L.append("\n```diff")
            L.extend(det["unified_diff"][:200])
            if det.get("truncated") or len(det["unified_diff"]) > 200:
                L.append("... (truncated)")
            L.append("```\n")
        if not allowed and isinstance(d["ours"], str) and isinstance(d["official"], str) \
                and "\n" in d["ours"] + d["official"]:
            ud = list(difflib.unified_diff(d["official"].splitlines(), d["ours"].splitlines(),
                                           "official", "ours", lineterm="", n=2))
            L.append("\n```diff")
            L.extend(ud[:200])
            L.append("```\n")
    if len(diffs) > 2000:
        L.append("- ... %d more (see report.json)" % (len(diffs) - 2000))
    return L


# --------------------------------------------------------------------------- main
def collect(paths, include_src):
    out = []
    for p in paths:
        if os.path.isdir(p):
            for root, dirs, files in os.walk(p):
                dirs.sort()
                for fn in sorted(files):
                    if fn.endswith(".rpm"):
                        out.append(os.path.join(root, fn))
        elif os.path.isfile(p):
            out.append(p)
        else:
            raise ToolError("no such file or directory: %s" % p)
    rpms = {}
    for f in out:
        r = Rpm(f)
        if r.is_source and not include_src:
            continue
        if r.key in rpms:
            raise ToolError("duplicate package %s: %s and %s" % (r.key, rpms[r.key].path, f))
        rpms[r.key] = r
    return rpms


def selected(key, exclude, keep):
    if any(re.fullmatch(k, key) for k in keep):
        return True
    return not any(re.fullmatch(x, key) for x in exclude)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Compare our RPMs against official ones.")
    ap.add_argument("--ours", nargs="+", action="extend", default=[], required=True)
    ap.add_argument("--official", nargs="+", action="extend", default=[], required=True)
    ap.add_argument("--allow", action="append", default=[], help="allowlist JSON (repeatable)")
    ap.add_argument("--no-default-allow", action="store_true")
    ap.add_argument("--name", default="rpm-parity")
    ap.add_argument("--out", default=".", help="directory for report.md / report.json")
    ap.add_argument("--exclude", action="append", default=[], help="regex over NAME.ARCH (full match)")
    ap.add_argument("--keep", action="append", default=[], help="regex over NAME.ARCH, overrides --exclude")
    ap.add_argument("--excluded-official", action="append", default=[],
                    help="NAME.ARCH filtered out before the tool ran (listed in the report)")
    ap.add_argument("--include-src", action="store_true")
    ap.add_argument("--no-integrity", action="store_true")
    ap.add_argument("--deep", action="store_true",
                    help="also parse/compare ELF and ar facts of files whose content is identical "
                         "(exercises the parsers; used by the self-comparison check)")
    ap.add_argument("--fail-on-unused", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args(argv)

    rules = Rules()
    if not a.no_default_allow:
        rules.load(os.path.join(ALLOW_DIR, "default.json"), optional=True)
    for f in a.allow:
        rules.load(f)
    opts = {"normalize_build_id": True, "integrity": not a.no_integrity}
    opts.update(rules.options)
    if a.no_integrity:
        opts["integrity"] = False
    if a.deep:
        opts["deep"] = True

    ours = collect(a.ours, a.include_src)
    off = collect(a.official, a.include_src)
    excluded = sorted(set(a.excluded_official) |
                      {k for k in set(ours) | set(off) if not selected(k, a.exclude, a.keep)})
    ours = {k: v for k, v in ours.items() if selected(k, a.exclude, a.keep)}
    off = {k: v for k, v in off.items() if selected(k, a.exclude, a.keep)}

    pkgs = []
    for key in sorted(set(ours) | set(off)):
        o, f = ours.get(key), off.get(key)
        entry = {"key": key,
                 "ours": {"file": o.path, "nevr": o.nevr} if o else None,
                 "official": {"file": f.path, "nevr": f.nevr} if f else None}
        if not a.quiet:
            print("rpm-parity: %s" % key, file=sys.stderr)
        if o and f:
            r = compare_pair(o, f, rules, opts)
            entry.update(differences=r.diffs, purity=r.purity, integrity=r.integrity,
                         stats=r.stats, elf=r.elf_rows, normalized=r.normalized)
        else:
            res = PairResult(key, rules)
            if o:
                res.diff("package.only-ours:" + key, o.nevra, None)
                hits, ierr = single_side(o, True, opts["integrity"])
                res.purity = hits
                res.integrity = [dict(e, side="ours") for e in ierr]
            else:
                res.diff("package.only-official:" + key, None, f.nevra)
            entry.update(differences=res.diffs, purity=res.purity, integrity=res.integrity, stats={})
        entry["unexpected"] = sum(1 for d in entry["differences"] if not d["allowed"])
        entry["allowed"] = sum(1 for d in entry["differences"] if d["allowed"])
        bad = entry["unexpected"] or entry["purity"] or entry["integrity"]
        entry["status"] = "FAIL" if bad else "PASS"
        pkgs.append(entry)

    unused = [{"id": r.get("id") or r.get("field"), "file": r["_src"], "reason": r["reason"]}
              for r in rules.allow + rules.rewrite if r["_hits"] == 0 and not r.get("optional")]
    summary = {
        "pairs": sum(1 for p in pkgs if p["ours"] and p["official"]),
        "only_ours": [p["key"] for p in pkgs if not p["official"]],
        "only_official": [p["key"] for p in pkgs if not p["ours"]],
        "excluded": excluded,
        "unexpected": sum(p["unexpected"] for p in pkgs),
        "allowed": sum(p["allowed"] for p in pkgs),
        "purity_violations": sum(len(p["purity"]) for p in pkgs),
        "integrity_errors": sum(len(p["integrity"]) for p in pkgs),
    }
    if summary["pairs"] == 0:
        raise ToolError("nothing compared: no package is present on both sides "
                        "(ours: %d, official: %d after filtering)" % (len(ours), len(off)))
    fail = any(p["status"] == "FAIL" for p in pkgs) or (a.fail_on_unused and unused)
    report = {"tool": "rpm-parity", "format": 1, "name": a.name,
              "status": "FAIL" if fail else "PASS", "summary": summary,
              "allowlists": rules.sources, "options": opts,
              "unused_rules": unused,
              "rewrites": [{"field": r["field"], "side": r.get("side", "both"), "hits": r["_hits"],
                            "reason": r["reason"], "file": r["_src"]} for r in rules.rewrite],
              "packages": pkgs}
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "report.json"), "w") as fh:
        json.dump(report, fh, indent=1, sort_keys=True, ensure_ascii=True)
        fh.write("\n")
    write_md(report, os.path.join(a.out, "report.md"))
    if not a.quiet:  # unexpected findings go to the build log too
        shown = 0
        for p in pkgs:
            for d in [d for d in p["differences"] if not d["allowed"]] + \
                     [{"id": "PURITY %s %s" % (h["where"], h["path"]), "ours": h["context"], "official": None}
                      for h in p["purity"]] + \
                     [{"id": "INTEGRITY %s %s" % (e["side"], e["path"]), "ours": None, "official": None}
                      for e in p["integrity"]]:
                if shown < 200:
                    print("  %s: %s  ours=%s official=%s" % (p["key"], d["id"], short(d["ours"], 120),
                                                             short(d["official"], 120)), file=sys.stderr)
                shown += 1
        if shown > 200:
            print("  ... %d more (report.md)" % (shown - 200), file=sys.stderr)
        for r in unused:
            print("  unused allowlist rule: %s (%s)" % (r["id"], r["file"]), file=sys.stderr)
        print("rpm-parity: %s — %s (%d unexpected, %d allowed, %d purity, %d integrity)" % (
            a.name, report["status"], summary["unexpected"], summary["allowed"],
            summary["purity_violations"], summary["integrity_errors"]), file=sys.stderr)
    return 1 if fail else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ToolError as e:
        print("rpm-parity: error: %s" % e, file=sys.stderr)
        sys.exit(2)
