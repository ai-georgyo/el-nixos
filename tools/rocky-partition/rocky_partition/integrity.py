"""Integrity-protected files: FIPS self-check data that a byte change of
its file invalidates (phase E's patchelf, the replay remap).

  companion   fipscheck format, one hex HMAC-SHA256 line keyed with
              fipscheck's key: <dir>/fipscheck/<name>.hmac (libxcrypt) or
              <dir>/.<name>.hmac (nettle). Other formats under those names
              (gnutls' INI file) cannot be verified.
  embedded    an HMAC inside the ELF file: section .rodata1 (openssl's
              fips.so, fips-hmacify.sh) or .note.fdo.integrity (libgcrypt,
              gen-note-integrity.sh); computed over the file itself.

A companion that verifies against its target before phase E is recomputed
after every change of the target (what fipshmac does at the end of
%install), and the change is reported as `integrity-rehashed`. A target
whose companion does not verify, and an embedded file, must not change:
phase E reports `integrity-runpath` and leaves the file as linked (remedy:
noPatchelf with a RUNPATH set at link time, or integrityOk when the data is
regenerated later or known unused)."""
import hashlib
import hmac
import os
import re

from .plan import output_rel_match
from .refs import walk_files

FIPSCHECK_KEY = b"orboDeJITITejsirpADONivirpUkvarP"
EMBEDDED_SECTIONS = (".rodata1", ".note.fdo.integrity")
HEX_LINE = re.compile(rb"\s*([0-9a-f]{64})\s*")


def _digest(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def fipscheck_hmac(path):
    with open(path, "rb") as f:
        return hmac.new(FIPSCHECK_KEY, f.read(), hashlib.sha256).hexdigest()


class Companion:
    __slots__ = ("output", "rel", "path", "target", "verified", "digest")

    def __init__(self, output, rel, path, target):
        self.output, self.rel, self.path, self.target = output, rel, path, target
        with open(path, "rb") as f:
            m = HEX_LINE.fullmatch(f.read())
        self.verified = bool(m) and m.group(1).decode() == fipscheck_hmac(target)
        self.digest = _digest(target)


class Integrity:
    def __init__(self, ctx):
        self.ctx = ctx
        self.companions = {}     # realpath of the target -> [Companion]
        self.embedded = {}       # realpath -> (output, rel, section)

    def scan(self):
        """find the companions (after materialise, before phases D/E)"""
        ctx, rep = self.ctx, self.ctx.report
        outs = [o for o in ctx.managed if o != ctx.debug_output]
        for o in outs:
            for rel, path in walk_files(ctx.out[o]):
                d, n = os.path.split(rel)
                if not n.endswith(".hmac") or n == ".hmac":
                    continue
                if os.path.basename(d) == "fipscheck":
                    trel = os.path.join(os.path.dirname(d), n[:-5])
                elif n.startswith("."):
                    trel = os.path.join(d, n[1:-5])
                else:
                    continue
                # the target: the same output first, then the siblings
                cand = [x for x in [o] + outs if os.path.lexists(ctx.path_of(x, trel))]
                if not cand:
                    rep.warning("integrity-orphan", "%s/%s: integrity file for %s, which is in no output"
                                % (o, rel, trel), output=o, file=rel)
                    continue
                target = os.path.realpath(ctx.path_of(cand[0], trel))
                if not os.path.isfile(target):
                    continue
                c = Companion(o, rel, path, target)
                self.companions.setdefault(target, []).append(c)
                rep.info("integrity-file", "%s/%s: integrity data of %s/%s (%s)"
                         % (o, rel, cand[0], trel, "fipscheck HMAC, verified" if c.verified
                            else "unknown format or stale: cannot be recomputed"), output=o, file=rel)

    def note_elf(self, y, rel, path, ef):
        """phase D: an ELF file with an embedded integrity HMAC"""
        sec = next((n for n, *_r in ef.sections if n in EMBEDDED_SECTIONS), None)
        if sec is not None and y != self.ctx.debug_output:
            self.embedded[os.path.realpath(path)] = (y, rel, sec, _digest(path))
            self.ctx.report.info("integrity-file", "%s/%s: embedded integrity HMAC (section %s)" % (y, rel, sec),
                                 output=y, file=rel)

    def hold(self, y, rel, path, old, new):
        """phase E, before patchelf: True = leave the file unchanged (error
        reported); False = patch (companions are recomputed by finish)"""
        rep, plan = self.ctx.report, self.ctx.plan
        rp = os.path.realpath(path)
        why = []
        if rp in self.embedded:
            why.append("it carries an embedded integrity HMAC (section %s)" % self.embedded[rp][2])
        bad = [c for c in self.companions.get(rp, []) if not c.verified]
        if bad:
            why.append("its integrity file%s %s cannot be recomputed (unknown format, or stale already)"
                       % ("s" if len(bad) > 1 else "", ", ".join("%s/%s" % (c.output, c.rel) for c in bad)))
        if not why:
            return False
        ack = output_rel_match(y, rel, plan.integrityOk)
        if ack:
            rep.info("integrity-runpath", "%s/%s: RUNPATH %r -> %r although %s (acked: integrityOk %s)"
                     % (y, rel, old, new, "; ".join(why), ack), output=y, file=rel)
            return False
        rep.error("integrity-runpath", "%s/%s: RUNPATH must change (%r -> %r) but %s: patchelf would break its"
                  " FIPS self-check, so the file is left as linked; set the RUNPATH at link time and list it in"
                  " noPatchelf, or ack with integrityOk" % (y, rel, old, new, "; ".join(why)), output=y, file=rel)
        return True

    def finish(self):
        """after phase E (and the replay remap): recompute the verified
        companions of changed targets; report the other changes"""
        ctx, rep = self.ctx, self.ctx.report
        done = []
        for target, cs in sorted(self.companions.items()):
            if not os.path.isfile(target) or _digest(target) == cs[0].digest:
                continue
            for c in cs:
                if c.verified:
                    new = fipscheck_hmac(target)
                    os.chmod(c.path, os.stat(c.path).st_mode | 0o200)
                    with open(c.path, "w") as f:
                        f.write(new + "\n")
                    done.append("%s/%s" % (c.output, c.rel))
                    rep.info("integrity-rehashed", "%s/%s: recomputed for the changed %s"
                             % (c.output, c.rel, os.path.basename(target)), output=c.output, file=c.rel)
                elif ctx.replay_old:
                    rep.warning("integrity-replay", "%s/%s: its target changed in the replay remap and it cannot be"
                                " recomputed (development copy)" % (c.output, c.rel), output=c.output, file=c.rel)
        for target, (y, rel, sec, dg) in sorted(self.embedded.items()):
            if ctx.replay_old and os.path.isfile(target) and _digest(target) != dg:
                rep.warning("integrity-replay", "%s/%s: the replay remap changed a file with an embedded integrity"
                            " HMAC (%s): its self-check fails in this development copy" % (y, rel, sec),
                            output=y, file=rel)
        rep.section("integrity", {
            "companions": sorted("%s/%s" % (c.output, c.rel) for cs in self.companions.values() for c in cs),
            "unverifiable": sorted("%s/%s" % (c.output, c.rel) for cs in self.companions.values() for c in cs
                                   if not c.verified),
            "embedded": sorted("%s/%s" % (y, rel) for y, rel, _s, _d in self.embedded.values()),
            "rehashed": sorted(done)})
