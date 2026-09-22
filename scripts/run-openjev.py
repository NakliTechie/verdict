#!/usr/bin/env python3
"""Run verdict against a stratified sample of ZefanCai/Open-Jev (state + typed question + gold `target`
distribution). Scores accuracy (vs target argmax) and, when the backend returns probabilities,
calibration: ECE (confidence vs correctness) and Brier vs the gold distribution.

  python3 scripts/run-openjev.py <openjev-test.json> --model verdict-fm --token-file <f> [--per-source 25] [--out r.json]
"""
import json, os, sys, time, math, argparse, urllib.request, random
from collections import defaultdict, Counter
ap=argparse.ArgumentParser(); ap.add_argument("rows"); ap.add_argument("--model",default="verdict-fm")
ap.add_argument("--url",default="http://127.0.0.1:7311"); ap.add_argument("--token-file"); ap.add_argument("--out")
ap.add_argument("--per-source",type=int,default=25); ap.add_argument("--seed",type=int,default=7)
a=ap.parse_args(); tok=open(os.path.expanduser(a.token_file)).read().strip() if a.token_file else None
allrows=json.load(open(os.path.expanduser(a.rows))); rng=random.Random(a.seed)
bysrc=defaultdict(list)
for r in allrows: bysrc[r["source"]].append(r)
sample=[]
for src,rs in bysrc.items():
    rng.shuffle(rs); sample+=rs[:a.per_source]
rng.shuffle(sample)
print(f"sampled {len(sample)} of {len(allrows)} across {len(bysrc)} sources ({a.per_source}/source)",flush=True)

def parse_opts(kind,options):
    if kind=="noul": return None,["no","yes"]
    if kind=="score": return [str(o) for o in options],[str(i) for i in range(len(options))]
    crit={}; keys=[]
    for o in options:
        if ": " in o: k,d=o.split(": ",1)
        else: k,d=o,None
        crit[k]=d; keys.append(k)
    return crit,keys

def ask(state,kind,question,crit):
    wq={"type":kind,"instructions":question}
    if crit is not None: wq["criteria"]=crit
    body=json.dumps({"model":a.model,"state":state,"questions":{"q":wq}}).encode()
    req=urllib.request.Request(a.url.rstrip("/")+"/v1/systemone",data=body,headers={"Content-Type":"application/json",**({"Authorization":f"Bearer {tok}"} if tok else {})})
    t0=time.time()
    try:
        with urllib.request.urlopen(req,timeout=180) as r: resp=json.load(r)
        return resp,(time.time()-t0)*1000,None
    except Exception as e: return None,(time.time()-t0)*1000,type(e).__name__

correct=n=failed=0; lat=[]; cal=[]; brier=[]; items=[]; by_src=defaultdict(lambda:[0,0])
for i,r in enumerate(sample):
    kind=r["kind"]; crit,labels=parse_opts(kind,r["options"])
    state=r["state_json"]
    try: state=json.loads(state) if isinstance(state,str) and state.strip()[:1] in "[{\"" else state
    except: pass
    if not isinstance(state,str): state=json.dumps(state,ensure_ascii=False)
    tgt=r["target"]; exp_idx=max(range(len(tgt)),key=lambda j:tgt[j]); exp=labels[exp_idx]
    resp,ms,err=ask(state,kind,r["question"],crit); lat.append(ms)
    a_=resp.get("answers",{}).get("q") if resp else None
    if a_ is None:
        failed+=1; n+=1; by_src[r["source"]][1]+=1; items.append({"id":r["id"],"src":r["source"],"kind":kind,"fail":err or "no_answer"}); continue
    if kind=="choice": pred=a_.get("choice")
    elif kind=="noul": pred="yes" if a_.get("noul",0)>=0.5 else "no"
    else: pred=str(a_.get("level"))
    ok=(pred==exp); n+=1; correct+=ok; by_src[r["source"]][0]+=ok; by_src[r["source"]][1]+=1
    # calibration if probabilities present
    if a_.get("confidence_kind") not in (None,"none"):
        p=None
        if kind=="noul": pt=a_.get("noul"); p={"yes":pt,"no":1-pt} if pt is not None else None
        else:
            pr=a_.get("probabilities"); p={labels[j]:pr.get(labels[j],0.0) for j in range(len(labels))} if isinstance(pr,dict) else None
        if p:
            conf=max(p.values()); cal.append((conf,ok))
            gold={labels[j]:tgt[j] for j in range(len(labels))}
            brier.append(sum((p.get(l,0)-gold.get(l,0))**2 for l in labels))
    items.append({"id":r["id"],"src":r["source"],"kind":kind,"pred":pred,"exp":exp,"ok":bool(ok)})
    if (i+1)%25==0: print(f"  {i+1}/{len(sample)} acc {correct}/{n}",flush=True)

def ece(pairs,bins=10):
    if not pairs: return None
    b=[[] for _ in range(bins)]
    for c,ok in pairs: b[min(bins-1,int(c*bins))].append((c,ok))
    tot=len(pairs); e=0
    for bk in b:
        if not bk: continue
        acc=sum(o for _,o in bk)/len(bk); mc=sum(c for c,_ in bk)/len(bk); e+=len(bk)/tot*abs(acc-mc)
    return round(e,4)
lat.sort()
summary={"model":a.model,"n":n,"accuracy":round(correct/n,3),"failed":failed,
         "latency_p50_ms":lat[len(lat)//2] if lat else None,
         "calibration_n":len(cal),"ece":ece(cal),"brier_vs_gold":round(sum(brier)/len(brier),4) if brier else None,
         "by_source":{k:{"acc":round(v[0]/v[1],3),"n":v[1]} for k,v in sorted(by_src.items())}}
print(json.dumps(summary,indent=1))
if a.out: json.dump({"summary":summary,"items":items},open(a.out,"w"),indent=1); print("record:",a.out)
