"""verdict (NakliTechie) adapter: on-device typed decisions via verdictd's Jev-compatible /v1/systemone.

verdict-fm (Apple Foundation Models) is label-only — one greedy guided-generation answer, no probability
— so it takes the label-only scoring path (accuracy, no calibration). verdict-laya (Laya Core ML) returns
a decoded distribution over the exact labels and is scored with calibration. Cost is on-device: the price
tariff is 0, so cost settles to 0 (zero route fee, compute excluded), the same basis other local entrants use.
"""
from __future__ import annotations
import json, os
from .base import DecisionResult, http_post_json


class VerdictNTAdapter:
    name = "verdict_nt"
    cost_basis = "on_device_zero_route_fee_compute_excluded"

    def __init__(self, endpoint=None, model=None, key_env="VERDICT_TOKEN", timeout_s=180,
                 price_input_per_m=0.0, price_output_per_m=0.0, revision=None, **kwargs):
        self.endpoint = (endpoint or "http://127.0.0.1:7311").rstrip("/")
        self.model = model or "verdict-fm"
        self.price_input_per_m = 0.0 if price_input_per_m is None else price_input_per_m
        self.price_output_per_m = 0.0 if price_output_per_m is None else price_output_per_m
        self.timeout_s = timeout_s or 180
        self.revision = revision
        tok = os.environ.get(key_env) if key_env else None
        if not tok:
            p = os.path.expanduser("~/Library/Application Support/verdict/token")
            tok = open(p).read().strip() if os.path.exists(p) else None
        self.token = tok

    def reserve_estimate(self, task):
        return 0.0

    def run(self, task) -> DecisionResult:
        res = DecisionResult(adapter=self.name, ok=False, model=self.model)
        q = task.question
        state = task.state if isinstance(task.state, str) else json.dumps(task.state, ensure_ascii=False)
        wq = {"type": q["type"], "instructions": q["instructions"]}
        if q.get("criteria") is not None:
            wq["criteria"] = q["criteria"]
        body = {"model": self.model, "state": state, "questions": {"q": wq}}
        res.request_body = body
        headers = {"Content-Type": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        try:
            status, parsed, _ = http_post_json(self.endpoint + "/v1/systemone", body, headers, self.timeout_s)
        except Exception as e:  # noqa: BLE001
            res.error = f"{type(e).__name__}: {str(e)[:200]}"
            return res
        res.status = status
        res.raw = parsed if isinstance(parsed, dict) else {"text": str(parsed)[:500]}
        if status != 200 or not isinstance(parsed, dict):
            err = parsed.get("error") if isinstance(parsed, dict) else None
            res.error = (err or {}).get("code") if isinstance(err, dict) else f"http{status}"
            return res
        a = parsed.get("answers", {}).get("q")
        if a is None:
            res.error = (parsed.get("failures", {}).get("q") or {}).get("code", "no_answer")
            return res
        res.model = parsed.get("model", self.model)
        res.usage = {"input_tokens": 0, "output_tokens": 0}  # on-device; tokens not billed
        labels = [str(x) for x in task.labels]
        qtype = q["type"]
        probs = None
        if qtype == "noul":
            p_true = a.get("noul")
            label = "yes" if (p_true is not None and p_true >= 0.5) else "no"
            if a.get("confidence_kind") not in (None, "none") and p_true is not None:
                probs = {"yes": float(p_true), "no": 1.0 - float(p_true)}
        elif qtype == "choice":
            label = a.get("choice")
            pr = a.get("probabilities")
            if a.get("confidence_kind") not in (None, "none") and isinstance(pr, dict):
                probs = {k: float(pr.get(k, 0.0)) for k in labels}
        else:  # score
            label = None if a.get("level") is None else str(a.get("level"))
            pr = a.get("probabilities")
            if a.get("confidence_kind") not in (None, "none") and isinstance(pr, dict):
                probs = {k: float(pr.get(k, 0.0)) for k in labels}
        if probs is not None and sum(probs.values()) > 0:
            res.probs = probs
            res.probs_source = "native"
        else:
            res.label = label
            res.probs = None
            res.probs_source = "label_only_no_calibrated_distribution"
        res.ok = label is not None
        return res
