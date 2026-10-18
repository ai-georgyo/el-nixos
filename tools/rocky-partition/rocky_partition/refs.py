"""Phase D (reference scan, text rewriting), Phase G (pieced and nested
references) and Phase F (forwarding stubs), design §2.5, §2.7, §2.8."""
import collections
import os
import re

from . import elf as E
from . import scan as S
from .decoders import nested_blobs
from .model import STD_TOP, norm_rel
from .plan import output_rel_match, rel_match

# interpreters that stay FHS at run time (design §1.4)
RUNTIME_FHS = ("/bin/sh", "/usr/bin/env")
# documentation: references there are recorded (Nix edges) but not errors
DOC_DIRS = ("share/doc/", "share/man/", "share/info/", "share/gtk-doc/", "share/help/")
FHS_LITERAL = re.compile(rb"(?<![A-Za-z0-9_.+@%/-])/(?:usr|lib64|bin|sbin)/[A-Za-z0-9._+-]+")
# CMake export files (install(EXPORT) <Pkg>Targets[-<config>].cmake): CMake
# checks at find_package() time that every file they name exists
CMAKE_IMPORT = re.compile(rb"_(?:cmake_import_check_files_for|IMPORT_CHECK_FILES_FOR)_|IMPORTED_LOCATION")


def walk_files(root):
    """regular files below an output (sorted, symlinks skipped)"""
    for d, dirs, files in os.walk(root):
        dirs.sort()
        for n in sorted(files):
            p = os.path.join(d, n)
            if not os.path.islink(p):
                yield os.path.relpath(p, root), p


class Refs:
    def __init__(self, ctx):
        self.ctx = ctx
        self.rx = S.prefix_re(ctx.Pb)
        self.srx = S.store_re(sorted({ctx.store_dir, "/nix/store"}))
        self.hash_start = len(os.path.dirname(ctx.P)) + 1
        self.own = {ctx.hash_of(ctx.P)} | {ctx.hash_of(p) for p in ctx.out.values()}
        self.pending = []                       # binary refs for phase F
        self.split = []                         # ld.so token expansions of the last classify() owned elsewhere
        self.elves = {}                         # (output, rel) -> Elf (dynamic, for phase E)
        self.rewrites = collections.Counter()   # (Y, X) -> n
        self.rewrite_samples = []
        self.fhs = collections.defaultdict(lambda: [0, []])
        self.foreign = collections.defaultdict(set)
        self.rpath_foreign = {}                 # (output, rel) -> hashes in RUNPATH, decided after phase E
        self.pieces = []
        self.nested = []

    def check_rpath_foreign(self):
        """case 7 for RUNPATH entries, after phase E: a foreign store path
        still in the final RUNPATH/RPATH must be allowed"""
        ctx, rep = self.ctx, self.ctx.report
        for (y, rel), hs in sorted(self.rpath_foreign.items()):
            with open(ctx.path_of(y, rel), "rb") as f:
                ef = E.parse(f.read())
            final = ((ef.runpath if ef.runpath is not None else ef.rpath) or "") if ef is not None else ""
            for m in self.srx.finditer(final.encode()):
                h = m.group(1).decode()
                if h in self.own:
                    continue
                self.foreign[h].add("%s:%s" % (y, rel))
                if ctx.allowed is not None and h not in ctx.allowed:
                    rep.error("foreign-store-path", "%s/%s: RUNPATH entry %s is not an allowed store path"
                              % (y, rel, m.group(0).decode()), output=y, file=rel)
        if self.foreign:
            rep.section("foreignStorePaths", {h[:8] + "...": sorted(v)[:10] for h, v in sorted(self.foreign.items())})

    # -------------------------------------------------------------- classify
    def classify(self, y, rel):
        """-> (case, owner(s), anchor); case: out | other | union | shared-self | dangling | bare
        (bare: the prefix itself, or a standard top-level dir several outputs fill)"""
        self.split = []
        if rel is not None and S.TOKEN_RE.search(rel):
            # ld.so dynamic string tokens: classify the expansions ($LIB -> lib64 first)
            exp = [norm_rel(S.TOKEN_RE.sub(v, rel)) for v in ("lib64", "lib")] if "LIB" in rel \
                else [norm_rel(S.TOKEN_RE.sub("x86_64", rel))]
            res = [self._classify(y, e) for e in exp]
            first = res[0]
            if all(r[:2] == first[:2] or r[0] == "dangling" for r in res[1:]):
                return first
            if first[0] in ("out", "other", "shared-self"):
                # the native expansion decides; the others are not found under
                # its owner (scan_file reports them as dangling)
                self.split = [(e, r) for e, r in zip(exp[1:], res[1:]) if r[:2] != first[:2] and r[0] != "dangling"]
                return first
            return "union", set().union(*[r[1] if isinstance(r[1], set) else {r[1]} for r in res if r[1]]), first[2]
        return self._classify(y, rel)

    def _classify(self, y, rel):
        ctx = self.ctx
        if not rel:
            return "bare", None, ""
        anc = ctx.anchor(rel)
        if anc is None:
            return "dangling", None, None
        owners, kind = ctx.lookup(anc)
        out = ctx.prefix_output
        if len(owners) > 1:
            if kind == "dir":
                return ("bare" if anc in STD_TOP else "union"), owners, anc
            if out in owners:
                return "out", out, anc
            if y in owners:
                return "shared-self", y, anc
            req = [o for o in owners if ctx.requires(y, o)]
            if len(req) == 1:
                return "other", req[0], anc
            return "union", owners, anc
        x = next(iter(owners))
        return ("out" if x == out else "other"), x, anc

    # -------------------------------------------------------------- phase D/G
    def scan_all(self):
        ctx = self.ctx
        for y in ctx.managed:
            for rel, path in walk_files(ctx.out[y]):
                self.scan_file(y, rel, path)
        rep = ctx.report
        rep.section("rewrites")["counts"] = {"%s->%s" % k: n for k, n in sorted(self.rewrites.items())}
        rep.section("rewrites")["samples"] = self.rewrite_samples
        rep.section("fhsLiterals", {k: {"files": v[0], "samples": v[1]} for k, v in sorted(self.fhs.items())})
        rep.section("piecedRefs", self.pieces)
        rep.section("nestedRefs", self.nested[:ctx.plan.maxSamples * 5])
        if self.foreign:
            rep.section("foreignStorePaths", {h[:8] + "...": sorted(v)[:10] for h, v in sorted(self.foreign.items())})

    def scan_file(self, y, rel, path):
        ctx, rep, plan = self.ctx, self.ctx.report, self.ctx.plan
        out = ctx.prefix_output
        with open(path, "rb") as f:
            data = f.read()
        kind = S.kind_of(data)
        ef = E.parse(data) if kind == "elf" else None
        if ef is not None and ef.dynamic and ef.needed and ef.etype in (E.ET_EXEC, E.ET_DYN):
            self.elves[(y, rel)] = ef
        if ef is not None and ctx.integrity is not None:
            ctx.integrity.note_elf(y, rel, path, ef)
        spans = ef.rpath_spans if ef is not None else []
        dirty = False
        if kind == "text" and y != out and rel.endswith(".pc"):
            nd = self._pc_expand(data)
            if nd != data:
                rep.info("pc-expanded", "%s/%s: prefix-derived pkg-config variables written out in full" % (y, rel),
                         output=y, file=rel)
                data, dirty = nd, True
        if kind == "text" and y != out and rel.endswith(".cmake"):
            nd = self._cmake_expand(data)
            if nd != data:
                rep.info("cmake-expanded", "%s/%s: ${_IMPORT_PREFIX} (the absolute prefix) written out in full" % (y, rel),
                         output=y, file=rel)
                data, dirty = nd, True
        full = S.prefix_refs(data, self.rx)
        edits = []
        file_subs = ctx.subs_of(y, rel)
        doc = rel.startswith(DOC_DIRS)
        cmake_export = kind == "text" and rel.endswith(".cmake") and bool(CMAKE_IMPORT.search(data))
        for start, end, tail in full:
            r = norm_rel(tail) if tail.startswith("/") else None
            if not r:
                r = None                                  # bare, "$P/", or glued to other characters
            case, x, anc = self.classify(y, r)
            where = dict(output=y, file=rel, ref=ctx.P + tail)
            in_rpath = any(a <= start < b for a, b in spans)
            if self.split and not in_rpath:
                self._token_split(y, rel, tail, case, x, kind, doc, where)
            self._subref(file_subs, x if case in ("out", "other", "shared-self") else None, anc)
            if case == "out":
                ctx.add_edge(y, out, "%s: %s" % (rel, tail))
            elif case == "bare":
                if kind == "text" and y != out and anc and y in x and self._self_dir(anc):
                    self._self_rewrite(y, rel, tail, anc, start, edits, where)
                    continue
                ctx.add_edge(y, out, "%s: bare prefix" % rel)
                what = ("the bare prefix" if not anc else
                        "$%s/%s, a top-level directory several outputs fill" % (out, anc))
                ack = output_rel_match(y, rel, plan.prefixRelativeOk) or (anc and rel_match(anc, plan.unionDirs))
                if not ack and kind == "text" and rel.endswith(".pc") and self._unused_pc_var(data, start):
                    ack = "pkg-config variable defined as %s and not used in the file" % ("the prefix" if not anc else anc)
                if not ack and kind == "text" and rel.endswith(".cmake") and self._unused_cmake_prefix(data, start):
                    ack = "CMake export file: _IMPORT_PREFIX defined as the prefix, every use written out in full"
                if not ack and doc:
                    ack = "documentation"
                if y == out or in_rpath or y == ctx.debug_output:
                    rep.info("prefix-relative-out", "%s/%s: %s" % (y, rel, what), **where)
                elif ack:
                    rep.info("prefix-relative", "%s/%s names %s (acked: %s)" % (y, rel, what, ack), **where)
                else:
                    rep.error("prefix-relative", "%s/%s names %s: prefix-relative software split across outputs;"
                              " merge %s into %s (mergeOutputs) or ack (prefixRelativeOk)" % (y, rel, what, y, out),
                              **where)
            elif case == "union":
                if kind == "text" and y != out and y in x and self._self_dir(anc):
                    self._self_rewrite(y, rel, tail, anc, start, edits, where)
                    continue
                ctx.add_edge(y, out, "%s: %s (union)" % (rel, tail))
                ack = rel_match(anc, plan.unionDirs) or rel_match(r, plan.runtimeSearchPaths) \
                    or rel_match(anc, plan.runtimeSearchPaths) or output_rel_match(y, rel, plan.prefixRelativeOk)
                if ack or y == ctx.debug_output or in_rpath or doc:
                    pass
                else:
                    rep.error("union-unacked", "%s/%s references %s, owned by %s: ack it in unionDirs (with the"
                              " mechanism) or runtimeSearchPaths" % (y, rel, anc, ", ".join(sorted(x))),
                              owners=sorted(x), **where)
            elif case == "dangling":
                ctx.add_edge(y, out, "%s: %s (dangling)" % (rel, tail))
                ok = rel_match(r, plan.danglingOk) or rel_match(r, plan.runtimeSearchPaths) \
                    or output_rel_match(y, rel, plan.prefixRelativeOk) or (doc and "documentation")
                if ok or y == ctx.debug_output:
                    rep.info("dangling", "%s/%s: %s exists in no output (acked)" % (y, rel, tail), **where)
                elif in_rpath:
                    pass                                   # phase E drops unused RUNPATH entries
                else:
                    rep.error("dangling", "%s/%s references %s, which exists in no output (view leak?): danglingOk,"
                              " runtimeSearchPaths or fix the build" % (y, rel, tail), **where)
            else:                                          # other / shared-self: owner x != out
                if in_rpath:
                    continue                               # phase E
                if kind == "text":
                    if x == y or ctx.requires(y, x) or cmake_export:
                        if not (x == y or ctx.requires(y, x)):
                            # kept as $out it could never exist and find_package()
                            # fails on every import; rewritten, the edge makes
                            # the file present (Rocky: install the subpackage)
                            rep.info("cmake-unrequired", "%s/%s: %s is in %s, which %s does not Require:"
                                     " CMake export file, rewritten to $%s (edge %s -> %s)"
                                     % (y, rel, tail, x, y, x, y, x), owner=x, **where)
                        edits.append((start, start + len(ctx.Pb), ctx.out[x].encode()))
                        ctx.add_edge(y, x, "%s: %s" % (rel, tail))
                        self.rewrites[(y, x)] += 1
                        if len(self.rewrite_samples) < plan.maxSamples * 5:
                            self.rewrite_samples.append([y, rel, tail, x])
                    else:
                        ctx.add_edge(y, out, "%s: %s (not required)" % (rel, tail))
                        (rep.info if doc else rep.warning)("not-required", "%s/%s: %s is in %s, which %s does not Require: kept as $%s%s"
                                    % (y, rel, tail, x, y, out, tail), owner=x, **where)
                else:
                    ctx.add_edge(y, out, "%s: %s (binary)" % (rel, tail))
                    if y == ctx.debug_output:
                        continue
                    self.pending.append((y, x, anc, r, rel, kind))
        if edits or dirty:
            for a, b, new in sorted(edits, reverse=True):
                data = data[:a] + new + data[b:]
            os.chmod(path, os.stat(path).st_mode | 0o200)
            with open(path, "wb") as f:
                f.write(data)
        # other store paths (case 7)
        for m in self.srx.finditer(data):
            h = m.group(1).decode()
            if h in self.own:
                continue
            if (y, rel) in self.elves and any(a <= m.start() < b for a, b in spans) \
                    and y != ctx.debug_output and not rel_match(rel, plan.noPatchelf):
                # a RUNPATH entry: phase E recomputes it (drops e.g. the cc's
                # -L dirs the ld-wrapper turned into -rpath); checked on the
                # final RUNPATH by check_rpath_foreign()
                self.rpath_foreign.setdefault((y, rel), set()).add(h)
                continue
            self.foreign[h].add("%s:%s" % (y, rel))
            if ctx.allowed is not None and h not in ctx.allowed:
                rep.error("foreign-store-path", "%s/%s references %s, not an allowed store path"
                          % (y, rel, m.group(0).decode()), output=y, file=rel)
        # FHS literals and shebangs
        if kind == "text":
            sb = S.shebang(data)
            if sb and sb.startswith(("/usr/", "/bin/", "/sbin/")) and sb not in RUNTIME_FHS:
                late = plan.lateBind.get(y, {}).get("interpreters", [])
                if ("#!" + sb) in plan.fhsAllowlist or sb in plan.fhsAllowlist or os.path.basename(sb) in late:
                    rep.info("fhs-shebang", "%s/%s: #!%s (allowlisted / late-bound)" % (y, rel, sb), output=y, file=rel)
                else:
                    rep.warning("fhs-shebang", "%s/%s: #!%s" % (y, rel, sb), output=y, file=rel)
        if kind in ("text", "elf"):
            lits = FHS_LITERAL.findall(data if kind == "text" else self._loaded(data, ef))
            if lits:
                fh = self.fhs[y]
                fh[0] += 1
                if len(fh[1]) < plan.maxSamples:
                    fh[1].append([rel, sorted({x.decode("utf-8", "replace") for x in lits})[:5]])
                if plan.strictFhs:
                    rep.error("fhs-literal", "%s/%s: %s" % (y, rel, lits[0].decode("utf-8", "replace")), output=y, file=rel)
        # phase G: pieced (loaded sections of ELF) and nested references
        if ef is not None and y != ctx.debug_output:
            hits = S.pieced(data, ctx.Pb, self.hash_start, full, ef.alloc_ranges())
            if hits:
                self.pieces.append([y, rel, hits])
                if y == out:
                    rep.info("pieced", "%s/%s: %d store-by-pieces windows of the prefix (%s)"
                             % (y, rel, sum(hits.values()), ", ".join(sorted(hits))), output=y, file=rel)
                else:
                    ctx.hidden[y].add(out)
                    ctx.add_edge(y, out, "%s: pieced" % rel)
                    ack = output_rel_match(y, rel, plan.opaqueRefs)
                    (rep.info if ack else rep.error)(
                        "pieced" if ack else "pieced-unacked",
                        "%s/%s: store-by-pieces reference to the prefix (%s); registered in hidden-references%s"
                        % (y, rel, ", ".join(sorted(hits)), "" if ack else "; ack with opaqueRefs (behaviour test)"),
                        output=y, file=rel)
        if kind.startswith("compressed:") or kind in ("elf", "ar"):
            for where, blob in nested_blobs(data):
                nf = S.prefix_refs(blob, self.rx)
                if nf:
                    owners = sorted({str(self.classify(y, norm_rel(t) if t.startswith("/") else None)[1]) for _s, _e, t in nf})
                    if y != out:
                        ctx.hidden[y].add(out)
                        ctx.add_edge(y, out, "%s: nested %s" % (rel, where))
                    self.nested.append([y, rel, where, len(nf), owners])
                    rep.info("nested-ref", "%s/%s: %d prefix references inside %s (owners %s)"
                             % (y, rel, len(nf), where, ", ".join(owners)), output=y, file=rel)
                for m in self.srx.finditer(blob):
                    h = m.group(1).decode()
                    if h in self.own:
                        continue
                    self.foreign[h].add("%s:%s>%s" % (y, rel, where))
                    if ctx.allowed is not None and h not in ctx.allowed:
                        rep.error("foreign-store-path", "%s/%s (inside %s) references %s, not an allowed store path"
                                  % (y, rel, where, m.group(0).decode()), output=y, file=rel)

    def _token_split(self, y, rel, tail, case, x, kind, doc, where):
        """an ld.so token path ($LIB) whose expansions are owned by different
        outputs: the reference points into one output E (the native
        expansion's owner if the text is rewritten, else the prefix output,
        where a stub may forward); an expansion not owned by E is not found
        at run time"""
        ctx, plan = self.ctx, self.ctx.plan
        out = ctx.prefix_output
        e_out = x if case != "out" and kind == "text" and (x == y or ctx.requires(y, x)) else out
        for e, r in self.split:
            owners = r[1] if isinstance(r[1], set) else {r[1]}
            if e_out in owners:
                continue
            msg = ("%s/%s: $%s%s points into %s, but its expansion %s is %s's: not found there at run time"
                   % (y, rel, e_out, tail, e_out, e, ", ".join(sorted(owners))))
            if rel_match(e, plan.danglingOk) or doc or y == ctx.debug_output or output_rel_match(y, rel, plan.prefixRelativeOk):
                ctx.report.info("dangling", msg + " (acked)", **where)
            else:
                ctx.report.error("dangling", msg + "; danglingOk [\"%s\"] if that expansion is not needed, or"
                                 " mergeOutputs" % e, **where)

    @staticmethod
    def _self_dir(anc):
        """library and header dirs: where a -devel output keeps its own build
        inputs (unversioned .so links, .pc, headers)"""
        return anc.split("/", 1)[0] in ("lib64", "lib", "include")

    def _self_rewrite(self, y, rel, tail, anc, start, edits, where):
        """text reference to a directory several outputs fill, the referrer
        among them: point it at the referrer's own part ($dev/lib64 in a
        -devel .pc file's libdir, where the unversioned .so link is)"""
        ctx = self.ctx
        edits.append((start, start + len(ctx.Pb), ctx.out[y].encode()))
        self.rewrites[(y, y)] += 1
        ctx.report.info("union-self", "%s/%s: $%s%s -> $%s%s (%s is filled by several outputs, %s among them)"
                        % (y, rel, ctx.prefix_output, tail, y, tail, anc, y), **where)

    PC_DEF = re.compile(rb"\s*([A-Za-z_][A-Za-z0-9_.]*)\s*=\s*(.*?)\s*$")
    PC_REF = re.compile(rb"\$\{([A-Za-z_][A-Za-z0-9_.]*)\}")

    def _pc_expand(self, data):
        """pkg-config file of a non-prefix output: write the prefix-derived
        variables out in full (meson/cmake style `libdir=${prefix}/lib64`
        -> `libdir=<P>/lib64`), so every path is a literal reference that
        the usual rules classify and rewrite ($dev/lib64 for a -devel
        file, R2). Definitions take every prefix-derived variable, other
        lines (Libs:, Cflags:) only aliases of the prefix itself; the
        prefix variables are then unused (R3)."""
        P = self.ctx.Pb
        lines = data.split(b"\n")
        defs = {}
        for ln in lines:
            m = self.PC_DEF.match(ln)
            if m:
                defs.setdefault(m.group(1), m.group(2))
        memo = {}

        def expand(name, seen=()):
            if name in memo:
                return memo[name]
            if name not in defs or name in seen:
                return None
            v, ok = defs[name], True

            def one(m):
                nonlocal ok
                e = expand(m.group(1), seen + (name,))
                if e is None:
                    ok = False
                    return m.group(0)
                return e
            v = self.PC_REF.sub(one, v)
            memo[name] = v if ok else None
            return memo[name]

        derived = {n for n in defs if (expand(n) or b"") == P or (expand(n) or b"").startswith(P + b"/")}
        if not derived:
            return data
        alias = {n for n in derived if expand(n) == P}
        out = []
        for ln in lines:
            m = self.PC_DEF.match(ln)
            use = derived if m else alias
            out.append(self.PC_REF.sub(lambda r: expand(r.group(1)) if r.group(1) in use else r.group(0), ln))
        return b"\n".join(out)

    def _cmake_set_re(self):
        return re.compile(rb'set\(_IMPORT_PREFIX "' + re.escape(self.ctx.Pb) + rb'/?"\)')

    def _cmake_expand(self, data):
        """CMake export file (<Pkg>Targets.cmake, written by install(EXPORT))
        of a non-prefix output: CMake writes `set(_IMPORT_PREFIX "<P>")` when
        the install dirs are absolute and then names every file as
        ${_IMPORT_PREFIX}/<rel>; the files themselves were split across
        outputs (headers in -devel, libraries in -libs).  Writing the uses out
        in full makes each one a literal reference the usual rules classify
        and rewrite ($dev/include for the -devel export file, as for .pc
        files, R2); the definition is then unused."""
        if not self._cmake_set_re().search(data):
            return data
        return data.replace(b"${_IMPORT_PREFIX}", self.ctx.Pb)

    def _unused_cmake_prefix(self, data, start):
        """the reference is the `set(_IMPORT_PREFIX "<P>")` definition and no
        ${_IMPORT_PREFIX} use is left"""
        a = data.rfind(b"\n", 0, start) + 1
        b = data.find(b"\n", start)
        line = data[a:b if b >= 0 else len(data)]
        return bool(self._cmake_set_re().search(line)) and b"${_IMPORT_PREFIX}" not in data

    def _unused_pc_var(self, data, start):
        """the reference is `name=<prefix>` in a pkg-config file and neither
        ${name} nor a variable derived from it (`exec_prefix=${prefix}`) is
        used by any other line"""
        a = data.rfind(b"\n", 0, start) + 1
        m = re.match(rb"\s*([A-Za-z_][A-Za-z0-9_.]*)\s*=", data[a:start])
        if not m:
            return False
        P = re.escape(self.ctx.Pb)
        defs = {}
        for line in data.splitlines():
            d = re.match(rb"\s*([A-Za-z_][A-Za-z0-9_.]*)\s*=\s*(.*?)\s*$", line)
            if d:
                defs[d.group(1)] = d.group(2)
        derived = {m.group(1)}
        while True:
            more = {k for k, v in defs.items() if k not in derived
                    and (re.fullmatch(P + rb"/?", v) or any(v == b"${" + x + b"}" for x in derived))}
            if not more:
                break
            derived |= more
        for line in data.splitlines():
            d = re.match(rb"\s*([A-Za-z_][A-Za-z0-9_.]*)\s*=", line)
            if d and d.group(1) in derived:
                continue
            if any(b"${" + x + b"}" in line for x in derived):
                return False
        return True

    @staticmethod
    def _loaded(data, ef):
        if ef is None:
            return b""
        return b"\0".join(data[o:o + s] for n, o, s in ef.alloc_ranges() if n in (".rodata", ".data", ".interp"))

    def _subref(self, file_subs, x, anc):
        if x is None or not anc:
            return
        for t in self.ctx.subs_of(x, anc):
            for s in file_subs:
                if s != t:
                    self.ctx.subref[(s, t)] += 1

    # -------------------------------------------------------------- phase F
    def stubs(self):
        ctx, rep, plan = self.ctx, self.ctx.report, self.ctx.plan
        out = ctx.prefix_output
        made = {}
        deny = plan.forward.get("deny", [])
        # shallow anchors first: a stub for share/foo serves share/foo/data.txt
        # too, whichever order the referrers name them in
        for y, x, anc, r, rel, kind in sorted(self.pending, key=lambda t: (t[2].count("/"), t[2], ctx.order[t[0]], t[4])):
            where = dict(output=y, file=rel, ref=ctx.P + "/" + r, owner=x)
            if rel_match(r, plan.runtimeSearchPaths) or rel_match(anc, plan.runtimeSearchPaths):
                rep.info("binary-ref", "%s/%s: $%s/%s dangles; %s's setup hook serves it (runtimeSearchPaths)"
                         % (y, rel, out, r, x), **where)
                continue
            if anc in made:
                continue
            up = next((a for a in made if anc.startswith(a + "/")), None)
            if up is not None and made[up] == x:
                rep.info("stub", "$%s/%s is served by the stub $%s/%s -> $%s/%s (for %s/%s)"
                         % (out, anc, out, up, x, up, y, rel), output=out, file=anc, owner=x)
                continue
            remedies = ("remedies: layout (compile that macro dir as %s's path), mergeOutputs [%s, %s],"
                        " or runtimeSearchPaths" % (x, out, x))
            if rel_match(anc, deny):
                rep.error("binary-ref", "%s/%s: compiled-in $%s/%s is %s's (forward.deny); %s" % (y, rel, out, r, x, remedies),
                          **where)
                continue
            if not (y == x or ctx.requires(y, x)):
                rep.error("binary-ref", "%s/%s: compiled-in $%s/%s belongs to %s, which %s does not Require; %s"
                          % (y, rel, out, r, x, y, remedies), **where)
                continue
            if y == x:
                rep.error("binary-ref", "%s/%s: compiled-in $%s/%s points back into %s itself: a stub %s->%s would close"
                          " a cycle; %s" % (y, rel, out, r, x, out, x, remedies), **where)
                continue
            if self._reaches(x, out):
                rep.error("binary-ref", "%s/%s: compiled-in $%s/%s belongs to %s; a stub %s->%s would close a cycle"
                          " (%s reaches %s); %s" % (y, rel, out, r, x, out, x, x, out, remedies), **where)
                continue
            dst = ctx.path_of(out, anc)
            if os.path.lexists(dst):
                rep.error("binary-ref", "%s/%s: stub location $%s/%s already exists; %s" % (y, rel, out, anc, remedies),
                          **where)
                continue
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            os.symlink(ctx.path_of(x, anc), dst)
            made[anc] = x
            ctx.add_edge(out, x, "stub %s" % anc)
            rep.info("stub", "$%s/%s -> $%s/%s (for %s/%s)" % (out, anc, x, anc, y, rel), output=out, file=anc, owner=x)
        ctx.stubs = made
        rep.section("stubs", {a: x for a, x in sorted(made.items())})

    def _reaches(self, src, dst):
        seen, todo = {src}, [src]
        while todo:
            v = todo.pop()
            if v == dst:
                return True
            for w in self.ctx.edges.get(v, {}):
                if w not in seen:
                    seen.add(w)
                    todo.append(w)
        return False
