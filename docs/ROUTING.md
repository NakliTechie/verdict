# Routing decisions to the right backend

verdict has three backends with **different strengths on different task families**. The best
realizable strategy is not an automatic hybrid — it is to **route each task family to the backend
that owns it**, which verdict already supports: set `model` per request, or per event type in a
dataflow `topology.json`. Evidence: [COMPARISON.md](COMPARISON.md) (10,356 Open-Jev + 2,000
typed-decisions, held-out).

## Which backend for which task

| task family | backend | why |
|---|---|---|
| Content-sensing / extraction (is_url, is_secret, is_contact) | **verdict-fm** | leads precision (0.988), zero-install |
| Spatial / game-state reasoning | **verdict-fm** | e.g. tile_platformer 0.89 vs laya 0.20 |
| Typed workflow / policy-gating / agent-control (action, urgency, escalate) | **verdict-laya** | in-distribution specialist, 0.73–0.80; 843 MB |
| Customer-service triage | **verdict-laya** in-tree; **Qwen3.5-4B** for the extra edge | laya handles typed intent; Qwen wins this domain (0.90) but is a *separate* llamacpp-jev endpoint, not a verdict backend — see below |
| Anything else / unsure | **verdict-fm** (default) | zero-install, no download |

Default to **verdict-fm** — it is the OS model, so it costs nothing to reach for. Move a task family
to another backend only where the evidence shows it wins.

## Why not an automatic router

Measured on the same data: **no automatic router robustly beats picking the right backend per domain.**
Majority-vote-of-3 beats Laya on Open-Jev (+1.8) but *loses* on typed-decisions (−4.3, dragged down by
a weak third arm); confidence gates lose on both. Confidence is not the routing signal. A hand-written
per-domain table is robust (never worse than the best single backend) and needs no extra compute — a
3-way vote costs 3× latency plus two model downloads for a sometimes-negative delta.

## Worked example

[`scripts/routing-topology.json`](../scripts/routing-topology.json) routes three event types across
verdict's own backends — `clipboard` → verdict-fm, `workflow_decision` → verdict-laya,
`customer_service` → verdict-laya. Run it:

```bash
verdictd watch --db events.sqlite --topology scripts/routing-topology.json
```

Per single request, route with the `model` field instead:

```bash
verdict decide --state note.txt --choice "billing|technical|account" --model verdict-laya
```

**A topology `model` names a verdict backend — `verdict-fm` or `verdict-laya` only.** Aliases resolve
to those (e.g. `jev-latest` → `verdict-fm`), so do not use an alias expecting a third engine.
**Qwen3.5-4B is not a verdict backend** — it runs as a separate
[llamacpp-jev](https://github.com/NakliTechie/llamacpp-jev) server on its own port. To send the
customer-service domain to Qwen, point that consumer's client at the llamacpp-jev endpoint directly;
verdict's topology cannot route to it. Validate any topology before shipping it:
`python3 scripts/check-topology.py <topology.json>`.

Full dataflow setup: [INTEGRATION.md](INTEGRATION.md).
