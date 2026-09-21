#!/usr/bin/env python3
"""A labelled clipboard fixture for the dataflow gate (SPEC 12.5, M4b) and the comparison harness.
Each item is a realistic clipboard capture with crisp ground truth for four noul questions and the
derived routing decision. Parametric generators produce ~200 unique items.

  python3 scripts/make-clipboard-fixture.py scripts/clipboard-fixture-200.json

Ground truth (unambiguous by construction; secrets are synthetic):
  is_url / is_contact / is_code / is_secret
Routing (join under test): surface = (is_url OR is_contact) AND NOT is_secret
"""
import json, sys, random
rng = random.Random(7)

def card():
    fn = rng.choice(["Priya Raman","Arjun Mehta","Sara Khan","Devlin Fox","Ana Costa","Wei Chen","Omar Haddad","Lena Vogel","Nina Rao","Tom Ford","Yuki Sato","Ravi Iyer"])
    org = rng.choice(["Atlas Robotics","Northwind Labs","Meridian Health","Cobalt Systems","Vireo AI","Pallas Data","Kestrel Bank","Umbra Studios"])
    dom = org.lower().split()[0]
    role = rng.choice(["Senior Engineer","Head of Design","Founder","Analyst","Product Manager","VP Sales","Researcher","CTO"])
    cc = rng.choice(["+91 98765 43210","+1 415 555 0182","+44 7700 900123","+61 2 5550 1234","+49 30 555 0199"])
    return f"{fn}\n{role}, {org}\n{fn.split()[0].lower()}@{dom}.example\n{cc}"

def address():
    street = rng.choice(["221B Baker Street","1600 Amphitheatre Parkway","Flat 4, Sunder Nagar","Rua Augusta 1200","12 Rue de Rivoli","4-1 Chiyoda","88 Queen Street","Plot 7, Banjara Hills","30 Rockefeller Plaza","5 Marina Boulevard","19 Almeida Road","77 King William St"])
    city = rng.choice(["London NW1 6XE, UK","Mountain View, CA 94043","New Delhi 110003, India","01304-001 Sao Paulo","75001 Paris, France","Tokyo 100-0001, Japan","Auckland 1010, NZ","Hyderabad 500034, India","New York, NY 10112","Singapore 018989"])
    return f"{street}\n{city}"

def prose():
    subj = rng.choice(["The meeting","The quarterly review","Her argument","The draft","The release","The retro","The client call","The design","The migration","The onboarding"])
    verb = rng.choice(["is moved to","was softer than expected on","hinges on","needs another pass before","slipped to","went long over","landed well with","surprised everyone on","was blocked by","got pushed past"])
    obj = rng.choice(["Thursday afternoon","the enterprise side","the primitives, not the framework","the conclusion","next sprint","the caching section","the finance team","the mobile layout","the vendor review","the security sign-off"])
    tail = rng.choice(["please review before then.","bring questions.","the spare key is with the neighbour.","we can discuss Monday.","nothing urgent.","flag anything odd.","details to follow.","no action needed yet.","loop in design.","notes in the doc."])
    return f"{subj} {verb} {obj}; {tail}"

def code():
    return rng.choice([
        "func total(_ xs: [Int]) -> Int { xs.reduce(0, +) }",
        "SELECT id, name FROM users WHERE active = 1 ORDER BY created_at DESC LIMIT 50;",
        "const sum = (a, b) => a + b;\nexport default sum;",
        "for i in range(10):\n    print(i * i)",
        '{"model": "verdict-fm", "policy": {"votes": 3}, "timeout_ms": 5000}',
        "git rebase -i HEAD~3 && git push --force-with-lease",
        "docker run --rm -p 8080:8080 -e LOG_LEVEL=debug myimage:latest",
        "import numpy as np\narr = np.zeros((3, 3))\nprint(arr.sum())",
        "curl -s https://api.example.com/v1/items | jq '.data[].id'",
        "def fib(n): return n if n < 2 else fib(n-1) + fib(n-2)",
        "CREATE INDEX idx_events_status ON events(status, id);",
        "let total = items.filter { $0.active }.reduce(0) { $0 + $1.count }",
        "kubectl rollout restart deployment/api -n production",
        "npm install --save-dev vitest @vitest/coverage-v8",
        'print(f"{name}: {value:.2f}")',
        "SELECT count(*) FROM users GROUP BY country HAVING count(*) > 100;",
        'export PATH="$HOME/.local/bin:$PATH" && source ~/.zshrc',
        'for f in *.txt; do mv "$f" "${f%.txt}.md"; done',
        "type Point = { x: number; y: number };",
        "assert response.status_code == 200, response.text",
        "brew install --cask docker && open -a Docker",
        "rsync -av --delete ./build/ server:/var/www/",
        "@Test func decodes() throws { #expect(try parse(x) == y) }",
        "df -h | awk 'NR>1 {print $5, $6}' | sort -rn",
    ])

def url():
    host = rng.choice(["developer.apple.com","github.com","news.ycombinator.com","en.wikipedia.org","arxiv.org","www.bbc.co.uk","stackoverflow.com","docs.python.org","www.nytimes.com","huggingface.co","medium.com","www.reddit.com"])
    tmpl = rng.choice(["documentation/foundationmodels","mizorewww/laya-coreml","wiki/Actor_model","abs/{n5}","news/technology-{n8}","questions/{n7}/how-to","3/library/asyncio.html","r/LocalLLaMA/comments/{s}","models/{s}","item?id={n7}","blog/{s}/post","a/{s}/deep-dive"])
    path = tmpl.format(n5=rng.randint(0,99999), n8=rng.randint(0,99999999), n7=rng.randint(1000,9999999), s="".join(rng.choice("abcdefghijklmnop") for _ in range(6)))
    scheme = rng.choice(["https://","https://","http://",""])
    return f"{scheme}{host}/{path}"

def url_with_secret():
    tok = "".join(rng.choice("abcdef0123456789") for _ in range(32))
    host = rng.choice(["api.example.com/v1/data","hooks.slack.com/services/T00/B00","example.com/reset","cdn.site.io/asset"])
    key = rng.choice(["api_key","token","access_token","sig"])
    return f"https://{host}?{key}={tok}"

def api_key():
    body = "".join(rng.choice("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789") for _ in range(rng.choice([32,38,40])))
    return rng.choice([f"sk-{body}", f"ghp_{body}", f"AKIA{body[:16]}", f"xoxb-{body}", f"AIza{body[:35]}"])

def password_line():
    pw = "".join(rng.choice("ABCDEFghijkl!@#$%mnop0123456789") for _ in range(rng.choice([12,16,20])))
    return rng.choice([f"password: {pw}", f"db_pass={pw}", f"login: admin  /  {pw}", f"PGPASSWORD={pw}"])

def private_key():
    return "-----BEGIN OPENSSH PRIVATE KEY-----\n" + "".join(rng.choice("ABCDEFGHIJKLMNOPabcdef0123456789+/") for _ in range(rng.choice([60,80,100]))) + "\n-----END OPENSSH PRIVATE KEY-----"

def email():
    n = rng.choice(["priya","arjun.mehta","s.khan","hello","dev","nina.rao","support","t.ford","yuki","contact"])
    d = rng.choice(["gmail.com","atlas.example","proton.me","fastmail.com","outlook.com","company.co"])
    return f"{n}@{d}"

def phone():
    cc = rng.choice(["+91","+1","+44","+61","+49","+81",""])
    n = " ".join("".join(rng.choice("0123456789") for _ in range(rng.choice([3,4,5]))) for _ in range(rng.choice([2,3])))
    return f"{cc} {n}".strip()

# (name, gen, is_url, is_contact, is_code, is_secret, count)
CLASSES = [
    ("pure_url",     url,             1,0,0,0, 26),
    ("url_secret",   url_with_secret, 1,0,0,1, 14),
    ("contact_card", card,            0,1,0,0, 24),
    ("address",      address,         0,1,0,0, 14),
    ("email",        email,           0,1,0,0, 20),
    ("phone",        phone,           0,1,0,0, 16),
    ("code",         code,            0,0,1,0, 24),
    ("prose",        prose,           0,0,0,0, 24),
    ("api_key",      api_key,         0,0,0,1, 20),
    ("password",     password_line,   0,0,0,1, 14),
    ("private_key",  private_key,     0,0,1,1,  8),
]

cases = []
for name, gen, u, c, code_, sec, n in CLASSES:
    seen = set(); tries = 0
    while len([x for x in cases if x["class"] == name]) < n and tries < n * 40:
        tries += 1
        text = gen()
        if text in seen: continue
        seen.add(text)
        truth = {"is_url": bool(u), "is_contact": bool(c), "is_code": bool(code_), "is_secret": bool(sec)}
        surface = (truth["is_url"] or truth["is_contact"]) and not truth["is_secret"]
        cases.append({"id": f"{name}-{len([x for x in cases if x['class']==name])+1}", "class": name,
                      "state": text, "truth": truth, "should_surface": surface})
rng.shuffle(cases)
out = sys.argv[1] if len(sys.argv) > 1 else "clipboard.json"
json.dump({"seed": 7, "questions": ["is_url","is_contact","is_code","is_secret"],
           "join": "surface = (is_url OR is_contact) AND NOT is_secret", "cases": cases},
          open(out, "w"), indent=1, ensure_ascii=False)
from collections import Counter
print(len(cases), "items:", dict(Counter(c["class"] for c in cases)))
print("should_surface:", sum(c["should_surface"] for c in cases), "of", len(cases))
