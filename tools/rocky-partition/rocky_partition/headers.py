"""Transient RPM headers (design §2.1): one `rpm -qp --qf` per RPM.

Every value is emitted as `=<shell-quoted value>` after an `@TAG` marker
(`:shescape`), so scriptlet bodies with newlines and quotes survive and
`shlex` recovers the exact strings; absent tags yield empty lists. The
payload is never read (the RPMs may be truncated after the header)."""
import os
import shlex
import subprocess

STR = ["NAME", "VERSION", "RELEASE", "ARCH", "SOURCERPM", "SUMMARY", "LICENSE", "URL",
       "PREIN", "POSTIN", "PREUN", "POSTUN", "PRETRANS", "POSTTRANS", "PREUNTRANS", "POSTUNTRANS", "VERIFYSCRIPT"]
INT = ["EPOCH"]
STR_ARRAYS = ["FILENAMES", "FILELINKTOS", "FILEDIGESTS", "FILEUSERNAME", "FILEGROUPNAME", "FILECAPS",
              "REQUIRENAME", "REQUIREVERSION", "PROVIDENAME", "PROVIDEVERSION",
              "CONFLICTNAME", "CONFLICTVERSION", "OBSOLETENAME", "OBSOLETEVERSION",
              "RECOMMENDNAME", "RECOMMENDVERSION", "SUGGESTNAME", "SUGGESTVERSION",
              "SUPPLEMENTNAME", "SUPPLEMENTVERSION", "ENHANCENAME", "ENHANCEVERSION",
              "PREINPROG", "POSTINPROG", "PREUNPROG", "POSTUNPROG", "PRETRANSPROG", "POSTTRANSPROG",
              "PREUNTRANSPROG", "POSTUNTRANSPROG", "VERIFYSCRIPTPROG",
              "TRIGGERNAME", "TRIGGERVERSION", "TRIGGERSCRIPTS", "TRIGGERSCRIPTPROG",
              "FILETRIGGERNAME", "FILETRIGGERVERSION", "FILETRIGGERSCRIPTS", "FILETRIGGERSCRIPTPROG",
              "TRANSFILETRIGGERNAME", "TRANSFILETRIGGERVERSION", "TRANSFILETRIGGERSCRIPTS",
              "TRANSFILETRIGGERSCRIPTPROG"]
INT_ARRAYS = ["FILEFLAGS", "FILEMODES", "FILEINODES", "FILESIZES", "FILENLINKS",
              "REQUIREFLAGS", "PROVIDEFLAGS", "CONFLICTFLAGS", "OBSOLETEFLAGS", "RECOMMENDFLAGS",
              "SUGGESTFLAGS", "SUPPLEMENTFLAGS", "ENHANCEFLAGS",
              "TRIGGERFLAGS", "TRIGGERINDEX", "FILETRIGGERFLAGS", "FILETRIGGERINDEX", "FILETRIGGERPRIORITIES",
              "TRANSFILETRIGGERFLAGS", "TRANSFILETRIGGERINDEX", "TRANSFILETRIGGERPRIORITIES"]


def _qf():
    parts = []
    for t in STR:
        parts.append("@%s %%|%s?{=%%{%s:shescape}}|" % (t, t, t))
    for t in INT:
        parts.append("@%s %%|%s?{=%%{%s}}|" % (t, t, t))
    for t in STR_ARRAYS:
        parts.append("@%s [=%%{%s:shescape} ]" % (t, t))
    for t in INT_ARRAYS:
        parts.append("@%s [=%%{%s} ]" % (t, t))
    return " ".join(parts) + "\\n"


QF = _qf()

# FILEFLAGS bits (rpmfileAttrs) -> the letters of rpm's :fflags
FFLAGS = [(1, "c"), (2, "d"), (8, "m"), (16, "n"), (32, "s"), (64, "g"), (128, "l"), (256, "r"), (4096, "a")]
RPMSENSE_RPMLIB = 1 << 24
SCRIPTLETS = ["prein", "postin", "preun", "postun", "pretrans", "posttrans", "preuntrans", "postuntrans", "verifyscript"]


class HeaderError(Exception):
    pass


def fflags(n):
    return "".join(c for b, c in FFLAGS if n & b)


def parse_qf(text):
    """`rpm --qf QF` output -> {TAG: [values]} (ints converted)"""
    toks = shlex.split(text, posix=True)
    tags, cur = {}, None
    for t in toks:
        if t.startswith("@"):
            cur = t[1:]
            tags[cur] = []
        elif t.startswith("=") and cur is not None:
            tags[cur].append(t[1:])
        else:
            raise HeaderError("unexpected token %r after @%s" % (t[:40], cur))
    for t in INT + INT_ARRAYS:
        tags[t] = [int(v) for v in tags.get(t, [])]
    return tags


def query(rpm, path, configdir=None):
    env = dict(os.environ)
    if configdir:
        env["RPM_CONFIGDIR"] = configdir
    p = subprocess.run([rpm, "-qp", "--nosignature", "--nodigest", "--qf", QF, path],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    if p.returncode != 0:
        raise HeaderError("%s: rpm -qp failed: %s" % (path, p.stderr.decode("utf-8", "replace").strip()))
    return parse_qf(p.stdout.decode("utf-8", "surrogateescape"))


def _col(tags, t, n, default):
    v = tags.get(t, [])
    return v if len(v) == n else [default] * n


def _deps(tags, kind):
    names = tags.get(kind + "NAME", [])
    n = len(names)
    return [{"name": a, "flags": b, "version": c}
            for a, b, c in zip(names, _col(tags, kind + "FLAGS", n, 0), _col(tags, kind + "VERSION", n, ""))]


def _triggers(tags, prefix):
    scripts = tags.get(prefix + "SCRIPTS", [])
    progs = tags.get(prefix + "SCRIPTPROG", [])
    out = [{"script": s, "prog": progs[i] if i < len(progs) else "", "conditions": []} for i, s in enumerate(scripts)]
    names = tags.get(prefix + "NAME", [])
    n = len(names)
    for name, fl, ver, idx in zip(names, _col(tags, prefix + "FLAGS", n, 0), _col(tags, prefix + "VERSION", n, ""),
                                  _col(tags, prefix + "INDEX", n, 0)):
        if 0 <= idx < len(out):
            out[idx]["conditions"].append({"name": name, "flags": fl, "version": ver})
    prio = tags.get(prefix + "PRIORITIES", [])
    for i, p in enumerate(prio):
        if i < len(out):
            out[i]["priority"] = p
    return out


def subpackage(tags, rpmfile):
    """{TAG: [...]} -> the header record used everywhere else"""
    one = lambda t: (tags.get(t) or [None])[0]
    files = []
    names = tags.get("FILENAMES", [])
    n = len(names)
    cols = {t: _col(tags, t, n, d) for t, d in [
        ("FILEFLAGS", 0), ("FILEMODES", 0), ("FILELINKTOS", ""), ("FILEINODES", 0), ("FILEDIGESTS", ""),
        ("FILEUSERNAME", "root"), ("FILEGROUPNAME", "root"), ("FILECAPS", ""), ("FILESIZES", 0), ("FILENLINKS", 1)]}
    for i, path in enumerate(names):
        files.append({
            "path": path, "flags": cols["FILEFLAGS"][i], "mode": cols["FILEMODES"][i],
            "linkto": cols["FILELINKTOS"][i], "inode": cols["FILEINODES"][i], "digest": cols["FILEDIGESTS"][i],
            "user": cols["FILEUSERNAME"][i], "group": cols["FILEGROUPNAME"][i], "caps": cols["FILECAPS"][i],
            "size": cols["FILESIZES"][i], "nlink": cols["FILENLINKS"][i],
        })
    scriptlets = {}
    for s in SCRIPTLETS:
        body = one(s.upper())
        prog = tags.get(s.upper() + "PROG", [])
        if body is not None or prog:
            scriptlets[s] = {"body": body, "prog": prog}
    return {
        "name": one("NAME"), "epoch": one("EPOCH"), "version": one("VERSION"), "release": one("RELEASE"),
        "arch": one("ARCH"), "sourcerpm": one("SOURCERPM"), "summary": one("SUMMARY"), "license": one("LICENSE"),
        "url": one("URL"), "rpmfile": os.path.basename(rpmfile),
        "files": files,
        "requires": _deps(tags, "REQUIRE"), "provides": _deps(tags, "PROVIDE"),
        "conflicts": _deps(tags, "CONFLICT"), "obsoletes": _deps(tags, "OBSOLETE"),
        "recommends": _deps(tags, "RECOMMEND"), "suggests": _deps(tags, "SUGGEST"),
        "supplements": _deps(tags, "SUPPLEMENT"), "enhances": _deps(tags, "ENHANCE"),
        "scriptlets": scriptlets,
        "triggers": _triggers(tags, "TRIGGER"),
        "fileTriggers": _triggers(tags, "FILETRIGGER"),
        "transFileTriggers": _triggers(tags, "TRANSFILETRIGGER"),
    }


def is_debug(name):
    return name.endswith("-debuginfo") or name.endswith("-debugsource")


def read_all(rpm, rpms_dir, configdir=None):
    """-> {subpackage name: record}"""
    found = []
    for root, dirs, files in os.walk(rpms_dir):
        dirs.sort()
        found.extend(os.path.join(root, f) for f in sorted(files) if f.endswith(".rpm"))
    if not found:
        raise HeaderError("no RPMs under %s" % rpms_dir)
    out = {}
    for f in found:
        rec = subpackage(query(rpm, f, configdir), f)
        if rec["name"] in out:
            raise HeaderError("two RPMs named %s (%s, %s)" % (rec["name"], out[rec["name"]]["rpmfile"], rec["rpmfile"]))
        out[rec["name"]] = rec
    return out


def sibling_requires(subs, canon_rel=None):
    """Unique-provider Requires between sibling subpackages ([SG] rule): s
    requires p if some Require of s is provided (by name, or as a file path)
    by p alone among the siblings. -> {s: set(p)}"""
    providers = {}
    for name, r in subs.items():
        for p in r["provides"]:
            providers.setdefault(p["name"], set()).add(name)
        providers.setdefault(name, set()).add(name)
        for f in r["files"]:
            providers.setdefault(f["path"], set()).add(name)
    req = {}
    for name, r in subs.items():
        got = set()
        for d in r["requires"]:
            if d["flags"] & RPMSENSE_RPMLIB:
                continue
            ps = providers.get(d["name"], set()) - {name}
            if len(ps) == 1 and name not in providers.get(d["name"], set()):
                got |= ps
        req[name] = got
    return req
