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

## Results — clipboard routing join (71 items)

| engine | join precision | recall | secret leaks | P50 / decision | per-question acc (url / contact / code / secret) | probabilities | raw ECE | ECE after temperature | recalibration gain |
|---|---|---|---|---|---|---|---|---|---|
| **verdict-fm** (Apple Foundation Models) | **1.00** | 0.84 | 0 | 966 ms | **0.90 / 0.97 / 0.90 / 0.97** | none | — | — | — |
| verdict-laya (Laya Core ML, CPU) | 0.95 | 0.63 | 0 | 797 ms | 0.79 / 0.87 / 0.68 / 0.89 | decoded (logits) | 0.081 | 0.084 | 0.04 |
| llamacpp-jev (Qwen3.5-2B, Metal) | **1.00** | 0.78 | 0 | **302 ms** | 0.89 / 0.89 / 0.63 / 0.96 | decoded (logprobs) | 0.188 | 0.049 | **0.157** |

Records: `evidence/compare-2026-09-22-clipboard-*.json`.

## What it says

1. **The routing join is robust across engines.** All three reach ~1.0 join precision with zero secret
   leaks, because the join reads *answers*, and every engine gets the routing-critical answers
   (is_url / is_contact / is_secret) mostly right. Decision quality, not engine, is what carries it.
2. **verdict-fm has the best per-question answers** (0.90–0.97), edging the 2B Jev-mechanism model and
   Laya. Apple's guided generation answers a typed question at least as accurately as a purpose-built
   2B typed-decision model here.
3. **llamacpp-jev is the fastest** at 302 ms, ~3× quicker than verdict-fm, from its one-token-branch
   design on a small model. That speed is a real Jev-mechanism advantage.
4. **Real probabilities carry the field's calibration tax, and we reproduced it locally.**
   llamacpp-jev's raw logprob probabilities are badly overconfident (ECE 0.19); a single temperature
   T=0.25 removes 76% of the error (0.206 → 0.049 on held-out) — almost exactly the "recalibration
   removes three-quarters of the error" that `predict_addict` found on hosted Jev over 16,500 tabular
   predictions. Laya's decoded confidence is better-calibrated raw (ECE 0.08) but gains little from
   recalibration. verdict-fm has no probability to miscalibrate.

## Can we say verdict-fm is better than Jev?

Not against **hosted Jev** — we have never run it (it needs a TypeSafe API key), and "better" needs one
metric on one shared testbed. Against a **faithful local Jev-mechanism engine** (Qwen3.5-2B, genuine
logprobs, the same wire), on this routing task, verdict-fm **matches join precision, beats per-question
accuracy, and avoids the overconfidence that recalibration exposes** — at the cost of being ~3× slower
and offering no probability at all. If a consumer needs a probability to threshold on, none of the three
gives a calibrated one raw; a temperature-scaled llamacpp-jev gets closest. For a routing or filing
*decision*, verdict-fm is the pick.

Sovereignty is the one axis where verdict beats hosted Jev outright and by construction: on-device, no
key, no egress.

## Limits of this comparison

- One task (clipboard routing), 71 items — the signal is clear but a wider fixture (~200) would tighten
  the interval.
- Qwen3.5-2B is not hosted Jev; it is a small open model in the Jev *mechanism*. A larger model would
  likely raise per-question accuracy and may change the calibration picture.
- `is_code` is the weak question for every engine (~0.63–0.90): JSON and config blobs overlap the other
  classes. It does not feed the join, so it does not move precision.
- Single machine, single OS build.

## Not yet run (the roadmap)

- **Hosted Jev** — needs a TypeSafe API key (a human step; the harness already speaks its wire).
- **Wide (26-way) and narrow (160-case) fixtures** through this same harness, for a fuller matrix.
- **verdict-fm with votes ≥ 3** — does agreement-as-confidence calibrate better than logprobs?
- **Other fully-local Jev alternatives** — Decider-2b, Reflex-4b (downloadable GGUF), the tier verdict
  actually competes in.
- **Energy per decision** — the axis laya-coreml's own benchmarks emphasise.
