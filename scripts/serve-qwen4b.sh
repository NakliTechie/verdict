#!/usr/bin/env bash
# Bring up llamacpp-jev with Qwen3.5-4B-Q8_0 on a chosen port. Prints the URL on success, exits !=0 on failure.
set -euo pipefail
PORT="${1:-8010}"
LOG="${2:-/tmp/qwen4b-serve.log}"
export HF_HOME=/Users/chiragpatnaik/models/hf-hub
GGUF="$(hf download unsloth/Qwen3.5-4B-GGUF Qwen3.5-4B-Q8_0.gguf 2>/dev/null)"
[ -f "$GGUF" ] || { echo "FATAL: gguf not found: $GGUF" >&2; exit 2; }
LS=""
for c in /Users/chiragpatnaik/Code/llama.cpp-dev/build-metal/bin/llama-server \
         /Users/chiragpatnaik/Code/llama.cpp-prism/build-metal/bin/llama-server; do
  [ -x "$c" ] && { LS="$c"; break; }
done
[ -n "$LS" ] || { echo "FATAL: no llama-server binary" >&2; exit 3; }
cd /Users/chiragpatnaik/Code/llamacpp-jev
nohup uv run llamajev serve --model "$GGUF" --llama-server "$LS" --slots 4 --port "$PORT" > "$LOG" 2>&1 &
echo "serve pid $!"
for i in $(seq 1 90); do
  code=$(curl -s -m2 -o /dev/null -w "%{http_code}" -X POST "http://127.0.0.1:$PORT/v1/systemone" \
    -H 'Content-Type: application/json' \
    -d '{"model":"jev-latest","state":"x","questions":{"q":{"type":"noul","instructions":"Is this text?"}}}' || echo 000)
  [ "$code" = "200" ] && { echo "READY http://127.0.0.1:$PORT"; exit 0; }
  sleep 4
done
echo "FATAL: server did not become ready; see $LOG" >&2; tail -5 "$LOG" >&2; exit 4
