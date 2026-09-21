#!/usr/bin/env python3
"""Benchmark any Jev-compatible /v1/systemone endpoint on the labelled clipboard fixture: routing-join
precision AND probability calibration (ECE + recalibration gain). Works against verdictd or llamacpp-jev
(identical wire), so it is a head-to-head over the shared contract.

  python3 scripts/bench-endpoint.py <fixture.json> --url http://127.0.0.1:7311 --model verdict-fm --token-file <f>
  python3 scripts/bench-endpoint.py <fixture.json> --url http://127.0.0.1:8000 --model jev-latest        # llamacpp-jev

Calibration is computed only when the endpoint returns per-option probabilities (Laya, llamacpp-jev);
verdict-fm returns none and is scored on accuracy alone. The recalibration test (vault:
2026-09-20-predict-addict): fit one temperature on half the noul predictions, apply to the other half;
if ECE drops by more than a noise floor, the shipped probabilities were not calibrated.
"""
import json, math, os, sys, time, argparse, urllib.request

ap = argparse.ArgumentParser()
ap.add_argument("fixture")
ap.add_argument("--url", required=True)
ap.add_argument("--model", required=True)
ap.add_argument("--token-file")
ap.add_argument("--out")
ap.add_argument("--label", help="Row label for the table (default: model).")
args = ap.parse_args()

token = open(os.path.expanduser(args.token_file)).read().strip() if args.token_file else None
fx = json.load(open(os.path.expanduser(args.fixture)))
cases = fx["cases"]
QS = ["is_url", "is_contact", "is_code", "is_secret"]
JOIN_QS = ["is_url", "is_contact", "is_secret"]
INSTR = {
    "is_url": "Is the text a single web URL?",
    "is_contact": "Is the text a person's contact details (a card, email address, phone number, or postal address)?",
    "is_code": "Is the text source code, a shell command, or a config or JSON blob?",
    "is_secret": "Does the text contain a credential such as an API key, access token, password, or private key?",
}

def ask(state):
    body = json.dumps({"model": args.model, "state": state,
                       "questions": {q: {"type": "noul", "instructions": INSTR[q]} for q in QS}}).encode()
    req = urllib.request.Request(args.url.rstrip("/") + "/v1/systemone", data=body,
                                 headers={"Content-Type": "application/json", **({"Authorization": f"Bearer {token}"} if token else {})})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=180) as r:
        resp = json.load(r)
    return resp, (time.time() - t0) * 1000

# Collect answers, P(true), latencies.
per_q = {q: {"right": 0, "n": 0} for q in QS}
probs = []   # (p_true, truth_bool) over all noul answers with a probability
lat = []
tp = fp = fn = tn = 0
secret_leaks = 0
failures = 0
items = []
has_probs = False
for c in cases:
    try:
        resp, ms = ask(c["state"])
    except Exception as e:
        print("request failed:", e, file=sys.stderr); sys.exit(3)
    lat.append(ms)
    ans = {}
    for q in QS:
        a = resp.get("answers", {}).get(q)
        if a is None:
            failures += 1; ans[q] = None; continue
        p_true = a.get("noul")
        b = (p_true is not None and p_true >= 0.5) if p_true is not None else (a.get("choice") == "true")
        ans[q] = b
        per_q[q]["n"] += 1
        if b == c["truth"][q]: per_q[q]["right"] += 1
        # A real probability: any noul float whose kind is not the degenerate greedy "none" (verdict-fm).
        # Captures Laya (decoded), verdict-fm votes (agreement), and llamacpp-jev (no kind field, real logprobs).
        if p_true is not None and a.get("confidence_kind") != "none":
            has_probs = True
            probs.append((float(p_true), c["truth"][q]))
    if all(ans[q] is not None for q in JOIN_QS):
        surface = (ans["is_url"] or ans["is_contact"]) and not ans["is_secret"]
        truth = c["should_surface"]
        if surface and truth: tp += 1
        elif surface and not truth:
            fp += 1
            if c["truth"]["is_secret"]: secret_leaks += 1
        elif not surface and truth: fn += 1
        else: tn += 1
    items.append({"id": c["id"], "class": c["class"], "answers": ans})

def ece(pairs, bins=10):
    """Expected calibration error over predicted-class confidence vs empirical accuracy."""
    if not pairs: return None
    buckets = [[] for _ in range(bins)]
    for p_true, truth in pairs:
        pred = p_true >= 0.5
        conf = max(p_true, 1 - p_true)
        correct = (pred == truth)
        buckets[min(bins - 1, int(conf * bins))].append((conf, correct))
    n = len(pairs); e = 0.0
    for b in buckets:
        if not b: continue
        acc = sum(c for _, c in b) / len(b)
        cf = sum(cf for cf, _ in b) / len(b)
        e += (len(b) / n) * abs(acc - cf)
    return e

def temperature_scale(pairs, T):
    """Apply temperature T to P(true) via logit, return (p_true', truth) pairs."""
    out = []
    for p_true, truth in pairs:
        p = min(1 - 1e-6, max(1e-6, p_true))
        logit = math.log(p / (1 - p)) / T
        out.append((1 / (1 + math.exp(-logit)), truth))
    return out

def fit_temperature(pairs):
    """Grid-search T minimizing ECE on these pairs (coarse; enough to detect recalibration gain)."""
    best_T, best_e = 1.0, ece(pairs)
    for T in [0.25, 0.4, 0.5, 0.7, 0.85, 1.0, 1.25, 1.5, 2.0, 3.0, 5.0, 8.0]:
        e = ece(temperature_scale(pairs, T))
        if e is not None and (best_e is None or e < best_e): best_T, best_e = T, e
    return best_T, best_e

cal = None
if has_probs and len(probs) >= 20:
    # Split-half: fit T on the first half, measure ECE gain on the second half.
    mid = len(probs) // 2
    train, test = probs[:mid], probs[mid:]
    T, _ = fit_temperature(train)
    ece_before = ece(test)
    ece_after = ece(temperature_scale(test, T))
    cal = {"n": len(probs), "ece_raw": round(ece(probs), 4),
           "fitted_temperature": T, "ece_test_before": round(ece_before, 4), "ece_test_after": round(ece_after, 4),
           "recalibration_gain": round((ece_before or 0) - (ece_after or 0), 4)}

precision = tp / (tp + fp) if (tp + fp) else None
lat.sort()
summary = {
    "label": args.label or args.model, "url": args.url, "model": args.model, "items": len(cases),
    "per_question_accuracy": {q: round(per_q[q]["right"] / per_q[q]["n"], 3) if per_q[q]["n"] else None for q in QS},
    "surface_precision": round(precision, 3) if precision is not None else None,
    "surface_recall": round(tp / (tp + fn), 3) if (tp + fn) else None,
    "confusion": {"tp": tp, "fp": fp, "fn": fn, "tn": tn}, "secret_leaks": secret_leaks,
    "question_failures": failures, "has_probabilities": has_probs,
    "latency_p50_ms": lat[len(lat) // 2] if lat else None, "latency_p90_ms": lat[int(len(lat) * 0.9)] if lat else None,
    "calibration": cal,
}
print(json.dumps(summary, indent=1))
if args.out:
    json.dump({"summary": summary, "items": items}, open(args.out, "w"), indent=1)
    print("record:", args.out)
