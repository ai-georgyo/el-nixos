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
never mixes in a different build of the same name.  The filelists are used
only if their repomd.xml still has the primary checksum rpms.json records
(``repodata.<repo>/<arch>/os.primary``): the lock and the file lists then
describe the same repository snapshot.  A locked package without a summary
is an error (``allow_missing`` turns it into a warning; its tags then
degrade to ``other``).  The summary is cached as ``filesummary-<digest>.json``,
the digest covering the filelists checksums and the wanted pkgids.
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


class FilelistsError(RuntimeError):
    pass


def file_summary(UL, rpms_doc, cache_dir, repos=None, log=None, allow_missing=False):
    """Summary for every package of rpms.json (dict as loaded).  UL is the
    update-lock module (download helpers).  Downloads at most one filelists
    file per repo; the result is cached.  The provenance (filelists sha256
    per repo) is returned under the key "" -- callers record it in the files
    they write (provenance()) and must not treat it as a package."""
    log = log or UL.log
    mirrors = rpms_doc["mirrors"]
    rpms = rpms_doc["rpms"]
    if repos is None:
        repos = sorted({r["repo"] for r in rpms.values()})
    paths, sums, prov_out = [], [], {}
    for repo in repos:
        p, prov = UL.get_repodata(mirrors, repo, "binary", cache_dir, "filelists")
        tree = "%s/%s" % (repo, UL.TREES["binary"])
        locked = (rpms_doc.get("repodata") or {}).get(tree, {}).get("primary")
        if locked != prov.get("primary"):
            msg = ("filelists: %s repomd.xml has primary %s, rpms.json records %s: the "
                   "repository moved on since the lock (update the lock, or use a mirror "
                   "of the locked snapshot)" % (tree, prov.get("primary"), locked))
            if not allow_missing:
                raise FilelistsError(msg)
            log("warning: " + msg)
        paths.append(p)
        sums.append("%s:%s" % (repo, prov["filelists"]))
        prov_out[repo] = prov["filelists"]
    want = {r["sha256"]: k for k, r in rpms.items()}
    # (the version tag changes whenever summarize_files does)
    h = hashlib.sha256(("v4 " + " ".join(sums) + "\n").encode())
    for pkgid, k in sorted(want.items()):
        h.update(("%s %s\n" % (pkgid, k)).encode())
    cached = os.path.join(cache_dir, "filesummary-%s.json" % h.hexdigest()[:16])
    if os.path.exists(cached):
        with open(cached) as f:
            summary = json.load(f)
    else:
        summary = {}
        for p in paths:
            summary.update(parse_filelists(p, want))
        tmp = cached + ".tmp"
        with open(tmp, "w") as f:
            json.dump(summary, f, sort_keys=True, separators=(",", ":"))
        os.replace(tmp, cached)
    missing = sorted(set(rpms) - set(summary))
    if missing:
        msg = ("filelists: %d of %d locked packages not found by pkgid (repodata changed "
               "since the lock?): %s" % (len(missing), len(rpms), missing[:10]))
        if not allow_missing:
            raise FilelistsError(msg)
        log("warning: %s; their tags degrade to 'other'" % msg)
    summary[""] = prov_out
    return summary


def provenance(summary):
    """{repo: filelists sha256} of a file_summary() result."""
    return dict(sorted(summary.get("", {}).items()))
