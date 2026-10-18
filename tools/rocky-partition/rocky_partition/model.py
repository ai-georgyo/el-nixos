"""The partition context: plan, outputs, subpackages, header entries, the
canonical path mapping (design §2.2 Phase A) and the ownership index."""
import collections
import os
import posixpath
import stat

from . import headers as H
from .plan import PlanError, substitute

USRMERGE = ("bin", "sbin", "lib", "lib64")
FHS_RUNTIME = ("etc", "var", "run")
# top-level dirs too generic to stand for a missing path below them
STD_TOP = {"", "bin", "sbin", "lib", "lib64", "libexec", "include", "share", "etc", "var", "run", "src"}


class Entry:
    """one header file entry of one subpackage"""
    __slots__ = ("sub", "output", "hpath", "ns", "rel", "flags", "mode", "linkto", "inode", "digest", "user",
                 "group", "caps", "size", "nlink", "kind", "ghost", "debugsub")

    def __init__(self, sub, output, f, ns, rel, debugsub):
        self.sub, self.output, self.hpath, self.ns, self.rel = sub, output, f["path"], ns, rel
        self.flags, self.mode, self.linkto = f["flags"], f["mode"], f["linkto"]
        self.inode, self.digest, self.user, self.group = f["inode"], f["digest"], f["user"], f["group"]
        self.caps, self.size, self.nlink = f["caps"], f["size"], f["nlink"]
        fmt = stat.S_IFMT(self.mode)
        self.kind = "dir" if fmt == stat.S_IFDIR else "link" if fmt == stat.S_IFLNK else "file"
        self.ghost = bool(self.flags & 64)
        self.debugsub = debugsub


class Ctx:
    def __init__(self, plan, report):
        self.plan, self.report = plan, report
        self.replay_old = None      # compile prefix of a replayed tree (P), remapped at the end
        self.subs = {}              # subpackage -> header record
        self.sub_output = {}        # subpackage -> output
        self.entries = []           # [Entry]
        self.owners = collections.defaultdict(dict)    # rel -> {output: [Entry]}
        self.implied = collections.defaultdict(set)    # dir rel -> outputs with entries below
        self.out_requires = collections.defaultdict(set)
        self.sub_requires = {}
        self.edges = collections.defaultdict(dict)     # Y -> {X: evidence} (analysis graph, phase F)
        self.hidden = collections.defaultdict(set)     # Y -> {store path}
        self.subref = collections.Counter()            # (sub, sub) reference counts (merge report)
        self.dropped = {}                              # rel -> Entry (dropped build-id links)
        self.integrity = None                          # integrity.Integrity (FIPS integrity files)

    # ------------------------------------------------------------------ setup
    def setup_outputs(self, outputs):
        p = self.plan
        if not outputs:
            raise PlanError("no output paths (plan.outputs, or the attrs file's outputs)")
        self.out = dict(outputs)
        self.prefix_output = p.prefixOutput
        if self.prefix_output not in self.out:
            raise PlanError("prefixOutput %s is not an output" % self.prefix_output)
        self.debug_output = p.debugOutput if p.debugOutput in self.out else None
        self.unmanaged = set(p.unmanagedOutputs)
        for s, o in p.subpackages.items():
            if o not in self.out:
                raise PlanError("subpackage %s maps to unknown output %s" % (s, o))
        self.store_dir = p.storeDir.rstrip("/")
        # compile prefix
        self.P = p.prefix or self.out[self.prefix_output]
        if self.replay_old:
            self.P = self.replay_old
        elif self.P != self.out[self.prefix_output]:
            raise PlanError("prefix %s differs from output %s (%s): use --replay/--remap"
                            % (self.P, self.prefix_output, self.out[self.prefix_output]))
        self.Pb = self.P.encode()
        self.layout_prefixes = sorted((p for o, p in self.out.items() if o != self.prefix_output), key=len, reverse=True)
        self.system_dirs = [substitute(d, self.out) for d in p.systemLibDirs]
        self.input_dirs = [substitute(d, self.out) for d in p.inputLibDirs]
        self.allowed = None
        if p.allowedStorePaths is not None:
            self.allowed = {self.hash_of(substitute(x, self.out)) for x in p.allowedStorePaths}
        self.managed = [o for o in self.out if o not in self.unmanaged]
        self.order = {o: i for i, o in enumerate(self.out)}

    @staticmethod
    def hash_of(path):
        b = os.path.basename(path.rstrip("/"))
        return b.split("-", 1)[0]

    def out_of_sub(self, sub):
        if H.is_debug(sub):
            return self.debug_output
        return self.plan.subpackages.get(sub)

    # ------------------------------------------------------------------ Phase A
    def canon(self, path, debugsub=False):
        """header path -> (namespace, rel); namespaces: usr (the prefix,
        /usr and its usrmerge spellings), debug (lib/debug, src/debug of a
        debug subpackage), dropped (build-id links of other subpackages),
        fhs (/etc, /var, /run), other (any other absolute path)"""
        P = self.P
        lay = None
        if not (path == P or path.startswith(P + "/")):
            # a `layout` build compiles some macro dirs as another output's path
            lay = next((q for q in self.layout_prefixes if path == q or path.startswith(q + "/")), None)
        if path == P or path.startswith(P + "/"):
            urel = path[len(P):].strip("/")
        elif lay is not None:
            urel = path[len(lay):].strip("/")
        elif path == "/usr" or path.startswith("/usr/"):
            urel = path[4:].strip("/")
        else:
            top = path.lstrip("/").split("/", 1)[0]
            if top in USRMERGE:
                urel = path.strip("/")
            elif top in FHS_RUNTIME:
                return "fhs", path.strip("/")
            else:
                return "other", path.strip("/")
        urel = norm_rel(urel)
        if urel == "lib/debug" or urel.startswith("lib/debug/") or urel == "src/debug" or urel.startswith("src/debug/"):
            return ("debug" if debugsub else "usr"), urel
        if (urel == "lib/.build-id" or urel.startswith("lib/.build-id/")) and not debugsub:
            return "dropped", urel
        return "usr", urel

    def canon_target(self, abspath):
        """absolute symlink target (rpm namespace) -> (namespace, rel)"""
        ns, rel = self.canon(abspath, True)
        return ("usr" if ns == "debug" else ns), rel

    def load_entries(self, subs):
        rep = self.report
        self.subs = subs
        declared = set(self.plan.subpackages)
        built = {s for s in subs if not H.is_debug(s)}
        for s in sorted(built - declared):
            rep.error("undeclared-subpackage", "subpackage %s was built but is not in plan.subpackages" % s, subpackage=s)
        for s in sorted(declared - built):
            rep.error("missing-subpackage", "subpackage %s is in plan.subpackages but was not built" % s, subpackage=s)
        dropped = collections.Counter()
        for s in sorted(subs):
            o = self.out_of_sub(s)
            if o is None:
                if H.is_debug(s):
                    rep.error("undeclared-subpackage", "debug subpackage %s built but plan.debugOutput is not an output" % s,
                              subpackage=s)
                continue
            self.sub_output[s] = o
            dbg = H.is_debug(s)
            for f in subs[s]["files"]:
                ns, rel = self.canon(f["path"], dbg)
                e = Entry(s, o, f, ns, rel, dbg)
                self.entries.append(e)
                if ns == "dropped":
                    dropped[s] += 1
                    self.dropped.setdefault(rel, e)
                    continue
                if ns == "other":
                    rep.info("other-absolute", "%s: %s placed at %s/%s" % (s, f["path"], o, rel), subpackage=s, path=f["path"])
                if rel == "":
                    continue
                self.owners[rel].setdefault(o, []).append(e)
                parts = rel.split("/")
                for i in range(1, len(parts)):
                    self.implied["/".join(parts[:i])].add(o)
        for s, n in sorted(dropped.items()):
            rep.info("build-id-dropped", "%s: %d usr/lib/.build-id entries dropped" % (s, n), subpackage=s)
        # Requires gating
        if self.plan.requires is not None:
            self.sub_requires = {s: set(v) for s, v in self.plan.requires.items()}
        else:
            self.sub_requires = H.sibling_requires({s: r for s, r in subs.items() if s in self.sub_output})
        for s, req in self.sub_requires.items():
            if s not in self.sub_output:
                continue
            for p in req:
                if p in self.sub_output and self.sub_output[p] != self.sub_output[s]:
                    self.out_requires[self.sub_output[s]].add(self.sub_output[p])

    # ------------------------------------------------------------------ lookups
    def lookup(self, rel):
        """-> (owners: set of outputs, kind: file|dir|link|missing)"""
        if rel in self.owners:
            os_ = self.owners[rel]
            kinds = {e.kind for es in os_.values() for e in es}
            if kinds == {"dir"}:
                return set(os_) | self.implied.get(rel, set()), "dir"
            return set(os_), ("link" if kinds == {"link"} else "file")
        if rel in self.implied:
            return set(self.implied[rel]), "dir"
        return set(), "missing"

    def anchor(self, rel):
        """the owned path a reference stands for: rel itself if it exists,
        else its deepest owned ancestor that is specific enough (not a
        standard top-level dir); None = dangling"""
        if rel in self.owners or rel in self.implied:
            return rel
        r = rel
        while "/" in r:
            r = r.rsplit("/", 1)[0]
            if r in STD_TOP:
                return None
            if r in self.owners or r in self.implied:
                return r
        return None

    def requires(self, y, x):
        return x in self.out_requires.get(y, ())

    def add_edge(self, y, x, why):
        if y != x:
            self.edges[y].setdefault(x, why)

    def subs_of(self, output, rel):
        es = self.owners.get(rel, {}).get(output, [])
        return sorted({e.sub for e in es})

    def path_of(self, output, rel):
        return self.out[output] + ("/" + rel if rel else "")


def norm_rel(rel):
    """normalise a prefix-relative path ('a//b/./c/' -> 'a/b/c');
    None if it escapes the prefix"""
    if not rel:
        return ""
    n = posixpath.normpath("/" + rel)
    if n.startswith("//"):
        n = n[1:]
    n = n.lstrip("/")
    return "" if n == "." else n
