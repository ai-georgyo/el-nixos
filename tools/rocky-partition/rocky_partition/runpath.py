"""Phase E: RUNPATH recompute from DT_NEEDED (design §2.6)."""
import os
import subprocess

from . import elf as E
from .plan import glob_match, rel_match


class Runpath:
    def __init__(self, ctx, elves):
        self.ctx = ctx
        self.elves = elves
        self._cls = {}

    def _class_at(self, path):
        if path not in self._cls:
            rp = os.path.realpath(path)
            self._cls[path] = E.elf_class(rp) if os.path.isfile(rp) else None
        return self._cls[path]

    def _has(self, d, soname, cls):
        p = os.path.join(d, soname)
        return os.path.lexists(p) and self._class_at(p) == cls

    def system_has(self, soname, cls):
        return any(self._has(d, soname, cls) for d in self.ctx.system_dirs)

    def run(self):
        ctx, rep, plan = self.ctx, self.ctx.report, self.ctx.plan
        P = ctx.P
        out_p = ctx.out[ctx.prefix_output]
        changes = []
        candidates = [o for o in ctx.managed if o != ctx.debug_output]
        late_libs = {o: v for o, v in plan.lateBind.items() if v.get("libs") or v.get("sonames")}
        for (y, rel), ef in sorted(self.elves.items(), key=lambda kv: (ctx.order[kv[0][0]], kv[0][1])):
            if y == ctx.debug_output or rel_match(rel, plan.noPatchelf):
                continue
            path = ctx.path_of(y, rel)
            old = ef.runpath if ef.runpath is not None else ef.rpath
            entries = [x for x in (old or "").split(":") if x]
            named = []
            for ent in entries:
                if ent == P or ent.startswith(P + "/"):
                    r = ent[len(P):].strip("/")
                    if r not in named:
                        named.append(r)
            std = ["lib64", "lib"] if ef.cls == 64 else ["lib", "lib64"]
            dirs_rel = std + [r for r in named if r not in std]
            new = [x for x in entries if x.startswith(("$ORIGIN", "${ORIGIN}"))]
            fdir = os.path.dirname(path)
            inputs = list(ctx.input_dirs) + [x for x in entries
                                             if x.startswith("/") and not (x == P or x.startswith(P + "/"))
                                             and not any(x.startswith(ctx.out[o]) for o in ctx.out)]
            for so in ef.needed:
                if self.system_has(so, ef.cls):
                    continue
                if any(self._has(x.replace("${ORIGIN}", fdir).replace("$ORIGIN", fdir), so, ef.cls)
                       for x in new):
                    continue
                found = None
                for d in dirs_rel:                                  # (a) own output
                    if self._has(ctx.path_of(y, d), so, ef.cls):
                        found = (y, d)
                        break
                if found is None:                                   # (b) siblings
                    hits = []
                    for o in candidates:
                        if o == y:
                            continue
                        for d in dirs_rel:
                            if self._has(ctx.path_of(o, d), so, ef.cls):
                                hits.append((o, d))
                                break
                    if len(hits) > 1:
                        req = [h for h in hits if ctx.requires(y, h[0])]
                        if len(req) == 1:
                            hits = req
                        else:
                            rep.warning("ambiguous-needed", "%s/%s: NEEDED %s is in %s; using %s"
                                        % (y, rel, so, ", ".join(h[0] for h in hits), hits[0][0]), output=y, file=rel)
                    if hits:
                        found = hits[0]
                if found is not None:
                    ent = ctx.path_of(*found)
                    if ent not in new:
                        new.append(ent)
                    ctx.add_edge(y, found[0], "%s: RUNPATH for %s" % (rel, so))
                    continue
                for d in inputs:                                    # (c) inputs
                    if self._has(d, so, ef.cls):
                        if d not in new:
                            new.append(d)
                        break
                else:
                    if glob_match(so, plan.allowUnresolvedNeeded):
                        rep.info("unresolved-needed", "%s/%s: NEEDED %s unresolved (allowUnresolvedNeeded)" % (y, rel, so),
                                 output=y, file=rel)
                    elif y in late_libs and (not late_libs[y].get("sonames") or glob_match(so, late_libs[y]["sonames"])):
                        rep.info("unresolved-needed", "%s/%s: NEEDED %s left to lateBind" % (y, rel, so), output=y, file=rel)
                    else:
                        rep.error("unresolved-needed", "%s/%s: NEEDED %s is in no output, input lib dir or system dir"
                                  % (y, rel, so), output=y, file=rel, soname=so)
            new_s = ":".join(new)
            old_cmp = (old or "").replace(P, out_p) if ctx.replay_old else (old or "")
            if new_s == old_cmp:
                continue                    # unchanged (an existing DT_RPATH is left as it is)
            self.patch(path, new_s, old)
            changes.append([y, rel, old, new_s])
            rep.info("runpath-changed", "%s/%s: %r -> %r" % (y, rel, old, new_s), output=y, file=rel)
        rep.section("runpath", {"changed": len(changes), "changes": changes[:plan.maxSamples * 10]})

    def patch(self, path, new, old):
        exe = self.ctx.plan.patchelf
        if not exe:
            self.ctx.report.error("runpath-changed", "%s: RUNPATH must change (%r -> %r) but plan.patchelf is not set"
                                  % (path, old, new), file=path)
            return
        os.chmod(path, os.stat(path).st_mode | 0o200)
        args = [exe, "--remove-rpath", path] if not new else [exe, "--set-rpath", new, path]
        p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if p.returncode != 0:
            raise RuntimeError("%s failed: %s" % (" ".join(args), p.stdout.decode("utf-8", "replace")))
