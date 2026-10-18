"""plan.json: loading, defaults, validation (schema: ../PLAN.md)."""
import fnmatch
import json
import re


class PlanError(Exception):
    pass


# key -> (type, default); type: str, bool, int, list, dict, "str?" (str or None), "dict?", "list?"
SCHEMA = {
    "version": (int, 1),
    "srpm": (str, ""),
    "buildroot": ("str?", None),
    "rpmsDir": ("str?", None),
    "rpm": ("str?", None),
    "rpmConfigDir": ("str?", None),
    "prefix": ("str?", None),
    "prefixOutput": (str, "out"),
    "outputs": ("dict?", None),
    "subpackages": (dict, None),
    "debugOutput": ("str?", "debug"),
    "unmanagedOutputs": (list, []),
    "requires": ("dict?", None),
    "mergeOutputs": (list, []),
    "layout": (dict, {}),
    "runtimeSearchPaths": (dict, {}),
    "searchPaths": (dict, {}),
    "unionDirs": (dict, {}),
    "danglingOk": (list, []),
    "opaqueRefs": (list, []),
    "prefixRelativeOk": (list, []),
    "forward": (dict, {}),
    "lateBind": (dict, {}),
    "lateReferrers": (dict, {}),
    "noPatchelf": (list, []),
    "integrityOk": (list, []),
    "fhsAllowlist": (dict, {}),
    "strictFhs": (bool, False),
    "allowUnresolvedNeeded": (list, []),
    "inputLibDirs": (list, []),
    "systemLibDirs": (list, []),
    "allowedStorePaths": ("list?", None),
    "patchelf": ("str?", None),
    "storeDir": (str, "/nix/store"),
    "failOnError": (bool, True),
    "reportFile": ("str?", None),
    "copy": (bool, False),
    "maxSamples": (int, 20),
}

_TYPES = {"str?": (str, type(None)), "dict?": (dict, type(None)), "list?": (list, type(None))}


class Plan:
    def __init__(self, d):
        for k, (_t, default) in SCHEMA.items():
            v = d.get(k, default)
            if isinstance(v, (list, dict)):
                v = json.loads(json.dumps(v))  # private copy
            setattr(self, k, v)


def _check(d):
    unknown = sorted(set(d) - set(SCHEMA))
    if unknown:
        raise PlanError("unknown plan keys: %s" % ", ".join(unknown))
    for k, v in d.items():
        t = SCHEMA[k][0]
        ok = isinstance(v, _TYPES[t]) if isinstance(t, str) else isinstance(v, t)
        if t is int and isinstance(v, bool):
            ok = False
        if not ok:
            raise PlanError("plan key %s: expected %s, got %r" % (k, t if isinstance(t, str) else t.__name__, v))
    if d.get("version", 1) != 1:
        raise PlanError("unsupported plan version %r" % d.get("version"))
    if "subpackages" not in d:
        raise PlanError("plan key subpackages is required")
    for k in ("forward",):
        extra = set(d.get(k, {})) - {"deny"}
        if extra:
            raise PlanError("plan key forward: unknown keys %s" % sorted(extra))
    for o, spec in d.get("lateBind", {}).items():
        if not isinstance(spec, dict) or set(spec) - {"interpreters", "libs", "sonames"}:
            raise PlanError("lateBind.%s: expected {interpreters, libs, sonames}" % o)
    for g in d.get("mergeOutputs", []):
        if not (isinstance(g, list) and g and all(isinstance(x, str) for x in g)):
            raise PlanError("mergeOutputs: expected a list of non-empty subpackage lists")


def load(path):
    """Read a plan file. It is either the plan itself, or a __structuredAttrs
    attrs file ($NIX_ATTRS_JSON_FILE) with the plan under "rockyPlan" and the
    output paths under "outputs"."""
    with open(path) as f:
        doc = json.load(f)
    if "rockyPlan" in doc:
        d = dict(doc["rockyPlan"])
        if d.get("outputs") is None and isinstance(doc.get("outputs"), dict):
            d["outputs"] = doc["outputs"]
    else:
        d = doc
    _check(d)
    return Plan(d)


def substitute(s, outputs):
    """@<output>@ -> that output's path (in path lists of the plan)."""
    def rep(m):
        n = m.group(1)
        if n not in outputs:
            raise PlanError("unknown output in @%s@" % n)
        return outputs[n]
    return re.sub(r"@([A-Za-z0-9_]+)@", rep, s)


def rel_match(rel, patterns):
    """True if `rel` equals a pattern, lies below it, or fnmatches it
    (`*` also matches `/`). Returns the matching pattern or None."""
    for p in patterns:
        p2 = p.strip("/")
        if rel == p2 or rel.startswith(p2 + "/") or fnmatch.fnmatchcase(rel, p2):
            return p
    return None


def glob_match(name, patterns):
    for p in patterns:
        if fnmatch.fnmatchcase(name, p):
            return p
    return None


def output_rel_match(output, rel, entries):
    """opaqueRefs-style entries: "<output>" or "<output>:<rel glob>"."""
    for e in entries:
        o, _, g = e.partition(":")
        if fnmatch.fnmatchcase(output, o) and (not g or fnmatch.fnmatchcase(rel, g)):
            return e
    return None

