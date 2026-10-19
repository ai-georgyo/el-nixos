#!/usr/bin/env python3
"""Unit tests of late-bind.py on synthetic trees in a fake store (no Nix).

    python3 -I unit.py --tool late-bind.py --elf-lib DIR --workdir DIR

Needs `cc` (fixture ELFs), `patchelf`, `readelf`, and bash with the
functions patchShebangs/isScript exported (export -f, from stdenv's setup).
Every case runs the tool as the bind derivation does (bind, patchShebangs per
listed output, verify) and checks the exit status and the error codes."""
import argparse
import gzip
import json
import os
import shutil
import subprocess
import sys

H = "0123456789abcdfghijklmnpqrsvwxyz"


def h(c):
    return c * 32


class T:
    def __init__(self, args):
        self.args = args
        self.n = 0
        self.failed = []

    def case(self, name):
        self.n += 1
        root = os.path.join(self.args.workdir, "c%02d" % self.n)
        shutil.rmtree(root, ignore_errors=True)
        os.makedirs(os.path.join(root, "store"))
        return Case(self, name, root)


class Case:
    """outputs: raw <h('1'..)>-pkg-1.0[-o], bound <h('a'..)>-pkg-1.0[-o]"""

    def __init__(self, t, name, root):
        self.t, self.name, self.root = t, name, root
        self.store = os.path.join(root, "store")
        self.outs = {}
        self.graph = {}
        self.plan = {"late": [], "lstar": [], "referrers": {}, "skip": [], "binds": {}, "systemLibDirs": []}

    def out(self, o, rawc, boundc, name=None):
        suffix = "" if o == "out" else "-" + o
        raw = os.path.join(self.store, "%s-pkg-1.0%s" % (h(rawc), suffix))
        bound = os.path.join(self.store, "%s-%s%s" % (h(boundc), name or "pkg-1.0", suffix))
        os.makedirs(raw)
        self.outs[o] = (raw, bound)
        self.graph.setdefault(o, set())
        return raw

    def raw(self, o):
        return self.outs[o][0]

    def bound(self, o):
        return self.outs[o][1]

    def file(self, o, rel, data, mode=0o644):
        p = os.path.join(self.raw(o), rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(data.encode() if isinstance(data, str) else data)
        os.chmod(p, mode)
        return p

    def link(self, o, rel, target):
        p = os.path.join(self.raw(o), rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        os.symlink(target, p)

    def elf(self, o, rel, c_src, ldflags=()):
        p = os.path.join(self.raw(o), rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        src = os.path.join(self.root, os.path.basename(rel) + ".c")
        with open(src, "w") as f:
            f.write(c_src)
        subprocess.run(["cc", "-O0", "-o", p, src] + list(ldflags), check=True)
        return p

    def ref(self, y, x):
        self.graph[y].add(x)

    def run(self, expect_rc, expect_codes=(), stage="verify"):
        plan = dict(self.plan)
        plan["storeDir"] = self.store
        plan["raw"] = {o: r for o, (r, b) in self.outs.items() if o not in plan["skip"]}
        plan["bound"] = {o: self.bound(o) for o in plan["lstar"]}
        plan["rawGraph"] = [{"path": self.raw(o), "references": sorted(self.raw(x) for x in xs | {o})}
                            for o, xs in self.graph.items() if o not in plan["skip"]]
        pf = os.path.join(self.root, "plan.json")
        with open(pf, "w") as f:
            json.dump(plan, f)
        a = self.t.args
        st, sb = os.path.join(self.root, "state.json"), os.path.join(self.root, "shebangs")
        r = subprocess.run([sys.executable, "-I", a.tool, "bind", "--plan", pf, "--elf-lib", a.elf_lib,
                            "--patchelf", "patchelf", "--shebangs", sb, "--state", st],
                           capture_output=True, text=True)
        log = r.stderr
        rc = r.returncode
        if rc == 0 and stage == "verify":
            with open(sb) as f:
                for line in f:
                    o, hp, d = line.rstrip("\n").split("\t")
                    subprocess.run(["bash", "-c", 'HOST_PATH="$1" patchShebangs --host "$2" >&2', "_", hp, d],
                                   check=True)
            r = subprocess.run([sys.executable, "-I", a.tool, "verify", "--plan", pf, "--state", st],
                               capture_output=True, text=True)
            log += r.stderr
            rc = r.returncode
        self.log = log
        ok = rc == expect_rc and all("[%s]" % c in log for c in expect_codes)
        print("%s: %s (rc=%d)" % ("ok" if ok else "FAIL", self.name, rc))
        if not ok:
            print("  expected rc=%d codes=%s; log:\n    %s" % (expect_rc, list(expect_codes),
                                                             log.replace("\n", "\n    ")))
            self.t.failed.append(self.name)
        return ok

    def check(self, cond, what):
        if not cond:
            print("FAIL: %s: %s" % (self.name, what))
            self.t.failed.append("%s: %s" % (self.name, what))
        else:
            print("ok: %s: %s" % (self.name, what))


def late_common(c, referrers=("lp",)):
    """common (late, text self-ref + C.utf8) <- lp (symlink) ; out (not late)"""
    c.out("out", "0", "0")
    rc = c.out("common", "1", "a")
    c.file("common", "lib/locale/C.utf8/LC_CTYPE", "ctype\n")
    c.file("common", "share/where", "%s/lib/locale and %s/share\n" % (rc, c.raw("out")))
    c.out("lp", "2", "b")
    c.link("lp", "lib/locale/xx/LC_CTYPE", rc + "/lib/locale/C.utf8/LC_CTYPE")
    c.ref("common", "out")
    c.ref("lp", "common")
    c.plan.update(late=["common"], lstar=["common"] + list(referrers), referrers={"common": list(referrers)})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tool", required=True)
    ap.add_argument("--elf-lib", required=True)
    ap.add_argument("--workdir", required=True)
    t = T(ap.parse_args())

    # 1. positive: text, symlink rewritten; non-L* reference kept
    c = t.case("text and symlinks rebound")
    late_common(c)
    if c.run(0):
        with open(os.path.join(c.bound("common"), "share/where")) as f:
            w = f.read()
        c.check(c.bound("common") in w and c.raw("out") in w and c.raw("common") not in w,
                "text: own raw hash -> bound, out kept")
        c.check(os.readlink(os.path.join(c.bound("lp"), "lib/locale/xx/LC_CTYPE")).startswith(c.bound("common")),
                "symlink target -> bound common")
        c.check(os.path.exists(os.path.join(c.bound("lp"), "lib/locale/xx/LC_CTYPE")), "symlink resolves")
        with open(os.path.join(c.bound("common"), "nix-support/rocky-late-bind.json")) as f:
            rep = f.read()
        c.check(c.store not in rep and '"share/where"' in rep, "report: names rewritten files, no store paths")

    # 2. incomplete referrer list (direct)
    c = t.case("incomplete referrers: direct")
    late_common(c, referrers=())
    c.run(1, ["late-referrer-missing"], stage="bind")
    c.check("lp reaches late output common (lp -> common)" in c.log, "error names the referrer and the chain")

    # 3. incomplete referrer list (transitive: lp2 -> lp -> common)
    c = t.case("incomplete referrers: transitive")
    late_common(c)
    c.out("lp2", "3", "c")
    c.link("lp2", "lib/locale/yy/LC_CTYPE", c.raw("lp") + "/lib/locale/xx/LC_CTYPE")
    c.ref("lp2", "lp")
    c.run(1, ["late-referrer-missing"], stage="bind")
    c.check("lp2 -> lp -> common" in c.log, "transitive chain reported")

    # 4. unused declared referrer: info only
    c = t.case("unused referrer is info")
    late_common(c, referrers=("lp", "lp3"))
    c.out("lp3", "4", "d")
    c.file("lp3", "share/own", "x\n")
    c.run(0)
    c.check("late-referrer-unused: referrers.common: lp3" in c.log, "reported")

    # 5. ELF content referencing the raw late output: refused
    c = t.case("ELF content ref into late output refused")
    late_common(c)
    c.elf("common", "bin/prog", 'const char *p = "%s/share/where";\nint main(void){return p[0]==0;}\n'
          % c.raw("common"))
    c.run(1, ["late-elf-ref"], stage="bind")
    c.check("common/bin/prog: ELF content references raw late output common" in c.log, "names file and output")

    # 6. ELF content in a referrer referencing another L* output (a referrer): refused
    c = t.case("ELF content ref into referrer refused")
    late_common(c, referrers=("lp", "lp2"))
    c.out("lp2", "3", "c")
    c.link("lp2", "x", c.raw("common") + "/share/where")
    c.ref("lp2", "common")
    c.elf("lp2", "bin/prog", 'const char *p = "%s/lib/locale";\nint main(void){return p[0]==0;}\n' % c.raw("lp"))
    c.ref("lp2", "lp")
    c.run(1, ["late-elf-ref"], stage="bind")
    c.check("references raw referrer lp" in c.log, "kind = referrer")

    # 7. ELF referencing the late output only through RUNPATH: rebound by patchelf
    c = t.case("RUNPATH into late output rebound")
    late_common(c)
    os.makedirs(os.path.join(c.raw("common"), "lib64"))
    c.elf("common", "bin/prog", "int main(void){return 0;}\n", ["-Wl,-rpath," + c.raw("common") + "/lib64"])
    if c.run(0):
        rp = subprocess.run(["patchelf", "--print-rpath", os.path.join(c.bound("common"), "bin/prog")],
                            capture_output=True, text=True).stdout.strip()
        c.check(c.bound("common") + "/lib64" in rp, "RUNPATH names bound common: " + rp)
        with open(os.path.join(c.bound("common"), "bin/prog"), "rb") as f:
            c.check(h("1").encode() not in f.read(), "no raw hash left in the ELF")

    # 8. compressed member referencing the late output: refused
    c = t.case("compressed member ref refused")
    late_common(c)
    c.file("common", "share/man/x.1.gz", gzip.compress(("see %s/share/where\n" % c.raw("common")).encode(), mtime=0))
    c.run(1, ["late-compressed-ref"], stage="bind")

    # 9. hidden-references naming a raw L* output: refused
    c = t.case("hidden reference refused")
    late_common(c)
    c.file("common", "nix-support/hidden-references", c.raw("common") + "\n")
    c.run(1, ["late-hidden-ref"], stage="bind")

    # 10. unresolved NEEDED bound to a lib; strict system dirs
    def needs_foo(c, libs, sysdirs):
        c.out("out", "0", "0")
        c.out("utils", "1", "a")
        libdir = os.path.join(c.root, "libfoo", "lib64")
        os.makedirs(libdir)
        src = os.path.join(c.root, "foo.c")
        with open(src, "w") as f:
            f.write('int foo(void){return 42;}\n')
        subprocess.run(["cc", "-shared", "-fPIC", "-Wl,-soname,libfoo.so.1", "-o", libdir + "/libfoo.so.1", src],
                       check=True)
        os.symlink("libfoo.so.1", libdir + "/libfoo.so")
        c.elf("utils", "bin/use-foo", "int foo(void);\nint main(void){return foo()!=42;}\n",
              ["-L" + libdir, "-lfoo"])
        subprocess.run(["patchelf", "--remove-rpath", os.path.join(c.raw("utils"), "bin/use-foo")], check=True)
        c.ref("utils", "out")
        c.plan.update(late=["utils"], lstar=["utils"], systemLibDirs=sysdirs,
                      binds={"utils": {"hostPath": "", "libs": [{"name": n, "dirs": d(libdir)} for n, d in libs]}})
        return libdir

    c = t.case("unresolved NEEDED bound to the lib")
    libdir = needs_foo(c, [("libfoo", lambda d: [d, os.path.dirname(d) + "/lib"])], [])
    if c.run(0):
        exe = os.path.join(c.bound("utils"), "bin/use-foo")
        rp = subprocess.run(["patchelf", "--print-rpath", exe], capture_output=True, text=True).stdout.strip()
        c.check(rp == libdir, "RUNPATH = the lib dir: " + rp)
        c.check(subprocess.run([exe]).returncode == 0, "bound ELF runs")
        c.check(subprocess.run([os.path.join(c.raw("utils"), "bin/use-foo")],
                               capture_output=True).returncode != 0, "raw ELF does not (control)")

    c = t.case("bind lib that resolves nothing")
    needs_foo(c, [("libfoo", lambda d: [d]), ("libbar", lambda d: [os.path.dirname(d)])], [])
    c.run(1, ["late-lib-unused"], stage="bind")
    c.check("binds.utils.libs: libbar" in c.log, "names the lib")

    c = t.case("strict system dirs: NEEDED found nowhere")
    needs_foo(c, [("libbar", lambda d: [os.path.dirname(d)])], [os.path.join(c.root, "nolibc")])
    c.run(1, ["late-needed-unresolved"], stage="bind")

    # 11. shebangs: bound interpreter, runtime FHS kept, unbound interpreter refused
    def shebangs(c, extra):
        late_common(c)
        b = os.path.join(c.store, h("9") + "-dummy-bash", "bin")
        os.makedirs(b)
        os.symlink(shutil.which("bash"), b + "/bash")
        c.file("common", "bin/ldd", "#!/usr/bin/bash\necho ldd\n", 0o755)
        c.file("common", "bin/envsh", "#!/usr/bin/env bash\necho env\n", 0o755)
        c.file("common", "bin/plain", "#!/bin/sh\necho sh\n", 0o755)
        c.file("common", "share/notexec", "#!/usr/bin/bash\n", 0o644)
        for rel, line in extra:
            c.file("common", rel, line + "\necho x\n", 0o755)
        c.plan["binds"] = {"common": {"hostPath": b, "libs": []}}
        return b

    c = t.case("shebangs bound")
    b = shebangs(c, [])
    if c.run(0):
        def first(rel):
            with open(os.path.join(c.bound("common"), rel)) as f:
                return f.readline().strip()
        c.check(first("bin/ldd") == "#!" + b + "/bash", "#!/usr/bin/bash -> bound bash")
        c.check(first("bin/envsh") == "#!" + b + "/bash", "#!/usr/bin/env bash -> bound bash")
        c.check(first("bin/plain") == "#!/bin/sh", "#!/bin/sh kept (runtime FHS)")
        c.check(first("share/notexec") == "#!/usr/bin/bash", "non-executable file untouched")

    c = t.case("unbound shebang refused")
    shebangs(c, [("bin/mtrace", "#!/usr/bin/perl")])
    c.run(1, ["late-shebang-unbound"])
    c.check("common/bin/mtrace: #!/usr/bin/perl" in c.log, "names the script")

    # 12. store names differ -> refused before anything is written
    c = t.case("bound name differs")
    c.out("common", "1", "a", name="pkg-1.1")
    c.plan.update(late=["common"], lstar=["common"])
    c.run(1, ["late-name"], stage="bind")

    # 13. raw output missing from the reference graph
    c = t.case("graph incomplete")
    late_common(c)
    c.out("extra", "5", "e")
    c.plan["skip"] = []
    del c.graph["extra"]
    c.run(1, ["late-graph"], stage="bind")

    # 14. skip: debug references late outputs but is neither bound nor an error
    c = t.case("skip: debug may reference late outputs")
    late_common(c)
    c.out("debug", "6", "f")
    c.file("debug", "lib/debug/x.debug", c.raw("common") + "\n")
    c.ref("debug", "common")
    c.plan["skip"] = ["debug"]
    c.run(0)

    # 15. a late output bound without interpreters keeps an FHS shebang: refused;
    #     a referrer's FHS shebang is not the bind's business
    c = t.case("late output without interpreters, FHS shebang")
    late_common(c)
    c.file("common", "bin/ldd", "#!/usr/bin/bash\necho ldd\n", 0o755)
    c.run(1, ["late-shebang-unbound"])
    c = t.case("referrer with FHS shebang is left alone")
    late_common(c)
    c.file("lp", "bin/tool", "#!/usr/bin/bash\necho tool\n", 0o755)
    c.run(0)

    print("%d cases, %d failures" % (t.n, len(t.failed)))
    for f in t.failed:
        print("FAILED: " + f)
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
