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
M0 shipped. `swift build` + `swift test` (25 offline tests over a fake backend) + `verdict replay` over the 40-item fm-bench fixture on macOS 26.5.2:

| run | top-1 | out-of-schema | refusals | P50 / item | record |
|---|---|---|---|---|---|
| greedy (`--votes 1`) | 28/40 | 0 | 0 | 1184 ms | `evidence/replay-2026-09-21-foundation-models-v1.json` |
| agreement (`--votes 3`) | 25/40 | 0 | 0 | 2887 ms | `evidence/replay-2026-09-21-foundation-models-v3.json` |
| agreement (`--votes 5`) | 25/40 | 0 | 0 | 4782 ms | `evidence/replay-2026-09-21-foundation-models-v5.json` |

Agreement: winner share on right vs wrong answers is 0.77 vs 0.58 at N=3 and 0.86 vs 0.63 at N=5; at both N, 9/25 right answers are unanimous and 0/15 wrong ones are. "Unanimous → accept, split → ask" holds on this fixture at either N; N=3 buys it at 2.4× greedy latency instead of 4×.

```bash
swift build -c release
.build/release/verdict status
.build/release/verdict decide --example | .build/release/verdict decide --request -
.build/release/verdict replay ~/Code/knowledge/plan/fm-bench/fixture.json --votes 1 --gate 26
```

Contract and agent face: [SPEC.md](SPEC.md) (§0 agent contract, §3 Jev-compatible wire shape, §6 failure codes, §7 exit codes).

## Milestones
- **M0 — core + Foundation Models backend, CLI only.** `verdict decide --state f.txt --choice "a|b|c"`; agreement confidence; refusal retry-then-fail; fixture replay gate: matches the fm-bench greedy result (26/39 top-1) and never emits an option outside the schema. **Shipped 2026-09-21 — see Status.**
- **M1 — Laya Core ML backend.** In-process; decoded confidence; fixture replay ≥ fm-bench; measured P50 on this Mac.
- **M2 — `verdictd` loopback face.** Jev-compatible JSON, token gate, one process serving many callers; Inlay and Summon smoke calls.
- **M3 — MLX sidecar + policy routing.** Only if Core ML weights fail their fidelity gate on this machine.

## Prior art in the vault
- `notes/jcr-pattern-applications-smart-paste-and-on-device-capture` — FM has no probabilities; agreement is the only confidence; BM25 out-routes the LLM for filing.
- `sources/2026-09-20-laya-coreml-repo` · `sources/2026-09-20-laya-mlx-repo` — the two Laya ports and their numbers; Laya scored 62.5% on Cuth's Jev-style bench, so accuracy must be measured per task.
- `sources/2026-09-20-needle-semantic-find-chrome-extension-repo` — the loopback topology this copies, minus the cloud.
- `~/Code/llamacpp-jev`, `~/Code/sglang-jev-diffusion` — the engine-side wrappers; `verdict` is the Mac-native, no-GPU sibling.

## Open questions
- Does laya-coreml's Apache-2.0 port carry usable weights for the `laya-typed-decisions` checkpoint, or only the English/multilingual QA ones?
- Native-messaging host vs plain `127.0.0.1` fetch for Inlay: which survives Chrome's extension permission model with less friction?
- Agreement N: measured 2026-09-21, N=3 and N=5 give the same unanimous-right / unanimous-wrong split (9/25 vs 0/15) on this fixture; N=3 at 2.4× greedy latency is the working default for callers that want a confidence. Re-measure on the passage-ranking fixture before fixing it in policy.
