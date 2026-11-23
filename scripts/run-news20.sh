#!/usr/bin/env bash
# run-news20.sh — one make.fun News-20 build inside a GitHub Actions runner.
# Replicates the proven local pipeline (finish-news20.sh + news20-block-driver.sh
# + codex-npm-xingchi-build.sh), with VM paths replaced by $WORK.
# Env (from workflow): WALLET_N, WALLET_ADDR, REFERRAL, COMP, TITLE.
# Secrets (env, never printed): XINGCHI_API_KEY, ARCHIVE_PASSPHRASE.
# Exits 0 only when the submit returns a claim code AF-... and the result
# JSON is written to work/result.json. On any failure writes
# work/result-failed.json and exits 1 (artifacts still upload).
set -u
ROOT="${GITHUB_WORKSPACE:-$PWD}"
WORK="$ROOT/work"
N="${WALLET_N:?}"; ADDR="${WALLET_ADDR:?}"; REF="${REFERRAL:-}"; COMP="${COMP:-news-image-20261120}"
TITLE="${TITLE:-Friday 20 November 2026 — Trilateral Shenzhen summit, ICJ verdict, Akvan landfall}"
KIT_URL="https://make.fun/c/news-image-20261120/kit"
mkdir -p "$WORK/creds" "$WORK/results"
BUILD_LOG="$WORK/build.log"; : > "$BUILD_LOG"
say() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$BUILD_LOG"; }
fail() { say "FAIL: $*";
  python3 -c "import json; json.dump({'wallet':$N,'competition':'$COMP','status':'failed','step':'$1','error':'''$2''','at':'$(date -u +%FT%TZ)'}, open('$WORK/result-failed.json','w'), indent=2)"
  exit 1; }
# watchdog_wait <pid> <logfile> <max_seconds> — wait for a background build,
# killing it after 600s with no log growth or after <max_seconds> total.
# Returns the child exit code (nonzero on kill/timeout).
watchdog_wait() {
  local pid="$1" log="$2" max="$3" idle=0 elapsed=0 last=0 size=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 30; elapsed=$((elapsed+30))
    size="$(stat -c %s "$log" 2>/dev/null || echo 0)"
    if [ "$size" = "$last" ]; then idle=$((idle+30)); else idle=0; last="$size"; fi
    if [ "$idle" -ge 600 ]; then say "WATCHDOG: no output for 600s, killing pid $pid"; kill -TERM "$pid" 2>/dev/null; sleep 5; kill -KILL "$pid" 2>/dev/null; break; fi
    if [ "$elapsed" -ge "$max" ]; then say "TIMEOUT: ${max}s, killing pid $pid"; kill -KILL "$pid" 2>/dev/null; break; fi
  done
  wait "$pid" 2>/dev/null && return 0 || return $?
}
# 0. Pick one of 10 Xingchi keys by wallet number (2 jobs per key at 20-way
#    parallelism) — fixes the 429 storm from batch 21, when all 20 jobs hit
#    a single key. Slots XINGCHI_API_KEY_1..10 are GitHub Secrets; an unset
#    slot falls back to the original XINGCHI_API_KEY, so jobs keep working
#    while slots are being filled. Only the slot NUMBER is logged, never a key.
KEY_IDX=$(( (N - 1) % 10 + 1 ))
KEY_VAR="XINGCHI_API_KEY_${KEY_IDX}"
XINGCHI_API_KEY="${!KEY_VAR:-${XINGCHI_API_KEY:-}}"
export XINGCHI_API_KEY
[ -n "${XINGCHI_API_KEY:-}" ] || fail "setup" "no Xingchi key: slot $KEY_IDX empty and XINGCHI_API_KEY secret missing"
say "using Xingchi key slot $KEY_IDX (wallet $N)"
[ -n "${ARCHIVE_PASSPHRASE:-}" ] || fail "setup" "ARCHIVE_PASSPHRASE secret missing"

# 1. Decrypt per-account credentials archive (ciphertext is committed to the
#    private repo; the passphrase lives only in a GitHub Secret).
say "decrypting credentials archive"
printf '%s' "$ARCHIVE_PASSPHRASE" | gpg --batch --yes --quiet --passphrase-fd 0 \
  --output "$WORK/creds.tar.gz" --decrypt "$ROOT/credentials.tar.gz.gpg" \
  || fail "decrypt" "gpg decrypt of credentials.tar.gz.gpg failed"
tar xzf "$WORK/creds.tar.gz" -C "$WORK/creds" || fail "decrypt" "tar extract failed"
rm -f "$WORK/creds.tar.gz"
KP="$WORK/creds/keypair-wallet-$N.json"
chmod 600 "$KP" "$WORK/creds/"*.json 2>/dev/null || true
[ -f "$KP" ] || fail "decrypt" "keypair-wallet-$N.json not in archive"
CREDS="$WORK/creds/credentials-wallet-$N.json"
export MAKEFUN_CREDENTIALS="$CREDS"

# 2. Codex via npm (same version as the VM: 0.170.0) + Xingchi profile.
say "installing codex 0.170.0"
mkdir -p "$WORK/codex-npm" "$HOME/.codex"
cat > "$HOME/.codex/xingchi.config.toml" <<'EOF'
model = "gpt-6.1-sol"
model_provider = "xingchi"

[model_providers.xingchi]
name = "xingchi"
base_url = "https://api.xingchiapi.com/v1"
wire_api = "responses"
env_key = "XINGCHI_API_KEY"
EOF
cd "$WORK/codex-npm" && npm install --no-save @openai/codex@0.170.0 >>"$BUILD_LOG" 2>&1 \
  || fail "codex-install" "npm install @openai/codex@0.170.0 failed"
CODEX="$WORK/codex-npm/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex"
[ -x "$CODEX" ] || fail "codex-install" "codex binary not found after npm install"
export XINGCHI_API_KEY

# 3. Fresh kit (the VM's v27 copy is stale: server is at level 29).
say "downloading fresh kit $KIT_URL"
mkdir -p "$WORK/kit-dl" && curl -sSL "$KIT_URL" | tar xz -C "$WORK/kit-dl" \
  || fail "kit" "kit download failed"
KIT="$(find "$WORK/kit-dl" -maxdepth 2 -name competition.yaml -path "*$COMP*" -print -quit | xargs dirname 2>/dev/null)"
[ -n "$KIT" ] && [ -f "$KIT/cli/makefun.mjs" ] || fail "kit" "kit for $COMP not found in download"
CLI="$KIT/cli/makefun.mjs"
say "kit ready: $KIT"

# 4. Register the account if it has no API credentials yet.
#    register stores the key in $MAKEFUN_CREDENTIALS (never printed).
NEW_CREDS=""
if [ ! -f "$CREDS" ]; then
  [ -n "$REF" ] || fail "register" "no credentials in archive and no referral code given"
  say "registering wallet $N with referral $REF"
  node "$CLI" register --keypair "$KP" --ref "$REF" --json > "$WORK/register-w$N.out" 2> "$WORK/register-w$N.err" \
    || { cat "$WORK/register-w$N.err" >> "$BUILD_LOG" 2>/dev/null; fail "register" "makefun register failed (see register-w$N.err artifact)"; }
  [ -f "$CREDS" ] || fail "register" "register exited 0 but no credentials file was written"
  chmod 600 "$CREDS"
  NEW_CREDS=1
  say "registered (handle in register output)"
  # Extract the handle for sync-back (defensive: --json shape may vary).
  python3 - "$WORK/register-w$N.out" "$WORK/handle.txt" <<'PY' 2>/dev/null || true
import json, re, sys
def find(o):
    if isinstance(o, dict):
        if "handle" in o: return o["handle"]
        for v in o.values():
            r = find(v)
            if r: return r
    if isinstance(o, list):
        for v in o:
            r = find(v)
            if r: return r
    return None
try:
    d = json.load(open(sys.argv[1])); h = find(d)
except Exception:
    h = None
if not h:
    m = re.search(r"@([A-Za-z0-9_-]+)", open(sys.argv[1]).read())
    h = "@" + m.group(1) if m else ""
open(sys.argv[2], "w").write(h or "")
PY
else
  say "credentials already in archive, skipping register"
fi

# 5. Kit init: creates the entry repo + anchor (drand round, repo_url bundle:<sha>).
#    MUST live OUTSIDE $GITHUB_WORKSPACE: makefun init refuses to start an
#    entry inside another repository ("run init in that repository's top
#    directory, or in a new directory outside it"). That was the W210
#    failure in run 44824709287: work/entry-repo sits inside the checkout.
#    Use --keypair (the proven local form) instead of --wallet.
REPO="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/entry-repo-w$N"
rm -rf "$REPO"
mkdir -p "$REPO"
say "kit init for wallet $ADDR (repo $REPO)"
(cd "$REPO" && node "$CLI" init --competition "$COMP" --keypair "$KP" > "$WORK/init-w$N.log" 2>&1) \
  || { cat "$WORK/init-w$N.log" >> "$BUILD_LOG" 2>/dev/null; fail "init" "makefun init failed (see init-w$N.log artifact)"; }
ANCHOR_LINE="$(grep -oE 'makefun anchor [0-9a-f]{40} round [0-9]+' "$WORK/init-w$N.log" | head -1)"
[ -n "$ANCHOR_LINE" ] || fail "init" "no anchor line in init output"
ANCHOR="$(echo "$ANCHOR_LINE" | awk '{print $3}')"; ROUND="$(echo "$ANCHOR_LINE" | awk '{print $5}')"
say "anchor $ANCHOR round $ROUND"

# 6. Prompt from template + build lanes (watchdog: kill after 10 min idle).
# Lane priority: 1 Codex/Xingchi -> 2 OpenCode/HMS (100milionseek.top) ->
# 3 OpenCode/DotAi (samp.team). A lane only wins when it exits 0 AND
# main.py exists in the staging dir AND its transcript is collectable
# (Codex rollout by anchor, OpenCode store dir). LANE/LANE_MODEL record
# the winning lane for the finish step and result.json.
LANE=""; LANE_MODEL=""; OPENCODE_DIR="$HOME/.local/share/opencode"
STAGE="$WORK/wallet-$N-news-image-20261120"
mkdir -p "$STAGE"
python3 "$ROOT/scripts/gen-prompt.py" --template "$ROOT/prompts/news20-template.txt" \
  --anchor "$ANCHOR" --round "$ROUND" --wallet-n "$N" \
  --staging "$STAGE" --template-path "$ROOT/reference/template-news20-main.py" \
  --out "$WORK/prompt-w$N-news20.txt" || fail "prompt" "gen-prompt failed"
PROMPT="$(cat "$WORK/prompt-w$N-news20.txt")"
say "codex build started (watchdog 10 min idle, 60 min max)"
# Codex's workspace-write sandbox only allows writes under its working
# directory. The npm install above left cwd at $WORK/codex-npm, so in run
# 44825231693 Codex built main.py under codex-npm/wallet-... instead of the
# staging dir (which it reported read-only) and the run failed with
# "no main.py in staging dir" even though the build itself succeeded.
# Run Codex from $WORK so the staging dir is inside its workspace.
cd "$WORK"
RUN_LOG="$WORK/codex-run.log"; : > "$RUN_LOG"
"$CODEX" exec --profile xingchi --sandbox workspace-write --skip-git-repo-check "$PROMPT" \
  < /dev/null >> "$RUN_LOG" 2>&1 &
CODEX_PID=$!
IDLE=0; ELAPSED=0; LAST_SIZE=0
while kill -0 "$CODEX_PID" 2>/dev/null; do
  sleep 30; ELAPSED=$((ELAPSED+30))
  SIZE="$(stat -c %s "$RUN_LOG" 2>/dev/null || echo 0)"
  if [ "$SIZE" = "$LAST_SIZE" ]; then IDLE=$((IDLE+30)); else IDLE=0; LAST_SIZE="$SIZE"; fi
  if [ "$IDLE" -ge 600 ]; then say "WATCHDOG: no output for 600s, killing codex"; kill -TERM "$CODEX_PID" 2>/dev/null; sleep 5; kill -KILL "$CODEX_PID" 2>/dev/null; break; fi
  if [ "$ELAPSED" -ge 3600 ]; then say "TIMEOUT: 60 min, killing codex"; kill -KILL "$CODEX_PID" 2>/dev/null; break; fi
done
wait "$CODEX_PID" 2>/dev/null && EC=0 || EC=$?
say "codex build exit $EC"
[ "$EC" -eq 0 ] || say "lane 1 (codex) FAILED exit $EC — trying lane 2 (see codex-run.log artifact)"
# Defensive salvage: if the sandbox still diverted the files to the
# codex-npm working dir (as in run 44825231693), adopt the Codex-built
# files from there — they were typed in this session, this only moves them
# to the staging dir the finish step expects.
if [ ! -s "$STAGE/main.py" ] && [ -s "$WORK/codex-npm/wallet-$N-news-image-20261120/main.py" ]; then
  say "salvage: adopting Codex-built files from codex-npm workdir"
  cp "$WORK/codex-npm/wallet-$N-news-image-20261120/main.py" "$WORK/codex-npm/wallet-$N-news-image-20261120/README.md" "$STAGE/" 2>/dev/null || true
fi
if [ ! -s "$STAGE/main.py" ]; then say "lane 1 (codex) produced no main.py — trying lane 2"; fi

# 7. Rollout session by ANCHOR (Codex lane only; never newest-by-mtime:
#    parallel jobs share HOME). Codex 0.170.0 stores sessions at
#    ~/.codex/sessions/<yyyy>/<mm>/<dd>/ rollout-*.jsonl — the old glob
#    "20*/rollout-*.jsonl" missed that depth, so grep found nothing and
#    `xargs ls -t` with no input listed the cwd, picking "build.log" as the
#    "rollout" (run 44826396065 failed at bundle: "--session build.log: not
#    valid JSON"). Use the dated glob, xargs -r so an empty match runs
#    nothing, and require the result to actually be a rollout file under
#    .codex/sessions. A missing/mismatched rollout means lane 1 cannot
#    bundle — fall through to lane 2 with a clean staging dir.
ROLLOUT=""
if [ -s "$STAGE/main.py" ]; then
  ROLLOUT="$(grep -l "$ANCHOR" "$HOME"/.codex/sessions/20*/*/*/rollout-*.jsonl 2>/dev/null | xargs -r ls -t 2>/dev/null | head -1)"
  case "$ROLLOUT" in
    */.codex/sessions/*/rollout-*.jsonl) ;;
    *) say "lane 1 (codex) rollout not found (glob found: ${ROLLOUT:-none}) — trying lane 2"; ROLLOUT="" ;;
  esac
  if [ -n "$ROLLOUT" ] && [ -f "$ROLLOUT" ] && grep -q "$ANCHOR" "$ROLLOUT"; then
    LANE="codex"; LANE_MODEL="xingchi/gpt-6.1-sol"; say "lane 1 (codex) WON rollout $ROLLOUT"
  elif [ -n "$ROLLOUT" ]; then
    say "lane 1 (codex) rollout anchor mismatch — trying lane 2"; ROLLOUT=""
  fi
fi

# 7b. Lane 2: OpenCode + HMS (100milionseek.top, deepseek-v4.1-flash-free).
#     Codex cannot use HMS keys (no /v1/responses); OpenCode uses chat
#     completions. Try up to 3 HMS slots starting at (N-1)%11+1, next key
#     on any failure. Only the slot NUMBER is logged, never a key.
if [ -z "$LANE" ]; then
  say "lane 2: installing opencode 1.19.6"
  if npm install -g opencode-ai@1.19.6 >>"$BUILD_LOG" 2>&1 && command -v opencode >/dev/null; then
    mkdir -p "$HOME/.config/opencode"
    cat > "$HOME/.config/opencode/opencode.json" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "hms": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "100milionseek",
      "options": { "baseURL": "https://100milionseek.top/v1", "apiKey": "{env:HMS_API_KEY}" },
      "models": { "deepseek-v4.1-flash-free": { "name": "deepseek-v4.1-flash-free" } }
    },
    "samp": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "SampTeam",
      "options": { "baseURL": "https://api.samp.team/v1", "apiKey": "{env:SAMP_API_KEY}" },
      "models": {
        "minimax-m3.1-flash": { "name": "minimax-m3.1-flash" },
        "deepseek-v4.1-flash": { "name": "deepseek-v4.1-flash" },
        "glm-5.3-flash": { "name": "glm-5.3-flash" }
      }
    }
  }
}
EOF
    ATTEMPT=0
    while [ "$ATTEMPT" -lt 3 ] && [ -z "$LANE" ]; do
      HMS_IDX=$(( (N - 1 + ATTEMPT) % 11 + 1 ))
      HMS_VAR="HMS_API_KEY_${HMS_IDX}"
      HMS_API_KEY="${!HMS_VAR:-}"
      if [ -z "$HMS_API_KEY" ]; then say "lane 2: HMS slot $HMS_IDX empty, skipping"; ATTEMPT=$((ATTEMPT+1)); continue; fi
      export HMS_API_KEY
      say "lane 2 attempt $((ATTEMPT+1)): opencode hms/deepseek-v4.1-flash-free (HMS slot $HMS_IDX)"
      rm -f "$STAGE/main.py" "$STAGE/README.md"
      OC_LOG="$WORK/opencode-run.log"; : > "$OC_LOG"
      cd "$WORK"
      # --auto: unattended CI run on an ephemeral runner, our own prompt
      # and repo — the build needs write/edit/bash without a human present.
      opencode run --auto --model hms/deepseek-v4.1-flash-free "$PROMPT" < /dev/null >> "$OC_LOG" 2>&1 &
      OC_PID=$!
      if watchdog_wait "$OC_PID" "$OC_LOG" 2400; then OC_EC=0; else OC_EC=$?; fi
      say "lane 2 attempt $((ATTEMPT+1)) exit $OC_EC"
      if [ "$OC_EC" -eq 0 ] && [ -s "$STAGE/main.py" ]; then LANE="opencode-hms"; LANE_MODEL="hms/deepseek-v4.1-flash-free"; say "lane 2 (opencode-hms) WON (HMS slot $HMS_IDX)"; fi
      ATTEMPT=$((ATTEMPT+1))
    done
    unset HMS_API_KEY
  else
    say "lane 2 unavailable: opencode install failed — trying lane 3"
  fi
fi

# 7c. Lane 3: OpenCode + DotAi (samp.team, minimax-m3.1-flash first).
#     Only when every HMS key failed. DotAi models flicker (deepseek
#     400/503), so minimax is the first choice. Try up to 2 keys.
if [ -z "$LANE" ]; then
  if command -v opencode >/dev/null; then
    DOTAI_VARS="DOTAI_API_KEY DOTAI_API_KEY_GEORGE DOTAI_API_KEY_JESS DOTAI_API_KEY_MUSE5 DOTAI_API_KEY_FIERSA DOTAI_API_KEY_SWEETY DOTAI_API_KEY_FREDY DOTAI_API_KEY_NUR DOTAI_API_KEY_DINI DOTAI_API_KEY_ESTES"
    DOTAI_LIST="$(echo "$DOTAI_VARS" | tr ' ' '\n')"
    DOTAI_N=10
    ATTEMPT=0
    while [ "$ATTEMPT" -lt 2 ] && [ -z "$LANE" ]; do
      DOTAI_POS=$(( (N - 1 + ATTEMPT) % DOTAI_N + 1 ))
      DOTAI_VAR="$(echo "$DOTAI_LIST" | sed -n "${DOTAI_POS}p")"
      SAMP_API_KEY="${!DOTAI_VAR:-}"
      if [ -z "$SAMP_API_KEY" ]; then say "lane 3: DotAi key #$DOTAI_POS ($DOTAI_VAR) empty, skipping"; ATTEMPT=$((ATTEMPT+1)); continue; fi
      export SAMP_API_KEY
      say "lane 3 attempt $((ATTEMPT+1)): opencode samp/minimax-m3.1-flash (DotAi key #$DOTAI_POS)"
      rm -f "$STAGE/main.py" "$STAGE/README.md"
      OC_LOG="$WORK/opencode-run.log"; : > "$OC_LOG"
      cd "$WORK"
      opencode run --auto --model samp/minimax-m3.1-flash "$PROMPT" < /dev/null >> "$OC_LOG" 2>&1 &
      OC_PID=$!
      if watchdog_wait "$OC_PID" "$OC_LOG" 2400; then OC_EC=0; else OC_EC=$?; fi
      say "lane 3 attempt $((ATTEMPT+1)) exit $OC_EC"
      if [ "$OC_EC" -eq 0 ] && [ -s "$STAGE/main.py" ]; then LANE="opencode-dotai"; LANE_MODEL="samp/minimax-m3.1-flash"; say "lane 3 (opencode-dotai) WON (DotAi key #$DOTAI_POS)"; fi
      ATTEMPT=$((ATTEMPT+1))
    done
    unset SAMP_API_KEY
  else
    say "lane 3 unavailable: opencode not installed"
  fi
fi

[ -n "$LANE" ] || fail "build" "all lanes failed: codex (Xingchi 503/empty), opencode-hms (3 keys), opencode-dotai (2 keys) — see build.log"
say "winning lane: $LANE model $LANE_MODEL"

# 8. Validate + commit + bundle + check + submit (ported finish-news20.sh).
say "finish: validate/bundle/check/submit"
export WORK REPO STAGE KIT CLI KP LANE LANE_MODEL OPENCODE_DIR
bash "$ROOT/scripts/finish-news20-actions.sh" "$N" "$TITLE" "$BUILD_LOG" "$ROLLOUT" "" "$LANE" "$OPENCODE_DIR" \
  || fail "submit" "finish step failed (see finish-w$N-news20.log artifact)"
SUBOUT="$WORK/submit-w$N-news20.out"
CLAIM="$(grep -o -m1 'AF-[A-Z0-9]\{5\}-[A-Z0-9]\{5\}-[A-Z0-9]\{5\}-[A-Z0-9]\{5\}' "$SUBOUT" || true)"
[ -n "$CLAIM" ] || fail "submit" "submit exited 0 but no AF- claim code in output"
say "SUBMIT OK claim=$CLAIM"

# 9. Result JSON for sync-back to the VM (pushed to the `results` branch).
python3 - "$N" "$COMP" "$CLAIM" "$SUBOUT" "$WORK/result.json" "$WORK/handle.txt" <<'PY'
import json, os, sys
n, comp, claim, subout, dest, handle_file = sys.argv[1:7]
d = json.load(open(subout))
r = d.get("receipt", {}) or {}
handle = ""
try: handle = open(handle_file).read().strip()
except Exception: pass
json.dump({
    "wallet": int(n), "competition": comp, "status": "server-verified",
    "lane": os.environ.get("LANE", "codex"), "lane_model": os.environ.get("LANE_MODEL", ""),
    "handle": handle or None,
    "claim_code": claim, "submission_id": d.get("submission_id"),
    "title": d.get("title"), "payout_wallet": d.get("payout_wallet"),
    "server_time": r.get("server_time"), "repo": r.get("repo"),
    "commit": r.get("commit"), "bundle_sha256": r.get("bundle_sha256"),
    "run": {"runner": "github-actions", "kit": "fresh-download"},
}, open(dest, "w"), indent=2)
print("result.json written")
PY
cp "$WORK/result.json" "$WORK/results/wallet-$N-news20.json"
# If this run registered the account, return the new credentials encrypted
# (same passphrase) so the VM can adopt them — never plaintext in git.
if [ -n "$NEW_CREDS" ]; then
  printf '%s' "$ARCHIVE_PASSPHRASE" | gpg --batch --yes --quiet --passphrase-fd 0 \
    --symmetric --cipher-algo AES256 --output "$WORK/results/credentials-wallet-$N.json.gpg" "$CREDS" \
    || fail "sync" "encrypting returned credentials failed"
  say "new credentials encrypted for sync-back"
fi
# Push results branch from a throwaway clone (never touch the main worktree:
# it holds work/, the entry repo and the decrypted credentials).
git config --global user.name "makefun-actions" || true
git config --global user.email "makefun-actions@local" || true
CLONE="$WORK/results-clone"
rm -rf "$CLONE"
if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  git clone --quiet "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "$CLONE" >>"$BUILD_LOG" 2>&1 || true
fi
if [ -d "$CLONE/.git" ]; then
  ( cd "$CLONE" && (git checkout -B results origin/results 2>/dev/null || git checkout --orphan results) \
    && mkdir -p results && cp "$WORK/results/"* results/ 2>/dev/null \
    && git add results && git commit -m "wallet-$N $COMP $CLAIM" >>"$BUILD_LOG" 2>&1 \
    && ( for _try in 1 2 3; do git push origin results >>"$BUILD_LOG" 2>&1 && break; sleep 10; git fetch origin results >>"$BUILD_LOG" 2>&1 && git rebase origin/results >>"$BUILD_LOG" 2>&1 || git rebase --abort >>"$BUILD_LOG" 2>&1; done; git push origin results >>"$BUILD_LOG" 2>&1 ) && echo PUSHED || echo PUSH_FAILED ) > "$WORK/push-results.out" 2>&1
  if grep -q PUSHED "$WORK/push-results.out"; then say "results branch pushed"; else say "WARNING: results branch push failed — import from the uploaded artifact instead"; fi
else
  say "WARNING: no GitHub remote available — import from the uploaded artifact instead"
fi
rm -rf "$CLONE"
say "DONE wallet-$N claim=$CLAIM"
exit 0
