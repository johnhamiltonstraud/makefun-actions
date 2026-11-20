#!/usr/bin/env python3
"""Generate one wallet's News-20 build prompt from the template.

Only identity/anchor/path tokens are replaced; task content is untouched.
Never prints keys. Usage:
  gen-prompt.py --template prompts/news20-template.txt \
    --anchor <40-hex> --round <n> --wallet-n 210 \
    --staging <dir> --template-path <file> --out <file>
"""
import argparse

p = argparse.ArgumentParser()
p.add_argument("--template", required=True)
p.add_argument("--anchor", required=True)
p.add_argument("--round", required=True)
p.add_argument("--wallet-n", required=True)
p.add_argument("--staging", required=True)
p.add_argument("--template-path", required=True)
p.add_argument("--out", required=True)
a = p.parse_args()

text = open(a.template).read()
for token, value in [
    ("__ANCHOR__", a.anchor),
    ("__ROUND__", a.round),
    ("__STAGING_DIR__", a.staging),
    ("__TEMPLATE_PATH__", a.template_path),
]:
    assert token in text, f"template missing token {token}"
    text = text.replace(token, value)
assert "__" not in text.split("makefun anchor")[0] or True
for leftover in ("__ANCHOR__", "__ROUND__", "__STAGING_DIR__", "__TEMPLATE_PATH__"):
    assert leftover not in text, f"unreplaced token {leftover}"
open(a.out, "w").write(text)
print(f"OK prompt {a.out} wallet={a.wallet_n} anchor={a.anchor[:12]}... round={a.round}")
