# Integrating with verdictd

For a program that wants a typed on-device decision: give `verdictd` a piece of text and typed
questions, get typed answers with an honest confidence label. This is the contract Inlay, Summon, and
the capture app call. The working shapes are pinned in `scripts/smoke-summon.sh` and
`scripts/smoke-inlay.mjs`; this document is the prose around them.

`verdictd` speaks TypeSafe Jev's `POST /v1/systemone`, so a client written against Jev, openjev, or
`llamacpp-jev` works unchanged — send `"model": "jev-latest"` and the default backend answers.

## 1. Reach the server

- **Bind.** `http://127.0.0.1:7311` only. There is no flag to bind anything else. A client that cannot
  open a loopback socket cannot use verdict; there is no remote fallback by design.
- **Is it up?** `GET /health` needs no token and returns `200` with `{status, bind, models, backends,
  uptime_s, limits, version}`, or `503` when no backend is available. Poll it before the first call.
- **Start it.** If `/health` refuses the connection, the server is not running. `verdictd install`
  registers a per-user launchd agent that keeps it up across logins (see the README). A consumer app
  should treat "connection refused" as "not installed yet", not as an error to retry forever.

## 2. The token

Every route except `/health` requires `Authorization: Bearer <token>`.

- The token is 64 hex characters in `~/Library/Application Support/verdict/token`, mode `0600`, created
  on first start. `verdictd token` prints it; `verdictd token --path` prints the file path.
- A native app the user runs reads that file directly at the same UID.
- A **browser extension** (Inlay) cannot read the file. Deliver the token once through the extension's
  own options page: the user runs `verdictd token`, pastes the value into a field, and the extension
  stores it in `chrome.storage.local`. A native-messaging host is the heavier alternative and is only
  worth it if you also need lifecycle control; plain loopback `fetch` from an MV3 service worker with
  `host_permissions: <all_urls>` needs no host and no CORS. Recommendation: options-page paste first.
- Missing or wrong token → `401` with `WWW-Authenticate: Bearer` and a remedy naming the file. Never
  put the token in a URL or a query string; it is a header only.

## 3. Ask

`POST /v1/systemone`, `Content-Type: application/json`, body up to 1 MiB:

```json
{
  "model": "verdict-fm",
  "state": "<the text every question is asked about>",
  "questions": {
    "<your id>": {"type": "noul",   "instructions": "A yes/no question."},
    "<your id>": {"type": "choice", "instructions": "Pick one.", "criteria": {"key_a": "desc", "key_b": "desc"}},
    "<your id>": {"type": "score",  "instructions": "Rate it.", "criteria": ["low", "mid", "high"]}
  },
  "policy": {"votes": 1}
}
```

- **`model`** — `verdict-fm` (Foundation Models, the default and the recommendation) or `verdict-laya`
  (Laya Core ML). Aliases: `fm`, `foundation-models`, `laya`, `laya-coreml`, `jev-latest`. `GET
  /v1/models` lists what this install serves. Unknown model → `422`.
- **`state`** — a string. Objects and chat transcripts are not accepted yet (M2 scope). Truncate long
  input yourself; verdict does not, and an over-long state returns `413 context_exceeded` with the
  measured safe length.
- **`questions`** — 1 to 64, keyed by your own ids; the response echoes those ids. Types:
  - `noul` — yes/no. `criteria` optional; when absent each backend uses its own trained wording. Supply
    `{"true": "...", "false": "..."}` when the phrasing matters (it shifts Laya's answer noticeably).
  - `choice` — 2 to 64 options as `{key: description}`; a `null` description shows the key itself. The
    answer is one key.
  - `score` — an ordered rubric of 2 to 64 levels, lowest first. The answer is a level index and its
    expected value.
- **`policy.votes`** — 1 (greedy, no confidence) or 2 to 25 (sampled runs, agreement confidence). Only
  meaningful on `verdict-fm`; `verdict-laya` always runs once and ignores it. Each vote is another model
  call, so N votes is N× the latency — opt in per question, not by default.

## 4. Read

`200` with:

```json
{
  "model": "verdict-fm",
  "backend": "foundation-models",
  "answers": {
    "<id>": {"type": "noul",   "noul": 0.93, "confidence": null, "confidence_kind": "none", "samples": 1, "latency_ms": 300},
    "<id>": {"type": "choice", "choice": "key_a", "probabilities": {...}, "confidence": 0.8, "confidence_kind": "decoded", ...},
    "<id>": {"type": "score",  "score": 1.3, "level": 1, "legend": {"0": "low", "1": "mid", "2": "high"}, ...}
  },
  "failures": {},
  "usage": {"samples": 3, "retries": 0, "seed": 1, "votes": 1, "latency_ms": 710}
}
```

- Every question id appears in exactly one of `answers` or `failures`.
- **`confidence_kind`** is the honest part. `none` = one greedy run, no confidence exists, `confidence`
  is `null` — do not invent one. `agreement` = share of N votes that agreed (Foundation Models).
  `decoded` = a real model probability (Laya). A number is never emitted without a kind.
- `noul` is P(true) in `[0,1]`. `choice` gives the winning key plus `probabilities`. `score` gives the
  expected level and a `legend`.
- Response headers on `200`: `x-verdict-backend`, `x-verdict-latency-ms`, `x-verdict-failures` (count).
- **Per-question failures do not fail the request.** If one question is refused, its id lands in
  `failures` with a `code`, `message`, `remedy`, and `retryable`; the others still answer, and the
  status stays `200`. Branch on the presence of each id, not on the HTTP status alone.

## 5. Handle failure by status

One HTTP status maps to one next action:

| status | meaning | what the client should do |
|---|---|---|
| `200` | answered (check `failures` per id) | consume `answers`; for any `failures[id]`, read its `remedy` |
| `401` | missing/wrong token | re-read the token file; prompt the user to re-paste in an extension |
| `422` | malformed request or unknown model | fix the body; `GET /v1/models` for valid model names |
| `413` | body or state too large | shorten `state` (the message names the limit) |
| `429` | throttled or concurrent | back off and retry; `retryable` is true |
| `503` | a whole backend is unavailable | the model is off or still downloading; surface the remedy, retry later |
| `502` | the model declined | rephrase the state or question; not automatically retryable |

Request-level errors return `{"error": {"code", "message", "remedy", "retryable"}}` with the same closed
`code` set as per-question failures. Show the `remedy`; it names the fix.

## 6. Choosing a backend

- **`verdict-fm`** is the default and the right choice for most callers: more accurate on this vault's
  text and faster (~300–800 ms per question on an M4 Pro). It gives no confidence on a single run;
  use `votes >= 3` when you need an agreement signal to threshold on.
- **`verdict-laya`** is the only backend that returns a real per-option probability (`decoded`). Pick it
  only when you need that distribution to threshold on, and measure it on your own inputs first: on the
  vault fixtures its confidence was nearly flat (most answers under 0.5) and its accuracy trailed
  `verdict-fm`. It runs on the CPU here, so it does not contend for the Neural Engine.
- `verdict bench` prints both backends' warm latency on the current machine.

## 7. Two working examples

- `scripts/smoke-summon.sh [model]` — smart-paste field routing: a `choice` over form fields, a `noul`,
  and a `score`, called the way Summon's `LocalModelRung` calls a loopback model server (curl, token
  from the file). Exit 0 = every answer schema-valid.
- `scripts/smoke-inlay.mjs [model]` — passage ranking: one `score` per candidate passage plus a
  best-passage `choice`, called with Node `fetch` as an MV3 service worker would. Exit 0 = ranking
  returned.

Both are the exact shapes their consumers will send; start from them.

## 8. Dataflow mode (second door)

For a consumer that already has a stream of small events (Summon's clipboard history, a page reader),
`verdictd watch` is an alternative to calling `/v1/systemone` per event. You give it an SQLite file and
a topology; it answers each pending event's questions into a `decisions` table you join in your own SQL.

```bash
verdictd watch --db events.sqlite --topology topology.json --once   # drain the backlog and exit
verdictd watch --db events.sqlite --topology topology.json          # poll and keep answering
```

- **You insert events**: `INSERT INTO events(type, state) VALUES('clipboard', '<text>')` — `status`
  defaults to `pending`. verdict creates the two tables if absent (`SPEC §12.1`) and never alters them.
- **topology.json** maps each event `type` to a model and a set of questions in the exact §3 shape; see
  `scripts/example-topology.json`. An event whose type is not in the topology is `skipped`, never guessed.
- **You read decisions** once the event is `done`: one row per question with `answer`, `confidence`,
  `confidence_kind`, `probabilities`, and `failed`/`code` for a per-question failure. Join them back to
  your events and apply your threshold in SQL.
- **The join and the fallback are yours.** verdict writes honest rows and stops; the threshold that
  decides "confident enough to act" and the route for low-confidence or `failed` decisions (a bigger
  model, a human) live in your SQL, measured on your own data — verdict has no larger on-device model to
  fall back to, and a confidence threshold only means something on your inputs.

Each event is answered in one transaction, so a crash leaves it `pending` with no partial rows and a
re-run reprocesses it cleanly. Contract: `SPEC §12`.
