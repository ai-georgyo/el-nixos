#!/usr/bin/env python3
"""rocky-partition self-tests on synthetic trees (checks.nn-partition-selftest).

  selftest.py TOOLDIR WORKDIR [case...]

Every case builds a relocated BUILDROOT by hand (ELF fixtures compiled with
`cc`, text, symlinks, gzip'ed pages), packs real RPM headers with `rpmbuild`
(the partitioner reads them with `rpm -qp --qf`), runs the partitioner
against fake store outputs (a store dir below WORKDIR) and checks the result
and the report. Needs rpm/rpmbuild, cc, patchelf on PATH. Exit 1 if any case
fails."""
import gzip
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import traceback

TOOL = os.path.abspath(sys.argv[1])
WORK = os.path.abspath(sys.argv[2])
ONLY = sys.argv[3:]
sys.path.insert(0, TOOL)
from rocky_partition import elf as E  # noqa: E402

STORE = os.path.join(WORK, "store")
NIX32 = "0123456789abcdfghijklmnpqrsvwxyz"
SYSLIB = os.path.dirname(subprocess.run(["cc", "-print-file-name=libc.so.6"], capture_output=True,
                                        text=True, check=True).stdout.strip())


def fhash(seed):
    return "".join(NIX32[b % 32] for b in hashlib.sha256(seed.encode()).digest()[:32])


class Case:
    def __init__(self, name, pkg="foo"):
        self.name, self.pkg = name, pkg
        self.dir = os.path.join(WORK, name)
        shutil.rmtree(self.dir, ignore_errors=True)
        os.makedirs(self.dir)
        self.P = os.path.join(STORE, "%s-%s-1-1" % (fhash(name + "/out"), pkg))
        self.br = os.path.join(self.dir, "BR")
        os.makedirs(self.br + self.P)
        os.symlink(self.P.lstrip("/"), os.path.join(self.br, "usr"))
        self.subs = {}            # subpackage -> {"files": [], "requires": [], "post": None}
        self.outputs = {}

    # ---------------------------------------------------------------- fixture
    def sub(self, name, requires=(), post=None):
        self.subs.setdefault(name, {"files": [], "requires": list(requires), "post": post})
        return self

    def path(self, rel):
        return self.br + self.P + "/" + rel

    def own(self, sub, line):
        self.subs[sub]["files"].append(line)

    def text(self, sub, rel, content, mode=0o644, attr=None):
        p = self.path(rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(content.replace("@P@", self.P))
        os.chmod(p, mode)
        self.own(sub, ("%%attr(%s) " % attr if attr else "") + self.P + "/" + rel)

    def gz(self, sub, rel, content):
        p = self.path(rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(gzip.compress(content.replace("@P@", self.P).encode(), mtime=0))
        self.own(sub, self.P + "/" + rel)

    def link(self, sub, rel, target):
        p = self.path(rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        os.symlink(target.replace("@P@", self.P), p)
        self.own(sub, self.P + "/" + rel)

    def etc(self, sub, rel, content, flags="%config(noreplace) "):
        p = os.path.join(self.br, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(content)
        self.own(sub, flags + "/" + rel)

    def cc(self, sub, rel, src, args=(), shared=False, own=True, rpath=None):
        """compile a fixture; its RUNPATH is exactly `rpath` (the toolchain's
        own entries removed)"""
        p = self.path(rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        c = os.path.join(self.dir, os.path.basename(rel) + ".c")
        with open(c, "w") as f:
            f.write(src.replace("@P@", self.P))
        cmd = ["cc", "-O1", "-o", p, c] + (["-shared", "-fPIC"] if shared else []) + \
            [a.replace("@P@", self.P).replace("@BRP@", self.br + self.P) for a in args]
        subprocess.run(cmd, check=True)
        subprocess.run(["patchelf", "--remove-rpath", p], check=True)
        if rpath:
            subprocess.run(["patchelf", "--set-rpath", rpath.replace("@P@", self.P), p], check=True)
        if own:
            self.own(sub, self.P + "/" + rel)

    def pieces_src(self, var="pieces"):
        """C source of an array that holds the prefix in 8-byte chunks (each
        NUL-terminated): store-by-pieces windows, never a full occurrence"""
        chunks = [self.P[i:i + 8] for i in range(0, len(self.P), 8)]
        body = ", ".join('"%s"' % c for c in chunks)
        return "const char %s[][9] = { %s };\nconst char *get_%s(int i) { return %s[i]; }\n" % (var, body, var, var)

    # ---------------------------------------------------------------- build + run
    def rpms(self):
        main = self.subs.get(self.pkg, {"requires": []})
        spec = ["Name: %s" % self.pkg, "Version: 1", "Release: 1", "Summary: s", "License: MIT",
                "AutoReqProv: no"] + ["Requires: %s" % r for r in main["requires"]] + ["%description", "d"]
        for s, d in self.subs.items():
            if s != self.pkg:
                spec += ["%%package -n %s" % s, "Summary: s", "AutoReqProv: no"]
                spec += ["Requires: %s" % r for r in d["requires"]]
                spec += ["%%description -n %s" % s, "d"]
        spec += ["%install", "mkdir -p %{buildroot}", "cp -a %s/. %%{buildroot}/" % self.br, "rm -f %{buildroot}/usr"]
        for s, d in self.subs.items():
            if d["post"]:
                spec += ["%%post%s" % ("" if s == self.pkg else " -n " + s), d["post"]]
        for s, d in self.subs.items():
            spec += ["%%files%s" % ("" if s == self.pkg else " -n " + s)] + d["files"]
        sp = os.path.join(self.dir, "x.spec")
        with open(sp, "w") as f:
            f.write("\n".join(spec) + "\n")
        top = os.path.join(self.dir, "top")
        for d in ("tmp",):
            os.makedirs(os.path.join(top, d), exist_ok=True)
        subprocess.run(["rpmbuild", "-bb", "--quiet", "--define", "_topdir " + top,
                        "--define", "_tmppath " + top + "/tmp", "--define", "__os_install_post %{nil}",
                        "--define", "debug_package %{nil}", "--define", "_build_id_links none",
                        "--define", "_binary_payload w0.ufdio", "--define", "_unpackaged_files_terminate_build 0",
                        "--nodeps", sp], check=True, env=dict(os.environ, HOME=self.dir),
                       stdout=subprocess.DEVNULL)
        return os.path.join(top, "RPMS")

    def out(self, o):
        if o not in self.outputs:
            self.outputs[o] = self.P if o == "out" else "%s/%s-%s-1-1-%s" % (STORE, fhash(self.name + "/" + o), self.pkg, o)
        return self.outputs[o]

    def run(self, submap, extra=None, expect_rc=None, replay=None, copy_br=True, unclaimed=None):
        for o in set(submap.values()) | {"out", "debug"}:
            p = self.out(o)
            if os.path.exists(p):
                subprocess.run(["chmod", "-R", "u+w", p])
                shutil.rmtree(p)
        rpms = self.rpms()
        br = os.path.join(self.dir, "BR-run")
        shutil.rmtree(br, ignore_errors=True)
        subprocess.run(["cp", "-a", self.br, br], check=True)     # keeps hard links
        if unclaimed:
            with open(os.path.join(br + self.P, unclaimed), "w") as f:
                f.write("x\n")
        plan = {"srpm": self.pkg, "rpm": "rpm", "outputs": {o: self.out(o) for o in set(submap.values()) | {"out", "debug"}},
                "subpackages": submap, "patchelf": "patchelf", "storeDir": STORE, "buildroot": br,
                "rpmsDir": rpms, "systemLibDirs": [SYSLIB]}
        args = []
        if replay:
            # the tree keeps P; new outputs get other hashes of the same length
            tree = os.path.join(self.dir, "tree")
            shutil.rmtree(tree, ignore_errors=True)
            os.makedirs(tree)
            subprocess.run(["cp", "-a", br, os.path.join(tree, "BUILDROOT")], check=True)
            shutil.copytree(rpms, os.path.join(tree, "RPMS"))
            with open(os.path.join(tree, "prefix"), "w") as f:
                f.write(self.P + "\n")
            self.outputs = {o: p.replace(fhash(self.name + "/" + o), fhash("replay/" + self.name + "/" + o))
                            for o, p in plan["outputs"].items()}
            self.outputs["out"] = self.P.replace(fhash(self.name + "/out"), fhash("replay/" + self.name + "/out"))
            plan["outputs"] = dict(self.outputs)
            del plan["buildroot"], plan["rpmsDir"]
            args = ["--replay", tree, "--remap", "%s=%s" % (self.P, self.outputs["out"])]
        plan.update(extra or {})
        for o in plan["outputs"].values():
            if os.path.exists(o):
                subprocess.run(["chmod", "-R", "u+w", o])
                shutil.rmtree(o)
        pf = os.path.join(self.dir, "plan.json")
        with open(pf, "w") as f:
            json.dump(plan, f, indent=1)
        p = subprocess.run([sys.executable, "-I", os.path.join(TOOL, "rocky-partition"), "--plan", pf] + args,
                           capture_output=True, text=True)
        self.rc, self.stderr = p.returncode, p.stderr
        rf = os.path.join(self.outputs["out"], "nix-support", "rocky-report.json")
        self.report = json.load(open(rf)) if os.path.exists(rf) else None
        if expect_rc is not None and p.returncode != expect_rc:
            raise AssertionError("exit %d, expected %d\n%s" % (p.returncode, expect_rc, p.stderr[-3000:]))
        return self

    # ---------------------------------------------------------------- checks
    def codes(self, severity="error"):
        return sorted(i["code"] for i in self.report["findings"] if i["severity"] == severity)

    def has(self, code, severity="error", contains=""):
        ok = any(i["code"] == code and i["severity"] == severity and contains in i["message"]
                 for i in self.report["findings"])
        if not ok:
            raise AssertionError("no %s %s %r; findings: %s" % (severity, code, contains,
                                 [(i["severity"], i["code"], i["message"][:150]) for i in self.report["findings"]
                                  if i["severity"] != "info"][:20]))

    def no_errors(self):
        errs = [i["message"] for i in self.report["findings"] if i["severity"] == "error"]
        if errs or self.rc != 0:
            raise AssertionError("rc %d, errors: %s\n%s" % (self.rc, errs[:20], self.stderr[-2000:]))

    def p(self, o, rel=""):
        return self.outputs[o] + ("/" + rel if rel else "")

    def read(self, o, rel):
        with open(self.p(o, rel)) as f:
            return f.read()

    def runpath(self, o, rel):
        with open(self.p(o, rel), "rb") as f:
            e = E.parse(f.read())
        return e.runpath if e.runpath is not None else e.rpath


def eq(a, b, what=""):
    if a != b:
        raise AssertionError("%s: %r != %r" % (what, a, b))


def true(c, what):
    if not c:
        raise AssertionError(what)


LIB_SRC = 'int foo_answer(void) { return 42; }\n'
BIN_SRC = ('#include <stdio.h>\nint foo_answer(void);\n'
           'int main(void) { printf("%d %s\\n", foo_answer(), "@P@/share/foo"); return 0; }\n')


def split_fixture(c):
    """foo / foo-libs / foo-devel / foo-common / foo-doc"""
    c.sub("foo", ["foo-libs", "foo-common"], post='echo "post of foo" \'quoted\'\nexit 0').sub("foo-libs")
    c.sub("foo-devel", ["foo-libs"]).sub("foo-common").sub("foo-doc")
    c.cc("foo-libs", "lib64/libfoo.so.1.0", LIB_SRC, ["-Wl,-soname,libfoo.so.1"], shared=True)
    c.link("foo-libs", "lib64/libfoo.so.1", "libfoo.so.1.0")
    c.link("foo-devel", "lib64/libfoo.so", "libfoo.so.1")
    c.cc("foo", "bin/foo", BIN_SRC, ["-L@BRP@/lib64", "-l:libfoo.so.1.0"], rpath="@P@/lib64")
    # setuid only in the header (%attr): the build sandbox forbids setuid bits on disk
    c.text("foo", "bin/foo-helper", "#!/bin/sh\nexec @P@/bin/foo\n", mode=0o755, attr="4755,root,root")
    os.link(c.path("bin/foo-helper"), c.path("bin/foo-helper2"))
    c.own("foo", c.P + "/bin/foo-helper2")
    c.link("foo", "lib/.build-id/12/3456789abcdef", "../../../bin/foo")
    c.text("foo-common", "share/foo/data.txt", "data\n")
    c.text("foo-devel", "include/foo.h", "int foo_answer(void);\n")
    c.text("foo-devel", "lib64/pkgconfig/foo.pc",
           "prefix=@P@\nexec_prefix=${prefix}\nlibdir=@P@/lib64\nincludedir=@P@/include\n\n"
           "Name: foo\nVersion: 1\nLibs: -L${libdir} -lfoo\nCflags: -I${includedir}\n")
    c.text("foo-doc", "share/doc/foo/README", "see @P@/share/foo/data.txt\n")
    c.gz("foo-doc", "share/man/man1/foo.1.gz", ".TH FOO 1\n.SH FILES\n@P@/share/foo/data.txt\n")
    c.etc("foo", "etc/foo.conf", "x=1\n")


SPLIT_MAP = {"foo": "out", "foo-libs": "lib", "foo-devel": "dev", "foo-common": "common", "foo-doc": "doc"}


def t_split():
    c = Case("split")
    split_fixture(c)
    c.run(SPLIT_MAP, {"layout": {}})
    c.no_errors()
    # Phase E: RUNPATH $out/lib64 -> $lib/lib64 (libc: system dir, no entry)
    eq(c.runpath("out", "bin/foo"), c.p("lib", "lib64"), "RUNPATH of bin/foo")
    # Phase F: compiled-in $out/share/foo (foo-common, Required) -> stub
    eq(os.readlink(c.p("out", "share/foo")), c.p("common", "share/foo"), "stub")
    true("share/foo" in open(c.p("out", "nix-support/rocky-stubs")).read(), "rocky-stubs lists the stub")
    # Phase C: symlinks
    eq(os.readlink(c.p("lib", "lib64/libfoo.so.1")), "libfoo.so.1.0", "same-output link stays relative")
    eq(os.readlink(c.p("dev", "lib64/libfoo.so")), c.p("lib", "lib64/libfoo.so.1"), "cross-output link absolute")
    # Phase D: text rewriting (.pc: includedir -> $dev, libdir union -> $dev, unused prefix kept)
    pc = c.read("dev", "lib64/pkgconfig/foo.pc")
    true("includedir=%s/include" % c.p("dev") in pc, "includedir rewritten: " + pc)
    true("libdir=%s/lib64" % c.p("dev") in pc, "libdir -> own part of lib64: " + pc)
    true("prefix=%s\n" % c.P in pc, "unused prefix variable kept")
    # Requires-gated text: doc does not Require common -> kept as $out/... (warning)
    true(c.P + "/share/foo/data.txt" in c.read("doc", "share/doc/foo/README"), "not-required text kept")
    c.has("not-required", "warning", "doc/share/doc/foo/README")
    # Phase G: gzip'ed man page -> hidden-references
    true(c.P in c.read("doc", "nix-support/hidden-references"), "nested ref registered")
    c.has("nested-ref", "info", "share/man/man1/foo.1.gz")
    # Phase A/B: /etc, build-id links dropped, hard links, setuid -> metadata
    true(os.path.isfile(c.p("out", "etc/foo.conf")), "etc file in out/etc")
    true(not os.path.exists(c.p("out", "lib/.build-id")), "build-id links dropped")
    eq(os.stat(c.p("out", "bin/foo-helper")).st_ino, os.stat(c.p("out", "bin/foo-helper2")).st_ino, "hard link kept")
    true(not os.stat(c.p("out", "bin/foo-helper")).st_mode & stat.S_ISUID, "setuid not in the store")
    meta = json.load(open(c.p("out", "nix-support/rpm/foo.json")))
    conf = [f for f in meta["files"] if f["path"] == "/etc/foo.conf"][0]
    eq((conf["flags"], conf["config"]), ("cn", True), "config flags")
    helper = [f for f in meta["files"] if f["rel"] == "bin/foo-helper"][0]
    true(helper["setid"] and helper["mode"].endswith("4755"), "setid recorded: %r" % helper)
    eq(meta["scriptlets"]["postin"]["body"], 'echo "post of foo" \'quoted\'\nexit 0', "scriptlet body")
    true(c.P not in json.dumps(meta), "metadata names the prefix as /usr, never a store path")
    eq(open(c.p("lib", "nix-support/rpm-name")).read(), "foo-libs\n", "rpm-name")
    # Phase H: graph
    edges = c.report["graph"]["edges"]
    true("lib" in edges.get("out", {}) and "common" in edges.get("out", {}), "out -> lib, common: %r" % edges)
    eq(c.report["graph"]["sccs"], [], "no cycles")
    eq(c.report["outputRequires"].get("out"), ["common", "lib"], "unique-provider Requires")
    # report must not name other outputs' store paths (Nix would see edges)
    rep = open(c.p("out", "nix-support/rocky-report.json")).read()
    for o in ("lib", "dev", "common", "doc"):
        true(c.p(o) not in rep, "report names $%s" % o)


def t_libs_self_cycle():
    """-libs referencing its own plugin dir by the prefix path: a stub would
    close a cycle -> error; mergeOutputs fixes it"""
    c = Case("selfcycle")
    c.sub("foo", ["foo-libs"]).sub("foo-libs")
    c.cc("foo-libs", "lib64/libfoo.so.1", 'const char *d(void) { return "@P@/lib64/foo/plugins"; }\n',
         ["-Wl,-soname,libfoo.so.1"], shared=True)
    c.text("foo-libs", "lib64/foo/plugins/a.conf", "a\n")
    c.text("foo", "share/doc/foo/README", "x\n")
    c.run({"foo": "out", "foo-libs": "lib"}, expect_rc=1)
    c.has("binary-ref", "error", "points back into lib itself")
    c.run({"foo": "out", "foo-libs": "out"}, {"mergeOutputs": [["foo", "foo-libs"]]}, expect_rc=0)
    c.no_errors()


def t_search_path():
    """compiled-in path into an output nobody Requires: error; a
    runtimeSearchPaths entry instead makes it dangle + setup hook"""
    c = Case("searchpath")
    c.sub("foo").sub("foo-plugins")
    c.cc("foo", "bin/foo", '#include <stdio.h>\nint main(void) { puts("@P@/share/foo-plugins"); return 0; }\n')
    c.text("foo-plugins", "share/foo-plugins/p1", "p\n")
    c.run({"foo": "out", "foo-plugins": "plugins"}, expect_rc=1)
    c.has("binary-ref", "error", "which out does not Require")
    c.run({"foo": "out", "foo-plugins": "plugins"}, {"runtimeSearchPaths": {"share/foo-plugins": "FOO_PLUGINS"}},
          expect_rc=0)
    c.no_errors()
    true('addToSearchPath FOO_PLUGINS "%s/share/foo-plugins"' % c.p("plugins") in c.read("plugins", "nix-support/setup-hook"),
         "setup hook")
    true(not os.path.lexists(c.p("out", "share/foo-plugins")), "no stub")


def t_text_cycle():
    """text references both ways between two Required siblings: Nix cycle
    -> error with the merge suggestion"""
    c = Case("textcycle")
    c.sub("foo", ["foo-a"]).sub("foo-a", ["foo-b"]).sub("foo-b", ["foo-a"])
    c.text("foo", "bin/foo", "#!/bin/sh\n")
    c.text("foo-a", "share/a/conf", "other=@P@/share/b/conf\n")
    c.text("foo-b", "share/b/conf", "other=@P@/share/a/conf\n")
    c.run({"foo": "out", "foo-a": "a", "foo-b": "b"}, expect_rc=1)
    c.has("cycle", "error", 'mergeOutputs = [ [ "foo-a" "foo-b" ] ]')
    c.run({"foo": "out", "foo-a": "a", "foo-b": "a"}, {"mergeOutputs": [["foo-a", "foo-b"]]}, expect_rc=0)
    c.no_errors()


def t_dangling_foreign_union():
    c = Case("dangling")
    c.sub("foo").sub("foo-libs").sub("foo-lang")
    c.text("foo", "bin/tz", "TZDIR=@P@/share/zoneinfo\nX=/nix/store/%s-evil/bin/x\n" % fhash("evil"))
    c.text("foo", "share/locale/de/LC_MESSAGES/foo.mo", "x\n")
    c.text("foo-lang", "share/locale/fr/LC_MESSAGES/foo.mo", "x\n")
    c.cc("foo-libs", "lib64/libfoo.so.1", 'const char *d(void) { return "@P@/share/locale"; }\n',
         ["-Wl,-soname,libfoo.so.1", "-nostdlib"], shared=True)
    m = {"foo": "out", "foo-libs": "lib", "foo-lang": "lang"}
    c.run(m, {"allowedStorePaths": []}, expect_rc=1)
    c.has("dangling", "error", "share/zoneinfo")
    c.has("foreign-store-path", "error", "out/bin/tz")
    c.has("union-unacked", "error", "lib/lib64/libfoo.so.1 references share/locale")
    c.run(m, {"allowedStorePaths": ["/nix/store/%s-evil" % fhash("evil")], "danglingOk": ["share/zoneinfo"],
              "unionDirs": {"share/locale": "TEXTDOMAINDIR"}}, expect_rc=0)
    c.no_errors()


def t_pieced():
    c = Case("pieced")
    c.sub("foo", ["foo-libs"]).sub("foo-libs")
    c.cc("foo-libs", "lib64/libfoo.so.1", c.pieces_src(), ["-Wl,-soname,libfoo.so.1"], shared=True)
    c.text("foo", "share/doc/foo/README", "x\n")
    with open(c.path("lib64/libfoo.so.1"), "rb") as f:
        true(c.P.encode() not in f.read(), "fixture has no full prefix")
    m = {"foo": "out", "foo-libs": "lib"}
    c.run(m, expect_rc=1)
    c.has("pieced-unacked", "error", "lib/lib64/libfoo.so.1")
    c.run(m, {"opaqueRefs": ["lib:lib64/libfoo.so.*"]}, expect_rc=0)
    c.no_errors()
    eq(c.read("lib", "nix-support/hidden-references"), c.P + "\n", "hidden-references")
    true("out" in c.report["graph"]["edges"].get("lib", {}), "edge lib -> out registered")


def t_prefix_relative():
    c = Case("prefixrel")
    c.sub("foo", ["foo-libs"]).sub("foo-libs")
    c.cc("foo-libs", "lib64/libfoo.so.1", 'const char *d(void) { return "@P@"; }\n', ["-Wl,-soname,libfoo.so.1"],
         shared=True)
    c.text("foo", "bin/x", "#!/bin/sh\n")
    m = {"foo": "out", "foo-libs": "lib"}
    c.run(m, expect_rc=1)
    c.has("prefix-relative", "error", "lib/lib64/libfoo.so.1 names the bare prefix")
    c.run(m, {"prefixRelativeOk": ["lib"]}, expect_rc=0)
    c.no_errors()


def t_late():
    """lateBind: an output reaching a late output must be listed in
    lateReferrers; rocky-late.json records L*"""
    c = Case("late")
    c.sub("foo", ["foo-common"]).sub("foo-common").sub("foo-lang", ["foo-common"])
    c.text("foo-common", "bin/tool", "#!/usr/bin/bash\necho\n", mode=0o755)
    c.text("foo-common", "share/foo/C.utf8", "c\n")
    c.link("foo-lang", "share/foo/de", "C.utf8")
    c.text("foo", "bin/foo", "#!/bin/sh\n")
    m = {"foo": "out", "foo-common": "common", "foo-lang": "lang"}
    late = {"common": {"interpreters": ["bash"]}}
    c.run(m, {"lateBind": late}, expect_rc=1)
    c.has("late-referrer-missing", "error", "lang reaches lateBind output common")
    c.run(m, {"lateBind": late, "lateReferrers": {"common": ["lang"]}}, expect_rc=0)
    c.no_errors()
    lj = json.load(open(c.p("out", "nix-support/rocky-late.json")))
    eq(lj["lstar"], ["common", "lang"], "L*")
    c.has("fhs-shebang", "info", "common/bin/tool")


def t_subpackages_unclaimed():
    c = Case("decl")
    c.sub("foo").sub("foo-extra")
    c.text("foo", "bin/x", "#!/bin/sh\n")
    c.text("foo-extra", "share/x", "x\n")
    c.run({"foo": "out", "foo-ghost": "ghost"}, expect_rc=1, unclaimed="leftover")
    c.has("undeclared-subpackage", "error", "foo-extra")
    c.has("missing-subpackage", "error", "foo-ghost")
    c.has("unclaimed-file", "error", "leftover")


def t_replay():
    """--replay/--remap: same-length remap of a kept tree into other outputs"""
    c = Case("replay")
    split_fixture(c)
    old = c.P
    c.run(SPLIT_MAP, replay=True, expect_rc=0)
    c.no_errors()
    new = c.outputs["out"]
    true(new != old and len(new) == len(old), "new prefix")
    eq(c.runpath("out", "bin/foo"), c.p("lib", "lib64"), "RUNPATH of bin/foo (replay)")
    with open(c.p("out", "bin/foo"), "rb") as f:
        b = f.read()
    true(new.encode() in b and old.encode() not in b, "ELF strings remapped")
    with open(c.p("doc", "share/man/man1/foo.1.gz"), "rb") as f:
        page = gzip.decompress(f.read()).decode()
    true(new in page and old not in page, "gzip member re-encoded with the new prefix")
    eq(c.report["replay"]["leftovers"], [], "nothing of the old prefix left")


def t_plan_errors():
    c = Case("planerr")
    c.sub("foo")
    c.text("foo", "bin/x", "#!/bin/sh\n")
    c.run({"foo": "out"}, {"noSuchKey": 1}, expect_rc=2)
    true("unknown plan keys: noSuchKey" in c.stderr, c.stderr)


CASES = [t_split, t_libs_self_cycle, t_search_path, t_text_cycle, t_dangling_foreign_union, t_pieced,
         t_prefix_relative, t_late, t_subpackages_unclaimed, t_replay, t_plan_errors]


def main():
    os.makedirs(STORE, exist_ok=True)
    failed = []
    for t in CASES:
        if ONLY and t.__name__[2:] not in ONLY:
            continue
        try:
            t()
            print("PASS %s" % t.__name__[2:])
        except Exception:
            failed.append(t.__name__)
            print("FAIL %s\n%s" % (t.__name__[2:], traceback.format_exc()))
    print("%d case(s), %d failed" % (len(CASES) if not ONLY else len(ONLY), len(failed)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
