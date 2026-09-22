# Adapting verdict to your domain

verdict is built to need **no training** — the default is the stock Apple model, steered by the
question and rubric you send. When you genuinely need to adapt it to a domain, there are four
layers, lightest first. Each says plainly what ships today versus what is a recipe or roadmap.

| Layer | What it changes | Ships today? | Sovereign (on-device)? |
|---|---|---|---|
| 1. Prompt + rubric | The decision itself | yes | yes |
| 2. Recalibrate verdict-laya | Confidence, not answers | yes (format) | yes |
| 3. Fine-tune verdict-laya | Answers (weights) | recipe — no exporter shipped | yes |
| 4. LoRA adapter on Apple FM | verdict-fm answers | roadmap — not wired in verdict | yes |

## Layer 1 — Prompt + rubric (no training)

The intended customization surface. You shape a decision with the question, the options, and a
per-option rubric (`criteria`). No model changes, both backends, works today.

```bash
# The rubric is inline in the option string: key=description, options separated by |
verdict decide --state ticket.txt \
  --ask "Which team owns this ticket?" \
  --choice "billing=charges, refunds, invoices|technical=bugs, errors, outages|sales=pricing, plans, upgrades"
```

(Over HTTP the same rubric is the `criteria` field on the question object; on the CLI it is the
`key=description` form above.) For most "adapt it to my workflow" needs this is the whole answer — reach for a lower layer only
when the accuracy or the confidence on *your* data is not good enough.

## Layer 2 — Recalibrate verdict-laya on your data (ships today)

`verdict-laya` returns a decoded probability. Its calibration is a set of temperatures in
`rl_agent_config.json`, separate from the weights. You can **fit those temperatures on your own
labelled examples** — no weight training — and drop the directory back in. This is the real
"tune it on your machine and use it" path, and it stays entirely on your disk.

1. Get the open checkpoint (Apache-2.0, 843 MB):
   ```bash
   hf download aac6fef/laya-typed-decisions-coreml --local-dir ~/laya-mine
   ```
2. Collect labelled examples in your domain — each is a `(state, question, gold_label)`.
3. Fit temperatures by minimizing ECE on a held-out half (the method verdict already uses to
   *test* calibration — see `scripts/bench-endpoint.py`, the `recalibration_gain` block). Write the
   result into `rl_agent_config.json`:
   ```json
   { "head_max_len": 192, "temperature": [1.0, 1.0, 1.0], "temperature_by_options": { "3": 1.4, "5": 1.7 } }
   ```
   `temperature` is [noul, choice, score]; `temperature_by_options` overrides by option count.
   All must be finite and > 0.
4. Point verdict at your copy and verify:
   ```bash
   export VERDICT_LAYA_MODEL=~/laya-mine
   verdict status --verify           # checks manifest sizes + sha256
   verdict bench                      # confirms it loads and answers
   ```

Only the calibration file changed, so the answers are identical to stock Laya — what improves is
whether its probabilities are worth thresholding on for *your* data. Measure ECE before and after.

## Layer 3 — Fine-tune verdict-laya's weights (recipe; exporter not shipped)

If you need different *answers*, not just better-calibrated confidence, retrain the checkpoint.
`verdict-laya` loads any directory in the `laya-coreml` v1 format, so a re-export drops in exactly
like Layer 2 — but verdict does **not** yet ship the exporter, so this is a recipe you run yourself.

1. Fine-tune the underlying encoder (ModernBERT-large class) on your labelled typed-decision data
   with HuggingFace `transformers` — a standard sequence-classification / span head fine-tune.
2. Export to Core ML with `coremltools` and assemble the `laya-coreml` v1 layout the backend reads:
   - `coreml_config.json` — `{"format":"laya-coreml","format_version":1,"source":…,"precision":…,`
     `"shape":{"max_length":512,"lengths":[…],"max_options":32},"files":{<path>:{"bytes":…,"sha256":…}}}`
   - `rl_agent_config.json` — head length + calibration temperatures (Layer 2)
   - `tokenizer/tokenizer.json`, `tokenizer/tokenizer_config.json`
   - `model.mlpackage/…` — the compiled Core ML package; the weight blob's sha256 keys the compile
     cache, so verdict never pairs stale weights with a new tokenizer.
3. `export VERDICT_LAYA_MODEL=<your export dir>` and `verdict status --verify`.

Roadmap: a `verdict export` command that produces this layout from a fine-tuned checkpoint, so
Layer 3 becomes one command like Layer 2. Until then, reproduce the format above.

## Layer 4 — LoRA adapter on Apple Foundation Models (roadmap)

Apple ships an **adapter training toolkit** that produces a LoRA-style `.fmadapter` loadable on the
on-device model — so adapting verdict-fm itself is possible at the platform level. Two things to know:

- It is **version-locked to a specific base-model build** and must be retrained whenever Apple
  updates the OS model; it is also a download and needs the training toolkit. That cuts against the
  zero-install default, so it belongs at Product tier, not the Tool-tier default.
- **verdict-fm does not load a custom adapter today.** Wiring `SystemLanguageModel` adapter support
  into the `FoundationModelsBackend` is a roadmap item — this layer is not a shipped verdict feature
  yet, unlike Layers 1–2.

## Which layer do you want?

- Need a different *decision* on *general* text → **Layer 1** (rubric). Almost always enough.
- Laya's probability is miscalibrated on your data → **Layer 2** (recalibrate). Ships today.
- Need different *answers* and you have labelled data → **Layer 3** (fine-tune Laya, re-export).
- Want to adapt the Apple model itself → **Layer 4** (LoRA), when verdict wires it in.
