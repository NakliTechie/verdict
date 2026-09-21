#!/bin/sh
# Summon-shaped smoke call: smart-paste field routing. Mirrors what Summon's LocalModelRung does for a
# loopback model server (http://127.0.0.1, bearer from a file, one URLSession POST). Exit 0 = every
# question answered with a schema-valid label and the expected keys present.
set -eu
PORT=${VERDICT_PORT:-7311}
TOKEN=$(cat "${VERDICT_TOKEN_FILE:-$HOME/Library/Application Support/verdict/token}")
MODEL=${1:-verdict-laya}
body=$(cat <<JSON
{
  "model": "$MODEL",
  "state": "Dr. Priya Raman\nSenior Engineer, Atlas Robotics\npriya.raman@atlasrobotics.example\n+91 98765 43210\nBengaluru, KA 560001",
  "questions": {
    "field_for_line3": {"type": "choice", "instructions": "The clipboard's third line is an email address. Which form field should receive it?",
      "criteria": {"name": "Full name", "email": "Email address", "phone": "Phone number", "company": "Company or organisation", "city": "City"}},
    "is_contact": {"type": "noul", "instructions": "Is this clipboard content a person's contact details?"},
    "fill_confidence": {"type": "score", "instructions": "How safe is it to auto-fill a contact form from this text without asking?",
      "criteria": ["Ask first: ambiguous", "Propose: mostly clear", "Fill: unambiguous contact card"]}
  }
}
JSON
)
t0=$(python3 -c 'import time;print(int(time.time()*1000))')
resp=$(curl -s -w '\n%{http_code}' -X POST "http://127.0.0.1:$PORT/v1/systemone" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data "$body")
t1=$(python3 -c 'import time;print(int(time.time()*1000))')
code=$(printf '%s' "$resp" | tail -n1)
json=$(printf '%s' "$resp" | sed '$d')
printf '%s\n' "$json" | python3 -c '
import json,sys
d=json.load(sys.stdin); a=d["answers"]
assert not d["failures"], d["failures"]
assert a["field_for_line3"]["choice"] in {"name","email","phone","company","city"}
assert a["is_contact"]["type"]=="noul" and 0<=a["is_contact"]["noul"]<=1
assert a["fill_confidence"]["level"] in (0,1,2)
print("field_for_line3 =", a["field_for_line3"]["choice"], "| is_contact =", round(a["is_contact"]["noul"],3), "| fill_confidence level =", a["fill_confidence"]["level"], "| kind =", a["is_contact"]["confidence_kind"])
'
echo "HTTP $code  wall $((t1 - t0)) ms  model $MODEL"
[ "$code" = "200" ]
