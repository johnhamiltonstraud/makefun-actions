#!/usr/bin/env bash
# deploy.sh — create the PRIVATE repo, push, set secrets, dispatch W210.
# RUN BY HAND on the VM after Ariel provides GitHub access. This script reads
# secret VALUES only from local mode-600 files and pipes them straight into
# `gh secret set` — it never prints them, never writes them to a file/log.
# Needs: gh authenticated as johnhamiltonstraud with scopes repo + workflow.
#   If `gh auth status` fails, run first (Ariel, interactive):
#     gh auth login --scopes repo,workflow
#   and approve in the browser / paste the code. No password/OTP is typed here.
set -euo pipefail
REPO_DIR="$HOME/workspace/makefun-actions"
REPO="johnhamiltonstraud/makefun-actions"
PASS_FILE="$HOME/workspace/makefun-actions-passphrase.txt"
cd "$REPO_DIR"
gh auth status >/dev/null 2>&1 || { echo "FAIL: gh is not logged in. Run: gh auth login --scopes repo,workflow (Ariel, interactive)" >&2; exit 1; }
[ -f credentials.tar.gz.gpg ] || { echo "FAIL: run scripts/package-secrets.sh first" >&2; exit 1; }
[ -f "$PASS_FILE" ] || { echo "FAIL: passphrase file missing: $PASS_FILE" >&2; exit 1; }
if gh repo view "$REPO" >/dev/null 2>&1; then
  echo "repo $REPO already exists, pushing to it"
else
  gh repo create "$REPO" --private --description "make.fun News-20 builds on GitHub Actions (parallel lanes)" || exit 1
fi
git init -q 2>/dev/null || true
git add -A
git commit -qm "makefun-actions: News-20 workflow + W210 test" || echo "(nothing new to commit)"
git branch -M main
git remote add origin "https://github.com/$REPO.git" 2>/dev/null || true
git push -u origin main
gh secret set ARCHIVE_PASSPHRASE < "$PASS_FILE"
echo "ARCHIVE_PASSPHRASE set (value never printed)"
# XINGCHI_API_KEY: the VM holds NO plaintext Xingchi key — Codex here runs on
# a runtime surrogate that does not work outside this VM, and the key file
# ~/workspace/xingchiapi/api_key does not exist. Ariel must supply the real
# key. `gh secret set` with no value prompts for it (hidden input, never
# echoed, never pasted in chat). Get it from the Xingchi dashboard/API keys
# page (the key Ariel reconnected 21 Nov 02:24 WIB).
echo "Now set the Xingchi key (paste when prompted; it is hidden, never shown):"
gh secret set XINGCHI_API_KEY
echo "secrets set"
gh workflow run news20-build.yml --ref main \
  -f wallet=210 -f wallet_address=EfRoY8nU755DppBCbCZ1V3D652vRSkUtZ4b7veqfeAuR \
  -f referral=p346xfan
echo "dispatched W210. Watch: https://github.com/$REPO/actions"
echo "After it finishes, import with: bash scripts/import-actions-result.sh 210"
