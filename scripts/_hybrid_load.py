"""Shared task loaders + a Jev-wire endpoint caller, factored out of hybrid-experiment.py so the
qwen-arm backfill and the analyzer reconstruct EXACTLY the same task set (matched by id). No argparse,
no global state: build_tasks(dataset, fmt) is pure and returns every row (no per-source truncation)."""
import json, os, time, urllib.request
from collections import defaultdict

def _load_openjev(path):
    rows=json.load(open(os.path.expanduser(path))); out=[]
    for r in rows:
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
    return out

def _load_jevbench(repo):
    out=[]
    for f in ["easy","hard","original"]:
        for line in open(os.path.join(repo,"datasets/public",f+".jsonl")):
            t=json.loads(line)
            if t.get("expected") is None: continue
            q=t["question"]; kind=q["type"]; exp=str(t["expected"]) if kind=="score" else t["expected"]
            st=t["state"] if isinstance(t["state"],str) else json.dumps(t["state"])
            out.append({"id":t["id"],"src":t["family"],"kind":kind,"state":st,"instructions":q["instructions"],"criteria":q.get("criteria"),"expected":exp})
    return out

def _load_typed(path):
    rows=json.load(open(os.path.expanduser(path))); out=[]
    for r in rows:
        qs=r["questions"] if isinstance(r["questions"],dict) else json.loads(r["questions"])
        gold=r["gold"] if isinstance(r["gold"],dict) else json.loads(r["gold"])
        st=r["state"]
        if not isinstance(st,str): st=json.dumps(st,ensure_ascii=False)
        for qid,q in qs.items():
            g=gold.get(qid) or {}; exp=g.get("label")
            if exp is None: continue
            if q["type"]=="noul":  # gold codes yes/no as true/false; harness predicts yes/no
                exp={"true":"yes","false":"no","1":"yes","0":"no"}.get(str(exp).lower(),str(exp))
            out.append({"id":f"{r['id']}#{qid}","src":r.get("workflow","typed"),"kind":q["type"],
                        "state":st,"instructions":q["instructions"],"criteria":q.get("criteria"),"expected":str(exp)})
    return out

def build_tasks(dataset, fmt):
    return {"openjev":_load_openjev,"jevbench":_load_jevbench,"typed_decisions":_load_typed}[fmt](dataset)

def ask_endpoint(url, model, key, task, timeout=180):
    """Returns (pred, conf) from a Jev /v1/systemone endpoint. pred normalised to the same label space
    hybrid-experiment uses; conf is decoded certainty (llamacpp-jev returns per-option probs)."""
    wq={"type":task["kind"],"instructions":task["instructions"]}
    if task["criteria"] is not None: wq["criteria"]=task["criteria"]
    body=json.dumps({"model":model,"state":task["state"],"questions":{"q":wq}}).encode()
    hdr={"Content-Type":"application/json",**({"Authorization":f"Bearer {key}"} if key else {})}
    req=urllib.request.Request(url.rstrip("/")+"/v1/systemone",data=body,headers=hdr)
    try:
        with urllib.request.urlopen(req,timeout=timeout) as r: resp=json.load(r)
    except Exception: return None,None
    an=resp.get("answers",{}).get("q")
    if not an: return None,None
    k=task["kind"]
    pred=an.get("choice") if k=="choice" else ("yes" if an.get("noul",0)>=0.5 else "no") if k=="noul" else str(an.get("level"))
    conf=an.get("confidence")
    if conf is None and an.get("noul") is not None: conf=max(an["noul"],1-an["noul"])
    return pred,conf
