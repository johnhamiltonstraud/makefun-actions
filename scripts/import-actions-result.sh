#!/usr/bin/env bash
# import-actions-result.sh — pull one wallet's Actions result back into the VM.
# Usage: import-actions-result.sh <wallet> [--repo johnhamiltonstraud/makefun-actions]
# Requires: gh authenticated (deploy.sh does this). Reads the `results` branch
# (wallet-N-news20.json + optionally credentials-wallet-N.json.gpg), decrypts
# returned credentials with ~/workspace/makefun-actions-passphrase.txt,
# installs them mode 600, updates referral165-progress.tsv and writes
# hidden_files/w<N>-submissions.md. Prints NO secret material.
# Safe to re-run: skips a wallet already marked server-verified for News 20.
set -euo pipefail
N="${1:?usage: import-actions-result.sh <wallet>}"
REPO="${2:-johnhamiltonstraud/makefun-actions}"
GOAL="$HOME/workspace/goals/make-fun-usdc-bounty-entries"
TSV="$GOAL/hidden_files/referral165-progress.tsv"
PASS_FILE="$HOME/workspace/makefun-actions-passphrase.txt"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
gh repo clone "$REPO" "$TMP/repo" -- --branch results --single-branch >/dev/null 2>&1 \
  || { echo "FAIL: cannot clone $REPO branch results (is gh authed? did any job push yet?)" >&2; exit 1; }
RES="$TMP/repo/results/wallet-$N-news20.json"
[ -f "$RES" ] || { echo "FAIL: no result for wallet $N on results branch yet" >&2; exit 1; }
python3 - "$RES" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("status") == "server-verified", f"status is {d.get('status')}, not server-verified"
assert d.get("claim_code", "").startswith("AF-"), "no AF- claim code"
print(f"OK result wallet={d['wallet']} claim={d['claim_code']} submission={d.get('submission_id')} server_time={d.get('server_time')}")
PY
CLAIM="$(python3 -c "import json;print(json.load(open('$RES'))['claim_code'])")"
HANDLE="$(python3 -c "import json;d=json.load(open('$RES'));print(d.get('handle','') or '')" 2>/dev/null || true)"
# Returned credentials (only when the run registered the account): decrypt + install.
ENC="$TMP/repo/results/credentials-wallet-$N.json.gpg"
if [ -f "$ENC" ]; then
  [ -f "$PASS_FILE" ] || { echo "FAIL: passphrase file missing: $PASS_FILE" >&2; exit 1; }
  gpg --batch --yes --quiet --passphrase-file "$PASS_FILE" \
    --output "$HOME/workspace/makefun-work/credentials-wallet-$N.json" --decrypt "$ENC"
  chmod 600 "$HOME/workspace/makefun-work/credentials-wallet-$N.json"
  echo "OK installed credentials-wallet-$N.json (mode 600)"
fi
# Update TSV row for this wallet number (bounty news-image-20261120).
python3 - "$TSV" "$N" "$CLAIM" "$HANDLE" <<'PY'
import sys
tsv, n, claim, handle = sys.argv[1:5]
rows = [l.rstrip("\n").split("\t") for l in open(tsv)]
out, found = [], False
for r in rows:
    if len(r) >= 2 and r[1] == n:
        found = True
        # keep ref_no/handle/wallet; set bounty, claim, status
        while len(r) < 8: r.append("")
        if handle: r[2] = handle
        r[4] = "news-image-20261120"; r[5] = claim; r[6] = "server-verified"
    out.append(r)
assert found, f"no TSV row for wallet {n}"
open(tsv, "w").write("\n".join("\t".join(r) for r in out) + "\n")
print(f"OK TSV updated wallet={n} claim={claim}")
PY
# Submissions record (same shape as the local wNN-submissions.md files).
SUB="$GOAL/hidden_files/w$N-submissions.md"
{
  echo "# Wallet $N — news-image-20261120 (GitHub Actions)"
  echo ""
  echo "- claim: $CLAIM"
  echo "- result: $(cat "$RES" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('submission_id',''), d.get('server_time',''))")"
  echo "- runner: github-actions (see repo $REPO, branch results)"
} > "$SUB"
echo "OK wrote $SUB"
echo "DONE wallet $N imported"
