"""--check-shebangs: the shebang gate of design decision 11 / §1.4.3, run
after the fixup phase (nixpkgs `patchShebangs --host` has bound what the
runtime inputs provide).  The partition itself only warns (`fhs-shebang`),
because it runs before patchShebangs.

An executable regular file of a managed output (not debugOutput, not
unmanagedOutputs) whose `#!` interpreter is an FHS path (/usr/, /bin/,
/sbin/) is an error unless it is
  * runtime FHS (`/bin/sh`, `/usr/bin/env`, design §1.4),
  * late-bound (its basename in lateBind.<output>.interpreters), or
  * in fhsAllowlist (`"#!/usr/bin/sh"` or `"/usr/bin/sh"` -> reason;
    bootstrap stages only).
Non-executable files are not checked (nothing can exec them; patchShebangs
skips them too)."""
import os
import stat
import sys

from . import scan as S
from .refs import RUNTIME_FHS

FHS_DIRS = ("/usr/", "/bin/", "/sbin/")


def check(plan, out=sys.stderr):
    """-> number of errors; one line per finding on `out`"""
    if not plan.outputs:
        print("rocky-partition --check-shebangs: the plan has no outputs", file=out)
        return 1
    skip = set(plan.unmanagedOutputs) | ({plan.debugOutput} if plan.debugOutput else set())
    errors = allowed = 0
    for o, root in sorted(plan.outputs.items()):
        if o in skip or not os.path.isdir(root):
            continue
        late = plan.lateBind.get(o, {}).get("interpreters", [])
        for d, dirs, files in os.walk(root):
            dirs.sort()
            for n in sorted(files):
                p = os.path.join(d, n)
                st = os.lstat(p)
                if not stat.S_ISREG(st.st_mode) or not st.st_mode & 0o111:
                    continue
                with open(p, "rb") as f:
                    head = f.read(512)
                sb = S.shebang(head)
                if not sb or not sb.startswith(FHS_DIRS) or sb in RUNTIME_FHS:
                    continue
                rel = os.path.relpath(p, root)
                why = plan.fhsAllowlist.get("#!" + sb) or plan.fhsAllowlist.get(sb) \
                    or (os.path.basename(sb) in late and "lateBind.%s.interpreters" % o)
                if why:
                    allowed += 1
                    print("fhs-shebang (allowed: %s): %s/%s: #!%s" % (why, o, rel, sb), file=out)
                else:
                    errors += 1
                    print("error: fhs-shebang: %s/%s: #!%s is not bound (no runtime input provides %s),"
                          " not runtime FHS (#!/bin/sh, #!/usr/bin/env), not late-bound and not in"
                          " fhsAllowlist" % (o, rel, sb, os.path.basename(sb)), file=out)
    print("rocky-partition --check-shebangs: %s: %d unbound FHS shebang(s), %d allowed"
          % (plan.srpm or "?", errors, allowed), file=out)
    return errors
