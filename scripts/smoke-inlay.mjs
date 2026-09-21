// Inlay-shaped smoke call: semantic ⌘F Tier 1. An MV3 service worker with host_permissions <all_urls>
// fetches http://127.0.0.1 directly (no CORS preflight applies to extension workers), so plain Node fetch
// is the faithful stand-in. Ranks candidate passages for a query with one Score per passage and one
// Choice for the best. Exit 0 = every answer schema-valid; prints the ranking.
import { readFileSync } from "node:fs";
import { homedir } from "node:os";

const port = process.env.VERDICT_PORT ?? "7311";
const token = readFileSync(process.env.VERDICT_TOKEN_FILE ?? `${homedir()}/Library/Application Support/verdict/token`, "utf8").trim();
const model = process.argv[2] ?? "verdict-laya";
const query = "how do I revoke an API key";
const passages = {
  p1: "Billing is charged monthly in arrears. Invoices are emailed on the 1st and payable within 30 days.",
  p2: "To revoke an API key, open Settings → API keys, find the key, and click Revoke. Revocation is immediate and cannot be undone.",
  p3: "Rate limits are 600 requests per minute per key. Exceeding them returns HTTP 429 with a Retry-After header.",
  p4: "Rotating a key: create a new key first, update your clients, then revoke the old one to avoid downtime.",
};
const questions = Object.fromEntries(Object.entries(passages).map(([id, text]) => [
  `rel_${id}`, { type: "score", instructions: `Query: "${query}"\nPassage: ${text}\nHow relevant is the passage to the query?`,
                 criteria: ["Irrelevant", "Related", "Answers the query"] },
]));
questions.best = { type: "choice", instructions: `Which passage best answers the query "${query}"?`, criteria: passages };

const t0 = Date.now();
const res = await fetch(`http://127.0.0.1:${port}/v1/systemone`, {
  method: "POST",
  headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
  body: JSON.stringify({ model, state: `Search query: ${query}`, questions }),
});
const wall = Date.now() - t0;
const body = await res.json();
if (!res.ok) { console.error(res.status, body); process.exit(1); }
if (Object.keys(body.failures).length) { console.error("failures:", body.failures); process.exit(1); }
const ranking = Object.keys(passages)
  .map((id) => ({ id, score: body.answers[`rel_${id}`].score, level: body.answers[`rel_${id}`].level }))
  .sort((a, b) => b.score - a.score);
for (const r of ranking) console.log(`${r.id}  level ${r.level}  score ${r.score.toFixed(3)}`);
console.log(`best = ${body.answers.best.choice}  kind = ${body.answers.best.confidence_kind}  confidence = ${body.answers.best.confidence ?? "null"}`);
console.log(`HTTP ${res.status}  wall ${wall} ms  server ${res.headers.get("x-verdict-latency-ms")} ms  model ${model}`);
if (!(body.answers.best.choice in passages)) process.exit(1);
