"""The decision log: findings (error / warning / info, each with a stable
code) plus named sections (edges, stubs, rewrites, ...), written to
$<prefix output>/nix-support/rocky-report.json (design §2.10)."""
import collections
import json
import sys

ERROR, WARNING, INFO = "error", "warning", "info"

# code -> one-line meaning (PLAN.md lists them with remedies)
CODES = {
    # phase A/B
    "undeclared-subpackage": "a subpackage was built that the plan does not map to an output",
    "missing-subpackage": "a subpackage of the plan was not built",
    "unclaimed-file": "a BUILDROOT file no RPM claims",
    "missing-file": "a header file (not %ghost) is absent from BUILDROOT",
    "other-absolute": "a header path outside /usr, the prefix and /etc,/var,/run",
    "build-id-dropped": "usr/lib/.build-id links of a non-debug subpackage were dropped",
    "hardlink-split": "a hard link group spans outputs and was split into copies",
    "setid-dropped": "setuid/setgid bit dropped (recorded in nix-support/rpm/*.json)",
    "shared-file": "a file owned by several outputs is copied into each",
    # phase C
    "symlink-dangling": "a symlink target exists in no output",
    "symlink-union": "a symlink target is owned by several outputs, none of them the link's",
    # phase D
    "prefix-relative": "bare prefix (or a union dir below it) referenced from a non-prefix output",
    "prefix-relative-out": "bare prefix referenced from the prefix output (info)",
    "union-unacked": "reference to a directory/file owned by several outputs without an unionDirs/runtimeSearchPaths ack",
    "dangling": "reference to a path that exists in no output",
    "union-self": "text reference to a directory several outputs fill rewritten to the referrer's own part",
    "pc-expanded": "prefix-derived pkg-config variables of a non-prefix output written out in full",
    "not-required": "text reference into an output the referrer does not Require (kept as $out/rel)",
    "foreign-store-path": "store path neither an own output nor allowed",
    "fhs-shebang": "#! interpreter in FHS form (patchShebangs, lateBind or fhsAllowlist must cover it)",
    "fhs-literal": "FHS path literal in an output (strictFhs makes it an error)",
    # phase E
    "unresolved-needed": "DT_NEEDED soname found nowhere",
    "ambiguous-needed": "DT_NEEDED soname provided by several sibling outputs",
    "runpath-changed": "RUNPATH recomputed",
    "integrity-file": "FIPS integrity data found (a companion .hmac file, or an HMAC embedded in the ELF file)",
    "integrity-orphan": "a companion .hmac file whose target is in no output",
    "integrity-runpath": "RUNPATH must change but the file's integrity data cannot follow (left as linked)",
    "integrity-rehashed": "a verified companion .hmac file recomputed for its changed target",
    # phase F
    "binary-ref": "compiled-in reference into a non-prefix output that no stub/search path serves",
    "stub": "forwarding stub created",
    # phase G
    "pieced-unacked": "store-by-pieces reference in a non-prefix output without an opaqueRefs ack",
    "pieced": "store-by-pieces reference (registered)",
    "nested-ref": "reference inside compressed/nested data (registered in hidden-references)",
    # phase H
    "cycle": "reference cycle between outputs",
    "debug-referenced": "an output references the debug/unmanaged output",
    "merge-unneeded": "a mergeOutputs group whose members do not reference each other",
    "late-referrer-missing": "an output reaching a lateBind output is not in lateReferrers",
    "late-referrer-unused": "a lateReferrers entry matched no referrer",
    "late-elf-ref": "ELF content of L* references a lateBind output",
    # replay
    "replay-remap-incomplete": "the old prefix survives in an output after --remap",
    "integrity-replay": "the replay remap changed a file whose integrity data cannot be recomputed",
}


class Report:
    def __init__(self, max_samples=20, verbose=True):
        self.items = []
        self.sections = collections.OrderedDict()
        self.max_samples = max_samples
        self.verbose = verbose
        self._per_code = collections.Counter()

    def add(self, severity, code, message, **where):
        assert code in CODES, code
        self._per_code[(severity, code)] += 1
        item = {"severity": severity, "code": code, "message": message}
        item.update({k: v for k, v in where.items() if v is not None})
        self.items.append(item)
        if self.verbose and severity == ERROR and self._per_code[(severity, code)] <= self.max_samples:
            print("rocky-partition: error: [%s] %s" % (code, message), file=sys.stderr)
        return item

    def error(self, code, message, **where):
        return self.add(ERROR, code, message, **where)

    def warning(self, code, message, **where):
        return self.add(WARNING, code, message, **where)

    def info(self, code, message, **where):
        return self.add(INFO, code, message, **where)

    def section(self, name, default=None):
        if name not in self.sections:
            self.sections[name] = {} if default is None else default
        return self.sections[name]

    def errors(self):
        return [i for i in self.items if i["severity"] == ERROR]

    def summary(self):
        by = collections.defaultdict(dict)
        for (sev, code), n in sorted(self._per_code.items()):
            by[sev][code] = n
        return {"errors": sum(by[ERROR].values()), "warnings": sum(by[WARNING].values()),
                "info": sum(by[INFO].values()), "byCode": by}

    def to_json(self, header):
        # bounded: info items beyond max_samples per code are counted, not listed
        kept, seen = [], collections.Counter()
        for i in self.items:
            k = (i["severity"], i["code"])
            seen[k] += 1
            if i["severity"] != INFO or seen[k] <= self.max_samples:
                kept.append(i)
        doc = dict(header)
        doc["summary"] = self.summary()
        doc["findings"] = kept
        doc.update(self.sections)
        return doc

    def write(self, path, header):
        with open(path, "w") as f:
            json.dump(self.to_json(header), f, indent=1, sort_keys=False, default=sorted)
            f.write("\n")
