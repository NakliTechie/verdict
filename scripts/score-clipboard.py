#!/usr/bin/env python3
"""Run the labelled clipboard fixture through `verdictd watch` and score the routing join (SPEC §12.5, M4b).

  python3 scripts/score-clipboard.py <fixture.json> <model> [--out record.json] [--verdictd PATH] [--conf-threshold T]

Loads each item as a pending `clipboard` event, runs the four-noul topology once, then:
  - per-question accuracy vs ground truth
  - join precision/recall for `surface = (is_url OR is_contact) AND NOT is_secret`
  - secret-leak count (a secret item surfaced — the worst error, must be 0)
  - fallback rate: events with a failed question, plus (decoded backend) any answer below --conf-threshold
Gate: join precision >= 0.90 AND secret leaks == 0. Exit 0 pass / 1 fail / 3 indeterminate.
"""
import json, os, sqlite3, subprocess, sys, tempfile, time, argparse

ap = argparse.ArgumentParser()
ap.add_argument("fixture"); ap.add_argument("model")
ap.add_argument("--out"); ap.add_argument("--verdictd", default=".build/release/verdictd")
ap.add_argument("--conf-threshold", type=float, default=0.6)
ap.add_argument("--db", help="Use this db path (created) instead of a tempdir, so a run can be monitored.")
ap.add_argument("--score-only", action="store_true", help="Read decisions from --db without running verdictd (re-score a saved run).")
args = ap.parse_args()

fx = json.load(open(os.path.expanduser(args.fixture)))
cases = fx["cases"]
QS = ["is_url", "is_contact", "is_code", "is_secret"]
INSTR = {
    "is_url": "Is the text a single web URL?",
    "is_contact": "Is the text a person's contact details (a card, email address, phone number, or postal address)?",
    "is_code": "Is the text source code, a shell command, or a config or JSON blob?",
    "is_secret": "Does the text contain a credential such as an API key, access token, password, or private key?",
}

tmp = tempfile.mkdtemp(prefix="verdict-clip-")
db = args.db or os.path.join(tmp, "clip.sqlite")
if args.db and os.path.exists(db): os.remove(db)
topo = os.path.join(tmp, "topology.json")
json.dump({"version": 1, "types": {"clipboard": {"model": args.model,
           "questions": {q: {"type": "noul", "instructions": INSTR[q]} for q in QS}}}}, open(topo, "w"))

wall = 0.0
if not args.score_only:
    con = sqlite3.connect(db)
    con.executescript("CREATE TABLE events(id INTEGER PRIMARY KEY, type TEXT NOT NULL, state TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending', created_at TEXT, processed_at TEXT);")
    for i, c in enumerate(cases):
        con.execute("INSERT INTO events(id, type, state) VALUES(?,?,?)", (i + 1, "clipboard", c["state"]))
    con.commit(); con.close()
    t0 = time.time()
    proc = subprocess.run([args.verdictd, "watch", "--db", db, "--topology", topo, "--once"],
                          capture_output=True, text=True)
    wall = time.time() - t0
    if proc.returncode != 0:
        print("INDETERMINATE: verdictd watch exited", proc.returncode, proc.stderr.strip()[-300:], file=sys.stderr)
        sys.exit(3)

con = sqlite3.connect(db)
rows = {}
for eid, qid, ans, conf, kind, failed in con.execute(
        "SELECT event_id, question_id, answer, confidence, confidence_kind, failed FROM decisions"):
    rows.setdefault(eid, {})[qid] = {"answer": ans, "conf": conf, "kind": kind, "failed": failed}
n_done = con.execute("SELECT count(*) FROM events WHERE status='done'").fetchone()[0]
con.close()
if n_done == 0:
    print("INDETERMINATE: no events completed", file=sys.stderr); sys.exit(3)

JOIN_QS = ["is_url", "is_contact", "is_secret"]   # is_code is asked (diagnostic) but not used by this join
per_q = {q: {"right": 0, "n": 0} for q in QS}
tp = fp = fn = tn = 0
secret_leaks = []
fallback = 0
items = []
for i, c in enumerate(cases):
    eid = i + 1
    d = rows.get(eid, {})
    ans = {}
    for q in QS:
        r = d.get(q)
        if not r or r["failed"]:
            ans[q] = None
            continue
        b = (r["answer"] == "true")
        ans[q] = b
        per_q[q]["n"] += 1
        if b == c["truth"][q]:
            per_q[q]["right"] += 1
    # The join abstains (-> consumer fallback tier) when any question it depends on failed or, for a
    # decoded backend, its certainty is below threshold. `confidence` is certainty in [0,1], high = sure.
    routed_to_fallback = False
    for q in JOIN_QS:
        r = d.get(q)
        if not r or r["failed"]:
            routed_to_fallback = True
        elif r["kind"] == "decoded" and r["conf"] is not None and r["conf"] < args.conf_threshold:
            routed_to_fallback = True
    failed_any = any((not d.get(q)) or d[q]["failed"] for q in JOIN_QS)
    if routed_to_fallback:
        fallback += 1
    surface_pred = None
    if not failed_any:
        surface_pred = (ans["is_url"] or ans["is_contact"]) and not ans["is_secret"]
    truth_surface = c["should_surface"]
    # Confusion on auto-actable items only (fallback items are handed off, not auto-acted).
    if surface_pred is not None and not routed_to_fallback:
        if surface_pred and truth_surface: tp += 1
        elif surface_pred and not truth_surface:
            fp += 1
            if c["truth"]["is_secret"]: secret_leaks.append(c["id"])
        elif not surface_pred and truth_surface: fn += 1
        else: tn += 1
    items.append({"id": c["id"], "class": c["class"], "answers": ans,
                  "surface_pred": surface_pred, "should_surface": truth_surface, "fallback": routed_to_fallback})

precision = tp / (tp + fp) if (tp + fp) else None
recall = tp / (tp + fn) if (tp + fn) else None
summary = {
    "model": args.model, "items": len(cases), "completed": n_done, "wall_s": round(wall, 1),
    "per_question_accuracy": {q: round(per_q[q]["right"] / per_q[q]["n"], 3) if per_q[q]["n"] else None for q in QS},
    "join": fx["join"],
    "surface_precision": round(precision, 3) if precision is not None else None,
    "surface_recall": round(recall, 3) if recall is not None else None,
    "confusion": {"tp": tp, "fp": fp, "fn": fn, "tn": tn},
    "secret_leaks": secret_leaks, "fallback_rate": round(fallback / len(cases), 3),
    "conf_threshold": args.conf_threshold,
}
gate_pass = precision is not None and precision >= 0.90 and len(secret_leaks) == 0
summary["gate_passed"] = gate_pass
print(json.dumps(summary, indent=1))
if args.out:
    json.dump({"summary": summary, "items": items}, open(args.out, "w"), indent=1)
    print("record:", args.out)
sys.exit(0 if gate_pass else 1)
