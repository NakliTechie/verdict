#!/usr/bin/env python3
"""A labelled clipboard fixture for the dataflow gate (SPEC §12.5, M4b). Each item is a realistic
clipboard capture with crisp ground truth for four noul questions and the derived routing decision.

  python3 scripts/make-clipboard-fixture.py ~/Code/knowledge/plan/fm-bench/clipboard.json

Ground truth (unambiguous by construction; secrets are synthetic):
  is_url      the text is a single web URL
  is_contact  the text is a person's contact detail(s): a card, a bare email, phone, or postal address
  is_code     the text is source code, a shell command, or a config/JSON blob
  is_secret   the text contains a credential: an API key, token, password line, or private key
Routing (the join under test): surface = (is_url OR is_contact) AND NOT is_secret
  — verdict should offer to capture URLs and contact cards, and must never surface a secret.
"""
import json, sys, random

rng = random.Random(7)

def card():
    fn = rng.choice(["Priya Raman","Arjun Mehta","Sara Khan","Devlin Fox","Ana Costa","Wei Chen","Omar Haddad","Lena Vogel"])
    org = rng.choice(["Atlas Robotics","Northwind Labs","Meridian Health","Cobalt Systems","Vireo AI"])
    dom = org.lower().split()[0]
    return f"{fn}\n{rng.choice(['Senior Engineer','Head of Design','Founder','Analyst','PM'])}, {org}\n{fn.split()[0].lower()}@{dom}.example\n+{rng.choice(['91 98765 43210','1 415 555 0182','44 7700 900123','61 2 5550 1234'])}"

def address():
    return rng.choice([
        "221B Baker Street\nLondon NW1 6XE\nUnited Kingdom",
        "1600 Amphitheatre Parkway\nMountain View, CA 94043",
        "Flat 4, Sunder Nagar\nNew Delhi 110003\nIndia",
        "Rua Augusta 1200\n01304-001 São Paulo, SP",
    ])

def prose():
    return rng.choice([
        "The meeting is moved to Thursday; please review the deck before then and bring questions.",
        "I finished the draft last night. It still needs a conclusion but the argument holds together.",
        "Remember to water the plants and the spare key is with the neighbour while we're away.",
        "The quarterly numbers were softer than expected, mostly on the enterprise side of the book.",
        "She argued that the primitives matter more than the framework, and the room mostly agreed.",
        "Turns out the bug was a race in the cache layer, not the parser like everyone assumed.",
    ])

def code():
    return rng.choice([
        "func total(_ xs: [Int]) -> Int { xs.reduce(0, +) }",
        "SELECT id, name FROM users WHERE active = 1 ORDER BY created_at DESC LIMIT 50;",
        'const sum = (a, b) => a + b;\nexport default sum;',
        "for i in range(10):\n    print(i * i)",
        '{"model": "verdict-fm", "policy": {"votes": 3}, "timeout_ms": 5000}',
        "git rebase -i HEAD~3 && git push --force-with-lease",
        "docker run --rm -p 8080:8080 -e LOG_LEVEL=debug myimage:latest",
    ])

def url():
    return rng.choice([
        "https://developer.apple.com/documentation/foundationmodels",
        "https://github.com/mizorewww/laya-coreml",
        "https://news.ycombinator.com/item?id=41234567",
        "https://en.wikipedia.org/wiki/Actor_model",
        "https://arxiv.org/abs/2411.00001",
        "www.bbc.co.uk/news/technology-12345678",
    ])

def url_with_secret():
    tok = "".join(rng.choice("abcdef0123456789") for _ in range(32))
    return rng.choice([
        f"https://api.example.com/v1/data?api_key={tok}",
        f"https://hooks.slack.com/services/T00/B00/{tok}",
    ])

def api_key():
    body = "".join(rng.choice("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789") for _ in range(rng.choice([32,38,40])))
    return rng.choice([f"sk-{body}", f"ghp_{body}", f"AKIA{body[:16]}", f"xoxb-{body}"])

def password_line():
    pw = "".join(rng.choice("ABCDEFghijkl!@#$%mnop0123456789") for _ in range(rng.choice([12,16])))
    return rng.choice([f"password: {pw}", f"db_pass={pw}", f"login: admin  /  {pw}"])

def private_key():
    return "-----BEGIN OPENSSH PRIVATE KEY-----\n" + "".join(rng.choice("ABCDEFGHIJKLMNOPabcdef0123456789+/") for _ in range(rng.choice([60,80]))) + "\n-----END OPENSSH PRIVATE KEY-----"

def email():
    n = rng.choice(["priya","arjun.mehta","s.khan","hello","dev"])
    d = rng.choice(["gmail.com","atlas.example","proton.me","fastmail.com"])
    return f"{n}@{d}"

def phone():
    return rng.choice(["+91 98765 43210","+1 (415) 555-0182","+44 7700 900123","98765 43210"])

# (generator, is_url, is_contact, is_code, is_secret, count)
CLASSES = [
    ("pure_url",     url,             1,0,0,0, 10),
    ("url_secret",   url_with_secret, 1,0,0,1,  6),
    ("contact_card", card,            0,1,0,0, 10),
    ("address",      address,         0,1,0,0,  6),
    ("email",        email,           0,1,0,0,  8),
    ("phone",        phone,           0,1,0,0,  6),
    ("code",         code,            0,0,1,0, 12),
    ("prose",        prose,           0,0,0,0, 12),
    ("api_key",      api_key,         0,0,0,1, 10),
    ("password",     password_line,   0,0,0,1,  6),
    ("private_key",  private_key,     0,0,1,1,  4),
]

cases = []
for name, gen, u, c, code_, sec, n in CLASSES:
    seen = set()
    tries = 0
    while len([x for x in cases if x["class"] == name]) < n and tries < n * 20:
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
