#!/usr/bin/env python3
"""Honest train/test analysis of a hybrid items file (fm+laya, and qwen if backfilled). Fits every
router on a 50/50 TRAIN split and reports accuracy on the held-out TEST split. Decoupled from
collection so it re-runs in a second without re-querying any backend.

  python3 scripts/analyze-hybrid.py <items.json> [--seed 7]
"""
import json, os, sys, argparse, random
from collections import defaultdict, Counter
ap=argparse.ArgumentParser(); ap.add_argument("items"); ap.add_argument("--seed",type=int,default=7)
ap.add_argument("--out"); a=ap.parse_args()
items=json.load(open(os.path.expanduser(a.items)))
has_qwen=all("qwen_ok" in x for x in items) and len(items)>0
random.Random(a.seed).shuffle(items)
mid=len(items)//2; train,test=items[:mid],items[mid:]
def acc(rows,f): return round(sum(f(x) for x in rows)/len(rows),3) if rows else None
backends=["fm","laya"]+(["qwen"] if has_qwen else [])

# per-source router: best backend per source on train
src=defaultdict(lambda:defaultdict(int))
for x in train:
    for b in backends: src[x["src"]][b]+=x[b+"_ok"]
pick={s:max(backends,key=lambda b:v[b]) for s,v in src.items()}
def route_src(x): return x[pick.get(x["src"],"fm")+"_ok"]

# global best single backend on train (fallback / tie-break)
gbest=max(backends,key=lambda b:sum(x[b+"_ok"] for x in train))

# laya-conf gate between fm and laya
def fit_gate(conf_key,hi,lo):
    bt,ba=1.0,-1
    for t in [round(0.02*k,2) for k in range(1,51)]:
        at=acc(train,lambda x,t=t: x[hi+"_ok"] if (x.get(conf_key) or 0)>=t else x[lo+"_ok"])
        if at is not None and at>ba: ba,bt=at,t
    return bt
lt=fit_gate("laya_conf","laya","fm")
def route_laya_gate(x): return x["laya_ok"] if (x.get("laya_conf") or 0)>=lt else x["fm_ok"]

# majority vote across available backends, tie-break to global-best backend
def vote_ok(x):
    preds=[x[b] for b in backends if x.get(b) is not None]
    if not preds: return False
    c=Counter(preds); top=c.most_common(); best=top[0][1]
    tied=[p for p,n in top if n==best]
    pred=x.get(gbest) if len(tied)>1 else tied[0]
    return pred==x["exp"]

def oracle(x,bs): return any(x[b+"_ok"] for b in bs)
res={"n":len(items),"n_test":len(test),"has_qwen":has_qwen,
     "test":{**{b:acc(test,lambda x,b=b:x[b+"_ok"]) for b in backends},
             "majority_vote":acc(test,vote_ok),
             "router_per_source":acc(test,route_src),
             "router_laya_conf_gate":acc(test,route_laya_gate),
             "oracle_fm_laya":acc(test,lambda x:oracle(x,["fm","laya"]))},
     "fitted":{"laya_conf_threshold":lt,"global_best":gbest,"source_picks":pick}}
if has_qwen:
    qt=fit_gate("qwen_conf","qwen","fm")
    res["test"]["router_qwen_conf_gate"]=acc(test,lambda x: x["qwen_ok"] if (x.get("qwen_conf") or 0)>=qt else x["fm_ok"])
    res["test"]["oracle_all3"]=acc(test,lambda x:oracle(x,backends))
    res["fitted"]["qwen_conf_threshold"]=qt
print(json.dumps(res,indent=1))
if a.out: json.dump(res,open(os.path.expanduser(a.out),"w"),indent=1); print("record:",a.out)
