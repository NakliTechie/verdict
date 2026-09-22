#!/usr/bin/env python3
"""Re-score a typed-decisions hybrid items file against the corrected gold labels (noul true/false
-> yes/no), recomputing *_ok from the stored predictions. No model calls: only exp + *_ok change.

  python3 scripts/rescore-typed.py <items.json> --dataset <typed-test.json>
"""
import json, os, sys, argparse
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _hybrid_load import build_tasks
ap=argparse.ArgumentParser(); ap.add_argument("items"); ap.add_argument("--dataset",required=True)
a=ap.parse_args()
items=json.load(open(os.path.expanduser(a.items)))
exp_by_id={t["id"]:t["expected"] for t in build_tasks(a.dataset,"typed_decisions")}
changed=0; unmatched=0
for x in items:
    ne=exp_by_id.get(x["id"])
    if ne is None: unmatched+=1; continue
    if ne!=x.get("exp"): changed+=1
    x["exp"]=ne
    x["fm_ok"]=(x.get("fm")==ne); x["laya_ok"]=(x.get("laya")==ne)
    if "qwen" in x: x["qwen_ok"]=(x.get("qwen")==ne)
json.dump(items,open(os.path.expanduser(a.items),"w"))
print(f"rescored {len(items)} items: {changed} exp labels corrected, {unmatched} unmatched -> {a.items}")
