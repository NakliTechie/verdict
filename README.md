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

## Milestones
- **M0 — core + Foundation Models backend, CLI only.** `verdict decide --state f.txt --choice "a|b|c"`; agreement confidence; refusal retry-then-fail; fixture replay gate: matches the fm-bench greedy result (26/39 top-1) and never emits an option outside the schema.
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
- Should agreement confidence default to N=3 or N=5? fm-bench measured N=5 at 5× latency; N=3 is unmeasured.
