"""Ollama (0.35+) adapter for JevBench: the native Jev wire (TypeSafeAdapter) against a local Ollama server,
with one status mapping. Ollama answers a prompt longer than the model's context with HTTP 400
("prompt 0 has N tokens; expected 1–M (input is never truncated)"). JevBench's runner counts a 422 as the
system refusing the input — scored wrong, not an outage — but three consecutive other errors stop the run.
This adapter reports that one context-limit 400 as 422, so the item is scored wrong and the run continues,
the same treatment every other context-limited entrant gets. Nothing else changes.

Install: copy beside jevbench/adapters/typesafe.py, register "ollama_nt": OllamaNTAdapter in jevbench/cli.py
(kinds dict + --adapter choices), run with --adapter ollama_nt --endpoint http://localhost:11434 --key-env "".
"""
from __future__ import annotations

from .typesafe import TypeSafeAdapter


class OllamaNTAdapter(TypeSafeAdapter):
    name = "ollama_nt"

    def run(self, task):
        res = super().run(task)
        if res.status == 400 and "tokens; expected" in (res.error or "") and "never truncated" in (res.error or ""):
            res.status = 422
        return res
