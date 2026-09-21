# Changelog

All notable changes to verdict are recorded here. Format follows [Keep a Changelog](https://keepachangelog.com); this project uses [Semantic Versioning](https://semver.org).

## [0.1.0] — 2026-09-22

First public release. Sovereign typed decisions on your Mac — on-device Apple Foundation Models, Jev-compatible, honest about confidence.

### Added
- **`VerdictCore`** — typed decisions (`choice` / `score` / `noul`) over a text state. Every `Decision` carries `answer`, `confidence`, and `confidenceKind` (`.decoded` | `.agreement` | `.none`); a number is never emitted without a kind.
- **`FoundationModelsBackend`** (default, `verdict-fm`) — Apple Foundation Models guided generation with `@Guide(.anyOf)` / bounded-int / Bool; schema-valid answers, on-device, no key, no download.
- **`LayaCoreMLBackend`** (optional, `verdict-laya`) — Laya typed-decisions via Core ML, real decoded probability distributions; own byte-level BPE tokenizer verified against the Python port.
- **Agreement confidence** — opt-in N sampled runs, unanimity share → `confidenceKind = .agreement`.
- **Refusal handling** — retry once, then a typed failure; never a silent fallback answer.
- **`verdict` CLI** — `status`, `decide` (flags or a Jev request, `--example`), `replay` (fixture gate), `bench` (per-backend warm latency).
- **`verdictd`** — loopback HTTP face on `127.0.0.1`, bearer-token gated, Jev-compatible `POST /v1/systemone` plus `GET /health` `/v1/models` `/v1/limits`. A `jev-latest` client works unchanged.
- **Dataflow mode** — `verdictd watch`: an SQLite `events` table in, a `decisions` table out, questions per event type from `topology.json`, the join left to the consumer's SQL.
- **launchd agent** — `verdictd install` / `uninstall` / `agent-status` (RunAtLoad + KeepAlive, per-user, no sudo).
- **Docs** — `SPEC.md` (the contract), `docs/INTEGRATION.md` (how to call it), `docs/COMPARISON.md` (benchmarks vs local Jev-mechanism engines), `llms.txt` (agent face).

### Verified
- 55 tests across 11 suites (offline contract tests over a fake backend; tokenizer + sequence parity vs the laya-coreml Python port; live Laya fidelity; server/router; dataflow).
- fm-bench routing gate: `verdict-fm` 28/40 top-1, 0 out-of-schema. Clipboard routing join (204 items): `verdict-fm` precision 0.988, 0.83 recall, 1 secret leak. Full matrix in `docs/COMPARISON.md`.

### Known limits
- `verdict-fm` returns no calibrated probability (single greedy run); use `votes >= 3` or `verdict-laya` for a distribution.
- Apple Silicon + macOS 26 with Apple Intelligence only.
- Wide retrieval (which of 100 topics) is better served by BM25; verdict is for narrow typed decisions.
- Not benchmarked against hosted Jev (no API key yet).

[0.1.0]: https://github.com/NakliTechie/verdict/releases/tag/v0.1.0
