#!/usr/bin/env python3
"""Run verdict against JevBench's public tasks (MIT, github.com/fstandhartinger/jevbench).
Maps each task 1:1 to verdict's /v1/systemone wire, scores accuracy per tier / type / family.

  python3 scripts/run-jevbench.py <jevbench-repo> --model verdict-fm --url http://127.0.0.1:7311 --token-file <f> [--out r.json]

Label-only note: verdict-fm returns no probability, so this scores Intelligence (accuracy) + latency only,
not JevBench's Calibration axis (which is 0 for label-only systems by their rule).
"""
import json, os, sys, time, argparse, urllib.request, glob
from collections import defaultdict

ap = argparse.ArgumentParser()
ap.add_argument("repo"); ap.add_argument("--model", default="verdict-fm")
ap.add_argument("--url", default="http://127.0.0.1:7311"); ap.add_argument("--token-file")
ap.add_argument("--out"); ap.add_argument("--limit", type=int)
args = ap.parse_args()
token = open(os.path.expanduser(args.token_file)).read().strip() if args.token_file else None

tiers = {"easy": "easy", "hard": "hard", "original": "original"}
tasks = []
for tier, f in tiers.items():
    for line in open(os.path.join(args.repo, "datasets/public", f + ".jsonl")):
        t = json.loads(line); t["_tier"] = tier
        if t.get("expected") is not None:
            tasks.append(t)
if args.limit: tasks = tasks[:args.limit]

def ask(task):
    q = task["question"]; state = task["state"] if isinstance(task["state"], str) else json.dumps(task["state"], ensure_ascii=False)
    wq = {"type": q["type"], "instructions": q["instructions"]}
    if q.get("criteria") is not None: wq["criteria"] = q["criteria"]
    body = json.dumps({"model": args.model, "state": state, "questions": {"q": wq}}).encode()
    req = urllib.request.Request(args.url.rstrip("/") + "/v1/systemone", data=body,
        headers={"Content-Type": "application/json", **({"Authorization": f"Bearer {token}"} if token else {})})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=180) as r: resp = json.load(r)
        return resp, (time.time() - t0) * 1000, None
    except urllib.error.HTTPError as e:
        return json.load(e), (time.time() - t0) * 1000, f"http{e.code}"
    except Exception as e:
        return None, (time.time() - t0) * 1000, type(e).__name__

def predicted_label(resp, qtype):
    a = resp.get("answers", {}).get("q")
    if a is None: return None
    if qtype == "choice": return a.get("choice")
    if qtype == "noul":   return "yes" if (a.get("noul", 0) >= 0.5) else "no"
    if qtype == "score":  return str(a.get("level"))
    return None

by = lambda: {"n": 0, "correct": 0, "failed": 0}
tier_s = defaultdict(by); type_s = defaultdict(by); fam_s = defaultdict(by)
lat = []; items = []; total = correct = failed = 0
for i, t in enumerate(tasks):
    qt = t["question"]["type"]; exp = str(t["expected"]) if qt == "score" else t["expected"]
    resp, ms, err = ask(t); lat.append(ms)
    pred = predicted_label(resp, qt) if resp else None
    fail = pred is None or (resp and "q" in resp.get("failures", {}))
    code = (resp.get("failures", {}).get("q", {}) or {}).get("code") if resp else err
    ok = (not fail) and (pred == exp)
    total += 1; correct += ok; failed += fail
    for d, k in ((tier_s, t["_tier"]), (type_s, qt), (fam_s, t["family"])):
        d[k]["n"] += 1; d[k]["correct"] += ok; d[k]["failed"] += fail
    items.append({"id": t["id"], "tier": t["_tier"], "type": qt, "family": t["family"],
                  "predicted": pred, "expected": exp, "correct": bool(ok), "failed": bool(fail), "code": code, "ms": round(ms)})
    if (i + 1) % 20 == 0: print(f"  {i+1}/{len(tasks)}  acc {correct}/{total}", flush=True)

def acc(d): return {k: {"acc": round(v["correct"]/v["n"], 3), "n": v["n"], "failed": v["failed"]} for k, v in sorted(d.items())}
lat.sort()
summary = {"model": args.model, "tasks": total, "accuracy": round(correct/total, 3), "correct": correct, "failed": failed,
           "latency_p50_ms": lat[len(lat)//2], "latency_p90_ms": lat[int(len(lat)*0.9)],
           "by_tier": acc(tier_s), "by_type": acc(type_s), "by_family": acc(fam_s),
           "note": "public subset only (109 hard held out); label-only accuracy — no JevBench Calibration axis for verdict-fm"}
print(json.dumps(summary, indent=1))
if args.out: json.dump({"summary": summary, "items": items}, open(args.out, "w"), indent=1); print("record:", args.out)
