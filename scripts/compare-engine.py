#!/usr/bin/env python3
"""One engine, every benchmark, serially: cold first decision, resident memory, disk footprint, then the
clipboard join (204), JevBench public (231, their harness), Open-Jev stratified (224) and Bespoke's public
human-labelled suite (3,880). Run engines one at a time so no two engines share the machine.

  python3 scripts/compare-engine.py --engine ollama  --model tev1:0.8b --label ollama-tev1-0.8b \
      --jevbench <jevbench repo> --openjev <open-jev test rows.json> --nimble <nimble repo> --scratch <dir>
  python3 scripts/compare-engine.py --engine verdict --model verdict-fm --label verdict-fm ...

Writes evidence/{compare-<date>-clip204,jevbench-<date>-faithful,openjev-<date>,nimble-public-<date>,
engine-<date>}-<label>.json. The JevBench run needs the verdict_nt adapter registered (scripts/jevbench/README.md).
"""
import argparse, json, os, re, statistics, subprocess, sys, time, urllib.request
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument("--engine", choices=["ollama", "verdict"], required=True)
ap.add_argument("--model", required=True)
ap.add_argument("--label", required=True)
ap.add_argument("--jevbench", required=True)
ap.add_argument("--openjev", required=True)
ap.add_argument("--nimble", required=True)
ap.add_argument("--scratch", required=True)
ap.add_argument("--date", default=time.strftime("%Y-%m-%d"))
ap.add_argument("--url", help="override the engine URL, e.g. a second `ollama serve` with other runner settings")
ap.add_argument("--only", nargs="*", default=["cold", "clip204", "jevbench", "openjev", "nimble"],
                help="steps; `memprobe` alone re-measures memory over 325 Bespoke decisions, no benchmark record")
a = ap.parse_args()

REPO = Path(__file__).resolve().parent.parent
EV = REPO / "evidence"
S = Path(a.scratch); S.mkdir(parents=True, exist_ok=True)
TOKEN_FILE = os.path.expanduser("~/Library/Application Support/verdict/token")
URL = a.url or ("http://localhost:11434" if a.engine == "ollama" else "http://127.0.0.1:7311")
TOK = ["--token-file", TOKEN_FILE] if a.engine == "verdict" else []
MEM_MATCH = ("llama-server|ollama serve" if a.engine == "ollama"
             else "verdictd|TGOnDeviceInferenceProviderService|modelmanagerd")
PY = sys.executable


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {a.label}: {msg}", flush=True)


def sh(cmd, **kw):
    log("$ " + " ".join(map(str, cmd)))
    return subprocess.run(list(map(str, cmd)), check=True, **kw)


def decide(state="https://example.com/reset?sig=abc123", timeout=600):
    body = {"model": a.model, "state": state,
            "questions": {"q": {"type": "noul", "instructions": "Is the text a single web URL?"}}}
    hdr = {"Content-Type": "application/json"}
    if a.engine == "verdict":
        hdr["Authorization"] = "Bearer " + open(TOKEN_FILE).read().strip()
    req = urllib.request.Request(URL + "/v1/systemone", data=json.dumps(body).encode(), headers=hdr)
    t0 = time.perf_counter()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        json.load(r)
    return (time.perf_counter() - t0) * 1000


def unload_and_cold():
    """Unload the model (Ollama: stop every loaded model; verdict: restart verdictd), then time decision 1."""
    if a.engine == "ollama":
        loaded = json.load(urllib.request.urlopen(URL + "/api/ps"))["models"]
        for m in loaded:
            sh(["ollama", "stop", m["name"]], env={**os.environ, "OLLAMA_HOST": URL})
        for _ in range(120):  # /api/ps empties before the old runner exits; wait for the process too
            if (not json.load(urllib.request.urlopen(URL + "/api/ps"))["models"]
                    and subprocess.run(["pgrep", "-f", "llama-server --model"], capture_output=True).returncode):
                break
            time.sleep(1)
        note = "Ollama with no model loaded; first request loads the weights"
    else:
        sh(["launchctl", "kickstart", "-k", f"gui/{os.getuid()}/com.naklitechie.verdictd"])
        for _ in range(60):
            try:
                urllib.request.urlopen("http://127.0.0.1:7311/", timeout=1)
            except urllib.error.HTTPError:
                break
            except Exception:
                time.sleep(0.5); continue
            break
        note = ("verdictd restarted; first request loads the backend in verdictd (verdict-fm's OS model "
                "lives in a system process the OS keeps resident on its own schedule)")
    cold = decide()
    warm = [decide() for _ in range(5)]
    return {"cold_first_decision_ms": round(cold), "warm_median_ms": round(statistics.median(warm)),
            "cold_note": note}


def disk():
    if a.engine == "ollama":
        tags = json.load(urllib.request.urlopen(URL + "/api/tags"))["models"]
        m = next(t for t in tags if t["name"] in (a.model, a.model + ":latest"))
        cellar = subprocess.run(["du", "-sk", "/opt/homebrew/Cellar/ollama"], capture_output=True, text=True).stdout
        return {"model_bytes": m["size"], "quantization": m["details"].get("quantization_level"),
                "parameter_size": m["details"].get("parameter_size"),
                "runtime_kb": int(cellar.split()[0]), "runtime": "Homebrew ollama " +
                json.load(urllib.request.urlopen(URL + "/api/version"))["version"]}
    base = os.path.expanduser("~/Library/Application Support/verdict")
    kb = lambda p: int(subprocess.run(["du", "-sk", p], capture_output=True, text=True).stdout.split()[0])
    if a.model == "verdict-fm":
        model, parts = 0, {}
    else:  # the downloaded package + the compiled model verdict keys by weight hash; other entries are listed apart
        d = base + "/models/laya-typed-decisions-coreml"
        parts = {e: kb(f"{d}/{e}") * 1024 for e in sorted(os.listdir(d))}
        model = sum(v for e, v in parts.items() if e == "model.mlpackage" or e.startswith("model-") or e == "tokenizer")
    sha = subprocess.run(["shasum", "-a", "256", base + "/bin/verdictd"], capture_output=True, text=True).stdout.split()[0]
    return {"model_bytes": model, "model_parts_bytes": parts, "runtime_kb": kb(base + "/bin"), "verdictd_sha256": sha,
            "model_note": "the macOS system Foundation Model; no extra download" if a.model == "verdict-fm"
            else "Laya Core ML package under Application Support/verdict/models"}


ENGINE_PROCS = ("llama-server", "ollama", "verdictd", "TGOnDeviceInferenceProviderService", "modelmanagerd",
                "kernel_task", "WindowServer")


def foreign_hogs(min_gb=4.0):
    """Processes outside the engines that hold >= min_gb physical footprint (top's MEM, compressed included)."""
    hogs = []
    for line in subprocess.run(["top", "-l", "1", "-o", "mem", "-n", "8", "-stats", "pid,mem,command"],
                               capture_output=True, text=True).stdout.splitlines():
        m = re.match(r"\s*(\d+)\s+([\d.]+)([KMG])\S*\s+(.*)", line)
        if not m: continue
        gb = float(m.group(2)) * {"K": 1 / 2**20, "M": 1 / 1024, "G": 1}[m.group(3)]
        if gb >= min_gb and not m.group(4).startswith(ENGINE_PROCS):
            hogs.append(f"{m.group(1)} {m.group(4).strip()} {gb:.1f}G")
    return hogs


def quiet_gate(quiet_s=60, max_s=4 * 3600):
    """Wait until the Mac is quiet for `quiet_s` seconds: no Swift build/test (other sessions build here) and no
    foreign process holding >= 4 GB (e.g. a large upload), since either skews latency. Returns seconds waited."""
    t0, last_busy, said = time.time(), time.time(), set()
    while time.time() - t0 < max_s:
        hogs = foreign_hogs()
        busy = bool(hogs) or subprocess.run(["pgrep", "-f", "swift-build|swift-test|swift-frontend|xcodebuild"],
                                            capture_output=True).returncode == 0
        for h in hogs:
            if h.split()[0] not in said:
                log(f"quiet gate: waiting on {h}"); said.add(h.split()[0])
        if busy: last_busy = time.time()
        elif time.time() - last_busy >= quiet_s: break
        time.sleep(5)
    return round(time.time() - t0)


waited = quiet_gate()
log(f"quiet gate: waited {waited} s for no Swift builds")
out = {"label": a.label, "engine": a.engine, "model": a.model, "url": URL, "date": a.date, "quiet_gate_wait_s": waited,
       "machine": subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip(),
       "macos": subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()}
rec = EV / f"engine-{a.date}-{a.label}.json"
if rec.exists():
    out = {**json.load(open(rec)), **out}
if "cold" in a.only:
    out.update(unload_and_cold()); log(f"cold {out['cold_first_decision_ms']} ms, warm {out['warm_median_ms']} ms")
out["disk"] = disk()

done_marker = S / f"{a.label}.mem.done"
done_marker.unlink(missing_ok=True)
mem_out = S / f"{a.label}.mem.json"
sampler = subprocess.Popen([PY, REPO / "scripts/sample-rss.py", "--match", MEM_MATCH,
                            "--until-file", done_marker, "--out", mem_out])
t_start = time.time()
try:
    if "clip204" in a.only:
        sh([PY, REPO / "scripts/bench-endpoint.py", REPO / "scripts/clipboard-fixture-200.json", "--url", URL,
            "--model", a.model, *TOK, "--label", a.label,
            "--out", EV / f"compare-{a.date}-clip204-{a.label}.json"], stdout=subprocess.DEVNULL)
    if "jevbench" in a.only:
        tasks = ",".join(f"datasets/public/{t}.jsonl" for t in ("easy", "hard", "original"))
        res = S / f"jb-{a.label}.jsonl"; res.unlink(missing_ok=True)
        adapter = ["--adapter", "ollama_nt", "--key-env", ""] if a.engine == "ollama" else ["--adapter", "verdict_nt"]
        sh([PY, "-m", "jevbench.cli", "run", "--tasks", tasks, *adapter, "--endpoint", URL, "--model", a.model,
            "--results", res, "--ledger", S / f"jb-{a.label}-ledger.json", "--raw-dir", S / f"jb-{a.label}-raw",
            "--price-in-per-m", "0", "--price-out-per-m", "0", "--cap-usd", "1",
            "--cost-basis", "on_device_zero_route_fee_compute_excluded",
            "--manifest", S / f"jb-{a.label}-manifest.json"], cwd=a.jevbench, stdout=subprocess.DEVNULL)
        summ = subprocess.run([PY, "-m", "jevbench.cli", "summarize", "--tasks", tasks, "--results", res],
                              cwd=a.jevbench, capture_output=True, text=True, check=True).stdout
        (EV / f"jevbench-{a.date}-faithful-{a.label}.json").write_text(summ)
    if "openjev" in a.only:
        sh([PY, REPO / "scripts/run-openjev.py", a.openjev, "--model", a.model, "--url", URL, *TOK,
            "--per-source", "20", "--seed", "7", "--out", EV / f"openjev-{a.date}-{a.label}.json"],
           stdout=subprocess.DEVNULL)
    if "nimble" in a.only:
        rows = S / f"nimble-public-{a.label}.jsonl"
        sh([PY, REPO / "scripts/run-nimble-public.py", "--nimble-repo", a.nimble, "--url", URL, "--model", a.model,
            *TOK, *(["--state-as-string"] if a.engine == "verdict" else []), "--label", a.label,
            "--rows", rows, "--out", EV / f"nimble-public-{a.date}-{a.label}.json"], stdout=subprocess.DEVNULL)
    if "memprobe" in a.only:
        sh([PY, REPO / "scripts/run-nimble-public.py", "--nimble-repo", a.nimble, "--url", URL, "--model", a.model,
            *TOK, *(["--state-as-string"] if a.engine == "verdict" else []), "--limit", "25",
            "--rows", S / f"memprobe-{a.label}.jsonl", "--out", S / f"memprobe-{a.label}.json"], stdout=subprocess.DEVNULL)
        (S / f"memprobe-{a.label}.jsonl").unlink(missing_ok=True)
finally:
    done_marker.touch()
    sampler.wait(timeout=60)
if "memprobe" not in a.only:
    out["benchmarks_wall_s"] = round(time.time() - t_start)
if "memprobe" in a.only and out.get("memory"):
    out["memory_first_pass"] = out["memory"]  # kept: the full run's RSS-only reading, superseded by the probe
out["memory"] = json.load(open(mem_out)) if mem_out.exists() else None
if a.engine == "ollama":
    out["ollama_ps"] = json.load(urllib.request.urlopen(URL + "/api/ps"))["models"]
rec.write_text(json.dumps(out, indent=1))
log(f"record: {rec}")
