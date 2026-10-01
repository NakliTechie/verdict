#!/usr/bin/env python3
"""Sample an inference engine's memory while a benchmark runs: per process, both RSS and the macOS physical
footprint (top's MEM column, which also counts compressed pages; RSS does not, and under memory pressure
a large share of an engine's heap sits compressed). Reports the peak of the per-sample sums, per-process
peaks keyed by pid + model argument, and the most processes seen at once, so a stray second runner shows.

  python3 scripts/sample-rss.py --match 'llama-server' --until-file /tmp/done --out mem.json
  python3 scripts/sample-rss.py --match 'verdictd|TGOnDeviceInferenceProviderService|modelmanagerd' ...

Stops when --until-file exists (after at least one sample) or after --max-seconds. Interval 2 s.
"""
import argparse, json, os, re, statistics, subprocess, time

ap = argparse.ArgumentParser()
ap.add_argument("--match", required=True, help="regex over the full command line")
ap.add_argument("--until-file", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--interval", type=float, default=2.0)
ap.add_argument("--max-seconds", type=float, default=6 * 3600)
a = ap.parse_args()
pat = re.compile(a.match)
me = os.getpid()
UNIT = {"B": 1 / 1024 / 1024, "K": 1 / 1024, "M": 1, "G": 1024}


def mb(tok):  # top prints e.g. 9070M, 1664M+, 12G-
    m = re.match(r"([\d.]+)([BKMG])", tok)
    return float(m.group(1)) * UNIT[m.group(2)] if m else 0.0


def model_arg(cmd):
    m = re.search(r"--model (\S+)", cmd)
    return os.path.basename(m.group(1))[:20] if m else ""


rss_sums, fp_sums, procs, max_conc, t0 = [], [], {}, 0, time.time()
while time.time() - t0 < a.max_seconds:
    out = subprocess.run(["ps", "-axo", "pid=,rss=,command="], capture_output=True, text=True).stdout
    hits = {}
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 3 or not parts[0].isdigit() or not parts[1].isdigit():
            continue  # a process whose argv holds a newline spills onto extra ps lines
        pid, rss, cmd = parts
        if int(pid) == me or "sample-rss.py" in cmd or not pat.search(cmd): continue
        hits[pid] = (int(rss) / 1024, cmd)
    fp = {}
    if hits:
        args = ["top", "-l", "1", "-stats", "pid,mem,cmprs"]
        for pid in hits: args += ["-pid", pid]
        for line in subprocess.run(args, capture_output=True, text=True).stdout.splitlines():
            f = line.split()
            if len(f) >= 3 and f[0] in hits: fp[f[0]] = (mb(f[1]), mb(f[2]))
    max_conc = max(max_conc, len(hits))
    rss_sums.append(sum(r for r, _ in hits.values()))
    fp_sums.append(sum(v[0] for v in fp.values()))
    for pid, (rss, cmd) in hits.items():
        key = f"{pid} {pat.search(cmd).group(0)} {model_arg(cmd)}".strip()
        p = procs.setdefault(key, {"rss_mb": 0, "footprint_mb": 0, "compressed_mb": 0})
        p["rss_mb"] = max(p["rss_mb"], round(rss))
        if pid in fp:
            p["footprint_mb"] = max(p["footprint_mb"], round(fp[pid][0]))
            p["compressed_mb"] = max(p["compressed_mb"], round(fp[pid][1]))
    if os.path.exists(a.until_file):
        break
    time.sleep(a.interval)
res = {"match": a.match, "samples": len(rss_sums), "seconds": round(time.time() - t0),
       "peak_footprint_mb": round(max(fp_sums)) if fp_sums else None,
       "median_footprint_mb": round(statistics.median(fp_sums)) if fp_sums else None,
       "peak_rss_mb": round(max(rss_sums)) if rss_sums else None,
       "median_rss_mb": round(statistics.median(rss_sums)) if rss_sums else None,
       "max_concurrent_processes": max_conc, "per_process": procs}
json.dump(res, open(a.out, "w"), indent=1)
print(json.dumps(res))
