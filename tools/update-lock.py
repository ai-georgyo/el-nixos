#!/usr/bin/env python3
"""Generate el-nixos lockfiles from Rocky Linux repodata.

Usage (from the repository root):

    nix run .#update-lock -- [--release 10.2] [--out lock] [--cache-dir .cache/repodata]
    python3 -I tools/update-lock.py --self-test

Standard library only.  For every repo in --repos (default BaseOS AppStream CRB)
it downloads ``repomd.xml`` and the ``primary`` metadata of both the source tree
(``<repo>/source/tree``) and the binary tree (``<repo>/x86_64/os``), verifies the
primary file against the sha256 published in repomd.xml, and writes three files
into ``<out>/rocky-<release>/``:

srpms.json   (read by Nix at eval time; contract in docs/DESIGN.md)
    {"release", "dist", "mirrors", "srpms": {name: {epoch, version, release,
    repo, path, sha256, size, buildRequires: ["binutils >= 2.30", ...]}}}
    Newest EVR per SRPM name across all repos (ties: first repo in --repos order).
    SRPM URL = <mirror>/<repo>/source/tree/<path>.

rpms.json    (read by Nix lazily, only when officialRpms is used)
    {"format": 1, "release", "arches", "mirrors", "repodata": {...provenance...},
     "rpms":   {"<name>.<arch>": {name, arch, epoch, version, release, repo, path,
                                  sha256, size, srpm, sourcerpm}},
     "bySrpm": {"<srpm name>": ["<name>.<arch>", ...]}}
    Newest EVR per name.arch, arches x86_64 + noarch (Rocky 10 x86_64 repos are
    not multilib: they contain no i686 packages; anything else is dropped and
    counted).  ``srpm`` is the SRPM *name*, ``sourcerpm`` the full filename from
    the binary header.  RPM URL = <mirror>/<repo>/x86_64/os/<path>.
    One package per line so diffs stay reviewable.

deps.json.gz (NOT read by Nix; input for tools/resolve-buildrequires.py)
    gzip (mtime 0) of {"format": 1, "release", "packages": {"<name>.<arch>": {
        "evr": "[E:]V-R", "repo", "srpm",
        "provides": [dep...], "requires": [dep...],
        "conflicts": [dep...], "obsoletes": [dep...],
        "recommends": [dep...], "suggests": [dep...],
        "supplements": [dep...], "enhances": [dep...],
        "files": ["/usr/bin/foo", ...]   # the file list subset present in primary.xml
    }}}
    Same package set as rpms.json.  A dep is a string "name" or "name OP [E:]V[-R]"
    with OP in = < > <= >=; rich (boolean) deps are kept verbatim, e.g.
    "(foo if bar)".  Weak deps are kept although mock builds use
    install_weak_deps=0: libsolv still uses them to choose between alternative
    providers (e.g. openssl-libs Suggests openssl-fips-provider, which decides
    who satisfies "fips-provider-so").
    ``rpmlib(...)`` requires and, unless --keep-kernel-abi is given, the kernel
    symbol-versioning deps ``kernel(...)`` / ``ksym(...)`` are dropped (they are
    >90% of all provides and only matter for kmod packages).

Derived files (docs/nix-native-design.md §3.2, §8.2; skipped with
--no-derived, regenerated alone from the committed lock with --derived-only):

builddeps.json  per SRPM the direct providers of every BuildRequire, providers
                tagged tool/lib/macro from the official filelists.xml
                (tools/lock_builddeps.py, tools/lock_filelists.py)
order.json      SRPM build graph, edge classes, feedback-arc set, build order
                (tools/lock_order.py; verified by checks.nn-order)
subpackages.json  rpmspec -q results per SRPM.  These need nix builds and
                are produced by tools/lock_subpackages.py (incremental); this
                tool only drops entries whose SRPM EVR changed and re-derives
                the repodata-dependent fields (shipped, prefix).

All output is deterministic: sorted keys, fixed formatting, no timestamps other
than the repomd revision/timestamps recorded as provenance in rpms.json.
"""

import argparse
import gzip
import hashlib
import io
import json
import os
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

DEFAULT_RELEASE = "10.2"
DEFAULT_REPOS = ["BaseOS", "AppStream", "CRB"]
BIN_ARCH = "x86_64"
KEEP_ARCHES = ("x86_64", "noarch")
TREES = {"source": "source/tree", "binary": BIN_ARCH + "/os"}

NS_REPO = "{http://linux.duke.edu/metadata/repo}"
NS_C = "{http://linux.duke.edu/metadata/common}"
NS_RPM = "{http://linux.duke.edu/metadata/rpm}"

FLAGS = {"EQ": "=", "LT": "<", "GT": ">", "LE": "<=", "GE": ">="}


def log(*a):
    print(*a, file=sys.stderr, flush=True)


# --------------------------------------------------------------------------
# rpm version comparison (port of rpmvercmp() from rpm/rpmio/rpmvercmp.c)
# --------------------------------------------------------------------------

def _isdigit(c):
    return "0" <= c <= "9"


def _isalpha(c):
    return ("a" <= c <= "z") or ("A" <= c <= "Z")


def _isalnum(c):
    return _isdigit(c) or _isalpha(c)


def rpmvercmp(a, b):
    """Compare two version (or release) strings like rpm does. Returns -1/0/1.

    Handles '~' (sorts before everything, even the end of the string) and
    '^' (sorts after the end of the string but before any other segment)."""
    if a == b:
        return 0
    i = j = 0
    la, lb = len(a), len(b)
    while i < la or j < lb:
        while i < la and not _isalnum(a[i]) and a[i] not in "~^":
            i += 1
        while j < lb and not _isalnum(b[j]) and b[j] not in "~^":
            j += 1
        # tilde: sorts before everything else
        ta = i < la and a[i] == "~"
        tb = j < lb and b[j] == "~"
        if ta or tb:
            if not ta:
                return 1
            if not tb:
                return -1
            i += 1
            j += 1
            continue
        # caret: like tilde, except the end of the string sorts before it
        ca = i < la and a[i] == "^"
        cb = j < lb and b[j] == "^"
        if ca or cb:
            if i >= la:
                return -1
            if j >= lb:
                return 1
            if not ca:
                return 1
            if not cb:
                return -1
            i += 1
            j += 1
            continue
        if not (i < la and j < lb):
            break
        si, sj = i, j
        if _isdigit(a[i]):
            while i < la and _isdigit(a[i]):
                i += 1
            while j < lb and _isdigit(b[j]):
                j += 1
            isnum = True
        else:
            while i < la and _isalpha(a[i]):
                i += 1
            while j < lb and _isalpha(b[j]):
                j += 1
            isnum = False
        s1, s2 = a[si:i], b[sj:j]
        if not s2:
            # numeric segments are always newer than alpha segments
            return 1 if isnum else -1
        if isnum:
            s1 = s1.lstrip("0")
            s2 = s2.lstrip("0")
            if len(s1) != len(s2):
                return 1 if len(s1) > len(s2) else -1
        if s1 != s2:
            return 1 if s1 > s2 else -1
    if i >= la and j >= lb:
        return 0
    return -1 if i >= la else 1


def parse_evr(s):
    """'[E:]V[-R]' -> (epoch:int, version:str, release:str|None)."""
    epoch = 0
    if ":" in s:
        e, s = s.split(":", 1)
        epoch = int(e) if e else 0
    if "-" in s:
        v, r = s.rsplit("-", 1)
    else:
        v, r = s, None
    return (epoch, v, r)


def evrcmp(a, b):
    """Compare (epoch, version, release) tuples.  A missing (None) release on
    either side is not compared (rpm semantics for 'foo >= 1.2')."""
    if a[0] != b[0]:
        return 1 if a[0] > b[0] else -1
    c = rpmvercmp(a[1], b[1])
    if c:
        return c
    if a[2] is None or b[2] is None:
        return 0
    return rpmvercmp(a[2], b[2])


def format_evr(epoch, ver, rel):
    s = ""
    if epoch not in (None, "", "0", 0):
        s = "%s:" % epoch
    s += ver or ""
    if rel:
        s += "-" + rel
    return s


# Vectors from rpm's tests/rpmvercmp.at (plus a few EVR ones).
_VERCMP_TESTS = [
    ("1.0", "1.0", 0), ("1.0", "2.0", -1), ("2.0", "1.0", 1),
    ("2.0.1", "2.0.1", 0), ("2.0", "2.0.1", -1), ("2.0.1", "2.0", 1),
    ("2.0.1a", "2.0.1a", 0), ("2.0.1a", "2.0.1", 1), ("2.0.1", "2.0.1a", -1),
    ("5.5p1", "5.5p1", 0), ("5.5p1", "5.5p2", -1), ("5.5p2", "5.5p1", 1),
    ("5.5p10", "5.5p10", 0), ("5.5p1", "5.5p10", -1), ("5.5p10", "5.5p1", 1),
    ("10xyz", "10.1xyz", -1), ("10.1xyz", "10xyz", 1),
    ("xyz10", "xyz10", 0), ("xyz10", "xyz10.1", -1), ("xyz10.1", "xyz10", 1),
    ("xyz.4", "xyz.4", 0), ("xyz.4", "8", -1), ("8", "xyz.4", 1),
    ("xyz.4", "2", -1), ("2", "xyz.4", 1),
    ("5.5p2", "5.6p1", -1), ("5.6p1", "5.5p2", 1),
    ("5.6p1", "6.5p1", -1), ("6.5p1", "5.6p1", 1),
    ("6.0.rc1", "6.0", 1), ("6.0", "6.0.rc1", -1),
    ("10b2", "10a1", 1), ("10a2", "10b2", -1),
    ("1.0aa", "1.0aa", 0), ("1.0a", "1.0aa", -1), ("1.0aa", "1.0a", 1),
    ("10.0001", "10.0001", 0), ("10.0001", "10.1", 0), ("10.1", "10.0001", 0),
    ("10.0001", "10.0039", -1), ("10.0039", "10.0001", 1),
    ("4.999.9", "5.0", -1), ("5.0", "4.999.9", 1),
    ("20101121", "20101121", 0), ("20101121", "20101122", -1),
    ("20101122", "20101121", 1),
    ("2_0", "2_0", 0), ("2.0", "2_0", 0), ("2_0", "2.0", 0),
    ("a", "a", 0), ("a+", "a+", 0), ("a+", "a_", 0), ("a_", "a+", 0),
    ("+a", "+a", 0), ("+a", "_a", 0), ("_a", "+a", 0),
    ("+_", "+_", 0), ("_+", "+_", 0), ("_+", "_+", 0),
    ("+", "_", 0), ("_", "+", 0),
    ("1.0~rc1", "1.0~rc1", 0), ("1.0~rc1", "1.0", -1), ("1.0", "1.0~rc1", 1),
    ("1.0~rc1", "1.0~rc2", -1), ("1.0~rc2", "1.0~rc1", 1),
    ("1.0~rc1~git123", "1.0~rc1~git123", 0),
    ("1.0~rc1~git123", "1.0~rc1", -1), ("1.0~rc1", "1.0~rc1~git123", 1),
    ("1.0^", "1.0^", 0), ("1.0^", "1.0", 1), ("1.0", "1.0^", -1),
    ("1.0^git1", "1.0^git1", 0), ("1.0^git1", "1.0", 1), ("1.0", "1.0^git1", -1),
    ("1.0^git1", "1.0^git2", -1), ("1.0^git2", "1.0^git1", 1),
    ("1.0^git1", "1.01", -1), ("1.01", "1.0^git1", 1),
    ("1.0^20160101", "1.0^20160101", 0), ("1.0^20160101", "1.0.1", -1),
    ("1.0.1", "1.0^20160101", 1),
    ("1.0^20160101^git1", "1.0^20160101^git1", 0),
    ("1.0^20160102", "1.0^20160101^git1", 1),
    ("1.0^20160101^git1", "1.0^20160102", -1),
    ("1.0~rc1^git1", "1.0~rc1^git1", 0), ("1.0~rc1^git1", "1.0~rc1", 1),
    ("1.0~rc1", "1.0~rc1^git1", -1),
    ("1.0^git1~pre", "1.0^git1~pre", 0), ("1.0^git1", "1.0^git1~pre", 1),
    ("1.0^git1~pre", "1.0^git1", -1),
]


def helpers():
    """The tools/lock_*.py helper modules (imported lazily: the plain
    repodata path does not need them)."""
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)  # -I drops the script dir from sys.path
    sys.dont_write_bytecode = True
    import lock_builddeps
    import lock_filelists
    import lock_order
    import lock_subpackages
    return lock_filelists, lock_builddeps, lock_order, lock_subpackages


def self_test():
    bad = 0
    for a, b, want in _VERCMP_TESTS:
        got = rpmvercmp(a, b)
        if got != want:
            log("FAIL rpmvercmp(%r, %r) = %d, want %d" % (a, b, got, want))
            bad += 1
    for a, b, want in [
        ("1:1.0-1", "2.0-1", 1), ("0:1.0-1", "1.0-1", 0), ("1.0", "1.0-5", 0),
        ("1.0-1.el10", "1.0-1.el10_2", -1), ("2.39-142.el10_2", "2.39-99.el10_2", 1),
    ]:
        got = evrcmp(parse_evr(a), parse_evr(b))
        if got != want:
            log("FAIL evrcmp(%r, %r) = %d, want %d" % (a, b, got, want))
            bad += 1
    log("self-test: %d failures (%d cases)" % (bad, len(_VERCMP_TESTS) + 5))
    _fl, bd, order, sub = helpers()
    hbad = bd.selftest() + order.selftest() + sub.selftest()
    log("self-test (lock_builddeps, lock_order, lock_subpackages): %d failures" % hbad)
    return bad == 0 and hbad == 0


# --------------------------------------------------------------------------
# download
# --------------------------------------------------------------------------

def http_get(url, retries=4):
    req = urllib.request.Request(url, headers={"User-Agent": "el-nixos-update-lock/1"})
    last = None
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code == 404:
                raise
            last = e
        except (urllib.error.URLError, OSError) as e:
            last = e
        time.sleep(2 ** attempt)
    raise last


def fetch_first(mirrors, relpath):
    """Fetch relpath from the first mirror that has it. Returns (bytes, url)."""
    errors = []
    for m in mirrors:
        url = "%s/%s" % (m.rstrip("/"), relpath)
        try:
            return http_get(url), url
        except Exception as e:  # noqa: BLE001 - report and try next mirror
            errors.append("%s: %s" % (url, e))
    raise RuntimeError("could not fetch %s:\n  %s" % (relpath, "\n  ".join(errors)))


def get_primary(mirrors, repo, tree, cache_dir):
    """Download repomd.xml + primary.xml.gz (cached by checksum, verified).
    Returns (path to primary.xml.gz, provenance dict)."""
    return get_repodata(mirrors, repo, tree, cache_dir, "primary")


def get_repodata(mirrors, repo, tree, cache_dir, kind):
    """Download repomd.xml + the <kind> (primary, filelists) metadata file,
    cached by checksum and verified.  Returns (path, provenance dict)."""
    base = "%s/%s" % (repo, TREES[tree])
    repomd, url = fetch_first(mirrors, base + "/repodata/repomd.xml")
    root = ET.fromstring(repomd)
    revision = root.findtext(NS_REPO + "revision")
    for data in root.findall(NS_REPO + "data"):
        if data.get("type") == kind:
            break
    else:
        raise RuntimeError("no %s in %s" % (kind, url))
    ck = data.find(NS_REPO + "checksum")
    if ck.get("type") != "sha256":
        raise RuntimeError("unsupported checksum type %s in %s" % (ck.get("type"), url))
    sha = ck.text.strip()
    href = data.find(NS_REPO + "location").get("href")
    ts = int(data.findtext(NS_REPO + "timestamp") or 0)
    os.makedirs(cache_dir, exist_ok=True)
    dest = os.path.join(cache_dir, "%s-%s-%s-%s.xml.gz" % (repo, tree, sha, kind))
    if os.path.exists(dest) and sha256_file(dest) == sha:
        log("  cached   %s %s" % (base, sha[:12]))
    else:
        log("  download %s/%s" % (base, href))
        blob, _ = fetch_first(mirrors, base + "/" + href)
        got = hashlib.sha256(blob).hexdigest()
        if got != sha:
            raise RuntimeError("checksum mismatch for %s: %s != %s" % (href, got, sha))
        tmp = dest + ".tmp"
        with open(tmp, "wb") as f:
            f.write(blob)
        os.replace(tmp, dest)
    return dest, {"revision": revision, kind: sha, "timestamp": ts}


def sha256_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# --------------------------------------------------------------------------
# primary.xml parsing
# --------------------------------------------------------------------------

def dep_string(entry):
    a = entry.attrib
    s = a["name"]
    fl = a.get("flags")
    if fl:
        s += " %s %s" % (FLAGS[fl], format_evr(a.get("epoch"), a.get("ver"), a.get("rel")))
    return s


def dep_list(fmt, tag, drop):
    el = fmt.find(NS_RPM + tag)
    if el is None:
        return []
    out = set()
    for e in el.findall(NS_RPM + "entry"):
        name = e.get("name")
        if drop(name):
            continue
        out.add(dep_string(e))
    return sorted(out)


def iter_packages(path):
    """Yield parsed <package> elements, clearing them afterwards."""
    with gzip.open(path) as f:
        for _ev, el in ET.iterparse(f):
            if el.tag == NS_C + "package":
                yield el
                el.clear()


def pkg_header(el):
    v = el.find(NS_C + "version")
    ck = el.find(NS_C + "checksum")
    if ck.get("type") != "sha256":
        raise RuntimeError("unsupported package checksum type " + ck.get("type"))
    return {
        "name": el.findtext(NS_C + "name"),
        "arch": el.findtext(NS_C + "arch"),
        "epoch": int(v.get("epoch") or 0),
        "version": v.get("ver"),
        "release": v.get("rel"),
        "path": el.find(NS_C + "location").get("href"),
        "sha256": ck.text.strip(),
        "size": int(el.find(NS_C + "size").get("package")),
    }


def evr_of(d):
    return (d["epoch"], d["version"], d["release"])


def srpm_name(filename):
    base = filename[:-len(".src.rpm")] if filename.endswith(".src.rpm") else filename
    parts = base.rsplit("-", 2)
    if len(parts) != 3:
        raise ValueError("bad sourcerpm %r" % filename)
    return parts[0]


def drop_rpmlib(name):
    return name.startswith("rpmlib(")


def make_drop(keep_kernel_abi):
    def drop(name):
        if name.startswith("rpmlib("):
            return True
        if not keep_kernel_abi and (name.startswith("kernel(") or name.startswith("ksym(")):
            return True
        return False
    return drop


def parse_sources(path, repo, srpms, stats):
    for el in iter_packages(path):
        h = pkg_header(el)
        if h["arch"] not in ("src", "nosrc"):
            continue
        stats["srpm_entries"] += 1
        cur = srpms.get(h["name"])
        if cur is not None and evrcmp(evr_of(h), evr_of(cur)) <= 0:
            continue
        fmt = el.find(NS_C + "format")
        srpms[h["name"]] = {
            "epoch": h["epoch"], "version": h["version"], "release": h["release"],
            "repo": repo, "path": h["path"], "sha256": h["sha256"], "size": h["size"],
            "buildRequires": dep_list(fmt, "requires", drop_rpmlib),
        }


def parse_binaries(path, repo, rpms, deps, drop, stats):
    for el in iter_packages(path):
        h = pkg_header(el)
        stats["rpm_entries"] += 1
        if h["arch"] not in KEEP_ARCHES:
            stats["dropped_arch"][h["arch"]] = stats["dropped_arch"].get(h["arch"], 0) + 1
            continue
        key = "%s.%s" % (h["name"], h["arch"])
        cur = rpms.get(key)
        if cur is not None and evrcmp(evr_of(h), evr_of(cur)) <= 0:
            continue
        fmt = el.find(NS_C + "format")
        sourcerpm = fmt.findtext(NS_RPM + "sourcerpm") or ""
        h["repo"] = repo
        h["sourcerpm"] = sourcerpm
        h["srpm"] = srpm_name(sourcerpm)
        rpms[key] = h
        files = sorted({f.text for f in fmt.findall(NS_C + "file") if f.text})
        deps[key] = {
            "evr": format_evr(h["epoch"], h["version"], h["release"]),
            "repo": repo,
            "srpm": h["srpm"],
            "provides": dep_list(fmt, "provides", drop),
            "requires": dep_list(fmt, "requires", drop),
            "conflicts": dep_list(fmt, "conflicts", drop),
            "obsoletes": dep_list(fmt, "obsoletes", drop),
            "recommends": dep_list(fmt, "recommends", drop),
            "suggests": dep_list(fmt, "suggests", drop),
            "supplements": dep_list(fmt, "supplements", drop),
            "enhances": dep_list(fmt, "enhances", drop),
            "files": files,
        }


# --------------------------------------------------------------------------
# output
# --------------------------------------------------------------------------

def line_obj(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def dump_one_per_line(top):
    """JSON with sorted keys where every value of a nested dict-of-dicts is on
    its own line.  Valid JSON; diff-friendly; ~half the size of indent=2."""
    out = ["{"]
    keys = sorted(top)
    for i, k in enumerate(keys):
        v = top[k]
        comma = "," if i < len(keys) - 1 else ""
        if isinstance(v, dict) and v and all(isinstance(x, (dict, list)) for x in v.values()):
            out.append("  %s: {" % json.dumps(k))
            sub = sorted(v)
            for j, sk in enumerate(sub):
                c2 = "," if j < len(sub) - 1 else ""
                out.append("    %s: %s%s" % (json.dumps(sk), line_obj(v[sk]), c2))
            out.append("  }" + comma)
        else:
            out.append("  %s: %s%s" % (json.dumps(k), line_obj(v), comma))
    out.append("}")
    return "\n".join(out) + "\n"


def write_text(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def write_gzip_json(path, obj):
    raw = (json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
           + "\n").encode()
    buf = io.BytesIO()
    # filename="" and mtime=0 make the gzip header reproducible
    with gzip.GzipFile(filename="", mode="wb", fileobj=buf, compresslevel=9, mtime=0) as g:
        g.write(raw)
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(buf.getvalue())
    os.replace(tmp, path)
    return len(raw)


def dist_for(release):
    parts = release.split(".")
    if len(parts) >= 2:
        return ".el%s_%s" % (parts[0], parts[1])
    return ".el%s" % parts[0]


def write_derived(outdir, rel, cache):
    """builddeps.json + order.json from the lock files in outdir, and the
    subpackages.json refresh (see the module docstring)."""
    fl, bd, order, sub = helpers()
    with open(os.path.join(outdir, "rpms.json")) as f:
        rpms_doc = json.load(f)
    summary = fl.file_summary(sys.modules[__name__], rpms_doc, cache)
    doc = bd.generate(outdir, summary)
    p = os.path.join(outdir, "builddeps.json")
    write_text(p, dump_one_per_line(doc))
    log("wrote %s (%d bytes)" % (p, os.path.getsize(p)))
    odoc = order.compute(doc)
    p = os.path.join(outdir, "order.json")
    write_text(p, dump_one_per_line(odoc))
    log("wrote %s: %s" % (p, json.dumps(odoc["stats"], sort_keys=True)))
    missing = sub.refresh(outdir, rel, rpms_doc, summary)
    if missing:
        log("subpackages.json: %d SRPMs without an rpmspec result: run "
            "python3 -I tools/lock_subpackages.py --stale" % missing)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--release", default=DEFAULT_RELEASE)
    ap.add_argument("--repos", nargs="+", default=DEFAULT_REPOS)
    ap.add_argument("--out", default="lock", help="output root (default: ./lock)")
    ap.add_argument("--cache-dir", default=None,
                    help="where downloaded metadata is cached (default: ./.cache/repodata)")
    ap.add_argument("--mirror", action="append", default=None,
                    help="mirror base URL including the release dir (repeatable; "
                         "default: dl.rockylinux.org pub + vault)")
    ap.add_argument("--keep-kernel-abi", action="store_true",
                    help="keep kernel(...)/ksym(...) deps in deps.json.gz")
    ap.add_argument("--self-test", action="store_true", help="run the self-tests and exit")
    ap.add_argument("--no-derived", action="store_true",
                    help="only srpms.json, rpms.json, deps.json.gz")
    ap.add_argument("--derived-only", action="store_true",
                    help="only regenerate builddeps.json/order.json and refresh "
                         "subpackages.json from the committed lock files")
    args = ap.parse_args(argv)

    if args.self_test:
        return 0 if self_test() else 1
    if not self_test():
        return 1

    if args.out == "lock" and not os.path.exists("flake.nix"):
        log("error: run from the el-nixos repository root, or pass --out")
        return 2
    rel = args.release
    mirrors = args.mirror or [
        "https://dl.rockylinux.org/pub/rocky/%s" % rel,
        "https://dl.rockylinux.org/vault/rocky/%s" % rel,
    ]
    cache = args.cache_dir or os.path.join(".cache", "repodata", rel)
    outdir = os.path.join(args.out, "rocky-%s" % rel)
    os.makedirs(outdir, exist_ok=True)
    if args.derived_only:
        write_derived(outdir, rel, cache)
        return 0

    stats = {"srpm_entries": 0, "rpm_entries": 0, "dropped_arch": {}}
    srpms, rpms, deps, prov = {}, {}, {}, {}
    drop = make_drop(args.keep_kernel_abi)
    for repo in args.repos:
        for tree in ("source", "binary"):
            path, p = get_primary(mirrors, repo, tree, cache)
            prov["%s/%s" % (repo, TREES[tree])] = p
            t0 = time.time()
            if tree == "source":
                parse_sources(path, repo, srpms, stats)
            else:
                parse_binaries(path, repo, rpms, deps, drop, stats)
            log("  parsed   %s/%s in %.1fs" % (repo, TREES[tree], time.time() - t0))

    by_srpm = {}
    for key, r in rpms.items():
        by_srpm.setdefault(r["srpm"], []).append(key)
    for v in by_srpm.values():
        v.sort()

    # --- srpms.json (contract: docs/DESIGN.md) ---
    lock = {"release": rel, "dist": dist_for(rel), "mirrors": mirrors,
            "srpms": dict(sorted(srpms.items()))}
    p_srpms = os.path.join(outdir, "srpms.json")
    write_text(p_srpms, json.dumps(lock, indent=2, sort_keys=True, ensure_ascii=False) + "\n")

    # --- rpms.json ---
    rpms_doc = {
        "format": 1,
        "release": rel,
        "arches": list(KEEP_ARCHES),
        "mirrors": mirrors,
        "repodata": prov,
        "rpms": rpms,
        "bySrpm": by_srpm,
    }
    p_rpms = os.path.join(outdir, "rpms.json")
    write_text(p_rpms, dump_one_per_line(rpms_doc))

    # --- deps.json.gz ---
    p_deps = os.path.join(outdir, "deps.json.gz")
    raw = write_gzip_json(p_deps, {"format": 1, "release": rel,
                                   "keepKernelAbi": bool(args.keep_kernel_abi),
                                   "packages": deps})

    # --- report ---
    no_src = sorted(s for s in by_srpm if s not in srpms)
    evr_mismatch = sorted(
        k for k, r in rpms.items()
        if r["srpm"] in srpms and r["sourcerpm"] != "%s-%s-%s.src.rpm" % (
            r["srpm"], srpms[r["srpm"]]["version"], srpms[r["srpm"]]["release"]))
    log("")
    log("srpm entries %d -> %d SRPM names" % (stats["srpm_entries"], len(srpms)))
    log("rpm entries  %d -> %d name.arch (dropped arches: %s)"
        % (stats["rpm_entries"], len(rpms), stats["dropped_arch"] or "none"))
    log("binary SRPM names without a source in these repos: %d %s"
        % (len(no_src), no_src[:20]))
    log("binaries whose sourcerpm != locked SRPM NEVR: %d %s"
        % (len(evr_mismatch), evr_mismatch[:10]))
    for p in (p_srpms, p_rpms, p_deps):
        log("wrote %s (%d bytes)" % (p, os.path.getsize(p)))
    log("      (deps.json uncompressed: %d bytes)" % raw)
    if not args.no_derived:
        write_derived(outdir, rel, cache)
    return 0


if __name__ == "__main__":
    sys.exit(main())
