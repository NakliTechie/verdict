#!/usr/bin/env python3
"""Derive a narrow-decision fixture (noul + 3-way + 5-way choice, with ground truth) from the fm-bench
topic fixture. Truth = MOC membership, so every label is a real filing decision, not an annotation.

  python3 scripts/make-narrow-fixture.py ~/Code/knowledge/plan/fm-bench/fixture.json ~/Code/knowledge/plan/fm-bench/narrow.json

Output is the generic `cases` fixture `verdict replay` accepts:
  {"cases": [{"id", "state", "questions": {qid: <Jev question>}, "truth": {qid: <label>}}]}
Labels: choice → option key · noul → "true"/"false" · score → level index as a string.
"""
import json, random, sys

src, dst = sys.argv[1], sys.argv[2]
fx = json.load(open(src))
rng = random.Random(7)
titles = {t["slug"]: t["title"] for t in fx["topics"]}
slugs = sorted(titles)
cases = []
for it in fx["items"]:
    state = f"Title: {it['title']}\nSummary: {it['tldr']}"
    truth = it["truth"][0]
    others = [s for s in slugs if s not in it["truth"]]
    neg = rng.choice(others)
    for kind, topic, label in (("pos", truth, "true"), ("neg", neg, "false")):
        cases.append({"id": f"{it['slug']}::noul-{kind}", "state": state,
                      "questions": {"q": {"type": "noul", "instructions": f"Does this note belong under the topic \"{titles[topic]}\"?"}},
                      "truth": {"q": label}})
    for k in (3, 5):
        opts = [truth] + rng.sample(others, k - 1)
        rng.shuffle(opts)
        cases.append({"id": f"{it['slug']}::choice{k}", "state": state,
                      "questions": {"q": {"type": "choice", "instructions": "Which topic does this note belong under?",
                                          "criteria": {s: titles[s] for s in opts}}},
                      "truth": {"q": truth}})
json.dump({"source": src, "seed": 7, "cases": cases}, open(dst, "w"), indent=1, ensure_ascii=False)
from collections import Counter
print(len(cases), "cases:", dict(Counter(c["id"].split("::")[1].rstrip("-posneg").rstrip("-") for c in cases)))
