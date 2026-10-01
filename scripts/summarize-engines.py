#!/usr/bin/env python3
"""Print the markdown tables of docs/COMPARISON.md's "verdict vs Ollama" section from the evidence records
that scripts/compare-engine.py wrote, so every number in the doc is read from a record, never retyped.

  python3 scripts/summarize-engines.py --date 2026-10-01 verdict-fm verdict-laya ollama-nimble ollama-tev1 ollama-tev1-0.8b
"""
import argparse, json
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument("--date", required=True)
ap.add_argument("labels", nargs="+")
a = ap.parse_args()
EV = Path(__file__).resolve().parent.parent / "evidence"


def load(kind, label):
    p = EV / f"{kind}-{a.date}-{label}.json"
    return json.load(open(p)) if p.exists() else None


def f(x, n=3):
    return "—" if x is None else f"{x:.{n}f}"


def mb(b):
    return "0" if not b else f"{b / 1e9:.1f} GB" if b >= 1e9 else f"{b / 1e6:.0f} MB"


def mem(eng):
    m = eng.get("memory") or {}
    fp = m.get("peak_footprint_mb")
    return f"{fp / 1024:.1f} GB" if fp else "—"


rows = []
for lb in a.labels:
    eng, nim = load("engine", lb) or {}, (load("nimble-public", lb) or {}).get("summary", {})
    jb, oj = load("jevbench", f"faithful-{lb}") or {}, (load("openjev", lb) or {}).get("summary", {})
    clip = (load("compare", f"clip204-{lb}") or {}).get("summary", {})
    ece = (jb.get("ece") or {}).get("ece") if isinstance(jb.get("ece"), dict) else jb.get("ece")
    o = nim.get("overall", {})
    rows.append((lb, eng, nim, jb, oj, clip, ece, o))

print("| engine | Bespoke suite macro / micro (13 sets, 3,880) | JevBench public (231) | Open-Jev (224) | "
      "clip join P / R / leaks (204) | ECE (Bespoke) | recal. gain | P50 / P95 per decision | cold 1st decision | "
      "peak footprint | model on disk |")
print("|---|---|---|---|---|---|---|---|---|---|---|")
for lb, eng, nim, jb, oj, clip, ece, o in rows:
    rc = (nim.get("recalibration") or {}).get("recalibration_gain")
    print(f"| {lb} | {f(nim.get('macro_accuracy'))} / {f(nim.get('micro_accuracy'))} | {f(jb.get('accuracy'))} | "
          f"{f(oj.get('accuracy'))} | {f(clip.get('surface_precision'))} / {f(clip.get('surface_recall'), 2)} / "
          f"{clip.get('secret_leaks', '—')} | {f(o.get('ece10'))} | {f(rc)} | "
          f"{o.get('latency_p50_s', 0) * 1000:.0f} / {o.get('latency_p95_s', 0) * 1000:.0f} ms | "
          f"{eng.get('cold_first_decision_ms', '—')} ms | {mem(eng)} | "
          f"{mb((eng.get('disk') or {}).get('model_bytes'))} |")

subsets = list(rows[0][2].get("by_subset", {}).keys())
print()
print("| subset | type | n | " + " | ".join(r[0] for r in rows) + " |")
print("|---|---|---|" + "---|" * len(rows))
types = {}
for r in rows:
    for it in (load("nimble-public", r[0]) or {}).get("items", []):
        types.setdefault(it["subset"], it["type"])
for s in subsets:
    cells = []
    for r in rows:
        g = r[2].get("by_subset", {}).get(s, {})
        cell = f(g.get("accuracy"))
        if g.get("errors"): cell += f" ({g['errors']} err)"
        cells.append(cell)
    print(f"| {s} | {types.get(s, '')} | {rows[0][2]['by_subset'][s]['n']} | " + " | ".join(cells) + " |")
print("| **macro** | | 3,880 | " + " | ".join(f"**{f(r[2].get('macro_accuracy'))}**" for r in rows) + " |")
for t in ("choice", "noul", "score"):
    print(f"| macro {t} | | | " + " | ".join(f((r[2].get('macro_by_type') or {}).get(t)) for r in rows) + " |")

print()
print("| engine | clip P50 / P95 per request (4 questions) | JevBench P50 / P95 | Open-Jev P50 | warm single decision | "
      "errors (Bespoke) | runtime on disk |")
print("|---|---|---|---|---|---|---|")
for lb, eng, nim, jb, oj, clip, ece, o in rows:
    lat = jb.get("latency") or {}
    print(f"| {lb} | {f(clip.get('latency_p50_ms'), 0)} / {f(clip.get('latency_p95_ms'), 0)} ms | "
          f"{f((lat.get('p50_s') or 0) * 1000, 0)} / {f((lat.get('p95_s') or 0) * 1000, 0)} ms | "
          f"{f(oj.get('latency_p50_ms'), 0)} ms | {eng.get('warm_median_ms', '—')} ms | {o.get('errors', '—')} | "
          f"{(eng.get('disk') or {}).get('runtime_kb', 0) / 1024:.0f} MB |")
