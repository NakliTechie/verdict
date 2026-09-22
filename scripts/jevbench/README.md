# Running verdict against JevBench

[JevBench](https://github.com/fstandhartinger/jevbench) (Benchmark Heaven, MIT) scores Jev-class
decision models on Intelligence, Calibration, Speed and Cost. Its task shape — a `state` plus a typed
`choice`/`score`/`noul` question — is identical to verdict's `/v1/systemone` wire, so verdict drops in
with the adapter here.

`verdict_nt.py` is a JevBench adapter for verdict. verdict-fm is label-only (no probability → accuracy
only, no Calibration credit, by JevBench's rule); verdict-laya returns a decoded distribution and is
scored with calibration. On-device → the price tariff is 0, so Cost settles to $0.

## Faithful run (their harness + scoring)

```bash
git clone https://github.com/fstandhartinger/jevbench && cd jevbench
pip install -e .                                    # their package
cp <verdict>/scripts/jevbench/verdict_nt.py jevbench/adapters/
# register it: add `from .verdict_nt import VerdictNTAdapter` to jevbench/adapters/__init__.py,
# add "verdict_nt": VerdictNTAdapter to the kinds dict in jevbench/cli.py, and "verdict_nt" to the
# --adapter argparse choices list.
verdictd install                                    # verdict must be serving on 127.0.0.1:7311
export VERDICT_TOKEN=$(verdictd token)

TASKS=datasets/public/easy.jsonl,datasets/public/hard.jsonl,datasets/public/original.jsonl
python -m jevbench.cli run --tasks "$TASKS" --adapter verdict_nt \
  --endpoint http://127.0.0.1:7311 --model verdict-fm \
  --results /tmp/verdict-fm.jsonl --ledger /tmp/led.json --raw-dir /tmp/jev-raw \
  --price-in-per-m 0 --price-out-per-m 0 --cap-usd 5
python -m jevbench.cli summarize --tasks "$TASKS" --results /tmp/verdict-fm.jsonl
```

Swap `--model verdict-laya` for the decoded-probability backend (gets a Calibration/ECE score).

## Quick run (accuracy per tier, no harness install)

`<verdict>/scripts/run-jevbench.py <jevbench-repo> --model verdict-fm --token-file <token>` posts each
public task to verdictd and scores accuracy per tier / type / family. Simpler; not the full composite.

## Caveats

- **Public subset only** (231 tasks; 109 hard held out) — not the official board number.
- **verdict-fm scores 0 on Calibration** (label-only); its Cost axis maxes (on-device) and Speed is good.
- A pull request to add `verdict_nt` upstream would put verdict on the official board.
