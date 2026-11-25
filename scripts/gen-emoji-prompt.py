#!/usr/bin/env python3
"""Generate one wallet's One Emoji One Smile build prompt from the template.

Only identity/anchor/path/emoji tokens are replaced; task content is untouched.
Never prints keys. Usage:
  gen-emoji-prompt.py --template prompts/emoji-template.txt \
    --anchor <40-hex> --round <n> --wallet-n 210 \
    --staging <dir> --emoji <emoji> --out <file>
"""
import argparse

p = argparse.ArgumentParser()
p.add_argument("--template", required=True)
p.add_argument("--anchor", required=True)
p.add_argument("--round", required=True)
p.add_argument("--wallet-n", required=True)
p.add_argument("--staging", required=True)
p.add_argument("--emoji", required=True)
p.add_argument("--out", required=True)
a = p.parse_args()

text = open(a.template, encoding="utf-8").read()
for token, value in [
    ("__ANCHOR__", a.anchor),
    ("__ROUND__", a.round),
    ("__STAGING_DIR__", a.staging),
    ("__EMOJI__", a.emoji),
]:
    assert token in text, f"template missing token {token}"
    text = text.replace(token, value)
for leftover in ("__ANCHOR__", "__ROUND__", "__STAGING_DIR__", "__EMOJI__"):
    assert leftover not in text, f"unreplaced token {leftover}"
open(a.out, "w", encoding="utf-8").write(text)
print(f"OK prompt {a.out} wallet={a.wallet_n} anchor={a.anchor[:12]}... round={a.round}")
