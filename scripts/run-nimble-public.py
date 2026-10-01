#!/usr/bin/env python3
"""Run any Jev-wire /v1/systemone endpoint on Bespoke's 13-subset public human-labelled suite (3,880
decisions; github.com/bespokelabsai/nimble, docs/PUBLIC_BENCHMARKS.md) — the benchmark Ollama quotes
for nimble / tev1. Requests and scoring are Bespoke's own code, imported from a pinned Nimble checkout:
`request_payload` builds the body, `validate_teacher` + `jev_row` score a probability-bearing answer
exactly as Bespoke scored hosted Jev, and an invalid or failed response is an error row counted wrong.

Three adaptations for verdict, all recorded per row: a label-only answer (verdict-fm, `confidence_kind:
"none"`) is scored on accuracy alone (prediction = choice / noul > 0.5 / level) and excluded from ECE;
`--state-as-string` sends the state object as a JSON string with sorted keys, for verdictd builds before
ea748bb that decode only string state (later builds render an object state to that same text, SPEC.md
§3); and a response with no token counts gets zeros before validation, because
verdict reports none and that check is token accounting, not the decision.

  python3 scripts/run-nimble-public.py --nimble-repo <nimble> --url http://localhost:11434 --model nimble \
      --rows /tmp/nimble-public-nimble.jsonl --out evidence/<record>.json
  python3 scripts/run-nimble-public.py --nimble-repo <nimble> --url http://127.0.0.1:7311 --model verdict-fm \
      --token-file "~/Library/Application Support/verdict/token" --rows ... --out ...

Serial (one request in flight) so latency is per decision, not throughput. Resumes from --rows.
"""
import argparse, hashlib, json, math, os, sys, time, urllib.error, urllib.request
from pathlib import Path

SUBSETS = ["vitaminc-dev", "massive-en-US", "massive-de-DE", "boolq", "squad2", "paws", "multinli",
           "civil_comments", "aegis2", "helpsteer2", "summeval-relevance", "summeval-consistency", "pubmedqa"]

ap = argparse.ArgumentParser()
ap.add_argument("--nimble-repo", required=True)
ap.add_argument("--data-root", help="default: <nimble-repo>/data/public")
ap.add_argument("--url", required=True)
ap.add_argument("--model", required=True)
ap.add_argument("--token-file")
ap.add_argument("--rows", required=True, help="per-record JSONL (resumable)")
ap.add_argument("--out", required=True)
ap.add_argument("--subsets", nargs="*", default=SUBSETS)
ap.add_argument("--label")
ap.add_argument("--limit", type=int, help="first N records per subset (smoke test)")
ap.add_argument("--state-as-string", action="store_true",
                help="send `state` as a JSON string: verdictd decodes only string state (422 on an object), "
                     "so this mirrors scripts/jevbench/verdict_nt.py; Jev and Ollama take the object as-is")
args = ap.parse_args()

repo = Path(os.path.expanduser(args.nimble_repo)).resolve()
sys.path.insert(0, str(repo))
from nimble.datasets.dataset_io import validate_teacher                      # noqa: E402
from nimble.evaluation.evaluate_public import expected_calibration_error    # noqa: E402
from nimble.evaluation.evaluate_public_jev import (                          # noqa: E402
    base_row, error_row, jev_row, request_payload, validate_reference)

token = open(os.path.expanduser(args.token_file)).read().strip() if args.token_file else None
data_root = Path(os.path.expanduser(args.data_root)) if args.data_root else repo / "data" / "public"


def post(payload):
    req = urllib.request.Request(args.url.rstrip("/") + "/v1/systemone", data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json",
                                          **({"Authorization": f"Bearer {token}"} if token else {})})
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        raise ValueError(f"HTTP {e.code}: {e.read()[:200]!r}") from None


def label_only_row(row, response, elapsed):
    kind = row["input"]["questions"]["decision"]["type"]
    a = response["answers"]["decision"]
    pred = a["choice"] if kind == "choice" else (a["noul"] > 0.5) if kind == "noul" else a["level"]
    return {**base_row(row, elapsed), "student": {"prediction": pred, "correct": pred == row["reference"]["target"],
                                                  "label_only": True}}


def score(row):
    payload = request_payload(row, args.model)
    if args.state_as_string and not isinstance(payload["state"], str):
        payload = {**payload, "state": json.dumps(payload["state"], ensure_ascii=False, sort_keys=True)}
    t0 = time.perf_counter()
    try:
        response = post(payload)
        elapsed = time.perf_counter() - t0
        a = (response.get("answers") or {}).get("decision")
        if a is None:
            raise ValueError(f"no answer: {json.dumps(response.get('failures'))[:200]}")
        if a.get("confidence_kind") == "none":
            return label_only_row(row, response, elapsed)
        usage = response.get("usage") or {}
        shim = not all(type(usage.get(k)) is int for k in ("input_tokens", "output_tokens"))
        if shim:  # verdict reports no token counts (on-device); the validator's last check is token accounting only
            response = {**response, "usage": {**usage, "input_tokens": 0, "output_tokens": 0}}
        validate_teacher(row, response, args.model)
        out = jev_row(row, response, elapsed)
        if shim: out["usage_shimmed"] = True
        out.pop("raw_student", None)
        return out
    except (ValueError, KeyError, TypeError, OSError) as e:
        return error_row(row, f"{type(e).__name__}: {str(e)[:200]}", time.perf_counter() - t0)


# Load records; resume from rows already scored.
records, manifests = [], {}
for s in args.subsets:
    path = data_root / s / "all.jsonl"
    raw = path.read_bytes()
    manifests[s] = {"dataset_sha256": hashlib.sha256(raw).hexdigest()}
    lines = [line for line in raw.decode().split("\n") if line.strip()][:args.limit]
    for line in lines:
        r = json.loads(line); validate_reference(r); r["_subset"] = s; records.append(r)
rows_path = Path(os.path.expanduser(args.rows))
done = {}
if rows_path.exists():
    for line in rows_path.read_text().split("\n"):
        if line.strip():
            r = json.loads(line)
            if "error" not in r: done[(r["subset"], r["id"])] = r
pending = [r for r in records if (r["_subset"], r["id"]) not in done]
print(f"{len(records)} records, {len(done)} done, {len(pending)} to run -> {args.model} @ {args.url}", flush=True)
started = time.strftime("%Y-%m-%dT%H:%M:%S%z")
with rows_path.open("w") as fh:
    for r in done.values(): fh.write(json.dumps(r) + "\n")
    for i, r in enumerate(pending):
        out = {**score(r), "subset": r["_subset"]}
        done[(r["_subset"], r["id"])] = out
        fh.write(json.dumps(out) + "\n"); fh.flush()
        if (i + 1) % 100 == 0:
            print(f"  {i+1}/{len(pending)}", flush=True)

rows = [done[(r["_subset"], r["id"])] for r in records]


def temp_scale(probs, T):
    logits = {k: math.log(max(p, 1e-12)) / T for k, p in probs.items()}
    m = max(logits.values()); z = sum(math.exp(v - m) for v in logits.values())
    return {k: math.exp(v - m) / z for k, v in logits.items()}


def recalibration(prob_rows):
    """Split-half temperature test (as scripts/bench-endpoint.py): fit T on even rows, ECE gain on odd rows."""
    if len(prob_rows) < 40: return None
    def pairs(rs, T):
        out = []
        for r in rs:
            p = temp_scale(r["student"]["probabilities"], T); best = max(p, key=p.get)
            out.append((p[best], r["student"]["correct"]))
        return out
    train, test = prob_rows[0::2], prob_rows[1::2]
    grid = [0.25, 0.4, 0.5, 0.7, 0.85, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0, 5.0]
    T = min(grid, key=lambda t: expected_calibration_error(pairs(train, t)))
    before, after = expected_calibration_error(pairs(test, 1.0)), expected_calibration_error(pairs(test, T))
    return {"fitted_temperature": T, "ece_test_before": round(before, 4), "ece_test_after": round(after, 4),
            "recalibration_gain": round(before - after, 4)}


def pct(xs, q):
    xs = sorted(xs); return xs[min(len(xs) - 1, math.ceil(q * len(xs)) - 1)] if xs else None


def group(rs):
    prob = [r for r in rs if "error" not in r and "probabilities" in r["student"]]
    g = {"n": len(rs), "correct": sum(bool(r["student"]["correct"]) for r in rs),
         "errors": sum("error" in r for r in rs), "label_only": sum(bool(r["student"].get("label_only")) for r in rs),
         "usage_shimmed": sum(bool(r.get("usage_shimmed")) for r in rs)}
    g["accuracy"] = round(g["correct"] / g["n"], 4)
    if prob:
        g["ece10"] = round(expected_calibration_error((r["student"]["top_probability"], r["student"]["correct"])
                                                      for r in prob), 4)
        g["brier_mean"] = round(sum(r["student"]["multiclass_brier"] for r in prob) / len(prob), 4)
    lat = [r["elapsed_seconds"] for r in rs]
    g["latency_p50_s"], g["latency_p95_s"] = round(pct(lat, .5), 4), round(pct(lat, .95), 4)
    return g


by_subset = {s: {**group([r for r in rows if r["subset"] == s]), **manifests[s]} for s in args.subsets}
types = {}
for s in args.subsets:
    t = next(r["type"] for r in rows if r["subset"] == s); types.setdefault(t, []).append(s)
prob_rows = [r for r in rows if "error" not in r and "probabilities" in r["student"]]
summary = {
    "label": args.label or args.model, "model": args.model, "url": args.url, "started": started,
    "finished": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "nimble_repo_sha": os.environ.get("NIMBLE_SHA"),
    "subsets": len(args.subsets), "records": len(rows), "state_as_string": args.state_as_string,
    "macro_accuracy": round(sum(by_subset[s]["accuracy"] for s in args.subsets) / len(args.subsets), 4),
    "micro_accuracy": round(sum(bool(r["student"]["correct"]) for r in rows) / len(rows), 4),
    "macro_by_type": {t: round(sum(by_subset[s]["accuracy"] for s in ss) / len(ss), 4) for t, ss in types.items()},
    "overall": group(rows),
    "recalibration": recalibration(prob_rows),
    "by_subset": by_subset,
    "scoring": "Bespoke nimble evaluate_public_jev (request_payload, validate_teacher, jev_row); label-only "
               "answers scored on accuracy only; error rows count as incorrect; a response without token counts "
               "gets zero counts before validation (usage_shimmed), the only check relaxed",
}
print(json.dumps({k: v for k, v in summary.items() if k != "by_subset"}, indent=1))
items = [{"subset": r["subset"], "id": r["id"], "type": r["type"], "pred": r["student"].get("prediction"),
          "target": r["reference"]["target"], "correct": bool(r["student"]["correct"]),
          "top_p": r["student"].get("top_probability"), "s": round(r["elapsed_seconds"], 4),
          **({"error": r["error"]} if "error" in r else {})} for r in rows]
json.dump({"summary": summary, "items": items}, open(args.out, "w"), indent=1)
print("record:", args.out)
