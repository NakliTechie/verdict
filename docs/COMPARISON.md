# verdict vs the typed-decision field

How verdict's backends stack up against a faithful Jev-*mechanism* engine and against each other, on
verdict's own tasks. This is the evidence behind "use `verdict-fm`" and the honest boundary on any
"better than Jev" claim.

## Method

One harness, `scripts/bench-endpoint.py`, drives any Jev-compatible `POST /v1/systemone` endpoint over
the identical wire, so the comparison is apples-to-apples: every engine answers the same 71 labelled
clipboard items (`scripts/clipboard-fixture.json`), routes them with the same join
`surface = (is_url OR is_contact) AND NOT is_secret`, and is scored the same way. No engine abstains
here — precision is measured on acting on every item — so the numbers differ from `score-clipboard.py`,
which routes low-confidence items to a fallback tier. Calibration uses the test from the field's own
critique (`predict_addict`, 2026-09-20): fit one temperature on half the noul predictions, apply it to
the other half; if ECE drops by more than the noise floor, the shipped probabilities were not calibrated.

Run 2026-09-22, M4 Pro, macOS 26.5.2. `verdict-fm` on the Neural Engine, `verdict-laya` on the CPU,
`llamacpp-jev` on Metal (Qwen3.5-2B-Q8_0, text-only).

## Results — clipboard routing join (204 items, 2026-09-22)

Larger pool (`scripts/clipboard-fixture-200.json`, 204 items, 100 should-surface). Latency is
approximate — some runs overlapped on the machine. The decision-quality columns are the headline.

| engine | join precision | recall | secret leaks | P50 / decision | per-question acc (url / contact / code / secret) | probabilities | recalibration gain |
|---|---|---|---|---|---|---|---|
| **verdict-fm** (Apple FM, on-device) | **0.988** | 0.83 | **1** | 906 ms | 0.90 / 0.97 / 0.91 / 0.94 | none | — |
| verdict-laya (Laya Core ML, CPU) | 0.94 | 0.63 | **0** | 728 ms | 0.84 / 0.85 / 0.78 / 0.89 | decoded | 0.05 |
| llamacpp-jev Qwen3.5-2B (Metal) | 0.94 | 0.78 | 2 | **296 ms** | 0.90 / 0.90 / 0.71 / 0.95 | logprobs | 0.17 |
| llamacpp-jev Qwen3.5-4B (Metal) | 0.978 | **0.87** | 2 | 677 ms | 0.94 / 0.98 / 0.90 / 0.89 | logprobs | **0.00** |

Records: `evidence/compare-2026-09-22-clip204-*.json`. (A first pass on 71 items had verdict-fm and
llamacpp-jev-2B both at 1.00 precision with 0 leaks; the larger pool is the trustworthy read and shows
neither is perfect.)

## What it says

1. **verdict-fm leads on precision and leaks, but does not dominate.** It has the highest join precision
   (0.988) and the fewest secret leaks (1), and the best is_contact/is_code answers. But a 4B local
   Jev-mechanism model is right behind (0.978) with **higher recall** (0.87 vs 0.83) and better is_url.
2. **The calibration problem is a small-model effect, not inherent to the Jev mechanism.** Qwen3.5-2B's
   logprob probabilities are badly overconfident (a temperature removes 17 points of ECE); Qwen3.5-4B's
   are **already calibrated** (recalibration gain 0.00). So "Jev-style probabilities are miscalibrated"
   holds for small models and dissolves by 4B — an honest correction to the 71-item first pass and to a
   blanket reading of the field's calibration critique.
3. **Speed still favours the small Jev model** (296 ms, 3× verdict-fm), with the 4B in between (677 ms).
4. **No engine gates secrets perfectly.** verdict-fm leaked 1 (a reset URL with a `?sig=` token it read
   as a plain URL), the Jev models 2 each; only Laya leaked 0, bought with the worst recall (0.63). A
   consumer that must never surface a secret needs defense in depth (e.g. a regex for token-shaped query
   params), not the model alone.

## Can we say verdict-fm is better than Jev — or "better than the rest"?

No to both, and the larger pool is why we can say that with confidence rather than by caution:

- Against **hosted Jev** — never run (needs a TypeSafe key); no shared testbed yet.
- Against **"the rest"** — refuted here: a 4B local Jev-mechanism model matches verdict-fm on decision
  quality (0.978 vs 0.988 precision), **beats it on recall**, and adds **calibrated probabilities**
  verdict-fm does not have. And on the separate 26-way topic-routing task, plain BM25 beats verdict-fm
  (33/40 vs 28/40). "Better than the rest" is a leaderboard claim the evidence does not support.
- What the evidence **does** support: verdict-fm is **among the best local engines on decision quality**,
  edging precision and secret-leaks; it is **uniquely sovereign** — it is the OS model, so there is no
  separate multi-GB download, no model server, no second process to run or update; and it is **honest
  about confidence** (it reports `none` rather than a miscalibrated number). Those three — accurate
  enough, zero-install sovereign, honest — are the claim, not a leaderboard win.

## Limits of this comparison

- One task (clipboard routing), 71 items — the signal is clear but a wider fixture (~200) would tighten
  the interval.
- Qwen3.5-2B is not hosted Jev; it is a small open model in the Jev *mechanism*. A larger model would
  likely raise per-question accuracy and may change the calibration picture.
- `is_code` is the weak question for every engine (~0.63–0.90): JSON and config blobs overlap the other
  classes. It does not feed the join, so it does not move precision.
- Single machine, single OS build.

## External benchmark: JevBench

[JevBench](https://github.com/fstandhartinger/jevbench) (Benchmark Heaven, MIT) scores Jev-class
decision models on **Intelligence, Calibration, Speed, Cost** (geometric mean). Its task format is
identical to verdict's wire, so verdict runs through JevBench's own harness with a small adapter
(`scripts/jevbench/verdict_nt.py`). Run 2026-09-22 on the **231 public tasks** (109 hard held out, so
this is not the official board number) through their CLI and scoring:

| backend | accuracy | calibration (ECE) | latency P50 / P95 | cost / 1k decisions | probabilities |
|---|---|---|---|---|---|
| **verdict-fm** | **0.619** (143/231) | — (label-only → 0) | 0.30 s / 2.58 s | **$0.00** | none |
| verdict-laya | 0.541 (125/231) | **0.073** (well-calibrated) | 0.34 s / 3.64 s | **$0.00** | decoded |

By tier (verdict-fm): easy 100%, original 75%, hard 37%. Strong on the typed-routing families verdict
is built for (extraction, fact, intent, tool_selection, policy: 0.79–1.00), weak on multi-step reasoning
(trap, ambiguous, multi_hop, temporal_numeric: 0.00–0.20). Records:
`evidence/jevbench-2026-09-22-faithful-verdict-{fm,laya}.json`.

What this shows, honestly:
- **verdict-fm answers more accurately (0.62 vs 0.54) but cannot post a composite JevBench Score.** It is
  label-only, so Calibration is 0, and the score is a geometric mean — a 0 on any axis zeroes it. The
  benchmark rewards calibrated probabilities, which the stock Foundation Model does not expose.
- **verdict-laya is the backend that plays all four axes.** Lower accuracy, but a genuinely calibrated
  distribution (ECE 0.073; its reliability bins are monotonic — 0.26 confidence → 0.20 accuracy, 0.84 →
  0.96), full schema validity, and the same $0 on-device cost. This is exactly why Laya is kept: it is
  what lets verdict compete on a calibration-weighted board at all. (It reads a right-truncated state on
  the 3,700-token hard tasks — its 1,024-token context — which caps its hard-tier accuracy.)
- **Both cost $0 per 1,000 decisions** (on-device) and run at ~0.3 s median — the Cost and Speed axes are
  verdict's to win; Intelligence on the hard reasoning tier is not.
- Reproduce or upstream: `scripts/jevbench/` (adapter + guide). Independent cross-check: JevBench's #2
  system is SemIf = Qwen3.5-4B, the same class our own head-to-head found competitive with the Jev mechanism.

## External benchmark: Open-Jev + typed-decisions — the full 3-backend run

[ZefanCai/Open-Jev](https://huggingface.co/datasets/ZefanCai/Open-Jev) is a large typed-decision set
(state + choice/score/noul + a gold `target`), spanning business workflows and games. Run 2026-09-22 on
the **entire set** (10,356 decisions) plus the **LocalLLaMA/typed-decisions** test split (2,000
decisions) — every item through **all three backends**: verdict-fm, verdict-laya, and llamacpp-jev
Qwen3.5-4B. Routers are fit on a 50/50 train split and scored on the held-out test half
(`scripts/hybrid-experiment.py` + `scripts/analyze-hybrid.py`; records
`evidence/hybrid-3way-2026-09-22-{openjev,typed_decisions}.json`).

**Correction to an earlier sample.** A 224-item stratified sample (20/source) previously reported a
per-source router lifting accuracy +12 points (0.54 → 0.66, "the real score lever"). The full
10,356-item run with a proper held-out split **does not reproduce that**: the real per-domain gain is
**+2.7 points on Open-Jev and ~0 on typed-decisions**. The +12 was a small-sample, no-held-out
artifact. The full run below is the trustworthy read. (Also fixed in this run: the typed-decisions set
codes noul gold as true/false while the wire predicts yes/no — scoring it raw deflated every backend;
`scripts/rescore-typed.py` normalizes it.)

Held-out accuracy — Open-Jev (n_test = 5,178) and typed-decisions (n_test = 1,000):

| strategy | Open-Jev | typed-dec | realizable? |
|---|---|---|---|
| verdict-fm | 0.439 | 0.507 | single · zero-install |
| **verdict-laya** | **0.574** | **0.757** | single · 843 MB |
| Qwen3.5-4B | 0.481 | 0.375 | single · 4B download |
| majority vote (3) | 0.592 | 0.714 | automatic |
| **per-domain router** | **0.601** | **0.757** | needs domain label |
| laya-conf gate | 0.488 | 0.741 | automatic |
| qwen-conf gate | 0.514 | 0.507 | automatic |
| oracle (best of 3) | 0.837 | 0.887 | ceiling |

**What it says, honestly:**

1. **Laya is the strongest single backend on both** (0.574 / 0.757). It is the typed-decision-trained
   specialist and these sets are its home distribution; verdict-fm answers them zero-shot. Read this as
   in-distribution advantage, not verdict-fm being weak — on the clipboard content-sensing join above,
   fm leads (0.988).
2. **No automatic router robustly beats Laya.** Majority vote *wins* on Open-Jev (+1.8) but *loses* on
   typed-decisions (−4.3), dragged down by Qwen's 0.375 there — a vote inherits its weakest competitive
   member. Both confidence gates lose on both sets. Confidence is not the routing signal; agreement only
   helps when every arm is competitive.
3. **Only per-domain routing is robust** — never worse than the best single backend (it can fall back to
   Laya per domain), +2.7 on Open-Jev, tie on typed. It needs the caller's domain label, which verdict
   already carries: the request `model` field and the dataflow `topology.json` (model per event type).
4. **The complementarity is real but concentrated** — each backend owns a distinct pocket, and Laya owns
   most of the volume:

| backend | owns (domain) | example margin |
|---|---|---|
| verdict-fm | spatial game states + content-sensing¹ | tile_platformer 0.89 vs laya 0.20 |
| verdict-laya | 12 of 16 domains — workflows, policy-gating, painting, agent traces | security_incidents 0.73 vs fm 0.08 |
| Qwen3.5-4B | customer_service workflow | 0.90 vs laya 0.71 |

¹ content-sensing (is_url / is_secret) is verdict-fm's turf from the clipboard join (precision 0.988);
it is **not** in Open-Jev, so a router fit on this set alone under-uses fm — combine both task families.

**The lever, restated:** the payoff is a **deterministic per-domain routing table the caller opts
into**, not an automatic hybrid backend. An automatic 3-way vote would regress on typed-decisions and
cost 3× compute plus two model downloads for a data-dependent, sometimes-negative delta. verdict's
multi-backend design already delivers the robust lever for free — pick the backend by task family.

**Option order is not a lever** (`scripts/jevbench-order-test.py`): verdict sorts option keys, so it is
input-order invariant, and reversing the *presented* order left verdict-fm's accuracy unchanged (0.619 →
0.612 over 139 JevBench choice tasks; 16.5% of tasks flip individually but cancel). Unlike the small
models JevBench flagged (72% → 21% on reversal), verdict has no systematic order bias to exploit or fix.

## Not yet run (the roadmap)

- **Hosted Jev** — needs a TypeSafe API key (a human step; the harness already speaks its wire).
- **Wide (26-way) and narrow (160-case) fixtures** through this same harness, for a fuller matrix.
- **verdict-fm with votes ≥ 3** — does agreement-as-confidence calibrate better than logprobs?
- **Other fully-local Jev alternatives** — Decider-2b, Reflex-4b (downloadable GGUF), the tier verdict
  actually competes in.
- **Energy per decision** — the axis laya-coreml's own benchmarks emphasise.
- **Faithful JevBench composite** — a proper adapter through their MIT harness so verdict-fm and verdict-laya get real Intelligence/Calibration/Speed/Cost rows, plus a verdict-laya accuracy run.
