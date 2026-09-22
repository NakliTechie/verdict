#!/usr/bin/env python3
"""Hybrid backend router experiment. For each task, call BOTH verdict-fm and verdict-laya, record
each answer + laya's decoded confidence + the gold, then evaluate routing strategies that use ONLY
information available at inference (no source label): laya-confidence gating and agreement.

  python3 scripts/hybrid-experiment.py <dataset> --format openjev|jevbench --token-file <f> [--per-source N] [--limit N] --out r.json
"""
import json, os, sys, time, argparse, urllib.request, random
from collections import defaultdict
ap=argparse.ArgumentParser(); ap.add_argument("dataset"); ap.add_argument("--format",choices=["openjev","jevbench","typed_decisions"],required=True)
ap.add_argument("--url",default="http://127.0.0.1:7311"); ap.add_argument("--token-file"); ap.add_argument("--out")
ap.add_argument("--per-source",type=int,default=None); ap.add_argument("--limit",type=int); ap.add_argument("--seed",type=int,default=7)
ap.add_argument("--checkpoint-every",type=int,default=25)
a=ap.parse_args(); tok=open(os.path.expanduser(a.token_file)).read().strip() if a.token_file else None
rng=random.Random(a.seed)

def load_openjev(path):
    rows=json.load(open(os.path.expanduser(path))); bysrc=defaultdict(list)
    for r in rows: bysrc[r["source"]].append(r)
    out=[]
    for src,rs in bysrc.items():
        rng.shuffle(rs)
        for r in (rs if a.per_source is None else rs[:a.per_source]):
            kind=r["kind"]; opts=r["options"]; tgt=r["target"]
            if kind=="noul": crit=None; labels=["no","yes"]
            elif kind=="score": crit=[str(o) for o in opts]; labels=[str(i) for i in range(len(opts))]
            else:
                crit={}; labels=[]
                for o in opts:
                    k,d=(o.split(": ",1)+[None])[:2] if ": " in o else (o,None); crit[k]=d; labels.append(k)
            st=r["state_json"]
            try: st=json.loads(st) if isinstance(st,str) and st.strip()[:1] in "[{\"" else st
            except: pass
            if not isinstance(st,str): st=json.dumps(st,ensure_ascii=False)
            exp=labels[max(range(len(tgt)),key=lambda j:tgt[j])]
            out.append({"id":r["id"],"src":r["source"],"kind":kind,"state":st,"instructions":r["question"],"criteria":crit,"expected":exp})
    rng.shuffle(out); return out

def load_jevbench(repo):
    out=[]
    for f in ["easy","hard","original"]:
        for line in open(os.path.join(repo,"datasets/public",f+".jsonl")):
            t=json.loads(line)
            if t.get("expected") is None: continue
            q=t["question"]; kind=q["type"]; exp=str(t["expected"]) if kind=="score" else t["expected"]
            st=t["state"] if isinstance(t["state"],str) else json.dumps(t["state"])
            out.append({"id":t["id"],"src":t["family"],"kind":kind,"state":st,"instructions":q["instructions"],"criteria":q.get("criteria"),"expected":exp})
    return out

def load_typed(path):
    rows=json.load(open(os.path.expanduser(path))); out=[]
    for r in rows:
        qs=r["questions"] if isinstance(r["questions"],dict) else json.loads(r["questions"])
        gold=r["gold"] if isinstance(r["gold"],dict) else json.loads(r["gold"])
        st=r["state"]
        if not isinstance(st,str): st=json.dumps(st,ensure_ascii=False)
        for qid,q in qs.items():
            g=gold.get(qid) or {}; exp=g.get("label")
            if exp is None: continue
            out.append({"id":f"{r['id']}#{qid}","src":r.get("workflow","typed"),"kind":q["type"],
                        "state":st,"instructions":q["instructions"],"criteria":q.get("criteria"),"expected":str(exp)})
    return out
tasks={"openjev":load_openjev,"jevbench":load_jevbench,"typed_decisions":load_typed}[a.format](a.dataset)
if a.limit: tasks=tasks[:a.limit]
print(f"{len(tasks)} tasks",flush=True)

def ask(model,t):
    wq={"type":t["kind"],"instructions":t["instructions"]}
    if t["criteria"] is not None: wq["criteria"]=t["criteria"]
    body=json.dumps({"model":model,"state":t["state"],"questions":{"q":wq}}).encode()
    req=urllib.request.Request(a.url.rstrip("/")+"/v1/systemone",data=body,headers={"Content-Type":"application/json",**({"Authorization":f"Bearer {tok}"} if tok else {})})
    try:
        with urllib.request.urlopen(req,timeout=180) as r: resp=json.load(r)
    except Exception: return None,None
    an=resp.get("answers",{}).get("q")
    if not an: return None,None
    k=t["kind"]
    pred=an.get("choice") if k=="choice" else ("yes" if an.get("noul",0)>=0.5 else "no") if k=="noul" else str(an.get("level"))
    conf=an.get("confidence")   # laya: decoded certainty; fm: None
    if conf is None and an.get("noul") is not None: conf=max(an["noul"],1-an["noul"])
    return pred,conf

items=[]; done=set()
if a.out and os.path.exists(os.path.expanduser(a.out)):
    try:
        items=json.load(open(os.path.expanduser(a.out))); done={x["id"] for x in items}
        print(f"resuming: {len(done)} already done",flush=True)
    except Exception: items=[]
def flush():
    if a.out: json.dump(items,open(os.path.expanduser(a.out),"w"))
todo=[t for t in tasks if t["id"] not in done]
print(f"{len(todo)} to do (of {len(tasks)})",flush=True)
for i,t in enumerate(todo):
    fp,_=ask("verdict-fm",t); lp,lc=ask("verdict-laya",t)
    items.append({"id":t["id"],"src":t["src"],"exp":t["expected"],"fm":fp,"laya":lp,"laya_conf":lc,
                  "fm_ok":fp==t["expected"],"laya_ok":lp==t["expected"]})
    if (i+1)%a.checkpoint_every==0: flush(); print(f"  {len(done)+i+1}/{len(tasks)} (acc fm {sum(x['fm_ok'] for x in items)}/{len(items)})",flush=True)
flush()
# Honest eval: fit the router (per-source choice + conf-gate threshold) on TRAIN, report on TEST.
rng.shuffle(items); mid=len(items)//2; train,test=items[:mid],items[mid:]
def acc(rows,f): return round(sum(f(x) for x in rows)/len(rows),3) if rows else None
# per-source router fit on train
src=defaultdict(lambda:[0,0]); 
for x in train: src[x["src"]][0]+=x["fm_ok"]; src[x["src"]][1]+=x["laya_ok"]
pick={s:("fm" if v[0]>=v[1] else "laya") for s,v in src.items()}
def route_src(x): return x["fm_ok"] if pick.get(x["src"],"fm")=="fm" else x["laya_ok"]
# conf-gate threshold fit on train
bt,ba=1.0,0
for t in [round(0.02*k,2) for k in range(1,50)]:
    at=acc(train,lambda x,t=t: x["laya_ok"] if (x["laya_conf"] or 0)>=t else x["fm_ok"])
    if at is not None and at>ba: ba,bt=at,t
def route_conf(x): return x["laya_ok"] if (x["laya_conf"] or 0)>=bt else x["fm_ok"]
out={"n":len(items),"n_test":len(test),
     "test":{"fm":acc(test,lambda x:x["fm_ok"]),"laya":acc(test,lambda x:x["laya_ok"]),
             "agree_else_fm":acc(test,lambda x: x["fm_ok"] if x["fm"]==x["laya"] else x["fm_ok"]),
             "router_per_source":acc(test,route_src),
             "router_conf_gate":acc(test,route_conf),
             "oracle":acc(test,lambda x: x["fm_ok"] or x["laya_ok"])},
     "fitted":{"conf_threshold":bt,"source_picks":pick}}
print(json.dumps(out,indent=1))
if a.out: print("record:",a.out)
