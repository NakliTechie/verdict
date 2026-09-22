#!/usr/bin/env python3
"""Option-order sensitivity: run each JevBench public CHOICE task through verdict in two prompt orders
(verdict's default sorted-key order, and a forced-reversed order via key prefixes), compare accuracy + flips.
verdict sorts option keys, so it is input-order invariant; this probes sensitivity to the *presented* order.

  python3 scripts/jevbench-order-test.py <jevbench-repo> --model verdict-fm --token-file <f> [--out r.json]
"""
import json, os, sys, time, argparse, urllib.request
ap=argparse.ArgumentParser(); ap.add_argument("repo"); ap.add_argument("--model",default="verdict-fm")
ap.add_argument("--url",default="http://127.0.0.1:7311"); ap.add_argument("--token-file"); ap.add_argument("--out"); ap.add_argument("--limit",type=int)
a=ap.parse_args(); tok=open(os.path.expanduser(a.token_file)).read().strip() if a.token_file else None
tasks=[]
for f in ["easy","hard","original"]:
    for line in open(os.path.join(a.repo,"datasets/public",f+".jsonl")):
        t=json.loads(line)
        if t.get("expected") is not None and t["question"]["type"]=="choice": tasks.append(t)
if a.limit: tasks=tasks[:a.limit]

def ask(state,instructions,criteria):
    body=json.dumps({"model":a.model,"state":state,"questions":{"q":{"type":"choice","instructions":instructions,"criteria":criteria}}}).encode()
    req=urllib.request.Request(a.url.rstrip("/")+"/v1/systemone",data=body,headers={"Content-Type":"application/json",**({"Authorization":f"Bearer {tok}"} if tok else {})})
    with urllib.request.urlopen(req,timeout=180) as r: resp=json.load(r)
    ans=resp.get("answers",{}).get("q"); return ans.get("choice") if ans else None

def_correct=rev_correct=flips=n=0; items=[]
for i,t in enumerate(tasks):
    state=t["state"] if isinstance(t["state"],str) else json.dumps(t["state"]); crit=t["question"]["criteria"]; instr=t["question"]["instructions"]; exp=t["expected"]
    keys=sorted(crit.keys())
    # reversed presentation: prefix so sorted(newkeys) reverses the default order
    rev_map={f"{len(keys)-1-j:02d}__{k}":k for j,k in enumerate(keys)}   # newkey -> origkey
    rev_crit={nk:crit[ok] for nk,ok in rev_map.items()}
    try:
        d=ask(state,instr,crit)                       # default (sorted) order
        rraw=ask(state,instr,rev_crit)                # reversed order
    except Exception as e:
        print("skip",t["id"],type(e).__name__,file=sys.stderr); continue
    r=rev_map.get(rraw) if rraw else None             # strip prefix back to original key
    dc=(d==exp); rc=(r==exp); n+=1; def_correct+=dc; rev_correct+=rc
    if dc!=rc: flips+=1
    items.append({"id":t["id"],"tier":t.get("split"),"expected":exp,"default":d,"reversed":r,"default_ok":dc,"reversed_ok":rc,"flipped":dc!=rc})
    if (i+1)%20==0: print(f"  {i+1}/{len(tasks)} def {def_correct} rev {rev_correct} flips {flips}",flush=True)
summary={"model":a.model,"choice_tasks":n,"accuracy_default":round(def_correct/n,3),"accuracy_reversed":round(rev_correct/n,3),
         "flips":flips,"flip_rate":round(flips/n,3),"agree":round((n-flips)/n,3)}
print(json.dumps(summary,indent=1))
if a.out: json.dump({"summary":summary,"items":items},open(a.out,"w"),indent=1); print("record:",a.out)
