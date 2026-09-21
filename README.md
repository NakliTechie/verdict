# verdict

> Tier: **Tool**. A reusable typed-decision service for the Mac: one Swift process, one loopback HTTP face, Jev-style `Choice` / `Score` / `Noul` over a shared state, fronting Apple Foundation Models and Laya (Core ML / MLX). Honest contract: **constrained choice + agreement confidence**, never "calibrated probabilities" unless the backend actually reads logits.

## Why
Every NakliTechie surface that wants a small, fast, on-device *decision* (rank these passages, pick this field, file under this topic, yes/no with a reason) currently re-solves the same problem: Inlay against Gemini Nano, Summon against its agent socket, the on-device capture app against Foundation Models directly. Needle showed the shape (extension → loopback server → decision model) with a cloud hop in the middle. `verdict` is that loopback server, sovereign, reusable, and explicit about what each backend can and cannot promise.

## What it is
- A **Swift package** (`VerdictCore`) exposing `decide(state:, questions:) -> [Decision]` where a question is `Choice(options)`, `Score(range)`, or `Noul(yes/no)`, and a `Decision` carries `answer`, `confidence`, and `confidenceKind` (`.decoded` | `.agreement` | `.none`).
- A **loopback HTTP face** (`verdictd`, `127.0.0.1` only, token-gated) speaking a Jev-compatible request shape so callers written against `POST /v1/systemone` work unchanged.
- **Backends**, selected per request or by policy:
  1. **Foundation Models** (macOS 26+): guided generation with `.anyOf` / `@Generable` → schema-valid answers, no logits. Confidence = sampling agreement (N runs, unanimity share), opt-in because it multiplies latency.
  2. **Laya via Core ML** (`mizorewww/laya-coreml`, Apache-2.0): in-process from Swift, Neural Engine, 4.98 ms P50 short decisions on M3 Max, real distributions → `confidenceKind = .decoded`.
  3. **Laya via MLX** (`mizorewww/laya-mlx`): Python sidecar, 7.4–13.4 ms P50; fallback when Core ML weights are unavailable.
- A **fixture replay** as the verifier: the 40-item vault-routing fixture from `~/Code/knowledge/plan/fm-bench/` plus a passage-ranking set, replayed per backend, reporting top-1 and latency.

## What it is not
- Not a Jev reproduction. Foundation Models exposes no per-candidate probabilities (verified against the macOS 26.5 SDK: `GenerationOptions` = sampling/temperature/maxTokens; `Response` = content only). Only the Laya backends produce decoded distributions.
- Not a cloud gateway. No network egress except a caller's own loopback call.
- Not a chat model. State + typed questions in, typed answers out.

## Consumers (day one)
- **Inlay** — semantic ⌘F Tier 1 (native-messaging host or `127.0.0.1` fetch) once the Nano Tier 0 spike reports (`~/Code/inlay/plan/semantic-find-research.md`).
- **Summon** — smart-paste field routing over the agent socket.
- **On-device capture app** — topic filing and link proposals (`~/Code/knowledge/notes/jcr-pattern-applications-smart-paste-and-on-device-capture.md`).

## Status (2026-09-21)
M0, M1 and M2 shipped. `verdictd` serves `POST /v1/systemone` on `127.0.0.1:7311` behind a bearer token; both day-one consumer shapes ran against it live (`scripts/smoke-summon.sh`, `scripts/smoke-inlay.mjs`), on both backends, HTTP 200 with schema-valid answers.

```bash
swift build -c release
.build/release/verdictd                 # loads Laya once (~2–3 s), prints the token file path
curl -s http://127.0.0.1:7311/health    # no token needed: the one perception act
TOKEN=$(.build/release/verdictd token)
.build/release/verdict decide --example | curl -s -X POST http://127.0.0.1:7311/v1/systemone -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d @-
```

A stock Jev client works unchanged: send `"model": "jev-latest"` and the default backend answers. Contract: [SPEC.md §10](SPEC.md).

 `swift test`: 29 tests in 6 suites (offline contract tests over a fake backend; tokenizer and sequence parity against the laya-coreml Python port; a live Laya fidelity test when the checkpoint is present). `verdict replay` over the 40-item fm-bench fixture on macOS 26.5.2, M4 Pro:

| backend · run | top-1 | out-of-schema | refusals | P50 / item | confidence | record |
|---|---|---|---|---|---|---|
| `verdict-fm` greedy (`--votes 1`) | **28/40** | 0 | 0 | 1184 ms | none | `evidence/replay-2026-09-21-foundation-models-v1.json` |
| `verdict-fm` agreement (`--votes 3`) | 25/40 | 0 | 0 | 2887 ms | agreement | `evidence/replay-2026-09-21-foundation-models-v3.json` |
| `verdict-fm` agreement (`--votes 5`) | 25/40 | 0 | 0 | 4782 ms | agreement | `evidence/replay-2026-09-21-foundation-models-v5.json` |
| `verdict-laya` (Laya typed-decisions, Core ML, CPU) | 18/40 | 0 | 0 | 2.3–2.7 s (two runs) | decoded | `evidence/replay-2026-09-21-laya-coreml-v1.json` |

**Narrow-decision fixture** (160 cases derived from the vault's own filing decisions: 80 yes/no with a true and a false topic per note, 40 three-way and 40 five-way choices; `scripts/make-narrow-fixture.py`):

| backend | total | noul (pos / neg) | 3-way | 5-way | P50 / case | confidence right vs wrong |
|---|---|---|---|---|---|---|
| `verdict-fm` greedy | **130/160** | 66/80 (27 / 39) | 30/40 | **34/40** | **518 ms** | none |
| `verdict-laya` | 113/160 | 55/80 (35 / 20) | **32/40** | 26/40 | 1775 ms | 0.14 vs 0.08 (decoded) |

Records: `evidence/replay-2026-09-21-narrow-*.json`. Laya's decoded confidence carries a little signal (cases above its median confidence: 67/80 right; below: 46/80) but the distributions are nearly flat: 158 of 160 answers have confidence under 0.5 because the checkpoint's calibration temperatures for small option counts are 1.8–2.0. Foundation Models is more accurate on every kind except the three-way choice, and 3.4× faster, on this vault's text. The two models fail differently on yes/no: Laya says yes too readily (35/40 positives, 20/40 negatives), Foundation Models says no too readily (27/40, 39/40).

Laya's answers match the laya-coreml Python port on all 40 items and its probabilities within 4.5e-5. Its decoded confidence on this 26-way task is over-sharp: the checkpoint's own `choice:11+` calibration temperature is 0.10, and wrong answers carry almost the same confidence as right ones (mean 0.89 vs 0.95; 11 of 22 wrong answers at ≥ 0.95). **Laya is not the router for a wide topic choice on this vault.** Where it earns its place is narrow decisions (noul, 2–10 options, short states): ~230–370 ms per decision with a real distribution, where Foundation Models gives ~300 ms and no confidence at all. `verdict bench` prints both on this Mac.

Core ML placement on macOS 26.5: every one of the export's 1,643 ops runs on the CPU under every compute-unit setting (the port's 5–14 ms figures are M3 Max GPU/ANE numbers on another OS build). `VERDICT_LAYA_COMPUTE` overrides the default `cpu`.

Agreement (Foundation Models): winner share on right vs wrong answers is 0.77 vs 0.58 at N=3 and 0.86 vs 0.63 at N=5; at both N, 9/25 right answers are unanimous and 0/15 wrong ones are. "Unanimous → accept, split → ask" holds on this fixture at either N; N=3 buys it at 2.4× greedy latency instead of 4×.

```bash
swift build -c release
.build/release/verdict status
.build/release/verdict decide --example | .build/release/verdict decide --request -
.build/release/verdict replay ~/Code/knowledge/plan/fm-bench/fixture.json --votes 1 --gate 26
hf download aac6fef/laya-typed-decisions-coreml --local-dir "$HOME/Library/Application Support/verdict/models/laya-typed-decisions-coreml"   # 843 MB, Apache-2.0
.build/release/verdict status --verify
.build/release/verdict decide --example | .build/release/verdict decide --request - --model verdict-laya
.build/release/verdict bench
```

Contract and agent face: [SPEC.md](SPEC.md) (§0 agent contract, §3 Jev-compatible wire shape, §6 failure codes, §7 exit codes).

## Milestones
- **M0 — core + Foundation Models backend, CLI only.** `verdict decide --state f.txt --choice "a|b|c"`; agreement confidence; refusal retry-then-fail; fixture replay gate: matches the fm-bench greedy result (26/39 top-1) and never emits an option outside the schema. **Shipped 2026-09-21 — see Status.**
- **M1 — Laya Core ML backend.** In-process; decoded confidence; fixture replay ≥ fm-bench; measured P50 on this Mac. **Shipped 2026-09-21 — see Status. The "≥ fm-bench" clause failed (18/40 vs 28/40); recorded, not waived.**
- **M2 — `verdictd` loopback face.** Jev-compatible JSON, token gate, one process serving many callers; Inlay and Summon smoke calls. **Shipped 2026-09-21 — see Status.** Real Inlay/Summon integrations are those projects' work; the smoke scripts pin the exact shapes they will send.
- **M3 — MLX sidecar + policy routing.** Only if Core ML weights fail their fidelity gate on this machine.

## Prior art in the vault
- `notes/jcr-pattern-applications-smart-paste-and-on-device-capture` — FM has no probabilities; agreement is the only confidence; BM25 out-routes the LLM for filing.
- `sources/2026-09-20-laya-coreml-repo` · `sources/2026-09-20-laya-mlx-repo` — the two Laya ports and their numbers; Laya scored 62.5% on Cuth's Jev-style bench, so accuracy must be measured per task.
- `sources/2026-09-20-needle-semantic-find-chrome-extension-repo` — the loopback topology this copies, minus the cloud.
- `~/Code/llamacpp-jev`, `~/Code/sglang-jev-diffusion` — the engine-side wrappers; `verdict` is the Mac-native, no-GPU sibling.

## Open questions
- ~~Does laya-coreml's Apache-2.0 port carry usable weights for the `laya-typed-decisions` checkpoint?~~ Yes: `aac6fef/laya-typed-decisions-coreml`, Apache-2.0, sha256 manifest, validated 63/63 against upstream by the porter and 40/40 + 4.5e-5 drift against the Python port here.
- Native-messaging host vs plain `127.0.0.1` fetch for Inlay: Inlay's manifest already has `host_permissions: <all_urls>`, so a worker `fetch` to `127.0.0.1` needs no new permission and no CORS. Open only if Chrome tightens loopback access; the token still has to reach the extension (options page paste, or a native host later).
- Agreement N: measured 2026-09-21, N=3 and N=5 give the same unanimous-right / unanimous-wrong split (9/25 vs 0/15) on this fixture; N=3 at 2.4× greedy latency is the working default for callers that want a confidence. Re-measure on the passage-ranking fixture before fixing it in policy.
