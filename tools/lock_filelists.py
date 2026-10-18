"""Per-package file-list facts from Rocky's filelists.xml (helper module).

Imported by tools/update-lock.py, tools/lock_builddeps.py and
tools/lock_subpackages.py; standard library only.  The binary trees'
``filelists`` metadata (verified against repomd.xml, cached next to the
primary files) is reduced to a small summary per binary RPM of rpms.json:

    {"<name>.<arch>": {"usr": <files under /usr>,      # dirs and %ghost excluded
                       "bin": bool,     # a file in /usr/bin, /usr/sbin, /bin, /sbin
                       "solib": bool,   # a shared library /usr/lib{,64}/lib*.so[.*]
                       "macro": bool}}  # rpm macros: /usr/lib/rpm/macros.d/*,
                                        # /usr/lib/rpm/{,redhat/}macros, /etc/rpm/macros.*

Packages are matched by pkgid (= the sha256 rpms.json records), so a summary
never mixes in a different build of the same name.  The summary is cached as
``filesummary-<digest of the filelists checksums>.json``.
"""

import gzip
import hashlib
import json
import os
import re
import xml.etree.ElementTree as ET

NS_F = "{http://linux.duke.edu/metadata/filelists}"
SOLIB = re.compile(r"^/usr/lib(64)?/lib[^/]*\.so(\.[^/]*)?$")
MACRO = re.compile(r"^(/usr/lib/rpm/macros\.d/[^/]+|/usr/lib/rpm/macros|/usr/lib/rpm/redhat/macros|/etc/rpm/macros[^/]*)$")
BIN = ("/usr/bin/", "/usr/sbin/", "/bin/", "/sbin/")


def summarize_files(paths):
    """paths: iterable of (path, type) with type None (file/symlink), "dir"
    or "ghost".  Returns the summary dict for one package."""
    s = {"usr": 0, "bin": False, "solib": False, "macro": False}
    for p, t in paths:
        if t in ("dir", "ghost"):
            continue
        if p.startswith("/usr/"):
            s["usr"] += 1
        if p.startswith(BIN):
            s["bin"] = True
        if SOLIB.match(p):
            s["solib"] = True
        if MACRO.match(p):
            s["macro"] = True
    return s


def parse_filelists(path, want):
    """want: {pkgid: "<name>.<arch>"}.  Returns {key: summary} for the
    packages of `path` whose pkgid is wanted."""
    out = {}
    with gzip.open(path) as f:
        for _ev, el in ET.iterparse(f):
            if el.tag != NS_F + "package":
                continue
            key = want.get(el.get("pkgid"))
            if key is not None:
                out[key] = summarize_files((x.text or "", x.get("type"))
                                           for x in el.findall(NS_F + "file"))
            el.clear()
    return out


def file_summary(UL, rpms_doc, cache_dir, repos=None, log=None):
    """Summary for every package of rpms.json (dict as loaded).  UL is the
    update-lock module (download helpers).  Downloads at most one filelists
    file per repo; the result is cached."""
    log = log or UL.log
    mirrors = rpms_doc["mirrors"]
    rpms = rpms_doc["rpms"]
    if repos is None:
        repos = sorted({r["repo"] for r in rpms.values()})
    paths, sums = [], []
    for repo in repos:
        p, prov = UL.get_repodata(mirrors, repo, "binary", cache_dir, "filelists")
        paths.append(p)
        sums.append("%s:%s" % (repo, prov["filelists"]))
    # (the version tag changes whenever summarize_files does)
    digest = hashlib.sha256(("v3 " + " ".join(sums) + " " + str(len(rpms))).encode()).hexdigest()[:16]
    cached = os.path.join(cache_dir, "filesummary-%s.json" % digest)
    if os.path.exists(cached):
        with open(cached) as f:
            return json.load(f)
    want = {r["sha256"]: k for k, r in rpms.items()}
    summary = {}
    for p in paths:
        summary.update(parse_filelists(p, want))
    missing = sorted(set(rpms) - set(summary))
    if missing:
        log("filelists: %d of %d packages not found by pkgid (repodata changed since the lock?): %s"
            % (len(missing), len(rpms), missing[:10]))
    tmp = cached + ".tmp"
    with open(tmp, "w") as f:
        json.dump(summary, f, sort_keys=True, separators=(",", ":"))
    os.replace(tmp, cached)
    return summary
