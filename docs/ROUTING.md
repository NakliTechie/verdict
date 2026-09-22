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
| Customer-service triage | **Qwen3.5-4B** (`jev-latest`, optional) | wins this domain, 0.90; needs the 4B backend running |
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

[`scripts/routing-topology.json`](../scripts/routing-topology.json) routes three event types to three
backends — `clipboard` → verdict-fm, `workflow_decision` → verdict-laya, `customer_service` →
Qwen3.5-4B. Run it:

```bash
verdictd watch --db events.sqlite --topology scripts/routing-topology.json
```

Per single request, route with the `model` field instead:

```bash
verdict decide --state note.txt --choice "billing|technical|account" --model verdict-laya
```

Full dataflow setup: [INTEGRATION.md](INTEGRATION.md).
