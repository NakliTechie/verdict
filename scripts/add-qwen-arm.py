#!/usr/bin/env python3
"""Backfill a third backend (Qwen3.5-4B via llamacpp-jev) into an existing hybrid-experiment items file,
matched by id. Additive and resumable: only items lacking qwen_ok are queried; checkpoints every N.
The fm/laya columns collected by hybrid-experiment.py are never re-run.

  python3 scripts/add-qwen-arm.py <items.json> --dataset <ds> --format openjev|typed_decisions \
      --qwen-url http://127.0.0.1:8010 --qwen-model jev-latest [--checkpoint-every 25]
"""
import json, os, sys, argparse
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _hybrid_load import build_tasks, ask_endpoint

ap=argparse.ArgumentParser()
ap.add_argument("items"); ap.add_argument("--dataset",required=True)
ap.add_argument("--format",choices=["openjev","jevbench","typed_decisions"],required=True)
ap.add_argument("--qwen-url",default="http://127.0.0.1:8010"); ap.add_argument("--qwen-model",default="jev-latest")
ap.add_argument("--qwen-key"); ap.add_argument("--checkpoint-every",type=int,default=25)
a=ap.parse_args()
key=open(os.path.expanduser(a.qwen_key)).read().strip() if a.qwen_key else None

items=json.load(open(os.path.expanduser(a.items)))
tmap={t["id"]:t for t in build_tasks(a.dataset,a.format)}
todo=[x for x in items if "qwen_ok" not in x and x["id"] in tmap]
missing=[x for x in items if "qwen_ok" not in x and x["id"] not in tmap]
print(f"{len(items)} items, {len(todo)} to query, {len(missing)} unmatched-by-id (skipped)",flush=True)

def save(): json.dump(items,open(os.path.expanduser(a.items),"w"))
for i,x in enumerate(todo):
    t=tmap[x["id"]]
    qp,qc=ask_endpoint(a.qwen_url,a.qwen_model,key,t)
    x["qwen"]=qp; x["qwen_conf"]=qc; x["qwen_ok"]=(qp==x["exp"])
    if (i+1)%a.checkpoint_every==0:
        save(); print(f"  {i+1}/{len(todo)} (qwen ok {sum(1 for y in items if y.get('qwen_ok'))})",flush=True)
save()
n=sum(1 for x in items if "qwen_ok" in x)
print(f"done: qwen column on {n}/{len(items)} items -> {a.items}",flush=True)
