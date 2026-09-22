#!/usr/bin/env python3
"""Validate a verdict topology JSON against the wire contract, so a broken example never ships:
- choice questions: `criteria` MUST be an object (key -> description); an array fails to load.
- score questions:  `criteria` MUST be an array of level labels.
- noul questions:   `criteria` absent, or an object.
- every `model` MUST be a canonical verdict backend (verdict-fm / verdict-laya), not an alias
  (e.g. `jev-latest` silently resolves to verdict-fm — name the backend you mean).
Exit non-zero on any violation. Usage: check-topology.py <topology.json> [more.json ...]
"""
import json, sys
CANON = {"verdict-fm", "verdict-laya"}
def check(path):
    errs = []
    d = json.load(open(path))
    for tname, t in (d.get("types") or {}).items():
        m = t.get("model", "verdict-fm")
        if m not in CANON:
            errs.append(f"{tname}: model `{m}` is not a canonical backend {sorted(CANON)}")
        for qid, q in (t.get("questions") or {}).items():
            kind, crit = q.get("type"), q.get("criteria")
            if kind == "choice" and not isinstance(crit, dict):
                errs.append(f"{tname}.{qid}: choice `criteria` must be an object, got {type(crit).__name__}")
            elif kind == "score" and not isinstance(crit, list):
                errs.append(f"{tname}.{qid}: score `criteria` must be an array, got {type(crit).__name__}")
            elif kind == "noul" and crit is not None and not isinstance(crit, dict):
                errs.append(f"{tname}.{qid}: noul `criteria` must be absent or an object")
    return errs
if __name__ == "__main__":
    bad = 0
    for p in sys.argv[1:]:
        e = check(p)
        if e:
            bad += 1; print(f"FAIL {p}"); [print(f"  - {x}") for x in e]
        else:
            print(f"OK   {p}")
    sys.exit(1 if bad else 0)
